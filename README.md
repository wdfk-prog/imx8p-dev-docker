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

> 本项目不修改 Ubuntu APT 软件源，基础镜像仍为 `ubuntu:20.04`。

## 1. 目录和职责

```text
imx8p-dev-docker/
├── Dockerfile
├── compose.yaml
├── README.md
├── .dockerignore
├── .gitignore
├── assets/
│   └── README.md
├── docker/
│   └── entrypoint.sh
├── docs/
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

## 6. 离线导出/导入镜像

### 6.1 导出

默认 gzip：

```sh
./scripts/export-image.sh /path/to/imx8p-dev-20.04-image.tar.gz
```

大镜像推荐 zstd：

```sh
sudo apt install zstd
./scripts/export-image.sh /path/to/imx8p-dev-20.04-image.tar.zst
```

脚本会同时生成：

```text
<archive>
<archive>.sha256
```

当前实现采用流式导出，不再额外创建完整约 27 GiB 临时 TAR。

### 6.2 导入

```sh
./scripts/import-image.sh /path/to/imx8p-dev-20.04-image.tar.gz
```

或：

```sh
./scripts/import-image.sh /path/to/imx8p-dev-20.04-image.tar.zst
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
