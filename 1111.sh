#!/bin/bash
# Docker 一站式管理脚本 v3.2 (Enhanced)
# 基于 https://github.com/zhang8682/zhang8682/blob/main/ubuntu-docker.sh 优化

# ==================== 全局变量与初始化 ====================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/docker-manager.log"
CONFIG_FILE="/etc/docker-manager/config.conf"

# 自动检测终端是否支持颜色（解决 \033 乱码问题）
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    COLORS_SUPPORTED=true
else
    COLORS_SUPPORTED=false
fi

# 颜色定义（若不支持则为空）
if [ "$COLORS_SUPPORTED" = true ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    GRAY='\033[0;90m'
    NC='\033[0m' # No Color
    BOLD='\033[1m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; CYAN=''; GRAY=''; NC=''; BOLD=''
fi

EXPERT_MODE=false
MIRROR=""

# 缓存状态（避免重复查询）
declare -A CACHE_STATUS
CACHE_STATUS[docker_installed]=false
CACHE_STATUS[portainer_installed]=false
CACHE_STATUS[npm_installed]=false
CACHE_STATUS[dpanel_installed]=false

# ==================== 工具函数 ====================
log() {
    local level=${1:-INFO}
    local msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

print_info() { printf "${CYAN}[ℹ]${NC} %s\n" "$1"; log "INFO" "$1"; }
print_success() { printf "${GREEN}[✓]${NC} %s\n" "$1"; log "SUCCESS" "$1"; }
print_warning() { printf "${YELLOW}[⚠]${NC} %s\n" "$1"; log "WARNING" "$1"; }
print_error() { printf "${RED}[✗]${NC} %s\n" "$1"; log "ERROR" "$1"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }
has_systemd() { [ -d /run/systemd/system ]; }

confirm_with_timeout() {
    local prompt="$1" timeout="${2:-10}" default="${3:-N}"
    read -t "$timeout" -p "$prompt (y/N, default $default): " choice </dev/tty || true
    [[ "${choice:-$default}" =~ ^[Yy]$ ]]
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 权限运行！"
        exit 1
    fi
}

setup_log_rotation() {
    if command_exists logrotate && [ ! -f /etc/logrotate.d/docker-manager ]; then
        cat > /etc/logrotate.d/docker-manager <<EOF
$LOG_FILE {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 root root
}
EOF
    fi
}

print_menu_header() {
    local title="$1"
    printf "\n${PURPLE}${BOLD}╔════════════════════════════╗${NC}\n"
    printf "${PURPLE}${BOLD}║%*s%*s║${NC}\n" $(( (28 + ${#title}) / 2 )) "$title" $(( (28 - ${#title}) / 2 + 28 - (28 + ${#title}) / 2 )) ""
    printf "${PURPLE}${BOLD}╚════════════════════════════╝${NC}\n\n"
}

# ==================== 修复：安全进度条（防超100%，防乱码）====================
show_progress_bar() {
    local current=$1
    local total=$2
    local label=${3:-"处理中"}

    # 安全边界处理（解决 125% 问题）
    [ "$total" -le 0 ] && total=1
    [ "$current" -lt 0 ] && current=0
    [ "$current" -gt "$total" ] && current="$total"  # 关键修复：限制不超过 total

    local percent=$(( current * 100 / total ))
    local bar_width=40
    local filled=$(( current * bar_width / total ))
    local empty=$(( bar_width - filled ))

    # 使用 printf 避免 echo -e 兼容性问题（解决 \033 乱码）
    printf "\r${CYAN}[ℹ] %s ${NC}[" "$label"
    for ((i=0; i<filled; i++)); do 
        if [ "$COLORS_SUPPORTED" = true ]; then
            printf "${GREEN}█${NC}"
        else
            printf "█"
        fi
    done
    for ((i=0; i<empty; i++)); do printf " "; done
    printf "] %d%% (%d/%d)" "$percent" "$current" "$total"
}

# ==================== 新增：系统健康检查 ====================
show_system_health() {
    local disk_usage mem_usage docker_ok="❌"

    # 获取磁盘使用率（当前目录所在分区）
    disk_usage=$(df . | awk 'NR==2 {gsub(/%/,""); print $5}')
    # 获取内存使用率
    mem_usage=$(free | awk 'NR==2 {if($2>0) printf "%.0f", ($3/$2)*100; else print "0"}')

    # 检查 Docker 是否运行
    if (has_systemd && systemctl is-active --quiet docker) || [ -S /var/run/docker.sock ]; then
        docker_ok="✅"
    fi

    printf "\n${CYAN}📊 系统健康 | 磁盘: ${disk_usage}%% | 内存: ${mem_usage}%% | Docker: ${docker_ok}${NC}\n"
    if [ "$disk_usage" -gt 90 ]; then
        printf "${RED}⚠️  磁盘空间严重不足！${NC}\n"
    elif [ "$disk_usage" -gt 80 ]; then
        printf "${YELLOW}⚠️  磁盘使用率偏高${NC}\n"
    fi
    if [ "$mem_usage" -gt 85 ]; then
        printf "${RED}⚠️  内存使用过高！${NC}\n"
    fi
    printf "\n"
}

# ==================== 新增：网络诊断工具 ====================
network_diagnostics() {
    while true; do
        print_menu_header "网络诊断工具"
        printf "1) 测试到 Docker Hub 的连接 ${GRAY}← 验证外网访问${NC}\n"
        printf "2) 测试容器网络连通性 ${GRAY}← 容器内 ping 外网${NC}\n"
        printf "3) 查看 Docker 网络配置 ${GRAY}← 列出所有网络${NC}\n"
        printf "4) 修复容器网络 ${RED}← 重置 docker0 bridge${NC}\n"
        printf "5) 返回主菜单\n"
        printf "\n"
        read -p "请选择 (1-5): " choice

        case $choice in
            1)
                print_info "测试连接到 Docker Hub..."
                if ! command_exists curl; then
                    print_error "需要 curl 命令"
                    apt-get update >/dev/null 2>&1 && apt-get install -y curl 2>/dev/null || true
                fi
                if curl -I --connect-timeout 10 https://hub.docker.com >/dev/null 2>&1; then
                    print_success "可以正常访问 Docker Hub"
                else
                    print_error "无法访问 Docker Hub"
                    print_info "建议：在「安装与配置」菜单中配置镜像加速器"
                fi
                ;;
            2)
                print_info "测试容器网络（使用 alpine 镜像）..."
                if ! docker pull --quiet alpine >/dev/null 2>&1; then
                    print_warning "拉取 alpine 镜像失败，尝试使用本地镜像"
                fi
                if docker run --rm --network bridge alpine ping -c 3 -w 10 8.8.8.8 >/dev/null 2>&1; then
                    print_success "容器网络正常"
                else
                    print_error "容器无法访问外网"
                    print_info "可能原因：宿主机防火墙、DNS 或代理问题"
                fi
                ;;
            3)
                print_info "Docker 网络列表："
                docker network ls
                ;;
            4)
                print_warning "此操作将重启 Docker 服务并重置默认 bridge 网络！"
                if confirm_with_timeout "确定要修复容器网络？" 10 "N"; then
                    if has_systemd; then
                        systemctl stop docker
                        ip link delete docker0 2>/dev/null || true
                        systemctl start docker
                        print_success "Docker 网络已重置！"
                    else
                        print_error "非 systemd 系统，无法自动修复"
                    fi
                fi
                ;;
            5)
                return 0
                ;;
            *)
                print_error "无效选择"
                ;;
        esac
        printf "\n"
        if [ "$choice" != "5" ]; then
            read -p "按Enter键继续..." </dev/tty
        fi
    done
}

