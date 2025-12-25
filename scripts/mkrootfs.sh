#!/bin/bash

__usage="
Usage: mkrootfs [OPTIONS]
Build Rootfs rootfs.
Run in root user.

Options: 
  --mirror MIRROR_ADDR         The URL/path of target mirror address.
  --rootfs ROOTFS_DIR          The directory name of rootfs rootfs.
  --version ROOTFS_VER         The version of alpine.
  --arch ROOTFS_ARCH
  --help                       Show command help.
"

help()
{
    echo "$__usage"
    exit $1
}

default_param() {
    ROOTFS="rootfs"
    VERSION="3.22"
    ARCH="aarch64"
    MIRROR="https://dl-cdn.alpinelinux.org"
}

parseargs()
{
    if [ "x$#" == "x0" ]; then
        return 0
    fi

    while [ "x$#" != "x0" ];
    do
        case "$1" in
            --mirror)
                MIRROR="$2"
                shift 2
                ;;
            --rootfs)
                ROOTFS="$2"
                shift 2
                ;;
            --version)
                VERSION="$2"
                shift 2
                ;;
            --arch)
                ARCH="$2"
                shift 2
                ;;
            --help|-h)
                help 0
                ;;
            *)
                log_err "Unknown parameter: $1"
                help 2
                ;;
        esac
    done
}

get_minirootfs() {
    if [ ! -d ${ROOTFS} ];then
      mkdir ${ROOTFS}
    fi

    major=$(echo "${VERSION}" | cut -d. -f1)
    minor=$(echo "${VERSION}" | cut -d. -f2)
    patch=$(echo "${VERSION}" | cut -d. -f3)

    echo "Major: $major"
    echo "Minor: $minor"
    echo "Patch: $patch"

    echo "Downloading ${MIRROR}/alpine/v${major}.${minor}/releases/${ARCH}/alpine-minirootfs-${VERSION}-${ARCH}.tar.gz ..."
    
    wget "${MIRROR}/alpine/v${major}.${minor}/releases/${ARCH}/alpine-minirootfs-${VERSION}-${ARCH}.tar.gz"
    
    if [ $? -ne 0 ]; then
        echo "Failed to download minirootfs from ${MIRROR}"
        exit 2
    fi

    tar -zxvf "alpine-minirootfs-${VERSION}-${ARCH}.tar.gz" \
    -C ${ROOTFS}
    
    rm "alpine-minirootfs-${VERSION}-${ARCH}.tar.gz"
}

init_rootfs() {
    cp -b /etc/resolv.conf ${ROOTFS}/etc/resolv.conf

    sed -i "s|https|http|g" ${ROOTFS}/etc/apk/repositories
    
    cat <<EOF | chroot ${ROOTFS} sh
apk update
apk add bash
EOF

}

PKG_LISTS="openrc openrc-bash-completion alpine-base vim \
           openrc-init busybox-openrc busybox-mdev-openrc \
           busybox-suid openssh-server-common-openrc sudo \
           util-linux btop bash-completion openssh tzdata coreutils \
           dhcpcd mdev-conf networkmanager networkmanager-openrc \
           networkmanager-cli networkmanager-tui networkmanager-wifi \
           networkmanager-bluetooth networkmanager-dnsmasq"

install_pkgs(){
    for pkg in ${PKG_LISTS}; do
        echo "Installing package: ${pkg} ..."
        chroot ${ROOTFS} apk add ${pkg}
        if [ $? -ne 0 ]; then
            echo "Failed to install package: ${pkg}"
            exit 3
        fi
    done
}

config_rootfs(){
    chroot ${ROOTFS} rc-update add devfs sysinit
    chroot ${ROOTFS} rc-update add procfs sysinit
    chroot ${ROOTFS} rc-update add sysfs sysinit

    chroot ${ROOTFS} rc-update add mdev sysinit

    sed -i '/tty1/d' ${ROOTFS}/etc/inittab
    sed -i '/tty2/d' ${ROOTFS}/etc/inittab
    sed -i '/tty3/d' ${ROOTFS}/etc/inittab
    sed -i '/tty4/d' ${ROOTFS}/etc/inittab
    sed -i '/tty5/d' ${ROOTFS}/etc/inittab
    sed -i '/tty6/d' ${ROOTFS}/etc/inittab

    echo "ttyAMA0::respawn:/sbin/getty -L 0 ttyAMA0 vt100" >> ${ROOTFS}/etc/inittab

    echo "Configuring Network..."
    mkdir -p ${ROOTFS}/etc/network

    echo "auto lo" > ${ROOTFS}/etc/network/interfaces
    echo "iface lo inet loopback" >> ${ROOTFS}/etc/network/interfaces

    chroot ${ROOTFS} rc-update add networking boot
    chroot ${ROOTFS} rc-update add modules boot

    mkdir -p ${ROOTFS}/etc/local.d
    cat > ${ROOTFS}/etc/local.d/load_modules.start << 'EOF'
#!/bin/sh
echo "Scanning hardware drivers..."
mdev -s
find /sys -name modalias -type f -exec cat '{}' + | sort -u | xargs -n1 modprobe -b -q 2>/dev/null
EOF
    chmod +x ${ROOTFS}/etc/local.d/load_modules.start
    chroot ${ROOTFS} rc-update add local default

    echo "alpine" > ${ROOTFS}/etc/hostname

    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' ${ROOTFS}/etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' ${ROOTFS}/etc/ssh/sshd_config
    chroot ${ROOTFS} rc-update add sshd default

    cp ${ROOTFS}/usr/share/zoneinfo/Asia/Shanghai ${ROOTFS}/etc/localtime
    echo "Asia/Shanghai" > ${ROOTFS}/etc/timezone

    sed -i 's/\/bin\/ash/\/bin\/bash/g' ${ROOTFS}/etc/passwd

    chroot ${ROOTFS} echo "root:1234" | chpasswd

    #chroot ${ROOTFS} depmod -a

    rm -rf ${ROOTFS}/var/cache/apk/*
}

default_param
parseargs "$@" || help $?

get_minirootfs
init_rootfs
install_pkgs
config_rootfs
