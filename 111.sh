#!/bin/bash
# 文件名：docker-manager.sh
# 描述：Docker、Docker Compose、Portainer、DPanel和Nginx Proxy Manager的安装与管理工具
# 版本：3.0 - 增加Nginx Proxy Manager支持

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置变量
DOCKER_CONFIG_DIR="/etc/docker"
DOCKER_DAEMON_CONFIG="$DOCKER_CONFIG_DIR/daemon.json"
PORTAINER_DIR="/opt/portainer"
PORTAINER_COMPOSE_FILE="$PORTAINER_DIR/docker-compose.yml"
CURRENT_USER=$(logname 2>/dev/null || echo $SUDO_USER)

# 全局状态变量
DOCKER_INSTALLED=false
COMPOSE_INSTALLED=false
PORTAINER_INSTALLED=false
PORTAINER_RUNNING=false
DPANEL_INSTALLED=false
DPANEL_RUNNING=false
NGINXPM_INSTALLED=false
NGINXPM_RUNNING=false

# ==================== 基础函数（必须放在最前面） ====================

# 函数：打印彩色消息
print_color() {
    echo -e "${2}${1}${NC}"
}

# 函数：检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_color "请使用sudo运行此脚本: sudo $0" "$RED"
        exit 1
    fi
}

# 函数：显示标题
show_title() {
    clear
    print_color "=========================================" "$PURPLE"
    print_color "     Docker 一站式管理脚本" "$CYAN"
    print_color "    支持 Docker, Portainer, DPanel, Nginx Proxy Manager" "$CYAN"
    print_color "=========================================" "$PURPLE"
    echo ""
}

# ==================== 新增：Docker配置函数 ====================

# 函数：配置Docker镜像加速器
configure_docker_mirrors() {
    echo ""
    print_color "配置Docker镜像加速器..." "$YELLOW"
    
    # 创建配置目录
    mkdir -p $DOCKER_CONFIG_DIR
    
    # 备份原有配置
    if [ -f "$DOCKER_DAEMON_CONFIG" ]; then
        cp "$DOCKER_DAEMON_CONFIG" "$DOCKER_DAEMON_CONFIG.backup.$(date +%Y%m%d%H%M%S)"
    fi
    
    # 创建/更新配置
    cat > "$DOCKER_DAEMON_CONFIG" << 'EOF'
{
  "registry-mirrors": [
    "https://cf07taoe.mirror.aliyuncs.com",
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com",
    "https://registry.docker-cn.com"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ]
}
EOF
    
    if [ $? -eq 0 ]; then
        print_color "✓ Docker镜像加速器配置完成" "$GREEN"
        return 0
    else
        print_color "✗ 配置失败" "$RED"
        return 1
    fi
}

# 函数：创建docker用户组并添加用户
setup_docker_group() {
    echo ""
    print_color "配置Docker用户组..." "$YELLOW"
    
    # 检查docker组是否存在
    if ! getent group docker > /dev/null; then
        print_color "创建docker用户组..." "$YELLOW"
        groupadd docker
        if [ $? -eq 0 ]; then
            print_color "✓ docker用户组已创建" "$GREEN"
        else
            print_color "✗ 创建docker用户组失败" "$RED"
            return 1
        fi
    else
        print_color "docker用户组已存在" "$GREEN"
    fi
    
    # 添加当前用户到docker组
    if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
        print_color "将用户 $CURRENT_USER 添加到docker组..." "$YELLOW"
        if ! id -nG "$CURRENT_USER" | grep -qw "docker"; then
            usermod -aG docker "$CURRENT_USER"
            if [ $? -eq 0 ]; then
                print_color "✓ 用户已添加到docker组" "$GREEN"
            else
                print_color "✗ 添加用户到docker组失败" "$RED"
                return 1
            fi
        else
            print_color "用户已在docker组中" "$GREEN"
        fi
    fi
    
    # 修复docker.socket配置
    fix_docker_socket
    
    return 0
}

# 函数：修复docker.socket配置
fix_docker_socket() {
    echo ""
    print_color "修复docker.socket配置..." "$YELLOW"
    
    local docker_socket_file="/lib/systemd/system/docker.socket"
    
    if [ -f "$docker_socket_file" ]; then
        # 备份原文件
        cp "$docker_socket_file" "${docker_socket_file}.backup.$(date +%Y%m%d%H%M%S)"
        
        # 修复SocketGroup设置
        sed -i 's/^SocketGroup=.*$/SocketGroup=docker/' "$docker_socket_file"
        
        # 确保配置正确
        if ! grep -q "SocketGroup=docker" "$docker_socket_file"; then
            print_color "更新docker.socket配置..." "$YELLOW"
            cat > "$docker_socket_file" << 'EOF'
[Unit]
Description=Docker Socket for the API
PartOf=docker.service

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF
        fi
        
        # 重新加载systemd配置
        systemctl daemon-reload
        
        print_color "✓ docker.socket配置已修复" "$GREEN"
    else
        print_color "⚠ docker.socket文件不存在，跳过修复" "$YELLOW"
    fi
}

# 函数：验证Docker安装
verify_docker_installation() {
    echo ""
    print_color "验证Docker安装..." "$YELLOW"
    
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        print_color "尝试 $attempt/$max_attempts..." "$YELLOW"
        
        # 检查Docker服务状态
        if systemctl is-active docker > /dev/null 2>&1; then
            print_color "✓ Docker服务正在运行" "$GREEN"
            
            # 检查docker.sock权限
            if [ -e "/var/run/docker.sock" ]; then
                local sock_group=$(stat -c %G /var/run/docker.sock 2>/dev/null)
                if [ "$sock_group" = "docker" ]; then
                    print_color "✓ docker.sock权限正确 (组: $sock_group)" "$GREEN"
                else
                    print_color "⚠ docker.sock组为 $sock_group (应为 docker)" "$YELLOW"
                    chown root:docker /var/run/docker.sock
                    chmod 660 /var/run/docker.sock
                fi
            fi
            
            # 测试Docker命令
            if docker info > /dev/null 2>&1; then
                print_color "✓ Docker命令测试成功" "$GREEN"
                
                # 测试非root用户权限（如果配置了）
                if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
                    print_color "测试用户 $CURRENT_USER 的Docker权限..." "$YELLOW"
                    if su - "$CURRENT_USER" -c "docker info > /dev/null 2>&1"; then
                        print_color "✓ 用户 $CURRENT_USER 的Docker权限正常" "$GREEN"
                    else
                        print_color "⚠ 用户 $CURRENT_USER 的Docker权限可能需要重新登录" "$YELLOW"
                    fi
                fi
                
                return 0
            else
                print_color "✗ Docker命令测试失败" "$RED"
            fi
        else
            print_color "启动Docker服务..." "$YELLOW"
            systemctl start docker
            sleep 2
        fi
        
        attempt=$((attempt + 1))
        sleep 3
    done
    
    print_color "✗ Docker安装验证失败" "$RED"
    return 1
}

# ==================== 状态检查函数 ====================

# 函数：检查 Portainer 状态
check_portainer_status() {
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^portainer$"; then
        PORTAINER_INSTALLED=true
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^portainer$"; then
            PORTAINER_RUNNING=true
            PORTAINER_STATUS="运行中"
        else
            PORTAINER_RUNNING=false
            PORTAINER_STATUS="已停止"
        fi
    else
        PORTAINER_INSTALLED=false
        PORTAINER_RUNNING=false
        PORTAINER_STATUS="未安装"
    fi
}

# 函数：检查 DPanel 状态
check_dpanel_status() {
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^dpanel$"; then
        DPANEL_INSTALLED=true
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^dpanel$"; then
            DPANEL_RUNNING=true
            DPANEL_STATUS="运行中"
        else
            DPANEL_RUNNING=false
            DPANEL_STATUS="已停止"
        fi
    else
        DPANEL_INSTALLED=false
        DPANEL_RUNNING=false
        DPANEL_STATUS="未安装"
    fi
}