# ==================== 原始功能：安装与配置 ====================
install_docker() {
    if [ "${CACHE_STATUS[docker_installed]}" = true ]; then
        print_success "Docker 已安装"
        return 0
    fi

    print_info "正在安装 Docker..."
    apt-get update >/dev/null 2>&1
    apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1
    mkdir -p /etc/apt/keyrings
    if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        print_error "添加 Docker GPG 密钥失败"
        return 1
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update >/dev/null 2>&1
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
    usermod -aG docker "$USER" 2>/dev/null || true
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
    CACHE_STATUS[docker_installed]=true
    print_success "Docker 安装完成！"
}

configure_docker_mirror() {
    mkdir -p /etc/docker
    local registry_mirrors="[\"https://docker.mirrors.ustc.edu.cn\",\"https://hub-mirror.c.163.com\"]"
    if [ -n "$MIRROR" ]; then
        registry_mirrors="\"$MIRROR\""
    fi
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [$registry_mirrors],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF
    systemctl restart docker
    print_success "Docker 镜像加速已配置"
}

install_npm() {
    if [ "${CACHE_STATUS[npm_installed]}" = true ]; then
        print_success "Nginx Proxy Manager 已安装"
        return 0
    fi

    print_info "正在安装 Nginx Proxy Manager..."
    install_docker

    local steps=(create_dir pull_image create_network run_container)
    local total=${#steps[@]}
    for i in "${!steps[@]}"; do
        case $((i+1)) in
            1) mkdir -p /data/npm/{nginx,letsencrypt} ;;
            2) docker pull jc21/nginx-proxy-manager:latest >/dev/null 2>&1 ;;
            3) docker network create npm >/dev/null 2>&1 ;;
            4)
                docker run -d \
                  --name npm \
                  --network npm \
                  -p 80:80 \
                  -p 443:443 \
                  -p 81:81 \
                  -v /data/npm/nginx:/etc/nginx/conf.d \
                  -v /data/npm/letsencrypt:/etc/letsencrypt \
                  --restart unless-stopped \
                  jc21/nginx-proxy-manager:latest >/dev/null 2>&1
                ;;
        esac
        show_progress_bar $((i+1)) $total "NPM安装进度"
    done
    echo  # 换行
    CACHE_STATUS[npm_installed]=true
    print_success "Nginx Proxy Manager 安装完成！"
    printf "\n访问信息：\n"
    printf "  Web界面: http://$(hostname -I | awk '{print $1}'):81\n"
    printf "  默认账号: admin@example.com\n"
    printf "  默认密码: changeme\n\n"
}

