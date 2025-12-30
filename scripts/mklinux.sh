#!/bin/bash

set -e

__usage="
Usage: $(basename $0) [OPTIONS] mklinux.sh
Download, compile and package Linux Kernel for Alpine Linux.

Options:
  --kernel_arch <arch>     Target architecture (default: arm64)
  --kernel_url <url>       Git repository URL (default: https://github.com/torvalds/linux)
  --kernel_branch <branch> Git branch/tag (default: v6.12)
  --kernel_config <file>   Path to config file (optional)

Run as root or with sudo if necessary for packaging permissions.
Dependencies: git, build-essential, bison, flex, libssl-dev, bc, openssl
"

help()
{
    echo "$__usage"
    exit $1
}

log_info() { echo -e "\033[32m[INFO] $1\033[0m"; }
log_warn() { echo -e "\033[33m[WARN] $1\033[0m"; }
log_err() { echo -e "\033[31m[ERR] $1\033[0m"; }

default_param() {
    kernel_arch="arm64"
    kernel_url="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
    kernel_branch="v6.12.60"
    kernel_config="" 
    
    work_dir="$(pwd)/build"
    out_dir="${work_dir}/kernel-pkg/kernel-bin"
    kernel_dir="${work_dir}/linux-src"
}

parseargs()
{
    if [ "x$#" == "x0" ]; then
        return 0
    fi

    while [ "x$#" != "x0" ];
    do
        case "$1" in
            --kernel_arch)
                kernel_arch="$2"
                shift 2
                ;;
            --kernel_url)
                kernel_url="$2"
                shift 2
                ;;
            --kernel_branch)
                kernel_branch="$2"
                shift 2
                ;;
            --kernel_config)
                kernel_config="$2"
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

check_env() {
    for cmd in git make gcc openssl tar; do
        if ! command -v $cmd &> /dev/null; then
            log_err "Missing dependency: $cmd"
            exit 1
        fi
    done

    host_arch=$(uname -m)
    
    case $host_arch in
        x86_64) host_arch="x86_64" ;;
        aarch64) host_arch="arm64" ;;
    esac

    cross_compile=""
    if [ "$host_arch" != "$kernel_arch" ]; then
        if [ "$kernel_arch" == "arm64" ]; then
            cross_compile="aarch64-linux-gnu-"
            if ! command -v ${cross_compile}gcc &> /dev/null; then
                log_err "Cross compiler ${cross_compile}gcc not found. Please install it."
                exit 1
            fi
        fi
        log_info "Detected cross-compilation: Host=$host_arch, Target=$kernel_arch, Prefix=$cross_compile"
    fi

    mkdir -p ${work_dir}
    mkdir -p ${out_dir}
}

fetch_kernel(){
    if [ -d "${kernel_dir}" ]; then
        log_warn "Kernel directory ${kernel_dir} already exists. Skipping clone."
    else
        log_info "Cloning kernel source [${kernel_branch}] from ${kernel_url}..."
        git clone --depth=1 "${kernel_url}" -b "${kernel_branch}" "${kernel_dir}"
    fi
}

patch_kernel(){
    cd "${kernel_dir}"
    if [ -d "${work_dir}/../patches/kernel/${kernel_branch}/patches" ]; then
        log_info "Applying patches..."
        for patch in ${work_dir}/../patches/kernel/${kernel_branch}/patches/*.patch; do
            log_info "Applying patch: $(basename $patch)"
            git apply "$patch"
        done
    else
        log_info "No patches directory found. Skipping patching."
    fi

    if [ -d "${work_dir}/../patches/kernel/${kernel_branch}/files" ]; then
        log_info "Applying files..."
        cp -r ${work_dir}/../patches/kernel/${kernel_branch}/files/* .
    else
        log_info "No files directory found. Skipping patching."
    fi

    touch .patched
}

compile_kernel(){
    cd "${kernel_dir}"
    
    log_info "Configuring kernel for ${kernel_arch}..."


    if [ ! -f "../../configs/kernel/${kernel_config}" ]; then
        echo "${kernel_config} not found."
        exit 2
    fi
    
    log_info "Using relative config: ../../configs/kernel/${kernel_config}"
    cp "../../configs/kernel/${kernel_config}" .config
    make ARCH=${kernel_arch} CROSS_COMPILE=${cross_compile} olddefconfig


    log_info "Compiling kernel (Jobs: $(nproc))..."
    make ARCH=${kernel_arch} CROSS_COMPILE=${cross_compile} -j$(nproc) all
}

output_kernel() {
    log_info "Output Linux..."
    
    cd "${kernel_dir}"
    
    rm -rf "${out_dir}"
    mkdir -p "${out_dir}/boot"

    log_info "Installing modules to staging..."
    make ARCH=${kernel_arch} CROSS_COMPILE=${cross_compile} INSTALL_MOD_PATH="${out_dir}" modules_install
    
    rm "${out_dir}/lib/modules/${kern_ver}/build" || true

    log_info "Installing kernel image..."
    make ARCH=${kernel_arch} CROSS_COMPILE=${cross_compile} INSTALL_PATH="${out_dir}/boot" install
    cp arch/${kernel_arch}/boot/Image ${out_dir}/boot
    
    log_info "Installing kernel devicetrees..."
    make ARCH=${kernel_arch} CROSS_COMPILE=${cross_compile} INSTALL_PATH="${out_dir}/boot" dtbs_install
    cp -r ${out_dir}/boot/dtbs/* ${out_dir}/boot/dtb
}

default_param
parseargs "$@" || help $?

check_env
fetch_kernel

if [ ! -f ${kernel_dir}/.patched ];then
    patch_kernel
fi

compile_kernel
output_kernel
