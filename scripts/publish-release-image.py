#!/usr/bin/env python3
"""Stream an OCI-style Docker save Release into an OCI registry without docker load.

The release archive is expected to be a zstd-compressed ``docker save`` tar that
contains an OCI image layout (``oci-layout``, ``index.json`` and
``blobs/sha256/*``).  Split Release assets are read sequentially, so neither the
compressed archive nor the unpacked image is materialized on the runner.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import BinaryIO, Iterable

CHUNK_SIZE = 1024 * 1024
SMALL_BLOB_LIMIT = 8 * 1024 * 1024
SMALL_BLOB_CACHE_TOTAL_LIMIT = 64 * 1024 * 1024
GHCR_BLOB_LIMIT_BYTES = 10_000_000_000
TEMP_FILE_MARGIN_BYTES = 1024 * 1024 * 1024
OCI_UNCOMPRESSED_LAYER_MEDIA_TYPE = "application/vnd.oci.image.layer.v1.tar"
OCI_ZSTD_LAYER_MEDIA_TYPE = "application/vnd.oci.image.layer.v1.tar+zstd"
RELEASE_TAG_RE = re.compile(r"^imx8p-dev-20\.04-v[0-9]+(?:\.[0-9]+)+(?:[-.][0-9A-Za-z.-]+)?$")
PART_RE = re.compile(r"^imx8p-dev-20\.04\.tar\.zst\.part-([0-9]+)$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
OCI_MANIFEST_MEDIA_TYPES = {
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
}


class PublishError(RuntimeError):
    """Expected publication failure with a concise operator-facing message."""


@dataclass(frozen=True)
class Asset:
    name: str
    size: int
    digest: str
    download_url: str


@dataclass(frozen=True)
class RecompressedBlob:
    original_digest: str
    digest: str
    size: int
    media_type: str


def log(message: str) -> None:
    print(message, flush=True)


def request_bytes(url: str, token: str | None = None, attempts: int = 4) -> bytes:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "imx8p-release-to-ghcr/1",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
                return response.read()
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last_error = exc
            if attempt == attempts:
                break
            delay = min(2 ** (attempt - 1), 8)
            log(f"WARN: request failed ({attempt}/{attempts}), retrying in {delay}s: {exc}")
            time.sleep(delay)
    raise PublishError(f"request failed after {attempts} attempts: {url}: {last_error}")


def load_release(repository: str, release_tag: str, token: str | None, api_base: str) -> dict:
    quoted_tag = urllib.parse.quote(release_tag, safe="")
    url = f"{api_base.rstrip('/')}/repos/{repository}/releases/tags/{quoted_tag}"
    try:
        payload = request_bytes(url, token=token)
    except PublishError as exc:
        raise PublishError(f"GitHub Release not found or unreadable: {release_tag}: {exc}") from exc
    try:
        release = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise PublishError("GitHub Release API returned invalid JSON") from exc

    if release.get("tag_name") != release_tag:
        raise PublishError(f"Release tag mismatch: expected {release_tag}, got {release.get('tag_name')!r}")
    if release.get("draft"):
        raise PublishError("refusing to publish a draft Release")
    if release.get("prerelease"):
        raise PublishError("refusing to publish a prerelease")
    if not release.get("published_at"):
        raise PublishError("Release is not in Published state")
    return release


def parse_asset(asset: dict) -> Asset:
    name = str(asset.get("name", ""))
    size = asset.get("size")
    digest = str(asset.get("digest", ""))
    download_url = str(asset.get("browser_download_url", ""))
    if not name or not isinstance(size, int) or size < 0 or not download_url:
        raise PublishError(f"Release asset metadata is incomplete: {name or '<unnamed>'}")
    if not digest.startswith("sha256:") or not HEX64_RE.fullmatch(digest[7:]):
        raise PublishError(f"Release asset has no trustworthy SHA-256 digest: {name}")
    return Asset(name=name, size=size, digest=digest, download_url=download_url)


def select_assets(release: dict) -> tuple[list[Asset], Asset]:
    assets = [parse_asset(item) for item in release.get("assets", [])]
    checksum_name = "imx8p-dev-20.04.tar.zst.sha256"
    checksum_matches = [item for item in assets if item.name == checksum_name]
    if len(checksum_matches) != 1:
        raise PublishError(f"expected exactly one {checksum_name} asset")

    indexed_parts: list[tuple[int, Asset]] = []
    for asset in assets:
        match = PART_RE.fullmatch(asset.name)
        if match:
            indexed_parts.append((int(match.group(1)), asset))
    if not indexed_parts:
        raise PublishError("no split .tar.zst Release assets were found")
    indexed_parts.sort(key=lambda item: item[0])
    actual_indices = [index for index, _ in indexed_parts]
    expected_indices = list(range(len(indexed_parts)))
    if actual_indices != expected_indices:
        raise PublishError(f"Release part indices are not contiguous from 00: {actual_indices}")
    return [asset for _, asset in indexed_parts], checksum_matches[0]


def expected_archive_sha(checksum_asset: Asset) -> str:
    payload = request_bytes(checksum_asset.download_url).decode("utf-8", errors="strict")
    asset_hash = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    if f"sha256:{asset_hash}" != checksum_asset.digest:
        raise PublishError(f"checksum sidecar asset digest mismatch: {checksum_asset.name}")

    archive_name = "imx8p-dev-20.04.tar.zst"
    matches: list[str] = []
    for line in payload.splitlines():
        fields = line.strip().split()
        if len(fields) >= 2 and fields[-1].lstrip("*") == archive_name and HEX64_RE.fullmatch(fields[0].lower()):
            matches.append(fields[0].lower())
    if len(matches) != 1:
        raise PublishError(f"checksum sidecar must contain exactly one SHA-256 for {archive_name}")
    return matches[0]


class ReleasePartFeeder:
    """Feed split zstd assets into a decoder while verifying every asset and the full archive."""

    def __init__(self, assets: Iterable[Asset], zstd_stdin: BinaryIO):
        self.assets = list(assets)
        self.zstd_stdin = zstd_stdin
        self.archive_hash = hashlib.sha256()
        self.error: Exception | None = None

    def run(self) -> None:
        try:
            for position, asset in enumerate(self.assets, 1):
                log(f"Downloading Release part {position}/{len(self.assets)}: {asset.name} ({asset.size} bytes)")
                part_hash = hashlib.sha256()
                count = 0
                headers = {"User-Agent": "imx8p-release-to-ghcr/1"}
                request = urllib.request.Request(asset.download_url, headers=headers)
                with urllib.request.urlopen(request, timeout=120) as response:
                    while True:
                        chunk = response.read(CHUNK_SIZE)
                        if not chunk:
                            break
                        count += len(chunk)
                        part_hash.update(chunk)
                        self.archive_hash.update(chunk)
                        self.zstd_stdin.write(chunk)
                if count != asset.size:
                    raise PublishError(f"asset size mismatch for {asset.name}: expected {asset.size}, got {count}")
                actual_part_digest = f"sha256:{part_hash.hexdigest()}"
                if actual_part_digest != asset.digest:
                    raise PublishError(
                        f"asset SHA-256 mismatch for {asset.name}: expected {asset.digest}, got {actual_part_digest}"
                    )
                log(f"Verified Release part: {asset.name}")
        except Exception as exc:  # propagated to the main thread after the decoder is drained
            self.error = exc
        finally:
            try:
                self.zstd_stdin.close()
            except (BrokenPipeError, OSError):
                pass


def hash_file(path: str) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb") as source:
        while True:
            chunk = source.read(CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def oras_blob_push_file(repository: str, digest_hex: str, size: int, path: str) -> None:
    command = [
        "oras",
        "blob",
        "push",
        "--no-tty",
        "--size",
        str(size),
        f"{repository}@sha256:{digest_hex}",
        path,
    ]
    log(f"Uploading recompressed OCI blob sha256:{digest_hex} ({size} bytes)")
    completed = subprocess.run(command, check=False)
    if completed.returncode != 0:
        raise PublishError(f"ORAS blob upload failed for sha256:{digest_hex} (exit {completed.returncode})")


def recompress_oversized_blob(
    repository: str,
    digest_hex: str,
    size: int,
    source: BinaryIO,
    blob_limit_bytes: int,
) -> RecompressedBlob:
    temp_root = os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()
    os.makedirs(temp_root, exist_ok=True)
    free_bytes = shutil.disk_usage(temp_root).free
    required_free = min(size, blob_limit_bytes) + TEMP_FILE_MARGIN_BYTES
    if free_bytes < required_free:
        raise PublishError(
            f"insufficient temporary disk for layer recompression: {free_bytes} bytes free, "
            f"need at least {required_free} bytes in {temp_root}"
        )
    fd, temp_path = tempfile.mkstemp(prefix="imx8p-layer-", suffix=".tar.zst", dir=temp_root)
    original_digest = hashlib.sha256()
    remaining = size
    compressor: subprocess.Popen[bytes] | None = None
    try:
        with os.fdopen(fd, "wb") as compressed_output:
            compressor = subprocess.Popen(
                ["zstd", "-T0", "-3", "-q", "-c"],
                stdin=subprocess.PIPE,
                stdout=compressed_output,
            )
            if compressor.stdin is None:
                raise PublishError("failed to open zstd stdin for oversized OCI layer")

            write_error: Exception | None = None
            try:
                while remaining:
                    chunk = source.read(min(CHUNK_SIZE, remaining))
                    if not chunk:
                        raise PublishError(
                            f"unexpected EOF inside oversized blob sha256:{digest_hex}: "
                            f"{remaining} bytes still expected"
                        )
                    remaining -= len(chunk)
                    original_digest.update(chunk)
                    compressor.stdin.write(chunk)
            except Exception as exc:
                write_error = exc
            finally:
                if not compressor.stdin.closed:
                    try:
                        compressor.stdin.close()
                    except BrokenPipeError:
                        pass

            return_code = compressor.wait()
            if write_error is not None:
                raise write_error
            if return_code != 0:
                raise PublishError(
                    f"zstd recompression failed for sha256:{digest_hex} (exit {return_code})"
                )

        actual_original_digest = original_digest.hexdigest()
        if actual_original_digest != digest_hex:
            raise PublishError(
                f"OCI blob digest mismatch before recompression: filename sha256:{digest_hex}, "
                f"content sha256:{actual_original_digest}"
            )

        compressed_digest, compressed_size = hash_file(temp_path)
        ratio = compressed_size / size if size else 0.0
        log(
            f"Recompressed oversized OCI blob sha256:{digest_hex}: "
            f"{size} -> {compressed_size} bytes ({ratio:.1%})"
        )
        if compressed_size > blob_limit_bytes:
            raise PublishError(
                f"recompressed layer sha256:{compressed_digest} is {compressed_size} bytes, "
                f"still exceeding the {blob_limit_bytes}-byte GHCR blob limit; "
                "the Dockerfile layer must be split in a future image build"
            )

        oras_blob_push_file(repository, compressed_digest, compressed_size, temp_path)
        return RecompressedBlob(
            original_digest=digest_hex,
            digest=compressed_digest,
            size=compressed_size,
            media_type=OCI_ZSTD_LAYER_MEDIA_TYPE,
        )
    finally:
        if compressor is not None and compressor.poll() is None:
            compressor.kill()
            compressor.wait()
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass


def oras_blob_push(
    repository: str,
    digest_hex: str,
    size: int,
    source: BinaryIO,
    blob_limit_bytes: int,
) -> tuple[bytes | None, RecompressedBlob | None]:
    if size > blob_limit_bytes:
        log(
            f"OCI blob sha256:{digest_hex} is {size} bytes, above the registry limit; "
            "stream-recompressing it with zstd before upload"
        )
        return None, recompress_oversized_blob(
            repository,
            digest_hex,
            size,
            source,
            blob_limit_bytes,
        )

    command = [
        "oras",
        "blob",
        "push",
        "--no-tty",
        "--size",
        str(size),
        f"{repository}@sha256:{digest_hex}",
        "-",
    ]
    log(f"Uploading OCI blob sha256:{digest_hex} ({size} bytes)")
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    if process.stdin is None:
        raise PublishError("failed to open ORAS stdin")

    digest = hashlib.sha256()
    remaining = size
    cache = bytearray() if size <= SMALL_BLOB_LIMIT else None
    pipe_open = True
    upload_error: Exception | None = None
    try:
        while remaining:
            chunk = source.read(min(CHUNK_SIZE, remaining))
            if not chunk:
                raise PublishError(
                    f"unexpected EOF inside blob sha256:{digest_hex}: {remaining} bytes still expected"
                )
            remaining -= len(chunk)
            digest.update(chunk)
            if cache is not None:
                cache.extend(chunk)
            if pipe_open:
                try:
                    process.stdin.write(chunk)
                except BrokenPipeError:
                    # ORAS may finish early when the content-addressed blob already exists.
                    # Keep consuming/hash-checking the tar member so archive parsing remains aligned.
                    pipe_open = False
    except Exception as exc:
        upload_error = exc
    finally:
        if not process.stdin.closed:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            return_code = process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            return_code = process.wait()
            if upload_error is None:
                upload_error = PublishError(f"ORAS did not terminate for sha256:{digest_hex}")

    if upload_error is not None:
        raise upload_error

    actual_digest = digest.hexdigest()
    if actual_digest != digest_hex:
        raise PublishError(f"OCI blob digest mismatch: filename sha256:{digest_hex}, content sha256:{actual_digest}")
    if return_code != 0:
        raise PublishError(f"ORAS blob upload failed for sha256:{digest_hex} (exit {return_code})")
    return (bytes(cache) if cache is not None else None), None


def normalize_tar_member_name(name: str) -> str:
    # We never extract paths to disk, but aliases such as ../index.json must not
    # be allowed to impersonate OCI metadata inside a malformed Release archive.
    if name.startswith("/"):
        raise PublishError(f"absolute tar member path is not allowed: {name}")
    if ".." in name.split("/"):
        raise PublishError(f"parent traversal tar member path is not allowed: {name}")
    normalized = posixpath.normpath(name)
    if normalized == ".." or normalized.startswith("../"):
        raise PublishError(f"parent traversal tar member path is not allowed: {name}")
    if normalized in ("", "."):
        raise PublishError(f"invalid tar member path: {name!r}")
    return normalized


def read_small_member(archive: tarfile.TarFile, member: tarfile.TarInfo, limit: int = SMALL_BLOB_LIMIT) -> bytes:
    if member.size > limit:
        raise PublishError(f"metadata member is unexpectedly large: {member.name} ({member.size} bytes)")
    source = archive.extractfile(member)
    if source is None:
        raise PublishError(f"cannot read tar member: {member.name}")
    data = source.read()
    if len(data) != member.size:
        raise PublishError(f"short read for tar member: {member.name}")
    return data


def choose_manifest(index: dict, small_blobs: dict[str, bytes]) -> tuple[dict, bytes]:
    descriptors = index.get("manifests")
    if not isinstance(descriptors, list) or not descriptors:
        raise PublishError("OCI index.json contains no manifests")

    candidates: list[dict] = []
    for descriptor in descriptors:
        if not isinstance(descriptor, dict):
            continue
        digest = str(descriptor.get("digest", ""))
        media_type = str(descriptor.get("mediaType", ""))
        if media_type in OCI_MANIFEST_MEDIA_TYPES and digest.startswith("sha256:") and digest[7:] in small_blobs:
            candidates.append(descriptor)

    if not candidates:
        raise PublishError("OCI index does not reference a readable image manifest")

    # Prefer the exact image name/tag exported by this repository.  If the OCI
    # index contains only one image, accept it even if Docker omitted annotations.
    preferred: list[dict] = []
    for descriptor in candidates:
        annotations = descriptor.get("annotations") or {}
        image_name = str(annotations.get("io.containerd.image.name", ""))
        ref_name = str(annotations.get("org.opencontainers.image.ref.name", ""))
        platform = descriptor.get("platform") or {}
        if (
            image_name.endswith("/imx8p-dev:20.04")
            or image_name == "imx8p-dev:20.04"
            or ref_name == "20.04"
            or (platform.get("os") == "linux" and platform.get("architecture") == "amd64")
        ):
            preferred.append(descriptor)

    selected_pool = preferred or candidates
    if len(selected_pool) != 1:
        digests = [str(item.get("digest")) for item in selected_pool]
        raise PublishError(f"cannot unambiguously select one image manifest from OCI index: {digests}")

    descriptor = selected_pool[0]
    digest_hex = str(descriptor["digest"])[7:]
    manifest_bytes = small_blobs[digest_hex]
    if hashlib.sha256(manifest_bytes).hexdigest() != digest_hex:
        raise PublishError("selected manifest content does not match its OCI digest")
    if descriptor.get("size") != len(manifest_bytes):
        raise PublishError("selected manifest size does not match index descriptor")
    return descriptor, manifest_bytes


def validate_manifest_references(manifest_bytes: bytes, seen_blobs: dict[str, int]) -> tuple[dict, str]:
    try:
        manifest = json.loads(manifest_bytes)
    except json.JSONDecodeError as exc:
        raise PublishError("selected image manifest is not valid JSON") from exc
    if manifest.get("schemaVersion") != 2:
        raise PublishError(f"unsupported image manifest schemaVersion: {manifest.get('schemaVersion')}")
    media_type = str(manifest.get("mediaType", ""))
    if media_type not in OCI_MANIFEST_MEDIA_TYPES:
        raise PublishError(f"unsupported image manifest media type: {media_type}")

    descriptors: list[dict] = []
    config = manifest.get("config")
    if not isinstance(config, dict):
        raise PublishError("image manifest has no config descriptor")
    descriptors.append(config)

    layers = manifest.get("layers")
    if not isinstance(layers, list):
        raise PublishError("image manifest has no layers array")
    if any(not isinstance(item, dict) for item in layers):
        raise PublishError("image manifest layers must all be descriptors")
    descriptors.extend(layers)

    for descriptor in descriptors:
        digest = str(descriptor.get("digest", ""))
        if not digest.startswith("sha256:") or not HEX64_RE.fullmatch(digest[7:]):
            raise PublishError(f"manifest contains an invalid blob digest: {digest!r}")
        digest_hex = digest[7:]
        if digest_hex not in seen_blobs:
            raise PublishError(f"manifest references a blob missing from the Release archive: {digest}")
        expected_size = descriptor.get("size")
        if not isinstance(expected_size, int) or expected_size != seen_blobs[digest_hex]:
            raise PublishError(f"manifest blob size mismatch for {digest}")
    return manifest, media_type


def rewrite_recompressed_layers(
    manifest: dict,
    small_blobs: dict[str, bytes],
    recompressed_blobs: dict[str, RecompressedBlob],
) -> dict:
    if not recompressed_blobs:
        return manifest

    manifest_media_type = str(manifest.get("mediaType", ""))
    if manifest_media_type != "application/vnd.oci.image.manifest.v1+json":
        raise PublishError(
            "zstd layer rewriting requires an OCI image manifest; "
            f"got {manifest_media_type!r}"
        )

    config = manifest.get("config")
    if not isinstance(config, dict):
        raise PublishError("image manifest has no config descriptor")
    config_digest = str(config.get("digest", ""))
    if not config_digest.startswith("sha256:") or config_digest[7:] not in small_blobs:
        raise PublishError("image config blob is not available for recompression validation")
    try:
        config_json = json.loads(small_blobs[config_digest[7:]])
    except json.JSONDecodeError as exc:
        raise PublishError("image config blob is not valid JSON") from exc

    layers = manifest.get("layers")
    if not isinstance(layers, list):
        raise PublishError("image manifest has no layers array")
    rootfs = config_json.get("rootfs")
    if not isinstance(rootfs, dict):
        raise PublishError("image config has no valid rootfs object")
    diff_ids = rootfs.get("diff_ids")
    if not isinstance(diff_ids, list) or len(diff_ids) != len(layers):
        raise PublishError("image config rootfs.diff_ids does not match manifest layer count")

    rewritten = json.loads(json.dumps(manifest))
    consumed: set[str] = set()
    for index, layer in enumerate(rewritten["layers"]):
        digest = str(layer.get("digest", ""))
        if not digest.startswith("sha256:"):
            continue
        old_digest = digest[7:]
        replacement = recompressed_blobs.get(old_digest)
        if replacement is None:
            continue

        media_type = str(layer.get("mediaType", ""))
        if media_type != OCI_UNCOMPRESSED_LAYER_MEDIA_TYPE:
            raise PublishError(
                f"oversized blob sha256:{old_digest} is referenced with unsupported layer media type "
                f"{media_type!r}; only uncompressed OCI tar layers can be safely recompressed"
            )
        expected_diff_id = f"sha256:{old_digest}"
        if diff_ids[index] != expected_diff_id:
            raise PublishError(
                f"image config diff_id mismatch for recompressed layer {index}: "
                f"expected {expected_diff_id}, got {diff_ids[index]!r}"
            )

        layer["mediaType"] = replacement.media_type
        layer["digest"] = f"sha256:{replacement.digest}"
        layer["size"] = replacement.size
        consumed.add(old_digest)

    unused = sorted(set(recompressed_blobs) - consumed)
    if unused:
        raise PublishError(
            "oversized OCI blobs were recompressed but are not uncompressed layers in the selected image manifest: "
            + ", ".join(f"sha256:{digest}" for digest in unused)
        )

    return rewritten


def serialize_manifest(manifest: dict) -> bytes:
    return json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode("utf-8")


def run_oras(command: list[str], input_bytes: bytes | None = None) -> str:
    completed = subprocess.run(command, input=input_bytes, stdout=subprocess.PIPE, text=False, check=False)
    if completed.returncode != 0:
        raise PublishError(f"command failed ({completed.returncode}): {' '.join(command)}")
    return completed.stdout.decode("utf-8", errors="strict").strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, help="GitHub repository in owner/name form")
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--image-repository", required=True, help="Registry repository, e.g. ghcr.io/owner/repo")
    parser.add_argument("--publish-latest", choices=("true", "false"), default="true")
    parser.add_argument("--github-api-base", default="https://api.github.com", help=argparse.SUPPRESS)
    parser.add_argument(
        "--blob-limit-bytes",
        type=int,
        default=GHCR_BLOB_LIMIT_BYTES,
        help=argparse.SUPPRESS,
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not RELEASE_TAG_RE.fullmatch(args.release_tag):
        raise PublishError(
            "release tag must match imx8p-dev-20.04-v<version>, for example imx8p-dev-20.04-v5.1"
        )
    if not args.image_repository.startswith("ghcr.io/"):
        raise PublishError("image repository must be under ghcr.io/")
    if args.blob_limit_bytes <= 0:
        raise PublishError("blob limit must be positive")

    token = os.environ.get("GITHUB_TOKEN")
    release = load_release(args.repository, args.release_tag, token, args.github_api_base)
    parts, checksum_asset = select_assets(release)
    expected_sha = expected_archive_sha(checksum_asset)
    log(f"Release: {args.release_tag}")
    log(f"Archive parts: {len(parts)}")
    log(f"Expected compressed archive SHA-256: {expected_sha}")

    zstd = subprocess.Popen(["zstd", "-dc", "--no-progress"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    if zstd.stdin is None or zstd.stdout is None:
        raise PublishError("failed to start zstd streaming decoder")

    feeder = ReleasePartFeeder(parts, zstd.stdin)
    feeder_thread = threading.Thread(target=feeder.run, name="release-part-feeder", daemon=True)
    feeder_thread.start()

    seen_blobs: dict[str, int] = {}
    small_blobs: dict[str, bytes] = {}
    recompressed_blobs: dict[str, RecompressedBlob] = {}
    small_blob_cache_bytes = 0
    index_bytes: bytes | None = None
    oci_layout_bytes: bytes | None = None

    stream_error: Exception | None = None
    try:
        with tarfile.open(fileobj=zstd.stdout, mode="r|") as archive:
            for member in archive:
                if not member.isfile():
                    continue
                normalized = normalize_tar_member_name(member.name)
                if normalized == "index.json":
                    if index_bytes is not None:
                        raise PublishError("duplicate index.json in Release archive")
                    index_bytes = read_small_member(archive, member)
                    continue
                if normalized == "oci-layout":
                    if oci_layout_bytes is not None:
                        raise PublishError("duplicate oci-layout in Release archive")
                    oci_layout_bytes = read_small_member(archive, member)
                    continue
                prefix = "blobs/sha256/"
                if normalized.startswith(prefix):
                    digest_hex = normalized[len(prefix) :]
                    if not HEX64_RE.fullmatch(digest_hex):
                        raise PublishError(f"invalid OCI blob path: {member.name}")
                    if digest_hex in seen_blobs:
                        raise PublishError(f"duplicate OCI blob in archive: sha256:{digest_hex}")
                    source = archive.extractfile(member)
                    if source is None:
                        raise PublishError(f"cannot read OCI blob: {member.name}")
                    cached, recompressed = oras_blob_push(
                        args.image_repository,
                        digest_hex,
                        member.size,
                        source,
                        args.blob_limit_bytes,
                    )
                    seen_blobs[digest_hex] = member.size
                    if recompressed is not None:
                        recompressed_blobs[digest_hex] = recompressed
                    if cached is not None:
                        small_blob_cache_bytes += len(cached)
                        if small_blob_cache_bytes > SMALL_BLOB_CACHE_TOTAL_LIMIT:
                            raise PublishError(
                                f"small OCI metadata/blob cache exceeds {SMALL_BLOB_CACHE_TOTAL_LIMIT} bytes"
                            )
                        small_blobs[digest_hex] = cached
                    continue
                # Docker's compatibility manifest/repositories files are not
                # required to reconstruct the OCI manifest in GHCR.  Consume
                # them without persisting anything large.
                source = archive.extractfile(member)
                if source is not None:
                    while source.read(CHUNK_SIZE):
                        pass

        # Drain any tar padding so zstd verifies the full compressed frame and
        # the feeder computes the hash across every split Release asset byte.
        while zstd.stdout.read(CHUNK_SIZE):
            pass
    except Exception as exc:
        stream_error = exc
        # A parser/registry error can otherwise leave the feeder blocked on the
        # decoder pipe.  Terminate the decoder first, which releases the feeder
        # with BrokenPipe instead of waiting until the Actions job timeout.
        try:
            zstd.stdout.close()
        except OSError:
            pass
        zstd.terminate()
    finally:
        feeder_thread.join(timeout=30)
        if feeder_thread.is_alive():
            zstd.kill()
            raise PublishError("Release asset feeder did not terminate after the stream was aborted")
        zstd_return = zstd.wait()

    if stream_error is not None:
        raise stream_error

    if feeder.error is not None:
        raise PublishError(f"Release asset streaming failed: {feeder.error}") from feeder.error
    if zstd_return != 0:
        raise PublishError(f"zstd decompression failed with exit code {zstd_return}")

    actual_sha = feeder.archive_hash.hexdigest()
    if actual_sha != expected_sha:
        raise PublishError(f"full .tar.zst SHA-256 mismatch: expected {expected_sha}, got {actual_sha}")
    log(f"Verified full compressed archive SHA-256: {actual_sha}")

    if oci_layout_bytes is None or index_bytes is None:
        raise PublishError(
            "Release archive is not an OCI-layout docker save archive; refusing a disk-heavy docker load fallback"
        )
    try:
        layout = json.loads(oci_layout_bytes)
        index = json.loads(index_bytes)
    except json.JSONDecodeError as exc:
        raise PublishError("OCI layout metadata is invalid JSON") from exc
    if layout.get("imageLayoutVersion") != "1.0.0":
        raise PublishError(f"unsupported OCI layout version: {layout.get('imageLayoutVersion')!r}")

    descriptor, original_manifest_bytes = choose_manifest(index, small_blobs)
    original_manifest, media_type = validate_manifest_references(original_manifest_bytes, seen_blobs)
    original_manifest_digest = f"sha256:{hashlib.sha256(original_manifest_bytes).hexdigest()}"
    if descriptor.get("digest") != original_manifest_digest:
        raise PublishError("selected manifest digest changed during validation")

    rewritten_manifest = rewrite_recompressed_layers(original_manifest, small_blobs, recompressed_blobs)
    if recompressed_blobs:
        manifest_bytes = serialize_manifest(rewritten_manifest)
        log(
            f"Rewrote {len(recompressed_blobs)} oversized uncompressed layer descriptor(s) "
            "to zstd-compressed OCI layers"
        )
    else:
        manifest_bytes = original_manifest_bytes
    manifest_digest = f"sha256:{hashlib.sha256(manifest_bytes).hexdigest()}"

    version_tag = args.release_tag.removeprefix("imx8p-dev-")
    tags = version_tag
    if args.publish_latest == "true":
        tags += ",latest"
    target = f"{args.image_repository}:{tags}"
    log(f"Publishing manifest {manifest_digest} as {target}")
    run_oras(["oras", "manifest", "push", "--media-type", media_type, target, "-"], input_bytes=manifest_bytes)

    for tag in tags.split(","):
        resolved = run_oras(["oras", "resolve", f"{args.image_repository}:{tag}"])
        if resolved != manifest_digest:
            raise PublishError(
                f"remote manifest verification failed for {tag}: expected {manifest_digest}, got {resolved}"
            )
        log(f"Verified GHCR tag {tag} -> {manifest_digest}")

    log("PASS: Release image published to GHCR without docker load or SDK rebuild.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PublishError as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
