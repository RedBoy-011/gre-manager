#!/bin/bash

# ==============================================================================
# GRE Tunnel Manager v4.0 - Pure L3 Routing & Master/Slave Token Sync
# فزار فناور | فناوران زیرساخت داده راهورد
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

find_free_interface() {
    for i in {1..100}; do
        if [ ! -d "/sys/class/net/gre$i" ]; then
            echo "gre$i"
            return
        fi
    done
}

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
    if ! command -v ip >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        echo -e "${YELLOW}در حال نصب پیش‌نیازها...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q -y >/dev/null 2>&1
        apt-get install -q -y iproute2 base64 >/dev/null 2>&1
    fi
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-custom-gre.conf
    sysctl -p /etc/sysctl.d/99-custom-gre.conf >/dev/null 2>&1
}

create_service_file() {
    local IFACE=$1
    local LOCAL_IP=$2
    local REMOTE_IP=$3
    local SUBNET_IP=$4

    if [[ "$REMOTE_IP" == *":"* ]]; then
        CREATE_CMD="/sbin/ip link add ${IFACE} type ip6gre local ${LOCAL_IP} remote ${REMOTE_IP}"
    else
        CREATE_CMD="/sbin/ip tunnel add ${IFACE} mode gre remote ${REMOTE_IP} local ${LOCAL_IP}"
    fi

    cat <<EOF > /etc/systemd/system/gre-tun-${IFACE}.service
[Unit]
Description=GRE Tunnel ${IFACE}
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${CREATE_CMD}
ExecStart=/sbin/ip link set ${IFACE} up
ExecStart=/sbin/ip addr add ${SUBNET_IP}/30 dev ${IFACE}
ExecStop=/sbin/ip link del ${IFACE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gre-tun-${IFACE}.service >/dev/null 2>&1
    systemctl restart gre-tun-${IFACE}.service
}

# ==========================================
# بخش سرور خارج (Master)
# ==========================================
generate_node_a() {
    install_deps
    echo -e "${CYAN}--- سرور خارج: ساخت تانل جدید ---${NC}"
    read -p "آی‌پی عمومی همین سرور (خارج) را وارد کنید: " MY_IP
    read -p "آی‌پی عمومی سرور مقابل (ایران) را وارد کنید: " REMOTE_IP
    
    SUBNET_3RD=$((RANDOM % 200 + 10))
    SUBNET="10.200.${SUBNET_3RD}"
    GRE_IF=$(find_free_interface)
    
    create_service_file "$GRE_IF" "$MY_IP" "$REMOTE_IP" "${SUBNET}.1"
    
    TOKEN_RAW="${MY_IP}|${REMOTE_IP}|${SUBNET}"
    TOKEN=$(echo -n "$TOKEN_RAW" | base64 -w 0)
    
    echo -e "\n${GREEN}تانل (${GRE_IF}) روی آی‌پی لوکال ${SUBNET}.1 ایجاد شد!${NC}"
    echo -e "${YELLOW}توکن زیر را کپی کرده و در سرور ایران (گزینه ۲) وارد کنید:${NC}"
    echo -e "=========================================================="
    echo -e "${CYAN}${TOKEN}${NC}"
    echo -e "==========================================================\n"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

update_node_a() {
    echo -e "${CYAN}--- سرور خارج: ویرایش و صدور توکن جدید ---${NC}"
    select_tunnel || return
    
    LOCAL_PUB=$(ip -d link show $TARGET_GRE 2>/dev/null | grep -oP '(?<=local\s)[a-fA-F0-9\.:]+' | head -n 1)
    SUBNET_FULL=$(ip -4 addr show $TARGET_GRE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    SUBNET=$(echo $SUBNET_FULL | cut -d'.' -f1,2,3)
    
    echo -e "آی‌پی سرور خارج شما: ${GREEN}$LOCAL_PUB${NC}"
    read -p "آی‌پی جدید سرور ایران را وارد کنید: " NEW_REMOTE_IP
    
    systemctl stop gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    create_service_file "$TARGET_GRE" "$LOCAL_PUB" "$NEW_REMOTE_IP" "${SUBNET}.1"
    
    TOKEN_RAW="${LOCAL_PUB}|${NEW_REMOTE_IP}|${SUBNET}"
    TOKEN=$(echo -n "$TOKEN_RAW" | base64 -w 0)
    
    echo -e "\n${GREEN}تنظیمات در سرور خارج بروزرسانی شد!${NC}"
    echo -e "${YELLOW}این توکن جدید را کپی کرده و در سرور ایران (گزینه ۴) وارد کنید تا تنظیمات سینک شود:${NC}"
    echo -e "=========================================================="
    echo -e "${CYAN}${TOKEN}${NC}"
    echo -e "==========================================================\n"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# ==========================================
# بخش سرور ایران (Slave)
# ==========================================
consume_node_b() {
    install_deps
    echo -e "${CYAN}--- سرور ایران: اتصال به تانل جدید ---${NC}"
    read -p "توکن ایجاد شده در سرور خارج را پیست کنید: " TOKEN
    
    DECODED=$(echo -n "$TOKEN" | base64 --decode 2>/dev/null)
    if [[ "$DECODED" != *"|"* ]]; then echo -e "${RED}توکن نامعتبر است!${NC}"; sleep 2; return; fi
    
    REMOTE_IP=$(echo "$DECODED" | cut -d'|' -f1)
    MY_IP=$(echo "$DECODED" | cut -d'|' -f2)
    SUBNET=$(echo "$DECODED" | cut -d'|' -f3)

    GRE_IF=$(find_free_interface)
    create_service_file "$GRE_IF" "$MY_IP" "$REMOTE_IP" "${SUBNET}.2"
    
    echo -e "\n${GREEN}اتصال موفق! تانل (${GRE_IF}) روی آی‌پی لوکال ${SUBNET}.2 تنظیم شد.${NC}"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

apply_update_node_b() {
    echo -e "${CYAN}--- سرور ایران: اعمال توکن آپدیت روی تانل موجود ---${NC}"
    select_tunnel || return
    
    read -p "توکن آپدیت جدید را پیست کنید: " TOKEN
    DECODED=$(echo -n "$TOKEN" | base64 --decode 2>/dev/null)
    if [[ "$DECODED" != *"|"* ]]; then echo -e "${RED}توکن نامعتبر است!${NC}"; sleep 2; return; fi
    
    REMOTE_IP=$(echo "$DECODED" | cut -d'|' -f1)
    MY_IP=$(echo "$DECODED" | cut -d'|' -f2)
    SUBNET=$(echo "$DECODED" | cut -d'|' -f3)

    systemctl stop gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    create_service_file "$TARGET_GRE" "$MY_IP" "$REMOTE_IP" "${SUBNET}.2"
    
    echo -e "\n${GREEN}تنظیمات با موفقیت روی تانل $TARGET_GRE سینک و بروزرسانی شد!${NC}"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# ==========================================
# عملیات مشترک
# ==========================================
test_ping() {
    echo -e "${CYAN}--- تست ارتباط دوطرفه درون تانل ---${NC}"
    select_tunnel || return
    
    MY_TUN_IP=$(ip -4 addr show $TARGET_GRE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    REMOTE_TUN_IP="${MY_TUN_IP%.*}.1"
    if [ "$MY_TUN_IP" == "$REMOTE_TUN_IP" ]; then REMOTE_TUN_IP="${MY_TUN_IP%.*}.2"; fi

    echo -e "${YELLOW}در حال پینگ به آی‌پی لوکال مقابل ($REMOTE_TUN_IP) ...${NC}"
    if ping -c 4 -W 2 $REMOTE_TUN_IP; then
        echo -e "${GREEN}✅ ارتباط مستقیم از داخل سرور برقرار است! مسیردهی (Routing) بدون نقص کار می‌کند.${NC}"
    else
        echo -e "${RED}⚠️ ارتباط قطع است! بررسی کنید آیا آی‌پی پابلیک تغییر کرده یا فایروال بسته است.${NC}"
    fi
    read -p "برای بازگشت به منو اینتر بزنید..."
}

delete_tunnel() {
    echo -e "${RED}--- حذف کامل تانل ---${NC}"
    select_tunnel || return
    
    systemctl stop gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    systemctl disable gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    rm -f /etc/systemd/system/gre-tun-${TARGET_GRE}.service
    systemctl daemon-reload
    ip link del $TARGET_GRE >/dev/null 2>&1
    
    echo -e "${GREEN}تانل $TARGET_GRE کاملاً حذف شد.${NC}"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# منوی اصلی
while true; do
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}       GRE Tunnel Manager v4.0 (Pure Routing)         ${NC}"
    echo -e "${YELLOW}       فزار فناور | فناوران زیرساخت داده راهورد       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${GREEN}[ بخش سرور خارج ]${NC}"
    echo "1) 🌍 ساخت تانل جدید (تولید توکن)"
    echo "3) 🔄 ویرایش اتصال تانل موجود (صدور توکن آپدیت)"
    echo "------------------------------------------------------"
    echo -e "${CYAN}[ بخش سرور ایران ]${NC}"
    echo "2) 🇮🇷 اتصال به تانل (دریافت توکن از سرور خارج)"
    echo "4) 🔄 اعمال توکن آپدیت روی تانل موجود"
    echo "------------------------------------------------------"
    echo -e "${YELLOW}[ ابزارهای مشترک ]${NC}"
    echo "5) 📡 تست وضعیت ارتباط (Ping Test دوطرفه)"
    echo "6) 🗑️ حذف کامل یک تانل"
    echo "0) خروج"
    echo "------------------------------------------------------"
    read -p "انتخاب شما: " choice
    case $choice in
        1) generate_node_a ;;
        2) consume_node_b ;;
        3) update_node_a ;;
        4) apply_update_node_b ;;
        5) test_ping ;;
        6) delete_tunnel ;;
        0) echo -e "${GREEN}خروج...${NC}"; exit 0 ;;
        *) echo -e "${RED}گزینه نامعتبر!${NC}"; sleep 1 ;;
    esac
done
