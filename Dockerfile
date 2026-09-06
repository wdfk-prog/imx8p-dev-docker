# syntax=docker/dockerfile:1.7

# i.MX8P legacy development environment.
#
# The host may later be Ubuntu 24.04, but this image intentionally keeps the
# Ubuntu 20.04 userspace that has already been used with the NXP/FSL SDK.
FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive

ENV SDK_ROOT=/opt/fsl-imx-xwayland/6.1-mickledore \
    SDK_ENV=/opt/fsl-imx-xwayland/6.1-mickledore/environment-setup-armv8a-poky-linux \
    CMAKE_ROOT=/opt/cmake-3.20.6-linux-x86_64 \
    DEV_USER=embedsky

# Host-side build tools plus the small utilities needed by entrypoint.sh.
# passwd provides usermod/groupmod; util-linux provides setpriv.
# Keep Ubuntu's default APT sources; this project does not replace them.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bash-completion \
        build-essential \
        autoconf \
        automake \
        libtool \
        ca-certificates \
        chrpath \
        cmake \
        cpio \
        curl \
        diffstat \
        file \
        git \
        less \
        make \
        nano \
        ninja-build \
        openssh-client \
        sshpass \
        passwd \
        patch \
        pkg-config \
        python2 \
        python-is-python2 \
        python3 \
        python3-pexpect \
        python3-pip \
        python3-setuptools \
        rsync \
        tar \
        unzip \
        util-linux \
        wget \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Keep the fixed project CMake without baking the tar archive itself into a
# separate image layer. prepare-assets.sh creates this small build asset.
RUN --mount=type=bind,source=assets,target=/mnt/assets,ro \
    mkdir -p "$CMAKE_ROOT" \
    && tar --no-same-owner -xzf /mnt/assets/cmake-3.20.6-linux-x86_64.tar.gz -C "$CMAKE_ROOT" \
    && chmod -R a+rX "$CMAKE_ROOT" \
    && test -x "$CMAKE_ROOT/bin/cmake"

# The SDK is supplied as the Buildx named context "sdk" by build-image.sh.
#
# IMPORTANT PERMISSION POLICY:
#   - Keep the SDK owned by root inside the image.
#   - Make the WHOLE SDK readable by normal users.
#   - Make every directory traversable and preserve executable tools.
#
# a+rX means:
#   r = everyone may read files;
#   X = add execute only to directories or files that were already executable.
#
# Copy + chmod are deliberately in the SAME RUN layer. The SDK is about 25 GiB;
# copying it first and chmod'ing it in a later layer can create a very expensive
# extra layer. The bind mount from the named build context is temporary and is
# not stored in the final image.
RUN --mount=type=bind,from=sdk,source=/,target=/mnt/sdk,ro \
    mkdir -p "$SDK_ROOT" \
    && cp -a --no-preserve=ownership /mnt/sdk/. "$SDK_ROOT"/ \
    && chmod -R a+rX "$SDK_ROOT" \
    && test -r "$SDK_ENV" \
    && test -x "$SDK_ROOT/sysroots/x86_64-pokysdk-linux/usr/bin/aarch64-poky-linux/aarch64-poky-linux-gcc"

# Thrift code generation is a HOST-side x86-64 build dependency. Install it
# AFTER the expensive SDK layer so an existing v4 BuildKit cache can reuse the
# ~25 GiB SDK copy/permission layer when only this dependency is added.
# The ARM64 target runtime/header still come exclusively from the Yocto SDK; do
# not install Ubuntu's host libthrift-dev for the UTrack target link.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        thrift-compiler \
        openssh-client \
        sshpass \
    && rm -rf /var/lib/apt/lists/*

# The image contains a stable account name, but its numeric UID/GID is only a
# placeholder. entrypoint.sh changes the numeric IDs at CONTAINER START so the
# same image can be moved to another Ubuntu host without rebuilding it merely
# because that host uses UID/GID 1001 instead of 1000.
RUN groupadd --gid 1000 "$DEV_USER" \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash "$DEV_USER" \
    && mkdir -p /workspace \
    && chmod 1777 /workspace

COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/imx8p-entrypoint
COPY --chmod=755 scripts/verify-env.sh /usr/local/bin/verify-imx8p-env
COPY --chmod=755 scripts/check-sdk-permissions.sh /usr/local/bin/check-imx8p-sdk-permissions

WORKDIR /workspace

# ENTRYPOINT starts as root only long enough to map UID/GID and activate the SDK.
# It then drops privileges before running bash/build commands.
ENTRYPOINT ["/usr/local/bin/imx8p-entrypoint"]
CMD ["/bin/bash"]
