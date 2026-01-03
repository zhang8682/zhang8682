#!/bin/bash

# ============================================
# Nextcloud AIO 增强诊断工具
# 版本: 2.0
# 作者: AI助手
# ============================================

set -e

# 颜色定义（如果支持）
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
    BOLD='\033[1m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''; BOLD=''
fi

# 配置
COMPOSE_FILE="/opt/nextcloud-aio/docker-compose.yml"
MASTER_CONTAINER="nextcloud-aio-mastercontainer"
LOG_FILE="/tmp/nc-aio-debug-$(date +%Y%m%d-%H%M%S).log"
TIMEOUT=5

# 辅助函数
print_header() {
    echo -e "\n${BLUE}${BOLD}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

run_cmd() {
    local cmd="$1"
    local description="$2"
    
    echo -e "\n${BOLD}$description:${NC}"
    echo "命令: $cmd"
    
    if eval "$cmd" 2>&1; then
        return 0
    else
        local exit_code=$?
        print_error "命令执行失败 (退出码: $exit_code)"
        return $exit_code
    fi
}

check_port() {
    local host="$1"
    local port="$2"
    local service="$3"
    
    if timeout $TIMEOUT nc -zv $host $port >/dev/null 2>&1; then
        print_success "$service 端口 $port 可达"
        return 0
    else
        print_error "$service 端口 $port 不可达"
        return 1
    fi
}

# 开始诊断
main() {
    echo -e "${BOLD}${BLUE}============================================${NC}"
    echo -e "${BOLD}${BLUE}      Nextcloud AIO 全面诊断工具           ${NC}"
    echo -e "${BOLD}${BLUE}============================================${NC}"
    echo -e "开始时间: $(date)"
    echo -e "日志文件: $LOG_FILE"
    echo -e "${BOLD}${BLUE}============================================${NC}"
    
    # 记录到日志文件
    exec > >(tee -a "$LOG_FILE") 2>&1
    
    # 1. 基础系统检查
    print_header "1. 系统基础检查"
    
    print_info "系统信息: $(uname -a)"
    print_info "Docker 版本: $(docker --version 2>/dev/null || echo '未安装')"
    print_info "Docker Compose 版本: $(docker compose version 2>/dev/null || echo '未安装')"
    
    # 2. Docker 容器状态
    print_header "2. Docker 容器状态检查"
    
    run_cmd "docker compose ps" "容器状态"
    run_cmd "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" "容器详情"
    
    # 检查关键容器是否运行
    local essential_containers=(
        "$MASTER_CONTAINER"
        "nextcloud-aio-nextcloud"
        "nextcloud-aio-database"
    )
    
    for container in "${essential_containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^$container$"; then
            print_success "容器 $container 正在运行"
        else
            print_error "容器 $container 未运行"
        fi
    done
    
    # 3. 网络和端口检查
    print_header "3. 网络和端口检查"
    
    # 主机端口检查
    local ports_to_check=("88" "81" "86" "8443")
    for port in "${ports_to_check[@]}"; do
        echo -e "\n检查端口 $port:"
        if ss -tlnp | grep -q ":$port "; then
            print_success "主机端口 $port 正在监听"
            ss -tlnp | grep ":$port "
        else
            print_warning "主机端口 $port 未监听"
        fi
    done
    
    # 容器端口映射
    if docker ps --format '{{.Names}}' | grep -q "^$MASTER_CONTAINER$"; then
        run_cmd "docker port $MASTER_CONTAINER" "容器端口映射"
    fi
    
    # 4. 服务连通性测试
    print_header "4. 服务连通性测试"
    
    # 外部访问测试
    echo -e "\n${BOLD}外部访问测试:${NC}"
    check_port "localhost" "88" "HTTP服务"
    check_port "localhost" "81" "管理界面"
    check_port "localhost" "86" "HTTPS服务"
    
    # 5. 容器内部检查
    print_header "5. 容器内部状态检查"
    
    if docker ps --format '{{.Names}}' | grep -q "^$MASTER_CONTAINER$"; then
        # Master容器内部
        echo -e "\n${BOLD}Master容器内部检查:${NC}"
        
        # 进程检查
        run_cmd "docker exec $MASTER_CONTAINER ps aux | head -15" "运行进程"
        
        # 端口监听
        run_cmd "docker exec $MASTER_CONTAINER netstat -tlnp 2>/dev/null | head -20" "内部端口监听"
        
        # Web服务测试
        echo -e "\n${BOLD}内部服务测试:${NC}"
        
        local internal_ports=("80" "443" "8000" "8080")
        for port in "${internal_ports[@]}"; do
            echo -n "测试内部端口 $port: "
            if docker exec $MASTER_CONTAINER timeout 2 curl -s -f http://127.0.0.1:$port >/dev/null 2>&1; then
                print_success "可达"
            else
                print_warning "不可达"
            fi
        done
        
        # Caddy配置
        if docker exec $MASTER_CONTAINER test -f /Caddyfile; then
            run_cmd "docker exec $MASTER_CONTAINER head -20 /Caddyfile" "Caddy配置"
        fi
        
        # Apache配置检查
        echo -e "\n${BOLD}Apache配置检查:${NC}"
        docker exec $MASTER_CONTAINER sh -c '
            echo "查找Apache配置文件..."
            find /etc/apache2 /usr/local/apache2/conf -name "*.conf" 2>/dev/null | head -5
            
            echo -e "\n检查Proxy配置..."
            grep -r "ProxyPass\|ProxyPreserveHost" /etc/apache2 /usr/local/apache2/conf 2>/dev/null || echo "未找到Proxy配置"
        '
        
        # 容器间连通性
        echo -e "\n${BOLD}容器间连通性测试:${NC}"
        local services=("nextcloud-aio-nextcloud:9000" "nextcloud-aio-domaincheck:11000")
        for service in "${services[@]}"; do
            local name=${service%:*}
            local port=${service#*:}
            echo -n "测试连接 $name:$port: "
            if docker exec $MASTER_CONTAINER timeout 2 curl -s -f http://$name:$port >/dev/null 2>&1; then
                print_success "可达"
            else
                print_error "不可达"
            fi
        done
        
    else
        print_error "Master容器未运行，跳过内部检查"
    fi
    
    # 6. Nextcloud特定检查
    print_header "6. Nextcloud 服务检查"
    
    if docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-nextcloud"; then
        echo -e "\n${BOLD}Nextcloud容器内部:${NC}"
        
        # 检查Nextcloud服务
        echo -n "Nextcloud内部服务: "
        if docker exec nextcloud-aio-nextcloud timeout 2 curl -s -f http://localhost:9000 >/dev/null 2>&1; then
            print_success "运行正常"
        else
            print_error "服务异常"
        fi
        
        # 检查Nextcloud文件结构
        docker exec nextcloud-aio-nextcloud sh -c '
            echo "检查Nextcloud安装..."
            if [ -f /var/www/html/config/config.php ]; then
                echo "Nextcloud已安装"
                echo "版本: $(grep "\version" /var/www/html/config/config.php 2>/dev/null | head -1 || echo "未知")"
            else
                echo "Nextcloud未安装或配置丢失"
            fi
        '
    fi
    
    # 7. 数据库检查
    print_header "7. 数据库状态检查"
    
    if docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-database"; then
        echo -n "数据库连接测试: "
        if docker exec nextcloud-aio-database pg_isready -U nextcloud >/dev/null 2>&1; then
            print_success "数据库运行正常"
        else
            print_error "数据库连接失败"
        fi
    fi
    
    # 8. 日志检查
    print_header "8. 日志和错误检查"
    
    echo -e "\n${BOLD}最近日志(最后20行):${NC}"
    docker compose logs --tail=20 2>/dev/null || docker logs $MASTER_CONTAINER --tail=20 2>/dev/null
    
    echo -e "\n${BOLD}错误日志扫描:${NC}"
    docker compose logs 2>/dev/null | grep -i "error\|fail\|critical\|exception" | tail -10 || true
    
    # 9. 配置检查
    print_header "9. 配置检查"
    
    if [ -f "$COMPOSE_FILE" ]; then
        print_success "找到docker-compose配置文件"
        echo -e "\n${BOLD}端口映射配置:${NC}"
        grep -E "ports:| - " "$COMPOSE_FILE" | head -10
    else
        print_warning "未找到docker-compose配置文件: $COMPOSE_FILE"
    fi
    
    # 10. 综合诊断和建议
    print_header "10. 诊断总结和建议"
    
    echo -e "\n${BOLD}发现的问题:${NC}"
    
    # 检查常见问题
    local issues=()
    
    # 检查端口88
    if ! ss -tlnp | grep -q ":88 "; then
        issues+=("主机端口88未监听")
    fi
    
    # 检查master容器
    if ! docker ps --format '{{.Names}}' | grep -q "^$MASTER_CONTAINER$"; then
        issues+=("Master容器未运行")
    fi
    
    # 检查容器健康状态
    for container in $(docker ps --format "{{.Names}}" | grep nextcloud-aio); do
        health=$(docker inspect $container --format='{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
        if [ "$health" = "unhealthy" ]; then
            issues+=("容器 $container 不健康")
        fi
    done
    
    if [ ${#issues[@]} -eq 0 ]; then
        print_success "未发现明显问题"
    else
        for issue in "${issues[@]}"; do
            print_error "$issue"
        done
    fi
    
    echo -e "\n${BOLD}建议的解决步骤:${NC}"
    
    if [ ${#issues[@]} -gt 0 ]; then
        echo "1. 检查容器日志: docker compose logs"
        echo "2. 重启服务: docker compose down && docker compose up -d"
        echo "3. 检查端口冲突: netstat -tlnp | grep ':88\|:81\|:86'"
        echo "4. 检查防火墙: sudo ufw status 或 firewall-cmd --list-all"
        echo "5. 查看初始化状态: docker exec $MASTER_CONTAINER tail -f /var/log/aio.log"
    else
        echo "所有检查通过，如果仍无法访问，请检查:"
        echo "1. 防火墙设置"
        echo "2. 域名解析设置"
        echo "3. 浏览器缓存"
        echo "4. SSL证书问题"
    fi
    
    # 11. 快速测试
    print_header "11. 快速验证测试"
    
    echo -e "\n执行快速测试..."
    
    # 创建测试文件并验证
    cat > /tmp/test_nc_aio.sh << 'EOF'
#!/bin/bash
echo "快速测试结果:"
echo "1. 检查主机端口..."
timeout 2 curl -s -o /dev/null -w "%{http_code}" http://localhost:88 && echo " 端口88 HTTP服务正常" || echo " 端口88不可达"
echo "2. 检查管理界面..."
timeout 2 curl -s -o /dev/null -w "%{http_code}" http://localhost:81 && echo " 管理界面正常" || echo " 管理界面不可达"
echo "3. 容器状态..."
docker ps --filter "name=nextcloud" --format "{{.Names}}: {{.Status}}" | while read line; do echo "  $line"; done
EOF
    
    chmod +x /tmp/test_nc_aio.sh
    /tmp/test_nc_aio.sh
    
    echo -e "\n${BOLD}${GREEN}============================================${NC}"
    echo -e "${BOLD}${GREEN}      诊断完成！查看日志: $LOG_FILE        ${NC}"
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo -e "完成时间: $(date)"
    
    # 提供日志文件位置
    print_info "完整日志已保存到: $LOG_FILE"
    print_info "使用以下命令查看: cat $LOG_FILE | less"
}

# 异常处理
trap 'echo -e "\n${RED}诊断被中断${NC}"; exit 1' INT TERM

# 执行主函数
main "$@"

./debug3.sh