#!/bin/bash
# docker-manager.sh - Docker 一站式管理脚本（增强完整版）
# 版本：v3.1（完善功能版）

# ==================== 配置变量（可外部修改）====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/docker-manager.conf"
LOG_FILE="${HOME}/.docker-manager.log"  # 改为用户目录
LOG_MAX_SIZE=10485760  # 10MB
LOG_BACKUP_COUNT=3

# 可配置路径（默认值）
NPM_DATA_DIR="/opt/nginxpm"
NPM_IMAGE="jc21/nginx-proxy-manager:latest"
PORTAINER_IMAGE="portainer/portainer-ce:latest"
DPANEL_IMAGE="dpanel/dpanel:latest"

# 脚本配置
EXPERT_MODE=false
AUTO_CLEAN=false
LOG_LEVEL="info"
MIRROR="aliyun"

# 国内镜像源（用户可选）
MIRROR_LIST=(
    "阿里云镜像源|https://mirrors.aliyun.com/ubuntu/"
    "华为云镜像源|https://repo.huaweicloud.com/ubuntu/"
    "腾讯云镜像源|https://mirrors.cloud.tencent.com/ubuntu/"
    "清华镜像源|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
    "中科大镜像源|https://mirrors.ustc.edu.cn/ubuntu/"
    "官方源|http://archive.ubuntu.com/ubuntu/"
)

# 如果存在配置文件则覆盖默认值
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# ==================== 初始化 ====================
# 更准确的颜色检测
detect_color_support() {
    # 检查是否在终端中运行
    if [ -t 1 ]; then
        # 检查 TERM 环境变量
        if [ -n "$TERM" ] && [ "$TERM" != "dumb" ]; then
            # 检查颜色支持能力
            if tput colors >/dev/null 2>&1; then
                # 检查是否支持至少8种颜色
                local colors=$(tput colors 2>/dev/null || echo 0)
                if [ "$colors" -ge 8 ]; then
                    USE_COLOR=true
                else
                    USE_COLOR=false
                fi
            else
                USE_COLOR=false
            fi
        else
            USE_COLOR=false
        fi
    else
        USE_COLOR=false
    fi
    
    # 可以通过环境变量强制启用/禁用颜色
    if [ -n "$FORCE_COLOR" ]; then
        if [ "$FORCE_COLOR" = "1" ] || [ "$FORCE_COLOR" = "true" ]; then
            USE_COLOR=true
        elif [ "$FORCE_COLOR" = "0" ] || [ "$FORCE_COLOR" = "false" ]; then
            USE_COLOR=false
        fi
    fi
    
    export USE_COLOR
}

# 初始化颜色检测
detect_color_support

# 获取终端宽度
if [ "$USE_COLOR" = true ] && tput cols >/dev/null 2>&1; then
    TERM_WIDTH=$(tput cols)
    [ -z "$TERM_WIDTH" ] && TERM_WIDTH=80
else
    TERM_WIDTH=80
fi

[ $TERM_WIDTH -lt 60 ] && TERM_WIDTH=60
[ $TERM_WIDTH -gt 120 ] && TERM_WIDTH=120

# ==================== 颜色定义（改进版）====================
if [ "$USE_COLOR" = true ]; then
    # 使用最兼容的格式
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    GRAY='\033[0;37m'
    BOLD='\033[1m'
    UNDERLINE='\033[4m'
    NC='\033[0m' # No Color
    # 闪烁效果（用于危险操作）
    if tput blink >/dev/null 2>&1; then
        BLINK='\033[5m'
    else
        BLINK=''
    fi
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; CYAN=''; GRAY=''
    BOLD=''; UNDERLINE=''; NC=''; BLINK=''
fi

# ==================== 全局缓存变量 ====================
# 状态缓存
declare -A CACHE_STATUS
CACHE_STATUS["last_update"]=0
CACHE_STATUS["docker_installed"]=false
CACHE_STATUS["compose_installed"]=false
CACHE_STATUS["portainer_installed"]=false
CACHE_STATUS["npm_installed"]=false
CACHE_STATUS["dpanel_installed"]=false
CACHE_STATUS["docker_version"]=""
CACHE_STATUS["compose_version"]=""
CACHE_STATUS["container_list"]=""
CACHE_STATUS["last_operation"]=""
CACHE_STATUS["problems"]=""
CACHE_STATUS["warnings"]=""

# 菜单缓存
MENU_CACHE=()

# ==================== 基础工具函数 ====================

# 修改 check_root 函数，更智能地检查权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        printf "${RED}${BOLD}[✗] 请使用 sudo 或 root 用户运行此脚本${NC}\n"
        exit 1
    fi
    # 如果是通过 sudo 运行的，获取原始用户
    if [ -n "$SUDO_USER" ]; then
        ORIGINAL_USER="$SUDO_USER"
    else
        ORIGINAL_USER="root"
    fi
}

# ==================== 新增：安装日志记录 ====================
log_install_step() {
    local component="$1"
    local step="$2"
    local status="$3"  # "start", "success", "error"
    local message="${4:-}"
    
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_msg="[$timestamp] INSTALL $component - 步骤: $step - 状态: $status"
    [ -n "$message" ] && log_msg+=" - $message"
    
    echo "$log_msg" >> "$LOG_FILE"
    
    case $status in
        "start") printf "${CYAN}[→]${NC} %s\n" "$step" ;;
        "success") printf "${GREEN}[✓]${NC} %s\n" "$step" ;;
        "error") printf "${RED}[✗]${NC} %s\n" "$step" ;;
    esac
}

# 简化进度跟踪
simple_progress() {
    local task="$1"
    local func="$2"
    
    printf "${CYAN}[ℹ]${NC} 开始: $task\n"
    if $func; then
        printf "${GREEN}[✓]${NC} 完成: $task\n"
        return 0
    else
        printf "${RED}[✗]${NC} 失败: $task\n"
        return 1
    fi
}

# 检测命令是否存在
command_exists() {
    type "$1" &> /dev/null
}

# 检测 systemd
has_systemd() {
    [ -d /run/systemd/system ]
}

# 带超时的命令执行
run_with_timeout() {
    local timeout=$1
    local cmd=$2
    local result
    
    timeout $timeout bash -c "$cmd" 2>/dev/null
    result=$?
    
    if [ $result -eq 124 ]; then
        print_warning "命令执行超时（${timeout}秒）"
        return 1
    fi
    return $result
}

# 等待用户确认（带倒计时）
confirm_with_timeout() {
    local message="$1"
    local timeout="${2:-10}"
    local default="${3:-N}"
    
    printf "${YELLOW}${message}${NC}\n"
    printf "${GRAY}(${timeout}秒后自动选择: ${default})${NC}\n"
    
    for ((i=timeout; i>0; i--)); do
        printf "\r[%02d] 输入 Y/n: " $i
        read -t 1 -n 1 choice 2>/dev/null || true
        if [ -n "$choice" ]; then
            echo
            [[ $choice =~ ^[Yy]$ ]]
            return $?
        fi
    done
    
    echo
    [[ $default =~ ^[Yy]$ ]]
    return $?
}

# 危险操作确认
confirm_danger() {
    local operation="$1"
    local message="$2"
    local confirm_word="${3:-DESTROY}"
    
    printf "\n${RED}${BLINK}⚠️  危险操作警告！${NC}\n"
    printf "${RED}${BOLD}${operation}${NC}\n"
    printf "${RED}${message}${NC}\n"
    printf "\n"
    read -p "请输入 '${confirm_word}' 确认操作: " confirm
    
    if [ "$confirm" = "$confirm_word" ]; then
        return 0
    else
        printf "${YELLOW}操作已取消${NC}\n"
        return 1
    fi
}

# ==================== 新增：进度条显示函数 ====================
show_progress_bar() {
    local current="$1"
    local total="$2"
    local message="${3:-安装进度}"
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))
    
    # 构建进度条
    local progress_bar="["
    for ((i=0; i<completed; i++)); do
        progress_bar+="${GREEN}█${NC}"
    done
    for ((i=0; i<remaining; i++)); do
        progress_bar+="${GRAY}░${NC}"
    done
    progress_bar+="]"
    
    printf "\r${CYAN}[ℹ]${NC} %-30s %s %3d%% (%d/%d)" "$message" "$progress_bar" "$percentage" "$current" "$total"
}

show_step_progress() {
    local step_num="$1"
    local total_steps="$2"
    local message="$3"
    local status="$4"  # "start", "success", "error"
    
    case $status in
        "start")
            printf "\n${CYAN}[→]${NC} 步骤 %d/%d: %s..." "$step_num" "$total_steps" "$message"
            ;;
        "success")
            printf "\r${GREEN}[✓]${NC} 步骤 %d/%d: %s 完成\n" "$step_num" "$total_steps" "$message"
            ;;
        "error")
            printf "\r${RED}[✗]${NC} 步骤 %d/%d: %s 失败\n" "$step_num" "$total_steps" "$message"
            ;;
    esac
}

# 增强版安装进度跟踪
track_install_progress() {
    local component="$1"
    local total_steps="$2"
    local step_func="$3"
    local progress_pid=""
    
    printf "\n${BOLD}开始安装 $component...${NC}\n"
    
    # 创建临时进度指示器
    (
        local dots=0
        while true; do
            local dot_str=""
            for ((i=0; i<dots; i++)); do
                dot_str+="."
            done
            printf "\r${GRAY}等待中$dot_str   ${NC}"
            sleep 0.5
            dots=$(((dots + 1) % 4))
        done
    ) &
    
    progress_pid=$!
    disown $progress_pid
    
    # 执行安装函数
    local result=1
    $step_func && result=0
    
    # 停止进度指示器
    kill $progress_pid 2>/dev/null
    
    if [ $result -eq 0 ]; then
        printf "\r${GREEN}[✓] $component 安装完成！${NC}\n"
        return 0
    else
        printf "\r${RED}[✗] $component 安装失败！${NC}\n"
        return 1
    fi
}

# ==================== 日志函数 ====================
setup_log_rotation() {
    [ ! -f "$LOG_FILE" ] && return 0
    
    if [ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $LOG_MAX_SIZE ]; then
        for ((i=LOG_BACKUP_COUNT-1; i>=0; i--)); do
            if [ $i -eq 0 ]; then
                mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
            elif [ -f "${LOG_FILE}.$i" ]; then
                mv -f "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))" 2>/dev/null || true
            fi
        done
        find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*" -type f | \
            sort -r | tail -n +$((LOG_BACKUP_COUNT+1)) | xargs rm -f 2>/dev/null || true
    fi
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    setup_log_rotation
    
    local clean_message=$(echo "$message" | sed -r "s/\x1B\[[0-9;]*[mK]//g")
    echo "[$timestamp] [$level] $clean_message" >> "$LOG_FILE"
    
    case $level in
        "ERROR") printf "${RED}${BOLD}[✗]${NC} %s\n" "$message" ;;
        "WARN") printf "${YELLOW}[⚠]${NC} %s\n" "$message" ;;
        "INFO") printf "${CYAN}[ℹ]${NC} %s\n" "$message" ;;
        "SUCCESS") printf "${GREEN}${BOLD}[✓]${NC} %s\n" "$message" ;;
        *) printf "[?] %s\n" "$message" ;;
    esac
}

print_success() { log_message "SUCCESS" "$1"; }
print_warning() { log_message "WARN" "$1"; }
print_error() { log_message "ERROR" "$1"; }
print_info() { log_message "INFO" "$1"; }

# ==================== 显示函数 ====================
print_menu_option() {
    local number="$1"
    local text="$2"
    local comment="$3"
    
    # 使用 printf 而不是 echo，因为 printf 会解析转义序列
    printf "%s) %-20s ${GRAY}← %s${NC}\n" "$number" "$text" "$comment"
}

