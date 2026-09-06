# 权限、UID/GID 与跨 Ubuntu 迁移说明

这份文档只解释一个问题：**为什么 Docker 里会出现权限问题，以及 v5.1 为什么可以同时解决 SDK 和 bind mount 源码的权限。**

## 1. 两类权限一定要分开

### 1.1 镜像内部的 SDK

路径：

```text
/opt/fsl-imx-xwayland/6.1-mickledore
```

它属于 Docker image 自己的文件。

我们的目标是：

```text
owner: root
普通开发用户: 只读 + 可以进入目录 + 可以执行原本的工具
```

因此 Dockerfile 对整个 SDK 使用：

```sh
chmod -R a+rX /opt/fsl-imx-xwayland/6.1-mickledore
```

`X` 是大写。它与 `x` 不一样：

- 目录一定增加 execute/traverse；
- 原本就是 executable 的文件继续可执行；
- 普通 `.h/.a/.so` 不会因为这个命令被无意义地全部加 execute。

这解决的是：

```text
SDK 被 Docker 导入后 owner 变成 root
        ↓
原权限只有 owner/group 能读
        ↓
普通 embedsky 读不到头文件和 .a
        ↓
编译/链接报错
```

### 1.2 bind mount 的源码

假设：

```text
Host:      /home/H/share/project
Container: /workspace
```

这两边不是两份文件。`/workspace/a.cpp` 就是宿主机那个 `a.cpp`。

Linux 判断所有者看的是数字：

```text
UID / GID
```

不是用户名字符串。

所以：

```text
Host H:         UID 1001
Container user: UID 1000
```

即使两边都叫 `embedsky`，数字不同也可能产生写权限和产物 ownership 问题。反过来也一样：宿主用户名可以叫 `wdfk`，容器内仍然叫 `embedsky`；只要运行时映射后的数字 UID/GID 与宿主一致，bind mount 的 ownership 就能保持正确。

## 2. v5.1 的运行流程

```text
宿主机执行 ./scripts/dev.sh
        │
        ├─ id -u -> HOST_UID
        ├─ id -g -> HOST_GID
        └─ WORKSPACE_DIR -> 源码绝对路径
                │
                ▼
          docker compose run
                │
                ▼
        entrypoint 先以 root 启动
                │
                ├─ 修改容器 embedsky 数字 UID
                ├─ 修改容器 embedsky 主 GID
                ├─ 只 chown /home/embedsky
                ├─ source Yocto environment-setup
                └─ PATH 前置 CMake 3.20.6
                │
                ▼
          setpriv 降权为 embedsky
                │
                ▼
          bash / cmake / make
```

这里 root 只用于“启动配置”。真正编译时已经不是 root。

## 3. 为什么绝对不能在 entrypoint 里 chown /workspace

因为 `/workspace` 是 bind mount。

如果写：

```sh
chown -R embedsky:embedsky /workspace
```

实际上是在递归修改**宿主机真实 Git 仓库**。

这可能：

- 改掉本来正确的 owner；
- 破坏共享目录/团队 ACL；
- 扫描大型 Linux kernel 仓库很慢；
- 把问题从 Docker 扩大到宿主机。

因此 v5.1 只调整：

```text
/home/embedsky
```

从不自动 chown `/workspace`。

## 4. 为什么不把宿主 UID/GID写死在 Docker build

旧做法大致相当于：

```text
docker build 时：
Host UID/GID = 1000:1000
        ↓
Image 中 embedsky = 1000:1000
```

当前机器没有问题。

但导出镜像到机器 B：

```text
Host B = 1001:1001
Image  = 1000:1000
```

镜像本身已经制作完成，UID/GID 不会因为换电脑自动变化。

如果为了这两个数字重新制作 25 GiB SDK 镜像，迁移成本太高。

所以 v5.1 把 UID/GID 从**构建期**移到**容器启动期**。

## 5. 为什么 SDK 又不需要动态 UID/GID

因为 SDK 不应该属于开发用户。

它更像系统安装的：

```text
/usr/bin/gcc
/usr/include/stdio.h
```

合理模型是：

```text
root 拥有
所有开发用户可读
工具可执行
普通用户不可修改
```

因此 SDK 用 `a+rX`；源码用 UID/GID 匹配。两种问题不能用同一个 `chown` 方案处理。

## 6. 换 Ubuntu / 换目录时怎么做

例如旧机器：

```text
Ubuntu 20.04
UID=1000
源码=/home/embedsky/share/project
```

新机器：

```text
Ubuntu 24.04
UID=1001
源码=/mnt/data/project
```

只要：

1. 新机器是当前支持目标 Linux x86-64/amd64；
2. Docker Engine + Compose plugin 正常；
3. 已导入 `imx8p-dev:20.04` 镜像；
4. 当前用户本身对 `/mnt/data/project` 有读写权限；

就可以：

```sh
./scripts/dev.sh /mnt/data/project
```

`dev.sh` 会重新读取新机器的 UID/GID 和新路径。

镜像文件如何从 Ubuntu 20.04 离线迁移到 Ubuntu 24.04、如何避免 27 GiB 临时 TAR、VMware Shared Folder 怎么用，以及 Docker 29 containerd image store 为什么会显著增加磁盘占用，统一见：

[offline-image-migration.md](offline-image-migration.md)

## 7. 什么情况 UID/GID 匹配仍然不能解决

下面这些属于宿主机文件系统本身的问题：

- 当前宿主用户本来就没有源码目录写权限；
- NFS/CIFS 有额外服务端身份映射；
- ACL 明确禁止访问；
- 目录只读挂载；
- SELinux/AppArmor/企业安全策略另有限制。

v5.1 不会通过 `chmod 777` 强行绕过这些策略。

`dev.sh` 如果发现宿主用户自己都不能读写 workspace，会直接报错并停止。

## 8. 出问题时先执行哪几条

宿主机：

```sh
id
ls -ld /你的源码目录
docker image ls
```

进入容器：

```sh
whoami
id
ls -ld /workspace
ls -ld /opt/fsl-imx-xwayland/6.1-mickledore
```

快速验证：

```sh
verify-imx8p-env
```

全 SDK 权限检查：

```sh
check-imx8p-sdk-permissions
```

不要第一反应就执行 `sudo chmod -R 777`。

## 9. 这次 Thrift 问题如何对应到模型

之前出现的关键现象是：

```text
.../usr/include/thrift        root:root 770
.../lib/libthrift.a           root:root 770
```

普通用户没有 `other` 的 read/execute 权限，所以读取失败。

临时把 Thrift 路径改成普通用户可读后，UTrack 已经能够正常链接并完成构建。这说明现在要固化的不是新的 CMake 搜索路径，而是 SDK 文件权限策略。

v5.1 因此把修复面扩大到整个 SDK，而不是继续维护 Thrift/SSL/SQLite 等逐库白名单。
