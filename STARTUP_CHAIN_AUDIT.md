# Startup-chain audit

This revision is based on upstream `main` commit
`675376b02a3aa7e38ba782d598f49aa879559652` (2026-07-15). That upstream commit
already contains the startup-chain changes initially audited against `c5e003a`;
this follow-up fixes the missing extlinux initramfs setting and audits every
board against one explicit configuration contract.

## Applied fixes

- Added `efi-arm64`: GPT/ESP, `BOOTAA64.EFI`, GRUB for ARM64, U-Boot EFI, EDK2
  (AAVMF), and a reproducible QEMU launcher.
- Added Alpine's `gnutls-dev` host package required to compile U-Boot's
  `mkeficapsule` tool when EFI/capsule support is enabled. Also added `gawk` and
  `util-linux-dev` to match Alpine's current U-Boot build dependencies.
- Made `initrd=yes`, kernel flavor/revision, serial settings, boot layout, and
  all other boot-critical fields explicit and validated for every board.
- Validated bootloader checksums, all three kernel APKs, the signed repository,
  and rootfs board/kernel metadata whenever a build stage is reused.
- Made every generated kernel APK package function create its abuild output
  directory before copying the staged kernel, development, or documentation tree.
- Removed stale APKs from abuild output before packaging, so a reused build tree
  cannot silently republish an older kernel package.
- Derived the repository public key from the active private key and installed it
  into the host APK trust store before abuild performs its automatic index update.
- Staged the local kernel repository below its required `aarch64/` directory so
  apk's repository-root resolution finds both `APKINDEX.tar.gz` and the APKs.
- Installed Alpine's split `sgdisk` package instead of its `gptfdisk` parent and
  moved all image-tool checks before the time-consuming build stages.
- Loaded loop support and restored missing loop-control, loop block, and loop
  partition device nodes for minimal Alpine hosts without automatic /dev events.
- Removed the generic kernel's stale ImmortalWrt built-in initramfs paths,
  enabled gzip initramfs decompression, and verified every image contains `/init`.
- Added generated extlinux/GRUB configuration checks and U-Boot capability and
  output-manifest validation.
- Corrected DshanPi A1 to the RK3576 DTB and pinned its DDR TPL to the known-good
  rkbin v1.08 blob while retaining the current BL31.
- Validated Rockchip, Allwinner, Amlogic, and STM32MP2 firmware sizes before any
  raw disk write.
- Corrected STM32MP2 SD boot to two `fsbla*` copies followed by the ST-required
  non-FWU `fip` partition and the standard U-Boot ENV type GUID. TF-A is built
  with `PSA_FWU_SUPPORT=0`; no invalid metadata or fake A/B fallback is exposed.
- Added TF-A, OP-TEE, and rkbin source/config cache identities so switching
  boards or firmware settings cannot silently reuse incompatible output.
- Validated all required TF-A FIP payloads with `fiptool` before image creation.
- Added per-board serial-console metadata, matching getty configuration, kernel
  console-driver checks, built-in rootfs/devtmpfs checks, and staged-DTB checks.
- Extended CI/static tests to cover all board configs, boot config rendering,
  EFI QEMU commands, STM32MP2 partition/install rules, and kernel package layout.

## Verification performed

```text
make test
shellcheck -x build.sh scripts/*.sh scripts/libs/*.sh extra/scripts/*.sh tests/*.sh
bash -n build.sh scripts/*.sh scripts/libs/*.sh extra/scripts/*.sh tests/*.sh
git diff --check
```

The Alpine v3.23 aarch64 repository indexes were also checked for `grub`,
`grub-efi`, `aavmf`, and `qemu-system-aarch64`. Full firmware/kernel compilation
and real-board boot validation still require the intended ARM64 Alpine host and
the physical boards.
