#!/bin/bash

# ============================================
# Nextcloud AIO 超级详细体检脚本
# 版本: 3.0 - 极详细版
# 作者: AI助手
# 描述: 像医院体检一样，从内到外全面检查每个系统组件
# ============================================

set -e

# 配置
COMPOSE_FILE="/opt/nextcloud-aio/docker-compose.yml"
MASTER_CONTAINER="nextcloud-aio-mastercontainer"
LOG_FILE="/tmp/nc-aio-super-debug-$(date +%Y%m%d-%H%M%S).log"
TIMEOUT=10
DEBUG_LEVEL="full"  # full, medium, basic

# 颜色和格式
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    NC='\033[0m'
    BOLD='\033[1m'
    UNDERLINE='\033[4m'
    BG_RED='\033[41m'
    BG_GREEN='\033[42m'
    BG_YELLOW='\033[43m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; NC=''
    BOLD=''; UNDERLINE=''; BG_RED=''; BG_GREEN=''; BG_YELLOW=''
fi

# 进度指示器
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# 打印函数
print_section() {
    echo -e "\n${BG_BLUE}${BOLD}${WHITE}════════════════════════════════════════════════════════${NC}"
    echo -e "${BG_BLUE}${BOLD}${WHITE}   $1${NC}"
    echo -e "${BG_BLUE}${BOLD}${WHITE}════════════════════════════════════════════════════════${NC}\n"
}

print_subsection() {
    echo -e "\n${CYAN}${BOLD}▸ $1${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────${NC}"
}

print_item() {
    echo -e "  ${BLUE}•${NC} $1"
}

print_success() {
    echo -e "    ${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "    ${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "    ${RED}✗${NC} $1"
}

print_debug() {
    echo -e "    ${MAGENTA}⚡${NC} $1"
}

print_tip() {
    echo -e "    ${CYAN}💡${NC} $1"
}

# 记录详细输出
log_detail() {
    echo -e "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE.detail"
}

# ============================================
# 第1部分：系统级检查
# ============================================
system_checks() {
    print_section "第1部分：系统级全面检查"
    
    print_subsection "1.1 操作系统信息"
    print_item "内核版本和系统信息"
    echo "----------------------------------------"
    uname -a
    echo ""
    lsb_release -a 2>/dev/null || cat /etc/os-release
    echo ""
    print_item "系统负载和内存"
    echo "----------------------------------------"
    uptime
    free -h
    echo ""
    
    print_subsection "1.2 Docker环境检查"
    print_item "Docker版本信息"
    docker version 2>/dev/null || print_error "Docker未安装或无法访问"
    echo ""
    
    print_item "Docker Compose版本"
    docker compose version 2>/dev/null || docker-compose version 2>/dev/null || print_warning "Docker Compose未安装"
    echo ""
    
    print_item "Docker系统信息"
    docker info 2>/dev/null | grep -E "(Server Version|Containers|Running|Paused|Stopped|Images|Storage Driver|Logging Driver|Cgroup Driver|Docker Root Dir)"
    echo ""
    
    print_subsection "1.3 系统资源检查"
    print_item "磁盘空间和使用情况"
    df -h
    echo ""
    
    print_item "inode使用情况"
    df -i
    echo ""
    
    print_item "内存详细信息"
    cat /proc/meminfo | grep -E "(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree)"
    echo ""
    
    print_subsection "1.4 网络配置检查"
    print_item "主机网络接口"
    ip addr show | grep -E "(eth|ens|enp|wlan|wlp)" | grep inet
    echo ""
    
    print_item "主机路由表"
    ip route show | head -10
    echo ""
    
    print_item "DNS配置"
    cat /etc/resolv.conf
    echo ""
    
    print_item "防火墙状态"
    if command -v ufw >/dev/null; then
        sudo ufw status verbose
    elif command -v firewall-cmd >/dev/null; then
        sudo firewall-cmd --list-all
    elif command -v iptables >/dev/null; then
        sudo iptables -L -n | head -20
    else
        print_warning "未找到防火墙管理工具"
    fi
    echo ""
    
    print_item "SELinux状态"
    getenforce 2>/dev/null || print_warning "SELinux未安装"
    echo ""
}

# ============================================
# 第2部分：Docker容器级检查
# ============================================
docker_checks() {
    print_section "第2部分：Docker容器级详细检查"
    
    print_subsection "2.1 所有容器状态"
    print_item "完整容器列表"
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    
    print_item "仅运行中的容器"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}\t{{.Ports}}"
    echo ""
    
    print_subsection "2.2 Nextcloud AIO专属容器检查"
    print_item "按名称过滤的容器"
    docker ps -a --filter "name=nextcloud-aio" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}"
    echo ""
    
    # 检查每个关键容器
    declare -A essential_containers=(
        ["mastercontainer"]="核心管理容器"
        ["nextcloud"]="Nextcloud应用容器"
        ["database"]="PostgreSQL数据库"
        ["redis"]="Redis缓存"
        ["domaincheck"]="域名检查服务"
        ["clamav"]="病毒扫描"
        ["collabora"]="在线办公"
        ["onlyoffice"]="OnlyOffice"
        ["talk"]="Nextcloud Talk"
    )
    
    for container_suffix in "${!essential_containers[@]}"; do
        container_name="nextcloud-aio-$container_suffix"
        description="${essential_containers[$container_suffix]}"
        
        print_item "检查 $container_name ($description)"
        if docker ps --format '{{.Names}}' | grep -q "^$container_name$"; then
            print_success "正在运行"
            # 获取详细状态
            local status=$(docker inspect $container_name --format='{{.State.Status}}')
            local health=$(docker inspect $container_name --format='{{.State.Health.Status}}' 2>/dev/null || echo "N/A")
            local started=$(docker inspect $container_name --format='{{.State.StartedAt}}')
            local uptime=$(docker inspect $container_name --format='{{.State.StartedAt}}' | xargs -I {} date -d {} "+%Y-%m-%d %H:%M:%S")
            echo "      状态: $status | 健康: $health | 启动时间: $uptime"
        else
            if docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
                print_warning "已创建但未运行"
                local status=$(docker inspect $container_name --format='{{.State.Status}}')
                echo "      状态: $status"
            else
                print_error "不存在"
            fi
        fi
    done
    echo ""
    
    print_subsection "2.3 容器资源配置"
    print_item "容器资源限制"
    for container in $(docker ps --format '{{.Names}}' | grep nextcloud-aio); do
        echo "容器: $container"
        docker inspect $container --format='{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.CpuShares}}' | \
        awk '{printf "  内存: %.2f MB | CPU: %.2f核 | CPU权重: %d\n", $1/1024/1024, $2/1000000000, $3}'
    done
    echo ""
    
    print_subsection "2.4 容器网络配置"
    print_item "Docker网络列表"
    docker network ls
    echo ""
    
    print_item "AIO网络详情"
    docker network inspect nextcloud-aio_default 2>/dev/null || docker network inspect bridge 2>/dev/null
    echo ""
    
    print_item "容器IP地址分配"
    for container in $(docker ps --format '{{.Names}}' | grep nextcloud-aio); do
        echo "容器: $container"
        docker inspect $container --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
        echo ""
    done
}