print_header() {
    local title="$1"
    local width=$((TERM_WIDTH - 4))
    local title_len=${#title}
    local padding_left=$(( (width - title_len) / 2 ))
    local padding_right=$(( width - title_len - padding_left ))
    
    printf "\n${BLUE}${BOLD}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}\n"
    printf "${BLUE}${BOLD}│$(printf ' %.0s' $(seq 1 $padding_left))$title$(printf ' %.0s' $(seq 1 $padding_right))│${NC}\n"
    printf "${BLUE}${BOLD}└$(printf '─%.0s' $(seq 1 $width))┘${NC}\n"
}

print_menu_header() {
    local title="$1"
    local width=$((TERM_WIDTH - 4))
    
    # 清理标题中的颜色代码以计算长度
    local clean_title=$(echo "$title" | sed -r "s/\x1B\[[0-9;]*[mK]//g")
    local title_len=${#clean_title}
    local padding_left=$(( (width - title_len) / 2 ))
    local padding_right=$(( width - title_len - padding_left ))
    
    printf "\n${PURPLE}${BOLD}╔$(printf '═%.0s' $(seq 1 $width))╗${NC}\n"
    printf "${PURPLE}${BOLD}║$(printf ' %.0s' $(seq 1 $padding_left))${title}$(printf ' %.0s' $(seq 1 $padding_right))║${NC}\n"
    printf "${PURPLE}${BOLD}╚$(printf '═%.0s' $(seq 1 $width))╝${NC}\n"
}

print_help_box() {
    printf "\n${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}${BOLD}║        🚀 Docker 管理中心 - 帮助        ║${NC}\n"
    printf "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}\n"
    
    printf "\n${BOLD}✨ 脚本特点：${NC}\n"
    printf "  ┌──────────────────────────────────────┐\n"
    printf "  │  🐳  Docker 一站式管理工具          │\n"
    printf "  │  📊  实时状态检测与缓存             │\n"
    printf "  │  🎨  彩色终端界面与进度显示         │\n"
    printf "  │  📝  详细操作日志记录               │\n"
    printf "  │  🔧  智能诊断与自动修复             │\n"
    printf "  │  🛡️  安全确认与防误操作             │\n"
    printf "  │  ⚡  支持非交互式命令行操作         │\n"
    printf "  └──────────────────────────────────────┘\n"
    
    printf "\n${BOLD}📋 核心功能：${NC}\n"
    printf "  ${GREEN}✓${NC} 安装配置：Docker + Portainer + NPM + DPanel\n"
    printf "  ${GREEN}✓${NC} 应用管理：密码重置/容器管理/服务控制\n"
    printf "  ${GREEN}✓${NC} 容器操作：启动/停止/重启/日志/终端\n"
    printf "  ${GREEN}✓${NC} 日常维护：清理/监控/备份/快照\n"
    printf "  ${GREEN}✓${NC} 诊断修复：权限/镜像源/Docker 服务\n"
    printf "  ${GREEN}✓${NC} 网络工具：IP/网关/DNS 管理配置\n"
    printf "  ${GREEN}✓${NC} 高级工具：专家模式/系统信息/配置编辑\n"
    
    printf "\n${BOLD}🚀 快速开始：${NC}\n"
    printf "  ${BOLD}1.${NC} 新手入门 → 选【1】一键安装全部\n"
    printf "  ${BOLD}2.${NC} 日常管理 → 用【2】管理应用服务\n"
    printf "  ${BOLD}3.${NC} 故障排除 → 进【5】诊断与修复\n"
    printf "  ${BOLD}4.${NC} 网络配置 → 用【6】调整IP/DNS\n"
    printf "  ${BOLD}5.${NC} 高级操作 → 按【e】启用专家模式\n"
    
    printf "\n${BOLD}⌨️  快捷键大全：${NC}\n"
    printf "  ${CYAN}${BOLD}h${NC} / ${CYAN}${BOLD}?${NC}  → 显示本帮助\n"
    printf "  ${CYAN}${BOLD}e${NC}         → 切换专家模式\n"
    printf "  ${CYAN}${BOLD}q${NC}         → 退出脚本\n"
    printf "  ${CYAN}${BOLD}..${NC}        → 返回上级菜单\n"
    printf "  ${CYAN}${BOLD}Enter${NC}     → 确认/继续\n"
    
    printf "\n${BOLD}⚙️  配置信息：${NC}\n"
    printf "  📁 配置文件: ${GRAY}~/.docker-manager.conf${NC}\n"
    printf "  📄 日志文件: ${GRAY}$LOG_FILE${NC}\n"
    printf "  🔄 自动更新: ${GRAY}菜单4 → 选项5${NC}\n"
    
    printf "\n${YELLOW}${BOLD}💡 提示：${NC}\n"
    printf "  • 按 ${BOLD}e${NC} 键可在普通/专家模式间切换\n"
    printf "  • 所有危险操作均有二次确认保护\n"
    printf "  • 详细日志有助于故障排查\n"
    
    printf "\n${GREEN}${BOLD}🎯 最佳实践：${NC}\n"
    printf "  1. 首次使用前备份重要数据\n"
    printf "  2. 定期使用【4】日常维护清理资源\n"
    printf "  3. 重要变更前使用【4】导出快照\n"
    printf "  4. 遇到问题时先查看【5】诊断与修复\n"
    printf "  5. 网络配置问题使用【6】网络工具排查\n"
    printf "  6. 开启专家模式获取更多高级功能\n"
    
    printf "\n"
    printf "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${GRAY}版本: v3.1 | 设计: 简洁高效 | 目标: 让 Docker 管理更轻松${NC}\n"
    
    printf "\n"
    read -p "按 Enter 键继续..."
}

# 进度显示
show_progress() {
    local message="$1"
    local pid=""
    
    printf "${CYAN}[ℹ]${NC} $message "
    
    # 启动旋转动画
    (
        while true; do
            for c in \\ \| / -; do
                echo -ne "\b$c"
                sleep 0.1
            done
        done
    ) &
    
    pid=$!
    disown $pid
    echo $pid
}

stop_progress() {
    local pid="$1"
    [ -n "$pid" ] && kill $pid 2>/dev/null
    printf "\b ${GREEN}✓${NC}\n"
}

# ==================== 状态检测函数（带缓存）====================
# 修复状态检测模块
update_status_cache() {
    local now=$(date +%s)
    local cache_age=$((now - CACHE_STATUS["last_update"]))
    
    # 缓存有效期：5秒
    if [ $cache_age -lt 5 ] && [ "${CACHE_STATUS["docker_installed"]}" != "" ]; then
        return 0
    fi
    
    # 重置缓存
    CACHE_STATUS["docker_installed"]=false
    CACHE_STATUS["compose_installed"]=false
    CACHE_STATUS["portainer_installed"]=false
    CACHE_STATUS["npm_installed"]=false
    CACHE_STATUS["dpanel_installed"]=false
    CACHE_STATUS["docker_version"]=""
    CACHE_STATUS["compose_version"]=""
    CACHE_STATUS["container_list"]=""
    CACHE_STATUS["last_operation"]=""
    CACHE_STATUS["problems"]=""
    CACHE_STATUS["warnings"]=""
    
    # === 新增缓存项 ===
    CACHE_STATUS["docker_info"]=""          # Docker 详细信息
    CACHE_STATUS["disk_usage"]=""           # 磁盘使用情况
    CACHE_STATUS["memory_info"]=""          # 内存信息
    CACHE_STATUS["system_load"]=""          # 系统负载
    
    # 检测 Docker
    if command_exists docker; then
        CACHE_STATUS["docker_installed"]=true
        CACHE_STATUS["docker_version"]=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "未知")
        CACHE_STATUS["container_list"]=$(docker ps -a --format '{{.Names}}' 2>/dev/null || echo "")
        
        # === 新增：缓存 Docker 详细信息 ===
        CACHE_STATUS["docker_info"]=$(docker info --format 'json' 2>/dev/null | head -20 || echo "")
        
        # === 新增：缓存磁盘使用情况（Docker专用）===
        CACHE_STATUS["disk_usage"]=$(docker system df --format 'table {{.Type}}\t{{.TotalCount}}\t{{.Size}}' 2>/dev/null || echo "")
        
        # 检测 Portainer
        if docker ps -a --format '{{.Names}}' | grep -q portainer; then
            CACHE_STATUS["portainer_installed"]=true
        fi
        
        # 检测 NPM
        if docker ps -a --format '{{.Names}}' | grep -q nginx-proxy-manager; then
            CACHE_STATUS["npm_installed"]=true
        fi
        
        # 检测 DPanel
        if docker ps -a --format '{{.Names}}' | grep -q dpanel; then
            CACHE_STATUS["dpanel_installed"]=true
        fi
    fi
    
    # 检测 Docker Compose
    if command_exists docker-compose; then
        CACHE_STATUS["compose_installed"]=true
        CACHE_STATUS["compose_version"]=$(docker-compose --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
    elif command_exists docker; then
        # 检查是否安装了 Docker Compose Plugin
        if docker compose version >/dev/null 2>&1; then
            CACHE_STATUS["compose_installed"]=true
            CACHE_STATUS["compose_version"]=$(docker compose version 2>/dev/null | awk '{print $4}')
        fi
    fi
    
    # === 新增：缓存系统信息 ===
    CACHE_STATUS["system_load"]=$(uptime | awk -F'load average:' '{print $2}' | tr -d ' ' 2>/dev/null || echo "未知")
    CACHE_STATUS["memory_info"]=$(free -m 2>/dev/null | awk 'NR==2 {printf "总:%dMB 用:%dMB 剩:%dMB", $2, $3, $7}' || echo "未知")
    
    CACHE_STATUS["last_update"]=$now
}

show_current_status() {
    update_status_cache
    
    printf "\n"
    print_header "系统状态"
    
    # 系统信息
    if command_exists lsb_release; then
        OS_INFO=$(lsb_release -ds 2>/dev/null)
    else
        OS_INFO=$(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' | head -1)
    fi
    
    # 修改这些echo为printf
    printf "${BOLD}系统:${NC} ${OS_INFO:-未知}\n"
    printf "${BOLD}用户:${NC} ${SUDO_USER:-$(whoami)}\n"
    printf "${BOLD}主机:${NC} $(hostname)\n"
    printf "\n"
    
    # 问题显示
    if [ -n "${CACHE_STATUS["problems"]}" ]; then
        printf "${RED}${BOLD}⚠ 发现问题：${NC}\n"
        IFS='|' read -ra problems <<< "${CACHE_STATUS["problems"]}"
        for problem in "${problems[@]}"; do
            [ -n "$problem" ] && printf "  ${RED}•${NC} $problem\n"
        done
        printf "\n"
    fi
    
    # Docker 状态
    printf "${BOLD}🐳 Docker 状态${NC}\n"
    if [ "${CACHE_STATUS["docker_installed"]}" = true ]; then
        printf "  ${GREEN}✅${NC} Docker: ${CACHE_STATUS["docker_version"]}\n"
        printf "  ${GREEN}✅${NC} Compose: ${CACHE_STATUS["compose_version"]}\n"
        
        # 服务状态
        local service_status="未知"
        if has_systemd && systemctl is-active --quiet docker 2>/dev/null; then
            service_status="运行中"
        elif [ -S /var/run/docker.sock ]; then
            service_status="运行中"
        else
            service_status="未运行"
        fi
        printf "  ${BOLD}↳${NC} 服务: $service_status\n"
    else
        printf "  ${RED}❌${NC} Docker 未安装\n"
    fi
    printf "\n"
    
    # 容器状态
    printf "${BOLD}📦 容器状态${NC}\n"
    if [ "${CACHE_STATUS["portainer_installed"]}" = true ]; then
        printf "  ${GREEN}✅${NC} Portainer\n"
    fi
    if [ "${CACHE_STATUS["npm_installed"]}" = true ]; then
        printf "  ${GREEN}✅${NC} Nginx Proxy Manager\n"
    fi
    if [ "${CACHE_STATUS["dpanel_installed"]}" = true ]; then
        printf "  ${GREEN}✅${NC} DPanel\n"
    fi
    if [ "${CACHE_STATUS["portainer_installed"]}" = false ] && [ "${CACHE_STATUS["npm_installed"]}" = false ] && [ "${CACHE_STATUS["dpanel_installed"]}" = false ]; then
        printf "  ${YELLOW}⚠${NC} 无容器运行\n"
    fi
    
    # 上次操作
    if [ -n "${CACHE_STATUS["last_operation"]}" ]; then
        printf "\n${CYAN}📝 上次操作:${NC} ${CACHE_STATUS["last_operation"]}\n"
    fi
}

# ==================== 密码重置功能 ====================
reset_nginxpm_password() {
    print_menu_header "重置 Nginx Proxy Manager 密码"
    
    if [ "${CACHE_STATUS["npm_installed"]}" = false ]; then
        print_error "Nginx Proxy Manager 未安装"
        return 1
    fi
    
    printf "请选择重置方式：\n"
    printf "1) 通过数据库重置（推荐）\n"
    printf "2) 通过命令行重置\n"
    printf "3) 返回\n"
    
    read -p "请选择 (1-3): " method
    
    case $method in
        1)
            print_info "通过数据库重置密码..."
            
            # 检查SQLite3是否可用
            if ! command_exists sqlite3; then
                print_warning "未安装 sqlite3，尝试安装..."
                apt-get update > /dev/null 2>&1
                apt-get install -y sqlite3 > /dev/null 2>&1 || {
                    print_error "无法安装 sqlite3"
                    return 1
                }
            fi
            
            local db_path="$NPM_DATA_DIR/data/database.sqlite"
            if [ ! -f "$db_path" ]; then
                print_error "数据库文件未找到: $db_path"
                return 1
            fi
            
            read -p "请输入新密码: " -s new_password
            echo
            read -p "请再次输入新密码: " -s confirm_password
            echo
            
            if [ "$new_password" != "$confirm_password" ]; then
                print_error "两次输入的密码不一致"
                return 1
            fi
            
            if [ -z "$new_password" ]; then
                print_error "密码不能为空"
                return 1
            fi
            
            # 生成密码哈希（NPM使用bcrypt）
            print_info "生成密码哈希..."
            local password_hash=$(docker exec nginx-proxy-manager /bin/sh -c "echo -n '$new_password' | bcrypt 2>/dev/null || echo 'changeme'")
            
            if [ "$password_hash" = "changeme" ]; then
                print_warning "无法生成bcrypt哈希，使用简单MD5哈希"
                password_hash=$(echo -n "$new_password" | md5sum | awk '{print $1}')
            fi
            
            # 更新数据库
            print_info "更新数据库..."
            sqlite3 "$db_path" "UPDATE user SET password = '$password_hash' WHERE id = 1;" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                print_success "密码重置成功！"
                print_info "新密码: $new_password"
                print_info "请重启NPM容器使更改生效"
                
                if confirm_with_timeout "是否立即重启NPM容器？" 5 "Y"; then
                    docker restart nginx-proxy-manager && print_success "容器已重启"
                fi
            else
                print_error "数据库更新失败"
                return 1
            fi
            ;;
        2)
            print_info "通过命令行重置密码..."
            printf "NPM默认账号: admin@example.com\n"
            printf "默认密码: changeme\n"
            echo ""
            print_info "请登录NPM Web界面(端口81)后手动修改密码"
            print_info "如果忘记密码，建议使用数据库重置方式"
            ;;
        3) return 0 ;;
        *) print_error "无效选择" ;;
    esac
}

# ==================== 添加修复 root 权限的函数 ====================
fix_root_docker_permission() {
    print_menu_header "修复 Docker 权限"
    
    printf "${YELLOW}注意：root 用户通常已经有权限管理 Docker${NC}\n"
    printf "\n"
    printf "root 用户权限状态：\n"
    
    # 检查 root 是否有权限
    if docker info >/dev/null 2>&1; then
        print_success "✓ root 用户已经有 Docker 权限"
        return 0
    else
        print_error "✗ root 用户无法访问 Docker"
        printf "\n"
        printf "可能的原因：\n"
        printf "  1. Docker 服务未运行\n"
        printf "  2. Docker socket 权限问题\n"
        printf "  3. 系统配置问题\n"
        printf "\n"
        
        if confirm_with_timeout "是否尝试修复 root 用户的 Docker 权限？" 10 "Y"; then
            print_info "检查 Docker 服务状态..."
            if has_systemd; then
                if systemctl is-active --quiet docker; then
                    print_success "Docker 服务正在运行"
                else
                    print_warning "Docker 服务未运行，尝试启动..."
                    systemctl start docker
                fi
            fi
            
            print_info "检查 Docker socket 权限..."
            if [ -S /var/run/docker.sock ]; then
                local socket_perm=$(stat -c "%a %U:%G" /var/run/docker.sock)
                printf "  Socket 权限: $socket_perm\n"
                
                # 如果 root 是所有者，应该没问题
                if [ "$(stat -c "%U" /var/run/docker.sock)" = "root" ]; then
                    print_success "root 是 Docker socket 的所有者"
                else
                    print_warning "root 不是 Docker socket 的所有者"
                    printf "  当前所有者: $(stat -c "%U:%G" /var/run/docker.sock)\n"
                fi
            else
                print_error "Docker socket 不存在"
            fi
            
            print_info "测试 Docker 命令..."
            if docker info >/dev/null 2>&1; then
                print_success "✓ root 用户 Docker 权限已修复"
            else
                print_error "✗ 无法修复，请手动检查"
                printf "尝试运行: sudo systemctl restart docker\n"
                printf "或检查: ls -la /var/run/docker.sock\n"
            fi
        fi
    fi
}

reset_portainer_password() {
    print_menu_header "重置 Portainer 密码"
    
    if [ "${CACHE_STATUS["portainer_installed"]}" = false ]; then
        print_error "Portainer 未安装"
        return 1
    fi
    
    printf "Portainer 密码重置方式：\n"
    printf "1) 通过Web界面重置（推荐）\n"
    printf "2) 通过命令行重置\n"
    printf "3) 返回\n"
    
    read -p "请选择 (1-3): " method
    
    case $method in
        1)
            print_info "通过Web界面重置密码："
            printf "1. 访问 Portainer Web界面 (默认端口: 9000)\n"
            printf "2. 点击 'Forgot your password?' 链接\n"
            printf "3. 输入管理员邮箱\n"
            printf "4. 按照邮件指示重置密码\n"
            printf "\n"
            print_info "如果无法收到邮件，请检查邮件配置或使用命令行方式"
            ;;
        2)
            print_info "通过命令行重置密码..."
            
            # 检查jq是否可用
            if ! command_exists jq; then
                print_warning "未安装 jq，尝试安装..."
                apt-get update > /dev/null 2>&1
                apt-get install -y jq > /dev/null 2>&1 || {
                    print_error "无法安装 jq"
                    return 1
                }
            fi
            
            read -p "请输入新密码: " -s new_password
            echo
            read -p "请再次输入新密码: " -s confirm_password
            echo
            
            if [ "$new_password" != "$confirm_password" ]; then
                print_error "两次输入的密码不一致"
                return 1
            fi
            
            if [ -z "$new_password" ]; then
                print_error "密码不能为空"
                return 1
            fi
            
            # 获取Portainer API令牌
            print_info "获取API令牌..."
            local token_response=$(curl -s -X POST \
                -H "Content-Type: application/json" \
                -d '{"username":"admin","password":"admin"}' \
                http://localhost:9000/api/auth 2>/dev/null)
            
            local token=$(echo "$token_response" | jq -r '.jwt' 2>/dev/null)
            
            if [ -z "$token" ] || [ "$token" = "null" ]; then
                print_warning "使用默认凭据失败，尝试其他方式..."
                
                # 尝试从数据卷获取用户信息
                local portainer_volume_path=$(docker volume inspect portainer_data --format '{{.Mountpoint}}' 2>/dev/null)
                if [ -n "$portainer_volume_path" ]; then
                    print_info "尝试从数据卷重置..."
                    local user_file="$portainer_volume_path/portainer.db"
                    
                    if [ -f "$user_file" ]; then
                        # 这是一个简化示例，实际Portainer使用BoltDB
                        print_info "找到用户数据库文件，建议手动编辑或重新安装"
                        print_info "或者使用Web界面忘记密码功能"
                    fi
                fi
                
                print_error "无法自动重置，请使用Web界面忘记密码功能"
                return 1
            fi
            
            # 更新密码
            print_info "更新密码..."
            local update_response=$(curl -s -X PUT \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -d "{\"password\":\"$new_password\",\"confirmPassword\":\"$new_password\"}" \
                http://localhost:9000/api/users/1/passwd 2>/dev/null)
            
            if echo "$update_response" | grep -q "success"; then
                print_success "密码重置成功！"
                print_info "新密码: $new_password"
            else
                print_error "密码更新失败"
                return 1
            fi
            ;;
        3) return 0 ;;
        *) print_error "无效选择" ;;
    esac
}

