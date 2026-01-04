#!/bin/bash
# docker-manager.sh - Docker 一站式管理脚本（增强完整版）
# 集成 Nginx Proxy Manager 彻底清理 + 镜像备份功能

set -e

# ==================== 全局变量 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_USER="${SUDO_USER:-$(whoami)}"

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== 工具函数 ====================
print_color() {
    local text="$1"
    local color="$2"
    echo -e "${color}${text}${NC}"
}

print_header() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE} $1 ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}\n"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 sudo 或 root 用户运行此脚本"
        exit 1
    fi
}

pre_check() {
    if ! command -v lsb_release >/dev/null 2>&1; then
        apt update && apt install -y lsb-release
    fi
    if ! command -v curl >/dev/null 2>&1; then
        apt update && apt install -y curl
    fi
}

# ==================== 状态检测 ====================
update_status() {
    DOCKER_INSTALLED=false
    COMPOSE_INSTALLED=false
    PORTAINER_INSTALLED=false
    DPANEL_INSTALLED=false
    NGINXPM_INSTALLED=false
    DOCKER_VERSION=""
    COMPOSE_VERSION=""

    if command -v docker >/dev/null 2>&1; then
        DOCKER_INSTALLED=true
        DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "未知")
    fi

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_INSTALLED=true
        COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "未知")
    fi

    if [ "$DOCKER_INSTALLED" = true ] && docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
        PORTAINER_INSTALLED=true
    fi

    if [ "$DOCKER_INSTALLED" = true ] && docker ps -a --format '{{.Names}}' | grep -q 'dpanel'; then
        DPANEL_INSTALLED=true
    fi

    if [ "$DOCKER_INSTALLED" = true ] && docker ps -a --format '{{.Names}}' | grep -q 'nginx-proxy-manager'; then
        NGINXPM_INSTALLED=true
    fi
}

