#!/bin/bash

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 当前目录
cur_dir=$(pwd)

# 检查root权限
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# 检查参数
if [ $# -lt 4 ]; then
    echo -e "${yellow}用法:${plain} $0 <域名> <用户名> <密码> <x-ui端口>"
    echo -e "${yellow}示例:${plain} $0 example.com myadmin P@ssw0rd123 54321"
    exit 1
fi

DOMAIN=$1
XUI_USER=$2
XUI_PASSWORD=$3
XUI_PORT=$4

# 检查系统
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

# 检查架构
arch=$(arch)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="amd64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="amd64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo -e "系统架构: ${arch}"

# 检查是否64位系统
if [ $(getconf WORD_BIT) != '32' ] && [ $(getconf LONG_BIT) != '64' ]; then
    echo -e "${red}本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)${plain}"
    exit 1
fi

# 检查系统版本
os_version=""
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

# 安装基础工具
install_base() {
    echo -e "${green}正在安装必要工具...${plain}"
    if [[ x"${release}" == x"centos" ]]; then
        yum install -y wget curl tar lrzsz nginx
    else
        apt update -y
        apt install -y wget curl tar lrzsz nginx
    fi
}

# 安装x-ui
install_xui() {
    echo -e "${green}正在安装x-ui...${plain}"
    systemctl stop x-ui 2>/dev/null
    cd /usr/local/

    # 尝试从GitHub获取最新版
    last_version=$(curl -Ls "https://api.github.com/repos/vaxilu/x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -n "$last_version" ]]; then
        echo -e "检测到x-ui最新版本：${last_version}"
        wget -N --no-check-certificate -O /usr/local/x-ui-linux-${arch}.tar.gz https://github.com/vaxilu/x-ui/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz
        if [[ $? -eq 0 ]]; then
            rm -rf /usr/local/x-ui/
            tar zxvf x-ui-linux-${arch}.tar.gz -C /usr/local/
            rm -f x-ui-linux-${arch}.tar.gz
            cd /usr/local/x-ui
            chmod +x x-ui bin/xray-linux-${arch}
            cp -f x-ui.service /etc/systemd/system/
        fi
    fi

    # 如果从GitHub安装失败，使用备用方法
    if [[ ! -f /usr/local/x-ui/x-ui ]]; then
        echo -e "${yellow}从GitHub安装失败，尝试备用安装方法...${plain}"
        bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)
    fi

    # 设置账号密码和端口
    echo -e "${green}正在配置x-ui...${plain}"
    /usr/local/x-ui/x-ui setting -username ${XUI_USER} -password ${XUI_PASSWORD}
    /usr/local/x-ui/x-ui setting -port ${XUI_PORT}

    # 设置服务
    wget --no-check-certificate -O /usr/bin/x-ui https://raw.githubusercontent.com/vaxilu/x-ui/main/x-ui.sh
    chmod +x /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl start x-ui
}

# 启用BBR
enable_bbr() {
    echo -e "${green}正在启用BBR...${plain}"
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
}

# 安装SSL证书
install_ssl() {
    echo -e "${green}正在安装acme.sh...${plain}"
    curl https://get.acme.sh | sh
    ln -s /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
    acme.sh --set-default-ca --server letsencrypt

    echo -e "${green}正在申请SSL证书...${plain}"
    mkdir -p /var/www/html
    acme.sh --issue -d ${DOMAIN} -k ec-256 --webroot /var/www/html

    echo -e "${green}正在安装SSL证书...${plain}"
    mkdir -p /etc/x-ui
    acme.sh --install-cert -d ${DOMAIN} --ecc \
        --key-file /etc/x-ui/server.key \
        --fullchain-file /etc/x-ui/server.crt \
        --reloadcmd "systemctl force-reload nginx"
}

# 配置nginx
configure_nginx() {
    echo -e "${green}正在配置nginx...${plain}"
    # 备份原始配置
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    
    # 生成新配置
    cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;

    server {
        listen 443 ssl;
        server_name ${DOMAIN};
        ssl_certificate       /etc/x-ui/server.crt;
        ssl_certificate_key   /etc/x-ui/server.key;

        ssl_session_timeout 1d;
        ssl_session_cache shared:MozSSL:10m;
        ssl_session_tickets off;
        ssl_protocols    TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;

        location / {
            proxy_pass https://bing.com;
            proxy_redirect off;
            proxy_ssl_server_name on;
            sub_filter_once off;
            sub_filter "bing.com" \$server_name;
            proxy_set_header Host "bing.com";
            proxy_set_header Referer \$http_referer;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header User-Agent \$http_user_agent;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Accept-Language "zh-CN";
        }

        location /ray {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:10000;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        location /xui {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:${XUI_PORT};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
        }
    }

    server {
        listen 80;
        location /.well-known/ {
            root /var/www/html;
        }
        location / {
            rewrite ^(.*)$ https://\$host\$1 permanent;
        }
    }
}
EOF

    systemctl restart nginx
}

# 主函数
main() {
    echo -e "${green}=== 开始安装配置 ===${plain}"
    echo -e "域名: ${yellow}${DOMAIN}${plain}"
    echo -e "用户名: ${yellow}${XUI_USER}${plain}"
    echo -e "密码: ${yellow}${XUI_PASSWORD}${plain}"
    echo -e "x-ui端口: ${yellow}${XUI_PORT}${plain}"
    
    install_base
    enable_bbr
    install_xui
    install_ssl
    configure_nginx
    
    echo -e "${green}=== 安装完成 ===${plain}"
    echo -e "x-ui管理面板: ${yellow}https://${DOMAIN}/xui${plain}"
    echo -e "用户名: ${yellow}${XUI_USER}${plain}"
    echo -e "密码: ${yellow}${XUI_PASSWORD}${plain}"
    echo -e ""
    echo -e "${yellow}重要提示:${plain}"
    echo -e "1. 请确保域名 ${DOMAIN} 已解析到本服务器"
    echo -e "2. 防火墙请放行端口: 80, 443, ${XUI_PORT}"
    echo -e "3. 使用命令 'x-ui' 可以管理面板"
    echo -e "4. 当前x-ui监听端口: ${XUI_PORT} (通过参数传递)"
}

# 执行
main