# 函数：检查 Nginx Proxy Manager 状态
check_nginxpm_status() {
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^nginx-proxy-manager$"; then
        NGINXPM_INSTALLED=true
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^nginx-proxy-manager$"; then
            NGINXPM_RUNNING=true
            NGINXPM_STATUS="运行中"
        else
            NGINXPM_RUNNING=false
            NGINXPM_STATUS="已停止"
        fi
    else
        NGINXPM_INSTALLED=false
        NGINXPM_RUNNING=false
        NGINXPM_STATUS="未安装"
    fi
}

# 函数：更新状态信息
update_status() {
    # 检查Docker安装状态
    if command -v docker &> /dev/null; then
        DOCKER_INSTALLED=true
        DOCKER_VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//' || echo "未知版本")
    else
        DOCKER_INSTALLED=false
        DOCKER_VERSION="未安装"
    fi
    
    # 检查Docker Compose安装状态
    if command -v docker-compose &> /dev/null; then
        COMPOSE_INSTALLED=true
        COMPOSE_VERSION=$(docker-compose --version 2>/dev/null | awk '{print $3}' | sed 's/,//' || echo "未知版本")
        COMPOSE_TYPE="独立版本"
    elif docker compose version &> /dev/null; then
        COMPOSE_INSTALLED=true
        COMPOSE_VERSION=$(docker compose version 2>/dev/null | awk '{print $4}' || echo "未知版本")
        COMPOSE_TYPE="Docker插件"
    else
        COMPOSE_INSTALLED=false
        COMPOSE_VERSION="未安装"
        COMPOSE_TYPE=""
    fi
    
    # 检查Portainer安装状态
    check_portainer_status
    
    # 检查 DPanel 状态
    check_dpanel_status
    
    # 检查 Nginx Proxy Manager 状态
    check_nginxpm_status
}