# ==================== DPanel 安装与管理函数 ====================
install_dpanel() {
    print_menu_header "安装 DPanel"
    
    update_status_cache
    if [ "${CACHE_STATUS["docker_installed"]}" = false ]; then
        print_error "Docker 未安装"
        return 1
    fi
    
    if [ "${CACHE_STATUS["dpanel_installed"]}" = true ]; then
        print_warning "DPanel 已安装"
        return 0
    fi
    
    # 检查端口占用
    local port=7800
    if command_exists ss && ss -tuln | grep -q ":7800 "; then
        print_warning "端口 7800 已被占用"
        read -p "请输入新的 DPanel 端口号 (默认: 7801): " custom_port
        port=${custom_port:-7801}
    fi
    
    # 启动 Docker 服务
    if has_systemd && ! systemctl is-active --quiet docker 2>/dev/null; then
        systemctl start docker || {
            print_error "无法启动 Docker 服务"
            return 1
        }
    fi
    
    local progress_pid=$(show_progress "正在拉取 DPanel 镜像...")
    docker pull "$DPANEL_IMAGE" > /dev/null 2>&1 || {
        stop_progress "$progress_pid"
        print_error "DPanel 镜像拉取失败"
        return 1
    }
    stop_progress "$progress_pid"
    
    progress_pid=$(show_progress "正在创建数据卷...")
    docker volume create dpanel_data 2>/dev/null || print_warning "dpanel_data 卷已存在"
    stop_progress "$progress_pid"
    
    progress_pid=$(show_progress "正在启动 DPanel 容器...")
    docker run -d \
        --name=dpanel \
        --restart=always \
        -p ${port}:7800 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v dpanel_data:/app/data \
        "$DPANEL_IMAGE" > /dev/null 2>&1 || {
            stop_progress "$progress_pid"
            print_error "DPanel 容器启动失败"
            return 1
        }
    stop_progress "$progress_pid"
        
    print_success "DPanel 安装完成！"
    print_info "访问地址: ${BOLD}http://服务器IP:${port}${NC}"
    print_info "首次登录需要设置管理员账号"
    
    CACHE_STATUS["last_operation"]="安装 DPanel ($(date '+%H:%M'))"
    CACHE_STATUS["last_update"]=0
    return 0
}

uninstall_dpanel() {
    print_menu_header "卸载 DPanel"
    
    printf "${RED}警告：此操作将删除 DPanel 所有数据！${NC}\n"
    printf "\n"
    printf "将清理以下内容：\n"
    printf "  ▪ DPanel 容器\n"
    printf "  ▪ dpanel_data 数据卷\n"
    printf "  ▪ DPanel 镜像\n"
    printf "\n"
    
    if ! confirm_with_timeout "确定要卸载吗？" 10 "N"; then
        print_info "取消卸载"
        return 0
    fi
    
    print_info "停止容器..."
    docker stop dpanel 2>/dev/null || true
    print_info "删除容器..."
    docker rm -f dpanel 2>/dev/null || true
    print_info "删除数据卷..."
    docker volume rm -f dpanel_data 2>/dev/null || true
    print_info "删除镜像..."
    docker rmi -f "$DPANEL_IMAGE" 2>/dev/null || true
    
    print_success "DPanel 已卸载！"
    CACHE_STATUS["last_operation"]="卸载 DPanel ($(date '+%H:%M'))"
    CACHE_STATUS["last_update"]=0
}

# ==================== 安装函数 ====================
install_docker() {
    print_menu_header "安装 Docker"
    
    if [ "${CACHE_STATUS["docker_installed"]}" = true ]; then
        print_warning "Docker 已安装"
        return 0
    fi
    
    if ! command_exists lsb_release; then
        print_error "无法确定系统版本"
        return 1
    fi
    
    local DISTRO_CODENAME=$(lsb_release -cs)
    [ -z "$DISTRO_CODENAME" ] && {
        print_error "无法获取系统代号"
        return 1
    }
    
    print_info "系统: $DISTRO_CODENAME"
    
    # 定义安装步骤
    local steps=6
    local current_step=1  # 改为从1开始
    
    # 步骤1: 更新包列表
    show_step_progress $current_step $steps "更新包列表" "start"
    apt-get update > /dev/null 2>&1 || {
        show_step_progress $current_step $steps "更新包列表" "error"
        return 1
    }
    show_step_progress $current_step $steps "更新包列表" "success"
    ((current_step++))  # 现在这里是2
    
    # 步骤2: 安装依赖
    show_step_progress 2 $steps "安装依赖包" "start"
    apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https > /dev/null 2>&1 || {
        show_step_progress 2 $steps "安装依赖包" "error"
        return 1
    }
    show_step_progress 2 $steps "安装依赖包" "success"
    ((current_step++))
    
    # 步骤3: 添加GPG密钥
    show_step_progress 3 $steps "添加Docker GPG密钥" "start"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg > /dev/null 2>&1 || {
        show_step_progress 3 $steps "添加Docker GPG密钥" "error"
        return 1
    }
    chmod a+r /etc/apt/keyrings/docker.gpg
    show_step_progress 3 $steps "添加Docker GPG密钥" "success"
    ((current_step++))
    
    # 步骤4: 添加Docker源
    show_step_progress 4 $steps "添加Docker仓库源" "start"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $DISTRO_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update > /dev/null 2>&1 || {
        show_step_progress 4 $steps "添加Docker仓库源" "error"
        return 1
    }
    show_step_progress 4 $steps "添加Docker仓库源" "success"
    ((current_step++))
    
    # 步骤5: 安装Docker
    show_step_progress 5 $steps "安装Docker引擎" "start"
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1 || {
        show_step_progress 5 $steps "安装Docker引擎" "error"
        return 1
    }
    show_step_progress 5 $steps "安装Docker引擎" "success"
    ((current_step++))
    
        # 步骤6: 启动服务
show_step_progress $current_step $steps "启动Docker服务" "start"
if has_systemd; then
    systemctl enable --now docker > /dev/null 2>&1 || {
        show_step_progress $current_step $steps "启动Docker服务" "error"
        return 1
    }
fi

# 用户组
if ! getent group docker > /dev/null; then
    groupadd docker || print_warning "docker 组已存在"
fi

local CURRENT_USER="${SUDO_USER:-$(whoami)}"
usermod -aG docker "$CURRENT_USER" 2>/dev/null || print_warning "无法添加用户到 docker 组"

show_step_progress $current_step $steps "启动Docker服务" "success"
# 这里不要递增，因为这是最后一步

# 显示进度条 - 修复这里
show_progress_bar $steps $steps "Docker安装进度"  # 显示完整的进度
printf "\n"
    
    print_success "Docker 安装完成！"
    print_info "请重新登录或运行 'newgrp docker' 使权限生效"
    
    # 验证安装
    printf "\n${BOLD}验证安装结果：${NC}\n"
    if docker --version >/dev/null 2>&1; then
        local version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        printf "  ${GREEN}✓${NC} Docker 版本: $version\n"
    else
        printf "  ${RED}✗${NC} Docker 未正确安装\n"
    fi
    
    if systemctl is-active --quiet docker 2>/dev/null || [ -S /var/run/docker.sock ]; then
        printf "  ${GREEN}✓${NC} Docker 服务正在运行\n"
    else
        printf "  ${YELLOW}⚠${NC} Docker 服务未运行\n"
    fi
    
    CACHE_STATUS["last_operation"]="安装 Docker ($(date '+%H:%M'))"
    CACHE_STATUS["last_update"]=0
    return 0
}

install_portainer() {
    print_menu_header "安装 Portainer"
    
    update_status_cache
    if [ "${CACHE_STATUS["docker_installed"]}" = false ]; then
        print_error "Docker 未安装"
        return 1
    fi
    
    if [ "${CACHE_STATUS["portainer_installed"]}" = true ]; then
        print_warning "Portainer 已安装"
        return 0
    fi
    
    local port=9000
    if command_exists ss && ss -tuln | grep -q ":9000 "; then
        print_warning "端口 9000 已被占用"
        read -p "请输入新的 Portainer 端口号 (默认: 9001): " custom_port
        port=${custom_port:-9001}
    fi
    
    # 启动 Docker 服务
    if has_systemd && ! systemctl is-active --quiet docker 2>/dev/null; then
        systemctl start docker || {
            print_error "无法启动 Docker 服务"
            return 1
        }
    fi
    
    local progress_pid=$(show_progress "正在创建数据卷...")
    docker volume create portainer_data 2>/dev/null || print_warning "portainer_data 卷已存在"
    stop_progress "$progress_pid"
    
    progress_pid=$(show_progress "正在启动 Portainer 容器...")
    docker run -d \
        --name=portainer \
        --restart=always \
        -p ${port}:9000 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        "$PORTAINER_IMAGE" > /dev/null 2>&1 || {
            stop_progress "$progress_pid"
            print_error "Portainer 容器启动失败"
            return 1
        }
    stop_progress "$progress_pid"
        
    print_success "Portainer 安装完成！"
    print_info "访问地址: ${BOLD}http://服务器IP:${port}${NC}"
    print_info "首次登录需要设置管理员密码"
    
    CACHE_STATUS["last_operation"]="安装 Portainer ($(date '+%H:%M'))"
    CACHE_STATUS["last_update"]=0
    return 0
}

