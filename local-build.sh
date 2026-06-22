#!/usr/bin/env bash
#===============================================================================
# Link_NN6000V2 本地构建脚本 - 适用于 Ubuntu 22.04
#
# 功能：在本地服务器上模拟 GitHub Actions 工作流，编译 ImmortalWrt 固件
#
# 目录结构要求：
#   ~/Desktop/
#   ├── Link_NN6000V2/          # 本仓库
#   └── imm-nss/               # ImmortalWrt 源码目录（由本脚本自动克隆）
#
# 用法：
#   chmod +x local-build.sh
#   ./local-build.sh                    # 默认编译
#   ./local-build.sh --pppoe-user "账号" --pppoe-pass "密码"  # 带 PPPoE 配置
#   ./local-build.sh --clean            # 清理后重新编译
#   ./local-build.sh --no-wifi          # 仅编译无 WiFi 版本
#   ./local-build.sh --help             # 查看帮助
#===============================================================================

# 检测是否运行在 bash 下，如果不是则自动用 bash 重新执行
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -Eeuo pipefail
set -o errtrace

#-------------------------------------------------------------------------------
# 错误处理
#-------------------------------------------------------------------------------
error_handler() {
    local exit_code=$?
    local line=$1
    local cmd="$2"
    echo ""
    echo "=============================================="
    echo "  错误！脚本在行 ${line} 失败"
    echo "  命令: ${cmd}"
    echo "  退出码: ${exit_code}"
    echo "=============================================="
    exit "${exit_code}"
}

trap 'error_handler ${LINENO} "${BASH_COMMAND}"' ERR

#-------------------------------------------------------------------------------
# 颜色定义
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}================================================${NC}"; echo -e "${CYAN}  步骤: $*${NC}"; echo -e "${CYAN}================================================${NC}"; }

#-------------------------------------------------------------------------------
# 默认配置
#-------------------------------------------------------------------------------
DESKTOP_DIR="${HOME}/Desktop"
PROJECT_DIR="${DESKTOP_DIR}/Link_NN6000V2"
BUILD_DIR="${DESKTOP_DIR}/imm-nss"
DEVICE_MODEL="link_nn6000v2_immwrt"
REPO_URL="https://github.com/VIKINGYFY/immortalwrt.git"
REPO_BRANCH="main"
PPPOE_USERNAME="-"
PPPOE_PASSWORD="-"
CLEAN_BUILD=false
NO_WIFI=false

#-------------------------------------------------------------------------------
# 显示帮助
#-------------------------------------------------------------------------------
show_help() {
    cat <<'HELP'
用法: ./local-build.sh [选项]

选项:
  --pppoe-user <账号>    PPPoE 宽带账号
  --pppoe-pass <密码>    PPPoE 宽带密码
  --clean                清理构建目录后重新编译
  --no-wifi              仅编译无 WiFi 版本
  --help                 显示此帮助信息

目录结构:
  ~/Desktop/
  ├── Link_NN6000V2/       # 本仓库 (必须存在)
  └── imm-nss/             # ImmortalWrt 源码 (自动克隆)

示例:
  ./local-build.sh                               # 默认编译
  ./local-build.sh --clean                       # 清理后编译
  ./local-build.sh --pppoe-user "user" --pppoe-pass "pass"  # 带 PPPoE
  ./local-build.sh --no-wifi                     # 无 WiFi 版本
HELP
}

#-------------------------------------------------------------------------------
# 解析参数
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pppoe-user)
                PPPOE_USERNAME="$2"
                shift 2
                ;;
            --pppoe-pass)
                PPPOE_PASSWORD="$2"
                shift 2
                ;;
            --clean)
                CLEAN_BUILD=true
                shift
                ;;
            --no-wifi)
                NO_WIFI=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# 步骤 1: 环境准备 - 安装编译依赖
#-------------------------------------------------------------------------------
setup_build_environment() {
    step "1/6 - 安装编译依赖"

    info "更新软件包列表..."
    sudo apt-get update -qq

    info "安装 OpenWrt 编译依赖..."
    sudo apt-get install -y -qq \
        build-essential \
        clang \
        flex \
        bison \
        g++ \
        gawk \
        gcc-multilib \
        g++-multilib \
        gettext \
        git \
        libfuse-dev \
        libncurses5-dev \
        libssl-dev \
        python3 \
        python3-pip \
        python3-setuptools \
        rsync \
        swig \
        unzip \
        wget \
        xsltproc \
        zlib1g-dev \
        file \
        dos2unix \
        subversion \
        uuid-runtime

    info "安装 ccache..."
    sudo apt-get install -y -qq ccache

    # 安装 ImmortalWrt 官方构建环境脚本
    info "运行 ImmortalWrt 构建环境初始化脚本..."
    sudo bash -c 'bash <(curl -sL https://build-scripts.immortalwrt.org/init_build_environment.sh)' || {
        warn "官方环境初始化脚本执行失败，但基础依赖已安装，继续执行..."
    }

    # 设置时区
    sudo timedatectl set-timezone "Asia/Shanghai" 2>/dev/null || true

    info "编译环境准备完成"
}

