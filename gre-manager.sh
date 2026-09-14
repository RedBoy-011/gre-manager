#!/bin/bash

# ==============================================================================
# GRE Tunnel Manager v2.0 - Token Based & Port Selective
# فزار فناور | فناوران زیرساخت داده راهورد
# GitHub: https://github.com/RedBoy-011/gre-manager
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# پیدا کردن اولین کارت شبکه GRE آزاد
find_free_interface() {
    for i in {1..100}; do
        if ! ip link show gre$i > /dev/null 2>&1; then
            echo "gre$i"
            return
        fi
    done
}

install_deps() {
    if ! command -v iptables >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
        echo -e "${YELLOW}در حال نصب پیش‌نیازها...${NC}"
        apt-get update -q -y && apt-get install -q -y iptables iproute2 base64
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
    
    # تولید ساب‌نت رندوم برای جلوگیری از تداخل (مثلا 10.200.45.X)
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
    
    # تولید توکن
    TOKEN_RAW="${MY_IP}|${REMOTE_IP}|${SUBNET}"
    TOKEN=$(echo -n "$TOKEN_RAW" | base64 -w 0)
    
    echo -e "\n${GREEN}تانل (${GRE_IF}) با موفقیت ایجاد شد!${NC}"
    echo -e "${YELLOW}توکن زیر را کپی کرده و در سرور مقابل وارد کنید:${NC}"
    echo -e "=========================================================="
    echo -e "${CYAN}${TOKEN}${NC}"
    echo -e "==========================================================\n"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# 2. اتصال به تانل با توکن
consume_node_b() {
    install_deps
    echo -e "${CYAN}--- اتصال به تانل (مصرف توکن) ---${NC}"
    read -p "توکن را اینجا پیست کنید: " TOKEN
    
    # دیکود کردن توکن
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
    
    echo -e "\n${GREEN}اتصال موفق! تانل (${GRE_IF}) روی این سرور برقرار شد.${NC}"
    echo -e "آی‌پی لوکال شما: ${SUBNET}.2 | آی‌پی سرور مقابل: ${SUBNET}.1\n"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# 3. مدیریت پورت‌ها (انتقال انتخابی)
manage_ports() {
    echo -e "${CYAN}--- مدیریت انتقال پورت‌های خاص ---${NC}"
    
    # نمایش تانل‌های فعال
    ACTIVE_IFS=$(ip -o link show | awk -F': ' '{print $2}' | grep gre | grep -v gre0)
    if [ -z "$ACTIVE_IFS" ]; then
        echo -e "${RED}هیچ تانل GRE فعالی یافت نشد!${NC}"; sleep 2; return
    fi
    
    echo -e "${YELLOW}تانل‌های فعال شما:${NC}"
    echo "$ACTIVE_IFS"
    read -p "نام تانل مورد نظر را تایپ کنید (مثلاً gre1): " TARGET_GRE
    
    # استخراج آی‌پی لوکال و ریموت این تانل
    MY_TUN_IP=$(ip -4 addr show $TARGET_GRE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [ -z "$MY_TUN_IP" ]; then
        echo -e "${RED}تانل نامعتبر است!${NC}"; sleep 2; return
    fi
    REMOTE_TUN_IP="${MY_TUN_IP%.*}.1"
    if [ "$MY_TUN_IP" == "$REMOTE_TUN_IP" ]; then
        REMOTE_TUN_IP="${MY_TUN_IP%.*}.2"
    fi

    echo -e "انتقال ترافیک از این سرور به آی‌پی: ${CYAN}$REMOTE_TUN_IP${NC}"
    read -p "چه پورتی را می‌خواهید عبور دهید؟ (مثلاً 51820): " PORT
    
    # اعمال رول‌های اختصاصی فقط برای همین پورت
    iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $REMOTE_TUN_IP:$PORT
    iptables -t nat -A PREROUTING -p udp --dport $PORT -j DNAT --to-destination $REMOTE_TUN_IP:$PORT
    iptables -t nat -A POSTROUTING -d $REMOTE_TUN_IP -p tcp --dport $PORT -j SNAT --to-source $MY_TUN_IP
    iptables -t nat -A POSTROUTING -d $REMOTE_TUN_IP -p udp --dport $PORT -j SNAT --to-source $MY_TUN_IP
    
    # ذخیره رول‌ها
    apt-get install -y iptables-persistent >/dev/null 2>&1
    netfilter-persistent save >/dev/null 2>&1
    
    echo -e "${GREEN}پورت $PORT با موفقیت به تانل $TARGET_GRE متصل شد!${NC}"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# منوی اصلی
while true; do
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}       GRE Tunnel Manager v2.0 (Token Based)          ${NC}"
    echo -e "${YELLOW}       فزار فناور | فناوران زیرساخت داده راهورد       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo "1) ساخت تانل جدید (تولید توکن ارتباطی)"
    echo "2) اتصال به تانل (با استفاده از توکن)"
    echo "3) انتقال یک پورت خاص به داخل تانل"
    echo "0) خروج"
    echo "------------------------------------------------------"
    read -p "انتخاب شما: " choice
    case $choice in
        1) generate_node_a ;;
        2) consume_node_b ;;
        3) manage_ports ;;
        0) echo -e "${GREEN}خروج...${NC}"; exit 0 ;;
        *) echo -e "${RED}گزینه نامعتبر!${NC}"; sleep 1 ;;
    esac
done