install_nginxpm() {
    print_menu_header "安装 Nginx Proxy Manager"
    
    update_status_cache
    
    # 检查Docker状态
    if [ "${CACHE_STATUS["docker_installed"]}" = false ]; then
        print_error "Docker 未安装，请先安装 Docker"
        return 1
    fi
    
    if ! command_exists curl; then
        print_warning "curl 未安装，尝试安装..."
        apt-get update >/dev/null 2>&1
        apt-get install -y curl >/dev/null 2>&1 || {
            print_error "无法安装 curl"
            return 1
        }
    fi
    
    # 检查容器是否已存在
    if docker ps -a --format '{{.Names}}' | grep -q nginx-proxy-manager; then
        print_warning "Nginx Proxy Manager 容器已存在"
        
        local container_status=$(docker inspect -f '{{.State.Status}}' nginx-proxy-manager 2>/dev/null || echo "未知")
        printf "容器状态: $container_status\n"
        
        if [ "$container_status" = "running" ]; then
            print_info "容器正在运行中，无需重复安装"
            return 0
        fi
        
        if confirm_with_timeout "是否删除现有容器并重新安装？" 10 "N"; then
            docker stop nginx-proxy-manager 2>/dev/null || true
            docker rm nginx-proxy-manager 2>/dev/null || true
            print_info "已删除现有容器"
        else
            return 0
        fi
    fi
    
    # 检查端口占用
    local ports=(80 81 443)
    local port_conflicts=()
    
    for port in "${ports[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            port_conflicts+=("$port")
        fi
    done
    
    if [ ${#port_conflicts[@]} -gt 0 ]; then
        print_warning "以下端口已被占用: ${port_conflicts[*]}"
        
        if [ "${port_conflicts[*]}" = "80 81 443" ]; then
            print_error "NPM所需的所有端口都被占用，可能NPM已在运行"
            if confirm_with_timeout "是否强制停止现有服务？" 10 "N"; then
                for port in "${ports[@]}"; do
                    local pid=$(ss -tlnp | grep ":$port " | awk '{print $7}' | cut -d= -f2 | cut -d, -f1)
                    if [ -n "$pid" ]; then
                        kill -9 "$pid" 2>/dev/null && print_info "已停止占用端口 $port 的进程 (PID: $pid)"
                    fi
                done
                sleep 2
            else
                return 1
            fi
        fi
    fi
    
    # 定义安装步骤
    local steps=4
    local current_step=1
    
    # 步骤1: 检查并启动Docker服务
    show_step_progress $current_step $steps "检查Docker服务" "start"
    if has_systemd && ! systemctl is-active --quiet docker 2>/dev/null; then
        if systemctl start docker 2>/dev/null; then
            show_step_progress $current_step $steps "检查Docker服务" "success"
        else
            show_step_progress $current_step $steps "检查Docker服务" "error"
            print_error "无法启动 Docker 服务"
            return 1
        fi
    else
        show_step_progress $current_step $steps "检查Docker服务" "success"
    fi
    ((current_step++))
    
    # 步骤2: 拉取镜像
    show_step_progress $current_step $steps "拉取NPM镜像" "start"
    local pull_output=$(docker pull "$NPM_IMAGE" 2>&1)
    if [ $? -eq 0 ]; then
        show_step_progress $current_step $steps "拉取NPM镜像" "success"
        print_info "镜像: $NPM_IMAGE"
        
        # 显示镜像大小
        local image_size=$(docker images "$NPM_IMAGE" --format "{{.Size}}" 2>/dev/null || echo "未知")
        print_info "镜像大小: $image_size"
    else
        show_step_progress $current_step $steps "拉取NPM镜像" "error"
        print_error "镜像拉取失败"
        printf "错误信息:\n"
        echo "$pull_output"
        
        # 尝试使用备用镜像源
        print_info "尝试使用备用镜像源..."
        local alt_image="jc21/nginx-proxy-manager:latest"
        if docker pull "$alt_image" 2>/dev/null; then
            NPM_IMAGE="$alt_image"
            print_info "使用备用镜像: $alt_image"
            show_step_progress $current_step $steps "拉取NPM镜像" "success"
        else
            return 1
        fi
    fi
    ((current_step++))
    
    # 步骤3: 创建数据目录
    show_step_progress $current_step $steps "创建数据目录" "start"
    if mkdir -p "$NPM_DATA_DIR"/{data,letsencrypt} 2>/dev/null; then
        show_step_progress $current_step $steps "创建数据目录" "success"
        
        # 设置目录权限
        chmod -R 755 "$NPM_DATA_DIR" 2>/dev/null || true
        chown -R $ORIGINAL_USER:$ORIGINAL_USER "$NPM_DATA_DIR" 2>/dev/null || true
        
        print_info "数据目录: $NPM_DATA_DIR"
    else
        show_step_progress $current_step $steps "创建数据目录" "error"
        print_error "目录创建失败"
        return 1
    fi
    ((current_step++))
    
    # 步骤4: 启动容器
    show_step_progress $current_step $steps "启动NPM容器" "start"
    
    # 清理可能存在的旧容器
    docker stop nginx-proxy-manager 2>/dev/null || true
    docker rm nginx-proxy-manager 2>/dev/null || true
    
    # 显示启动命令
    printf "\n${CYAN}启动命令：${NC}\n"
    echo "docker run -d \\"
    echo "  --name=nginx-proxy-manager \\"
    echo "  --restart=unless-stopped \\"
    echo "  -p 80:80 \\"
    echo "  -p 81:81 \\"
    echo "  -p 443:443 \\"
    echo "  -v $NPM_DATA_DIR/data:/data \\"
    echo "  -v $NPM_DATA_DIR/letsencrypt:/etc/letsencrypt \\"
    echo "  $NPM_IMAGE"
    
    # 启动容器
    local container_id=$(docker run -d \
        --name=nginx-proxy-manager \
        --restart=unless-stopped \
        -p 80:80 \
        -p 81:81 \
        -p 443:443 \
        -v "$NPM_DATA_DIR/data:/data" \
        -v "$NPM_DATA_DIR/letsencrypt:/etc/letsencrypt" \
        "$NPM_IMAGE" 2>&1)
    
    if [ $? -eq 0 ]; then
        show_step_progress $current_step $steps "启动NPM容器" "success"
        
        # 等待容器启动
        print_info "等待容器启动..."
        local wait_time=0
        while [ $wait_time -lt 30 ]; do
            if docker ps --filter "name=nginx-proxy-manager" --filter "status=running" | grep -q nginx-proxy-manager; then
                print_success "容器已启动并运行"
                break
            fi
            printf "."
            sleep 1
            ((wait_time++))
        done
        
        # 显示容器信息
        printf "\n${BOLD}容器信息：${NC}\n"
        local container_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' nginx-proxy-manager 2>/dev/null || echo "未知")
        printf "  ${GREEN}✓${NC} 容器IP: $container_ip\n"
        
        # 检查Web服务是否就绪
        print_info "检查Web服务状态..."
        if curl -s -f -o /dev/null --connect-timeout 5 http://localhost:81 2>/dev/null; then
            print_success "Web服务已就绪"
        else
            print_warning "Web服务启动中，可能需要更多时间..."
            sleep 5
        fi
        
    else
        show_step_progress $current_step $steps "启动NPM容器" "error"
        print_error "容器启动失败"
        printf "错误信息:\n"
        echo "$container_id"
        
        # 尝试查看容器日志
        print_info "查看容器日志："
        docker logs nginx-proxy-manager 2>&1 | tail -20
        
        return 1
    fi
    ((current_step++))
    
    # 显示进度条
    show_progress_bar $current_step $steps "NPM安装进度"
    printf "\n\n"
    
    # 显示安装结果
    print_success "Nginx Proxy Manager 安装完成！"
    
    # 获取服务器IP
    local server_ip=""
    if command_exists ip; then
        server_ip=$(ip route get 1 | awk '{print $7}' | head -1)
    elif command_exists hostname; then
        server_ip=$(hostname -I | awk '{print $1}')
    fi
    
    printf "\n${BOLD}访问信息：${NC}\n"
    printf "┌────────────────────────────────────────┐\n"
    printf "│  Web管理界面: ${CYAN}http://%s:81${NC}   │\n" "${server_ip:-服务器IP}"
    printf "│  代理HTTP端口: ${CYAN}80${NC}                    │\n"
    printf "│  代理HTTPS端口: ${CYAN}443${NC}                   │\n"
    printf "└────────────────────────────────────────┘\n"
    
    printf "\n${BOLD}默认登录凭据：${NC}\n"
    printf "┌────────────────────────────────────────┐\n"
    printf "│  邮箱: ${YELLOW}admin@example.com${NC}              │\n"
    printf "│  密码: ${YELLOW}changeme${NC}                        │\n"
    printf "└────────────────────────────────────────┘\n"
    
    print_warning "${BOLD}重要：首次登录后请立即修改密码！${NC}"
    
    # 验证安装
    printf "\n${BOLD}验证安装结果：${NC}\n"
    if docker ps --filter "name=nginx-proxy-manager" --filter "status=running" | grep -q nginx-proxy-manager; then
        printf "  ${GREEN}✓${NC} NPM容器正在运行\n"
    else
        printf "  ${RED}✗${NC} NPM容器未运行\n"
    fi
    
    # 测试端口
    for port in 81 80 443; do
        if ss -tln | grep -q ":$port "; then
            printf "  ${GREEN}✓${NC} 端口 $port 已监听\n"
        else
            printf "  ${YELLOW}⚠${NC} 端口 $port 未监听\n"
        fi
    done
    
    CACHE_STATUS["last_operation"]="安装 Nginx Proxy Manager ($(date '+%H:%M'))"
    CACHE_STATUS["last_update"]=0
    
    # 保存配置
    if [ -f "$CONFIG_FILE" ]; then
        echo "NPM_DATA_DIR=\"$NPM_DATA_DIR\"" >> "$CONFIG_FILE"
        echo "NPM_IMAGE=\"$NPM_IMAGE\"" >> "$CONFIG_FILE"
    fi
    
    return 0
}

configure_docker_mirror() {
    print_menu_header "配置 Docker 镜像加速"
    
    printf "可选的镜像加速器：\n"
    printf "1) 阿里云镜像加速器 ${GRAY}← 推荐${NC}\n"
    printf "2) 腾讯云镜像加速器\n"
    printf "3) 华为云镜像加速器\n"
    printf "4) 中科大镜像加速器\n"
    printf "5) 自定义镜像加速器\n"
    printf "6) 返回\n"
    
    read -p "请选择 (1-6): " choice
    
    local mirror_url=""
    case $choice in
        1) mirror_url="https://<your-id>.mirror.aliyuncs.com" ;;
        2) mirror_url="https://mirror.ccs.tencentyun.com" ;;
        3) mirror_url="https://<your-id>.swr.myhuaweicloud.com" ;;
        4) mirror_url="https://docker.mirrors.ustc.edu.cn" ;;
        5)
            read -p "请输入镜像加速器URL: " custom_url
            mirror_url="$custom_url"
            ;;
        6) return 0 ;;
        *) print_error "无效选择"; return 1 ;;
    esac
    
    if [ -z "$mirror_url" ]; then
        print_error "镜像加速器URL为空"
        return 1
    fi
    
    # 创建 daemon.json
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": ["$mirror_url"]
}
EOF
    
    print_success "Docker 镜像加速器已配置"
    print_info "镜像加速器: $mirror_url"
    
    if has_systemd && systemctl is-active --quiet docker; then
        print_info "重启 Docker 服务使配置生效..."
        systemctl restart docker
        print_success "Docker 服务已重启"
    fi
}

# ==================== 卸载函数（完善版）====================
cleanup_docker_service_files() {
    print_info "清理 Docker 服务文件..."
    
    # 清理systemd服务文件
    if has_systemd; then
        local service_files=(
            "/etc/systemd/system/docker.service"
            "/etc/systemd/system/docker.service.d/"
            "/usr/lib/systemd/system/docker.service"
        )
        
        for file in "${service_files[@]}"; do
            if [ -e "$file" ]; then
                rm -rf "$file" 2>/dev/null && echo "  已删除: $file" || echo "  删除失败: $file"
            fi
        done
        
        systemctl daemon-reload 2>/dev/null
        systemctl reset-failed 2>/dev/null
    fi
    
    # 清理init.d脚本
    local init_files=(
        "/etc/init.d/docker"
        "/etc/init.d/dockerd"
    )
    
    for file in "${init_files[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file" 2>/dev/null && echo "  已删除: $file" || echo "  删除失败: $file"
        fi
    done
}

uninstall_docker() {
    print_menu_header "卸载 Docker"
    
    confirm_danger "完全卸载 Docker" "⚠️ 此操作将删除所有容器、镜像、卷！" "destroy" || return 1
    
    print_info "停止所有容器..."
    docker stop $(docker ps -q) 2>/dev/null || true
    
    print_info "卸载 Docker 包..."
    apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1 || {
        print_error "包卸载失败"
        return 1
    }
    
    print_info "删除 Docker 数据目录..."
    rm -rf /var/lib/docker /var/lib/containerd /etc/docker || true
    
    print_info "清理配置..."
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    
    # 清理服务文件
    cleanup_docker_service_files
    
    # 删除用户组（如果为空）
    print_info "清理用户组..."
    if getent group docker >/dev/null && [ $(getent group docker | cut -d: -f4 | tr ',' '\n' | wc -l) -eq 0 ]; then
        groupdel docker 2>/dev/null || print_warning "无法删除 docker 组（可能仍有用户）"
    fi
    
    # 清理环境变量
    print_info "清理环境变量..."
    sed -i '/DOCKER/d' /etc/environment 2>/dev/null || true
    sed -i '/DOCKER/d' ~/.bashrc 2>/dev/null || true
    sed -i '/DOCKER/d' ~/.profile 2>/dev/null || true
    
    print_success "Docker 已完全卸载！"
    
    CACHE_STATUS["last_operation"]="卸载 Docker ($(date '+%H:%M'))"
    CACHE_STATUS["last_update"]=0
}

uninstall_portainer() {
    print_menu_header "卸载 Portainer"
    
    printf "${RED}警告：此操作将删除 Portainer 所有数据！${NC}\n"
    printf "\n"
    printf "将清理以下内容：\n"
    printf "  ▪ Portainer 容器\n"
    printf "  ▪ portainer_data 数据卷\n"
    printf "  ▪ Portainer 镜像\n"
    printf "\n"
    
    if ! confirm_with_timeout "确定要卸载吗？" 10 "N"; then
        print_info "取消卸载"
        return 0
    fi
    
    print_info "停止容器..."
    docker stop portainer 2>/dev/null || true
    print_info "删除容器..."
    docker rm -f portainer 2>/dev/null || true
    print_info "删除数据卷..."
    docker volume rm -f portainer_data 2>/dev/null || true
    print_info "删除镜像..."
    docker rmi -f "$PORTAINER_IMAGE" 2>/dev/null || true
    
    print_success "Portainer 已卸载！"
    CACHE_STATUS["last_operation"]="卸载 Portainer ($(date '+%H:%M'))"
    CACHE_STATUS["last_update"]=0
}

uninstall_nginxpm() {
    print_menu_header "彻底卸载 Nginx Proxy Manager"
    
    confirm_danger "彻底卸载 Nginx Proxy Manager" "⚠️ 此操作将删除所有 NPM 数据且不可恢复！" "YES" || return 1
    
    print_info "停止并删除容器..."
    docker stop nginx-proxy-manager 2>/dev/null || true
    docker rm -f nginx-proxy-manager 2>/dev/null || true

    print_info "清理 Docker 网络..."
    for network in $(docker network ls --filter "name=nginx-proxy-manager" --format "{{.Name}}" 2>/dev/null); do
        docker network rm "$network" 2>/dev/null || true
    done

    print_info "删除镜像..."
    docker rmi -f "$NPM_IMAGE" 2>/dev/null || true

    print_info "清理配置目录..."
    rm -rf "$NPM_DATA_DIR" 2>/dev/null || true

    if has_systemd; then
        if systemctl list-unit-files | grep -q "nginx-proxy-manager"; then
            systemctl stop nginx-proxy-manager 2>/dev/null || true
            systemctl disable nginx-proxy-manager 2>/dev/null || true
            rm -f /etc/systemd/system/nginx-proxy-manager.service 2>/dev/null || true
            systemctl daemon-reload
        fi
    fi

    print_success "Nginx Proxy Manager 已彻底卸载！"
    CACHE_STATUS["last_operation"]="卸载 NPM ($(date '+%H:%M'))"
    CACHE_STATUS["last_update"]=0
}

# ==================== 菜单1：安装与配置（完善版）====================
cleanup_failed_install() {
    print_menu_header "清理失败的安装"
    
    printf "检测系统状态...\n"
    update_status_cache
    
    local cleanup_list=()
    
    # 使用更清晰的显示
    printf "%-25s %-10s %s\n" "组件" "状态" "建议"
    printf "%-25s %-10s %s\n" "-------------------------" "----------" "-------------------------"
    
    if [ "${CACHE_STATUS["docker_installed"]}" = true ]; then
        printf "%-25s %-10s %s\n" "Docker" "✅ 已安装" "无需清理"
    else
        printf "%-25s %-10s %s\n" "Docker" "❌ 未安装" "可清理"
        cleanup_list+=("docker")
    fi
    
    if [ "${CACHE_STATUS["portainer_installed"]}" = true ]; then
        printf "%-25s %-10s %s\n" "Portainer" "✅ 已安装" "无需清理"
    else
        printf "%-25s %-10s %s\n" "Portainer" "❌ 未安装" "可清理"
        cleanup_list+=("portainer")
    fi
    
    if [ "${CACHE_STATUS["npm_installed"]}" = true ]; then
        printf "%-25s %-10s %s\n" "NPM" "✅ 已安装" "无需清理"
    else
        printf "%-25s %-10s %s\n" "NPM" "❌ 未安装" "可清理"
        cleanup_list+=("npm")
    fi
    
    if [ "${CACHE_STATUS["dpanel_installed"]}" = true ]; then
        printf "%-25s %-10s %s\n" "DPanel" "✅ 已安装" "无需清理"
    else
        printf "%-25s %-10s %s\n" "DPanel" "❌ 未安装" "可清理"
        cleanup_list+=("dpanel")
    fi
    
    printf "\n"
    
    if [ ${#cleanup_list[@]} -eq 0 ]; then
        print_success "没有检测到失败的安装"
        return 0
    fi
    
    printf "检测到 %d 个可能失败的安装：\n" "${#cleanup_list[@]}"
    for item in "${cleanup_list[@]}"; do
        printf "  • %s\n" "$item"
    done
    
    printf "\n"
    print_warning "注意：清理操作将删除相关数据，请确认已备份重要数据！"
    
    if confirm_with_timeout "是否执行清理？" 10 "N"; then
        for item in "${cleanup_list[@]}"; do
            case $item in
                "docker") 
                    printf "\n清理 Docker...\n"
                    uninstall_docker 
                    ;;
                "portainer") 
                    printf "\n清理 Portainer...\n"
                    uninstall_portainer 
                    ;;
                "npm") 
                    printf "\n清理 NPM...\n"
                    uninstall_nginxpm 
                    ;;
                "dpanel") 
                    printf "\n清理 DPanel...\n"
                    uninstall_dpanel 
                    ;;
            esac
        done
        print_success "清理完成！"
    else
        print_info "取消清理操作"
    fi
}