install_portainer() {
    if [ "${CACHE_STATUS[portainer_installed]}" = true ]; then
        print_success "Portainer 已安装"
        return 0
    fi

    print_info "正在安装 Portainer..."
    install_docker
    docker volume create portainer_data >/dev/null 2>&1
    docker run -d \
      --name portainer \
      --restart always \
      -p 9000:9000 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest >/dev/null 2>&1
    CACHE_STATUS[portainer_installed]=true
    print_success "Portainer 安装完成！"
    printf "\n访问地址: http://$(hostname -I | awk '{print $1}'):9000\n\n"
}

install_dpanel() {
    if [ "${CACHE_STATUS[dpanel_installed]}" = true ]; then
        print_success "DPanel 已安装"
        return 0
    fi

    print_info "正在安装 DPanel..."
    install_docker
    docker run -d \
      --name dpanel \
      --restart always \
      -p 8080:80 \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      -v /:/host:ro \
      dpanel/dpanel:latest >/dev/null 2>&1
    CACHE_STATUS[dpanel_installed]=true
    print_success "DPanel 安装完成！"
    printf "\n访问地址: http://$(hostname -I | awk '{print $1}'):8080\n\n"
}

menu_install_configure() {
    while true; do
        print_menu_header "安装与配置中心"
        printf "1) 安装 Docker\n"
        printf "2) 配置镜像加速\n"
        printf "3) 安装 Nginx Proxy Manager\n"
        printf "4) 安装 Portainer\n"
        printf "5) 安装 DPanel\n"
        printf "6) 返回主菜单\n"
        printf "\n"
        read -p "请选择 (1-6): " choice
        case $choice in
            1) install_docker ;;
            2) configure_docker_mirror ;;
            3) install_npm ;;
            4) install_portainer ;;
            5) install_dpanel ;;
            6) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        printf "\n"
        if [ "$choice" != "6" ]; then
            read -p "按Enter键继续..." </dev/tty
        fi
    done
}

