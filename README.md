# alpine-sbc
build alpine linux for sbc

## Build

```
sudo bash build.sh --board <board> --version <version>
```

### Examples

```
sudo bash build.sh --board extlinux-arm64 --version 3.23.0
```

### Support Devices (Exp)

1.  100ASk

    - DShanPi R1

        ```
        sudo bash build.sh --board 100ask-dshanpi-r1 --version 3.23.0
        ```

    - DShanPi A1

        ```
        sudo bash build.sh --board 100ask-dshanpi-a1 --version 3.23.0
        ```

2.  Firefly

    - Station M2

        ```
        sudo bash build.sh --board firefly-rk3566-roc-pc --version 3.23.0
        ```

    - Station P2

        ```
        sudo bash build.sh --board firefly-rk3568-roc-pc --version 3.23.0
        ```

    - Station M3

        ```
        sudo bash build.sh --board firefly-rk3588s-roc-pc --version 3.23.0
        ```

3.  Sakura Pi

    - SakuraPi RK3308B

        ```
        sudo bash build.sh --board sakurapi-rk3308b --version 3.23.0
        ```

4.  Khadas

    - Khadas VIM 3

        ```
        sudo bash build.sh --board khadas-vim3 --version 3.23.0
        ```

5.  MYiR

    - myb-stm32mp257x-1GB

        ```
        sudo bash build.sh --board myb-stm32mp257x-1GB --version 3.23.0
        ```

## Reference

Alpine Linux: https://www.alpinelinux.org/

Armbian Linux: https://github.com/armbian/build

openEuler: https://atomgit.com/openeuler/SBC-sig