show_current_status() {
    update_status
    echo ""
    print_color "========== 当前状态 ==========" "$BLUE"
    echo "系统版本: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
    echo "当前用户: $CURRENT_USER"
    echo "Docker:          $([ $DOCKER_INSTALLED = true ] && echo -e "${GREEN}✓ $DOCKER_VERSION${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "Docker Compose:  $([ $COMPOSE_INSTALLED = true ] && echo -e "${GREEN}✓ $COMPOSE_VERSION${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "Portainer:       $([ $PORTAINER_INSTALLED = true ] && echo -e "${GREEN}✓ 已安装${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "DPanel:          $([ $DPANEL_INSTALLED = true ] && echo -e "${GREEN}✓ 已安装${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "Nginx Proxy Mgr: $([ $NGINXPM_INSTALLED = true ] && echo -e "${GREEN}✓ 已安装${NC}" || echo -e "${RED}✗ 未安装${NC}")"

    if [ "$DOCKER_INSTALLED" = true ]; then
        if systemctl is-active --quiet docker; then
            print_color "Docker服务状态:  ✓ 正在运行" "$GREEN"
        else
            print_color "Docker服务状态:  ✗ 未运行" "$RED"
        fi

        if [ -S /var/run/docker.sock ]; then
            if getent group docker | grep -q "\b$CURRENT_USER\b"; then
                print_color "docker.sock权限: ✓ $CURRENT_USER" "$GREEN"
            else
                print_color "docker.sock权限: ✗ root" "$RED"
            fi
        else
            print_color "docker.sock权限: ✗ 不存在" "$RED"
        fi
    fi
}

# ==================== 安装函数 ====================
install_docker() {
    print_header "安装 Docker"
    
    # 清理旧源
    rm -f /etc/apt/sources.list.d/docker*.list
    
    # 安装依赖
    apt update
    apt install -y ca-certificates curl gnupg lsb-release
    
    # 添加 GPG 密钥（阿里云）
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # 添加源
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # 安装
    apt update
    apt remove -y containerd runc docker docker-engine docker.io 2>/dev/null || true
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # 启动服务
    systemctl enable --now docker
    
    # 用户组
    if ! getent group docker > /dev/null; then
        groupadd docker
    fi
    usermod -aG docker $CURRENT_USER
    
    print_success "Docker 安装完成！"
    sleep 2
}

install_portainer() {
    if [ "$DOCKER_INSTALLED" = false ]; then
        print_error "Docker 未安装，请先安装 Docker"
        return 1
    fi
    
    docker volume create portainer_data
    docker run -d \
        --name=portainer \
        --restart=always \
        -p 9000:9000 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest
        
    print_success "Portainer 安装完成！访问 http://服务器IP:9000"
}

install_nginxpm() {
    if [ "$DOCKER_INSTALLED" = false ]; then
        print_error "Docker 未安装，请先安装 Docker"
        return 1
    fi

    if ! systemctl is-active --quiet docker; then
        systemctl start docker
    fi

    print_color "正在拉取 Nginx Proxy Manager 镜像..." "$CYAN"
    docker pull jc21/nginx-proxy-manager:latest

    print_color "正在创建 Nginx Proxy Manager 数据目录..." "$CYAN"
    mkdir -p /opt/nginxpm/{data,letsencrypt}

    print_color "正在启动 Nginx Proxy Manager 容器..." "$CYAN"
    docker run -d \
        --name=nginx-proxy-manager \
        --restart=unless-stopped \
        -p 80:80 \
        -p 81:81 \
        -p 443:443 \
        -v /opt/nginxpm/data:/data \
        -v /opt/nginxpm/letsencrypt:/etc/letsencrypt \
        jc21/nginx-proxy-manager:latest

    print_success "Nginx Proxy Manager 安装完成！"
    print_success "Web UI: http://服务器IP:81 (默认账号 admin@example.com / changeme)"
    NGINXPM_INSTALLED=true
}

# ==================== 【核心】NPM 彻底卸载函数 ====================
uninstall_nginxpm() {
    print_header "Nginx Proxy Manager 彻底卸载"

    # === 镜像备份选项 ===
    local backup_image=false
    read -p "是否备份 Nginx Proxy Manager 镜像信息？(y/N): " backup_choice
    if [[ $backup_choice =~ ^[Yy]$ ]]; then
        backup_image=true
        local image_name="jc21/nginx-proxy-manager:latest"
        if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "$image_name"; then
            local backup_file="/root/npm-image-backup-$(date +%Y%m%d-%H%M%S).txt"
            print_color "正在备份镜像信息到 $backup_file ..." "$CYAN"
            {
                echo "Nginx Proxy Manager 镜像备份信息"
                echo "时间: $(date)"
                echo "镜像: $image_name"
                echo ""
                echo "详细信息:"
                docker inspect "$image_name" 2>/dev/null || echo "无法获取 inspect 信息"
                echo ""
                echo "镜像ID:"
                docker images --filter "reference=$image_name" --format "{{.ID}}"
            } > "$backup_file"
            print_success "镜像信息已备份到: $backup_file"
        else
            print_warning "未找到 NPM 镜像，跳过备份"
        fi
    fi

    # === 停止并删除容器 ===
    print_color "停止并删除容器..." "$CYAN"
    docker stop nginx-proxy-manager 2>/dev/null || true
    docker rm -f nginx-proxy-manager 2>/dev/null || true

    # === 删除数据卷和网络 ===
    print_color "清理 Docker 资源..." "$CYAN"
    docker volume rm -f npm-data npm-letsencrypt 2>/dev/null || true
    docker network rm nginx-proxy-manager_default 2>/dev/null || true

    # === 删除镜像（如未备份）===
    if [ "$backup_image" = false ]; then
        print_color "删除镜像..." "$CYAN"
        docker rmi -f jc21/nginx-proxy-manager:latest 2>/dev/null || true
    fi

    # === 清理顽固目录 ===
    print_color "清理配置目录..." "$CYAN"
    for dir in /opt/nginxpm /opt/nginx-proxy-manager /etc/nginx/sites-enabled/npm-* /etc/nginx/sites-available/npm-*; do
        if [ -e "$dir" ]; then
            rm -rf "$dir" && print_success "已删除: $dir" || print_warning "无法删除: $dir"
        fi
    done

    # === 清理 systemd 服务（如有）===
    if systemctl list-unit-files | grep -q "nginx-proxy-manager"; then
        systemctl stop nginx-proxy-manager 2>/dev/null || true
        systemctl disable nginx-proxy-manager 2>/dev/null || true
        rm -f /etc/systemd/system/nginx-proxy-manager.service
        systemctl daemon-reload
    fi

    # === 清理 crontab 和 hosts ===
    crontab -l 2>/dev/null | grep -v "nginx-proxy-manager\|npm" | crontab - 2>/dev/null || true
    sed -i '/nginx-proxy-manager\|npm/d' /etc/hosts 2>/dev/null || true

    # === 强制卸载占用目录 ===
    force_unmount_dir() {
        local target_dir="$1"
        if [ ! -d "$target_dir" ]; then return 0; fi
        if command -v lsof >/dev/null 2>&1; then
            local pids=($(lsof +D "$target_dir" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u))
            if [ ${#pids[@]} -gt 0 ]; then
                print_warning "目录被进程占用，尝试终止..."
                for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
                sleep 2
            fi
        fi
        if mountpoint -q "$target_dir" 2>/dev/null; then
            umount -f "$target_dir" 2>/dev/null
        fi
        rm -rf "$target_dir" 2>/dev/null && print_success "强制删除: $target_dir"
    }
    force_unmount_dir "/opt/nginxpm"

    # === 验证清理结果 ===
    print_header "验证清理结果"
    if [ ! -d "/opt/nginxpm" ]; then
        print_success "配置目录已清理"
    else
        print_warning "残留目录: /opt/nginxpm"
    fi

    if ! docker ps -a | grep -q "nginx-proxy-manager"; then
        print_success "容器已清理"
    else
        print_warning "仍有 NPM 容器存在"
    fi

    print_success "Nginx Proxy Manager 已彻底卸载！"
    NGINXPM_INSTALLED=false
}

# ==================== 管理函数 ====================
manage_nginxpm() {
    if [ "$NGINXPM_INSTALLED" = false ]; then
        print_error "Nginx Proxy Manager 未安装"
        return
    fi

    while true; do
        print_header "Nginx Proxy Manager 管理"
        echo "1) 查看日志"
        echo "2) 重启服务"
        echo "3) 卸载 Nginx Proxy Manager"
        echo "4) 返回主菜单"
        read -p "请选择操作 (1-4): " choice

        case $choice in
            1)
                docker logs -f nginx-proxy-manager
                ;;
            2)
                docker restart nginx-proxy-manager && print_success "已重启"
                ;;
            3)
                uninstall_nginxpm
                break
                ;;
            4)
                break
                ;;
            *)
                print_error "无效选择"
                ;;
        esac
    done
}

# ==================== 其他辅助函数 ====================
fix_apt_problem() {
    print_header "修复 APT 问题"
    echo "1) 修复 sources.list 格式问题"
    echo "2) 清理 APT 缓存"
    echo "3) 修复 GPG 密钥"
    echo "4) 完全重置 APT 源（使用阿里云）"
    read -p "请选择 (1-4): " opt
    
    case $opt in
        1|4)
            cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d)
            cat > /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse
EOF
            apt clean && apt update
            print_success "APT 源已重置为阿里云"
            ;;
        2)
            apt clean && apt autoclean && apt update
            print_success "APT 缓存已清理"
            ;;
        3)
            apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 7EA0A9C3F273FCD8 2>/dev/null || true
            print_success "GPG 密钥已尝试修复"
            ;;
        *)
            print_warning "跳过修复"
            ;;
    esac
}

test_network() {
    print_header "测试网络连接"
    if timeout 5 curl -s https://www.baidu.com > /dev/null; then
        print_success "网络连接正常"
    else
        print_error "网络连接失败"
    fi
}

show_system_info() {
    print_header "系统信息"
    echo "内核: $(uname -r)"
    echo "架构: $(uname -m)"
    echo "内存: $(free -h | awk '/Mem:/ {print $2}')"
    echo "磁盘: $(df -h / | awk 'NR==2 {print $2}')"
}

diagnose_docker_issues() {
    print_header "Docker 问题诊断"
    if ! systemctl is-active --quiet docker; then
        print_error "Docker 服务未运行"
        systemctl status docker --no-pager -l
    else
        print_success "Docker 服务正常"
    fi
    if [ ! -S /var/run/docker.sock ]; then
        print_error "docker.sock 不存在"
    fi
}

# ==================== 主菜单 ====================
main_menu() {
    while true; do
        show_title
        show_current_status
        print_color "========== 主菜单 ==========" "$BLUE"
        echo ""
        echo " 1) 一键安装全部 (可选组件)"
        echo " 2) 安装Docker"
        echo " 3) 安装Docker Compose"
        echo " 4) 安装Portainer"
        echo " 5) 安装DPanel"
        echo " 6) 安装Nginx Proxy Manager"
        echo " 7) 管理Portainer"
        echo " 8) 管理DPanel"
        echo " 9) 管理Nginx Proxy Manager"
        echo "10) 修复APT问题"
        echo "11) 测试网络连接"
        echo "12) 查看系统信息"
        echo "13) Docker问题诊断"
        echo "14) 退出"
        echo ""
        read -p "请选择操作 (1-14): " choice

        case $choice in
            1)
                install_docker
                install_portainer
                install_nginxpm
                ;;
            2) install_docker ;;
            3) 
                if [ "$DOCKER_INSTALLED" = false ]; then
                    print_error "请先安装 Docker"
                else
                    print_success "Docker Compose 已内置（Docker 插件）"
                fi
                ;;
            4) install_portainer ;;
            5) print_warning "DPanel 安装暂未实现" ;;
            6) install_nginxpm ;;
            7) 
                if [ "$PORTAINER_INSTALLED" = false ]; then
                    print_error "Portainer 未安装"
                else
                    docker logs -f portainer
                fi
                ;;
            8) print_warning "DPanel 管理暂未实现" ;;
            9) manage_nginxpm ;;
            10) fix_apt_problem ;;
            11) test_network ;;
            12) show_system_info ;;
            13) diagnose_docker_issues ;;
            14) print_color "感谢使用，再见！" "$GREEN"; exit 0 ;;
            *) print_error "无效的选择，请重新输入" ;;
        esac
        echo ""; read -p "按Enter键继续..."
    done
}

show_title() {
    clear
    print_color "=========================================" "$PURPLE"
    print_color "     Docker 一站式管理脚本（增强完整版）" "$CYAN"
    print_color "    支持 Docker, Portainer, DPanel, Nginx Proxy Manager" "$CYAN"
    print_color "=========================================" "$PURPLE"
}

# ==================== 脚本入口 ====================
check_root
pre_check
main_menu