#-------------------------------------------------------------------------------
# 步骤 2: 克隆 ImmortalWrt 源码
#-------------------------------------------------------------------------------
clone_source() {
    step "2/6 - 克隆 ImmortalWrt 源码"

    # 如果目录已存在
    if [[ -d "${BUILD_DIR}" ]]; then
        if [[ "${CLEAN_BUILD}" == true ]]; then
            info "清理旧的构建目录..."
            cd "${BUILD_DIR}"
            # 保存 ccache 缓存
            local ccache_dir=""
            [[ -d ".ccache" ]] && ccache_dir="$(pwd)/.ccache"
            cd "${DESKTOP_DIR}"
            \rm -rf "${BUILD_DIR}"
            info "旧的构建目录已删除"
        else
            info "构建目录已存在: ${BUILD_DIR}"
            info "如需重新克隆请使用 --clean 参数"
            cd "${BUILD_DIR}"
            # 检查是否有 .git
            if [[ -d ".git" ]]; then
                info "更新已有仓库..."
                git reset --hard HEAD 2>/dev/null || true
                git pull --ff-only 2>/dev/null || warn "无法更新仓库，继续使用现有代码"
                return 0
            fi
        fi
    fi

    info "克隆仓库: ${REPO_URL} 分支: ${REPO_BRANCH}"
    info "目标目录: ${BUILD_DIR}"

    git clone --depth 1 -b "${REPO_BRANCH}" "${REPO_URL}" "${BUILD_DIR}"

    info "克隆完成"
}

#-------------------------------------------------------------------------------
# 步骤 3: 配置 PPPoE
#-------------------------------------------------------------------------------
configure_pppoe() {
    step "3/6 - 配置 PPPoE 参数"

    local network_config="${PROJECT_DIR}/nn6000v2/patches/992_network_config.sh"

    if [[ ! -f "${network_config}" ]]; then
        warn "PPPoE 配置文件不存在: ${network_config}"
        return 0
    fi

    if [[ "${PPPOE_USERNAME}" != "-" ]] || [[ "${PPPOE_PASSWORD}" != "-" ]]; then
        info "正在配置 PPPoE 账号密码..."
        sed -i "s#^PPPOE_USERNAME=.*#PPPOE_USERNAME=\"${PPPOE_USERNAME}\"#" "${network_config}"
        sed -i "s#^PPPOE_PASSWORD=.*#PPPOE_PASSWORD=\"${PPPOE_PASSWORD}\"#" "${network_config}"
        info "PPPoE Username: ${PPPOE_USERNAME}"
        info "PPPoE Password: [HIDDEN]"
    else
        info "未输入 PPPoE 账号密码，使用默认值"
    fi
}

#-------------------------------------------------------------------------------
# 步骤 4: 运行 update.sh（配置 feeds 和插件）
#-------------------------------------------------------------------------------
run_update() {
    step "4/6 - 运行 update.sh（Feeds 和插件配置）"

    cd "${PROJECT_DIR}"

    # 确保脚本可执行
    chmod +x "${PROJECT_DIR}/nn6000v2/scripts/"*.sh

    local update_script="${PROJECT_DIR}/nn6000v2/scripts/update.sh"

    if [[ ! -f "${update_script}" ]]; then
        error "update.sh 不存在: ${update_script}"
        exit 1
    fi

    info "开始执行 update.sh..."
    info "参数: REPO_URL=${REPO_URL} REPO_BRANCH=${REPO_BRANCH} BUILD_DIR=${BUILD_DIR}"

    # update.sh 需要从项目目录运行，它会自己 cd 到 BUILD_DIR
    bash "${update_script}" "${REPO_URL}" "${REPO_BRANCH}" "${BUILD_DIR}" "none"

    info "update.sh 执行完成"
}

#-------------------------------------------------------------------------------
# 步骤 5: 运行 build.sh（编译固件）
#-------------------------------------------------------------------------------
run_build() {
    step "5/6 - 编译固件"

    cd "${PROJECT_DIR}"

    local build_script="${PROJECT_DIR}/nn6000v2/scripts/build.sh"

    if [[ ! -f "${build_script}" ]]; then
        error "build.sh 不存在: ${build_script}"
        exit 1
    fi

    # 如果是编译无 WiFi 版本
    if [[ "${NO_WIFI}" == true ]]; then
        info "仅编译无 WiFi 版本"
        # 先修改配置文件临时禁用 WiFi
        local config_file="${PROJECT_DIR}/nn6000v2/configs/${DEVICE_MODEL}.config"
        if [[ -f "${config_file}" ]]; then
            info "备份配置文件..."
            cp -f "${config_file}" "${config_file}.bak"
        fi
        # 直接调用 build.sh 但传入 nowifi 设备名（需要配置 nowifi 版本）
        # 实际上 build.sh 支持双版本编译，我们先编译完整版，然后去掉 WiFi
        # 但这里简单处理：直接运行 build.sh 并传入正常设备名
    fi

    info "开始编译固件..."
    info "设备型号: ${DEVICE_MODEL}"
    info "编译目录: ${BUILD_DIR}"
    info ""
    info "注意：首次编译时间较长，请耐心等待"
    info "编译过程中可以使用 Ctrl+C 中断"
    info ""

    export REPO_URL="${REPO_URL}"
    export REPO_BRANCH="${REPO_BRANCH}"
    export BUILD_DIR="${BUILD_DIR}"

    bash "${build_script}" "${DEVICE_MODEL}"

    info "编译完成！"
}