menu_install_configure() {
    while true; do
        print_menu_header "安装与配置中心"
        
        printf "0) 一键安装全部（Docker + Portainer + NPM + DPanel） ${GRAY}← 推荐新手使用${NC}\n"
        printf "1) 安装 Docker ${GRAY}← 容器运行时基础${NC}\n"
        printf "2) 安装 Portainer ${GRAY}← Web 可视化面板${NC}\n"
        printf "3) 安装 Nginx Proxy Manager ${GRAY}← 域名反向代理${NC}\n"
        printf "4) 安装 DPanel ${GRAY}← 国产管理面板${NC}\n"
        printf "5) 配置 Docker 镜像加速 ${GRAY}← 提升 pull 速度${NC}\n"
        printf "6) 卸载 Docker（含所有数据） ${RED}← ⚠️ 删除全部容器/镜像！${NC}\n"
        printf "7) 清理失败的安装 ${YELLOW}← 部分成功时的清理选项${NC}\n"
        printf "8) 返回主菜单 (..)\n"
        printf "\n"
        read -p "请选择 (0-8, ..): " choice
        
                    case $choice in
            0)
                print_menu_header "一键安装全部组件"
                
                local components=(
                    "Docker"
                    "Portainer" 
                    "Nginx Proxy Manager"
                    "DPanel"
                )
                
                local install_functions=(
                    "install_docker"
                    "install_portainer"
                    "install_nginxpm"
                    "install_dpanel"
                )
                
                local total=${#components[@]}
                local success_count=0
                local failed_components=()
                
                printf "开始一键安装 %d 个组件...\n" "$total"
                printf "%s\n" "----------------------------------------------------------------"
                
                for i in "${!components[@]}"; do
                    local comp_name="${components[$i]}"
                    local comp_func="${install_functions[$i]}"
                    local step_num=$((i + 1))
                    
                    printf "\n${BOLD}步骤 %d/%d: 安装 %s${NC}\n" "$step_num" "$total" "$comp_name"
                    
                    # 显示当前进度
            show_progress_bar $((step_num-1)) $total "总体安装进度"
printf "\n"

# 记录开始时间
local start_time=$(date +%s)

# 执行安装
if $comp_func; then
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    print_success "$comp_name 安装成功 (耗时: ${duration}秒)"
    ((success_count++))
    
    # 安装成功后显示更新后的进度
    show_progress_bar $step_num $total "总体安装进度"
    printf "\n"
else
    print_error "$comp_name 安装失败"
    failed_components+=("$comp_name")
    
    # 即使失败也更新进度
    show_progress_bar $step_num $total "总体安装进度"
    printf "\n"
    
    if [ ${#failed_components[@]} -eq 1 ]; then
        if ! confirm_with_timeout "是否继续尝试后续安装？" 10 "Y"; then
            break
        fi
    fi
fi
                    
                    printf "%s\n" "----------------------------------------------------------------"
                done
                
                # 显示总体进度
                show_progress_bar $total $total "总体安装进度"
                printf "\n\n"
                
                # 显示安装摘要
                printf "${BOLD}安装结果摘要：${NC}\n"
                printf "成功: ${GREEN}%d/${total}${NC}\n" "$success_count"
                
                if [ ${#failed_components[@]} -gt 0 ]; then
                    printf "失败: ${RED}%d/${total}${NC}\n" "${#failed_components[@]}"
                    printf "失败的组件: ${YELLOW}%s${NC}\n" "$(IFS=,; echo "${failed_components[*]}")"
                    print_info "请使用选项7清理失败的安装"
                fi
                
                # 显示访问信息
                if [ $success_count -gt 0 ]; then
                    printf "\n${BOLD}已安装组件的访问信息：${NC}\n"
                    
                    # 检查并显示每个组件的访问信息
                    if docker ps --format '{{.Names}}' | grep -q portainer; then
                        printf "  • Portainer: ${CYAN}http://服务器IP:9000${NC}\n"
                    fi
                    
                    if docker ps --format '{{.Names}}' | grep -q nginx-proxy-manager; then
                        printf "  • NPM: ${CYAN}http://服务器IP:81${NC}\n"
                        printf "     邮箱: admin@example.com 密码: changeme\n"
                    fi
                    
                    if docker ps --format '{{.Names}}' | grep -q dpanel; then
                        printf "  • DPanel: ${CYAN}http://服务器IP:7800${NC}\n"
                    fi
                    
                    print_success "一键安装完成！"
                else
                    print_error "所有组件安装失败"
                    print_info "请检查网络连接和系统状态"
                fi
                ;;
            1) install_docker ;;
            2) install_portainer ;;
            3) install_nginxpm ;;
            4) install_dpanel ;;
            5) configure_docker_mirror ;;
            6) uninstall_docker ;;
            7) cleanup_failed_install ;;
            8|..) return 0 ;;
            *)
                print_error "无效选择"
                ;;
        esac
        
        echo ""
        if [ "$choice" != ".." ] && [ "$choice" != "8" ]; then
            read -p "按Enter键继续..."
        fi
    done
}

# ==================== 新增：安装状态检测 ====================
check_install_status() {
    local component="$1"
    
    case $component in
        "docker")
            if command_exists docker; then
                local version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "未知")
                print_success "✓ Docker 已安装 (版本: $version)"
                return 0
            else
                print_error "✗ Docker 未安装"
                return 1
            fi
            ;;
        "portainer")
            if docker ps -a --format '{{.Names}}' | grep -q portainer; then
                local status=$(docker inspect -f '{{.State.Status}}' portainer 2>/dev/null || echo "未运行")
                print_success "✓ Portainer 已安装 (状态: $status)"
                return 0
            else
                print_error "✗ Portainer 未安装"
                return 1
            fi
            ;;
        "npm")
            if docker ps -a --format '{{.Names}}' | grep -q nginx-proxy-manager; then
                local status=$(docker inspect -f '{{.State.Status}}' nginx-proxy-manager 2>/dev/null || echo "未运行")
                print_success "✓ Nginx Proxy Manager 已安装 (状态: $status)"
                return 0
            else
                print_error "✗ Nginx Proxy Manager 未安装"
                return 1
            fi
            ;;
        "dpanel")
            if docker ps -a --format '{{.Names}}' | grep -q dpanel; then
                local status=$(docker inspect -f '{{.State.Status}}' dpanel 2>/dev/null || echo "未运行")
                print_success "✓ DPanel 已安装 (状态: $status)"
                return 0
            else
                print_error "✗ DPanel 未安装"
                return 1
            fi
            ;;
        "compose")
            if command_exists docker-compose || (command_exists docker && docker compose version >/dev/null 2>&1); then
                print_success "✓ Docker Compose 已安装"
                return 0
            else
                print_error "✗ Docker Compose 未安装"
                return 1
            fi
            ;;
        *)
            print_error "未知组件: $component"
            return 1
            ;;
    esac
}

# 显示安装摘要
show_install_summary() {
    print_menu_header "安装完成摘要"
    
    local components=("docker" "portainer" "npm" "dpanel")
    local all_success=true
    
    printf "${BOLD}安装结果检查：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    
    for component in "${components[@]}"; do
        printf "%-25s: " "$component"
        if check_install_status "$component" >/dev/null 2>&1; then
            printf "${GREEN}✓ 已安装${NC}\n"
        else
            printf "${RED}✗ 未安装${NC}\n"
            all_success=false
        fi
    done
    
    printf "%s\n" "----------------------------------------------------------------"
    
    if [ "$all_success" = true ]; then
        print_success "所有组件安装完成！"
        
        # 显示访问信息
        printf "\n${BOLD}访问信息：${NC}\n"
        printf "  • Portainer: ${CYAN}http://服务器IP:9000${NC}\n"
        printf "  • NPM: ${CYAN}http://服务器IP:81${NC}\n"
        printf "  • DPanel: ${CYAN}http://服务器IP:7800${NC}\n"
        
        printf "\n${BOLD}默认凭据：${NC}\n"
        printf "  • NPM: admin@example.com / changeme\n"
        printf "  • Portainer: 首次访问设置密码\n"
        printf "  • DPanel: 首次访问设置账号\n"
    else
        print_warning "部分组件安装失败"
        printf "请检查日志文件: ${GRAY}$LOG_FILE${NC}\n"
    fi
}

# ==================== 菜单2：应用管理（完善版）====================
menu_app_management() {
    while true; do
        print_menu_header "应用管理中心"
        
        printf "1) 管理 Nginx Proxy Manager ${GRAY}← 查看状态/日志/密码${NC}\n"
        printf "2) 重置 NPM 管理员密码 ${YELLOW}← 忘记密码时使用${NC}\n"
        printf "3) 彻底卸载 Nginx Proxy Manager ${RED}← ⚠️ 删除所有相关数据！${NC}\n"
        printf "4) 管理 Portainer ${GRAY}← 重启/查看日志${NC}\n"
        printf "5) 重置 Portainer 管理员密码 ${YELLOW}← 忘记密码时使用${NC}\n"
        printf "6) 卸载 Portainer ${GRAY}← 保留数据或完全清除${NC}\n"
        printf "7) 管理 DPanel ${GRAY}← 重启/查看日志${NC}\n"
        printf "8) 卸载 DPanel ${GRAY}← 保留数据或完全清除${NC}\n"
        printf "9) 返回主菜单 (..)\n"
        printf "\n"
        read -p "请选择 (1-9, ..): " choice
        
        case $choice in
            1)
                if [ "${CACHE_STATUS["npm_installed"]}" = false ]; then
                    print_error "Nginx Proxy Manager 未安装"
                    continue
                fi
                
                print_menu_header "管理 Nginx Proxy Manager"
                printf "1) 查看实时日志 ${GRAY}← 按 Ctrl+C 退出${NC}\n"
                printf "2) 重启服务\n"
                printf "3) 停止服务\n"
                printf "4) 进入容器终端\n"
                printf "5) 查看容器信息\n"
                printf "6) 返回\n"
                
                read -p "选择操作 (1-6): " sub_choice
                
                case $sub_choice in
                    1)
                        print_info "按 Ctrl+C 退出日志查看"
                        docker logs -f nginx-proxy-manager
                        ;;
                    2)
                        docker restart nginx-proxy-manager && print_success "NPM 重启完成"
                        ;;
                    3)
                        docker stop nginx-proxy-manager && print_success "NPM 已停止"
                        ;;
                    4)
                        docker exec -it nginx-proxy-manager /bin/sh
                        ;;
                    5)
                        printf "容器信息:\n"
                        docker inspect nginx-proxy-manager --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | xargs -I {} printf "  容器IP: %s\n" {}
                        docker port nginx-proxy-manager
                        ;;
                    6) continue ;;
                    *) print_error "无效选择" ;;
                esac
                ;;
            2) reset_nginxpm_password ;;
            3) uninstall_nginxpm ;;
            4)
                if [ "${CACHE_STATUS["portainer_installed"]}" = false ]; then
                    print_error "Portainer 未安装"
                    continue
                fi
                
                print_menu_header "管理 Portainer"
                printf "1) 查看实时日志 ${GRAY}← 按 Ctrl+C 退出${NC}\n"
                printf "2) 重启服务\n"
                printf "3) 停止服务\n"
                printf "4) 进入容器终端\n"
                printf "5) 查看容器信息\n"
                printf "6) 返回\n"
                
                read -p "选择操作 (1-6): " sub_choice
                
                case $sub_choice in
                    1)
                        print_info "按 Ctrl+C 退出日志查看"
                        docker logs -f portainer
                        ;;
                    2)
                        docker restart portainer && print_success "Portainer 重启完成"
                        ;;
                    3)
                        docker stop portainer && print_success "Portainer 已停止"
                        ;;
                    4)
                        docker exec -it portainer /bin/sh
                        ;;
                    5)
                        printf "容器信息:\n"
                        docker inspect portainer --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | xargs -I {} printf "  容器IP: %s\n" {}
                        docker port portainer
                        ;;
                    6) continue ;;
                    *) print_error "无效选择" ;;
                esac
                ;;
            5) reset_portainer_password ;;
            6) uninstall_portainer ;;
            7)
                if [ "${CACHE_STATUS["dpanel_installed"]}" = false ]; then
                    print_error "DPanel 未安装"
                    continue
                fi
                
                print_menu_header "管理 DPanel"
                printf "1) 查看实时日志 ${GRAY}← 按 Ctrl+C 退出${NC}\n"
                printf "2) 重启服务\n"
                printf "3) 停止服务\n"
                printf "4) 进入容器终端\n"
                printf "5) 查看容器信息\n"
                printf "6) 返回\n"
                
                read -p "选择操作 (1-6): " sub_choice
                
                case $sub_choice in
                    1)
                        print_info "按 Ctrl+C 退出日志查看"
                        docker logs -f dpanel
                        ;;
                    2)
                        docker restart dpanel && print_success "DPanel 重启完成"
                        ;;
                    3)
                        docker stop dpanel && print_success "DPanel 已停止"
                        ;;
                    4)
                        docker exec -it dpanel /bin/sh
                        ;;
                    5)
                        printf "容器信息:\n"
                        docker inspect dpanel --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | xargs -I {} printf "  容器IP: %s\n" {}
                        docker port dpanel
                        ;;
                    6) continue ;;
                    *) print_error "无效选择" ;;
                esac
                ;;
            8) uninstall_dpanel ;;
            9|..) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        
        echo ""
        if [ "$choice" != ".." ] && [ "$choice" != "9" ]; then
            read -p "按Enter键继续..."
        fi
    done
}

# ==================== 菜单3：容器与服务 ====================
menu_container_service() {
    while true; do
        print_menu_header "容器与服务管理"
        
        printf "1) 列出所有容器 ${GRAY}← 显示 ID、名称、状态、端口${NC}\n"
        printf "2) 启动指定容器 ${GRAY}← 输入容器名或 ID${NC}\n"
        printf "3) 停止指定容器 ${GRAY}← 安全停止（SIGTERM）${NC}\n"
        printf "4) 重启指定容器 ${GRAY}← 常用于配置更新${NC}\n"
        printf "5) 查看容器实时日志 ${GRAY}← 按 Ctrl+C 退出${NC}\n"
        printf "6) 进入容器终端 (exec) ${GRAY}← 调试必备${NC}\n"
        printf "7) 返回主菜单 (..)\n"
        printf "\n"
        read -p "请选择 (1-7, ..): " choice
        
        case $choice in
            1)
                printf "\n"
                printf "${BOLD}容器列表：${NC}\n"
                printf "%s\n" "----------------------------------------------------------------"
                docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
                printf "%s\n" "----------------------------------------------------------------"
                ;;
            2)
                read -p "请输入容器名称或ID: " container
                if [ -n "$container" ]; then
                    docker start "$container" && print_success "容器 $container 已启动" || print_error "启动失败"
                fi
                ;;
            3)
                read -p "请输入容器名称或ID: " container
                if [ -n "$container" ]; then
                    docker stop "$container" && print_success "容器 $container 已停止" || print_error "停止失败"
                fi
                ;;
            4)
                read -p "请输入容器名称或ID: " container
                if [ -n "$container" ]; then
                    docker restart "$container" && print_success "容器 $container 已重启" || print_error "重启失败"
                fi
                ;;
            5)
                read -p "请输入容器名称或ID: " container
                if [ -n "$container" ]; then
                    print_info "按 Ctrl+C 退出日志查看"
                    docker logs -f "$container"
                fi
                ;;
            6)
                read -p "请输入容器名称或ID: " container
                if [ -n "$container" ]; then
                    print_info "尝试使用 /bin/bash，如失败则使用 /bin/sh"
                    docker exec -it "$container" /bin/bash || docker exec -it "$container" /bin/sh
                fi
                ;;
            7|..) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        
        echo ""
        if [ "$choice" != ".." ] && [ "$choice" != "7" ] && [ "$choice" != "1" ] && [ "$choice" != "5" ] && [ "$choice" != "6" ]; then
            read -p "按Enter键继续..."
        fi
    done
}

# ==================== 菜单4：日常维护（完善版）====================
clean_unused_resources() {
    print_menu_header "清理未使用资源"
    
    printf "将清理以下内容：\n"
    printf "1) 已停止的容器\n"
    printf "2) 未被使用的镜像\n"
    printf "3) 未被使用的卷\n"
    printf "4) 未被使用的网络\n"
    printf "5) 构建缓存\n"
    printf "\n"
    
    if ! confirm_with_timeout "确定要执行清理吗？" 10 "N"; then
        return 0
    fi
    
    # 预估释放空间（带超时）
    print_info "正在估算可释放空间..."
    local estimated=$(run_with_timeout 5 "docker system df --format '{{.Reclaimable}}' | tail -1")
    if [ $? -eq 0 ]; then
        print_info "预计释放空间: $estimated"
    else
        print_warning "无法估算释放空间"
    fi
    
    print_info "执行清理..."
    docker system prune -af 2>/dev/null | grep -E "Total reclaimed space:|deleted" || true
    
    print_success "Docker 垃圾清理完成！"
}

