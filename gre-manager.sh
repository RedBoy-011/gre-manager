#!/bin/bash

# ==============================================================================
# GRE Tunnel Manager v2.1 - Token Based, Auto-Ping & Logging
# فزار فناور | فناوران زیرساخت داده راهورد
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# پیدا کردن اولین کارت شبکه GRE آزاد با خواندن مستقیم از کرنل
find_free_interface() {
    for i in {1..100}; do
        if [ ! -d "/sys/class/net/gre$i" ]; then
            echo "gre$i"
            return
        fi
    done
}

# نصب هوشمند پیش‌نیازها (اسکیپ در صورت نصب بودن)
install_deps() {
    if command -v iptables >/dev/null 2>&1 && command -v ip >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
        echo -e "${GREEN}پیش‌نیازها از قبل نصب هستند (پرش از این مرحله).${NC}"
    else
        echo -e "${YELLOW}در حال بررسی و نصب پیش‌نیازها...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q -y >/dev/null 2>&1
        apt-get install -q -y iptables iproute2 base64 iptables-persistent >/dev/null 2>&1
    fi
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-custom-gre.conf
    sysctl -p /etc/sysctl.d/99-custom-gre.conf >/dev/null 2>&1
}

# 1. ساخت سرور مبدأ و تولید توکن
generate_node_a() {
    install_deps
    echo -e "${CYAN}--- راه‌اندازی سرور مبدأ (ایجاد توکن) ---${NC}"
    read -p "آی‌پی عمومی همین سرور را وارد کنید: " MY_IP
    read -p "آی‌پی عمومی سرور مقابل را وارد کنید: " REMOTE_IP
    
    SUBNET_3RD=$((RANDOM % 200 + 10))
    SUBNET="10.200.${SUBNET_3RD}"
    GRE_IF=$(find_free_interface)
    
    cat <<EOF > /etc/systemd/system/gre-tun-${GRE_IF}.service
[Unit]
Description=GRE Tunnel ${GRE_IF}
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add ${GRE_IF} mode gre remote ${REMOTE_IP} local ${MY_IP}
ExecStart=/sbin/ip link set ${GRE_IF} up
ExecStart=/sbin/ip addr add ${SUBNET}.1/30 dev ${GRE_IF}
ExecStop=/sbin/ip link del ${GRE_IF}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gre-tun-${GRE_IF}.service >/dev/null 2>&1
    systemctl start gre-tun-${GRE_IF}.service
    
    TOKEN_RAW="${MY_IP}|${REMOTE_IP}|${SUBNET}"
    TOKEN=$(echo -n "$TOKEN_RAW" | base64 -w 0)
    
    echo -e "\n${GREEN}تانل (${GRE_IF}) با موفقیت ایجاد شد!${NC}"
    echo -e "${YELLOW}توکن زیر را کپی کرده و در سرور مقابل وارد کنید:${NC}"
    echo -e "=========================================================="
    echo -e "${CYAN}${TOKEN}${NC}"
    echo -e "==========================================================\n"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# 2. اتصال به تانل با توکن + تست پینگ اتوماتیک
consume_node_b() {
    install_deps
    echo -e "${CYAN}--- اتصال به تانل (مصرف توکن) ---${NC}"
    read -p "توکن را اینجا پیست کنید: " TOKEN
    
    DECODED=$(echo -n "$TOKEN" | base64 --decode 2>/dev/null)
    if [[ "$DECODED" != *"|"* ]]; then
        echo -e "${RED}توکن نامعتبر است!${NC}"; sleep 2; return
    fi
    
    REMOTE_IP=$(echo "$DECODED" | cut -d'|' -f1)
    MY_IP=$(echo "$DECODED" | cut -d'|' -f2)
    SUBNET=$(echo "$DECODED" | cut -d'|' -f3)
    GRE_IF=$(find_free_interface)
    
    cat <<EOF > /etc/systemd/system/gre-tun-${GRE_IF}.service
[Unit]
Description=GRE Tunnel ${GRE_IF}
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add ${GRE_IF} mode gre remote ${REMOTE_IP} local ${MY_IP}
ExecStart=/sbin/ip link set ${GRE_IF} up
ExecStart=/sbin/ip addr add ${SUBNET}.2/30 dev ${GRE_IF}
ExecStop=/sbin/ip link del ${GRE_IF}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gre-tun-${GRE_IF}.service >/dev/null 2>&1
    systemctl start gre-tun-${GRE_IF}.service
    
    echo -e "\n${GREEN}اتصال موفق! تانل (${GRE_IF}) تنظیم شد.${NC}"
    echo -e "${YELLOW}در حال بررسی واقعی ارتباط شبکه (Ping Test)...${NC}"
    sleep 2
    
    if ping -c 3 -W 2 ${SUBNET}.1 >/dev/null 2>&1; then
        echo -e "${GREEN}✅ ارتباط پینگ موفقیت‌آمیز بود! تانل کاملاً برقرار است.${NC}\n"
    else
        echo -e "${RED}⚠️ هشدار: تانل ساخته شد اما پینگ ناموفق بود. ممکن است آی‌پی‌ها فیلتر باشند یا فایروال بسته باشد.${NC}\n"
    fi
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# 3. مدیریت پورت‌ها با سیستم تشخیص دقیق تانل
manage_ports() {
    echo -e "${CYAN}--- مدیریت انتقال پورت‌های خاص ---${NC}"
    ACTIVE_IFS=$(ls /sys/class/net/ 2>/dev/null | grep -E '^gre[1-9]')
    
    if [ -z "$ACTIVE_IFS" ]; then
        echo -e "${RED}هیچ تانل GRE فعالی یافت نشد! ابتدا تانل بسازید.${NC}"; sleep 2; return
    fi
    
    echo -e "${YELLOW}تانل‌های فعال شما:${NC}"
    for iface in $ACTIVE_IFS; do
        TUN_IP=$(ip -4 addr show $iface 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        echo " - $iface (IP: $TUN_IP)"
    done
    echo ""
    read -p "نام تانل مورد نظر را تایپ کنید (مثلاً gre1): " TARGET_GRE
    
    MY_TUN_IP=$(ip -4 addr show $TARGET_GRE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [ -z "$MY_TUN_IP" ]; then
        echo -e "${RED}تانل وارد شده نامعتبر است!${NC}"; sleep 2; return
    fi
    
    REMOTE_TUN_IP="${MY_TUN_IP%.*}.1"
    if [ "$MY_TUN_IP" == "$REMOTE_TUN_IP" ]; then REMOTE_TUN_IP="${MY_TUN_IP%.*}.2"; fi

    echo -e "انتقال ترافیک از این سرور به آی‌پی: ${CYAN}$REMOTE_TUN_IP${NC}"
    read -p "چه پورتی را می‌خواهید عبور دهید؟ (مثلاً 51820): " PORT
    
    iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $REMOTE_TUN_IP:$PORT
    iptables -t nat -A PREROUTING -p udp --dport $PORT -j DNAT --to-destination $REMOTE_TUN_IP:$PORT
    iptables -t nat -A POSTROUTING -d $REMOTE_TUN_IP -p tcp --dport $PORT -j SNAT --to-source $MY_TUN_IP
    iptables -t nat -A POSTROUTING -d $REMOTE_TUN_IP -p udp --dport $PORT -j SNAT --to-source $MY_TUN_IP
    
    netfilter-persistent save >/dev/null 2>&1
    echo -e "${GREEN}پورت $PORT با موفقیت به تانل $TARGET_GRE متصل شد!${NC}"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# 4. سیستم مانیتورینگ و لاگ‌گیری
check_status_logs() {
    echo -e "${CYAN}--- وضعیت و لاگ تانل‌ها ---${NC}"
    ACTIVE_IFS=$(ls /sys/class/net/ 2>/dev/null | grep -E '^gre[1-9]')
    
    if [ -z "$ACTIVE_IFS" ]; then
        echo -e "${RED}هیچ تانلی در سیستم ثبت نشده است.${NC}"; sleep 2; return
    fi
    
    for iface in $ACTIVE_IFS; do
        echo -e "${YELLOW}====================================${NC}"
        echo -e "${GREEN}نام تانل:${NC} $iface"
        TUN_IP=$(ip -4 addr show $iface 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        echo -e "${GREEN}آی‌پی لوکال:${NC} $TUN_IP"
        echo -e "${GREEN}وضعیت سرویس (systemctl):${NC}"
        systemctl status gre-tun-${iface}.service --no-pager | grep -E "Active:|Failed|Error"
        echo -e "${YELLOW}====================================${NC}\n"
    done
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# منوی اصلی
while true; do
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}       GRE Tunnel Manager v2.1 (Auto-Ping & Log)      ${NC}"
    echo -e "${YELLOW}       فزار فناور | فناوران زیرساخت داده راهورد       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo "1) ساخت تانل جدید (تولید توکن ارتباطی)"
    echo "2) اتصال به تانل (همراه با تست پینگ اتوماتیک)"
    echo "3) انتقال یک پورت خاص به داخل تانل"
    echo "4) وضعیت اتصال و لاگ تانل‌ها"
    echo "0) خروج"
    echo "------------------------------------------------------"
    read -p "انتخاب شما: " choice
    case $choice in
        1) generate_node_a ;;
        2) consume_node_b ;;
        3) manage_ports ;;
        4) check_status_logs ;;
        0) echo -e "${GREEN}خروج...${NC}"; exit 0 ;;
        *) echo -e "${RED}گزینه نامعتبر!${NC}"; sleep 1 ;;
    esac
done
