#!/bin/bash

#!/bin/bash

if [ -z ${optee_url} ];then
    exit 2
fi

# https://github.com/MYiR-Dev/myir-st-optee_os.git

if [ -z ${optee_branch} ];then
    exit 2
fi

# develop-ld25x-4.0

if [ -z ${board} ];then
    exit 2
fi

if [ -z ${optee_extra_config} ];then
    optee_extra_config=""
fi

# OP-TEE extra build options

add_extra_pkg(){
    apk add cmake py3-cryptography py3-pillow
}

fetch_optee(){
    add_extra_pkg

    if [ ! -d ${work_dir}/optee-src ];then
        git clone --depth=1 ${optee_url} -b ${optee_branch} ${work_dir}/optee-src
    fi
}

compile_optee(){
    if [ ! -d ${work_dir}/bin ];then
        mkdir ${work_dir}/bin
    fi

    ln -s /usr/bin/gcc ${work_dir}/bin/aarch64-alpine-linux-musl-cpp
    ln -s /usr/bin/objcopy ${work_dir}/bin/aarch64-alpine-linux-musl-objcopy
    ln -s /usr/bin/ar ${work_dir}/bin/aarch64-alpine-linux-musl-ar
    ln -s /usr/bin/ld.bfd ${work_dir}/bin/aarch64-alpine-linux-musl-ld.bfd
    ln -s /usr/bin/objdump ${work_dir}/bin/aarch64-alpine-linux-musl-objdump
    ln -s /usr/bin/nm ${work_dir}/bin/aarch64-alpine-linux-musl-nm
    ln -s /usr/bin/readelf ${work_dir}/bin/aarch64-alpine-linux-musl-readelf

    export PATH="$PATH:${work_dir}/bin"

    pushd ${work_dir}/optee-src
    make -j$(nproc) ARCH=arm CROSS_COMPILE_core=aarch64-alpine-linux-musl- \
                  CROSS_COMPILE_ta_arm64=aarch64-alpine-linux-musl- \
                  ${optee_extra_config}
    #cp out/arm-plat-stm32mp2/core ${work_dir}
    popd
}

work_dir="$(pwd)/build"

source ${src_dir}/boards/${board}.config

#fetch_optee
#compile_optee
