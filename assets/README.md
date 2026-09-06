# 构建资产目录

`scripts/prepare-assets.sh` 会在这里生成 Dockerfile 使用的固定 CMake 资产：

```text
assets/cmake-3.20.6-linux-x86_64.tar.gz
```

约 25 GiB 的 NXP/FSL Yocto SDK **不会**复制到这个目录。`scripts/build-image.sh`
会把 `/opt/fsl-imx-xwayland/6.1-mickledore` 作为 Buildx named context `sdk` 直接传入。

不要把完整 SDK 手工解压到 `assets/`。只有固定 CMake 源目录发生变化时，才需要重新运行
`scripts/prepare-assets.sh`。
