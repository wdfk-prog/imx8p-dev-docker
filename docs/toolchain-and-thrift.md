# UTrack 工具链与 Thrift 为什么这样配置

这份文档专门解释 v5.1 固化的两个问题：**CC/CXX 环境冲突**和 **Thrift compiler 缺失**。如果你以后重新迁移 Docker，先看这里，不要再从报错重新猜。

## 1. Thrift 实际上有两部分

UTrack 的 Thrift 不是“装一个包就全部解决”，而是同时需要 host 和 target 两侧。

```text
x86-64 Docker 容器
/usr/bin/thrift 0.13.0
        │
        │ 读取 *.thrift
        ▼
生成 *.cpp / *.h
        │
        │ ARM64 交叉编译
        ▼
Yocto target sysroot
.../usr/include/thrift
.../lib/libthrift.a
        │
        ▼
UTrack.elf (AArch64)
```

因此 v5.1 的 Dockerfile 安装：

```text
thrift-compiler
```

它负责得到 `/usr/bin/thrift`。

v5.1 **不安装** Ubuntu host 侧的 `libthrift-dev`，因为 UTrack 最终要链接的是 NXP/FSL Yocto SDK 中的 ARM64 `libthrift.a`，不是 x86-64 Ubuntu 的 Thrift 库。

`verify-imx8p-env` 会同时检查：

- `/usr/bin/thrift` 存在；
- Thrift compiler 版本为 0.13.0；
- target Thrift header 可读；
- target `libthrift.a` 可读且能被交叉编译器解析；
- 一个最小 `.thrift` 文件能够实际生成 C++；
- 生成的 C++ 能用 ARM64 交叉编译器编译。

## 2. 为什么不能直接照搬 Yocto 导出的 CC/CXX

NXP/FSL SDK 的 `environment-setup-armv8a-poky-linux` 必须 source，因为它提供很多真正需要的环境：

```text
PATH
SDKTARGETSYSROOT
OECORE_*
PKG_CONFIG_*
交叉工具链路径
```

但是它同时把 Yocto 自己的编译策略放进 `CC/CXX`，例如已经实际观察到：

```text
-O2
-D_FORTIFY_SOURCE=2
-Wformat
-Wformat-security
-Werror=format-security
```

UTrack 自己的 CMake 又使用：

```text
-O0
-Wno-format
```

两套策略叠在一起时，GCC 12.2.0 已经实际报过：

```text
'-Wformat-security' ignored without '-Wformat' [-Werror=format-security]
_FORTIFY_SOURCE requires compiling with optimization (-O)
```

因此 v5.1 不取消 Yocto environment setup，而是在 source 完以后只把“项目编译策略”剥离掉。

最终强制：

```text
CC  = aarch64-poky-linux-gcc --sysroot=<SDKTARGETSYSROOT>
CXX = aarch64-poky-linux-g++ --sysroot=<SDKTARGETSYSROOT>
```

并清空：

```text
CFLAGS
CXXFLAGS
CPPFLAGS
LDFLAGS
```

这样：

- Yocto 的 sysroot、PATH、pkg-config 等基础能力仍然存在；
- UTrack 的 `-O0`、warning policy 等继续由自己的 CMake 控制；
- 不再出现 Yocto `-O2/FORTIFY/Wformat-security` 和 UTrack `-O0/Wno-format` 相互打架。

这不是通用 Yocto 项目的默认做法，而是针对 **已经成功构建过的 UTrack 工程契约** 固化的兼容策略。

## 3. v5.1 为什么要在镜像 build 完以后做更强验证

以前只验证：

```text
交叉编译器存在
简单 main.c/main.cpp 可以编译
```

这只能证明 SDK 本身能工作，不能证明它和 UTrack 的 CMake flags 能一起工作。

v5.1 在 `scripts/build-image.sh` 最后自动运行 `verify-imx8p-env`。它会直接使用：

```text
-O0 -Wno-format
```

执行 C 和 C++ 交叉编译，并额外跑一个最小 CMake configure/build 集成测试；同时检查环境中不存在已经确认冲突的：

```text
-O2
-D_FORTIFY_SOURCE
-Wformat-security
-Werror=format-security
```

这个 CMake smoke 还会使用与真实 UTrack 相同的显式参数：

```text
-DTHRIFT_COMPILER=/usr/bin/thrift
```

并确认 `THRIFT_COMPILER` 被缓存为 `/usr/bin/thrift`，最后通过 `-lthrift` 链接出 AArch64 可执行文件。

因此只要旧的 CC/CXX 或 Thrift 查找问题重新出现，**镜像构建最后就会 FAIL**，而不是等进入 UTrack 后才发现。

## 4. 新镜像完成后第一次构建 UTrack

进入工程：

```sh
./scripts/dev.sh ~/share/ultra-embeddedcodetrack/Ultra_Linux
```

先确认镜像门禁：

```sh
verify-imx8p-env
```

最后必须看到：

```text
PASS: i.MX8P Docker development environment is UTrack-ready.
```

第一次使用这个新环境时，建议清掉旧 CMake cache，并显式传入 host Thrift compiler：

```sh
cd /workspace
rm -rf build
cmake -S /workspace \
      -B /workspace/build \
      -DP=UTrack \
      -DTHRIFT_COMPILER=/usr/bin/thrift
```

这里显式传路径不是临时 workaround，而是当前 UTrack 跨主机/跨 cache 的稳定配置契约。镜像负责保证 `/usr/bin/thrift` 存在和版本正确；UTrack 配置不再依赖其 CMake 逻辑一定能自动发现该程序。

检查 CMake cache：

```sh
grep '^THRIFT_COMPILER:' /workspace/build/CMakeCache.txt
```

预期：

```text
THRIFT_COMPILER:FILEPATH=/usr/bin/thrift
```

然后：

```sh
cmake --build /workspace/build -j4
```

最终验收仍然是实际 UTrack 构建达到：

```text
[100%] Built target UTrack
```

## 5. 不需要再做的临时操作

v5.1 的目标就是让下面这些历史临时操作全部消失：

```text
手工 apt install thrift-compiler
手工 export CC=...
手工 export CXX=...
unset CFLAGS/CXXFLAGS/CPPFLAGS/LDFLAGS
/tmp/utrack-thrift-lib
export LIBRARY_PATH=...
只对 Thrift 单独 chmod
```

如果 v5.1 仍要求其中任何环境级临时操作才能正常构建，就说明镜像没有达到本版本设计目标，应先查 `verify-imx8p-env` 的失败项，而不是继续叠加临时环境变量。

需要保留的 UTrack CMake 参数是：

```text
-DTHRIFT_COMPILER=/usr/bin/thrift
```

它属于工程 configure 输入，不属于对容器环境的临时修补。
