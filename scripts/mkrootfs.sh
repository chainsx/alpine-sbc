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
        if [ "x$1" == "x-h" -o "x$1" == "x--help" ]; then
            return 1
        elif [ "x$1" == "x" ]; then
            shift
        elif [ "x$1" == "x-m" -o "x$1" == "x--mirror" ]; then
            MIRROR=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-r" -o "x$1" == "x--rootfs" ]; then
            ROOTFS=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-v" -o "x$1" == "x--version" ]; then
            VERSION=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-v" -o "x$1" == "x--arch" ]; then
            ARCH=`echo $2`
            shift
            shift
        else
            echo `date` - ERROR, UNKNOWN params "$@"
            return 2
        fi
    done
}

get_minirootfs() {
    if [ ! -d ${ROOTFS} ];then
      mkdir $ROOTFS
    fi
    
    wget "${MIRROR}/alpine/v${VERSION}/releases/${ARCH}/alpine-minirootfs-${VERSION}.0-${ARCH}.tar.gz"
    
    tar -zxvf "alpine-minirootfs-${VERSION}.0-${ARCH}.tar.gz" \
    -C $ROOTFS
    
    rm "alpine-minirootfs-${VERSION}.0-${ARCH}.tar.gz"
}

init_rootfs() {
    cp -b /etc/resolv.conf ${ROOTFS}/etc/resolv.conf

    sed -i "s|https|http|g" ${ROOTFS}/etc/apk/repositories
    
    cat <<EOF | chroot ${ROOTFS} sh
apk update
apk add bash
EOF

}

install_pkgs(){
    chroot ${ROOTFS} apk add openrc openrc-bash-completion \
                             openrc-init busybox-openrc busybox-mdev-openrc \
                             busybox-suid openssh-server-common-openrc \
                             util-linux btop bash-completion openssh tzdata dhcpcd mdev-conf
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

    echo "Configuring Network..."
    mkdir -p ${ROOTFS}/etc/network
    cat > ${ROOTFS}/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

auto eth1
iface eth1 inet dhcp
EOF
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

    chroot ${ROOTFS} echo "root:alpine" | chpasswd

    chroot ${ROOTFS} depmod -a

    rm -rf ${ROOTFS}/var/cache/apk/*
}

default_param
parseargs "$@" || help $?

get_minirootfs
init_rootfs
install_pkgs
config_rootfs
