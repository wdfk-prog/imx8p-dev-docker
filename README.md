# i.MX8P Docker 开发环境 v5.1

这套文件用于把已经验证过的 **Ubuntu 20.04 + NXP/FSL i.MX8P Yocto SDK + CMake 3.20.6** 固化为可迁移的 Docker 开发环境，并在 Ubuntu 20.04/24.04 x86-64 Host 上保持相同的容器用户态和交叉编译工具链。

v5.1 重点解决这些已经实际遇到的问题：

1. **整个 SDK 权限正规化**：不再逐个修 Thrift/SSL/其他库权限。
2. **bind mount UID/GID 自动匹配宿主机**：容器生成的 build 文件保持宿主用户 ownership。
3. **host Thrift compiler 固化为 `/usr/bin/thrift` 0.13.0**，target header/library 继续来自 Yocto SDK。
4. **UTrack CC/CXX 环境正规化**：保留 Yocto sysroot/PATH，去掉与 UTrack `-O0/-Wno-format` 冲突的 Yocto policy flags。
5. **镜像 build 后自动执行强环境门禁**：包含 C/C++、target `libthrift.a`、Thrift code generation 和 CMake 集成 smoke。
6. **离线导入/导出不再落地完整临时 TAR**：降低 27 GiB 大镜像的磁盘峰值。
7. **支持 `.tar.zst` 快速分发**，同时保留 `.tar.gz` 兼容路径和 SHA256 校验。
8. **补充 Ubuntu 24.04 / Docker containerd image store 的磁盘规划说明**。
9. **UTrack 配置命令统一显式传入 `-DTHRIFT_COMPILER=/usr/bin/thrift`**，不再依赖项目自身的自动发现行为。
10. **`.dockerignore` 排除 workspace 和离线镜像包**，避免几十 GiB 无关文件进入 BuildKit context。
11. **GitHub Release 分片分发**：大镜像不进入 Git 历史，通过 Release Assets 上传/下载，使用 SHA256 与 zstd 双重校验后再导入。

> 本项目不修改 Ubuntu APT 软件源，基础镜像仍为 `ubuntu:20.04`。