# ==================== 应用管理 ====================
menu_app_management() {
    while true; do
        print_menu_header "应用管理中心"
        printf "1) 启动/停止 NPM\n"
        printf "2) 启动/停止 Portainer\n"
        printf "3) 启动/停止 DPanel\n"
        printf "4) 卸载应用\n"
        printf "5) 返回主菜单\n"
        printf "\n"
        read -p "请选择 (1-5): " choice
        case $choice in
            1)
                if docker ps -a --format '{{.Names}}' | grep -q '^npm$'; then
                    if docker ps --format '{{.Names}}' | grep -q '^npm$'; then
                        docker stop npm && print_success "NPM 已停止"
                    else
                        docker start npm && print_success "NPM 已启动"
                    fi
                else
                    print_error "NPM 未安装"
                fi
                ;;
            2)
                if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
                    if docker ps --format '{{.Names}}' | grep -q '^portainer$'; then
                        docker stop portainer && print_success "Portainer 已停止"
                    else
                        docker start portainer && print_success "Portainer 已启动"
                    fi
                else
                    print_error "Portainer 未安装"
                fi
                ;;
            3)
                if docker ps -a --format '{{.Names}}' | grep -q '^dpanel$'; then
                    if docker ps --format '{{.Names}}' | grep -q '^dpanel$'; then
                        docker stop dpanel && print_success "DPanel 已停止"
                    else
                        docker start dpanel && print_success "DPanel 已启动"
                    fi
                else
                    print_error "DPanel 未安装"
                fi
                ;;
            4)
                print_info "卸载选项："
                printf "  a) 卸载 NPM\n"
                printf "  b) 卸载 Portainer\n"
                printf "  c) 卸载 DPanel\n"
                read -p "请选择 (a-c): " app
                case $app in
                    a) docker rm -f npm 2>/dev/null && docker volume prune -f && print_success "NPM 已卸载" ;;
                    b) docker rm -f portainer 2>/dev/null && docker volume prune -f && print_success "Portainer 已卸载" ;;
                    c) docker rm -f dpanel 2>/dev/null && print_success "DPanel 已卸载" ;;
                    *) print_error "无效选择" ;;
                esac
                ;;
            5) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        printf "\n"
        if [ "$choice" != "5" ]; then
            read -p "按Enter键继续..." </dev/tty
        fi
    done
}

# ==================== 容器与服务 ====================
menu_container_service() {
    while true; do
        print_menu_header "容器与服务管理"
        printf "1) 查看所有容器\n"
        printf "2) 查看所有镜像\n"
        printf "3) 清理无用资源\n"
        printf "4) 返回主菜单\n"
        printf "\n"
        read -p "请选择 (1-4): " choice
        case $choice in
            1) docker ps -a ;;
            2) docker images ;;
            3)
                docker system prune -f
                docker volume prune -f
                print_success "清理完成"
                ;;
            4) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        printf "\n"
        if [ "$choice" != "4" ]; then
            read -p "按Enter键继续..." </dev/tty
        fi
    done
}

# ==================== 日常维护 ====================
menu_daily_maintenance() {
    while true; do
        print_menu_header "日常维护中心"
        printf "1) 系统更新\n"
        printf "2) Docker 更新\n"
        printf "3) 查看日志\n"
        printf "4) 返回主菜单\n"
        printf "\n"
        read -p "请选择 (1-4): " choice
        case $choice in
            1)
                apt-get update && apt-get upgrade -y
                print_success "系统更新完成"
                ;;
            2)
                docker system prune -f
                docker images | grep '<none>' | awk '{print $3}' | xargs -r docker rmi
                print_success "Docker 清理完成"
                ;;
            3)
                tail -n 20 "$LOG_FILE"
                ;;
            4) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        printf "\n"
        if [ "$choice" != "4" ]; then
            read -p "按Enter键继续..." </dev/tty
        fi
    done
}

# ==================== 诊断与修复 ====================
menu_diagnose_repair() {
    while true; do
        print_menu_header "诊断与修复中心"
        printf "1) 修复 APT 源\n"
        printf "2) 重置 Docker\n"
        printf "3) 检查系统依赖\n"
        printf "4) 返回主菜单\n"
        printf "\n"
        read -p "请选择 (1-4): " choice
        case $choice in
            1)
                cp /etc/apt/sources.list /etc/apt/sources.list.bak
                echo "deb http://archive.ubuntu.com/ubuntu $(lsb_release -cs) main restricted universe multiverse" > /etc/apt/sources.list
                echo "deb http://archive.ubuntu.com/ubuntu $(lsb_release -cs)-updates main restricted universe multiverse" >> /etc/apt/sources.list
                apt-get clean && apt-get update
                print_success "APT 源已修复"
                ;;
            2)
                if confirm_with_timeout "这将删除所有容器和镜像！确认？" 10 "N"; then
                    systemctl stop docker
                    rm -rf /var/lib/docker
                    systemctl start docker
                    print_success "Docker 已重置"
                fi
                ;;
            3)
                local deps=("curl" "wget" "git" "jq")
                for dep in "${deps[@]}"; do
                    if ! command_exists "$dep"; then
                        print_warning "$dep 未安装"
                    fi
                done
                print_success "依赖检查完成"
                ;;
            4) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        printf "\n"
        if [ "$choice" != "4" ]; then
            read -p "按Enter键继续..." </dev/tty
        fi
    done
}

