#!/usr/bin/env bash
#===============================================================================
# Link_NN6000V2 本地交互式编译脚本
#
# 与 local-build.sh（一键自动编译）不同，本脚本用于本地开发：
#   - 首次运行自动准备环境（克隆源码 + 安装 feeds/插件）
#   - 之后进入交互菜单，可反复 make menuconfig / kernel_menuconfig
#   - 可随时添加新插件（feed），并把改动保存回仓库配置
#
# 目录约定（可用环境变量覆盖）：
#   PROJECT_DIR  默认 $HOME/Desktop/Link_NN6000V2
#   BUILD_DIR    默认 $HOME/Desktop/imm-nss
#
# 用法：
#   ./local-dev.sh            # 进入交互菜单
#   PROJECT_DIR=/path/to/repo BUILD_DIR=/path/to/src ./local-dev.sh
#===============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -Eeuo pipefail
set -o errtrace

#-------------------------------------------------------------------------------
# 配置
#-------------------------------------------------------------------------------
PROJECT_DIR="${PROJECT_DIR:-$HOME/Desktop/Link_NN6000V2}"
BUILD_DIR="${BUILD_DIR:-$HOME/Desktop/imm-nss}"
REPO_URL="${REPO_URL:-https://github.com/VIKINGYFY/immortalwrt.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DEVICE_MODEL="link_nn6000v2_immwrt"
SCRIPT_DIR="${PROJECT_DIR}/nn6000v2/scripts"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}===== $* =====${NC}"; }

#-------------------------------------------------------------------------------
# 1. 安装编译依赖（一次性）
#-------------------------------------------------------------------------------
setup_env() {
    step "安装编译依赖（仅首次需要）"
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
        gettext git libfuse-dev libncurses5-dev libssl-dev python3 python3-pip \
        python3-setuptools rsync swig unzip wget xsltproc zlib1g-dev file \
        dos2unix subversion uuid-runtime ccache
    sudo bash -c 'bash <(curl -sL https://build-scripts.immortalwrt.org/init_build_environment.sh)' \
        || warn "官方环境脚本失败，但基础依赖已装，继续执行"
    sudo timedatectl set-timezone "Asia/Shanghai" 2>/dev/null || true
    info "依赖安装完成"
}

#-------------------------------------------------------------------------------
# 2. 克隆源码
#-------------------------------------------------------------------------------
clone_source() {
    if [[ -d "${BUILD_DIR}/.git" ]]; then
        info "源码已存在: ${BUILD_DIR}，执行 git pull 增量更新"
        git -C "${BUILD_DIR}" pull --ff-only 2>/dev/null || warn "pull 失败，使用现有代码"
        return 0
    fi
    step "克隆 ImmortalWrt 源码"
    mkdir -p "$(dirname "${BUILD_DIR}")"
    git clone --depth 1 -b "${REPO_BRANCH}" "${REPO_URL}" "${BUILD_DIR}"
    info "克隆完成"
}