[![Lightweight CI](https://github.com/wdfk-prog/imx8p-dev-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/wdfk-prog/imx8p-dev-docker/actions/workflows/ci.yml)
[![Documentation](https://github.com/wdfk-prog/imx8p-dev-docker/actions/workflows/pages-doxygen.yml/badge.svg)](https://github.com/wdfk-prog/imx8p-dev-docker/actions/workflows/pages-doxygen.yml)
[![GHCR Image](https://github.com/wdfk-prog/imx8p-dev-docker/actions/workflows/publish-image.yml/badge.svg)](https://github.com/wdfk-prog/imx8p-dev-docker/actions/workflows/publish-image.yml)

## GitHub CI/CD 与在线文档

本仓库把自动化拆成三个独立边界：源码静态检查、在线文档，以及已经构建完成的 Release 镜像发布。完整镜像构建仍然在拥有 NXP/FSL SDK 的开发机上完成；**GHCR 发布不会重新构建 SDK 镜像**，而是直接复用 GitHub Release 中已经上传的分片镜像。

```text
push / pull_request to master
        |
        +--> GitHub-hosted runner
        |       |
        |       +--> sh -n
        |       +--> ShellCheck
        |       +--> docker compose config
        |       +--> Doxygen -> GitHub Pages
        |
Published Release / manual existing Release
        |
        +--> GitHub-hosted runner
                |
                +--> stream split .tar.zst assets
                +--> verify Release asset SHA-256
                +--> verify full archive SHA-256
                +--> stream OCI blobs -> GHCR
                +--> publish OCI manifest/tag
```

### 轻量 CI

`.github/workflows/ci.yml` 在 `master` 的 push、pull request 和手工运行时执行。它只做不依赖 SDK 的快速检查，因此适合普通 GitHub-hosted runner：

- POSIX `sh -n` 语法检查；
- ShellCheck 静态检查；
- Release-to-GHCR Python 发布器语法/CLI 入口检查；
- `docker compose config --quiet` 配置检查。

它**不会**声称完整 Docker 镜像或 UTrack 工程已经构建成功。完整镜像验证仍以制作 Release 镜像时 `build-image.sh` 最后执行的 `verify-imx8p-env` 为准。

### MkDocs + GitHub Pages

`mkdocs.yml` 组织 `docs/` 下的手写文档，`.github/workflows/pages-doxygen.yml` 使用 MkDocs Material 构建 `site/` 并部署到 GitHub Pages。

本仓库主要是 Docker、Shell 和 Markdown，没有需要单独发布的 C/C++ API Reference，因此 Pages 只使用 MkDocs，不再维护 Doxygen 文档门户。

首次使用时，在 GitHub 仓库中设置：

```text
Settings
-> Pages
-> Build and deployment
-> Source
-> GitHub Actions
```

成功部署后，站点地址为：

```text
https://wdfk-prog.github.io/imx8p-dev-docker/
```

### GHCR：直接发布已经存在的 Release 镜像

`.github/workflows/publish-image.yml` 不再访问 NXP/FSL SDK，也不再运行 `docker build` / `docker load`。Release Assets 本身就是已经构建好的 `imx8p-dev:20.04` Docker 镜像，因此 GHCR 阶段只负责把**同一份镜像内容**从 Release 搬运到 Container Registry。

工作流支持两种入口：

1. 发布新的正式 GitHub Release 时，通过 `release.published` 自动执行；
2. 对已经存在的 Release，通过 `Actions -> Publish i.MX8P Release Image to GHCR -> Run workflow` 手工输入 Release Tag 再次执行。

因此，早于工作流创建的 v5.1 可以直接手工发布，不需要创建 v5.2：

```text
release_tag:    imx8p-dev-20.04-v5.1
publish_latest: true
```

成功后发布：

```text
ghcr.io/wdfk-prog/imx8p-dev-docker:20.04-v5.1
ghcr.io/wdfk-prog/imx8p-dev-docker:latest
```

标准 GitHub-hosted `ubuntu-latest` 的磁盘不足以安全执行这个约 27 GiB 镜像的 `docker load`。因此发布器使用 ORAS 直接处理 containerd/Docker 导出的 OCI layout：逐个读取 `blobs/sha256/*` 并流式上传，不在 runner 上落地完整 `.tar.zst`、完整 TAR 或 Docker image store。

在写入最终 GHCR tag 之前，发布器会依次验证：

- GitHub Release API 给出的每个分片 SHA-256；
- `.tar.zst.sha256` sidecar 自身的 Release Asset SHA-256；
- 所有分片拼接后的完整 `.tar.zst` SHA-256；
- OCI `blobs/sha256/*` 的内容摘要和大小；
- `index.json` 选择出的 image manifest 以及其 config/layer 引用。

只有这些检查全部通过，最后才写入 `20.04-vX.Y` / `latest` manifest tag。中途失败时可能已经存在未引用的内容寻址 blob，但不会把半成品发布成可拉取的正式 tag。

> 当前发布器要求 Release 中的 `docker save` 包包含 OCI layout（`oci-layout`、`index.json`、`blobs/sha256/*`）。如果遇到传统 legacy docker-archive，它会明确失败，而不会退回到占用几十 GiB 磁盘的 `docker load`。

### GHCR 大镜像限制

GHCR 可以保存 Docker/OCI 镜像，但 GitHub 当前明确限制：

- **单个 image layer 最大 10 GB**；
- **单个 layer 上传最长 10 分钟**。

因此“镜像总计约 27 GB”并不等于一定无法发布。v5.1 的实际 Release 已确认包含一个约 26.4 GB 的**未压缩 OCI layer**，不能原样提交给 GHCR。发布器遇到这种超限且最终被 image manifest 证明为 `application/vnd.oci.image.layer.v1.tar` 的 layer 时，会在 GitHub-hosted runner 上**流式 zstd 重压缩**，只临时落地压缩后的单层文件，然后上传新的内容寻址 blob，并把最终 image manifest 中该 layer 的 `mediaType` / `digest` / `size` 改写为 zstd 版本。

这个转换不会重新构建 SDK，也不会改变容器解压后的文件系统内容；image config 中的 `rootfs.diff_ids` 仍指向原始未压缩 layer digest。发布器会显式校验这一关系后才写最终 GHCR tag。如果重压缩后的单层仍超过 10 GB，或者 Release 中超限 blob 并不是未压缩 OCI tar layer，工作流会 fail-closed，此时下一版镜像才需要从 Dockerfile 层面拆分 SDK。

GitHub 官方说明：

- [Working with the Container registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [Docker image push](https://docs.docker.com/reference/cli/docker/image/push/)

## 0. 快速开始：从 GitHub Release 下载并导入现成镜像

如果目标只是恢复已经制作好的 `imx8p-dev:20.04`，**优先从 GitHub Release 下载现成镜像，不需要重新执行第 3 节的镜像构建流程**。

当前 v5.1 Release：

- Repository: `wdfk-prog/imx8p-dev-docker`
- Tag: `imx8p-dev-20.04-v5.1`
- Release: [i.MX8P Dev Docker 20.04 v5.1](https://github.com/wdfk-prog/imx8p-dev-docker/releases/tag/imx8p-dev-20.04-v5.1)

当前 Release 已发布以下 5 个 Assets：

```text
imx8p-dev-20.04.tar.zst.part-00
imx8p-dev-20.04.tar.zst.part-01
imx8p-dev-20.04.tar.zst.part-02
imx8p-dev-20.04.tar.zst.part-03
imx8p-dev-20.04.tar.zst.sha256
```

镜像被拆分为多个 Release Assets，是因为大镜像不适合进入普通 Git 历史。恢复时需要下载全部分片，然后按顺序合并回完整 `.tar.zst`。

### 0.1 安装下载工具并检查环境

Ubuntu Host 安装 `gh` 和 `zstd`：

```sh
sudo apt update
sudo apt install -y gh zstd
```

确认 Docker、GitHub CLI 和磁盘空间：

```sh
docker version
gh --version
docker system df
df -h /
```

如果 `gh` 尚未登录：

```sh
gh auth login
```

仓库是公开仓库，也可以直接在浏览器打开 Release 页面手工下载全部 5 个 Assets；命令行恢复推荐使用 `gh release download`。

### 0.2 从 GitHub Release 下载全部镜像分片

进入项目：

```sh
cd /home/wdfk/share/imx8p-dev-docker
```

定义当前 Release：

```sh
REPO=wdfk-prog/imx8p-dev-docker
RELEASE_TAG=imx8p-dev-20.04-v5.1
RELEASE_DIR="$PWD/docker-images/$RELEASE_TAG"
mkdir -p "$RELEASE_DIR"
```

下载该 Release 的全部 Assets：

```sh
gh release download "$RELEASE_TAG" \
    -R "$REPO" \
    -D "$RELEASE_DIR"
```

检查：

```sh
ls -lh "$RELEASE_DIR"
```

应至少看到：

```text
imx8p-dev-20.04.tar.zst.part-00
imx8p-dev-20.04.tar.zst.part-01
imx8p-dev-20.04.tar.zst.part-02
imx8p-dev-20.04.tar.zst.part-03
imx8p-dev-20.04.tar.zst.sha256
```

如果目录中已有同名 Asset，需要重新下载时可显式覆盖：

```sh
gh release download "$RELEASE_TAG" \
    -R "$REPO" \
    -D "$RELEASE_DIR" \
    --clobber
```

### 0.3 合并分片并校验完整镜像

按文件名顺序合并：

```sh
cat "$RELEASE_DIR"/imx8p-dev-20.04.tar.zst.part-* \
    > "$RELEASE_DIR"/imx8p-dev-20.04.tar.zst
```

先校验 SHA256：

```sh
cd "$RELEASE_DIR"
sha256sum -c imx8p-dev-20.04.tar.zst.sha256
```

预期：

```text
imx8p-dev-20.04.tar.zst: OK
```

再校验 zstd 数据完整性：

```sh
zstd -t imx8p-dev-20.04.tar.zst
```

只有 SHA256 和 zstd 校验都通过后，才继续导入 Docker。

> 合并阶段会同时存在分片和完整 `.tar.zst`，本地磁盘会临时多占约一个完整压缩包的空间。校验通过后，如果不再需要保留分片，可以删除 `part-*` 以回收空间。

### 0.4 导入 Docker 镜像

回到项目目录：

```sh
cd /home/wdfk/share/imx8p-dev-docker
```

优先使用项目导入脚本：

```sh
./scripts/import-image.sh \
    "$RELEASE_DIR/imx8p-dev-20.04.tar.zst"
```

脚本会读取同目录的：

```text
imx8p-dev-20.04.tar.zst.sha256
```

执行 SHA256 校验、Docker storage 空间检查以及 `docker load`，不会先在 `/tmp` 解出完整 TAR。

如果只有镜像包而没有项目脚本，也可以直接：

```sh
docker load -i "$RELEASE_DIR/imx8p-dev-20.04.tar.zst"
```

### 0.5 确认镜像已经可用

```sh
docker images imx8p-dev
docker image inspect imx8p-dev:20.04 >/dev/null && \
    echo 'PASS: imx8p-dev:20.04 is available'
```

预期至少能够看到：

```text
imx8p-dev:20.04
```

导入完成后，可以直接跳到 [第 4 节：进入开发容器](#4-进入开发容器)。

### 0.6 已经有本地 `.tar.zst` 时

如果已经存在完整文件：

```text
/home/wdfk/share/imx8p-dev-docker/imx8p-dev-20.04.tar.zst
```

则不需要 GitHub 下载和分片合并，直接执行：

```sh
cd /home/wdfk/share/imx8p-dev-docker
zstd -t ./imx8p-dev-20.04.tar.zst
./scripts/import-image.sh ./imx8p-dev-20.04.tar.zst
```

如果同目录存在 `imx8p-dev-20.04.tar.zst.sha256`，导入脚本会自动执行 SHA256 校验。

## 1. 目录和职责

```text
imx8p-dev-docker/
├── .github/
│   └── workflows/
│       ├── ci.yml
│       ├── pages-doxygen.yml
│       └── publish-image.yml
├── Dockerfile
├── compose.yaml
├── mkdocs.yml
├── requirements-docs.txt
├── README.md
├── .dockerignore
├── .gitignore
├── assets/
│   └── README.md
├── docker/
│   └── entrypoint.sh
├── docs/
│   ├── index.md
│   ├── offline-image-migration.md
│   ├── permissions-and-migration.md
│   └── toolchain-and-thrift.md
├── scripts/
│   ├── prepare-assets.sh
│   ├── build-image.sh
│   ├── dev.sh
│   ├── verify-env.sh
│   ├── check-sdk-permissions.sh
│   ├── export-image.sh
│   └── import-image.sh
└── workspace/
    └── .gitkeep
```

GitHub Release 中的大镜像属于发布产物，不属于 Git 源码树。仓库现有 `.gitignore` 已忽略 `docker-images/`，因此新的导出、分片和下载文件统一放在该目录下。

当前 v5.1 Release Assets 为：

```text
imx8p-dev-20.04.tar.zst.part-00
imx8p-dev-20.04.tar.zst.part-01
imx8p-dev-20.04.tar.zst.part-02
imx8p-dev-20.04.tar.zst.part-03
imx8p-dev-20.04.tar.zst.sha256
```

本地发布产物建议统一放在：

```text
docker-images/
└── <release-tag>/
    ├── imx8p-dev-20.04.tar.zst
    ├── imx8p-dev-20.04.tar.zst.sha256
    └── imx8p-dev-20.04.tar.zst.part-*
```

`docker-images/` 已被当前仓库 `.gitignore` 忽略，不要把其中的大文件强制 `git add -f` 到仓库。

运行关系：

```text
Host UTrack 源码
      │
      │ bind mount
      ▼
Container /workspace
      │
      ├─ Ubuntu 20.04 userspace
      ├─ /usr/bin/thrift                  # x86-64 host generator
      ├─ /opt/cmake-3.20.6-linux-x86_64
      └─ /opt/fsl-imx-xwayland/6.1-mickledore
            ├─ AArch64 cross toolchain
            ├─ target Thrift headers
            └─ ARM64 libthrift.a
```

源码始终保存在宿主机。删除容器不会删除 bind-mounted Git 源码。

## 2. 关键设计

### 2.1 Thrift 分 host 和 target

`/usr/bin/thrift` 运行在 x86-64 容器中，只负责：

```text
*.thrift → *.cpp / *.h
```

最终链接进 AArch64 UTrack 的 header/library 来自：

```text
/opt/fsl-imx-xwayland/6.1-mickledore/sysroots/armv8a-poky-linux/
```

因此 Dockerfile 安装 `thrift-compiler`，但不安装 Ubuntu host `libthrift-dev`。

### 2.2 为什么重写 CC/CXX

Yocto `environment-setup-armv8a-poky-linux` 必须 source，因为 PATH、sysroot、pkg-config、OECORE 等来自它。

但它还会把 Yocto 自己的编译 policy 写进 CC/CXX/flags，例如已经观察到：

```text
-O2
-D_FORTIFY_SOURCE=2
-Wformat
-Wformat-security
-Werror=format-security
```

UTrack 自己使用：

```text
-O0
-Wno-format
```

两套 policy 叠加已经产生过 `-Werror=format-security` 和 `_FORTIFY_SOURCE` 冲突。因此 entrypoint source SDK 后固定：

```text
CC  = aarch64-poky-linux-gcc --sysroot=<target sysroot>
CXX = aarch64-poky-linux-g++ --sysroot=<target sysroot>
```

并清空：

```text
CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
```

详细说明见 [docs/toolchain-and-thrift.md](docs/toolchain-and-thrift.md)。

### 2.3 为什么 SDK 和源码使用两种权限策略

SDK 属于镜像内部文件：

```text
root 拥有
普通开发用户可读
目录可 traverse
原本可执行的工具继续可执行
```

因此 Dockerfile 对整个 SDK 使用：

```sh
chmod -R a+rX /opt/fsl-imx-xwayland/6.1-mickledore
```

源码是 bind mount，ownership 由宿主 UID/GID 决定。`dev.sh` 每次读取宿主 UID/GID，entrypoint 在容器启动时映射 `embedsky` 的数字 UID/GID，然后以普通用户运行构建。

详细说明见 [docs/permissions-and-migration.md](docs/permissions-and-migration.md)。

## 3. 第一次制作镜像

进入项目：

```sh
cd ~/share/imx8p-dev-docker
```

### 3.1 准备构建资产

```sh
./scripts/prepare-assets.sh
```

默认检查：

```text
SDK:   /opt/fsl-imx-xwayland/6.1-mickledore
CMake: $HOME/share/cmake-3.20.6-linux-x86_64
```

如果 CMake 目录不同：

```sh
CMAKE_SOURCE_DIR=/实际路径/cmake-3.20.6-linux-x86_64 \
./scripts/prepare-assets.sh
```

该脚本只把固定 CMake 目录做成小型 build asset。约 25 GiB NXP/FSL SDK **不会**打成 tar.gz，而是由 `build-image.sh` 直接作为 Buildx named context `sdk` 传入。

### 3.2 构建镜像

```sh
./scripts/build-image.sh
```

首次处理约 25 GiB SDK 时间较长是正常现象。

构建结束后脚本会自动运行：

```text
verify-imx8p-env
```

期望最终看到：

```text
PASS: i.MX8P Docker development environment is UTrack-ready.
```

该 PASS 对应的是镜像级环境门禁，不等于真实 UTrack 工程已经完整编译通过。

## 4. 进入开发容器

假设源码：

```text
~/share/ultra-embeddedcodetrack/Ultra_Linux
```

执行：

```sh
./scripts/dev.sh ~/share/ultra-embeddedcodetrack/Ultra_Linux
```

启动输出中的 Workspace 应该指向真实源码，而不是默认的：

```text
.../imx8p-dev-docker/workspace
```

进入后检查：

```sh
whoami
id
pwd
cmake --version
thrift -version
printf 'CC=%s\n' "$CC"
printf 'CXX=%s\n' "$CXX"
```

核心预期：

```text
pwd = /workspace
cmake version 3.20.6
Thrift version 0.13.0
CC  = aarch64-poky-linux-gcc --sysroot=/opt/.../armv8a-poky-linux
CXX = aarch64-poky-linux-g++ --sysroot=/opt/.../armv8a-poky-linux
```

## 5. 第一次构建 UTrack

跨镜像版本或跨主机迁移后，先删除旧 CMake cache：

```sh
cd /workspace
rm -rf build
```

配置时**显式传入 host Thrift compiler**：

```sh
cmake -S /workspace \
      -B /workspace/build \
      -DP=UTrack \
      -DTHRIFT_COMPILER=/usr/bin/thrift
```

这里显式 `-DTHRIFT_COMPILER` 是当前 UTrack 的稳定迁移契约。镜像保证 `/usr/bin/thrift` 存在，但不再假设项目自己的 CMake 一定能在所有旧 cache/逻辑下自动发现它。

检查：

```sh
grep '^THRIFT_COMPILER:' /workspace/build/CMakeCache.txt
```

然后编译：

```sh
cmake --build /workspace/build -j4
```

工程级最终验收仍然是：

```text
[100%] Built target UTrack
```

## 6. 镜像导出、GitHub Release 上传与导入

本项目把 Git 仓库和大体积 Docker 镜像分开管理：

```text
Git repository
├── Dockerfile / compose.yaml
├── scripts/
├── docs/
└── README.md

GitHub Release Assets
├── imx8p-dev-20.04.tar.zst.part-00
├── imx8p-dev-20.04.tar.zst.part-01
├── imx8p-dev-20.04.tar.zst.part-02
├── imx8p-dev-20.04.tar.zst.part-03
└── imx8p-dev-20.04.tar.zst.sha256
```

不要把完整镜像或 `part-*` 分片提交进 Git 历史。

### 6.1 导出本地镜像

进入项目：

```sh
cd /home/wdfk/share/imx8p-dev-docker
mkdir -p ./docker-images/imx8p-dev-20.04-v5.1
```

大镜像推荐 zstd：

```sh
sudo apt install -y zstd
./scripts/export-image.sh \
    ./docker-images/imx8p-dev-20.04-v5.1/imx8p-dev-20.04.tar.zst
```

脚本会生成：

```text
docker-images/imx8p-dev-20.04-v5.1/imx8p-dev-20.04.tar.zst
docker-images/imx8p-dev-20.04-v5.1/imx8p-dev-20.04.tar.zst.sha256
```

当前实现采用流式 `docker save` + zstd，不额外落地完整约 27 GiB 临时 TAR。

导出完成后建议立即验证：

```sh
cd ./docker-images/imx8p-dev-20.04-v5.1
sha256sum -c ./imx8p-dev-20.04.tar.zst.sha256
zstd -t ./imx8p-dev-20.04.tar.zst
```

### 6.2 为 GitHub Release 生成分片

GitHub Release 使用小于 2 GiB 的单个 Asset。当前项目采用 `1900M` 分片，给上限保留余量：

```sh
cd /home/wdfk/share/imx8p-dev-docker/docker-images/imx8p-dev-20.04-v5.1
rm -f ./imx8p-dev-20.04.tar.zst.part-*

split -b 1900M -d -a 2 \
    ./imx8p-dev-20.04.tar.zst \
    ./imx8p-dev-20.04.tar.zst.part-
```

检查文件：

```sh
ls -lh ./imx8p-dev-20.04.tar.zst.part-* \
       ./imx8p-dev-20.04.tar.zst.sha256
```

当前 v5.1 对应 4 个分片：

```text
imx8p-dev-20.04.tar.zst.part-00
imx8p-dev-20.04.tar.zst.part-01
imx8p-dev-20.04.tar.zst.part-02
imx8p-dev-20.04.tar.zst.part-03
```

上传前可以回到仓库根目录检查 Git 状态：

```sh
cd /home/wdfk/share/imx8p-dev-docker
git status --short
```

`docker-images/` 已由当前仓库 `.gitignore` 忽略，因此正常情况下这些 Release Assets 不会出现在待提交列表中。仍然不要使用 `git add -f docker-images/...` 强制把大镜像加入 Git 历史。

### 6.3 首次创建新版本 Release 并上传 Assets

先确认 GitHub CLI：

```sh
gh --version
gh auth status
```

尚未登录时：

```sh
gh auth login
```

定义仓库和版本：

```sh
REPO=wdfk-prog/imx8p-dev-docker
RELEASE_TAG=imx8p-dev-20.04-v5.1
```

对于一个**新的版本 tag**，先确保需要发布的源码/文档已经正常提交和 push，然后创建 annotated tag：

```sh
git status
git log -1 --oneline

git tag -a "$RELEASE_TAG" \
    -m "i.MX8P Docker development environment v5.1"

git push origin "$RELEASE_TAG"
```

> `imx8p-dev-20.04-v5.1` 已经存在时不要重复执行上面的 `git tag`。后续镜像有实质变化时，推荐创建新的版本，例如 `v5.2`，而不是静默覆盖已经发布的 v5.1。

创建 Release，并一次上传所有分片和 SHA256：

```sh
cd /home/wdfk/share/imx8p-dev-docker

gh release create "$RELEASE_TAG" \
    ./docker-images/$RELEASE_TAG/imx8p-dev-20.04.tar.zst.part-* \
    ./docker-images/$RELEASE_TAG/imx8p-dev-20.04.tar.zst.sha256 \
    -R "$REPO" \
    --verify-tag \
    --title "i.MX8P Dev Docker 20.04 v5.1" \
    --notes "Prebuilt Ubuntu 20.04 i.MX8P development Docker image. Download all part files, concatenate them in order, verify SHA256, then import the image with docker load."
```

`--verify-tag` 会要求远端 GitHub 上已经存在该 tag，避免 Release 错误绑定到未确认的 revision。

发布完成后检查：

```sh
gh release view "$RELEASE_TAG" -R "$REPO"
gh release view "$RELEASE_TAG" -R "$REPO" --web
```

### 6.4 向已经存在的 Release 补充或替换 Asset

如果 Release 已经存在，只是漏传了一个文件：

```sh
gh release upload "$RELEASE_TAG" \
    ./docker-images/$RELEASE_TAG/imx8p-dev-20.04.tar.zst.part-03 \
    -R "$REPO"
```

如果同名 Asset 已经存在，普通 `gh release upload` 会拒绝覆盖。只有明确确认远端文件需要被替换时才使用：

```sh
gh release upload "$RELEASE_TAG" \
    ./docker-images/$RELEASE_TAG/imx8p-dev-20.04.tar.zst.part-* \
    ./docker-images/$RELEASE_TAG/imx8p-dev-20.04.tar.zst.sha256 \
    -R "$REPO" \
    --clobber
```

`--clobber` 会先删除同名远端 Asset 再重新上传；上传中途失败时原 Asset 可能已经不存在，因此正常版本迭代优先发布新 tag，而不是覆盖旧 Release。

### 6.5 从 GitHub Release 下载

完整恢复流程见 [第 0 节](#0-快速开始从-github-release-下载并导入现成镜像)。最简下载命令为：

```sh
gh release download imx8p-dev-20.04-v5.1 \
    -R wdfk-prog/imx8p-dev-docker \
    -D ./docker-images/imx8p-dev-20.04-v5.1
```

然后合并：

```sh
cat ./docker-images/imx8p-dev-20.04-v5.1/imx8p-dev-20.04.tar.zst.part-* \
    > ./docker-images/imx8p-dev-20.04-v5.1/imx8p-dev-20.04.tar.zst
```

校验：

```sh
cd ./docker-images/imx8p-dev-20.04-v5.1
sha256sum -c imx8p-dev-20.04.tar.zst.sha256
zstd -t imx8p-dev-20.04.tar.zst
```

### 6.6 导入本地镜像包

完整项目目录存在时：

```sh
./scripts/import-image.sh /path/to/imx8p-dev-20.04.tar.zst
```

导入脚本会：

- 自动检查同目录 `.sha256`；
- 直接让 `docker load` 读取压缩 archive；
- 不在 `/tmp` 解出完整临时 TAR；
- 检查 containerd image store 并显示存储文件系统空间；
- 在 containerd store 可用空间低于约 60 GiB 时给出警告；
- 导入后确认 `imx8p-dev:20.04` 实际存在。

Ubuntu 24.04 / VMware Shared Folder / Docker 29 containerd 磁盘占用详见：

[docs/offline-image-migration.md](docs/offline-image-migration.md)

### 6.7 从 GHCR 拉取在线镜像

当 `Publish i.MX8P Release Image to GHCR` 工作流成功发布后，也可以直接从 GitHub Container Registry 获取镜像，而不需要手工下载和拼接 Release 分片。

版本 Tag 与 GHCR Tag 的映射规则为：

```text
Release:  imx8p-dev-20.04-v5.1
GHCR:     ghcr.io/wdfk-prog/imx8p-dev-docker:20.04-v5.1
also:     ghcr.io/wdfk-prog/imx8p-dev-docker:latest
```

如果 package 保持 Private，先登录：

```sh
printf '%s' "$CR_PAT" | docker login ghcr.io -u USERNAME --password-stdin
```

然后拉取：

```sh
docker pull ghcr.io/wdfk-prog/imx8p-dev-docker:20.04-v5.1
```

如果在 GitHub Packages 设置中把 package 改为 Public，公共镜像可匿名拉取。GitHub 第一次发布 Container package 时默认可见性是 Private，因此不要因为仓库本身是 Public 就假设 package 自动公开。

对于这个项目，建议长期保留两条分发路径：

```text
GHCR
└── 适合网络条件良好的在线 docker pull

GitHub Release Assets
└── 适合离线迁移、可分片下载、SHA256 + zstd 双重校验
```

GHCR 发布器会先把超过 10 GB 的未压缩 OCI layer 流式重压缩为 zstd layer；如果压缩后仍超过限制或单层上传超时，Release Assets 仍然是当前已经验证过的分发方案，不影响开发环境继续使用。

## 7. Ubuntu 24.04 Host 注意事项

容器仍然是：

```text
Ubuntu 20.04 userspace
```

Host 可以是 Ubuntu 24.04 x86-64，只要 Docker Engine/Compose 正常。

一次实际迁移中，Docker 使用：

```text
[[driver-type io.containerd.snapshotter.v1]]
```

该环境的 `imx8p-dev:20.04` 显示：

```text
CONTENT SIZE : 27.1GB
DISK USAGE   : 54.7GB
/var/lib/containerd : 51G
```

这不是 27 GiB 临时 TAR 没删掉。Docker 官方说明 containerd image store 会同时保存 compressed image content 与 unpacked snapshot，因此大镜像需要明显更多磁盘。

对于当前镜像，建议：

```text
导入前 Docker storage 空闲：>= 60 GiB
Ubuntu 24 开发 VM 磁盘：   120~150 GiB
```

不要手工 `rm -rf /var/lib/containerd/*`。

## 8. 常用命令

进入源码：

```sh
./scripts/dev.sh /你的源码目录
```

快速镜像环境门禁：

```sh
verify-imx8p-env
```

完整 SDK 权限扫描（遍历约 25 GiB，不必每天运行）：

```sh
check-imx8p-sdk-permissions
```

Docker 存储状态：

```sh
docker info -f '{{ .DriverStatus }}'
docker system df -v
df -h /
```

GitHub Release：

```sh
gh release view imx8p-dev-20.04-v5.1 -R wdfk-prog/imx8p-dev-docker
gh release view imx8p-dev-20.04-v5.1 -R wdfk-prog/imx8p-dev-docker --web
```

## 9. 不要再使用这些历史临时修复

正常 v5.1 不需要：

```sh
export LIBRARY_PATH=/tmp/utrack-thrift-lib
export CC='...'
export CXX='...'
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
sudo chmod -R 777 ~/share
sudo chown -R 1000:1000 ~/share
```

也不需要在运行中的容器临时：

```sh
apt-get install thrift-compiler
```

这些行为应该由 Dockerfile/entrypoint 固化。

唯一保留为工程配置参数的是：

```text
-DTHRIFT_COMPILER=/usr/bin/thrift
```

它是 UTrack CMake 配置参数，不是对容器环境的临时修补。

## 10. 验证边界

本项目可进行：

- Shell 语法和失败路径检查；
- deterministic CMake asset 检查；
- 导入/导出脚本 fixture smoke；
- 文档本地链接检查；
- 完整 diff 静态审查。

但完整 Docker build / UTrack build 依赖真实环境：

- Docker daemon / Buildx / Compose；
- 约 25 GiB NXP/FSL SDK；
- CMake 3.20.6 source asset；
- 真实 UTrack 源码。

因此最终保留两层验收：

```text
镜像级：PASS: i.MX8P Docker development environment is UTrack-ready.
工程级：[100%] Built target UTrack
```


GitHub 自动化对应这两个边界：

```text
GitHub-hosted Lightweight CI
└── Shell / Compose 静态门禁，不声称完整镜像构建成功

GitHub-hosted GHCR publisher
└── Release SHA-256 -> OCI blob digest -> GHCR manifest/tag
    （只搬运已验证的 Release 镜像，不重新 build）

真实 UTrack 工程
└── 仍由项目级 [100%] Built target UTrack 作为最终工程验收
```

也就是说，CI/CD 增强了可重复性，但不会把“静态检查通过”“镜像环境通过”和“真实业务工程编译通过”混为一谈。
