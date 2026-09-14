#!/bin/bash

# ==============================================================================
# GRE Tunnel Manager - WireGuard Optimized
# فزار فناور | فناوران زیرساخت داده راهورد
# GitHub: https://github.com/RedBoy-011/gre-manager
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# بررسی و نصب هوشمند پیش‌نیازها
install_deps() {
    if command -v iptables >/dev/null 2>&1 && command -v ip >/dev/null 2>&1; then
        echo -e "${GREEN}پیش‌نیازها از قبل نصب هستند. پرش از این مرحله...${NC}"
        sleep 1
    else
        echo -e "${YELLOW}در حال نصب پیش‌نیازهای تانل (iptables, iproute2)...${NC}"
        apt-get update -q -y
        apt-get install -q -y iptables iproute2
        echo -e "${GREEN}نصب پیش‌نیازها با موفقیت انجام شد.${NC}"
    fi
    echo "------------------------------------------------------"
}

# اعمال تنظیمات Sysctl برای فورواردینگ
apply_sysctl() {
    echo -e "${CYAN}در حال تنظیم Sysctl...${NC}"
    cat <<EOF > /etc/sysctl.d/99-custom.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.eth0.proxy_ndp=1
EOF
    sysctl -p /etc/sysctl.d/99-custom.conf >/dev/null 2>&1
}

# راه‌اندازی تانل
setup_tunnel() {
    install_deps
    apply_sysctl

    echo -e "${YELLOW}پیکربندی سرور ${ROLE}${NC}"
    read -p "آی‌پی سرور مقابل را وارد کنید: " REMOTE_IP
    
    # مقادیر پیش‌فرض بر اساس نقش
    if [ "$ROLE" == "ایران" ]; then
        DEF_LOCAL_IP="10.255.255.1"
        DEF_LOCAL_IP6="fd0::1"
    else
        DEF_LOCAL_IP="10.255.255.2"
        DEF_LOCAL_IP6="fd0::2"
    fi

    read -p "آی‌پی لوکال تانل (IPv4) [پیش‌فرض: $DEF_LOCAL_IP]: " LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$DEF_LOCAL_IP}
    
    read -p "آی‌پی لوکال تانل (IPv6) [پیش‌فرض: $DEF_LOCAL_IP6]: " LOCAL_IP6
    LOCAL_IP6=${LOCAL_IP6:-$DEF_LOCAL_IP6}

    # ایجاد سرویس تونل
    cat <<EOF > /etc/systemd/system/tun.service
[Unit]
Description=GRE Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add gre1 mode gre remote $REMOTE_IP
ExecStart=/sbin/ip link set gre1 up
ExecStart=/sbin/ip addr add $LOCAL_IP/30 dev gre1
ExecStart=/sbin/ip -6 addr add $LOCAL_IP6/64 dev gre1
ExecStop=/sbin/ip link del gre1

[Install]
WantedBy=multi-user.target
EOF

    # ایجاد سرویس NAT
    cat <<EOF > /etc/systemd/system/gre-nat.service
[Unit]
Description=GRE NAT
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables -t nat -A POSTROUTING -s 10.255.255.0/30 -o eth0 -j MASQUERADE
ExecStop=/usr/sbin/iptables -t nat -D POSTROUTING -s 10.255.255.0/30 -o eth0 -j MASQUERADE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tun.service gre-nat.service >/dev/null 2>&1
    systemctl restart tun.service gre-nat.service
    
    echo -e "${GREEN}تانل و NAT با موفقیت پیکربندی و اجرا شدند!${NC}"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# تست اتصال تانل
test_tunnel() {
    echo -e "${CYAN}در حال پینگ گرفتن از سرور مقابل در بستر تانل...${NC}"
    if [ "$ROLE" == "ایران" ]; then
        TARGET="10.255.255.2"
    else
        TARGET="10.255.255.1"
    fi
    ping -c 4 $TARGET
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# حذف کامل تانل
remove_tunnel() {
    echo -e "${RED}در حال حذف تمامی تنظیمات تانل GRE...${NC}"
    systemctl stop tun.service gre-nat.service >/dev/null 2>&1
    systemctl disable tun.service gre-nat.service >/dev/null 2>&1
    rm -f /etc/systemd/system/tun.service
    rm -f /etc/systemd/system/gre-nat.service
    systemctl daemon-reload
    ip link del gre1 >/dev/null 2>&1
    iptables -t nat -D POSTROUTING -s 10.255.255.0/30 -o eth0 -j MASQUERADE >/dev/null 2>&1
    echo -e "${GREEN}تانل با موفقیت حذف شد.${NC}"
    read -p "برای بازگشت به منو اینتر بزنید..."
}

# منوی اصلی
while true; do
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}           GRE Tunnel Auto-Manager                    ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo "1) نصب و کانفیگ سرور >> ایران <<"
    echo "2) نصب و کانفیگ سرور >> خارج <<"
    echo "3) تست ارتباط تانل (Ping)"
    echo "4) حذف کامل تانل و تنظیمات"
    echo "0) خروج"
    echo "------------------------------------------------------"
    read -p "انتخاب شما: " choice
    case $choice in
        1) ROLE="ایران"; setup_tunnel ;;
        2) ROLE="خارج"; setup_tunnel ;;
        3) 
            if ip a | grep -q gre1; then
                # تشخیص نقش از روی آی‌پی ست شده
                if ip a show gre1 | grep -q "10.255.255.1"; then ROLE="ایران"; else ROLE="خارج"; fi
                test_tunnel
            else
                echo -e "${RED}تانلی یافت نشد! ابتدا تانل را نصب کنید.${NC}"
                sleep 2
            fi
            ;;
        4) remove_tunnel ;;
        0) echo -e "${GREEN}خروج...${NC}"; exit 0 ;;
        *) echo -e "${RED}گزینه نامعتبر!${NC}"; sleep 1 ;;
    esac
done