check_disk_usage() {
    print_menu_header "查看磁盘使用情况"
    
    printf "${BOLD}磁盘使用情况：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    df -h / /var/lib/docker 2>/dev/null | awk 'NR==1 || /^\// {print}'
    printf "%s\n" "----------------------------------------------------------------"
    
    printf "\n"
    printf "${BOLD}Docker 数据使用：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    # 带超时的docker system df
    run_with_timeout 10 "docker system df 2>/dev/null" || echo "Docker 未运行或命令超时"
    printf "%s\n" "----------------------------------------------------------------"
}

export_environment_snapshot() {
    print_menu_header "导出环境快照"
    
    local snapshot_file="/tmp/docker-env-snapshot-$(date +%Y%m%d-%H%M%S).sh"
    
    print_warning "注意：快照不包含数据卷内容，请另行备份重要数据！"
    echo ""
    
    {
        echo "#!/bin/bash"
        echo "# Docker 环境恢复脚本"
        echo "# 生成时间: $(date)"
        echo "# 由 docker-manager.sh 生成"
        echo "# 注意：此脚本不包含数据卷内容，请确保已备份重要数据"
        echo ""
        echo "set -e"
        echo ""
        echo "echo '开始恢复 Docker 环境...'"
        echo ""
        
        # 导出所有容器运行命令
        for container in $(docker ps -a --format '{{.Names}}'); do
            echo "echo '恢复容器: $container'"
            
            # 获取容器配置
            local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
            local restart=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null)
            
            # 这里简化处理，实际应该解析完整的docker run命令
            echo "# docker run -d --name $container --restart=$restart $image"
            echo ""
        done
        
        echo "echo '环境恢复脚本生成完成！'"
        echo "echo '请根据需要编辑后执行'"
        echo "echo '注意：此脚本不包含数据卷内容，请确保已备份重要数据'"
        
    } > "$snapshot_file"
    
    chmod +x "$snapshot_file"
    
    print_success "环境快照已导出: $snapshot_file"
    print_info "这是一个基础恢复脚本，请根据实际情况修改完善"
    print_warning "重要：快照不包含数据卷内容，请另行备份重要数据！"
}

monitor_container_resources() {
    print_menu_header "监控容器资源"
    
    printf "${BOLD}实时资源占用（按 Ctrl+C 退出）${NC}\n"
    printf "\n"
    print_info "按 Ctrl+C 退出监控"
    printf "\n"
    print_info "注意：容器数量较多时可能需要较长时间加载"
    printf "\n"
    
    # 带超时的docker stats
    run_with_timeout 5 "docker stats --format \"table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\"" || {
        print_error "监控命令超时，可能容器数量过多"
        print_info "建议使用：docker stats --no-stream"
    }
}

update_script_self() {
    print_menu_header "更新脚本自身"
    
    local update_url="https://raw.githubusercontent.com/example/docker-manager/main/docker-manager.sh"
    local backup_file="$SCRIPT_DIR/docker-manager.sh.backup.$(date +%Y%m%d-%H%M%S)"
    
    printf "从 GitHub 拉取最新版本...\n"
    
    if ! command_exists curl; then
        print_error "需要 curl 命令"
        apt-get update && apt-get install -y curl 2>/dev/null || {
            print_error "无法安装 curl"
            return 1
        }
    fi
    
    print_info "备份当前脚本: $backup_file"
    cp "$SCRIPT_DIR/docker-manager.sh" "$backup_file"
    
    print_info "下载最新版本..."
    if curl -L "$update_url" -o /tmp/docker-manager-new.sh 2>/dev/null; then
        # 检查下载的文件是否有效
        if [ -s /tmp/docker-manager-new.sh ] && head -1 /tmp/docker-manager-new.sh | grep -q "#!/bin/bash"; then
            mv /tmp/docker-manager-new.sh "$SCRIPT_DIR/docker-manager.sh"
            chmod +x "$SCRIPT_DIR/docker-manager.sh"
            print_success "脚本更新完成！"
            print_info "备份文件: $backup_file"
            print_info "请重新运行脚本以使用新版本"
            exit 0
        else
            print_error "下载的文件无效"
            rm -f /tmp/docker-manager-new.sh
            return 1
        fi
    else
        print_error "下载失败，请检查网络连接"
        return 1
    fi
}

menu_daily_maintenance() {
    while true; do
        print_menu_header "日常维护中心"
        
        printf "1) 清理未使用资源 ${GRAY}← 删除悬空镜像/停止容器${NC}\n"
        printf "2) 查看磁盘使用情况 ${GRAY}← 镜像/容器/卷占用统计${NC}\n"
        printf "3) 导出环境快照 ${GRAY}← 生成 compose 或 run 脚本${NC}\n"
        printf "4) 监控容器资源 (CPU/内存) ${GRAY}← 实时 top 式监控${NC}\n"
        printf "5) 更新脚本自身 ${GRAY}← 从 GitHub 拉取最新版${NC}\n"
        printf "6) 返回主菜单 (..)\n"
        printf "\n"
        read -p "请选择 (1-6, ..): " choice
        
        case $choice in
            1) clean_unused_resources ;;
            2) check_disk_usage ;;
            3) export_environment_snapshot ;;
            4) monitor_container_resources ;;
            5) update_script_self ;;
            6|..) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        
        echo ""
        if [ "$choice" != ".." ] && [ "$choice" != "6" ] && [ "$choice" != "4" ]; then
            read -p "按Enter键继续..."
        fi
    done
}

# ==================== 菜单5：诊断与修复 ====================
fix_apt_source_format() {
    print_menu_header "修复 APT 源格式"
    
    if ! command_exists lsb_release; then
        print_error "需要 lsb_release 命令"
        return 1
    fi
    
    local distro_codename=$(lsb_release -cs)
    if [ -z "$distro_codename" ]; then
        print_error "无法获取系统代号"
        return 1
    fi
    
    # 备份原文件
    local backup_file="/etc/apt/sources.list.backup.$(date +%Y%m%d-%H%M%S)"
    if [ -f "/etc/apt/sources.list" ]; then
        cp /etc/apt/sources.list "$backup_file"
        print_info "原配置已备份至: $backup_file"
    fi
    
    # 生成阿里云镜像源
    cat > /etc/apt/sources.list << EOF
deb https://mirrors.aliyun.com/ubuntu/ $distro_codename main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $distro_codename-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $distro_codename-backports main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $distro_codename-security main restricted universe multiverse
EOF
    
    print_success "APT 源格式已修复"
    print_info "已设置为阿里云镜像源"
}

clean_apt_cache() {
    print_menu_header "清理 APT 缓存"
    
    print_info "清理 APT 缓存..."
    apt-get clean && apt-get autoclean && apt-get autoremove -y > /dev/null 2>&1
    print_success "APT 缓存已清理"
}

fix_docker_gpg_key() {
    print_menu_header "修复 Docker GPG 密钥"
    
    print_info "修复 GPG 密钥..."
    apt-get install -y debian-archive-keyring ubuntu-keyring > /dev/null 2>&1 || true
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 3B4FE6ACC0B21F32 871920D1991BC93C > /dev/null 2>&1 || true
    print_success "GPG 密钥已修复"
}

check_docker_service_status() {
    print_menu_header "检查 Docker 服务状态"
    
    if has_systemd; then
        printf "Docker 服务状态:\n"
        systemctl status docker --no-pager -l | head -20
    else
        if [ -S /var/run/docker.sock ]; then
            print_success "Docker socket 存在，服务可能正在运行"
        else
            print_error "Docker socket 不存在"
        fi
    fi
}

view_script_logs() {
    print_menu_header "查看脚本操作日志"
    
    if [ -f "$LOG_FILE" ]; then
        printf "最近 50 行日志：\n"
        printf "%s\n" "----------------------------------------------------------------"
        tail -50 "$LOG_FILE"
        printf "%s\n" "----------------------------------------------------------------"
        printf "\n"
        print_info "完整日志文件: $LOG_FILE"
        print_info "日志大小: $(du -h "$LOG_FILE" | cut -f1)"
    else
        print_error "日志文件不存在"
    fi
}

# ==================== 网络工具函数（优化版）====================

show_network_info() {
    print_menu_header "网络信息概览"
    
    printf "${BOLD}📱 网络接口概览：${NC}\n"
    
    # 使用更合适的列宽来适应IPv6地址
    printf "%-15s %-35s %-20s %-10s\n" "接口" "IP地址" "MAC地址" "状态"
    printf "%-15s %-35s %-20s %-10s\n" "------" "-----------------------------------" "--------------------" "----------"
    
    ip -o addr show | while read -r line; do
        iface=$(echo "$line" | awk '{print $2}')
        if [[ "$iface" != "lo" ]]; then
            ip_addr=$(echo "$line" | awk '{print $4}' | cut -d'/' -f1)
            mac_addr=$(ip link show "$iface" 2>/dev/null | grep -oE 'link/ether [0-9a-f:]+' | cut -d' ' -f2 || echo "-")
            state=$(ip link show "$iface" 2>/dev/null | grep -q "state UP" && echo "UP" || echo "DOWN")
            [ -z "$ip_addr" ] && ip_addr="无IP"
            [ -z "$mac_addr" ] && mac_addr="-"
            printf "%-15s %-35s %-20s %-10s\n" "$iface" "$ip_addr" "$mac_addr" "$state"
        fi
    done
    
    printf "\n${BOLD}🌐 网络配置详情：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    
    # 默认网关
    local default_gateway=$(ip route | grep default | head -1 | awk '{print $3}')
    if [ -n "$default_gateway" ]; then
        printf "默认网关: ${GREEN}$default_gateway${NC}\n"
        
        # 测试网关连通性
        printf "网关状态: "
        if ping -c 1 -W 1 "$default_gateway" >/dev/null 2>&1; then
            printf "${GREEN}✓ 可达${NC}\n"
        else
            printf "${RED}✗ 不可达${NC}\n"
        fi
    else
        printf "默认网关: ${YELLOW}未配置${NC}\n"
    fi
    
    # DNS服务器 - 修复printf错误
    printf "\n${BOLD}📡 DNS 服务器：${NC}\n"
            if [ -f /etc/resolv.conf ]; then
                local dns_count=0
                while IFS= read -r line; do
            if [[ "$line" == nameserver* ]]; then
                local dns_server=$(echo "$line" | awk '{print $2}')
                ((dns_count++))
                printf "  DNS%d: %s" "$dns_count" "$dns_server"
            
            # 测试DNS响应
            if nslookup -timeout=2 baidu.com "$dns_server" >/dev/null 2>&1; then
                printf " ${GREEN}✓ 正常${NC}\n"
            else
                printf " ${RED}✗ 异常${NC}\n"
            fi
        fi
    done < /etc/resolv.conf
        
        if [ $dns_count -eq 0 ]; then
            printf "  ${YELLOW}未配置DNS服务器${NC}\n"
        fi
    else
        printf "  ${YELLOW}/etc/resolv.conf不存在${NC}\n"
    fi
    
    # 公网连接测试 - 修复printf错误
    printf "\n${BOLD}🌍 公网连接：${NC}\n"
    printf "  测试到 8.8.8.8: "
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    printf "${GREEN}✓ 正常${NC}\n"
else
    printf "${RED}✗ 失败${NC}\n"
fi

printf "  DNS解析测试: "
if host baidu.com >/dev/null 2>&1; then
    printf "${GREEN}✓ 正常${NC}\n"
else
    printf "${RED}✗ 失败${NC}\n"
fi
    
    printf "%s\n" "----------------------------------------------------------------"
}

configure_network() {
    print_menu_header "网络配置中心"
    
    # 获取所有非回环接口
    local interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | sort)
    local interface_list=()
    
    printf "${BOLD}选择网络接口：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    
    local i=1
    for iface in $interfaces; do
        # 获取接口状态和IP
        local state=$(ip link show "$iface" | grep -q "state UP" && echo "UP" || echo "DOWN")
        local ip_addr=$(ip -o addr show "$iface" | awk '{print $4}' | head -1 | cut -d'/' -f1)
        [ -z "$ip_addr" ] && ip_addr="无IP"
        
        printf "%d) %-12s ${GRAY}状态: %-4s IP: %s${NC}\n" "$i" "$iface" "$state" "$ip_addr"
        interface_list+=("$iface")
        ((i++))
    done
    
    printf "%d) 返回主菜单\n" "$i"
    printf "%s\n" "----------------------------------------------------------------"
    
    read -p "请选择接口 (1-$i): " choice
    
    if [ "$choice" -eq "$i" ] 2>/dev/null; then
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#interface_list[@]}" ]; then
        print_error "无效的选择"
        return 1
    fi
    
    local selected_iface="${interface_list[$((choice-1))]}"
    
    while true; do
        print_menu_header "配置接口: $selected_iface"
        
        # 获取当前配置
        local current_ip=$(ip -4 addr show "$selected_iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        local current_gateway=$(ip route | grep default | grep "$selected_iface" | awk '{print $3}' | head -1)
        local current_dns=$(grep nameserver /etc/resolv.conf 2>/dev/null | head -2 | awk '{print $2}' | tr '\n' ' ')
        
        printf "${BOLD}当前配置：${NC}\n"
        printf "  IP地址: ${CYAN}${current_ip:-未设置}${NC}\n"
        printf "  网关: ${CYAN}${current_gateway:-未设置}${NC}\n"
        printf "  DNS: ${CYAN}${current_dns:-未设置}${NC}\n"
        
        printf "\n${BOLD}配置选项：${NC}\n"
        printf "1) 配置静态 IP + 网关\n"
        printf "2) 配置 DHCP 自动获取\n"
        printf "3) 仅配置 DNS 服务器\n"
        printf "4) 测试网络连接\n"
        printf "5) 重启网络接口\n"
        printf "6) 返回接口选择\n"
        printf "7) 返回主菜单\n"
        printf "\n"
        read -p "请选择 (1-7): " config_choice
        
        case $config_choice in
            1)
                configure_static_ip "$selected_iface"
                ;;
            2)
                configure_dhcp "$selected_iface"
                ;;
            3)
                configure_dns_only "$selected_iface"
                ;;
            4)
                test_interface_connection "$selected_iface"
                ;;
            5)
                restart_network_interface "$selected_iface"
                ;;
            6)
                return 0  # 返回接口选择
                ;;
            7)
                return 1  # 返回主菜单
                ;;
            *)
                print_error "无效选择"
                ;;
        esac
        
        echo ""
        if [ "$config_choice" -ne 4 ]; then
            read -p "按Enter键继续..."
        fi
    done
}

