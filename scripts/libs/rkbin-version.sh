#!/bin/bash

if [ ! -z ${soc} ];then
    exit 2
fi

RKBIN_SOURCE_URL="https://github.com/rockchip-linux/rkbin.git"
RKBIN_SOURCE_VERSION="74213af1e952c4683d2e35952507133b61394862"

case "$soc" in
            rk3308)
                atf_bin="bin/rk33/rk3308_bl31_v2.27.elf"
		tpl_bin="bin/rk33/rk3308_ddr_589MHz_uart2_m1_v2.10.bin"
                shift 2
                ;;
            rk3328)
                atf_bin="bin/rk33/rk322xh_bl31_v1.49.elf"
		tpl_bin="bin/rk33/rk3328_ddr_333MHz_v1.21.bin"
		miniloader_bin="bin/rk33/rk322xh_miniloader_v2.50.bin"
                shift 2
                ;;
            rk3399)
                atf_bin="bin/rk33/rk3399_bl31_v1.36.elf"
		tpl_bin="bin/rk33/rk3399_ddr_800MHz_v1.30.bin"
		miniloader_bin="rk3399_miniloader_v1.30.bin"
                shift 2
                ;;
            rk3528)
                atf_bin="bin/rk35/rk3528_bl31_v1.20.elf"
		tpl_bin="bin/rk35/rk3528_ddr_1056MHz_v1.11.bin"
                shift 2
                ;;
            rk3566)
            	atf_bin="bin/rk35/rk3568_bl31_v1.45.elf"
		tpl_bin="bin/rk35/rk3566_ddr_1056MHz_v1.23.bin"
                shift 2
                ;;
            rk3568)
            	atf_bin="bin/rk35/rk3568_bl31_v1.45.elf"
		tpl_bin="bin/rk35/rk3568_ddr_1560MHz_v1.23.bin"
                shift 2
                ;;
            rk3576)
            	atf_bin="bin/rk35/rk3576_bl31_v1.20.elf"
		tpl_bin="bin/rk35/rk3576_ddr_lp4_2112MHz_lp5_2736MHz_v1.09.bin"
                shift 2
                ;;
            rk3588)
            	atf_bin="bin/rk35/rk3588_bl31_v1.51.elf"
		tpl_bin="bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.19.bin"
                shift 2
                ;;
            *)
                echo "Unknown SOC: $soc"
                help 2
                ;;
esac

fetch_rkbin(){
    git clone https://github.com/rockchip-linux/rkbin.git ${work_dir}/rkbin
    
    pushd ${work_dir}/rkbin
    git checkout ${RKBIN_SOURCE_VERSION}
    popd
}

#fetch_rkbin
