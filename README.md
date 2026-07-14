# alpine-sbc

在 **arm64 Alpine Linux host** 上，为 arm64 单板计算机原生构建 U-Boot、Linux
内核 Alpine 包、rootfs 和可写盘镜像。

内核打包布局对齐 Alpine 官方 `main/linux-lts`：

- `linux-sbc-<board>`：内核、模块、System.map、配置和 DTB；
- `linux-sbc-<board>-dev`：构建第三方内核模块所需的 headers、scripts、
  `Module.symvers`、可用时的 `vmlinux.h` 和 `/lib/modules/<release>/build`；
- `linux-sbc-<board>-doc`：内核文档；
- dev 包依赖 Alpine 官方 `linux-headers`，项目不会覆盖官方同名包；
- 主包依赖官方虚拟包 `initramfs-generator` 和 `linux-firmware-any`；
- APK 和本地 `APKINDEX.tar.gz` 均使用项目构建密钥签名，rootfs 不使用
  `--allow-untrusted`。

## 构建环境

- Alpine Linux arm64/aarch64 host；
- root 权限（安装依赖、chroot、loop device 和 mount）；
- 建议至少 30 GiB 可用磁盘空间；
- 能访问板级配置引用的 Git 仓库和 Alpine 镜像。

完整构建：

```sh
sudo ./build.sh --board extlinux-arm64 --version 3.23.0
```

首次运行会通过 `apk` 安装构建依赖。常用选项：

```text
--clean               删除 build/ 后完整重建
--jobs N              编译并行度
--mirror URL          Alpine 镜像根地址
--skip-deps           不执行 apk add
--skip-bootloader     复用 build/u-boot
--skip-kernel         复用 build/packages
--skip-rootfs         复用 build/rootfs
--skip-image          只生成到 rootfs
```

默认开发镜像允许 root 在串口控制台无密码登录，但 SSH 密码登录保持关闭。
需要控制台密码时，在调用前设置环境变量（不要把密码提交到仓库）：

```sh
sudo env ALPINE_SBC_ROOT_PASSWORD='change-me' \
  ./build.sh --board khadas-vim3 --version 3.23.0
```

产物位于：

```text
build/packages/aarch64/            已签名的内核 APK 和 APKINDEX
build/keys/alpine-sbc.rsa.pub      本地仓库公钥
build/rootfs/                       已安装内核的 Alpine rootfs
build/output/*.img.xz              压缩磁盘镜像
build/output/*.img.xz.sha256       镜像校验值
build/log/*.log                    构建日志
```

## 单独执行阶段

阶段脚本都支持 `--help`，并可独立运行：

```sh
sudo scripts/mkbootloader.sh --board firefly-rk3568-roc-pc --jobs 8
scripts/mklinux.sh --board firefly-rk3568-roc-pc --jobs 8
scripts/libs/kernel-pkg.sh --board firefly-rk3568-roc-pc
sudo scripts/mkrootfs.sh --board firefly-rk3568-roc-pc \
  --version 3.23.0 --arch aarch64
sudo scripts/mkimage.sh --board firefly-rk3568-roc-pc \
  --name alpine-firefly-rk3568-roc-pc-3.23.0-aarch64
```

## 新增开发板

在 `boards/<name>.config` 中至少定义：

```sh
arch="arm64"
rootfs_arch="aarch64"
platform="rockchip64"       # qemu/rockchip64/amlogic/stm32mp2/...
boot_mode="extlinux"
bootargs="... root=LABEL=rootfs ..."

bootloader_url="..."
bootloader_branch="..."
bootloader_config="..._defconfig"

kernel_url="..."
kernel_branch="..."
kernel_config="linux-....config"
dtb_name="vendor/board"     # 不带 .dtb；无 DTB 时为 none

part_table="gpt"
boot_size="256"             # MiB
```

默认 kernel flavor 为 `sbc-<board>`，可以用 `kernel_flavor` 覆盖；名称必须适合
APK 包名和内核 release 后缀。`kernel_pkgrel` 默认为 `0`，只修改打包内容而不变更
上游 kernel version 时应递增它。`kernel_firmware_packages` 可指定板级固件包；未设置
时会按 platform 选择 `linux-firmware-rockchip`、`linux-firmware-amlogic` 或
`linux-firmware-none`，从而明确满足官方 `linux-firmware-any` 虚拟依赖。

补丁和覆盖文件按以下顺序应用：

```text
patches/kernel/<ref>/{patches,files}
patches/kernel/<ref>/generic/{patches,files}
patches/kernel/<ref>/<board>/{patches,files}
patches/u-boot/<ref>/generic/{patches,files}
patches/u-boot/<ref>/<board>/{patches,files}
```

## 内核包兼容性

主包中的 ABI 形如 `6.12.60-0-sbc-khadas-vim3`，布局包括：

```text
/boot/vmlinuz-sbc-khadas-vim3
/boot/System.map-<ABI>
/boot/config-<ABI>
/boot/dtbs-sbc-khadas-vim3/
/lib/modules/<ABI>/kernel-suffix
/usr/share/kernel/sbc-khadas-vim3/kernel.release
```

`kernel-suffix` 和 flavor 化文件名供 Alpine 官方 `mkinitfs` trigger 使用。镜像脚本会
在生成前检查内核、initramfs 和板级 DTB，缺少任一必需产物都会立即失败。

安装第三方模块构建环境：

```sh
apk add linux-sbc-<board>-dev build-base
```

## 验证

无需 arm64 编译即可运行静态检查：

```sh
make test
shellcheck build.sh scripts/*.sh scripts/libs/*.sh tests/*.sh
```

完整内核、rootfs 和镜像验证必须在 arm64 Alpine host 上进行。

## 支持的配置

- `100ask-dshanpi-r1`
- `100ask-dshanpi-a1`
- `firefly-rk3566-roc-pc`
- `firefly-rk3568-roc-pc`
- `firefly-rk3588s-roc-pc`
- `sakurapi-rk3308b`
- `khadas-vim3`
- `myb-stm32mp257x-1GB`
- `extlinux-arm64`（QEMU virt）

## 参考

- [Alpine Linux](https://www.alpinelinux.org/)
- [Alpine aports: linux-lts](https://gitlab.alpinelinux.org/alpine/aports/-/tree/master/main/linux-lts)
- [Alpine aports: linux-headers](https://gitlab.alpinelinux.org/alpine/aports/-/tree/master/main/linux-headers)
- [Alpine abuild](https://wiki.alpinelinux.org/wiki/Abuild_and_Helpers)
