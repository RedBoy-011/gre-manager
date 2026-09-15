#!/bin/bash

# ==============================================================================
# GRE Tunnel Manager v4.2 - Pure Routing & Deep Diagnostics (Finglish Edition)
# Fazar Fanavar | Fanavaran Zirsakht Dadeh Rahavard
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
        echo -e "${RED}Hich tunneli yaft nashod!${NC}"
        return 1
    fi
    echo -e "${YELLOW}Tunnel-haye faale shoma:${NC}"
    for i in "${!ACTIVE_IFS[@]}"; do
        TUN_IP=$(ip -4 addr show ${ACTIVE_IFS[$i]} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        echo "$((i+1))) ${ACTIVE_IFS[$i]} (IP: $TUN_IP)"
    done
    read -p "Shomare tunnel ra vared konid: " TUN_NUM
    
    if ! [[ "$TUN_NUM" =~ ^[0-9]+$ ]] || [ "$TUN_NUM" -lt 1 ] || [ "$TUN_NUM" -gt "${#ACTIVE_IFS[@]}" ]; then
        echo -e "${RED}Entekhab namotabar!${NC}"
        sleep 2
        return 1
    fi
    TARGET_GRE="${ACTIVE_IFS[$((TUN_NUM-1))]}"
    return 0
}