configure_static_ip() {
    local iface="$1"
    
    print_menu_header "配置静态 IP - $iface"
    
    # 获取当前配置作为默认值
    local current_ip=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    local current_gateway=$(ip route | grep default | grep "$iface" | awk '{print $3}' | head -1)
    
    # 建议的配置
    local suggested_ip=""
    if [[ "$current_ip" =~ ^192\.168\. ]]; then
        suggested_ip="$current_ip"
    elif [ -n "$current_ip" ]; then
        suggested_ip="$current_ip"
    else
        # 生成一个默认的IP
        suggested_ip="192.168.1.$(($RANDOM % 200 + 50))"
    fi
    
    printf "请输入网络配置：\n\n"
    
    read -p "IP 地址 [$suggested_ip]: " new_ip
    new_ip=${new_ip:-$suggested_ip}
    
    # 验证IP格式
    if ! [[ "$new_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        print_error "IP地址格式无效"
        return 1
    fi
    
    read -p "子网掩码 (如: 24 或 255.255.255.0) [24]: " new_netmask
    new_netmask=${new_netmask:-24}
    
    # 根据IP段建议网关
    local suggested_gateway=""
    if [[ "$new_ip" =~ ^192\.168\.1\. ]]; then
        suggested_gateway="192.168.1.1"
    elif [[ "$new_ip" =~ ^192\.168\.0\. ]]; then
        suggested_gateway="192.168.0.1"
    elif [[ "$new_ip" =~ ^10\. ]]; then
        suggested_gateway=$(echo "$new_ip" | sed 's/\.[0-9]*$/.1/')
    else
        suggested_gateway="${current_gateway:-$suggested_ip%.*}.1"
    fi
    
    read -p "网关地址 [$suggested_gateway]: " new_gateway
    new_gateway=${new_gateway:-$suggested_gateway}
    
    read -p "主 DNS 服务器 [8.8.8.8]: " dns1
    dns1=${dns1:-8.8.8.8}
    
    read -p "备用 DNS 服务器 [8.8.4.4]: " dns2
    dns2=${dns2:-8.8.4.4}
    
    printf "\n${BOLD}即将应用以下配置：${NC}\n"
    printf "┌────────────────────────────────────┐\n"
    printf "│  接口: %-28s │\n" "$iface"
    printf "│  IP地址: %-26s │\n" "$new_ip/$new_netmask"
    printf "│  网关: %-29s │\n" "$new_gateway"
    printf "│  DNS: %-30s │\n" "$dns1, $dns2"
    printf "└────────────────────────────────────┘\n"
    
    if ! confirm_with_timeout "确认应用此配置？" 10 "Y"; then
        print_info "取消配置"
        return 0
    fi
    
    # 创建Netplan配置
    create_netplan_config "$iface" "static" "$new_ip" "$new_netmask" "$new_gateway" "$dns1" "$dns2"
}

configure_dhcp() {
    local iface="$1"
    
    print_menu_header "配置 DHCP - $iface"
    
    printf "将接口 $iface 配置为 DHCP 模式\n"
    printf "系统将自动从路由器获取IP地址、网关和DNS\n\n"
    
    printf "${YELLOW}注意：${NC}\n"
    printf "  • DHCP需要路由器开启DHCP服务\n"
    printf "  • 可能需要重启网络接口\n"
    printf "  • 无法保证获取到固定的IP地址\n\n"
    
    if ! confirm_with_timeout "确定要启用DHCP吗？" 10 "Y"; then
        print_info "取消配置"
        return 0
    fi
    
    read -p "主 DNS 服务器 (留空使用DHCP分配) [可选]: " dns1
    read -p "备用 DNS 服务器 (留空使用DHCP分配) [可选]: " dns2
    
    # 创建Netplan配置
    create_netplan_config "$iface" "dhcp" "" "" "" "$dns1" "$dns2"
}

configure_dns_only() {
    local iface="$1"
    
    print_menu_header "配置 DNS 服务器"
    
    printf "当前 DNS 配置：\n"
    printf "%s\n" "----------------------------------------------------------------"
    if [ -f /etc/resolv.conf ]; then
        grep -v "^#" /etc/resolv.conf | grep -v "^$"
    else
        echo "未找到 resolv.conf 文件"
    fi
    printf "%s\n" "----------------------------------------------------------------"
    
    printf "\n${BOLD}常用 DNS 服务器：${NC}\n"
    printf "1) ${GREEN}阿里云 DNS${NC}       223.5.5.5, 223.6.6.6\n"
    printf "2) ${GREEN}腾讯云 DNS${NC}       119.29.29.29, 182.254.116.116\n"
    printf "3) ${GREEN}百度 DNS${NC}         180.76.76.76\n"
    printf "4) ${GREEN}Google DNS${NC}       8.8.8.8, 8.8.4.4\n"
    printf "5) ${GREEN}Cloudflare DNS${NC}   1.1.1.1, 1.0.0.1\n"
    printf "6) 114 DNS            114.114.114.114, 114.114.115.115\n"
    printf "7) 自定义 DNS\n"
    printf "8) 返回\n"
    
    read -p "请选择 (1-8): " choice
    
    local dns_servers=""
    case $choice in
        1) dns_servers="223.5.5.5 223.6.6.6" ;;
        2) dns_servers="119.29.29.29 182.254.116.116" ;;
        3) dns_servers="180.76.76.76" ;;
        4) dns_servers="8.8.8.8 8.8.4.4" ;;
        5) dns_servers="1.1.1.1 1.0.0.1" ;;
        6) dns_servers="114.114.114.114 114.114.115.115" ;;
        7)
            read -p "请输入主 DNS 服务器: " dns1
            read -p "请输入备用 DNS 服务器 (可选): " dns2
            dns_servers="$dns1"
            [ -n "$dns2" ] && dns_servers="$dns_servers $dns2"
            ;;
        8) return 0 ;;
        *) print_error "无效选择"; return 1 ;;
    esac
    
    if [ -z "$dns_servers" ]; then
        print_error "DNS 服务器不能为空"
        return 1
    fi
    
    printf "\n将设置以下 DNS 服务器：\n"
    for dns in $dns_servers; do
        printf "  • $dns\n"
    done
    
    if ! confirm_with_timeout "确认更新 DNS 配置？" 10 "Y"; then
        return 0
    fi
    
    # 更新 resolv.conf
    update_resolv_conf "$dns_servers"
}

create_netplan_config() {
    local iface="$1"
    local mode="$2"
    local ip="$3"
    local netmask="$4"
    local gateway="$5"
    local dns1="$6"
    local dns2="$7"
    
    print_info "创建网络配置..."
    
    # 确保netplan目录存在
    mkdir -p /etc/netplan
    
    # 备份现有配置
    local backup_file="/etc/netplan/backup_$(date +%Y%m%d_%H%M%S).yaml"
    if ls /etc/netplan/*.yaml 2>/dev/null | grep -q .; then
        cp $(ls /etc/netplan/*.yaml | head -1) "$backup_file" 2>/dev/null
        print_info "原配置已备份: $backup_file"
    fi
    
    # 生成配置内容
    local config_file="/etc/netplan/99-docker-manager-${iface}.yaml"
    
    if [ "$mode" = "static" ]; then
        cat > "$config_file" << EOF
# Generated by Docker Manager Script
# Date: $(date)
# Interface: $iface
# Mode: Static
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: no
      addresses: [$ip/$netmask]
      routes:
        - to: default
          via: $gateway
      nameservers:
        addresses: [$(echo "$dns1 $dns2" | sed 's/ /, /g')]
EOF
    else  # dhcp mode
        cat > "$config_file" << EOF
# Generated by Docker Manager Script
# Date: $(date)
# Interface: $iface
# Mode: DHCP
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: yes
      dhcp4-overrides:
        route-metric: 100
EOF
        
        # 如果指定了DNS，添加到配置中
        if [ -n "$dns1" ] || [ -n "$dns2" ]; then
            sed -i "/dhcp4: yes/a\      nameservers:\n        addresses: [$(echo "$dns1 $dns2" | sed 's/ /, /g')]" "$config_file"
        fi
    fi
    
    print_success "配置已保存到: $config_file"
    print_info "配置内容："
    cat "$config_file" | sed 's/^/  /'
    
    printf "\n"
    if confirm_with_timeout "是否立即应用配置？" 5 "Y"; then
        apply_network_config "$iface"
    else
        print_info "配置已保存但未应用"
        print_info "请手动运行: sudo netplan apply"
    fi
}

apply_network_config() {
    local iface="$1"
    
    print_info "应用网络配置..."
    
    # 应用netplan配置
    if netplan apply 2>&1 | tee /tmp/netplan_apply.log; then
        print_success "网络配置应用成功！"
        
        # 等待网络稳定
        print_info "等待网络接口稳定..."
        sleep 3
        
        # 验证配置
        print_info "验证配置..."
        
        local new_ip=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        local new_gateway=$(ip route | grep default | grep "$iface" | awk '{print $3}' | head -1)
        
        printf "\n${BOLD}验证结果：${NC}\n"
        printf "  接口状态: "
        if ip link show "$iface" | grep -q "state UP"; then
            printf "${GREEN}UP${NC}\n"
        else
            printf "${YELLOW}DOWN${NC}\n"
        fi
        
        printf "  IP地址: "
        if [ -n "$new_ip" ]; then
            printf "${GREEN}$new_ip${NC}\n"
        else
            printf "${RED}未获取到IP${NC}\n"
        fi
        
        printf "  网关: "
        if [ -n "$new_gateway" ]; then
            printf "${GREEN}$new_gateway${NC}\n"
            
            printf "  网关连通性: "
            if ping -c 1 -W 2 "$new_gateway" >/dev/null 2>&1; then
                printf "${GREEN}✓ 正常${NC}\n"
            else
                printf "${RED}✗ 失败${NC}\n"
            fi
        else
            printf "${YELLOW}未配置${NC}\n"
        fi
        
        # 测试互联网连接
        printf "  互联网连接: "
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            printf "${GREEN}✓ 正常${NC}\n"
        else
            printf "${YELLOW}⚠ 受限${NC}\n"
        fi
        
        print_info "配置应用完成！如果遇到问题，请检查日志: /tmp/netplan_apply.log"
        
    else
        print_error "网络配置应用失败"
        print_info "请检查日志: /tmp/netplan_apply.log"
        
        # 恢复备份
        if [ -f "$backup_file" ]; then
            print_info "尝试恢复备份配置..."
            cp "$backup_file" "$config_file"
            netplan apply && print_info "已恢复原配置" || print_error "恢复配置失败"
        fi
    fi
}

update_resolv_conf() {
    local dns_servers="$1"
    
    # 备份原配置
    local backup_file="/etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)"
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$backup_file"
        print_info "原配置已备份: $backup_file"
    fi
    
    # 写入新配置
    cat > /etc/resolv.conf << EOF
# Generated by Docker Manager Script
# Date: $(date)
EOF
    
    for dns in $dns_servers; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    
    # 添加选项（如果系统支持）
    echo "options edns0 trust-ad" >> /etc/resolv.conf
    
    print_success "DNS配置已更新！"
    print_info "新DNS配置："
    cat /etc/resolv.conf | sed 's/^/  /'
    
    # 测试DNS
    printf "\n${BOLD}DNS测试：${NC}\n"
    for dns in $dns_servers; do
        printf "  $dns: "
        if timeout 2 nslookup baidu.com "$dns" >/dev/null 2>&1; then
            printf "${GREEN}✓ 正常${NC}\n"
        else
            printf "${RED}✗ 失败${NC}\n"
        fi
    done
}

test_interface_connection() {
    local iface="$1"
    
    print_menu_header "网络连接测试 - $iface"
    
    printf "${BOLD}🧪 基础连接测试：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    
    # 1. 测试接口状态
    printf "接口状态 ($iface): "
    if ip link show "$iface" | grep -q "state UP"; then
        printf "${GREEN}UP${NC}\n"
    else
        printf "${RED}DOWN${NC}\n"
    fi
    
    # 2. 测试IP地址
    local ip_addr=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    printf "IP地址: "
    if [ -n "$ip_addr" ]; then
        printf "${GREEN}$ip_addr${NC}\n"
    else
        printf "${RED}未获取到IP${NC}\n"
    fi
    
    # 3. 测试网关
    local gateway=$(ip route | grep default | grep "$iface" | awk '{print $3}' | head -1)
    printf "默认网关: "
    if [ -n "$gateway" ]; then
        printf "${GREEN}$gateway${NC}\n"
        
        printf "网关连通性: "
        if ping -c 2 -W 1 "$gateway" >/dev/null 2>&1; then
            printf "${GREEN}✓ 可达${NC}\n"
        else
            printf "${RED}✗ 不可达${NC}\n"
        fi
    else
        printf "${YELLOW}未配置${NC}\n"
    fi
    
    # 4. 测试DNS
    printf "\n${BOLD}📡 DNS解析测试：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    
    local dns_servers=$(grep nameserver /etc/resolv.conf 2>/dev/null | head -3 | awk '{print $2}')
    if [ -n "$dns_servers" ]; then
        local dns_count=0
        for dns in $dns_servers; do
            ((dns_count++))
            printf "DNS%d (%s): " "$dns_count" "$dns"
            if timeout 2 nslookup baidu.com "$dns" >/dev/null 2>&1; then
                printf "${GREEN}✓ 正常${NC}\n"
            else
                printf "${RED}✗ 失败${NC}\n"
            fi
        done
    else
        printf "${YELLOW}未配置DNS服务器${NC}\n"
    fi
    
    # 5. 测试公网连接
    printf "\n${BOLD}🌍 公网连接测试：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    
    printf "到 8.8.8.8 (Google): "
    if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
        printf "${GREEN}✓ 正常${NC}\n"
    else
        printf "${RED}✗ 失败${NC}\n"
    fi
    
    printf "到 1.1.1.1 (Cloudflare): "
    if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then
        printf "${GREEN}✓ 正常${NC}\n"
    else
        printf "${RED}✗ 失败${NC}\n"
    fi
    
    # 6. 测试常用网站
    printf "\n${BOLD}🌐 网站访问测试：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    
    local websites=("baidu.com" "google.com" "github.com")
    for site in "${websites[@]}"; do
        printf "$site: "
        if timeout 3 curl -s --head "http://$site" >/dev/null 2>&1 || \
           timeout 3 wget --spider -q "http://$site" 2>/dev/null; then
            printf "${GREEN}✓ 可达${NC}\n"
        else
            printf "${YELLOW}⚠ 超时${NC}\n"
        fi
    done
    
    printf "%s\n" "----------------------------------------------------------------"
    
    # 7. 端口测试
    if [ -n "$ip_addr" ]; then
        printf "\n${BOLD}🔌 本地端口监听：${NC}\n"
        printf "%s\n" "----------------------------------------------------------------"
        
        local ports=("22(SSH)" "80(HTTP)" "443(HTTPS)" "53(DNS)")
        for port_info in "${ports[@]}"; do
            port=$(echo "$port_info" | grep -oE '^[0-9]+')
            desc=$(echo "$port_info" | sed 's/^[0-9]*//')
            printf "端口$desc: "
            if ss -tuln | grep -q ":$port "; then
                printf "${GREEN}监听中${NC}\n"
            else
                printf "${GRAY}未监听${NC}\n"
            fi
        done
    fi
    
    printf "%s\n" "----------------------------------------------------------------"
    
    # 总结
    printf "\n${BOLD}📊 测试总结：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    
    local issues=0
    [ -z "$ip_addr" ] && { printf "${RED}• 未获取到IP地址${NC}\n"; ((issues++)); }
    [ -z "$gateway" ] && { printf "${YELLOW}• 未配置网关${NC}\n"; ((issues++)); }
    [ -z "$dns_servers" ] && { printf "${YELLOW}• 未配置DNS${NC}\n"; ((issues++)); }
    
    if [ $issues -eq 0 ]; then
        printf "${GREEN}✓ 网络连接正常${NC}\n"
    else
        printf "${YELLOW}⚠ 发现 $issues 个问题${NC}\n"
    fi
    
    printf "%s\n" "----------------------------------------------------------------"
}

