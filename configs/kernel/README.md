# Kernel configuration groups

The files in this directory are complete, reviewable kernel configurations
for a kernel *group*.  A group is the smallest unit that may share one Linux
build and one set of Alpine kernel packages.  Boards in the same group must
use the same kernel source URL, branch, configuration file, package release,
and kernel patches.  Their device trees may still be different; the package
contains the DTBs produced by that source and each board selects its own
`dtb_name` at image-generation time.

The group source identities live in `configs/kernel/groups/*.config`; a board
selects one with `kernel_group` and does not repeat those fields.

Current groups:

| Group | Configuration | Boards |
| --- | --- | --- |
| `generic-arm64` | `linux-generic-arm64-qemu.config` | `efi-arm64`, `extlinux-arm64` |
| `rockchip64-bsp` | `linux-rockchip64-bsp.config` | DshanPi A1/R1, Firefly RK3566/RK3568/RK3588S |
| `rockchip64-lts` | `linux-rockchip64-lts.config` | SakuraPi RK3308B |
| `amlogic-lts` | `linux-amlogic-lts.config` | Khadas VIM3 |
| `stm32mp2-bsp` | `linux-stm32mp2-bsp.config` | MYB STM32MP257X |

When a new board needs only a different DTB, it should join an existing
group.  When it needs a different kernel option, source branch, or patch, add
a new group and a new configuration file instead of weakening an existing
group.  This keeps package sharing safe: a package is never reused when its
effective kernel ABI or built-in device support can differ.

The configurations are intentionally group-scoped rather than copied into
every board file.  Device-specific choices belong in `boards/*.config`; only
options required by the complete group hardware set belong here.  After
changing a group configuration, run `make test` and rebuild at least one
board from every affected group.