install_deps() {
    if ! command -v ip >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1 || ! command -v tcpdump >/dev/null 2>&1; then
        echo -e "${YELLOW}Dar hale nasbe pish-niazha (iproute2, base64, tcpdump)...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q -y >/dev/null 2>&1
        apt-get install -q -y iproute2 base64 tcpdump >/dev/null 2>&1
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
# 🌍 Bakhshe Server Kharej (Master)
# ==========================================
generate_node_a() {
    install_deps
    echo -e "${CYAN}--- Server Kharej: Sakhte Tunnel Jadid ---${NC}"
    read -p "IP public hamin server (Kharej) ra vared konid: " MY_IP
    read -p "IP public server moghabel (Iran) ra vared konid: " REMOTE_IP
    
    echo -e "${YELLOW}Dar hale teste ertebat ba server Iran...${NC}"
    if ping -c 3 -W 2 "$REMOTE_IP" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Server Iran dar dastras ast.${NC}"
    else
        echo -e "${RED}⚠️ Server Iran ping nemidahad! (Momken ast firewall baste bashad).${NC}"
        read -p "Aya mikhahid ba in hal tunnel sakhte shavad? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then return; fi
    fi

    SUBNET_3RD=$((RANDOM % 200 + 10))
    SUBNET="10.200.${SUBNET_3RD}"
    GRE_IF=$(find_free_interface)
    
    create_service_file "$GRE_IF" "$MY_IP" "$REMOTE_IP" "${SUBNET}.1"
    
    TOKEN_RAW="${MY_IP}|${REMOTE_IP}|${SUBNET}"
    TOKEN=$(echo -n "$TOKEN_RAW" | base64 | tr -d '\n' | tr -d ' ')
    
    echo -e "\n${GREEN}Tunnel ba movafaghiat dar in server rah-andazi shod!${NC}"
    echo -e "=========================================================="
    echo -e "🌐 ${CYAN}IP Tunnel samte Kharej (Hamin server):${NC} ${SUBNET}.1"
    echo -e "🇮🇷 ${CYAN}IP Tunnel samte Iran (Bad az ettesal):${NC} ${SUBNET}.2"
    echo -e "=========================================================="
    echo -e "${YELLOW}Lotfan Token zire ra copy kardeh va dar menuye server Iran vared konid:${NC}"
    echo -e "\n${GREEN}${TOKEN}${NC}\n"
    read -p "Baraye bazgasht Enter bezanid..."
}

update_node_a() {
    echo -e "${CYAN}--- Server Kharej: Update Tanzimat & Sodoure Token Jadid ---${NC}"
    select_tunnel || return
    
    LOCAL_PUB=$(ip -d link show $TARGET_GRE 2>/dev/null | grep -oP '(?<=local\s)[a-fA-F0-9\.:]+' | head -n 1)
    SUBNET_FULL=$(ip -4 addr show $TARGET_GRE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    SUBNET=$(echo $SUBNET_FULL | cut -d'.' -f1,2,3)
    
    echo -e "IP public server khareje shoma: ${GREEN}$LOCAL_PUB${NC}"
    read -p "IP public jadide server Iran ra vared konid: " NEW_REMOTE_IP
    
    systemctl stop gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    create_service_file "$TARGET_GRE" "$LOCAL_PUB" "$NEW_REMOTE_IP" "${SUBNET}.1"
    
    TOKEN_RAW="${LOCAL_PUB}|${NEW_REMOTE_IP}|${SUBNET}"
    TOKEN=$(echo -n "$TOKEN_RAW" | base64 | tr -d '\n' | tr -d ' ')
    
    echo -e "\n${GREEN}Tanzimat dar server kharej baroozresani shod!${NC}"
    echo -e "${YELLOW}In Token jadid ra dar menuye update server Iran vared konid ta sync shavad:${NC}"
    echo -e "\n${GREEN}${TOKEN}${NC}\n"
    read -p "Baraye bazgasht Enter bezanid..."
}

# ==========================================
# 🇮🇷 Bakhshe Server Iran (Slave)
# ==========================================
consume_node_b() {
    install_deps
    echo -e "${CYAN}--- Server Iran: Ettesal be Tunnel ---${NC}"
    read -p "Token ijad shode dar server kharej ra paste konid: " TOKEN
    
    DECODED=$(echo -n "$TOKEN" | base64 --decode 2>/dev/null)
    if [[ "$DECODED" != *"|"* ]]; then echo -e "${RED}Token namotabar ast!${NC}"; sleep 2; return; fi
    
    REMOTE_IP=$(echo "$DECODED" | cut -d'|' -f1)
    MY_IP=$(echo "$DECODED" | cut -d'|' -f2)
    SUBNET=$(echo "$DECODED" | cut -d'|' -f3)

    GRE_IF=$(find_free_interface)
    create_service_file "$GRE_IF" "$MY_IP" "$REMOTE_IP" "${SUBNET}.2"
    
    echo -e "\n${YELLOW}Dar hale teste ertebate vaghe-ei dakhele tunnel...${NC}"
    sleep 2
    if ping -c 3 -W 2 "${SUBNET}.1" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Ertebate dotarafe tunnel kamelan movafaghiat-amiz ast!${NC}"
    else
        echo -e "${RED}⚠️ Tunnel sakhte shod ama ertebat bargharar nist! (Shayad IP-ha block bashand).${NC}"
    fi

    echo -e "=========================================================="
    echo -e "🇮🇷 ${CYAN}IP Tunnel samte Iran (Hamin server):${NC} ${SUBNET}.2"
    echo -e "🌐 ${CYAN}IP Tunnel samte Kharej (Server moghabel):${NC} ${SUBNET}.1"
    echo -e "=========================================================="
    read -p "Baraye bazgasht Enter bezanid..."
}

apply_update_node_b() {
    echo -e "${CYAN}--- Server Iran: Eemale Update rooye Tunnel Mojoud ---${NC}"
    select_tunnel || return
    
    read -p "Token update jadid ra paste konid: " TOKEN
    DECODED=$(echo -n "$TOKEN" | base64 --decode 2>/dev/null)
    if [[ "$DECODED" != *"|"* ]]; then echo -e "${RED}Token namotabar ast!${NC}"; sleep 2; return; fi
    
    REMOTE_IP=$(echo "$DECODED" | cut -d'|' -f1)
    MY_IP=$(echo "$DECODED" | cut -d'|' -f2)
    SUBNET=$(echo "$DECODED" | cut -d'|' -f3)

    systemctl stop gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    create_service_file "$TARGET_GRE" "$MY_IP" "$REMOTE_IP" "${SUBNET}.2"
    
    echo -e "\n${YELLOW}Dar hale teste ertebate update shode...${NC}"
    sleep 2
    if ping -c 3 -W 2 "${SUBNET}.1" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Tanzimat ba movafaghiat sync shod va ertebat bargharar ast!${NC}"
    else
        echo -e "${RED}⚠️ Tanzimat update shod ama ertebat bargharar nist.${NC}"
    fi
    read -p "Baraye bazgasht Enter bezanid..."
}

# ==========================================
# ℹ️ Vazeiat, Hazf & Eibyabi (Diagnostics)
# ==========================================
show_status() {
    echo -e "${CYAN}--- Vazeiat va IP Tunnel-ha ---${NC}"
    select_tunnel || return
    
    MY_TUN_IP=$(ip -4 addr show $TARGET_GRE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    REMOTE_TUN_IP="${MY_TUN_IP%.*}.1"
    if [ "$MY_TUN_IP" == "$REMOTE_TUN_IP" ]; then REMOTE_TUN_IP="${MY_TUN_IP%.*}.2"; fi

    echo -e "=========================================================="
    echo -e "Name Tunnel: ${GREEN}$TARGET_GRE${NC}"
    echo -e "IP Tunnel in server (Local): ${CYAN}$MY_TUN_IP${NC}"
    echo -e "IP Tunnel server moghabel (Remote): ${CYAN}$REMOTE_TUN_IP${NC}"
    echo -e "=========================================================="
    
    echo -e "${YELLOW}Teste Ping be server moghabel...${NC}"
    if ping -c 3 -W 2 $REMOTE_TUN_IP >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Vazeiat: Mottasel va Paydar${NC}"
    else
        echo -e "${RED}⚠️ Vazeiat: Ghat (Disconnected)${NC}"
    fi
    read -p "Baraye bazgasht Enter bezanid..."
}

delete_tunnel() {
    echo -e "${RED}--- Hazfe Kamel Tunnel ---${NC}"
    select_tunnel || return
    
    systemctl stop gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    systemctl disable gre-tun-${TARGET_GRE}.service >/dev/null 2>&1
    rm -f /etc/systemd/system/gre-tun-${TARGET_GRE}.service
    systemctl daemon-reload
    ip link del $TARGET_GRE >/dev/null 2>&1
    
    echo -e "${GREEN}Tunnel $TARGET_GRE kamelan hazf shod.${NC}"
    read -p "Baraye bazgasht Enter bezanid..."
}

deep_diagnostics() {
    install_deps
    echo -e "${CYAN}--- Systeme Eibyabi Amigh (Deep Diagnostics) ---${NC}"
    select_tunnel || return
    
    MY_TUN_IP=$(ip -4 addr show $TARGET_GRE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    REMOTE_TUN_IP="${MY_TUN_IP%.*}.1"
    if [ "$MY_TUN_IP" == "$REMOTE_TUN_IP" ]; then REMOTE_TUN_IP="${MY_TUN_IP%.*}.2"; fi

    echo -e "\n${YELLOW}1. Barresi IP Forwarding (Kernel)...${NC}"
    FWD=$(sysctl net.ipv4.ip_forward | awk '{print $3}')
    if [ "$FWD" == "1" ]; then
        echo -e "${GREEN}✅ IP Forwarding faal ast.${NC}"
    else
        echo -e "${RED}⚠️ IP Forwarding gheyr-faal ast! In baes mishavad traffic obour nakonad.${NC}"
    fi

    echo -e "\n${YELLOW}2. Teste MTU va Fragment (Packet Size Check)...${NC}"
    if ping -c 3 -M do -s 1300 $REMOTE_TUN_IP >/dev/null 2>&1; then
        echo -e "${GREEN}✅ MTU 1300 bedoune moshkel obour kard.${NC}"
    else
        echo -e "${RED}⚠️ Moshkel dar MTU! Packet-haye bozorg drop mishavand (Ehtemal dar Datacenter).${NC}"
    fi

    echo -e "\n${YELLOW}3. Barresi TCP Dump (Trafike Zende)...${NC}"
    echo -e "Dar hale shenoude trafike dakhele tunnel baraye 5 sanieh..."
    timeout 5 tcpdump -i $TARGET_GRE -n -c 5 > /tmp/gre_dump.txt 2>&1
    if grep -q "IP" /tmp/gre_dump.txt; then
        echo -e "${GREEN}✅ Trafik dar luleye GRE shenasayi shod (Data dar hale obour ast).${NC}"
    else
        echo -e "${RED}⚠️ Hich trafiki dar luleye GRE shenasayi nashod!${NC}"
        echo -e "${RED}Ehtemalan Protocol 47 (GRE) dar Firewall Datacenter baste ast, ya hich data-ei dar hale ersal nist.${NC}"
    fi
    rm -f /tmp/gre_dump.txt

    echo -e "\n${CYAN}Toseye Mohim: Agar hame chiz sabz ast ama port kar nemikonad:${NC}"
    echo -e "${CYAN}Motmaen shavid narmafzare shoma (mesle Xray ya SOCKS) rooye IP ${MY_TUN_IP} (Listen IP) bind shode bashad, na rooye 127.0.0.1${NC}"
    echo ""
    read -p "Baraye bazgasht Enter bezanid..."
}

# Menu-ye Asli
while true; do
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}       GRE Tunnel Manager v4.2 (Pure Routing)         ${NC}"
    echo -e "${YELLOW}       Fazar Fanavar | Fanavaran Zirsakht Dadeh       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${GREEN}[ Bakhshe Server Kharej (Master) ]${NC}"
    echo "1) 🌍 Sakhte Tunnel Jadid (Ijare Token)"
    echo "3) 🔄 Update IP va Sodoure Token Jadid"
    echo "------------------------------------------------------"
    echo -e "${CYAN}[ Bakhshe Server Iran (Slave) ]${NC}"
    echo "2) 🇮🇷 Ettesal be Tunnel (Vared Kardane Token)"
    echo "4) 🔄 Eemale Token Update (Sync Tanzimat)"
    echo "------------------------------------------------------"
    echo -e "${YELLOW}[ Vazeiat va Abzarha ]${NC}"
    echo "5) ℹ️ Namayeshe IP Tunnel-ha va Teste Vazeiat"
    echo "6) 🗑️ Hazfe Kamel Yek Tunnel"
    echo "7) 🔎 Systeme Eibyabi Amigh (Deep Diagnostics)"
    echo "0) Khorouj (Exit)"
    echo "------------------------------------------------------"
    read -p "Entekhabe Shoma: " choice
    case $choice in
        1) generate_node_a ;;
        2) consume_node_b ;;
        3) update_node_a ;;
        4) apply_update_node_b ;;
        5) show_status ;;
        6) delete_tunnel ;;
        7) deep_diagnostics ;;
        0) echo -e "${GREEN}Khorouj...${NC}"; exit 0 ;;
        *) echo -e "${RED}Entekhab namotabar!${NC}"; sleep 1 ;;
    esac
done
