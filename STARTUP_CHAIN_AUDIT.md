# Startup-chain audit

This changeset is based on upstream `main` commit
`c5e003ad1f046ff8ae2d9ecef590d7d15034bc60` (2026-07-14). It is intentionally
separate from the earlier archive based on the January revision.

## Applied fixes

- Added `efi-arm64`: GPT/ESP, `BOOTAA64.EFI`, GRUB for ARM64, U-Boot EFI, EDK2
  (AAVMF), and a reproducible QEMU launcher.
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