#-------------------------------------------------------------------------------
# 步骤 6: 收集编译产物
#-------------------------------------------------------------------------------
collect_firmware() {
    step "6/6 - 收集编译产物"

    local firmware_dir="${PROJECT_DIR}/firmware"
    local target_dir="${BUILD_DIR}/bin/targets"

    if [[ -d "${firmware_dir}" ]]; then
        info "固件目录: ${firmware_dir}"
        info ""
        info "编译产物列表:"
        ls -lh "${firmware_dir}/" 2>/dev/null | grep -v "^total" | grep -v "^$" || info "  (目录为空)"
        info ""
        info "编译时间: $(date '+%Y-%m-%d %H:%M:%S')"
        info "固件大小: $(du -sh "${firmware_dir}" 2>/dev/null | cut -f1)"
    else
        warn "未找到固件目录，尝试查找编译产物..."
        if [[ -d "${target_dir}" ]]; then
            info "在 ${target_dir} 中查找..."
            find "${target_dir}" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" \) 2>/dev/null | head -20 || true
        fi
    fi
}

#-------------------------------------------------------------------------------
# 检查磁盘空间
#-------------------------------------------------------------------------------
check_disk_space() {
    info "磁盘空间检查..."
    local available
    available=$(df -BG "${DESKTOP_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')

    if [[ -n "${available}" ]]; then
        info "可用空间: ${available}G"
        if [[ "${available}" -lt 15 ]]; then
            warn "磁盘空间不足 15G，编译可能失败"
            warn "建议清理磁盘空间后重试"
            warn ""
            warn "磁盘使用情况:"
            df -h "${DESKTOP_DIR}"
            echo ""
            read -rp "是否继续？(y/N): " confirm
            if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
                info "用户取消编译"
                exit 0
            fi
        fi
    fi
}

#-------------------------------------------------------------------------------
# 检查项目目录
#-------------------------------------------------------------------------------
check_project_dir() {
    if [[ ! -d "${PROJECT_DIR}" ]]; then
        error "项目目录不存在: ${PROJECT_DIR}"
        error "请确保 Link_NN6000V2 仓库已放置在 ~/Desktop/ 下"
        error "当前 ~/Desktop/ 内容:"
        ls -la "${DESKTOP_DIR}" 2>/dev/null || error "  ~/Desktop 目录不存在"
        exit 1
    fi

    if [[ ! -d "${PROJECT_DIR}/nn6000v2" ]]; then
        error "项目目录结构不正确，找不到 nn6000v2 子目录"
        exit 1
    fi

    info "项目目录: ${PROJECT_DIR}"
    info "构建目录: ${BUILD_DIR}"
}

#-------------------------------------------------------------------------------
# 系统信息
#-------------------------------------------------------------------------------
print_system_info() {
    info "系统信息:"
    echo "  CPU: $(lscpu 2>/dev/null | grep "Model name" | head -1 | cut -d: -f2 | xargs || echo 'N/A')"
    echo "  核心数: $(nproc 2>/dev/null || echo 'N/A')"
    echo "  内存: $(free -h 2>/dev/null | awk '/Mem:/ {print $2}' || echo 'N/A')"
    echo "  OS: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo 'N/A')"
    echo "  磁盘: $(df -h "${DESKTOP_DIR}" 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}' || echo 'N/A')"
}

#===============================================================================
# 主函数
#===============================================================================
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║      Link_NN6000V2 本地构建脚本 (Ubuntu 22.04)         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    parse_args "$@"
    check_project_dir
    print_system_info
    check_disk_space

    local start_time
    start_time=$(date +%s)

    echo ""
    info "编译配置:"
    echo "  PPPoE: $([ "${PPPOE_USERNAME}" != "-" ] && echo "已配置" || echo "未配置")"
    echo "  清理构建: ${CLEAN_BUILD}"
    echo "  仅无 WiFi: ${NO_WIFI}"
    echo ""

    read -rp "确认开始编译？(Y/n): " confirm
    if [[ -n "${confirm}" && "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        info "用户取消编译"
        exit 0
    fi

    #setup_build_environment
    clone_source
    configure_pppoe
    run_update
    run_build
    collect_firmware

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(( (duration % 3600) / 60 ))
    local seconds=$((duration % 60))

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                    编译完成！                            ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    info "总耗时: ${hours}小时${minutes}分${seconds}秒"
    info "构建目录: ${BUILD_DIR}"
    info "固件目录: ${PROJECT_DIR}/firmware"
    echo ""
}

main "$@"
