# 离线镜像迁移：Ubuntu 20.04 → Ubuntu 24.04

这份文档用于把已经制作并验证过的 `imx8p-dev:20.04` 镜像离线交给另一台 Linux 主机使用，重点处理这个镜像体积很大时的磁盘占用问题。

## 1. 推荐迁移模型

源码和 Docker 镜像分开迁移：

```text
制作机（Ubuntu 20.04）
  ├─ imx8p-dev:20.04
  │      │
  │      └─ export-image.sh
  │             ↓
  │       image.tar.gz/.tar.zst + .sha256
  │             ↓
  └──────── 移动硬盘 / NAS / VMware Shared Folder ────────┐
                                                           │
目标机（Ubuntu 24.04）                                     │
  ├─ import-image.sh <共享目录中的镜像包> <────────────────┘
  └─ UTrack 源码单独复制/克隆，再由 dev.sh bind mount
```

`docker save` 只保存 Docker image，不包含通过 `-v` / Compose bind mount 挂载进去的 Git 源码。

## 2. 为什么当前脚本不再生成完整临时 TAR

旧导出流程：

```text
Docker image (~27 GiB)
       ↓ docker save
临时 image.tar (~27 GiB)
       ↓ gzip
最终 image.tar.gz
```

在压缩期间，临时 TAR 和压缩文件会同时占空间。大镜像很容易把小容量虚拟机磁盘写满。

当前 `scripts/export-image.sh` 使用 FIFO：

```text
docker save
    ↓
  FIFO（只传数据，不保存完整 TAR）
    ↓
gzip / zstd
    ↓
最终压缩包
```

这样仍然能分别检查 `docker save` 与压缩器的退出状态，但不需要额外落地约 27 GiB 的临时 TAR。

旧导入流程也会先把 `.tar.gz` 完整解压到 `/tmp`，再执行 `docker load`。当前 `scripts/import-image.sh` 直接调用：

```sh
docker load -i image.tar.gz
```

Docker 官方支持从 gzip、bzip2、xz、zstd 压缩的 tar archive 直接 load，因此不需要先生成完整临时 TAR：

- https://docs.docker.com/reference/cli/docker/image/load/

## 3. 制作机导出

先确认镜像：

```sh
docker image ls imx8p-dev:20.04
```

### 3.1 默认：gzip，兼容性优先

```sh
./scripts/export-image.sh /path/to/imx8p-dev-20.04-image.tar.gz
```

脚本会生成：

```text
imx8p-dev-20.04-image.tar.gz
imx8p-dev-20.04-image.tar.gz.sha256
```

### 3.2 推荐大镜像：zstd，速度优先

制作机安装：

```sh
sudo apt install zstd
```

然后：

```sh
./scripts/export-image.sh /path/to/imx8p-dev-20.04-image.tar.zst
```

当前脚本使用：

```text
zstd -T0 -1
```

`-T0` 使用可用 CPU 线程，`-1` 优先压缩速度。对于包含约 25 GiB Yocto SDK 的开发镜像，比单线程 gzip 更适合重复离线分发。

## 4. VMware 虚拟机：优先直接放共享目录

如果目标 Ubuntu 24.04 是 VMware 虚拟机，不建议先把十几 GiB 的压缩包复制到虚拟机根分区，再导入。

宿主机可设置 VMware Shared Folder，例如共享名：

```text
CODE
```

Ubuntu Guest 先确保安装：

```sh
sudo apt update
sudo apt install -y open-vm-tools open-vm-tools-desktop
```

然后重启 Guest。Linux Guest 通常可以看到：

```text
/mnt/hgfs/CODE
```

检查：

```sh
vmware-hgfsclient
ls -lah /mnt/hgfs
```

如果 `vmware-hgfsclient` 能看到 `CODE`，但 `/mnt/hgfs` 仍为空，可以手工挂载：

```sh
sudo mkdir -p /mnt/hgfs
sudo vmhgfs-fuse .host:/ /mnt/hgfs -o allow_other
```

如果共享名是 `CODE`，可以建立：

```sh
mkdir -p /mnt/hgfs/CODE/docker-images
```