# 函数：显示当前状态
show_current_status() {
    update_status
    
    echo ""
    print_color "========== 当前状态 ==========" "$BLUE"
    echo ""
    echo "系统版本: $(lsb_release -ds 2>/dev/null || echo "未知")"
    echo "当前用户: $CURRENT_USER"
    echo "Docker:          $([ $DOCKER_INSTALLED = true ] && echo -e "${GREEN}✓ $DOCKER_VERSION${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "Docker Compose:  $([ $COMPOSE_INSTALLED = true ] && echo -e "${GREEN}✓ $COMPOSE_VERSION ($COMPOSE_TYPE)${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "Portainer:       $([ $PORTAINER_INSTALLED = true ] && echo -e "${GREEN}✓ 已安装 ($PORTAINER_STATUS)${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "DPanel:          $([ $DPANEL_INSTALLED = true ] && echo -e "${GREEN}✓ 已安装 ($DPANEL_STATUS)${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "Nginx Proxy Mgr: $([ $NGINXPM_INSTALLED = true ] && echo -e "${GREEN}✓ 已安装 ($NGINXPM_STATUS)${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    
    if [ $DOCKER_INSTALLED = true ]; then
        echo ""
        print_color "Docker服务状态:" "$YELLOW"
        if systemctl is-active docker &> /dev/null; then
            print_color "  ✓ 运行中" "$GREEN"
        else
            print_color "  ✗ 未运行" "$RED"
        fi
        
        # 显示docker.sock权限
        if [ -e "/var/run/docker.sock" ]; then
            local sock_group=$(stat -c %G /var/run/docker.sock 2>/dev/null || echo "未知")
            echo "docker.sock权限: $([ "$sock_group" = "docker" ] && echo -e "${GREEN}✓ $sock_group${NC}" || echo -e "${RED}✗ $sock_group${NC}")"
        fi
    fi
    echo ""
}

# ==================== APT相关函数 ====================

# 函数：修复APT源文件
fix_apt_sources() {
    echo ""
    print_color "========== 修复APT源文件 ==========" "$BLUE"
    echo ""
    
    # 备份原文件
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d%H%M%S)
        print_color "已备份原文件到: /etc/apt/sources.list.backup" "$GREEN"
    fi
    
    # 提供修复选项
    echo ""
    echo "检测到APT源文件格式问题，选择修复方式:"
    echo "  1) 自动修复（使用阿里云源替换）"
    echo "  2) 手动编辑"
    echo "  3) 跳过修复（可能会导致安装失败）"
    echo ""
    
    read -p "请选择 (1-3, 默认1): " fix_choice
    
    case ${fix_choice:-1} in
        1)
            auto_fix_sources
            ;;
        2)
            print_color "使用nano编辑器打开文件..." "$YELLOW"
            nano /etc/apt/sources.list
            ;;
        3)
            print_color "跳过修复，继续..." "$YELLOW"
            return 0
            ;;
    esac
    
    # 测试修复结果
    if apt-get update 2>&1 | grep -q "Malformed entry"; then
        print_color "修复失败，仍然存在格式问题" "$RED"
        return 1
    else
        print_color "✓ APT源文件修复成功" "$GREEN"
        return 0
    fi
}

# 函数：自动修复源文件
auto_fix_sources() {
    print_color "正在自动修复APT源文件..." "$YELLOW"
    
    # 获取系统版本
    UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
    
    # 创建新的sources.list文件
    cat > /tmp/sources.list.fixed << EOF
# 系统源 - 由脚本自动修复
# Ubuntu ${UBUNTU_CODENAME} 阿里云镜像源

# 主源
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
# deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse

# 更新源
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
# deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse

# 安全更新源
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
# deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse

# 向后兼容源
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
# deb-src https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
EOF
    
    # 替换原文件
    mv /tmp/sources.list.fixed /etc/apt/sources.list
    chmod 644 /etc/apt/sources.list
    
    print_color "✓ APT源文件已替换为阿里云镜像源" "$GREEN"
}

# 函数：检查APT源状态
check_apt_status() {
    echo ""
    print_color "检查APT源状态..." "$YELLOW"
    
    # 检查是否有格式错误
    if apt-get update 2>&1 | grep -q "Malformed entry"; then
        print_color "检测到APT源格式错误" "$RED"
        fix_apt_sources
        return $?
    fi
    
    # 测试网络连接
    print_color "测试网络连接..." "$YELLOW"
    if ping -c 2 -W 2 mirrors.aliyun.com >/dev/null 2>&1; then
        print_color "✓ 网络连接正常" "$GREEN"
        return 0
    else
        print_color "✗ 网络连接失败" "$RED"
        return 1
    fi
}

# 函数：修复APT问题
fix_apt_problem() {
    echo ""
    print_color "========== 修复APT问题 ==========" "$BLUE"
    echo ""
    
    echo "选择修复选项:"
    echo "  1) 修复sources.list格式问题"
    echo "  2) 清理APT缓存"
    echo "  3) 修复GPG密钥"
    echo "  4) 完全重置APT源（使用阿里云）"
    echo ""
    
    read -p "请选择 (1-4): " fix_option
    
    case $fix_option in
        1)
            fix_apt_sources
            ;;
        2)
            print_color "清理APT缓存..." "$YELLOW"
            apt-get clean
            apt-get autoclean
            rm -rf /var/lib/apt/lists/*
            apt-get update
            print_color "✓ APT缓存已清理" "$GREEN"
            ;;
        3)
            print_color "修复GPG密钥..." "$YELLOW"
            apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 3B4FE6ACC0B21F32 871920D1991BC93C 2>&1 | grep -v "Warning"
            apt-get update
            print_color "✓ GPG密钥已修复" "$GREEN"
            ;;
        4)
            print_color "完全重置APT源..." "$YELLOW"
            auto_fix_sources
            apt-get update
            print_color "✓ APT源已重置" "$GREEN"
            ;;
        *)
            print_color "无效选择" "$RED"
            ;;
    esac
}

# ==================== 依赖安装函数 ====================

# 函数：安装系统依赖
install_dependencies() {
    print_color "安装系统依赖..." "$YELLOW"
    
    # 先尝试修复APT源
    if ! check_apt_status; then
        return 1
    fi
    
    # 安装依赖包
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        nano 2>/dev/null
    
    return $?
}

# ==================== Docker安装函数 ====================

# 函数：使用阿里云源安装Docker（推荐）
install_docker_aliyun() {
    print_color "使用阿里云镜像源安装Docker..." "$YELLOW"
    
    # 卸载旧版本
    print_color "卸载旧版本..." "$YELLOW"
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # 安装依赖
    if ! install_dependencies; then
        print_color "✗ 安装依赖失败" "$RED"
        return 1
    fi
    
    # 添加阿里云Docker源
    print_color "添加阿里云Docker源..." "$YELLOW"
    
    # 创建目录
    mkdir -p /etc/apt/keyrings
    
    # 下载GPG密钥
    if ! curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker-aliyun.gpg; then
        print_color "下载GPG密钥失败，尝试使用官方密钥..." "$YELLOW"
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker-aliyun.gpg || {
            print_color "✗ 无法下载GPG密钥" "$RED"
            return 1
        }
    fi
    
    chmod a+r /etc/apt/keyrings/docker-aliyun.gpg
    
    # 添加仓库
    UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker-aliyun.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $UBUNTU_CODENAME stable" > /etc/apt/sources.list.d/docker-aliyun.list
    
    # 更新包列表
    apt-get update
    
    # 安装Docker
    print_color "安装Docker引擎..." "$YELLOW"
    if apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        print_color "✓ Docker安装完成！" "$GREEN"
        
        # 启动并启用服务
        systemctl start docker
        systemctl enable docker
        
        # 配置镜像加速器
        configure_docker_mirrors
        
        # 配置用户组和权限
        setup_docker_group
        
        # 重启Docker使配置生效
        print_color "重启Docker服务使配置生效..." "$YELLOW"
        systemctl restart docker
        
        # 验证安装
        if verify_docker_installation; then
            print_color "✓ Docker安装验证成功！" "$GREEN"
            print_color "✓ Docker版本: $(docker --version | head -1)" "$GREEN"
            
            # 提示用户可能需要重新登录
            if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
                echo ""
                print_color "重要提示:" "$CYAN"
                print_color "用户 $CURRENT_USER 已添加到docker组，但需要重新登录或注销后重新登录才能生效。" "$YELLOW"
                print_color "或者可以运行以下命令立即生效:" "$YELLOW"
                print_color "  newgrp docker" "$GREEN"
            fi
            
            return 0
        else
            print_color "⚠ Docker安装但验证失败" "$YELLOW"
            
            # 显示诊断信息
            echo ""
            print_color "诊断信息:" "$CYAN"
            systemctl status docker --no-pager
            echo ""
            ls -la /var/run/docker.sock 2>/dev/null || echo "docker.sock不存在"
            
            return 1
        fi
    else
        print_color "✗ Docker安装失败" "$RED"
        return 1
    fi
}

# 函数：使用系统仓库安装Docker
install_docker_system() {
    print_color "使用系统仓库安装Docker (docker.io)..." "$YELLOW"
    
    # 更新包列表
    apt-get update
    
    # 安装docker.io
    if apt-get install -y docker.io docker-compose; then
        print_color "✓ Docker安装完成！" "$GREEN"
        
        # 启动服务
        systemctl start docker
        systemctl enable docker
        
        # 配置用户组和权限
        setup_docker_group
        
        # 重启服务
        systemctl restart docker
        
        # 验证
        if docker --version &> /dev/null; then
            print_color "✓ Docker版本: $(docker --version | head -1)" "$GREEN"
            return 0
        fi
    else
        print_color "✗ Docker安装失败" "$RED"
        return 1
    fi
}

# 函数：安装Docker
install_docker() {
    echo ""
    print_color "========== 安装 Docker ==========" "$BLUE"
    echo ""
    
    # 检查是否已安装
    if command -v docker &> /dev/null; then
        print_color "Docker已经安装: $(docker --version | head -1)" "$GREEN"
        read -p "是否重新安装？ (y/N): " reinstall
        if [[ ! $reinstall =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    # 先检查APT源
    if ! check_apt_status; then
        print_color "APT源存在问题，请先修复" "$RED"
        return 1
    fi
    
    echo "选择安装源:"
    echo "  1) 阿里云镜像源 (推荐，解决网络问题)"
    echo "  2) 使用系统仓库 (docker.io)"
    echo ""
    
    read -p "请选择 (1-2, 默认1): " source_choice
    
    case ${source_choice:-1} in
        1)
            install_docker_aliyun
            ;;
        2)
            install_docker_system
            ;;
        *)
            install_docker_aliyun
            ;;
    esac
    
    # 更新状态
    update_status
}

# ==================== Docker Compose安装函数 ====================

# 函数：安装Docker Compose
install_docker_compose() {
    echo ""
    print_color "========== 安装 Docker Compose ==========" "$BLUE"
    echo ""
    
    # 检查是否已安装
    if docker compose version &> /dev/null || docker-compose --version &> /dev/null; then
        print_color "Docker Compose已经安装" "$GREEN"
        if docker compose version &> /dev/null; then
            docker compose version
        else
            docker-compose --version
        fi
        return 0
    fi
    
    # 检查Docker是否安装
    if ! command -v docker &> /dev/null; then
        print_color "请先安装Docker" "$RED"
        return 1
    fi
    
    print_color "安装Docker Compose插件（推荐）..." "$YELLOW"
    
    # 更新包列表
    apt-get update
    
    # 安装插件
    if apt-get install -y docker-compose-plugin; then
        print_color "✓ Docker Compose插件安装完成" "$GREEN"
        
        # 验证
        if docker compose version &> /dev/null; then
            docker compose version
            print_color "✓ Docker Compose安装成功！" "$GREEN"
        else
            print_color "⚠ 安装完成但验证失败" "$YELLOW"
        fi
        return 0
    else
        print_color "插件安装失败，尝试安装独立版本..." "$YELLOW"
        
        # 下载独立版本
        local compose_version="v2.24.0"
        print_color "下载 Docker Compose $compose_version..." "$YELLOW"
        
        if curl -L "https://github.com/docker/compose/releases/download/$compose_version/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose; then
            chmod +x /usr/local/bin/docker-compose
            ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
            
            if docker-compose --version &> /dev/null; then
                docker-compose --version
                print_color "✓ Docker Compose独立版本安装成功！" "$GREEN"
                return 0
            fi
        fi
        
        print_color "✗ Docker Compose安装失败" "$RED"
        return 1
    fi
}

# ==================== Portainer安装管理函数 ====================

# 函数：安装Portainer
install_portainer() {
    echo ""
    print_color "========== 安装 Portainer ==========" "$BLUE"
    echo ""
    
    # 检查Docker是否安装
    if ! command -v docker &> /dev/null; then
        print_color "请先安装Docker" "$RED"
        return 1
    fi
    
    # 检查Docker权限
    if ! docker info > /dev/null 2>&1; then
        print_color "Docker权限检查失败，尝试修复..." "$YELLOW"
        
        # 检查docker.sock权限
        if [ -e "/var/run/docker.sock" ]; then
            local sock_group=$(stat -c %G /var/run/docker.sock 2>/dev/null)
            if [ "$sock_group" != "docker" ]; then
                print_color "修复docker.sock权限..." "$YELLOW"
                chown root:docker /var/run/docker.sock
                chmod 660 /var/run/docker.sock
                systemctl restart docker
                sleep 2
            fi
        fi
    fi
    
    # 启动Docker服务
    if ! systemctl is-active docker &> /dev/null; then
        print_color "启动Docker服务..." "$YELLOW"
        systemctl start docker
        sleep 2
    fi
    
    # 检查是否已安装
    if docker ps -a --format '{{.Names}}' | grep -q "^portainer$"; then
        print_color "Portainer已经安装" "$GREEN"
        read -p "是否重新安装？ (y/N): " reinstall
        if [[ ! $reinstall =~ ^[Yy]$ ]]; then
            return 0
        fi
        
        # 停止并删除旧容器
        docker stop portainer 2>/dev/null || true
        docker rm portainer 2>/dev/null || true
    fi
    
    # 使用docker run安装
    print_color "拉取Portainer镜像..." "$YELLOW"
    if ! docker pull portainer/portainer-ce:latest; then
        print_color "镜像拉取失败" "$RED"
        return 1
    fi
    
    print_color "启动Portainer容器..." "$YELLOW"
    docker run -d \
        --name portainer \
        --restart always \
        -p 9000:9000 \
        -p 9443:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest
    
    # 检查是否启动成功
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if docker ps | grep -q portainer; then
            print_color "✓ Portainer启动成功！" "$GREEN"
            
            # 等待Portainer完全启动
            sleep 3
            
            # 获取IP地址
            local ip_address
            ip_address=$(hostname -I | awk '{print $1}' 2>/dev/null)
            if [ -z "$ip_address" ]; then
                ip_address="localhost"
            fi
            
            echo ""
            print_color "访问信息:" "$CYAN"
            print_color "  HTTPS: https://$ip_address:9443" "$YELLOW"
            print_color "  首次访问需要创建管理员账号" "$YELLOW"
            print_color "  默认用户名: admin" "$YELLOW"
            
            # 检查容器状态
            print_color "容器状态:" "$CYAN"
            docker ps --filter "name=portainer" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep 2
    done
    
    print_color "✗ Portainer启动失败" "$RED"
    
    # 显示详细错误信息
    echo ""
    print_color "错误日志:" "$CYAN"
    docker logs portainer 2>/dev/null || true
    
    # 检查端口占用
    echo ""
    print_color "端口检查:" "$CYAN"
    ss -tlnp | grep -E ':9000|:9443' || echo "端口9000和9443未占用"
    
    return 1
}

# 函数：管理 Portainer
manage_portainer() {
    echo ""
    print_color "========== Portainer 管理 ==========" "$BLUE"
    echo ""
    
    check_portainer_status
    
    if [ $PORTAINER_INSTALLED = true ]; then
        print_color "当前状态: $PORTAINER_STATUS" "$([ $PORTAINER_RUNNING = true ] && echo "$GREEN" || echo "$YELLOW")"
        echo ""
        echo "请选择操作:"
        echo "  1) 启动 Portainer"
        echo "  2) 停止 Portainer"
        echo "  3) 重启 Portainer"
        echo "  4) 查看日志"
        echo "  5) 卸载 Portainer"
        echo "  6) 返回主菜单"
        echo ""
        
        read -p "请选择 (1-6): " choice
        
        case $choice in
            1)
                docker start portainer
                print_color "Portainer 已启动" "$GREEN"
                ;;
            2)
                docker stop portainer
                print_color "Portainer 已停止" "$GREEN"
                ;;
            3)
                docker restart portainer
                print_color "Portainer 已重启" "$GREEN"
                ;;
            4)
                docker logs --tail 50 portainer
                echo ""
                read -p "按 Enter 查看更多日志，或按 Ctrl+C 停止: "
                docker logs -f portainer
                ;;
            5)
                read -p "确认卸载 Portainer？(y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    docker stop portainer 2>/dev/null || true
                    docker rm portainer 2>/dev/null || true
                    docker volume rm portainer_data 2>/dev/null || true
                    print_color "Portainer 已卸载" "$GREEN"
                fi
                ;;
            6)
                return 0
                ;;
        esac
    else
        print_color "Portainer 未安装" "$YELLOW"
        echo ""
        echo "请选择:"
        echo "  1) 安装 Portainer"
        echo "  2) 返回主菜单"
        echo ""
        
        read -p "请选择 (1-2): " choice
        
        case $choice in
            1)
                install_portainer
                ;;
            2)
                return 0
                ;;
        esac
    fi
}

# ==================== DPanel安装管理函数 ====================

# 函数：安装 DPanel
install_dpanel() {
    echo ""
    print_color "========== 安装 DPanel ==========" "$BLUE"
    echo ""
    
    # 检查Docker是否安装
    if ! command -v docker &> /dev/null; then
        print_color "请先安装Docker" "$RED"
        return 1
    fi
    
    # 启动Docker服务
    if ! systemctl is-active docker &> /dev/null; then
        print_color "启动Docker服务..." "$YELLOW"
        systemctl start docker
    fi
    
    # 检查是否已安装
    if docker ps -a --format '{{.Names}}' | grep -q "^dpanel$"; then
        print_color "DPanel已经安装" "$GREEN"
        echo ""
        echo "请选择操作:"
        echo "  1) 重新安装 DPanel"
        echo "  2) 返回主菜单"
        echo ""
        
        read -p "请选择 (1-2): " choice
        
        case $choice in
            1)
                # 停止并删除旧容器
                docker stop dpanel 2>/dev/null || true
                docker rm dpanel 2>/dev/null || true
                ;;
            2)
                return 0
                ;;
            *)
                return 0
                ;;
        esac
    fi
    
    echo "选择安装模式:"
    echo "  1) 标准安装 (端口: 80/443/8807)"
    echo "  2) 仅管理后台 (端口: 8807)"
    echo "  3) 自定义端口"
    echo ""
    read -p "请选择 (1-3, 默认2): " dpanel_mode
    
    case ${dpanel_mode:-2} in
        1)
            HTTP_PORT=80
            HTTPS_PORT=443
            ADMIN_PORT=8807
            ;;
        2)
            # 仅管理后台模式
            HTTP_PORT=""
            HTTPS_PORT=""
            ADMIN_PORT=8807
            ;;
        3)
            read -p "输入HTTP端口 (默认80): " HTTP_PORT
            HTTP_PORT=${HTTP_PORT:-80}
            read -p "输入HTTPS端口 (默认443): " HTTPS_PORT
            HTTPS_PORT=${HTTPS_PORT:-443}
            read -p "输入管理端口 (默认8807): " ADMIN_PORT
            ADMIN_PORT=${ADMIN_PORT:-8807}
            ;;
    esac
    
    # 检查端口占用
    check_port() {
        if [ -z "$1" ]; then
            # 如果是空字符串，跳过检查
            return 0
        fi
        
        if ss -tlnp | grep -q ":${1} "; then
            print_color "端口 $1 已被占用" "$RED"
            return 1
        fi
        return 0
    }
    
    # 只检查非空端口   
    if [ ! -z "$HTTP_PORT" ] && ! check_port $HTTP_PORT; then
        print_color "HTTP端口冲突，请选择其他端口" "$RED"
        return 1
    fi
    
    if [ ! -z "$HTTPS_PORT" ] && ! check_port $HTTPS_PORT; then
        print_color "HTTPS端口冲突，请选择其他端口" "$RED"
        return 1
    fi

    if ! check_port $ADMIN_PORT; then
        print_color "管理端口冲突，请选择其他端口" "$RED"
        return 1
    fi
    
    print_color "拉取DPanel镜像..." "$YELLOW"
    if ! docker pull dpanel/dpanel:latest; then
        print_color "镜像拉取失败" "$RED"
        return 1
    fi
    
    # 构建docker命令
    DOCKER_CMD="docker run -d \
        --name dpanel \
        --restart=always"

    # 添加端口映射（只添加非空的）
    if [ ! -z "$HTTP_PORT" ]; then
        DOCKER_CMD="$DOCKER_CMD -p $HTTP_PORT:80"
    fi

    if [ ! -z "$HTTPS_PORT" ]; then
        DOCKER_CMD="$DOCKER_CMD -p $HTTPS_PORT:443"
    fi

    # 管理端口是必须的
    DOCKER_CMD="$DOCKER_CMD -p $ADMIN_PORT:8080"

    # 添加其他参数
    DOCKER_CMD="$DOCKER_CMD \
        -e APP_NAME=dpanel \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v dpanel:/dpanel \
        dpanel/dpanel:latest"

    print_color "启动DPanel容器..." "$YELLOW"
    eval $DOCKER_CMD

    # 检查是否启动成功
    sleep 3
    if docker ps | grep -q dpanel; then
        print_color "✓ DPanel启动成功！" "$GREEN"
        
        local ip_address
        ip_address=$(hostname -I | awk '{print $1}' 2>/dev/null)
        if [ -z "$ip_address" ]; then
            ip_address="localhost"
        fi
        
        echo ""
        print_color "访问信息:" "$CYAN"
        print_color "  管理界面: http://$ip_address:$ADMIN_PORT" "$YELLOW"
    
        # 如果有HTTP/HTTPS端口，也显示
        if [ ! -z "$HTTP_PORT" ]; then
            print_color "  HTTP服务: http://$ip_address:$HTTP_PORT" "$YELLOW"
        fi
        if [ ! -z "$HTTPS_PORT" ]; then
            print_color "  HTTPS服务: https://$ip_address:$HTTPS_PORT" "$YELLOW"
        fi
        return 0
    else
        print_color "✗ DPanel启动失败" "$RED"
        docker logs dpanel 2>/dev/null || true
        return 1
    fi
}

# 函数：管理 DPanel
manage_dpanel() {
    echo ""
    print_color "========== DPanel 管理 ==========" "$BLUE"
    echo ""
    
    check_dpanel_status
    
    if [ $DPANEL_INSTALLED = true ]; then
        print_color "当前状态: $DPANEL_STATUS" "$([ $DPANEL_RUNNING = true ] && echo "$GREEN" || echo "$YELLOW")"
        echo ""
        echo "请选择操作:"
        echo "  1) 启动 DPanel"
        echo "  2) 停止 DPanel"
        echo "  3) 重启 DPanel"
        echo "  4) 查看日志"
        echo "  5) 卸载 DPanel"
        echo "  6) 返回主菜单"
        echo ""
        
        read -p "请选择 (1-6): " choice
        
        case $choice in
            1)
                docker start dpanel
                print_color "DPanel 已启动" "$GREEN"
                ;;
            2)
                docker stop dpanel
                print_color "DPanel 已停止" "$GREEN"
                ;;
            3)
                docker restart dpanel
                print_color "DPanel 已重启" "$GREEN"
                ;;
            4)
                docker logs --tail 50 dpanel
                echo ""
                read -p "按 Enter 查看更多日志，或按 Ctrl+C 停止: "
                docker logs -f dpanel
                ;;
            5)
                read -p "确认卸载 DPanel？(y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    docker stop dpanel 2>/dev/null || true
                    docker rm dpanel 2>/dev/null || true
                    docker volume rm dpanel 2>/dev/null || true
                    print_color "DPanel 已卸载" "$GREEN"
                fi
                ;;
            6)
                return 0
                ;;
        esac
    else
        print_color "DPanel 未安装" "$YELLOW"
        echo ""
        echo "请选择:"
        echo "  1) 安装 DPanel"
        echo "  2) 返回主菜单"
        echo ""
        
        read -p "请选择 (1-2): " choice
        
        case $choice in
            1)
                install_dpanel
                ;;
            2)
                return 0
                ;;
        esac
    fi
}

# ==================== Nginx Proxy Manager安装管理函数 ====================

# 函数：拉取Nginx Proxy Manager镜像（带重试和备用镜像）
pull_nginxpm_image() {
    local max_attempts=3
    local attempt=1
    local primary_image="jc21/nginx-proxy-manager:latest"
    local fallback_image="nginxproxy/nginx-proxy-manager:latest"
    local registry_mirror=""
    
    # 检查是否有镜像加速器配置
    if [ -f "$DOCKER_DAEMON_CONFIG" ]; then
        if grep -q "registry-mirrors" "$DOCKER_DAEMON_CONFIG"; then
            print_color "已配置Docker镜像加速器" "$GREEN"
            registry_mirror=$(grep -o '"https://[^"]*"' "$DOCKER_DAEMON_CONFIG" | head -1 | tr -d '"')
        fi
    fi
    
    # 首先尝试主镜像
    while [ $attempt -le $max_attempts ]; do
        print_color "尝试 $attempt/$max_attempts 拉取镜像: $primary_image..." "$YELLOW"
        
        if docker pull $primary_image; then
            print_color "✓ 成功拉取镜像: $primary_image" "$GREEN"
            return 0
        fi
        
        print_color "⚠ 拉取失败，等待3秒后重试..." "$YELLOW"
        sleep 3
        attempt=$((attempt + 1))
    done
    
    # 如果主镜像拉取失败，尝试备用镜像
    print_color "主镜像拉取失败，尝试备用镜像: $fallback_image..." "$YELLOW"
    attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        print_color "尝试 $attempt/$max_attempts 拉取备用镜像: $fallback_image..." "$YELLOW"
        
        if docker pull $fallback_image; then
            print_color "✓ 成功拉取备用镜像: $fallback_image" "$GREEN"
            # 给镜像打标签，使其与主镜像名称一致
            docker tag $fallback_image $primary_image
            return 0
        fi
        
        print_color "⚠ 备用镜像拉取失败，等待3秒后重试..." "$YELLOW"
        sleep 3
        attempt=$((attempt + 1))
    done
    
    # 如果备用镜像也失败，尝试使用加速器
    print_color "所有镜像拉取失败，尝试配置临时镜像加速器..." "$YELLOW"
    
    # 创建临时daemon.json文件
    if [ ! -f "$DOCKER_DAEMON_CONFIG" ]; then
        print_color "创建Docker镜像加速器配置..." "$YELLOW"
        mkdir -p $DOCKER_CONFIG_DIR
        cat > "$DOCKER_DAEMON_CONFIG" << 'EOF'
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com",
    "https://registry.docker-cn.com"
  ]
}
EOF
        systemctl restart docker
        sleep 2
    fi
    
    # 再次尝试拉取
    if docker pull $primary_image; then
        print_color "✓ 使用镜像加速器成功拉取镜像" "$GREEN"
        return 0
    fi
    
    print_color "✗ 所有镜像拉取尝试均失败" "$RED"
    return 1
}

# 函数：使用Docker Compose安装Nginx Proxy Manager（备用方案）
install_nginxpm_compose() {
    print_color "使用Docker Compose方式安装Nginx Proxy Manager..." "$YELLOW"
    
    local compose_file="/opt/nginxpm/docker-compose.yml"
    
    # 创建目录
    mkdir -p /opt/nginxpm
    
    # 创建docker-compose.yml文件
    cat > "$compose_file" << 'EOF'
version: '3.8'
services:
  app:
    image: jc21/nginx-proxy-manager:latest
    restart: always
    ports:
      - "${HTTP_PORT}:80"
      - "${ADMIN_PORT}:81"
      - "${HTTPS_PORT}:443"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      - DB_SQLITE_FILE=/data/database.sqlite
      - DISABLE_IPV6=true
EOF
    
    # 设置环境变量
    export HTTP_PORT=$1
    export ADMIN_PORT=$2
    export HTTPS_PORT=$3
    
    # 启动服务
    if docker-compose -f "$compose_file" up -d; then
        print_color "✓ Docker Compose方式启动成功" "$GREEN"
        return 0
    elif docker compose -f "$compose_file" up -d; then
        print_color "✓ Docker Compose插件方式启动成功" "$GREEN"
        return 0
    else
        print_color "✗ Docker Compose方式启动失败" "$RED"
        return 1
    fi
}

# 函数：安装 Nginx Proxy Manager
install_nginxpm() {
    echo ""
    print_color "========== 安装 Nginx Proxy Manager ==========" "$BLUE"
    echo ""
    
    # 检查Docker是否安装
    if ! command -v docker &> /dev/null; then
        print_color "请先安装Docker" "$RED"
        return 1
    fi
    
    # 检查Docker权限
    if ! docker info > /dev/null 2>&1; then
        print_color "Docker权限检查失败，尝试修复..." "$YELLOW"
        
        # 检查docker.sock权限
        if [ -e "/var/run/docker.sock" ]; then
            local sock_group=$(stat -c %G /var/run/docker.sock 2>/dev/null)
            if [ "$sock_group" != "docker" ]; then
                print_color "修复docker.sock权限..." "$YELLOW"
                chown root:docker /var/run/docker.sock
                chmod 660 /var/run/docker.sock
                systemctl restart docker
                sleep 2
            fi
        fi
    fi
    
    # 启动Docker服务
    if ! systemctl is-active docker &> /dev/null; then
        print_color "启动Docker服务..." "$YELLOW"
        systemctl start docker
        sleep 2
    fi
    
    # 检查是否已安装
    if docker ps -a --format '{{.Names}}' | grep -q "^nginx-proxy-manager$"; then
        print_color "Nginx Proxy Manager已经安装" "$GREEN"
        echo ""
        echo "请选择操作:"
        echo "  1) 重新安装 Nginx Proxy Manager"
        echo "  2) 返回主菜单"
        echo ""
        
        read -p "请选择 (1-2): " choice
        
        case $choice in
            1)
                # 停止并删除旧容器
                docker stop nginx-proxy-manager 2>/dev/null || true
                docker rm nginx-proxy-manager 2>/dev/null || true
                docker volume rm nginxpm_data 2>/dev/null || true
                docker volume rm nginxpm_letsencrypt 2>/dev/null || true
                ;;
            2)
                return 0
                ;;
            *)
                return 0
                ;;
        esac
    fi
    
    echo "选择安装模式:"
    echo "  1) 标准安装 (端口: 80/81/443)"
    echo "  2) 自定义端口"
    echo ""
    read -p "请选择 (1-2, 默认1): " nginxpm_mode
    
    case ${nginxpm_mode:-1} in
        1)
            HTTP_PORT=80
            ADMIN_PORT=81
            HTTPS_PORT=443
            ;;
        2)
            read -p "输入HTTP端口 (默认80): " HTTP_PORT
            HTTP_PORT=${HTTP_PORT:-80}
            read -p "输入管理端口 (默认81): " ADMIN_PORT
            ADMIN_PORT=${ADMIN_PORT:-81}
            read -p "输入HTTPS端口 (默认443): " HTTPS_PORT
            HTTPS_PORT=${HTTPS_PORT:-443}
            ;;
    esac
    
    # 检查端口占用
    check_port() {
        if [ -z "$1" ]; then
            return 0
        fi
        
        if ss -tlnp | grep -q ":${1} "; then
            print_color "端口 $1 已被占用" "$RED"
            return 1
        fi
        return 0
    }
    
    if ! check_port $HTTP_PORT; then
        print_color "HTTP端口冲突，请选择其他端口" "$RED"
        return 1
    fi
    
    if ! check_port $ADMIN_PORT; then
        print_color "管理端口冲突，请选择其他端口" "$RED"
        return 1
    fi

    if ! check_port $HTTPS_PORT; then
        print_color "HTTPS端口冲突，请选择其他端口" "$RED"
        return 1
    fi
    
    print_color "创建Nginx Proxy Manager数据目录..." "$YELLOW"
    mkdir -p /opt/nginxpm/data
    mkdir -p /opt/nginxpm/letsencrypt
    
    # 尝试拉取镜像
    if ! pull_nginxpm_image; then
        print_color "镜像拉取失败，尝试离线安装方案..." "$YELLOW"
        echo ""
        echo "请选择备选方案:"
        echo "  1) 使用Docker Compose方式安装"
        echo "  2) 手动下载镜像后继续"
        echo "  3) 取消安装"
        echo ""
        
        read -p "请选择 (1-3): " fallback_choice
        
        case $fallback_choice in
            1)
                if ! install_nginxpm_compose $HTTP_PORT $ADMIN_PORT $HTTPS_PORT; then
                    print_color "✗ Docker Compose安装失败" "$RED"
                    return 1
                fi
                ;;
            2)
                echo ""
                print_color "请手动下载镜像:" "$CYAN"
                print_color "1. 访问 https://hub.docker.com/r/jc21/nginx-proxy-manager" "$YELLOW"
                print_color "2. 下载镜像文件" "$YELLOW"
                print_color "3. 使用命令: docker load -i <镜像文件>" "$YELLOW"
                print_color "4. 然后重新运行此脚本" "$YELLOW"
                return 1
                ;;
            3)
                print_color "取消安装" "$YELLOW"
                return 1
                ;;
            *)
                print_color "无效选择，取消安装" "$RED"
                return 1
                ;;
        esac
    else
        # 使用docker run安装
        print_color "启动Nginx Proxy Manager容器..." "$YELLOW"
        docker run -d \
            --name=nginx-proxy-manager \
            --restart=always \
            -p $HTTP_PORT:80 \
            -p $ADMIN_PORT:81 \
            -p $HTTPS_PORT:443 \
            -v /opt/nginxpm/data:/data \
            -v /opt/nginxpm/letsencrypt:/etc/letsencrypt \
            jc21/nginx-proxy-manager:latest
    fi

    # 检查是否启动成功
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if docker ps | grep -q nginx-proxy-manager; then
            print_color "✓ Nginx Proxy Manager启动成功！" "$GREEN"
            
            # 等待服务完全启动
            sleep 5
            
            # 获取IP地址
            local ip_address
            ip_address=$(hostname -I | awk '{print $1}' 2>/dev/null)
            if [ -z "$ip_address" ]; then
                ip_address="localhost"
            fi
            
            echo ""
            print_color "访问信息:" "$CYAN"
            print_color "  管理界面: http://$ip_address:$ADMIN_PORT" "$YELLOW"
            print_color "  默认账号: admin@example.com" "$YELLOW"
            print_color "  默认密码: changeme" "$YELLOW"
            print_color "  HTTP代理端口: $HTTP_PORT" "$YELLOW"
            print_color "  HTTPS代理端口: $HTTPS_PORT" "$YELLOW"
            print_color "" "$YELLOW"
            print_color "  重要: 首次登录后请立即修改默认密码！" "$RED"
            
            # 检查容器状态
            print_color "容器状态:" "$CYAN"
            docker ps --filter "name=nginx-proxy-manager" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            
            # 显示容器日志（最后10行）
            echo ""
            print_color "启动日志:" "$CYAN"
            docker logs --tail 10 nginx-proxy-manager 2>/dev/null || true
            
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep 3
    done
    
    print_color "✗ Nginx Proxy Manager启动失败" "$RED"
    
    # 显示详细错误信息
    echo ""
    print_color "错误日志:" "$CYAN"
    docker logs nginx-proxy-manager 2>/dev/null || true
    
    # 检查端口占用
    echo ""
    print_color "端口检查:" "$CYAN"
    ss -tlnp | grep -E ":${HTTP_PORT}|:${ADMIN_PORT}|:${HTTPS_PORT}" || echo "相关端口未占用"
    
    # 提供诊断建议
    echo ""
    print_color "诊断建议:" "$CYAN"
    print_color "1. 检查端口是否被占用: netstat -tlnp | grep ':$HTTP_PORT\|:$ADMIN_PORT\|:$HTTPS_PORT'" "$YELLOW"
    print_color "2. 查看容器详细日志: docker logs nginx-proxy-manager" "$YELLOW"
    print_color "3. 检查Docker服务状态: systemctl status docker" "$YELLOW"
    
    return 1
}

# 函数：管理 Nginx Proxy Manager
manage_nginxpm() {
    echo ""
    print_color "========== Nginx Proxy Manager 管理 ==========" "$BLUE"
    echo ""
    
    check_nginxpm_status
    
    if [ $NGINXPM_INSTALLED = true ]; then
        print_color "当前状态: $NGINXPM_STATUS" "$([ $NGINXPM_RUNNING = true ] && echo "$GREEN" || echo "$YELLOW")"
        
        # 显示端口信息
        if [ $NGINXPM_RUNNING = true ]; then
            echo ""
            print_color "端口信息:" "$CYAN"
            docker ps --filter "name=nginx-proxy-manager" --format "table {{.Names}}\t{{.Ports}}"
        fi
        
        echo ""
        echo "请选择操作:"
        echo "  1) 启动 Nginx Proxy Manager"
        echo "  2) 停止 Nginx Proxy Manager"
        echo "  3) 重启 Nginx Proxy Manager"
        echo "  4) 查看日志"
        echo "  5) 查看详细状态"
        echo "  6) 重置管理员密码"
        echo "  7) 备份配置"
        echo "  8) 更新镜像"
        echo "  9) 卸载 Nginx Proxy Manager"
        echo "  10) 返回主菜单"
        echo ""
        
        read -p "请选择 (1-10): " choice
        
        case $choice in
            1)
                docker start nginx-proxy-manager
                print_color "Nginx Proxy Manager 已启动" "$GREEN"
                sleep 2
                ;;
            2)
                docker stop nginx-proxy-manager
                print_color "Nginx Proxy Manager 已停止" "$GREEN"
                ;;
            3)
                docker restart nginx-proxy-manager
                print_color "Nginx Proxy Manager 已重启" "$GREEN"
                sleep 2
                ;;
            4)
                echo ""
                print_color "最近50行日志:" "$CYAN"
                docker logs --tail 50 nginx-proxy-manager
                echo ""
                read -p "按 Enter 查看更多日志，或按 Ctrl+C 停止: "
                docker logs -f nginx-proxy-manager
                ;;
            5)
                echo ""
                print_color "容器详细信息:" "$CYAN"
                docker inspect nginx-proxy-manager --format '{{json .}}' | python3 -m json.tool 2>/dev/null || \
                docker inspect nginx-proxy-manager
                
                echo ""
                print_color "资源使用情况:" "$CYAN"
                docker stats nginx-proxy-manager --no-stream 2>/dev/null || echo "无法获取资源使用情况"
                ;;
            6)
                print_color "重置Nginx Proxy Manager管理员密码..." "$YELLOW"
                echo ""
                print_color "注意: 重置密码可能需要几分钟时间..." "$YELLOW"
                if docker exec nginx-proxy-manager /bin/bash -c "cd /app && npm run reset-password" 2>/dev/null; then
                    print_color "✓ 密码重置成功" "$GREEN"
                    print_color "新密码请查看容器日志: docker logs nginx-proxy-manager | grep -i password" "$CYAN"
                else
                    print_color "尝试使用备用方法重置密码..." "$YELLOW"
                    if docker exec nginx-proxy-manager /bin/bash -c "cd /app && node ./bin/reset-password" 2>/dev/null; then
                        print_color "✓ 密码重置成功" "$GREEN"
                    else
                        print_color "✗ 密码重置失败" "$RED"
                        print_color "请手动执行: docker exec -it nginx-proxy-manager /bin/bash" "$YELLOW"
                        print_color "然后运行: cd /app && npm run reset-password" "$YELLOW"
                    fi
                fi
                ;;
            7)
                print_color "备份Nginx Proxy Manager配置..." "$YELLOW"
                local backup_dir="/opt/nginxpm/backup-$(date +%Y%m%d-%H%M%S)"
                mkdir -p "$backup_dir"
                
                if [ -d "/opt/nginxpm/data" ]; then
                    cp -r /opt/nginxpm/data "$backup_dir/"
                    print_color "✓ 数据库配置已备份到: $backup_dir/data" "$GREEN"
                fi
                
                if [ -d "/opt/nginxpm/letsencrypt" ]; then
                    cp -r /opt/nginxpm/letsencrypt "$backup_dir/" 2>/dev/null || true
                    print_color "✓ SSL证书已备份到: $backup_dir/letsencrypt" "$GREEN"
                fi
                
                # 导出容器配置
                docker inspect nginx-proxy-manager > "$backup_dir/container-config.json" 2>/dev/null && \
                print_color "✓ 容器配置已备份到: $backup_dir/container-config.json" "$GREEN"
                
                echo ""
                print_color "备份完成，目录: $backup_dir" "$CYAN"
                ;;
            8)
                print_color "更新Nginx Proxy Manager镜像..." "$YELLOW"
                docker stop nginx-proxy-manager 2>/dev/null || true
                docker rm nginx-proxy-manager 2>/dev/null || true
                
                if pull_nginxpm_image; then
                    # 获取原容器端口映射
                    local old_ports=$(docker inspect nginx-proxy-manager --format '{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} {{end}}' 2>/dev/null || echo "")
                    
                    if [ ! -z "$old_ports" ]; then
                        print_color "使用原有端口配置重新创建容器..." "$YELLOW"
                        # 这里可以根据需要重新创建容器
                        print_color "请手动重新创建容器或使用备份恢复" "$YELLOW"
                    else
                        print_color "请重新运行安装程序创建新容器" "$YELLOW"
                    fi
                else
                    print_color "✗ 镜像更新失败" "$RED"
                fi
                ;;
            9)
                read -p "确认卸载 Nginx Proxy Manager？(y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    print_color "停止容器..." "$YELLOW"
                    docker stop nginx-proxy-manager 2>/dev/null || true
                    
                    print_color "删除容器..." "$YELLOW"
                    docker rm nginx-proxy-manager 2>/dev/null || true
                    
                    print_color "是否删除数据目录？" "$YELLOW"
                    read -p "删除 /opt/nginxpm 目录？(y/N): " delete_data
                    if [[ $delete_data =~ ^[Yy]$ ]]; then
                        rm -rf /opt/nginxpm
                        print_color "✓ 数据目录已删除" "$GREEN"
                    else
                        print_color "✓ 数据目录保留在 /opt/nginxpm" "$GREEN"
                    fi
                    
                    print_color "是否删除镜像？" "$YELLOW"
                    read -p "删除Nginx Proxy Manager镜像？(y/N): " delete_image
                    if [[ $delete_image =~ ^[Yy]$ ]]; then
                        docker rmi jc21/nginx-proxy-manager:latest 2>/dev/null || true
                        docker rmi nginxproxy/nginx-proxy-manager:latest 2>/dev/null || true
                        print_color "✓ 镜像已删除" "$GREEN"
                    fi
                    
                    print_color "Nginx Proxy Manager 已卸载" "$GREEN"
                fi
                ;;
            10)
                return 0
                ;;
        esac
    else
        print_color "Nginx Proxy Manager 未安装" "$YELLOW"
        echo ""
        echo "请选择:"
        echo "  1) 安装 Nginx Proxy Manager"
        echo "  2) 返回主菜单"
        echo ""
        
        read -p "请选择 (1-2): " choice
        
        case $choice in
            1)
                install_nginxpm
                ;;
            2)
                return 0
                ;;
        esac
    fi
}

# ==================== 新增：Docker问题诊断函数 ====================

diagnose_docker_issues() {
    echo ""
    print_color "========== Docker问题诊断 ==========" "$BLUE"
    echo ""
    
    print_color "1. 检查Docker服务状态:" "$CYAN"
    systemctl status docker --no-pager
    
    echo ""
    print_color "2. 检查docker.socket状态:" "$CYAN"
    systemctl status docker.socket --no-pager 2>/dev/null || echo "docker.socket服务不存在"
    
    echo ""
    print_color "3. 检查docker.sock权限:" "$CYAN"
    if [ -e "/var/run/docker.sock" ]; then
        ls -la /var/run/docker.sock
        echo "所有者: $(stat -c %U /var/run/docker.sock 2>/dev/null)"
        echo "所属组: $(stat -c %G /var/run/docker.sock 2>/dev/null)"
        echo "权限: $(stat -c %A /var/run/docker.sock 2>/dev/null)"
    else
        echo "docker.sock不存在"
    fi
    
    echo ""
    print_color "4. 检查docker用户组:" "$CYAN"
    getent group docker || echo "docker用户组不存在"
    
    if [ -n "$CURRENT_USER" ]; then
        echo ""
        print_color "5. 检查当前用户权限:" "$CYAN"
        echo "用户: $CURRENT_USER"
        echo "所属组: $(id -nG $CURRENT_USER 2>/dev/null || echo '未知')"
        echo "是否在docker组: $(id -nG $CURRENT_USER 2>/dev/null | grep -q docker && echo '是' || echo '否')"
    fi
    
    echo ""
    print_color "6. 测试Docker命令:" "$CYAN"
    docker info 2>&1 | head -20 || echo "Docker命令执行失败"
    
    echo ""
    print_color "7. 检查Docker配置:" "$CYAN"
    if [ -f "$DOCKER_DAEMON_CONFIG" ]; then
        cat "$DOCKER_DAEMON_CONFIG" || echo "无法读取配置文件"
    else
        echo "Docker配置文件不存在: $DOCKER_DAEMON_CONFIG"
    fi
    
    echo ""
    print_color "8. 检查容器状态:" "$CYAN"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "无法获取容器信息"
    
    echo ""
    read -p "是否尝试自动修复上述问题？ (y/N): " fix_choice
    if [[ $fix_choice =~ ^[Yy]$ ]]; then
        print_color "尝试自动修复..." "$YELLOW"
        
        # 修复步骤
        setup_docker_group
        
        # 重启服务
        systemctl restart docker.socket 2>/dev/null
        systemctl restart docker
        
        sleep 2
        
        print_color "修复完成，请重新测试" "$GREEN"
        
        # 重新测试
        if docker info > /dev/null 2>&1; then
            print_color "✓ Docker修复成功！" "$GREEN"
        else
            print_color "⚠ Docker修复后仍有问题，请查看详细错误信息" "$YELLOW"
        fi
    fi
}

# ==================== 一键安装函数 ====================

# 函数：一键安装全部（修改为可选安装 Portainer 和 Nginx Proxy Manager）
install_all() {
    echo ""
    print_color "========== 一键安装全部 ==========" "$BLUE"
    echo ""
    
    # 先检查并修复APT源
    if ! check_apt_status; then
        print_color "APT源存在问题，正在尝试修复..." "$YELLOW"
        if ! fix_apt_sources; then
            print_color "✗ APT源修复失败，无法继续安装" "$RED"
            return 1
        fi
    fi
    
    # 步骤1: 安装Docker
    print_color "步骤 1/4: 安装Docker" "$CYAN"
    if ! install_docker_aliyun; then
        print_color "尝试使用系统仓库安装Docker..." "$YELLOW"
        if ! install_docker_system; then
            print_color "✗ Docker安装失败，中止安装" "$RED"
            return 1
        fi
    fi
    
    # 步骤2: 安装Docker Compose
    print_color "步骤 2/4: 安装Docker Compose" "$CYAN"
    if ! install_docker_compose; then
        print_color "⚠ Docker Compose安装失败，但继续安装其他组件" "$YELLOW"
    fi
    
    # 步骤3: 询问是否安装 Portainer
    echo ""
    read -p "是否安装 Portainer？(y/N): " install_portainer_choice
    if [[ $install_portainer_choice =~ ^[Yy]$ ]]; then
        print_color "步骤 3/4: 安装Portainer" "$CYAN"
        if ! install_portainer; then
            print_color "⚠ Portainer安装失败" "$YELLOW"
        fi
    else
        print_color "跳过 Portainer 安装" "$YELLOW"
    fi
    
    # 步骤4: 询问是否安装 Nginx Proxy Manager
    echo ""
    read -p "是否安装 Nginx Proxy Manager？(y/N): " install_nginxpm_choice
    if [[ $install_nginxpm_choice =~ ^[Yy]$ ]]; then
        print_color "步骤 4/4: 安装Nginx Proxy Manager" "$CYAN"
        if ! install_nginxpm; then
            print_color "⚠ Nginx Proxy Manager安装失败" "$YELLOW"
        fi
    else
        print_color "跳过 Nginx Proxy Manager 安装" "$YELLOW"
    fi
    
    # 显示安装结果
    echo ""
    print_color "=========================================" "$PURPLE"
    print_color "     安装完成！" "$GREEN"
    print_color "=========================================" "$PURPLE"
    echo ""
    
    update_status
    print_color "安装结果汇总:" "$CYAN"
    echo "1. Docker:          $([ $DOCKER_INSTALLED = true ] && echo -e "${GREEN}✓ $DOCKER_VERSION${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "2. Docker Compose:  $([ $COMPOSE_INSTALLED = true ] && echo -e "${GREEN}✓ $COMPOSE_VERSION${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "3. Portainer:       $([ $PORTAINER_INSTALLED = true ] && echo -e "${GREEN}✓ 已安装${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "4. DPanel:          $([ $DPANEL_INSTALLED = true ] && echo -e "${GREEN}✓ 已安装${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    echo "5. Nginx Proxy Mgr: $([ $NGINXPM_INSTALLED = true ] && echo -e "${GREEN}✓ 已安装${NC}" || echo -e "${RED}✗ 未安装${NC}")"
    
    # 显示访问信息
    echo ""
    print_color "访问信息:" "$CYAN"
    
    local ip_address
    ip_address=$(hostname -I | awk '{print $1}' 2>/dev/null)
    if [ -z "$ip_address" ]; then
        ip_address="localhost"
    fi
    
    if [ $PORTAINER_INSTALLED = true ]; then
        print_color "  Portainer: https://$ip_address:9443" "$YELLOW"
    fi
    
    if [ $NGINXPM_INSTALLED = true ]; then
        # 获取Nginx PM的管理端口
        local nginxpm_admin_port=$(docker ps --filter "name=nginx-proxy-manager" --format "{{.Ports}}" 2>/dev/null | grep -o "0.0.0.0:\([0-9]*\)->81" | cut -d: -f2 | cut -d- -f1)
        if [ -z "$nginxpm_admin_port" ]; then
            nginxpm_admin_port="81"
        fi
        print_color "  Nginx PM: http://$ip_address:$nginxpm_admin_port" "$YELLOW"
        print_color "    账号: admin@example.com 密码: changeme" "$YELLOW"
    fi
    
    # 显示重要提示
    echo ""
    print_color "重要提示:" "$CYAN"
    if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
        print_color "1. 用户 $CURRENT_USER 已添加到docker组，需要重新登录才能使用docker命令" "$YELLOW"
        print_color "   立即生效命令: newgrp docker" "$GREEN"
    fi
    print_color "2. Nginx Proxy Manager 首次登录后请立即修改默认密码" "$YELLOW"
    print_color "3. 如果遇到权限问题，请使用菜单选项12进行诊断和修复" "$YELLOW"
    echo ""
}

# ==================== 主菜单函数 ====================

# 主菜单
main_menu() {
    while true; do
        show_title
        show_current_status
        
        print_color "========== 主菜单 ==========" "$BLUE"
        echo ""
        echo "  1) 一键安装全部 (可选组件)"
        echo "  2) 安装Docker"
        echo "  3) 安装Docker Compose"
        echo "  4) 安装Portainer"
        echo "  5) 安装DPanel"
        echo "  6) 安装Nginx Proxy Manager"
        echo "  7) 管理Portainer"
        echo "  8) 管理DPanel"
        echo "  9) 管理Nginx Proxy Manager"
        echo "  10) 修复APT问题"
        echo "  11) 测试网络连接"
        echo "  12) 查看系统信息"
        echo "  13) Docker问题诊断"
        echo "  14) 退出"
        echo ""
        
        read -p "请选择操作 (1-14): " choice
        
        case $choice in
            1)
                install_all
                ;;
            2)
                install_docker
                ;;
            3)
                install_docker_compose
                ;;
            4)
                install_portainer
                ;;
            5)
                install_dpanel
                ;;
            6)
                install_nginxpm
                ;;
            7)
                manage_portainer
                ;;
            8)
                manage_dpanel
                ;;
            9)
                manage_nginxpm
                ;;
            10)
                fix_apt_problem
                ;;
            11)
                echo ""
                print_color "测试网络连接..." "$YELLOW"
                ping -c 2 mirrors.aliyun.com
                ping -c 2 download.docker.com
                ;;
            12)
                echo ""
                print_color "系统信息:" "$CYAN"
                echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
                echo "Kernel: $(uname -r)"
                echo "Arch: $(uname -m)"
                echo "Hostname: $(hostname)"
                echo "IP: $(hostname -I 2>/dev/null || echo "未知")"
                echo "当前用户: $(whoami)"
                echo "登录用户: $CURRENT_USER"
                ;;
            13)
                diagnose_docker_issues
                ;;
            14)
                print_color "感谢使用，再见！" "$GREEN"
                exit 0
                ;;
            *)
                print_color "无效的选择，请重新输入" "$RED"
                ;;
        esac
        
        echo ""
        read -p "按Enter键继续..."
    done
}

# 启动脚本前先检查APT源
pre_check() {
    echo ""
    print_color "检查系统环境..." "$YELLOW"
    
    # 检查APT源
    if apt-get update 2>&1 | grep -q "Malformed entry"; then
        print_color "检测到APT源格式问题" "$RED"
        echo "建议先选择菜单选项10修复APT问题"
        echo ""
        read -p "是否立即修复？ (Y/n): " fix_now
        if [[ ! $fix_now =~ ^[Nn]$ ]]; then
            fix_apt_sources
        fi
    fi
    
    # 检查网络
    if ! ping -c 1 -W 2 mirrors.aliyun.com >/dev/null 2>&1; then
        print_color "网络连接可能有问题" "$YELLOW"
    fi
}

# ==================== 脚本入口 ====================

# 脚本入口
check_root
pre_check
main_menu