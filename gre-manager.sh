#!/bin/bash

# ==============================================================================
# GRE Tunnel Manager v3.1 - Smart UI & Duplicate Protection
# فزار فناور | فناوران زیرساخت داده راهورد
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# پیدا کردن اولین کارت شبکه GRE آزاد
find_free_interface() {
    for i in {1..100}; do
        if [ ! -d "/sys/class/net/gre$i" ]; then
            echo "gre$i"
            return
        fi
    done
}

# تابع جدید برای نمایش لیست تانل‌ها و انتخاب با عدد
select_tunnel() {
    ACTIVE_IFS=($(ls /sys/class/net/ 2>/dev/null | grep -E '^gre[1-9]'))
    if [ ${#ACTIVE_IFS[@]} -eq 0 ]; then
        echo -e "${RED}هیچ تانلی یافت نشد!${NC}"
        return 1
    fi
    echo -e "${YELLOW}تانل‌های فعال شما:${NC}"
    for i in "${!ACTIVE_IFS[@]}"; do
        TUN_IP=$(ip -4 addr show ${ACTIVE_IFS[$i]} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        echo "$((i+1))) ${ACTIVE_IFS[$i]} (IP: $TUN_IP)"
    done
    read -p "شماره تانل مورد نظر را وارد کنید: " TUN_NUM
    
    if ! [[ "$TUN_NUM" =~ ^[0-9]+$ ]] || [ "$TUN_NUM" -lt 1 ] || [ "$TUN_NUM" -gt "${#ACTIVE_IFS[@]}" ]; then
        echo -e "${RED}انتخاب نامعتبر!${NC}"
        sleep 2
        return 1
    fi
    TARGET_GRE="${ACTIVE_IFS[$((TUN_NUM-1))]}"
    return 0
}

install_deps() {
    if ! command -v iptables >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        echo -e "${YELLOW}در حال نصب پیش‌نیازها...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q -y >/dev/null 2>&1
        apt-get install -q -y iptables iproute2 base64 iptables-persistent >/dev/null 2>&1
    fi
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-custom-gre.conf
    sysctl -p /etc/sysctl.d/99-custom-gre.conf >/dev/null 2>&1
}

# 1. ساخت تانل
generate_node_a() {
    install_deps
    echo -e "${CYAN}--- راه‌اندازی سرور مبدأ (ایجاد توکن) ---${NC}"
    read -p "آی‌پی عمومی همین سرور را وارد کنید: " MY_IP
    read -p "آی‌پی عمومی سرور مقابل را وارد کنید: " REMOTE_IP
    
    # بررسی تکراری نبودن اتصال قبل از ساخت توکن
    for iface in $(ls /sys/class/net/ 2>/dev/null | grep -E '^gre[1-9]'); do
        CUR_REMOTE=$(ip -d link show $iface 2>/dev/null | grep -oP '(?<=remote\s)[a-fA-F0-9\.:]+' | head -n 1)
        if [ "$CUR_REMOTE" == "$REMOTE_IP" ]; then
            echo -e "${RED}⚠️ اخطار: شما از قبل یک تانل ($iface) متصل به این آی‌پی دارید!${NC}"
            sleep 3; return
        fi
    done

    if [[ "$REMOTE_IP" == *":"* ]]; then
        CREATE_CMD="/sbin/ip link add \${GRE_IF} type ip6gre local ${MY_IP} remote ${REMOTE_IP}"
    else
        CREATE_CMD="/sbin/ip tunnel add \${GRE_IF} mode gre remote ${REMOTE_IP} local ${MY_IP}"
    fi

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
Environment="GRE_IF=${GRE_IF}"
ExecStart=${CREATE_CMD}
ExecStart=/sbin/ip link set \${GRE_IF} up
ExecStart=/sbin/ip addr add ${SUBNET}.1/30 dev \${GRE_IF}
ExecStop=/sbin/ip link del \${GRE_IF}

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

# 2. مصرف توکن
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

    # سیستم ضد تکرار (Duplicate Token Protection)
    for iface in $(ls /sys/class/net/ 2>/dev/null | grep -E '^gre[1-9]'); do
        CUR_REMOTE=$(ip -d link show $iface 2>/dev/null | grep -oP '(?<=remote\s)[a-fA-F0-9\.:]+' | head -n 1)
        if [ "$CUR_REMOTE" == "$REMOTE_IP" ]; then
            echo -e "${RED}⚠️ این توکن قبلاً وارد شده است! (تانل $iface هم‌اکنون به این سرور متصل است)${NC}"
            sleep 3; return
        fi
    done

    GRE_IF=$(find_free_interface)
    
    if [[ "$REMOTE_IP" == *":"* ]]; then
        CREATE_CMD="/sbin/ip link add \${GRE_IF} type ip6gre local ${MY_IP} remote ${REMOTE_IP}"
    else
        CREATE_CMD="/sbin/ip tunnel add \${GRE_IF} mode gre remote ${REMOTE_IP} local ${MY_IP}"
    fi

    cat <<EOF > /etc/systemd/system/gre-tun-${GRE_IF}.service
[Unit]
Description=GRE Tunnel ${GRE_IF}
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment="GRE_IF=${GRE_IF}"
ExecStart=${CREATE_CMD}
ExecStart=/sbin/ip link set \${GRE_IF} up
ExecStart=/sbin/ip addr add ${SUBNET}.2/30 dev \${GRE_IF}
ExecStop=/sbin/ip link del \${GRE_IF}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gre-tun-${GRE_IF}.service >/dev/null 2>&1
    systemctl start gre-tun-${GRE_IF}.service
    
    echo -e "\n${GREEN}اتصال موفق! تانل (${GRE_IF}) تنظیم شد.${NC}"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# 3. مدیریت پورت (افزودن/حذف)
manage_ports() {
    echo -e "${CYAN}--- مدیریت انتقال پورت‌های خاص ---${NC}"
    select_tunnel || return
    
    MY_TUN_IP=$(ip -4 addr show $TARGET_GRE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    REMOTE_TUN_IP="${MY_TUN_IP%.*}.1"
    if [ "$MY_TUN_IP" == "$REMOTE_TUN_IP" ]; then REMOTE_TUN_IP="${MY_TUN_IP%.*}.2"; fi

    read -p "چه پورتی را می‌خواهید مدیریت کنید؟ (مثلاً 51820): " PORT
    echo "1) اضافه کردن پورت به تانل"
    echo "2) حذف کردن پورت از تانل"
    read -p "انتخاب: " ACTION

    if [ "$ACTION" == "1" ]; then
        iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $REMOTE_TUN_IP:$PORT
        iptables -t nat -A PREROUTING -p udp --dport $PORT -j DNAT --to-destination $REMOTE_TUN_IP:$PORT
        iptables -t nat -A POSTROUTING -d $REMOTE_TUN_IP -p tcp --dport $PORT -j SNAT --to-source $MY_TUN_IP
        iptables -t nat -A POSTROUTING -d $REMOTE_TUN_IP -p udp --dport $PORT -j SNAT --to-source $MY_TUN_IP
        echo -e "${GREEN}پورت $PORT با موفقیت به تانل $TARGET_GRE اضافه شد!${NC}"
    elif [ "$ACTION" == "2" ]; then
        iptables -t nat -D PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $REMOTE_TUN_IP:$PORT 2>/dev/null
        iptables -t nat -D PREROUTING -p udp --dport $PORT -j DNAT --to-destination $REMOTE_TUN_IP:$PORT 2>/dev/null
        iptables -t nat -D POSTROUTING -d $REMOTE_TUN_IP -p tcp --dport $PORT -j SNAT --to-source $MY_TUN_IP 2>/dev/null
        iptables -t nat -D POSTROUTING -d $REMOTE_TUN_IP -p udp --dport $PORT -j SNAT --to-source $MY_TUN_IP 2>/dev/null
        echo -e "${GREEN}پورت $PORT با موفقیت از تانل $TARGET_GRE حذف شد!${NC}"
    fi
    netfilter-persistent save >/dev/null 2>&1
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# 4. نمایش توکن تانل موجود
show_token() {
    echo -e "${CYAN}--- بازیابی توکن تانل‌های فعال ---${NC}"
    select_tunnel || return
    
    LOCAL_PUB=$(ip -d link show $TARGET_GRE 2>/dev/null | grep -oP '(?<=local\s)[a-fA-F0-9\.:]+' | head -n 1)
    REMOTE_PUB=$(ip -d link show $TARGET_GRE 2>/dev/null | grep -oP '(?<=remote\s)[a-fA-F0-9\.:]+' | head -n 1)
    SUBNET_FULL=$(ip -4 addr show $TARGET_GRE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    SUBNET=$(echo $SUBNET_FULL | cut -d'.' -f1,2,3)
    
    if [ -z "$LOCAL_PUB" ] || [ -z "$SUBNET" ]; then
        echo -e "${RED}خطا در خواندن اطلاعات تانل!${NC}"; sleep 2; return
    fi
    
    TOKEN_RAW="${LOCAL_PUB}|${REMOTE_PUB}|${SUBNET}"
    TOKEN=$(echo -n "$TOKEN_RAW" | base64 -w 0)
    
    echo -e "${YELLOW}توکن تانل $TARGET_GRE :${NC}"
    echo -e "=========================================================="
    echo -e "${CYAN}${TOKEN}${NC}"
    echo -e "==========================================================\n"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# 5. تست پینگ
test_ping() {
    echo -e "${CYAN}--- تست ارتباط درون تانل ---${NC}"
    select_tunnel || return
    
    MY_TUN_IP=$(ip -4 addr show $TARGET_GRE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    REMOTE_TUN_IP="${MY_TUN_IP%.*}.1"
    if [ "$MY_TUN_IP" == "$REMOTE_TUN_IP" ]; then REMOTE_TUN_IP="${MY_TUN_IP%.*}.2"; fi

    echo -e "${YELLOW}در حال پینگ به $REMOTE_TUN_IP ...${NC}"
    if ping -c 4 -W 2 $REMOTE_TUN_IP; then
        echo -e "${GREEN}✅ ارتباط برقرار است!${NC}"
    else
        echo -e "${RED}⚠️ ارتباط قطع است!${NC}"
    fi
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# 6. حذف کامل تانل
delete_tunnel() {
    echo -e "${RED}--- حذف کامل تانل ---${NC}"
    select_tunnel || return
    
    systemctl stop gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    systemctl disable gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    rm -f /etc/systemd/system/gre-tun-${TARGET_GRE}.service
    systemctl daemon-reload
    ip link del $TARGET_GRE >/dev/null 2>&1
    
    echo -e "${GREEN}تانل $TARGET_GRE و تمامی سرویس‌های آن با موفقیت پاک شد!${NC}"
    echo -e "${YELLOW}نکته: رول‌های پورت فورواردینگ iptables مربوط به این تانل باید از بخش مدیریت پورت حذف شوند.${NC}"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# منوی اصلی
while true; do
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}       GRE Tunnel Manager v3.1 (Smart UI Edition)     ${NC}"
    echo -e "${YELLOW}       فزار فناور | فناوران زیرساخت داده راهورد       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo "1) ساخت تانل جدید (تولید توکن ارتباطی)"
    echo "2) اتصال به تانل (با استفاده از توکن)"
    echo "3) مدیریت پورت‌ها (اضافه / حذف پورت)"
    echo "4) نمایش مجدد توکنِ یک تانل فعال"
    echo "5) تست وضعیت ارتباط (Ping Test)"
    echo "6) حذف کامل یک تانل (Delete)"
    echo "0) خروج"
    echo "------------------------------------------------------"
    read -p "انتخاب شما: " choice
    case $choice in
        1) generate_node_a ;;
        2) consume_node_b ;;
        3) manage_ports ;;
        4) show_token ;;
        5) test_ping ;;
        6) delete_tunnel ;;
        0) echo -e "${GREEN}خروج...${NC}"; exit 0 ;;
        *) echo -e "${RED}گزینه نامعتبر!${NC}"; sleep 1 ;;
    esac
done