然后把镜像包放在宿主机对应的共享目录中。目标机直接从：

```text
/mnt/hgfs/CODE/docker-images/
```

读取，不再额外占用 Ubuntu 虚拟磁盘保存压缩包。

## 5. 目标机导入

假设两个文件位于：

```text
/mnt/hgfs/CODE/docker-images/imx8p-dev-20.04-image.tar.gz
/mnt/hgfs/CODE/docker-images/imx8p-dev-20.04-image.tar.gz.sha256
```

直接：

```sh
./scripts/import-image.sh \
    /mnt/hgfs/CODE/docker-images/imx8p-dev-20.04-image.tar.gz
```

脚本会：

1. 检查 Docker daemon；
2. 如果同目录存在 `.sha256`，先校验 SHA256；
3. 检查 Docker storage backend；
4. 打印存储文件系统剩余空间；
5. 直接 `docker load -i`，不生成完整临时 TAR；
6. 检查 `imx8p-dev:20.04` 是否真实出现在本机 image store。

导入后：

```sh
docker image ls
df -h /
docker system df -v
```

## 6. Ubuntu 24.04 / Docker 29 为什么可能占约两倍空间

在一次实际迁移中，目标机得到：

```text
imx8p-dev:20.04
CONTENT SIZE : 27.1GB
DISK USAGE   : 54.7GB

/var/lib/containerd : 51G
```

并且：

```sh
docker info -f '{{ .DriverStatus }}'
```

输出：

```text
[[driver-type io.containerd.snapshotter.v1]]
```

这不是导入脚本留下了一个 27 GiB 临时 TAR。

Docker Engine 29.0+ 的 fresh installation 默认使用 containerd image store。Docker 官方说明，这种存储后端会同时保存：

- compressed image content：用于镜像内容管理、pull/push；
- unpacked snapshot：用于容器根文件系统和快速启动。

所以同一镜像的磁盘使用量会高于 legacy graph driver：

- https://docs.docker.com/engine/storage/containerd/

上面的 `54.7GB / 51G` 是该次环境的实测值，不应机械理解为所有机器都精确是 `2 × CONTENT SIZE`，但它说明这个项目必须给 Docker storage 留足空间。

### 建议容量

对于当前 `imx8p-dev:20.04`：

```text
导入前 Docker storage 可用空间：建议 >= 60 GiB
Ubuntu 24 开发虚拟机磁盘：       建议 120~150 GiB
```

如果还要在同一根分区保存 UTrack 源码、`build/`、系统更新和其他 Docker image，优先选择约 150 GiB。

## 7. 不要手工删除 /var/lib/containerd

不要为了回收空间执行：

```sh
sudo rm -rf /var/lib/containerd/*
```

containerd image store 的 content、snapshot 和 metadata 都在这里，手工删除可能让 Docker 数据不一致。

先检查：

```sh
docker image ls -a
docker system df -v
sudo du -sh /var/lib/containerd 2>/dev/null
```

普通 dangling 数据可以用 Docker 自己的 prune 命令处理，但不要在不确认目标的情况下执行：

```sh
docker system prune -a
```

因为 `-a` 可以删除当前没有容器引用、但你仍想保留的 `imx8p-dev:20.04`。

## 8. 导入后先验证镜像，再编译 UTrack

先确认容器可以启动：

```sh
./scripts/dev.sh /path/to/Ultra_Linux
```

进入容器后：

```sh
verify-imx8p-env
```

然后第一次构建时清理旧 CMake cache，并显式传入已经验证过的 host Thrift 路径：

```sh
cd /workspace
rm -rf build

cmake -S /workspace \
      -B /workspace/build \
      -DP=UTrack \
      -DTHRIFT_COMPILER=/usr/bin/thrift

cmake --build /workspace/build -j4
```

迁移验收分两层：

```text
镜像级：PASS: i.MX8P Docker development environment is UTrack-ready.
工程级：[100%] Built target UTrack
```

只有实际完成第二层，才能说明目标 Ubuntu 24.04 Host 上的完整 UTrack 构建路径已经通过。