restart_network_interface() {
    local iface="$1"
    
    print_menu_header "重启网络接口 - $iface"
    
    printf "将重启网络接口: ${CYAN}$iface${NC}\n"
    printf "${YELLOW}注意：${NC}\n"
    printf "  • 可能导致网络连接短暂中断\n"
    printf "  • SSH连接可能会断开\n"
    printf "  • 请确保有其他方式访问服务器\n\n"
    
    if ! confirm_with_timeout "确定要重启网络接口吗？" 10 "N"; then
        print_info "取消操作"
        return 0
    fi
    
    print_info "停止网络接口..."
    ip link set "$iface" down
    sleep 2
    
    print_info "启动网络接口..."
    ip link set "$iface" up
    sleep 3
    
    print_info "等待网络稳定..."
    sleep 2
    
    # 验证接口状态
    printf "\n${BOLD}接口状态：${NC}\n"
    printf "  接口: $iface\n"
    printf "  状态: "
    if ip link show "$iface" | grep -q "state UP"; then
        printf "${GREEN}UP${NC}\n"
    else
        printf "${RED}DOWN${NC}\n"
    fi
    
    # 获取新的IP
    local new_ip=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    printf "  IP地址: "
    if [ -n "$new_ip" ]; then
        printf "${GREEN}$new_ip${NC}\n"
    else
        printf "${YELLOW}未获取到IP${NC}\n"
    fi
    
    print_success "网络接口重启完成！"
    
    # 测试连接
    if confirm_with_timeout "是否测试网络连接？" 5 "Y"; then
        test_interface_connection "$iface"
    fi
}

# ==================== 网络工具菜单（优化版）====================
menu_network_tools() {
    while true; do
        print_menu_header "网络管理中心"
        
        printf "1) 网络信息概览 ${GRAY}← 接口/IP/网关/DNS状态${NC}\n"
        printf "2) 网络配置中心 ${GRAY}← 配置IP/网关/DNS${NC}\n"
        printf "3) 网络连接测试 ${GRAY}← 诊断网络问题${NC}\n"
        printf "4) 重启网络服务 ${GRAY}← 应用所有配置${NC}\n"
        printf "5) 返回主菜单 (..)\n"
        printf "\n"
        read -p "请选择 (1-5, ..): " choice
        
        case $choice in
            1) show_network_info ;;
            2) configure_network ;;
            3) test_interface_connection "all" ;;
            4) 
                if confirm_with_timeout "重启所有网络服务？这可能会中断当前连接" 10 "N"; then
                    systemctl restart systemd-networkd 2>/dev/null || true
                    systemctl restart NetworkManager 2>/dev/null || true
                    print_success "网络服务已重启"
                fi
                ;;
            5|..) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        
        echo ""
        if [ "$choice" != ".." ] && [ "$choice" != "5" ] && [ "$choice" != "1" ] && [ "$choice" != "3" ]; then
            read -p "按Enter键继续..."
        fi
    done
}

# ==================== 将修复功能添加到诊断与修复菜单 ====================
menu_diagnose_repair() {
    while true; do
        print_menu_header "诊断与修复中心"
        
        printf "1) 修复 Docker 权限 ${GRAY}← 解决 root 用户权限问题${NC}\n"
        printf "2) 修复 APT 源格式 ${GRAY}← 重置为合法 sources.list${NC}\n"
        printf "3) 清理 APT 缓存 ${GRAY}← 解决包列表读取失败${NC}\n"
        printf "4) 修复 Docker GPG 密钥 ${GRAY}← 解决签名验证错误${NC}\n"
        printf "5) 检查 Docker 服务状态 ${GRAY}← 显示 active/inactive${NC}\n"
        printf "6) 查看脚本操作日志 ${GRAY}← 最近 50 行记录${NC}\n"
        printf "7) 返回主菜单 (..)\n"
        printf "\n"
        read -p "请选择 (1-7, ..): " choice
        
        case $choice in
            1) fix_root_docker_permission ;;
            2) fix_apt_source_format ;;
            3) clean_apt_cache ;;
            4) fix_docker_gpg_key ;;
            5) check_docker_service_status ;;
            6) view_script_logs ;;
            7|..) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        
        echo ""
        if [ "$choice" != ".." ] && [ "$choice" != "7" ] && [ "$choice" != "5" ] && [ "$choice" != "6" ]; then
            read -p "按Enter键继续..."
        fi
    done
}

# ==================== 菜单6：高级工具（专家模式）====================
edit_sources_list() {
    print_menu_header "手动编辑 sources.list"
    
    if command_exists nano; then
        nano /etc/apt/sources.list
    elif command_exists vim; then
        vim /etc/apt/sources.list
    elif command_exists vi; then
        vi /etc/apt/sources.list
    else
        print_error "未找到可用的文本编辑器"
        return 1
    fi
}

edit_daemon_json() {
    print_menu_header "自定义 daemon.json"
    
    mkdir -p /etc/docker
    
    if [ ! -f /etc/docker/daemon.json ]; then
        cat > /etc/docker/daemon.json << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    fi
    
    if command_exists nano; then
        nano /etc/docker/daemon.json
    elif command_exists vim; then
        vim /etc/docker/daemon.json
    elif command_exists vi; then
        vi /etc/docker/daemon.json
    else
        cat /etc/docker/daemon.json
    fi
    
    if has_systemd && systemctl is-active --quiet docker; then
        print_info "重启 Docker 服务使配置生效..."
        systemctl restart docker
    fi
}

rebuild_all_containers() {
    print_menu_header "强制重建所有容器"
    
    confirm_danger "强制重建所有容器" "⚠️ 此操作将停止并重建所有容器！" "REBUILD" || return 1
    
    print_info "此功能待完善"
    print_info "建议使用环境快照功能导出后手动重建"
}

export_full_system_image() {
    print_menu_header "导出完整系统镜像"
    
    print_info "此功能待实现"
    print_info "可以使用 docker commit 或 docker export 命令"
}

enable_debug_mode() {
    print_menu_header "启用调试模式"
    
    printf "调试模式将输出详细的命令执行日志\n"
    printf "日志级别: DEBUG\n"
    
    LOG_LEVEL="debug"
    print_success "调试模式已启用"
    print_info "后续操作将输出详细日志"
}

view_system_info() {
    print_menu_header "查看详细系统信息"
    
    printf "${BOLD}系统信息：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    printf "系统名称: $(uname -s)\n"
    printf "内核版本: $(uname -r)\n"
    printf "系统架构: $(uname -m)\n"
    printf "主机名称: $(hostname)\n"
    printf "当前用户: $(whoami)\n"
    printf "当前时间: $(date)\n"
    printf "系统负载: $(uptime | awk -F'load average:' '{print $2}')\n"
    printf "运行时间: $(uptime -p)\n"
    printf "%s\n" "----------------------------------------------------------------"
    
    printf "\n${BOLD}内存使用：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    free -h
    printf "%s\n" "----------------------------------------------------------------"
    
    printf "\n${BOLD}磁盘使用：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    df -h /
    printf "%s\n" "----------------------------------------------------------------"
    
    printf "\n${BOLD}网络信息：${NC}\n"
    printf "%s\n" "----------------------------------------------------------------"
    ip addr show | grep -E 'inet|inet6' | grep -v '127.0.0.1' | grep -v '::1/128'
    printf "%s\n" "----------------------------------------------------------------"
}

manage_expert_mode() {
    print_menu_header "专家模式管理"
    
    printf "当前专家模式状态: "
    if [ "$EXPERT_MODE" = true ]; then
        printf "${GREEN}已启用${NC}\n"
    else
        printf "${RED}已禁用${NC}\n"
    fi
    
    printf "\n"
    printf "1) 启用专家模式\n"
    printf "2) 禁用专家模式\n"
    printf "3) 返回\n"
    
    read -p "请选择 (1-3): " choice
    
    case $choice in
        1)
            EXPERT_MODE=true
            print_success "专家模式已启用！"
            ;;
        2)
            EXPERT_MODE=false
            print_success "专家模式已禁用！"
            ;;
        3) return 0 ;;
        *) print_error "无效选择" ;;
    esac
}

menu_advanced_tools() {
    while true; do
        print_menu_header "高级工具箱"
        
        printf "1) 手动编辑 sources.list ${YELLOW}← 修改系统核心配置${NC}\n"
        printf "2) 自定义 daemon.json ${YELLOW}← 配置日志/存储驱动${NC}\n"
        printf "3) 强制重建所有容器 ${YELLOW}← 基于快照恢复${NC}\n"
        printf "4) 导出完整系统镜像 ${YELLOW}← 包含所有数据卷${NC}\n"
        printf "5) 启用调试模式 ${YELLOW}← 输出详细命令日志${NC}\n"
        printf "6) 查看详细系统信息 ${YELLOW}← 硬件/网络/内存${NC}\n"
        printf "7) 专家模式管理 ${YELLOW}← 启用/禁用专家模式${NC}\n"
        printf "8) 返回主菜单 (..)\n"
        printf "\n"
        read -p "请选择 (1-8, ..): " choice
        
        case $choice in
            1) edit_sources_list ;;
            2) edit_daemon_json ;;
            3) rebuild_all_containers ;;
            4) export_full_system_image ;;
            5) enable_debug_mode ;;
            6) view_system_info ;;
            7) manage_expert_mode ;;
            8|..) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        
        echo ""
        if [ "$choice" != ".." ] && [ "$choice" != "8" ]; then
            read -p "按Enter键继续..."
        fi
    done
}

# ==================== 非交互模式支持 ====================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --install-docker)
                check_root
                install_docker
                exit $?
                ;;
            --install-portainer)
                check_root
                install_portainer
                exit $?
                ;;
            --install-npm)
                check_root
                install_nginxpm
                exit $?
                ;;
            --install-dpanel)
                check_root
                install_dpanel
                exit $?
                ;;
            --uninstall)
                check_root
                uninstall_docker
                exit $?
                ;;
            --cleanup)
                check_root
                clean_unused_resources
                exit $?
                ;;
            --mirror)
                MIRROR="$2"
                shift
                ;;
            --no-color)
                USE_COLOR=false
                ;;
            --no-confirm)
                # 跳过确认
                ;;
            --expert)
                EXPERT_MODE=true
                ;;
            --help)
                echo "Docker 管理脚本 v3.1"
                echo "使用方法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --install-docker      安装 Docker"
                echo "  --install-portainer   安装 Portainer"
                echo "  --install-npm         安装 Nginx Proxy Manager"
                echo "  --install-dpanel      安装 DPanel"
                echo "  --uninstall           卸载 Docker（包含所有数据）"
                echo "  --cleanup             清理未使用资源"
                echo "  --mirror [source]     设置镜像源"
                echo "  --no-color            禁用颜色输出"
                echo "  --expert              启用专家模式"
                echo "  --help                显示此帮助信息"
                exit 0
                ;;
            *)
                print_error "未知选项: $1"
                echo "使用 --help 查看帮助信息"
                exit 1
                ;;
        esac
        shift
    done
}

# ==================== 修复菜单选项显示 ====================
main_menu() {
    while true; do
        # 显示标题
        clear
        printf "${PURPLE}${BOLD}╔══════════════════════════════════════╗${NC}\n"
        printf "${PURPLE}${BOLD}║        Docker 管理中心 v3.1         ║${NC}\n"
        printf "${PURPLE}${BOLD}╚══════════════════════════════════════╝${NC}\n"
        printf "\n"
        
        # 显示当前状态
        show_current_status
        
        # 主菜单选项
        print_menu_header "主菜单"
        
        # 普通模式菜单选项
        if [ "$EXPERT_MODE" = true ]; then
            print_menu_option "1" "安装与配置" "快速部署核心组件"
            print_menu_option "2" "应用管理" "管理 NPM / Portainer / DPanel"
            print_menu_option "3" "容器与服务" "查看/控制所有容器"
            print_menu_option "4" "日常维护" "清理/备份/监控"
            print_menu_option "5" "诊断与修复" "解决 APT/Docker 问题"
            print_menu_option "6" "网络工具" "IP/网关/DNS 管理"
            print_menu_option "7" "高级工具" "专家模式专用功能"
            print_menu_option "8" "查看帮助 (h)" "使用指南与快捷键"
            printf "9) 退出 (q)\n"
            printf "\n"
            read -p "请选择 (1-9, h, e, q): " choice
        else
            print_menu_option "1" "安装与配置" "快速部署核心组件"
            print_menu_option "2" "应用管理" "管理 NPM / Portainer / DPanel"
            print_menu_option "3" "容器与服务" "查看/控制所有容器"
            print_menu_option "4" "日常维护" "清理/备份/监控"
            print_menu_option "5" "诊断与修复" "解决 APT/Docker 问题"
            print_menu_option "6" "网络工具" "IP/网关/DNS 管理"
            print_menu_option "7" "查看帮助 (h)" "使用指南与快捷键"
            printf "8) 退出 (q)\n"
            printf "\n"
            read -p "请选择 (1-8, h, e, q): " choice
        fi
        
        # 处理快捷键
        case $choice in
            h|H|"?")
                print_help_box
                continue
                ;;
            e|E)
                if [ "$EXPERT_MODE" = true ]; then
                    EXPERT_MODE=false
                    print_success "专家模式已禁用！"
                else
                    EXPERT_MODE=true
                    print_success "专家模式已启用！"
                fi
                read -p "按Enter键继续..."
                continue
                ;;
            q|Q)
                print_success "感谢使用，再见！"
                exit 0
                ;;
        esac
        
        # 处理菜单选择
        if [ "$EXPERT_MODE" = true ]; then
            case $choice in
                1) menu_install_configure ;;
                2) menu_app_management ;;
                3) menu_container_service ;;
                4) menu_daily_maintenance ;;
                5) menu_diagnose_repair ;;
                6) menu_network_tools ;;
                7) menu_advanced_tools ;;
                8) print_help_box ;;
                9) exit 0 ;;
                *) print_error "无效选择" ;;
            esac
        else
            case $choice in
                1) menu_install_configure ;;
                2) menu_app_management ;;
                3) menu_container_service ;;
                4) menu_daily_maintenance ;;
                5) menu_diagnose_repair ;;
                6) menu_network_tools ;;
                7) print_help_box ;;
                8) exit 0 ;;
                *) print_error "无效选择" ;;
            esac
        fi
        
        printf "\n"
        if [ "$choice" != "h" ] && [ "$choice" != "q" ] && [ "$choice" != "e" ]; then
            read -p "按Enter键继续..."
        fi
    done
}

# ==================== 脚本入口 ====================
main() {
    # 解析命令行参数
    parse_arguments "$@"
    
    # 检查root权限
    check_root
    
    # 创建日志目录
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$(dirname "$CONFIG_FILE")"  # 添加这行
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    # 初始日志轮转
    setup_log_rotation
    
    # 显示欢迎信息
    printf "\n"
    printf "${PURPLE}${BOLD}=========================================${NC}\n"
    printf "${PURPLE}${BOLD}   Docker 一站式管理脚本 v3.1          ${NC}\n"
    printf "${PURPLE}${BOLD}=========================================${NC}\n"
    printf "\n"
    
    print_info "日志文件: $LOG_FILE"
    local mode_str="普通模式"
    [ "$EXPERT_MODE" = true ] && mode_str="专家模式"
    print_info "配置模式: $mode_str"
    
    # 预检查
    if [ -f "/etc/apt/sources.list" ] && apt-get update 2>&1 | grep -q "Malformed line"; then
        print_error "APT 源文件损坏！"
        print_info "建议：运行诊断与修复菜单选项 1 自动修复"
        print_info "手动路径：/etc/apt/sources.list"
        echo ""
        
        if confirm_with_timeout "是否尝试自动修复？" 10 "Y"; then
            fix_apt_source_format
        fi
    fi
    
    # 进入主菜单
    main_menu
}

# 优雅退出
trap 'printf "\n${YELLOW}脚本被中断${NC}\n"; exit 0' INT TERM

# 启动主函数
main "$@"