# ==================== 网络工具（集成网络诊断）====================
menu_network_tools() {
    while true; do
        print_menu_header "网络管理中心"
        printf "1) 网络诊断工具 ${GREEN}← 新增增强功能${NC}\n"
        printf "2) 配置静态 IP\n"
        printf "3) 配置 DNS\n"
        printf "4) 返回主菜单\n"
        printf "\n"
        read -p "请选择 (1-4): " choice
        case $choice in
            1) network_diagnostics ;;
            2)
                print_info "配置静态 IP 功能待实现"
                print_warning "请手动编辑 /etc/netplan/*.yaml"
                ;;
            3)
                print_info "当前 DNS 配置："
                cat /etc/resolv.conf
                ;;
            4) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        printf "\n"
        if [ "$choice" != "4" ]; then
            read -p "按Enter键继续..." </dev/tty
        fi
    done
}

# ==================== 高级工具 ====================
menu_advanced_tools() {
    while true; do
        print_menu_header "高级工具"
        printf "1) 专家模式开关 (${EXPERT_MODE} )\n"
        printf "2) 设置自定义镜像源\n"
        printf "3) 导出配置\n"
        printf "4) 返回主菜单\n"
        printf "\n"
        read -p "请选择 (1-4): " choice
        case $choice in
            1)
                EXPERT_MODE=$([ "$EXPERT_MODE" = true ] && echo false || echo true)
                print_success "专家模式已$( [ "$EXPERT_MODE" = true ] && echo "启用" || echo "禁用" )"
                ;;
            2)
                read -p "请输入镜像源 (留空使用默认): " MIRROR
                print_success "镜像源已设置为: $MIRROR"
                ;;
            3)
                mkdir -p "$(dirname "$CONFIG_FILE")"
                declare -p CACHE_STATUS > "$CONFIG_FILE"
                print_success "配置已导出到 $CONFIG_FILE"
                ;;
            4) return 0 ;;
            *) print_error "无效选择" ;;
        esac
        printf "\n"
        if [ "$choice" != "4" ]; then
            read -p "按Enter键继续..." </dev/tty
        fi
    done
}

# ==================== 主菜单 ====================
main_menu() {
    while true; do
        clear
        # 显示系统健康状态（新增功能）
        show_system_health
        
        print_menu_header "Docker 一站式管理"
        printf "1) 安装与配置\n"
        printf "2) 应用管理\n"
        printf "3) 容器与服务\n"
        printf "4) 日常维护\n"
        printf "5) 诊断与修复\n"
        printf "6) 网络工具 ${GREEN}← 增强版${NC}\n"
        printf "7) 高级工具\n"
        printf "8) 退出\n"
        printf "\n"
        read -p "请选择 (1-8): " choice
        case $choice in
            1) menu_install_configure ;;
            2) menu_app_management ;;
            3) menu_container_service ;;
            4) menu_daily_maintenance ;;
            5) menu_diagnose_repair ;;
            6) menu_network_tools ;;
            7) menu_advanced_tools ;;
            8) 
                print_success "感谢使用！"
                exit 0
                ;;
            *) print_error "无效选择" ;;
        esac
        printf "\n"
        if [ "$choice" != "8" ]; then
            read -p "按Enter键返回主菜单..." </dev/tty
        fi
    done
}

# ==================== 初始化与入口 ====================
initialize() {
    check_root
    setup_log_rotation
    
    # 加载缓存状态
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE" 2>/dev/null || true
    fi
    
    # 检测已安装组件
    if command_exists docker; then
        CACHE_STATUS[docker_installed]=true
        if docker ps -a --format '{{.Names}}' | grep -q '^npm$'; then
            CACHE_STATUS[npm_installed]=true
        fi
        if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
            CACHE_STATUS[portainer_installed]=true
        fi
        if docker ps -a --format '{{.Names}}' | grep -q '^dpanel$'; then
            CACHE_STATUS[dpanel_installed]=true
        fi
    fi
}

main() {
    initialize
    main_menu
}

# 启动主程序
main "$@"