#-------------------------------------------------------------------------------
# 3. 运行 update.sh（装 feeds / 插件 / 应用补丁）
#-------------------------------------------------------------------------------
run_update() {
    if [[ -f "${BUILD_DIR}/feeds/packages.index" ]]; then
        info "feeds 已安装，跳过 update.sh（如需重装请先 rm -rf ${BUILD_DIR}/feeds）"
        return 0
    fi
    step "运行 update.sh（Feeds 和插件配置）"
    chmod +x "${SCRIPT_DIR}"/*.sh
    bash "${SCRIPT_DIR}/update.sh" "${REPO_URL}" "${REPO_BRANCH}" "${BUILD_DIR}" "none"
    info "update.sh 完成"
}

#-------------------------------------------------------------------------------
# 4. 源码级修复（一次性，修改 mk/Makefile，持久生效）
#    与 build.sh 保持一致：内核 12MB、netfilter 冲突修复
#-------------------------------------------------------------------------------
apply_source_fixes() {
    step "应用源码级修复"
    cd "${BUILD_DIR}"

    # 内核大小 12MB
    local ipq60xx_mk="target/linux/qualcommax/image/ipq60xx.mk"
    if [[ -f "$ipq60xx_mk" ]]; then
        sed -i '/link_nn6000-common/,/endef/{s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/g}' "$ipq60xx_mk"
        info "KERNEL_SIZE -> 12288k (12MB)"
    fi

    # netfilter kmod 冲突修复
    local inc="include/netfilter.mk"
    local nf="package/kernel/linux/modules/netfilter.mk"
    if [[ -f "$inc" && -f "$nf" ]]; then
        sed -i 's@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables),))@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables, lt 6.12),))@' "$inc"
        sed -i 's@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_CORE,CONFIG_IP_NF_IPTABLES, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET)))@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_CORE,CONFIG_IP_NF_IPTABLES, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET, lt 6.12)))@' "$inc"
        sed -i 's@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT6,CONFIG_IP6_NF_IPTABLES, $(P_V6)ip6_tables),))@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT6,CONFIG_IP6_NF_IPTABLES, $(P_V6)ip6_tables, lt 6.12),))@' "$inc"
        sed -i 's@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_IPV6,CONFIG_IP6_NF_IPTABLES, ip6t_icmp6)))@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_IPV6,CONFIG_IP6_NF_IPTABLES, ip6t_icmp6, lt 6.12)))@' "$inc"
        sed -i 's/DEPENDS:=+!LINUX_6_12:kmod-iptables/DEPENDS:=+(!(LINUX_6_12||LINUX_6_18)):kmod-iptables/' "$nf"
        info "netfilter kmod 冲突修复已应用"
    fi
}

#-------------------------------------------------------------------------------
# 5. 用仓库默认配置初始化 .config（首次 / 重置）
#-------------------------------------------------------------------------------
seed_config() {
    step "用仓库配置初始化 .config"
    cd "${BUILD_DIR}"
    local cfg="${SCRIPT_DIR}/../configs/${DEVICE_MODEL}.config"
    if [[ ! -f "$cfg" ]]; then
        error "找不到配置文件: $cfg"
        exit 1
    fi
    cp -f "$cfg" .config
    cat "${SCRIPT_DIR}/../configs/docker_deps.config" >> .config
    make defconfig
    info ".config 已生成，可运行 make menuconfig 修改"
}

#-------------------------------------------------------------------------------
# 6. 编译前补丁（依赖 .config 内容）
#-------------------------------------------------------------------------------
prep_before_build() {
    cd "${BUILD_DIR}"
    # 若启用了 quickfile(nginx) 则移除 luci-light(uhttpd) 依赖
    local cfg_path=".config"
    local luci_mk="feeds/luci/collections/luci/Makefile"
    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$cfg_path" && [[ -f "$luci_mk" ]]; then
        sed -i '/luci-light/d' "$luci_mk"
        info "已移除 uhttpd(luci-light) 依赖"
    fi
    make defconfig
}

#-------------------------------------------------------------------------------
# 7. 编译
#-------------------------------------------------------------------------------
do_build() {
    step "编译固件"
    cd "${BUILD_DIR}"
    prep_before_build
    make download -j"$(($(nproc) * 2))"
    make -j"$(($(nproc) + 1))" || make -j1 V=s
    local out="${PROJECT_DIR}/firmware"
    mkdir -p "$out"
    find bin/targets -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*.img.gz" \) -exec cp -f {} "$out/" \;
    info "编译完成，产物在: $out"
}

#-------------------------------------------------------------------------------
# 8. 添加新插件（feed）
#-------------------------------------------------------------------------------
add_plugin() {
    cd "${BUILD_DIR}"
    read -rp "输入 feed 名称 (如 myfeed): " feed_name
    read -rp "输入 feed 地址 (src-git 链接, 如 https://github.com/xxx/openwrt-apps.git): " feed_url
    read -rp "输入要安装的包名 (如 luci-app-xxx，可留空稍后在 menuconfig 选): " pkg
    # 避免重复
    if ! grep -q "$feed_name" feeds.conf.default; then
        echo "src-git $feed_name $feed_url" >> feeds.conf.default
    fi
    ./scripts/feeds update "$feed_name"
    if [[ -n "$pkg" ]]; then
        ./scripts/feeds install -f -p "$feed_name" "$pkg"
        info "已安装 $pkg，可在 make menuconfig 中确认"
    fi
}

#-------------------------------------------------------------------------------
# 9. 保存 .config 回仓库
#-------------------------------------------------------------------------------
save_config() {
    cd "${BUILD_DIR}"
    local cfg="${SCRIPT_DIR}/../configs/${DEVICE_MODEL}.config"
    cp -f .config "$cfg"
    info "当前 .config 已保存到: $cfg"
}

#-------------------------------------------------------------------------------
# 10. 更新插件（feed）源码（手动触发）
#-------------------------------------------------------------------------------
update_feeds() {
    cd "${BUILD_DIR}"
    step "更新插件源码 (feeds update -a)"
    ./scripts/feeds update -a
    info "feeds 已更新，可运行 m 在 make menuconfig 中查看/选择新版本"
    read -rp "是否一并重新安装已选插件？(y/N): " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        ./scripts/feeds install -a
        info "已重新安装 feeds 插件"
    fi
}

#-------------------------------------------------------------------------------
# 交互菜单
#-------------------------------------------------------------------------------
interactive() {
    while true; do
        echo ""
        echo -e "${CYAN}========== 本地编译菜单 ==========${NC}"
        echo "  m   make menuconfig        (加/删插件、改软件包)"
        echo "  k   make kernel_menuconfig (改内核选项)"
        echo "  a   添加新插件 feed"
        echo "  u   更新插件（feed）源码"
        echo "  b   编译固件"
        echo "  s   保存当前 .config 回仓库配置"
        echo "  r   用仓库默认配置重置 .config"
        echo "  q   退出"
        echo -e "${CYAN}=================================${NC}"
        read -rp "请选择: " choice
        case "$choice" in
            m) cd "${BUILD_DIR}" && make menuconfig ;;
            k) cd "${BUILD_DIR}" && make kernel_menuconfig ;;
            a) add_plugin ;;
            u) update_feeds ;;
            b) do_build ;;
            s) save_config ;;
            r) seed_config ;;
            q) info "退出"; exit 0 ;;
            *) warn "未知选项: $choice" ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# 主流程
#-------------------------------------------------------------------------------
main() {
    if [[ ! -d "${PROJECT_DIR}/nn6000v2" ]]; then
        error "项目目录不存在: ${PROJECT_DIR}/nn6000v2"
        error "请先把本仓库克隆到 ${PROJECT_DIR}"
        exit 1
    fi

    echo "项目目录: ${PROJECT_DIR}"
    echo "源码目录: ${BUILD_DIR}"

    read -rp "是否安装/更新编译依赖？(y/N): " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        setup_env
    fi

    clone_source
    run_update
    apply_source_fixes

    if [[ ! -f "${BUILD_DIR}/.config" ]]; then
        seed_config
    else
        info ".config 已存在，直接复用（如需重置请选 r）"
    fi

    info "准备就绪，进入交互菜单。先 m 改配置，再 b 编译。"
    interactive
}

main "$@"