# ============================================
# 第3部分：端口和网络连接检查
# ============================================
port_network_checks() {
    print_section "第3部分：端口和网络连接深度检查"
    
    print_subsection "3.1 主机端口监听状态"
    print_item "所有监听端口 (完整列表)"
    ss -tulnp 2>/dev/null | head -30
    echo ""
    
    # Nextcloud AIO相关端口
    declare -A aio_ports=(
        ["88"]="HTTP访问端口"
        ["81"]="管理界面端口"
        ["86"]="HTTPS访问端口"
        ["8443"]="备用HTTPS端口"
        ["443"]="标准HTTPS端口"
        ["80"]="标准HTTP端口"
        ["8080"]="内部管理端口"
        ["8000"]="内部Apache端口"
        ["9000"]="Nextcloud服务端口"
        ["11000"]="域名检查端口"
    )
    
    print_subsection "3.2 AIO关键端口检查"
    for port in "${!aio_ports[@]}"; do
        description="${aio_ports[$port]}"
        print_item "端口 $port ($description)"
        
        # 检查是否监听
        if ss -tlnp | grep -q ":$port "; then
            print_success "正在监听"
            # 显示监听进程
            ss -tlnp | grep ":$port " | while read line; do
                echo "      $line"
            done
        else
            print_warning "未监听"
        fi
        
        # 测试连接性
        echo -n "      连接测试: "
        if timeout 2 bash -c "echo > /dev/tcp/localhost/$port" 2>/dev/null; then
            print_success "本地可达"
        else
            print_warning "本地不可达"
        fi
        
        echo ""
    done
    
    print_subsection "3.3 容器端口映射验证"
    print_item "Master容器端口映射"
    docker port $MASTER_CONTAINER 2>/dev/null || print_error "无法获取端口映射"
    echo ""
    
    print_item "所有AIO容器端口映射"
    for container in $(docker ps --format '{{.Names}}' | grep nextcloud-aio); do
        echo "容器: $container"
        docker port $container 2>/dev/null || echo "  无端口映射"
        echo ""
    done
    
    print_subsection "3.4 容器间网络测试"
    print_item "容器间连通性矩阵测试"
    
    # 获取所有AIO容器IP
    declare -A container_ips
    for container in $(docker ps --format '{{.Names}}' | grep nextcloud-aio); do
        ip=$(docker inspect $container --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
        container_ips["$container"]=$ip
        echo "  $container -> $ip"
    done
    echo ""
    
    # 测试master容器到其他容器的连接
    if docker ps --format '{{.Names}}' | grep -q "^$MASTER_CONTAINER$"; then
        print_item "从Master容器测试连接性"
        for target_container in "${!container_ips[@]}"; do
            if [ "$target_container" != "$MASTER_CONTAINER" ]; then
                echo -n "  连接到 $target_container: "
                if docker exec $MASTER_CONTAINER ping -c 1 -W 1 $target_container >/dev/null 2>&1; then
                    print_success "Ping成功"
                else
                    # 尝试通过IP连接
                    target_ip="${container_ips[$target_container]}"
                    if docker exec $MASTER_CONTAINER ping -c 1 -W 1 $target_ip >/dev/null 2>&1; then
                        print_success "通过IP Ping成功"
                    else
                        print_warning "Ping失败"
                    fi
                fi
            fi
        done
        echo ""
    fi
    
    print_subsection "3.5 外部访问模拟测试"
    print_item "模拟外部用户访问"
    
    echo "测试HTTP访问 (端口88):"
    curl_output=$(timeout 5 curl -v http://localhost:88 2>&1 | head -20)
    if echo "$curl_output" | grep -q "HTTP"; then
        print_success "HTTP服务响应"
        echo "$curl_output"
    else
        print_error "HTTP服务无响应"
    fi
    echo ""
    
    echo "测试管理界面 (端口81):"
    curl_output=$(timeout 5 curl -v http://localhost:81 2>&1 | head -20)
    if echo "$curl_output" | grep -q "HTTP"; then
        print_success "管理界面响应"
        echo "$curl_output"
    else
        print_error "管理界面无响应"
    fi
    echo ""
    
    echo "测试HTTPS访问 (端口86):"
    curl_output=$(timeout 5 curl -k -v https://localhost:86 2>&1 | head -20)
    if echo "$curl_output" | grep -q "HTTP"; then
        print_success "HTTPS服务响应"
        echo "$curl_output"
    else
        print_error "HTTPS服务无响应"
    fi
    echo ""
}

# ============================================
# 第4部分：Master容器内部深度检查
# ============================================
master_container_checks() {
    print_section "第4部分：Master容器内部深度检查"
    
    if ! docker ps --format '{{.Names}}' | grep -q "^$MASTER_CONTAINER$"; then
        print_error "Master容器未运行，跳过内部检查"
        return 1
    fi
    
    print_subsection "4.1 容器内部系统状态"
    print_item "容器内部进程列表 (前20个)"
    docker exec $MASTER_CONTAINER ps aux 2>/dev/null | head -20
    echo ""
    
    print_item "容器内部资源使用"
    docker exec $MASTER_CONTAINER top -bn1 2>/dev/null || \
    docker exec $MASTER_CONTAINER cat /proc/loadavg 2>/dev/null || \
    echo "无法获取资源使用信息"
    echo ""
    
    print_item "容器内部磁盘空间"
    docker exec $MASTER_CONTAINER df -h 2>/dev/null || echo "无法获取磁盘信息"
    echo ""
    
    print_subsection "4.2 网络服务状态"
    print_item "容器内部端口监听 (详细)"
    docker exec $MASTER_CONTAINER netstat -tulnp 2>/dev/null || \
    docker exec $MASTER_CONTAINER ss -tulnp 2>/dev/null || \
    print_error "无法获取网络信息"
    echo ""
    
    print_item "关键服务端口检查"
    local internal_ports=("80" "443" "8000" "8080" "8081" "8443" "88" "81" "86")
    for port in "${internal_ports[@]}"; do
        echo -n "  端口 $port: "
        if docker exec $MASTER_CONTAINER timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            print_success "监听中"
            # 查看哪个进程在监听
            docker exec $MASTER_CONTAINER sh -c "lsof -i :$port 2>/dev/null || ss -tlnp | grep :$port 2>/dev/null || echo '    无法获取进程信息'" | head -2
        else
            print_warning "未监听"
        fi
    done
    echo ""
    
    print_subsection "4.3 Web服务器配置检查"
    print_item "Apache服务器状态"
    docker exec $MASTER_CONTAINER apachectl status 2>/dev/null || \
    docker exec $MASTER_CONTAINER service apache2 status 2>/dev/null || \
    print_warning "Apache状态检查失败"
    echo ""
    
    print_item "Apache配置文件位置"
    docker exec $MASTER_CONTAINER find /etc/apache2 /usr/local/apache2 -name "*.conf" 2>/dev/null | head -10
    echo ""
    
    print_item "Apache模块状态"
    docker exec $MASTER_CONTAINER apachectl -M 2>/dev/null || \
    docker exec $MASTER_CONTAINER httpd -M 2>/dev/null || \
    print_warning "无法获取Apache模块"
    echo ""
    
    print_item "关键Apache配置检查"
    docker exec $MASTER_CONTAINER grep -r "ProxyPass\|ProxyPreserveHost\|Listen 8000\|ServerName" /etc/apache2 /usr/local/apache2 2>/dev/null | head -15
    echo ""
    
    print_item "Caddy配置检查"
    if docker exec $MASTER_CONTAINER test -f /Caddyfile; then
        print_success "找到Caddyfile"
        docker exec $MASTER_CONTAINER head -50 /Caddyfile
    else
        print_warning "未找到Caddyfile"
        docker exec $MASTER_CONTAINER find / -name "Caddyfile" -type f 2>/dev/null | head -5
    fi
    echo ""
    
    print_subsection "4.4 服务连通性测试"
    print_item "内部服务端点测试"
    
    # 测试各个端点
    local endpoints=(
        "http://127.0.0.1:8000 - Apache直接访问"
        "http://127.0.0.1:8080 - 内部管理端口"
        "http://127.0.0.1:80 - HTTP默认端口"
        "http://127.0.0.1:443 - HTTPS默认端口"
    )
    
    for endpoint in "${endpoints[@]}"; do
        url=$(echo $endpoint | cut -d' ' -f1)
        desc=$(echo $endpoint | cut -d'-' -f2-)
        echo -n "  测试 $desc: "
        if docker exec $MASTER_CONTAINER timeout 3 curl -s -f $url >/dev/null 2>&1; then
            print_success "可达"
        else
            http_code=$(docker exec $MASTER_CONTAINER timeout 3 curl -s -o /dev/null -w "%{http_code}" $url 2>/dev/null || echo "000")
            print_warning "不可达 (HTTP代码: $http_code)"
        fi
    done
    echo ""
    
    print_item "到其他容器的服务测试"
    local services=(
        "nextcloud-aio-nextcloud:9000 - Nextcloud应用服务"
        "nextcloud-aio-domaincheck:11000 - 域名检查服务"
        "nextcloud-aio-database:5432 - PostgreSQL数据库"
        "nextcloud-aio-redis:6379 - Redis缓存"
    )
    
    for service in "${services[@]}"; do
        target=$(echo $service | cut -d' ' -f1)
        desc=$(echo $service | cut -d'-' -f2-)
        host=$(echo $target | cut -d':' -f1)
        port=$(echo $target | cut -d':' -f2)
        
        echo -n "  测试 $desc: "
        
        # 首先测试DNS解析
        if docker exec $MASTER_CONTAINER getent hosts $host >/dev/null 2>&1; then
            print_success "DNS解析正常"
            echo -n "      网络连接: "
            if docker exec $MASTER_CONTAINER timeout 2 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
                print_success "端口开放"
                # 测试HTTP服务（如果是HTTP）
                if [[ $port =~ ^(80|443|8000|8080|9000|11000)$ ]]; then
                    echo -n "      HTTP服务: "
                    if docker exec $MASTER_CONTAINER timeout 3 curl -s -f http://$target >/dev/null 2>&1; then
                        print_success "响应正常"
                    else
                        print_warning "无HTTP响应"
                    fi
                fi
            else
                print_error "端口关闭"
            fi
        else
            print_error "DNS解析失败"
        fi
    done
    echo ""
    
    print_subsection "4.5 配置文件和日志检查"
    print_item "AIO配置文件位置"
    docker exec $MASTER_CONTAINER find /mnt/docker-aio-config /var/www/docker-aio -type f -name "*.json" -o -name "*.php" -o -name "*.yml" -o -name "*.yaml" 2>/dev/null | head -15
    echo ""
    
    print_item "主配置文件内容"
    if docker exec $MASTER_CONTAINER test -f /mnt/docker-aio-config/configuration.json; then
        docker exec $MASTER_CONTAINER cat /mnt/docker-aio-config/configuration.json 2>/dev/null | head -30
    else
        print_warning "未找到主配置文件"
    fi
    echo ""
    
    print_item "环境变量检查"
    docker exec $MASTER_CONTAINER env | grep -E "(NEXTCLOUD|APACHE|CADDY|PORT|HOST|DOMAIN)" | head -20
    echo ""
    
    print_item "关键日志文件检查"
    local log_files=(
        "/var/log/apache2/error.log"
        "/var/log/apache2/access.log"
        "/var/log/caddy.log"
        "/var/log/aio.log"
        "/var/log/syslog"
        "/var/log/messages"
        "/tmp/nextcloud.log"
    )
    
    for log_file in "${log_files[@]}"; do
        if docker exec $MASTER_CONTAINER test -f "$log_file"; then
            echo "  日志文件: $log_file (最后5行)"
            docker exec $MASTER_CONTAINER tail -5 "$log_file" 2>/dev/null || echo "      无法读取"
        fi
    done
    echo ""
    
    print_subsection "4.6 进程和服务详情"
    print_item "Web服务器进程树"
    docker exec $MASTER_CONTAINER pstree -p 2>/dev/null | grep -E "(apache|httpd|caddy|nginx)" || \
    docker exec $MASTER_CONTAINER ps auxf 2>/dev/null | grep -E "(apache|httpd|caddy|nginx)" | head -10
    echo ""
    
    print_item "服务启动顺序检查"
    docker exec $MASTER_CONTAINER cat /etc/rc.local 2>/dev/null || \
    docker exec $MASTER_CONTAINER systemctl list-units --type=service 2>/dev/null | grep -E "(apache|caddy|nextcloud)" || \
    echo "无法获取服务启动信息"
    echo ""
}

# ============================================
# 第5部分：Nextcloud应用级检查
# ============================================
nextcloud_app_checks() {
    print_section "第5部分：Nextcloud应用级深度检查"
    
    if ! docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-nextcloud"; then
        print_error "Nextcloud应用容器未运行，跳过应用检查"
        return 1
    fi
    
    print_subsection "5.1 Nextcloud容器基础状态"
    print_item "容器内部进程"
    docker exec nextcloud-aio-nextcloud ps aux 2>/dev/null | head -15
    echo ""
    
    print_item "Nextcloud服务状态"
    docker exec nextcloud-aio-nextcloud supervisorctl status 2>/dev/null || \
    docker exec nextcloud-aio-nextcloud service --status-all 2>/dev/null || \
    print_warning "无法获取服务状态"
    echo ""
    
    print_subsection "5.2 Nextcloud安装状态"
    print_item "Nextcloud文件结构检查"
    docker exec nextcloud-aio-nextcloud ls -la /var/www/html/ 2>/dev/null
    echo ""
    
    print_item "配置文件检查"
    if docker exec nextcloud-aio-nextcloud test -f /var/www/html/config/config.php; then
        print_success "Nextcloud已安装"
        echo "  配置文件权限:"
        docker exec nextcloud-aio-nextcloud ls -la /var/www/html/config/config.php 2>/dev/null
        
        echo "  配置文件摘要:"
        docker exec nextcloud-aio-nextcloud cat /var/www/html/config/config.php 2>/dev/null | \
        grep -E "(version|installed|datadirectory|dbhost|dbname|dbtableprefix|trusted_domains)" | head -10
    else
        print_error "Nextcloud未安装或配置文件丢失"
    fi
    echo ""
    
    print_item "版本信息"
    if docker exec nextcloud-aio-nextcloud test -f /var/www/html/version.php; then
        docker exec nextcloud-aio-nextcloud grep -E "(OC_Version|OC_VersionString)" /var/www/html/version.php 2>/dev/null || \
        echo "无法获取版本信息"
    fi
    echo ""
    
    print_subsection "5.3 Nextcloud服务测试"
    print_item "内部服务端口测试"
    echo -n "  Nextcloud内部服务(9000端口): "
    if docker exec nextcloud-aio-nextcloud timeout 3 curl -s -f http://localhost:9000 >/dev/null 2>&1; then
        print_success "运行正常"
        # 获取状态码
        status_code=$(docker exec nextcloud-aio-nextcloud timeout 3 curl -s -o /dev/null -w "%{http_code}" http://localhost:9000 2>/dev/null || echo "000")
        echo "      HTTP状态码: $status_code"
    else
        print_error "服务异常"
    fi
    echo ""
    
    print_item "从Master容器访问测试"
    echo -n "  从Master容器访问Nextcloud: "
    if docker exec $MASTER_CONTAINER timeout 3 curl -s -f http://nextcloud-aio-nextcloud:9000 >/dev/null 2>&1; then
        print_success "连接成功"
        # 测试实际响应
        response=$(docker exec $MASTER_CONTAINER timeout 3 curl -s http://nextcloud-aio-nextcloud:9000 | head -c 100)
        echo "      响应预览: $response"
    else
        print_error "连接失败"
    fi
    echo ""
    
    print_subsection "5.4 PHP和扩展检查"
    print_item "PHP版本和配置"
    docker exec nextcloud-aio-nextcloud php -v 2>/dev/null || print_warning "PHP不可用"
    echo ""
    
    print_item "PHP模块检查"
    docker exec nextcloud-aio-nextcloud php -m 2>/dev/null | grep -E "(opcache|apcu|redis|memcached|gd|imagick|exif)" | head -10
    echo ""
    
    print_item "PHP内存限制"
    docker exec nextcloud-aio-nextcloud php -i 2>/dev/null | grep -i "memory_limit" | head -2
    echo ""
    
    print_subsection "5.5 数据目录检查"
    print_item "数据目录状态"
    if docker exec nextcloud-aio-nextcloud test -d /var/www/html/data; then
        echo "  数据目录内容:"
        docker exec nextcloud-aio-nextcloud ls -la /var/www/html/data/ 2>/dev/null | head -5
        echo "  数据目录大小:"
        docker exec nextcloud-aio-nextcloud du -sh /var/www/html/data/ 2>/dev/null
    else
        print_warning "数据目录不存在"
    fi
    echo ""
}

# ============================================
# 第6部分：数据库和服务依赖检查
# ============================================
database_dependency_checks() {
    print_section "第6部分：数据库和服务依赖检查"
    
    print_subsection "6.1 PostgreSQL数据库检查"
    if docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-database"; then
        print_item "数据库容器状态"
        echo -n "  数据库连接测试: "
        if docker exec nextcloud-aio-database pg_isready -U nextcloud >/dev/null 2>&1; then
            print_success "数据库运行正常"
            
            echo "  数据库信息:"
            docker exec nextcloud-aio-database psql -U nextcloud -d nextcloud -c "
                SELECT version();
                SELECT current_database();
                SELECT usename FROM pg_user WHERE usename = 'nextcloud';
            " 2>/dev/null || print_warning "无法查询数据库信息"
            
            echo "  数据库大小和表统计:"
            docker exec nextcloud-aio-database psql -U nextcloud -d nextcloud -c "
                SELECT pg_database_size('nextcloud') as db_size_bytes;
                SELECT count(*) as table_count FROM information_schema.tables WHERE table_schema = 'public';
            " 2>/dev/null | head -10
        else
            print_error "数据库连接失败"
        fi
    else
        print_error "数据库容器未运行"
    fi
    echo ""
    
    print_subsection "6.2 Redis缓存检查"
    if docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-redis"; then
        print_item "Redis容器状态"
        echo -n "  Redis连接测试: "
        if docker exec nextcloud-aio-redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
            print_success "Redis运行正常"
            
            echo "  Redis信息:"
            docker exec nextcloud-aio-redis redis-cli info memory 2>/dev/null | head -5
            docker exec nextcloud-aio-redis redis-cli info stats 2>/dev/null | grep -E "(connected_clients|used_memory_human)"
        else
            print_error "Redis连接失败"
        fi
    else
        print_warning "Redis容器未运行"
    fi
    echo ""
    
    print_subsection "6.3 其他辅助服务"
    print_item "域名检查服务"
    if docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-domaincheck"; then
        echo -n "  域名检查服务测试: "
        if docker exec $MASTER_CONTAINER timeout 3 curl -s -f http://nextcloud-aio-domaincheck:11000 >/dev/null 2>&1; then
            print_success "服务正常"
        else
            print_warning "服务异常"
        fi
    fi
    echo ""
    
    print_item "ClamAV病毒扫描"
    if docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-clamav"; then
        echo -n "  ClamAV服务状态: "
        if docker exec nextcloud-aio-clamav pgrep clamd >/dev/null 2>&1; then
            print_success "运行中"
        else
            print_warning "未运行"
        fi
    fi
    echo ""
    
    print_item "Collabora/OnlyOffice"
    if docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-collabora"; then
        echo "  Collabora运行中"
    elif docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-onlyoffice"; then
        echo "  OnlyOffice运行中"
    else
        echo "  未运行在线办公服务"
    fi
    echo ""
}

# ============================================
# 第7部分：日志和错误分析
# ============================================
log_analysis() {
    print_section "第7部分：日志和错误深度分析"
    
    print_subsection "7.1 实时日志监控"
    print_item "最后50行组合日志"
    docker compose logs --tail=50 2>/dev/null || \
    (for container in $(docker ps --format '{{.Names}}' | grep nextcloud-aio); do
        echo "=== $container 日志 ==="
        docker logs $container --tail=10 2>/dev/null
    done)
    echo ""
    
    print_subsection "7.2 错误日志扫描"
    print_item "错误关键词扫描 (所有容器)"
    
    declare -A error_patterns=(
        ["ERROR"]="一般错误"
        ["FATAL"]="致命错误"
        ["CRITICAL"]="严重错误"
        ["failed"]="失败操作"
        ["exception"]="异常"
        ["timeout"]="超时"
        ["refused"]="拒绝连接"
        ["permission denied"]="权限拒绝"
        ["no such file"]="文件不存在"
        ["address already in use"]="地址已占用"
    )
    
    for pattern in "${!error_patterns[@]}"; do
        description="${error_patterns[$pattern]}"
        echo "  搜索: $description ($pattern)"
        
        # 在所有容器中搜索
        for container in $(docker ps --format '{{.Names}}' | grep nextcloud-aio); do
            count=$(docker logs $container 2>/dev/null | grep -i "$pattern" | wc -l)
            if [ $count -gt 0 ]; then
                print_warning "  $container 发现 $count 处"
                docker logs $container 2>/dev/null | grep -i "$pattern" | tail -3 | while read line; do
                    echo "    > $line"
                done
            fi
        done
    done
    echo ""
    
    print_subsection "7.3 启动和初始化日志"
    print_item "最近启动记录"
    for container in $(docker ps --format '{{.Names}}' | grep nextcloud-aio); do
        echo "  $container 启动日志:"
        docker logs $container 2>/dev/null | grep -i "start\|initial\|setup\|ready\|complete" | tail -5
    done
    echo ""
    
    print_subsection "7.4 性能相关日志"
    print_item "慢查询和超时"
    for container in $(docker ps --format '{{.Names}}' | grep -E "(nextcloud|database)"); do
        echo "  $container 性能日志:"
        docker logs $container 2>/dev/null | grep -i "slow\|timeout\|long\|duration" | tail -3
    done
    echo ""
}

# ============================================
# 第8部分：配置和文件系统检查
# ============================================
config_filesystem_checks() {
    print_section "第8部分：配置和文件系统检查"
    
    print_subsection "8.1 Docker Compose配置"
    print_item "主配置文件检查"
    if [ -f "$COMPOSE_FILE" ]; then
        print_success "找到配置文件: $COMPOSE_FILE"
        
        echo "  文件权限:"
        ls -la "$COMPOSE_FILE"
        
        echo "  关键配置节选:"
        grep -E "(ports:|volumes:|image:|environment:|depends_on:)" "$COMPOSE_FILE" | head -20
    else
        print_error "配置文件不存在: $COMPOSE_FILE"
        # 尝试查找其他位置
        find /opt /etc /home -name "*docker-compose*" -type f 2>/dev/null | grep -i nextcloud | head -5
    fi
    echo ""
    
    print_subsection "8.2 卷和绑定挂载检查"
    print_item "容器卷挂载情况"
    for container in $(docker ps --format '{{.Names}}' | grep nextcloud-aio); do
        echo "  容器: $container"
        docker inspect $container --format='{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}})
{{end}}' 2>/dev/null
    done
    echo ""
    
    print_item "主机卷目录检查"
    local volume_dirs=(
        "/mnt/docker-aio-config"
        "/opt/nextcloud-aio"
        "/var/lib/docker/volumes"
    )
    
    for dir in "${volume_dirs[@]}"; do
        if [ -d "$dir" ]; then
            echo "  目录: $dir"
            ls -la "$dir/" 2>/dev/null | head -5
            echo "  大小: $(du -sh "$dir" 2>/dev/null || echo "未知")"
        fi
    done
    echo ""
    
    print_subsection "8.3 环境变量检查"
    print_item "容器环境变量"
    for container in $(docker ps --format '{{.Names}}' | grep -E "(mastercontainer|nextcloud)"); do
        echo "  $container 关键环境变量:"
        docker inspect $container --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
        grep -E "(NEXTCLOUD|APACHE|CADDY|DOMAIN|PORT|HOST|DATABASE|REDIS)" | head -10
    done
    echo ""
    
    print_subsection "8.4 网络配置检查"
    print_item "主机网络配置"
    echo "  /etc/hosts 相关条目:"
    grep -i nextcloud /etc/hosts 2>/dev/null || echo "    无相关条目"
    echo ""
    
    echo "  防火墙规则 (Nextcloud相关):"
    if command -v ufw >/dev/null; then
        sudo ufw status numbered 2>/dev/null | grep -E "(88|81|86|443)"
    elif command -v iptables >/dev/null; then
        sudo iptables -L -n 2>/dev/null | grep -E "(88|81|86|443)"
    fi
    echo ""
}

# ============================================
# 第9部分：性能和安全检查
# ============================================
performance_security_checks() {
    print_section "第9部分：性能和安全检查"
    
    print_subsection "9.1 性能指标"
    print_item "容器资源使用统计"
    echo "  CPU和内存使用:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" | grep nextcloud
    echo ""
    
    print_item "响应时间测试"
    echo -n "  HTTP响应时间: "
    time_output=$(timeout 5 curl -o /dev/null -s -w "%{time_total}s\n" http://localhost:88 2>/dev/null || echo "超时")
    echo "    $time_output"
    
    echo -n "  管理界面响应时间: "
    time_output=$(timeout 5 curl -o /dev/null -s -w "%{time_total}s\n" http://localhost:81 2>/dev/null || echo "超时")
    echo "    $time_output"
    echo ""
    
    print_subsection "9.2 安全检查"
    print_item "SSL/TLS证书检查"
    echo -n "  HTTPS证书验证: "
    if timeout 5 openssl s_client -connect localhost:86 -servername localhost 2>/dev/null | grep -q "Verify return code"; then
        timeout 5 openssl s_client -connect localhost:86 -servername localhost 2>/dev/null | grep "Verify return code"
    else
        print_warning "无法验证证书"
    fi
    echo ""
    
    print_item "服务暴露检查"
    echo "  外部可访问性测试:"
    echo -n "    从外部访问端口88: "
    if timeout 2 curl -s http://$(hostname -I | awk '{print $1}'):88 >/dev/null 2>&1; then
        print_success "可访问"
    else
        print_warning "不可访问"
    fi
    echo ""
    
    print_item "容器权限检查"
    for container in $(docker ps --format '{{.Names}}' | grep nextcloud-aio); do
        echo "  $container 权限:"
        docker inspect $container --format='{{.HostConfig.Privileged}} {{.HostConfig.ReadonlyRootfs}}' | \
        awk '{printf "    特权模式: %s | 只读根文件系统: %s\n", $1, $2}'
    done
    echo ""
}

# ============================================
# 第10部分：综合诊断和建议
# ============================================
comprehensive_diagnosis() {
    print_section "第10部分：综合诊断和建议"
    
    # 收集问题
    declare -a problems
    declare -a warnings
    declare -a successes
    
    print_subsection "10.1 问题汇总"
    
    # 检查点1: 容器状态
    print_item "容器状态检查"
    if ! docker ps --format '{{.Names}}' | grep -q "^$MASTER_CONTAINER$"; then
        problems+=("Master容器未运行")
    else
        successes+=("Master容器运行正常")
    fi
    
    if ! docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-nextcloud"; then
        problems+=("Nextcloud应用容器未运行")
    else
        successes+=("Nextcloud容器运行正常")
    fi
    
    # 检查点2: 端口监听
    print_item "端口监听检查"
    if ! ss -tlnp | grep -q ":88 "; then
        problems+=("端口88未监听")
    else
        successes+=("端口88监听正常")
    fi
    
    if ! ss -tlnp | grep -q ":81 "; then
        warnings+=("端口81未监听（可能未启用管理界面）")
    else
        successes+=("管理界面端口81监听正常")
    fi
    
    # 检查点3: 服务连通性
    print_item "服务连通性检查"
    if ! timeout 3 curl -s http://localhost:88 >/dev/null 2>&1; then
        problems+=("HTTP服务无法访问")
    else
        successes+=("HTTP服务访问正常")
    fi
    
    # 检查点4: 数据库连接
    print_item "数据库连接检查"
    if docker ps --format '{{.Names}}' | grep -q "nextcloud-aio-database"; then
        if docker exec nextcloud-aio-database pg_isready -U nextcloud >/dev/null 2>&1; then
            successes+=("数据库连接正常")
        else
            problems+=("数据库连接失败")
        fi
    fi
    
    # 显示结果
    echo ""
    print_subsection "10.2 诊断结果"
    
    if [ ${#problems[@]} -eq 0 ]; then
        print_success "未发现严重问题"
    else
        print_error "发现 ${#problems[@]} 个严重问题:"
        for problem in "${problems[@]}"; do
            echo "  ✗ $problem"
        done
    fi
    
    if [ ${#warnings[@]} -gt 0 ]; then
        print_warning "发现 ${#warnings[@]} 个警告:"
        for warning in "${warnings[@]}"; do
            echo "  ⚠ $warning"
        done
    fi
    
    if [ ${#successes[@]} -gt 0 ]; then
        print_success "${#successes[@]} 个检查项正常:"
        for success in "${successes[@]}"; do
            echo "  ✓ $success"
        done
    fi
    
    echo ""
    print_subsection "10.3 修复建议"
    
    if [ ${#problems[@]} -gt 0 ]; then
        echo "  建议按以下顺序解决问题:"
        echo ""
        echo "  1. 启动停止的容器:"
        echo "     docker compose up -d"
        echo ""
        echo "  2. 检查端口冲突:"
        echo "     sudo netstat -tlnp | grep :88"
        echo "     如有冲突，修改 docker-compose.yml 中的端口映射"
        echo ""
        echo "  3. 查看详细错误日志:"
        echo "     docker compose logs --tail=100"
        echo ""
        echo "  4. 重启整个服务栈:"
        echo "     docker compose down && docker compose up -d"
        echo ""
        echo "  5. 检查文件权限:"
        echo "     sudo chown -R 33:33 /mnt/docker-aio-config/"
        echo ""
        echo "  6. 检查防火墙设置:"
        echo "     sudo ufw allow 88/tcp"
        echo "     sudo ufw allow 81/tcp"
        echo "     sudo ufw allow 86/tcp"
        echo ""
    else
        echo "  系统运行基本正常，如需进一步优化:"
        echo ""
        echo "  1. 性能优化建议:"
        echo "     - 调整PHP内存限制"
        echo "     - 启用Redis缓存"
        echo "     - 配置OPcache"
        echo ""
        echo "  2. 安全优化建议:"
        echo "     - 启用HTTPS"
        echo "     - 设置防火墙规则"
        echo "     - 定期备份"
        echo ""
        echo "  3. 监控建议:"
        echo "     - 设置日志轮转"
        echo "     - 监控磁盘空间"
        echo "     - 设置健康检查"
    fi
    
    echo ""
    print_subsection "10.4 快速修复命令"
    
    cat << 'EOF'
    # 重启整个AIO服务
    docker compose down
    docker compose up -d
    
    # 仅重启Master容器
    docker compose restart mastercontainer
    
    # 重置所有配置（危险！）
    docker compose down -v
    docker compose up -d
    
    # 查看实时日志
    docker compose logs -f
    
    # 进入Master容器调试
    docker exec -it nextcloud-aio-mastercontainer bash
    
    # 检查初始化状态
    docker exec nextcloud-aio-mastercontainer tail -f /var/log/aio.log
    
    # 备份配置
    cp -r /mnt/docker-aio-config /backup/
EOF
    
    echo ""
    print_subsection "10.5 后续步骤"
    
    echo "  如果问题仍未解决:"
    echo "  1. 收集完整日志: docker compose logs > aio_logs.txt"
    echo "  2. 保存配置: cp /opt/nextcloud-aio/docker-compose.yml ./"
    echo "  3. 记录网络配置: ip addr show > network_config.txt"
    echo "  4. 在Nextcloud社区或GitHub提交问题，附上以上文件"
}

# ============================================
# 主函数
# ============================================
main() {
    # 创建日志文件
    echo "Nextcloud AIO 超级详细诊断开始: $(date)" > "$LOG_FILE"
    echo "完整日志: $LOG_FILE" > "$LOG_FILE.detail"
    
    # 显示横幅
    clear
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}   Nextcloud AIO 超级详细诊断工具                     ${NC}"
    echo -e "${BOLD}${BLUE}   版本 3.0 - 体检级详细检查                          ${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════${NC}"
    echo -e "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "日志文件: $LOG_FILE"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════${NC}\n"
    
    # 询问是否继续
    read -p "按 Enter 开始全面诊断 (可能需要5-10分钟)..." 
    
    # 执行所有检查（输出同时到屏幕和日志）
    exec > >(tee -a "$LOG_FILE") 2>&1
    
    # 执行各个检查模块
    system_checks
    docker_checks
    port_network_checks
    master_container_checks
    nextcloud_app_checks
    database_dependency_checks
    log_analysis
    config_filesystem_checks
    performance_security_checks
    comprehensive_diagnosis
    
    # 完成信息
    echo -e "\n${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}   诊断完成！                                         ${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "诊断日志: $LOG_FILE"
    echo -e "详细日志: $LOG_FILE.detail"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    
    # 提供快速查看命令
    echo -e "\n${BOLD}快速查看命令:${NC}"
    echo "  查看摘要: grep -E '(第|✓|✗|⚠|建议)' $LOG_FILE"
    echo "  仅看错误: grep -E '(✗|ERROR|failed)' $LOG_FILE"
    echo "  查看端口: grep -E '(端口|监听)' $LOG_FILE"
    echo "  查看容器状态: grep -E '(容器|运行)' $LOG_FILE"
    
    # 文件大小
    echo -e "\n${BOLD}生成的文件:${NC}"
    ls -lh $LOG_FILE*
}

# 错误处理
trap 'echo -e "\n${RED}诊断被用户中断${NC}"; exit 1' INT
trap 'echo -e "\n${RED}发生错误，退出诊断${NC}"; exit 1' ERR

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}警告: 非root用户运行，某些检查可能需要sudo权限${NC}"
    echo -e "建议使用: sudo $0\n"
    read -p "是否继续? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# 运行主函数
main "$@"