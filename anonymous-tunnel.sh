#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

APP_NAME="anonymous-tunnel"
INSTALL_PATH="/usr/local/bin/$APP_NAME"
CORE_DIR="/usr/local/lib/$APP_NAME"
BIN_PATH="$CORE_DIR/core"
CONFIG_DIR="/etc/$APP_NAME"
SERVICE_DIR="/etc/systemd/system"
TG_CHANNEL="@anonymoustunnel"
APP_VERSION="2.4"
GITHUB_REPO="theneet0/anonymous-tunnel"
RELEASE_BASE_URL="https://github.com/$GITHUB_REPO/releases/latest/download"
MIRROR_BASE_URL="https://ghproxy.net/https://github.com/$GITHUB_REPO/releases/latest/download"

mkdir -p "$CONFIG_DIR" "$CORE_DIR"

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run this script as root.${NC}"
        exit 1
    fi
}

self_install() {
    local SELF
    SELF="$(readlink -f "$0")"
    if [ "$SELF" != "$INSTALL_PATH" ]; then
        cp "$SELF" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo -e "${GREEN}Anonymous Tunnel has been installed as a system command.${NC}"
        echo -e "${YELLOW}Next time just run: ${GREEN}sudo anonymous-tunnel${NC}"
        sleep 2
    fi
}

banner() {
    clear
    echo -e "${CYAN}${BOLD}==============================================${NC}"
    echo -e "${MAGENTA}${BOLD}            ANONYMOUS TUNNEL MANAGER${NC}"
    echo -e "${CYAN}${BOLD}                  v${APP_VERSION}${NC}"
    echo -e "${CYAN}${BOLD}==============================================${NC}"
    if [ -f "$BIN_PATH" ] && [ -x "$BIN_PATH" ]; then
        echo -e "${YELLOW}Core: ${GREEN}Installed${NC}"
    else
        echo -e "${YELLOW}Core: ${RED}Not Installed${NC}"
    fi
    echo -e "${YELLOW}Telegram Channel: ${GREEN}${TG_CHANNEL}${NC}"
    echo -e "${CYAN}${BOLD}==============================================${NC}"
}

get_json_value() {
    local file=$1
    local key=$2
    grep -oP "\"$key\"\s*:\s*\"\K[^\"]+" "$file" 2>/dev/null | head -n1
}

get_json_number() {
    local file=$1
    local key=$2
    grep -oP "\"$key\"\s*:\s*\K[0-9]+(\.[0-9]+)?" "$file" 2>/dev/null | head -n1
}

is_zero_gb() {
    awk -v v="$1" 'BEGIN{ if (v+0==0) exit 0; exit 1 }'
}

measure_latency() {
    local host=$1
    local port=$2
    local start end
    start=$(date +%s%N)
    if timeout 1 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        end=$(date +%s%N)
        echo "$(( (end-start)/1000000 ))ms"
    else
        echo "down"
    fi
}

show_tunnel_status() {
    local TUNNELS=($(list_tunnels))
    if [ ${#TUNNELS[@]} -eq 0 ]; then
        return
    fi
    echo -e "${YELLOW}${BOLD}Tunnels:${NC}"
    for T in "${TUNNELS[@]}"; do
        local CFG="$CONFIG_DIR/$T.json"
        local MODE
        MODE=$(get_json_value "$CFG" mode)
        local ACTIVE
        ACTIVE=$(systemctl is-active "${APP_NAME}-$T" 2>/dev/null)
        local STATC="${RED}Stopped${NC}"
        if [ "$ACTIVE" == "active" ]; then
            STATC="${GREEN}Running${NC}"
        fi
        local PING="-"
        local TRANSPORT_V
        TRANSPORT_V=$(get_json_value "$CFG" transport)
        if [ "$TRANSPORT_V" == "udp_fec" ]; then
            PING="n/a (udp)"
        elif [ "$MODE" == "client" ]; then
            local SADDR
            SADDR=$(get_json_value "$CFG" server_addr)
            local HOST=${SADDR%%:*}
            local PORT=${SADDR##*:}
            PING=$(measure_latency "$HOST" "$PORT")
        else
            local BADDR
            BADDR=$(get_json_value "$CFG" bind_addr)
            local PORT=${BADDR##*:}
            if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
                PING="listening"
            else
                PING="down"
            fi
        fi
        echo -e "  ${CYAN}$T${NC} [$MODE] - $STATC - ping: $PING"
    done
    echo -e "${CYAN}${BOLD}==============================================${NC}"
}

show_traffic_summary() {
    local TOTAL_RX=0
    local TOTAL_TX=0
    local T
    for T in $(list_tunnels); do
        local STATS="$CONFIG_DIR/$T.stats.json"
        if [ -f "$STATS" ]; then
            local RX TX
            RX=$(get_json_number "$STATS" rx)
            TX=$(get_json_number "$STATS" tx)
            RX=${RX:-0}
            TX=${TX:-0}
            TOTAL_RX=$((TOTAL_RX + RX))
            TOTAL_TX=$((TOTAL_TX + TX))
        fi
    done
    local TOTAL=$((TOTAL_RX + TOTAL_TX))
    echo -e "${YELLOW}${BOLD}Traffic:${NC} ${CYAN}Download: ${GREEN}$(human_bytes $TOTAL_RX)${NC}  ${CYAN}Upload: ${GREEN}$(human_bytes $TOTAL_TX)${NC}  ${CYAN}Total: ${GREEN}$(human_bytes $TOTAL)${NC}"
    echo -e "${CYAN}${BOLD}==============================================${NC}"
}

pause() {
    echo ""
    read -p "$(echo -e ${YELLOW}Press Enter to continue...${NC})"
}

detect_arch() {
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) echo "linux-amd64" ;;
        aarch64|arm64) echo "linux-arm64" ;;
        armv7l|armv7) echo "linux-armv7" ;;
        armv6l|armv6) echo "linux-armv6" ;;
        i386|i686) echo "linux-386" ;;
        *) echo "" ;;
    esac
}

ensure_downloader() {
    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${BLUE}Installing curl and wget...${NC}"
    if command -v apt >/dev/null 2>&1; then
        apt update -y >/dev/null 2>&1
        apt install -y curl wget >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget >/dev/null 2>&1
    fi
}

fetch_file() {
    local url=$1
    local dest=$2
    local timeout=15

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$timeout" -m 60 "$url" -o "$dest" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$timeout" -O "$dest" "$url" 2>/dev/null
    else
        return 1
    fi
}

download_core() {
    ensure_downloader
    local ARCH_SUFFIX
    ARCH_SUFFIX=$(detect_arch)
    if [ -z "$ARCH_SUFFIX" ]; then
        echo -e "${RED}Unsupported system architecture: $(uname -m)${NC}"
        return 1
    fi

    local ASSET_NAME="anonymous-tunnel-core-${ARCH_SUFFIX}"
    local PRIMARY_URL="${RELEASE_BASE_URL}/${ASSET_NAME}"
    local FALLBACK_URL="${MIRROR_BASE_URL}/${ASSET_NAME}"
    local TMP_FILE="/tmp/${ASSET_NAME}.tmp"

    rm -f "$TMP_FILE"
    echo -e "${BLUE}Target architecture: ${CYAN}${ARCH_SUFFIX}${NC}"
    echo -e "${BLUE}Downloading core from GitHub Releases...${NC}"

    if fetch_file "$PRIMARY_URL" "$TMP_FILE" && [ -s "$TMP_FILE" ]; then
        echo -e "${GREEN}Downloaded directly from GitHub Releases.${NC}"
    else
        echo -e "${YELLOW}Direct GitHub download failed or timed out. Trying mirror...${NC}"
        if fetch_file "$FALLBACK_URL" "$TMP_FILE" && [ -s "$TMP_FILE" ]; then
            echo -e "${GREEN}Downloaded successfully via mirror.${NC}"
        else
            echo -e "${RED}Failed to download core from both GitHub and mirror.${NC}"
            echo -e "${YELLOW}Checked URLs:${NC}"
            echo "  $PRIMARY_URL"
            echo "  $FALLBACK_URL"
            rm -f "$TMP_FILE"
            return 1
        fi
    fi

    chmod +x "$TMP_FILE"
    mv "$TMP_FILE" "$BIN_PATH"
    echo -e "${GREEN}Core binary installed at ${BIN_PATH}${NC}"
    return 0
}

download_core_silent() {
    ensure_downloader
    local ARCH_SUFFIX
    ARCH_SUFFIX=$(detect_arch)
    [ -z "$ARCH_SUFFIX" ] && return 1

    local ASSET_NAME="anonymous-tunnel-core-${ARCH_SUFFIX}"
    local PRIMARY_URL="${RELEASE_BASE_URL}/${ASSET_NAME}"
    local FALLBACK_URL="${MIRROR_BASE_URL}/${ASSET_NAME}"
    local TMP_FILE="/tmp/${ASSET_NAME}.tmp"

    rm -f "$TMP_FILE"
    if fetch_file "$PRIMARY_URL" "$TMP_FILE" && [ -s "$TMP_FILE" ]; then
        chmod +x "$TMP_FILE"
        mv "$TMP_FILE" "$BIN_PATH"
        return 0
    fi
    if fetch_file "$FALLBACK_URL" "$TMP_FILE" && [ -s "$TMP_FILE" ]; then
        chmod +x "$TMP_FILE"
        mv "$TMP_FILE" "$BIN_PATH"
        return 0
    fi
    rm -f "$TMP_FILE"
    return 1
}

install_core() {
    banner
    echo -e "${BLUE}Preparing Anonymous Tunnel Core...${NC}"
    if download_core; then
        echo -e "${GREEN}Anonymous Tunnel Core installed successfully.${NC}"
        local EXISTING
        EXISTING=($(list_tunnels))
        if [ ${#EXISTING[@]} -gt 0 ]; then
            read -p "$(echo -e ${CYAN}Restart all existing tunnels to apply this update now? - y or n [y]: ${NC})" RESTART_ALL
            RESTART_ALL=${RESTART_ALL:-y}
            if [ "$RESTART_ALL" == "y" ]; then
                for T in "${EXISTING[@]}"; do
                    systemctl restart "${APP_NAME}-$T" >/dev/null 2>&1
                done
                echo -e "${GREEN}All tunnels restarted with the updated core.${NC}"
            fi
        fi
    else
        echo -e "${RED}Failed to install core.${NC}"
    fi
    pause
}

check_installed() {
    if [ ! -f "$BIN_PATH" ] || [ ! -x "$BIN_PATH" ]; then
        echo -e "${RED}Core is not installed. Please install it first.${NC}"
        pause
        return 1
    fi
    return 0
}

list_tunnels() {
    ls "$CONFIG_DIR" 2>/dev/null | grep -v "\.stats\.json$" | grep -v "^telegram\.json$" | grep "\.json$" | sed 's/\.json$//'
}

generate_token() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

print_diag_line() {
    local name=$1
    local status=$2
    local detail=$3
    case "$status" in
        ok) echo -e "${GREEN}✓${NC} ${CYAN}$name${NC}: $detail" ;;
        warn) echo -e "${YELLOW}!${NC} ${CYAN}$name${NC}: $detail" ;;
        skip) echo -e "${YELLOW}-${NC} ${CYAN}$name${NC}: $detail" ;;
        *) echo -e "${RED}✗${NC} ${CYAN}$name${NC}: $detail" ;;
    esac
}

diag_dns() {
    local host=$1
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ok|already an IP address, DNS not needed"
        return 0
    fi
    local resolved
    resolved=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')
    if [ -n "$resolved" ]; then
        echo "ok|resolved to: $resolved"
        return 0
    fi
    echo "fail|could not resolve hostname"
    return 1
}

diag_ipv4() {
    local host=$1
    if ping -4 -c 2 -W 2 "$host" >/dev/null 2>&1; then
        echo "ok|reachable over IPv4"
        return 0
    fi
    echo "fail|no IPv4 reply"
    return 1
}

diag_ipv6() {
    local host=$1
    if ping -6 -c 2 -W 2 "$host" >/dev/null 2>&1; then
        echo "ok|reachable over IPv6"
        return 0
    fi
    echo "fail|no IPv6 reply (normal if the server has no IPv6)"
    return 1
}

diag_tcp() {
    local host=$1
    local port=$2
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        echo "ok|TCP handshake succeeded on port $port"
        return 0
    fi
    echo "fail|could not open TCP connection to port $port"
    return 1
}

diag_udp() {
    local host=$1
    local port=$2
    if ! command -v nc >/dev/null 2>&1; then
        echo "skip|nc not installed, skipped"
        return 2
    fi
    if timeout 3 bash -c "echo -n '' | nc -u -w2 $host $port" >/dev/null 2>&1; then
        echo "ok|UDP packet sent without error (UDP has no handshake to confirm delivery)"
        return 0
    fi
    echo "fail|failed to send UDP packet"
    return 1
}

diag_mtu() {
    local host=$1
    local best=0
    local size
    for size in 1472 1400 1300 1200; do
        if ping -M do -c 1 -W 2 -s "$size" "$host" >/dev/null 2>&1; then
            best=$((size + 28))
            break
        fi
    done
    if [ "$best" -gt 0 ]; then
        echo "ok|path MTU at least $best bytes"
        return 0
    fi
    echo "fail|even the smallest test packet (1228 bytes) failed"
    return 1
}

diag_route() {
    local host=$1
    local resolved_ip
    resolved_ip=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | head -n1)
    if [ -z "$resolved_ip" ]; then
        resolved_ip="$host"
    fi
    local r
    r=$(ip route get "$resolved_ip" 2>/dev/null | head -n1)
    if [ -n "$r" ]; then
        echo "ok|$r"
        return 0
    fi
    echo "fail|no route found"
    return 1
}

diag_ping_stats() {
    local host=$1
    local out
    out=$(ping -c 10 -W 2 "$host" 2>/dev/null)
    local loss
    loss=$(echo "$out" | grep -oP '\d+(?=% packet loss)')
    local avg
    avg=$(echo "$out" | grep -oP '= [0-9.]+/\K[0-9.]+')
    echo "${loss}|${avg}"
}

diag_firewall() {
    if command -v ufw >/dev/null 2>&1; then
        local st
        st=$(ufw status 2>/dev/null | head -n1)
        echo "info|ufw: $st"
        return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        local st
        st=$(firewall-cmd --state 2>/dev/null)
        echo "info|firewalld: $st"
        return 0
    fi
    local rules
    rules=$(iptables -L -n 2>/dev/null | grep -c "DROP\|REJECT")
    rules=${rules:-0}
    if [ "$rules" -gt 0 ]; then
        echo "info|no firewall manager detected, but iptables has $rules DROP/REJECT rules"
    else
        echo "info|no active firewall manager or blocking iptables rules detected"
    fi
    return 0
}

diag_port_accessibility() {
    local host=$1
    local port=$2
    local start end
    start=$(date +%s%N)
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        end=$(date +%s%N)
        echo "ok|open ($(( (end-start)/1000000 ))ms)"
        return 0
    fi
    echo "fail|closed or filtered (connection timed out or refused)"
    return 1
}

network_diagnostics() {
    banner
    echo -e "${YELLOW}${BOLD}Network Diagnostics${NC}"
    if command -v apt >/dev/null 2>&1; then
        apt install -y iputils-ping iproute2 netcat-openbsd >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iputils iproute nmap-ncat >/dev/null 2>&1
    fi

    local TUNNELS=($(list_tunnels))
    local HOST=""
    local PORT=""
    if [ ${#TUNNELS[@]} -gt 0 ]; then
        echo -e "${CYAN}Pick a tunnel to diagnose, or 0 for a custom host:${NC}"
        for i in "${!TUNNELS[@]}"; do
            echo "  $((i+1)). ${TUNNELS[$i]}"
        done
        read -p "$(echo -e ${CYAN}Select - 0 for custom: ${NC})" SEL
        if [ "$SEL" != "0" ] && [ -n "$SEL" ]; then
            local IDX=$((SEL-1))
            local TNAME="${TUNNELS[$IDX]}"
            local CFG="$CONFIG_DIR/$TNAME.json"
            local MODE
            MODE=$(get_json_value "$CFG" mode)
            if [ "$MODE" == "client" ]; then
                local SADDR
                SADDR=$(get_json_value "$CFG" server_addr)
                HOST=${SADDR%%:*}
                PORT=${SADDR##*:}
            else
                local BADDR
                BADDR=$(get_json_value "$CFG" bind_addr)
                HOST="127.0.0.1"
                PORT=${BADDR##*:}
            fi
        fi
    fi
    if [ -z "$HOST" ]; then
        read -p "$(echo -e ${CYAN}Enter host/IP to test: ${NC})" HOST
        read -p "$(echo -e ${CYAN}Enter port to test: ${NC})" PORT
    fi

    banner
    echo -e "${YELLOW}${BOLD}Network Diagnostics${NC} - ${CYAN}$HOST:$PORT${NC}"
    echo ""

    local RESULT STATUS DETAIL

    RESULT=$(diag_dns "$HOST"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    print_diag_line "DNS" "$STATUS" "$DETAIL"

    RESULT=$(diag_ipv4 "$HOST"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    print_diag_line "IPv4" "$STATUS" "$DETAIL"

    RESULT=$(diag_ipv6 "$HOST"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    print_diag_line "IPv6" "$STATUS" "$DETAIL"

    RESULT=$(diag_tcp "$HOST" "$PORT"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    print_diag_line "TCP Connectivity" "$STATUS" "$DETAIL"

    RESULT=$(diag_udp "$HOST" "$PORT"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    print_diag_line "UDP Connectivity" "$STATUS" "$DETAIL"

    RESULT=$(diag_mtu "$HOST"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    print_diag_line "MTU" "$STATUS" "$DETAIL"

    RESULT=$(diag_route "$HOST"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    print_diag_line "Route" "$STATUS" "$DETAIL"

    IFS='|' read -r LOSS AVG <<< "$(diag_ping_stats "$HOST")"
    if [ -n "$LOSS" ]; then
        if [ "$LOSS" -eq 0 ]; then
            print_diag_line "Packet Loss" "ok" "0% loss"
        elif [ "$LOSS" -lt 20 ]; then
            print_diag_line "Packet Loss" "warn" "${LOSS}% loss"
        else
            print_diag_line "Packet Loss" "fail" "${LOSS}% loss"
        fi
    else
        print_diag_line "Packet Loss" "fail" "no ping reply at all"
    fi

    if [ -n "$AVG" ]; then
        print_diag_line "Latency" "ok" "avg ${AVG}ms"
    else
        print_diag_line "Latency" "fail" "no ping reply"
    fi

    RESULT=$(diag_firewall); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    print_diag_line "Firewall" "$STATUS" "$DETAIL"

    RESULT=$(diag_port_accessibility "$HOST" "$PORT"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    print_diag_line "Port Accessibility" "$STATUS" "$DETAIL"

    pause
}

bench_cpu_model() {
    awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ *//'
}

bench_cpu_cores() {
    local cores mhz
    cores=$(nproc)
    mhz=$(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo | xargs)
    echo "${cores} @ ${mhz} MHz"
}

bench_cpu_cache() {
    awk -F: '/cache size/ {print $2; exit}' /proc/cpuinfo | xargs
}

bench_aesni() {
    if grep -qi aes /proc/cpuinfo; then
        echo "✓ Enabled"
    else
        echo "✗ Disabled"
    fi
}

bench_virt_support() {
    if grep -Eqi 'vmx|svm' /proc/cpuinfo; then
        echo "✓ Enabled"
    else
        echo "✗ Disabled"
    fi
}

bench_disk_info() {
    df -h --total 2>/dev/null | awk '/^total/ {print $2" ("$3" Used)"}'
}

bench_ram_info() {
    free -m | awk '/^Mem:/ {printf "%s MB (%s MB Used)", $2, $3}'
}

bench_swap_info() {
    free -m | awk '/^Swap:/ {if ($2>0) printf "%.1f GB (%s MB Used)", $2/1024, $3; else print "0 B (0 B Used)"}'
}

bench_uptime() {
    uptime -p 2>/dev/null | sed 's/^up //'
}

bench_load_avg() {
    awk '{print $1", "$2", "$3}' /proc/loadavg
}

bench_os_info() {
    if [ -f /etc/os-release ]; then
        awk -F= '/^PRETTY_NAME/ {gsub(/"/,"",$2); print $2}' /etc/os-release
    else
        uname -s
    fi
}

bench_virt_type() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local v
        v=$(systemd-detect-virt 2>/dev/null)
        if [ "$v" == "none" ]; then
            echo "Dedicated/Bare Metal"
        else
            echo "$v"
        fi
    else
        echo "Unknown"
    fi
}

bench_ip_online() {
    local flag=$1
    if curl -s "$flag" -m 5 -o /dev/null https://icanhazip.com 2>/dev/null; then
        echo "✓ Online"
    else
        echo "✗ Offline"
    fi
}

bench_io_run() {
    local result
    result=$(dd if=/dev/zero of=/tmp/anontunnel_iotest bs=64k count=16k conv=fdatasync 2>&1 | tail -n1)
    rm -f /tmp/anontunnel_iotest
    local speed unit
    speed=$(echo "$result" | grep -oP '[\d.]+(?=\s*[MG]B/s)')
    unit=$(echo "$result" | grep -oP '[MG]B/s')
    if [ "$unit" == "GB/s" ]; then
        speed=$(awk -v s="$speed" 'BEGIN{printf "%.1f", s*1024}')
    fi
    if [ -z "$speed" ]; then
        speed="0"
    fi
    echo "$speed"
}

bench_speedtest_row() {
    local label=$1
    local server_arg=$2
    local json
    json=$(speedtest --accept-license --accept-gdpr -f json $server_arg 2>/dev/null)
    if [ -z "$json" ] || ! echo "$json" | jq -e '.type == "result"' >/dev/null 2>&1; then
        printf " %-26s%-16s%-18s%-10s\n" "$label" "failed" "failed" "failed"
        return
    fi
    local dl up lat
    dl=$(echo "$json" | jq -r '.download.bandwidth')
    up=$(echo "$json" | jq -r '.upload.bandwidth')
    lat=$(echo "$json" | jq -r '.ping.latency')
    local dl_mbps up_mbps lat_ms
    dl_mbps=$(awk -v b="$dl" 'BEGIN{printf "%.2f", b*8/1000000}')
    up_mbps=$(awk -v b="$up" 'BEGIN{printf "%.2f", b*8/1000000}')
    lat_ms=$(awk -v l="$lat" 'BEGIN{printf "%.2f", l}')
    printf " %-26s%-16s%-18s%-10s\n" "$label" "${up_mbps} Mbps" "${dl_mbps} Mbps" "${lat_ms} ms"
}

bench_find_server_id() {
    local city=$1
    local encoded
    encoded=$(echo "$city" | sed 's/ /%20/g')
    curl -s -m 8 "https://www.speedtest.net/api/js/servers?engine=js&search=${encoded}&limit=1" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null
}

ensure_speedtest_cli() {
    if command -v speedtest >/dev/null 2>&1 && speedtest --version 2>/dev/null | grep -qi ookla; then
        return 0
    fi
    echo -e "${BLUE}Installing official Ookla Speedtest CLI...${NC}"
    if command -v apt >/dev/null 2>&1; then
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash >/dev/null 2>&1
        apt install -y speedtest >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash >/dev/null 2>&1
        yum install -y speedtest >/dev/null 2>&1
    fi
    command -v speedtest >/dev/null 2>&1
}

run_bench() {
    banner
    echo -e "${YELLOW}${BOLD}Server Benchmark${NC}"
    echo ""

    if command -v apt >/dev/null 2>&1; then
        apt install -y jq bc >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq bc >/dev/null 2>&1
    fi

    local DIVIDER="----------------------------------------------------------------------"

    echo "$DIVIDER"
    printf " %-20s: %s\n" "CPU Model" "$(bench_cpu_model)"
    printf " %-20s: %s\n" "CPU Cores" "$(bench_cpu_cores)"
    printf " %-20s: %s\n" "CPU Cache" "$(bench_cpu_cache)"
    printf " %-20s: %s\n" "AES-NI" "$(bench_aesni)"
    printf " %-20s: %s\n" "VM-x/AMD-V" "$(bench_virt_support)"
    printf " %-20s: %s\n" "Total Disk" "$(bench_disk_info)"
    printf " %-20s: %s\n" "Total RAM" "$(bench_ram_info)"
    printf " %-20s: %s\n" "Total Swap" "$(bench_swap_info)"
    printf " %-20s: %s\n" "System Uptime" "$(bench_uptime)"
    printf " %-20s: %s\n" "Load Average" "$(bench_load_avg)"
    printf " %-20s: %s\n" "OS" "$(bench_os_info)"
    printf " %-20s: %s\n" "Arch" "$(uname -m) ($(getconf LONG_BIT) Bit)"
    printf " %-20s: %s\n" "Kernel" "$(uname -r)"
    printf " %-20s: %s\n" "TCP Congestion Ctrl" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf " %-20s: %s\n" "Virtualization" "$(bench_virt_type)"

    local IPV4_STATUS IPV6_STATUS
    IPV4_STATUS=$(bench_ip_online -4)
    IPV6_STATUS=$(bench_ip_online -6)
    printf " %-20s: %s / %s\n" "IPv4/IPv6" "$IPV4_STATUS" "$IPV6_STATUS"

    local IPINFO
    IPINFO=$(curl -s -4 -m 5 "http://ip-api.com/json/?fields=org,city,regionName,country,as")
    local ORG CITY REGION COUNTRY
    ORG=$(echo "$IPINFO" | jq -r '.as // .org // "Unknown"' 2>/dev/null)
    CITY=$(echo "$IPINFO" | jq -r '.city // "Unknown"' 2>/dev/null)
    REGION=$(echo "$IPINFO" | jq -r '.regionName // "Unknown"' 2>/dev/null)
    COUNTRY=$(echo "$IPINFO" | jq -r '.country // "Unknown"' 2>/dev/null)
    printf " %-20s: %s\n" "Organization" "${ORG:-Unknown}"
    printf " %-20s: %s / %s\n" "Location" "${CITY:-Unknown}" "${COUNTRY:-Unknown}"
    printf " %-20s: %s\n" "Region" "${REGION:-Unknown}"
    echo "$DIVIDER"

    echo -e "${CYAN}Running I/O speed test (3 runs)...${NC}"
    local IO1 IO2 IO3 IOAVG
    IO1=$(bench_io_run)
    IO2=$(bench_io_run)
    IO3=$(bench_io_run)
    printf " %-20s: %s MB/s\n" "I/O Speed(1st run)" "$IO1"
    printf " %-20s: %s MB/s\n" "I/O Speed(2nd run)" "$IO2"
    printf " %-20s: %s MB/s\n" "I/O Speed(3rd run)" "$IO3"
    IOAVG=$(awk -v a="$IO1" -v b="$IO2" -v c="$IO3" 'BEGIN{printf "%.1f", (a+b+c)/3}')
    printf " %-20s: %s MB/s\n" "I/O Speed(average)" "$IOAVG"
    echo "$DIVIDER"

    if ensure_speedtest_cli; then
        echo -e "${CYAN}Running network speed test (Ookla, this may take a few minutes)...${NC}"
        printf " %-26s%-16s%-18s%-10s\n" "Node Name" "Upload" "Download" "Latency"
        bench_speedtest_row "Speedtest.net (nearest)" ""
        local CITIES=("New York" "London" "Frankfurt" "Singapore" "Tokyo" "Dubai")
        local CITY
        for CITY in "${CITIES[@]}"; do
            local SID
            SID=$(bench_find_server_id "$CITY")
            if [ -n "$SID" ]; then
                bench_speedtest_row "$CITY" "-s $SID"
            fi
        done
    else
        echo -e "${RED}Could not install the Ookla Speedtest CLI, skipping network test.${NC}"
    fi
    echo "$DIVIDER"

    pause
}

apply_kernel_optimizations() {
    modprobe tcp_bbr >/dev/null 2>&1
    sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=8388608 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 87380 8388608" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 65536 8388608" >/dev/null 2>&1
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-anonymous-tunnel-perf.conf <<EOF
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.ipv4.tcp_rmem=4096 87380 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-anonymous-tunnel-perf.conf >/dev/null 2>&1
    if ! grep -q "anonymous-tunnel" /etc/security/limits.conf 2>/dev/null; then
        {
            echo "* soft nofile 1048576 # anonymous-tunnel"
            echo "* hard nofile 1048576 # anonymous-tunnel"
        } >> /etc/security/limits.conf
    fi
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null
}

optimize_kernel() {
    banner
    echo -e "${YELLOW}${BOLD}Kernel / Network Optimization${NC}"
    echo -e "${CYAN}This applies system-wide tuning: BBR congestion control, larger${NC}"
    echo -e "${CYAN}socket buffers (8MB), and higher file descriptor limits.${NC}"
    read -p "$(echo -e ${YELLOW}Apply now? - y or n: ${NC})" OK
    if [ "$OK" != "y" ]; then
        return
    fi
    CURRENT_CC=$(apply_kernel_optimizations)
    if [ "$CURRENT_CC" == "bbr" ]; then
        echo -e "${GREEN}Applied successfully. Congestion control: bbr${NC}"
    else
        echo -e "${YELLOW}Buffers and limits applied. BBR could not be enabled on this kernel (fell back to: $CURRENT_CC).${NC}"
    fi
    pause
}

choose_transport() {
    echo -e "${CYAN}Choose transport:${NC}"
    echo "  1) TCP (default, recommended)"
    echo "  2) TCP Mux"
    echo "  3) TCP + Stealth (obfuscated)"
    echo "  4) TCP + PCK (anti-throttle shaping)"
    echo "  5) WS"
    echo "  6) WS Mux"
    echo "  7) WSS"
    echo "  8) WSS Mux"
    echo "  9) UDP + FEC"
    echo "  0) Back / Cancel"
    read -p "$(echo -e ${CYAN}Select [1]: ${NC})" TCH
    case $TCH in
        0) return 1 ;;
        2) TRANSPORT=tcp_mux ;;
        3) TRANSPORT=tcp_stealth ;;
        4) TRANSPORT=tcp_pck ;;
        5) TRANSPORT=ws ;;
        6) TRANSPORT=ws_mux ;;
        7) TRANSPORT=wss ;;
        8) TRANSPORT=wss_mux ;;
        9) TRANSPORT=udp_fec ;;
        *) TRANSPORT=tcp ;;
    esac
    return 0
}

create_watchdog() {
    local NAME=$1
    local WSVC="$SERVICE_DIR/${APP_NAME}-watch-$NAME.service"
    local WTIMER="$SERVICE_DIR/${APP_NAME}-watch-$NAME.timer"
    cat > "$WSVC" <<EOF
[Unit]
Description=Anonymous Tunnel Auto Refresh - $NAME

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'systemctl is-active --quiet ${APP_NAME}-$NAME || systemctl restart ${APP_NAME}-$NAME'
EOF
    cat > "$WTIMER" <<EOF
[Unit]
Description=Anonymous Tunnel Auto Refresh Timer - $NAME

[Timer]
OnBootSec=30
OnUnitActiveSec=30
Unit=${APP_NAME}-watch-$NAME.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${APP_NAME}-watch-$NAME.timer" >/dev/null 2>&1
}

remove_watchdog() {
    local NAME=$1
    systemctl disable --now "${APP_NAME}-watch-$NAME.timer" >/dev/null 2>&1
    rm -f "$SERVICE_DIR/${APP_NAME}-watch-$NAME.service"
    rm -f "$SERVICE_DIR/${APP_NAME}-watch-$NAME.timer"
    systemctl daemon-reload
}

watchdog_active() {
    local NAME=$1
    systemctl is-active --quiet "${APP_NAME}-watch-$NAME.timer" 2>/dev/null
}

tg_config_get() {
    local key=$1
    get_json_value "$CONFIG_DIR/telegram.json" "$key"
}

tg_api_call() {
    local method=$1
    local payload=$2
    local token
    token=$(tg_config_get bot_token)
    local proxy
    proxy=$(tg_config_get proxy)
    local PROXY_ARGS=()
    if [ -n "$proxy" ]; then
        PROXY_ARGS=(--proxy "$proxy")
    fi
    curl -s -m 20 "${PROXY_ARGS[@]}" -X POST "https://api.telegram.org/bot${token}/${method}" \
        -H "Content-Type: application/json" \
        -d "$payload"
}

tg_send() {
    local text=$1
    local keyboard=$2
    local admin
    admin=$(tg_config_get admin_id)
    local payload
    if [ -n "$keyboard" ]; then
        payload=$(jq -n --arg cid "$admin" --arg txt "$text" --argjson kb "$keyboard" \
            '{chat_id: ($cid|tonumber), text: $txt, parse_mode: "HTML", reply_markup: {inline_keyboard: $kb}}')
    else
        payload=$(jq -n --arg cid "$admin" --arg txt "$text" \
            '{chat_id: ($cid|tonumber), text: $txt, parse_mode: "HTML"}')
    fi
    tg_api_call sendMessage "$payload" >/dev/null
}

tg_edit() {
    local chat_id=$1
    local message_id=$2
    local text=$3
    local keyboard=$4
    local payload
    if [ -n "$keyboard" ]; then
        payload=$(jq -n --arg cid "$chat_id" --arg mid "$message_id" --arg txt "$text" --argjson kb "$keyboard" \
            '{chat_id: ($cid|tonumber), message_id: ($mid|tonumber), text: $txt, parse_mode: "HTML", reply_markup: {inline_keyboard: $kb}}')
    else
        payload=$(jq -n --arg cid "$chat_id" --arg mid "$message_id" --arg txt "$text" \
            '{chat_id: ($cid|tonumber), message_id: ($mid|tonumber), text: $txt, parse_mode: "HTML"}')
    fi
    tg_api_call editMessageText "$payload" >/dev/null
}

tg_answer_callback() {
    local callback_id=$1
    local text=$2
    local payload
    payload=$(jq -n --arg cbid "$callback_id" --arg txt "$text" '{callback_query_id: $cbid, text: $txt}')
    tg_api_call answerCallbackQuery "$payload" >/dev/null
}

tg_btn() {
    local text=$1
    local data=$2
    jq -nc --arg t "$text" --arg d "$data" '{text: $t, callback_data: $d}'
}

tg_row() {
    local IFS=,
    echo "[$*]"
}

tg_kb() {
    local IFS=,
    echo "[$*]"
}

tg_status_emoji() {
    local name=$1
    if systemctl is-active --quiet "${APP_NAME}-$name"; then
        echo "🟢"
    else
        echo "🔴"
    fi
}

tg_kb_main() {
    local r1 r2 r3 r4
    r1=$(tg_row "$(tg_btn "🖥 Manage Tunnels" "m:tunnels")")
    r2=$(tg_row "$(tg_btn "➕ Create Server Tunnel" "cs:start")" "$(tg_btn "➕ Create Client Tunnel" "cc:start")")
    r3=$(tg_row "$(tg_btn "📊 Traffic Summary" "stats:summary")" "$(tg_btn "🔄 Update Core" "core:update")")
    r4=$(tg_row "$(tg_btn "⚙️ Optimize" "opt:confirm")" "$(tg_btn "🔍 Diagnostics" "diag:start")")
    tg_kb "$r1" "$r2" "$r3" "$r4"
}

tg_kb_tunnels() {
    local TUNNELS
    TUNNELS=($(list_tunnels))
    local rows=()
    local T
    for T in "${TUNNELS[@]}"; do
        local EMOJI
        EMOJI=$(tg_status_emoji "$T")
        rows+=("$(tg_row "$(tg_btn "$EMOJI $T" "t:$T:menu")")")
    done
    rows+=("$(tg_row "$(tg_btn "⬅️ Back" "m:main")")")
    tg_kb "${rows[@]}"
}

tg_kb_tunnel_menu() {
    local T=$1
    local WD_LABEL="🔕 Enable Auto-Refresh"
    if watchdog_active "$T"; then
        WD_LABEL="🔔 Disable Auto-Refresh"
    fi
    local r1 r2 r3 r4 r5 r6 r7
    r1=$(tg_row "$(tg_btn "▶️ Start" "t:$T:start")" "$(tg_btn "⏹ Stop" "t:$T:stop")" "$(tg_btn "🔄 Restart" "t:$T:restart")")
    r2=$(tg_row "$(tg_btn "📈 Status" "t:$T:status")" "$(tg_btn "📜 Logs" "t:$T:logs")")
    r3=$(tg_row "$(tg_btn "$WD_LABEL" "t:$T:watchdog")")
    r4=$(tg_row "$(tg_btn "📶 Traffic Limit" "t:$T:setlimit")" "$(tg_btn "🚀 Bandwidth Limit" "t:$T:setbw")")
    r5=$(tg_row "$(tg_btn "♻️ Reset Traffic" "t:$T:resetconfirm")" "$(tg_btn "🔧 Edit" "t:$T:edit")")
    r6=$(tg_row "$(tg_btn "🗑 Delete" "t:$T:delconfirm")")
    r7=$(tg_row "$(tg_btn "⬅️ Back" "m:tunnels")")
    tg_kb "$r1" "$r2" "$r3" "$r4" "$r5" "$r6" "$r7"
}

tg_kb_confirm_delete() {
    local T=$1
    local r1 r2
    r1=$(tg_row "$(tg_btn "✅ Yes, delete it" "t:$T:deldo")")
    r2=$(tg_row "$(tg_btn "❌ Cancel" "t:$T:menu")")
    tg_kb "$r1" "$r2"
}

tg_tunnel_info_text() {
    local T=$1
    local CFG="$CONFIG_DIR/$T.json"
    local MODE
    MODE=$(get_json_value "$CFG" mode)
    local TRANSPORT
    TRANSPORT=$(get_json_value "$CFG" transport)
    TRANSPORT=${TRANSPORT:-tcp_mux}
    local STATC="🔴 Stopped"
    if systemctl is-active --quiet "${APP_NAME}-$T"; then
        STATC="🟢 Running"
    fi
    local TRX TTX TUSED
    TRX=$(get_json_number "$CONFIG_DIR/$T.stats.json" rx); TRX=${TRX:-0}
    TTX=$(get_json_number "$CONFIG_DIR/$T.stats.json" tx); TTX=${TTX:-0}
    TUSED=$((TRX + TTX))
    local WD="disabled"
    if watchdog_active "$T"; then
        WD="enabled"
    fi
    printf '<b>%s</b>\nMode: %s\nTransport: %s\nStatus: %s\nTraffic used: %s\nAuto-Refresh: %s' \
        "$T" "$MODE" "$TRANSPORT" "$STATC" "$(human_bytes $TUSED)" "$WD"
}

tg_handle_callback() {
    local chat_id=$1
    local message_id=$2
    local callback_id=$3
    local data=$4

    tg_answer_callback "$callback_id" ""

    if tg_handle_callback_phase2 "$chat_id" "$message_id" "$data"; then
        return
    fi

    case "$data" in
        m:main)
            tg_edit "$chat_id" "$message_id" "<b>Anonymous Tunnel Manager</b>" "$(tg_kb_main)"
            ;;
        m:tunnels)
            local TCOUNT
            TCOUNT=$(list_tunnels | wc -l)
            if [ "$TCOUNT" -eq 0 ]; then
                tg_edit "$chat_id" "$message_id" "No tunnels found yet." "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "m:main")")")"
            else
                tg_edit "$chat_id" "$message_id" "<b>Your Tunnels</b>" "$(tg_kb_tunnels)"
            fi
            ;;
        stats:summary)
            local TOTAL_RX=0 TOTAL_TX=0
            local T
            for T in $(list_tunnels); do
                local STATS="$CONFIG_DIR/$T.stats.json"
                if [ -f "$STATS" ]; then
                    local RX TX
                    RX=$(get_json_number "$STATS" rx); RX=${RX:-0}
                    TX=$(get_json_number "$STATS" tx); TX=${TX:-0}
                    TOTAL_RX=$((TOTAL_RX + RX))
                    TOTAL_TX=$((TOTAL_TX + TX))
                fi
            done
            local TOTAL=$((TOTAL_RX + TOTAL_TX))
            local TXT
            TXT=$(printf '<b>Traffic Summary</b>\nDownload: %s\nUpload: %s\nTotal: %s' \
                "$(human_bytes $TOTAL_RX)" "$(human_bytes $TOTAL_TX)" "$(human_bytes $TOTAL)")
            tg_edit "$chat_id" "$message_id" "$TXT" "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "m:main")")")"
            ;;
        core:update)
            tg_edit "$chat_id" "$message_id" "🔄 Updating core from GitHub Releases..." ""
            if download_core_silent; then
                for T in $(list_tunnels); do
                    systemctl restart "${APP_NAME}-$T" >/dev/null 2>&1
                done
                tg_edit "$chat_id" "$message_id" "✅ Core updated successfully and all tunnels restarted." "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "m:main")")")"
            else
                tg_edit "$chat_id" "$message_id" "❌ Core update failed. Check server network connectivity." "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "m:main")")")"
            fi
            ;;
        t:*)
            local T ACTION
            T=$(echo "$data" | cut -d: -f2)
            ACTION=$(echo "$data" | cut -d: -f3)
            case "$ACTION" in
                menu)
                    tg_edit "$chat_id" "$message_id" "$(tg_tunnel_info_text "$T")" "$(tg_kb_tunnel_menu "$T")"
                    ;;
                start)
                    systemctl start "${APP_NAME}-$T" >/dev/null 2>&1
                    sleep 1
                    tg_edit "$chat_id" "$message_id" "$(tg_tunnel_info_text "$T")" "$(tg_kb_tunnel_menu "$T")"
                    ;;
                stop)
                    systemctl stop "${APP_NAME}-$T" >/dev/null 2>&1
                    sleep 1
                    tg_edit "$chat_id" "$message_id" "$(tg_tunnel_info_text "$T")" "$(tg_kb_tunnel_menu "$T")"
                    ;;
                restart)
                    systemctl restart "${APP_NAME}-$T" >/dev/null 2>&1
                    sleep 1
                    tg_edit "$chat_id" "$message_id" "$(tg_tunnel_info_text "$T")" "$(tg_kb_tunnel_menu "$T")"
                    ;;
                status)
                    local STXT
                    STXT=$(systemctl status "${APP_NAME}-$T" --no-pager 2>&1 | head -n 15)
                    tg_edit "$chat_id" "$message_id" "<pre>$(tg_html_escape "$STXT")</pre>" "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "t:$T:menu")")")"
                    ;;
                logs)
                    local LTXT
                    LTXT=$(journalctl -u "${APP_NAME}-$T" -n 25 --no-pager 2>&1)
                    tg_edit "$chat_id" "$message_id" "<pre>$(tg_html_escape "$LTXT")</pre>" "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "t:$T:menu")")")"
                    ;;
                watchdog)
                    if watchdog_active "$T"; then
                        remove_watchdog "$T"
                    else
                        create_watchdog "$T"
                    fi
                    tg_edit "$chat_id" "$message_id" "$(tg_tunnel_info_text "$T")" "$(tg_kb_tunnel_menu "$T")"
                    ;;
                delconfirm)
                    tg_edit "$chat_id" "$message_id" "⚠️ Delete tunnel <b>$T</b>? This cannot be undone." "$(tg_kb_confirm_delete "$T")"
                    ;;
                deldo)
                    systemctl stop "${APP_NAME}-$T" >/dev/null 2>&1
                    systemctl disable "${APP_NAME}-$T" >/dev/null 2>&1
                    rm -f "$SERVICE_DIR/${APP_NAME}-$T.service"
                    rm -f "$CONFIG_DIR/$T.json"
                    rm -f "$CONFIG_DIR/$T.crt" "$CONFIG_DIR/$T.key"
                    rm -f "$CONFIG_DIR/$T.stats.json"
                    remove_watchdog "$T"
                    remove_limit_watcher "$T"
                    systemctl daemon-reload
                    tg_edit "$chat_id" "$message_id" "🗑 Tunnel <b>$T</b> deleted." "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "m:tunnels")")")"
                    ;;
                *)
                    tg_handle_callback_tunnel_phase2 "$chat_id" "$message_id" "$T" "$ACTION"
                    ;;
            esac
            ;;
    esac
}

tg_html_escape() {
    local s=$1
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    echo "$s"
}

tg_process_update() {
    local update=$1
    local admin
    admin=$(tg_config_get admin_id)

    local callback_data callback_id callback_chat callback_msgid
    callback_data=$(echo "$update" | jq -r '.callback_query.data // empty')
    if [ -n "$callback_data" ]; then
        callback_id=$(echo "$update" | jq -r '.callback_query.id')
        callback_chat=$(echo "$update" | jq -r '.callback_query.message.chat.id')
        callback_msgid=$(echo "$update" | jq -r '.callback_query.message.message_id')
        if [ "$callback_chat" != "$admin" ]; then
            tg_answer_callback "$callback_id" "Not authorized"
            return
        fi
        tg_handle_callback "$callback_chat" "$callback_msgid" "$callback_id" "$callback_data"
        return
    fi

    local msg_text msg_chat
    msg_text=$(echo "$update" | jq -r '.message.text // empty')
    msg_chat=$(echo "$update" | jq -r '.message.chat.id // empty')
    if [ -n "$msg_chat" ]; then
        if [ "$msg_chat" != "$admin" ]; then
            return
        fi
        if [ "$msg_text" == "/start" ] || [ "$msg_text" == "/menu" ]; then
            tg_state_clear
            tg_send "<b>Anonymous Tunnel Manager</b>" "$(tg_kb_main)"
            return
        fi
        local step
        step=$(tg_state_get step)
        if [ -n "$step" ]; then
            tg_handle_state_text "$msg_chat" "$step" "$msg_text"
        fi
    fi
}

run_telegram_bot() {
    local token
    token=$(tg_config_get bot_token)
    if [ -z "$token" ]; then
        echo "Telegram bot is not configured."
        exit 1
    fi
    local proxy
    proxy=$(tg_config_get proxy)
    local PROXY_ARGS=()
    if [ -n "$proxy" ]; then
        PROXY_ARGS=(--proxy "$proxy")
    fi
    tg_send "✅ Telegram bot is now active." "$(tg_kb_main)"
    local OFFSET=0
    while true; do
        local RESPONSE
        RESPONSE=$(curl -s -m 40 "${PROXY_ARGS[@]}" "https://api.telegram.org/bot${token}/getUpdates?offset=${OFFSET}&timeout=30")
        if [ -z "$RESPONSE" ]; then
            sleep 3
            continue
        fi
        local OK
        OK=$(echo "$RESPONSE" | jq -r '.ok // false' 2>/dev/null)
        if [ "$OK" != "true" ]; then
            sleep 5
            continue
        fi
        local UPDATES=()
        mapfile -t UPDATES < <(echo "$RESPONSE" | jq -c '.result[]' 2>/dev/null)
        local U
        for U in "${UPDATES[@]}"; do
            [ -z "$U" ] && continue
            local UPID
            UPID=$(echo "$U" | jq -r '.update_id')
            OFFSET=$((UPID + 1))
            tg_process_update "$U"
        done
    done
}

tg_check_notify() {
    local admin
    admin=$(tg_config_get admin_id)
    if [ -z "$admin" ]; then
        return
    fi
    local STATE_FILE="$CONFIG_DIR/.tg_notify_state"
    touch "$STATE_FILE"
    local T
    for T in $(list_tunnels); do
        local CUR="inactive"
        if systemctl is-active --quiet "${APP_NAME}-$T"; then
            CUR="active"
        fi
        local PREV
        PREV=$(grep "^$T:" "$STATE_FILE" 2>/dev/null | cut -d: -f2)
        if [ "$PREV" != "$CUR" ]; then
            if [ "$CUR" == "inactive" ] && [ -n "$PREV" ]; then
                tg_send "🔴 Tunnel <b>$T</b> went down." ""
            elif [ "$CUR" == "active" ] && [ "$PREV" == "inactive" ]; then
                tg_send "🟢 Tunnel <b>$T</b> is back up." ""
            fi
            grep -v "^$T:" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null
            mv "$STATE_FILE.tmp" "$STATE_FILE"
            echo "$T:$CUR" >> "$STATE_FILE"
        fi
    done
}

tg_state_set() {
    local key=$1
    local val=$2
    local cur
    cur=$(cat "$CONFIG_DIR/.tg_state.json" 2>/dev/null)
    if [ -z "$cur" ]; then
        cur="{}"
    fi
    echo "$cur" | jq --arg k "$key" --arg v "$val" '.[$k] = $v' > "$CONFIG_DIR/.tg_state.json.tmp" 2>/dev/null
    mv "$CONFIG_DIR/.tg_state.json.tmp" "$CONFIG_DIR/.tg_state.json"
}

tg_state_get() {
    local key=$1
    jq -r --arg k "$key" '.[$k] // empty' "$CONFIG_DIR/.tg_state.json" 2>/dev/null
}

tg_state_clear() {
    rm -f "$CONFIG_DIR/.tg_state.json"
}

tg_transport_name() {
    case "$1" in
        1) echo "tcp" ;;
        2) echo "tcp_mux" ;;
        3) echo "tcp_stealth" ;;
        4) echo "tcp_pck" ;;
        5) echo "ws" ;;
        6) echo "ws_mux" ;;
        7) echo "wss" ;;
        8) echo "wss_mux" ;;
        9) echo "udp_fec" ;;
        *) echo "tcp" ;;
    esac
}

tg_kb_transport() {
    local prefix=$1
    local r1 r2 r3 r4 r5 r6
    r1=$(tg_row "$(tg_btn "TCP (default)" "$prefix:1")" "$(tg_btn "TCP Mux" "$prefix:2")")
    r2=$(tg_row "$(tg_btn "TCP+Stealth" "$prefix:3")" "$(tg_btn "TCP+PCK" "$prefix:4")")
    r3=$(tg_row "$(tg_btn "WS" "$prefix:5")" "$(tg_btn "WS Mux" "$prefix:6")")
    r4=$(tg_row "$(tg_btn "WSS" "$prefix:7")" "$(tg_btn "WSS Mux" "$prefix:8")")
    r5=$(tg_row "$(tg_btn "UDP+FEC" "$prefix:9")")
    r6=$(tg_row "$(tg_btn "❌ Cancel" "m:main")")
    tg_kb "$r1" "$r2" "$r3" "$r4" "$r5" "$r6"
}

tg_build_services_json() {
    local mode=$1
    local ports=$2
    local SERVICES="{"
    local IFS=','
    local PARR=($ports)
    local FIRST=1
    local P
    for P in "${PARR[@]}"; do
        P=$(echo "$P" | xargs)
        [ -z "$P" ] && continue
        if [ "$FIRST" -eq 0 ]; then
            SERVICES="$SERVICES,"
        fi
        if [ "$mode" == "server" ]; then
            SERVICES="$SERVICES\"$P\":\"0.0.0.0:$P\""
        else
            SERVICES="$SERVICES\"$P\":\"127.0.0.1:$P\""
        fi
        FIRST=0
    done
    SERVICES="$SERVICES}"
    echo "$SERVICES"
}

tg_finalize_create_server() {
    local NAME PORT PORTS TOKEN TRANSPORT
    NAME=$(tg_state_get name)
    PORT=$(tg_state_get port)
    [ "$PORT" == "-" ] || [ -z "$PORT" ] && PORT=2333
    PORTS=$(tg_state_get ports)
    TOKEN=$(tg_state_get token)
    if [ "$TOKEN" == "-" ] || [ -z "$TOKEN" ]; then
        TOKEN=$(generate_token)
    fi
    TRANSPORT=$(tg_state_get transport)

    local CERT_JSON=""
    if [ "$TRANSPORT" == "wss" ] || [ "$TRANSPORT" == "wss_mux" ]; then
        local CERTF="$CONFIG_DIR/$NAME.crt"
        local KEYF="$CONFIG_DIR/$NAME.key"
        openssl req -x509 -newkey rsa:2048 -keyout "$KEYF" -out "$CERTF" -days 3650 -nodes -subj "/CN=anonymous-tunnel" >/dev/null 2>&1
        CERT_JSON=",
  \"cert\": \"$CERTF\",
  \"key\": \"$KEYF\""
    fi

    local SERVICES
    SERVICES=$(tg_build_services_json server "$PORTS")

    cat > "$CONFIG_DIR/$NAME.json" <<EOF
{
  "mode": "server",
  "bind_addr": "0.0.0.0:$PORT",
  "token": "$TOKEN",
  "transport": "$TRANSPORT"$CERT_JSON,
  "services": $SERVICES
}
EOF
    create_service "$NAME" "server"
    create_watchdog "$NAME"
    tg_state_clear
    printf 'Server tunnel <b>%s</b> created and started.\nToken: <code>%s</code>' "$NAME" "$TOKEN"
}

tg_finalize_create_client() {
    local NAME HOST PORT PORTS TOKEN TRANSPORT
    NAME=$(tg_state_get name)
    HOST=$(tg_state_get host)
    PORT=$(tg_state_get port)
    [ "$PORT" == "-" ] || [ -z "$PORT" ] && PORT=2333
    PORTS=$(tg_state_get ports)
    TOKEN=$(tg_state_get token)
    TRANSPORT=$(tg_state_get transport)

    local SERVICES
    SERVICES=$(tg_build_services_json client "$PORTS")

    cat > "$CONFIG_DIR/$NAME.json" <<EOF
{
  "mode": "client",
  "server_addr": "$HOST:$PORT",
  "token": "$TOKEN",
  "transport": "$TRANSPORT",
  "services": $SERVICES
}
EOF
    create_service "$NAME" "client"
    create_watchdog "$NAME"
    tg_state_clear
    printf 'Client tunnel <b>%s</b> created and started.' "$NAME"
}

tg_handle_state_text() {
    local chat_id=$1
    local step=$2
    local text=$3

    case "$step" in
        cs_name)
            if [ -z "$text" ] || [ -f "$CONFIG_DIR/$text.json" ]; then
                tg_send "That name is empty or already used. Send a different name:" ""
                return
            fi
            tg_state_set name "$text"
            tg_state_set step cs_port
            tg_send "Send the control port (or - for default 2333):" ""
            ;;
        cs_port)
            tg_state_set port "$text"
            tg_state_set step cs_ports
            tg_send "Send public ports to expose, comma separated (e.g. 443,8080):" ""
            ;;
        cs_ports)
            if [ -z "$text" ]; then
                tg_send "Send at least one port:" ""
                return
            fi
            tg_state_set ports "$text"
            tg_state_set step cs_token
            tg_send "Send a token/password (or - for a random one):" ""
            ;;
        cs_token)
            tg_state_set token "$text"
            tg_state_set step ""
            tg_send "Choose a transport:" "$(tg_kb_transport cst)"
            ;;
        cc_name)
            if [ -z "$text" ] || [ -f "$CONFIG_DIR/$text.json" ]; then
                tg_send "That name is empty or already used. Send a different name:" ""
                return
            fi
            tg_state_set name "$text"
            tg_state_set step cc_host
            tg_send "Send the Iran server IP address:" ""
            ;;
        cc_host)
            if [ -z "$text" ]; then
                tg_send "Send a valid IP or host:" ""
                return
            fi
            tg_state_set host "$text"
            tg_state_set step cc_port
            tg_send "Send the server control port (or - for default 2333):" ""
            ;;
        cc_port)
            tg_state_set port "$text"
            tg_state_set step cc_ports
            tg_send "Send ports to forward, comma separated (e.g. 443,8080):" ""
            ;;
        cc_ports)
            if [ -z "$text" ]; then
                tg_send "Send at least one port:" ""
                return
            fi
            tg_state_set ports "$text"
            tg_state_set step cc_token
            tg_send "Send the token/password used on the server:" ""
            ;;
        cc_token)
            if [ -z "$text" ]; then
                tg_send "Send the token:" ""
                return
            fi
            tg_state_set token "$text"
            tg_state_set step ""
            tg_send "Choose a transport:" "$(tg_kb_transport cct)"
            ;;
        setlimit)
            if ! [[ "$text" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                tg_send "Invalid number, send a number in GB (0 = unlimited):" ""
                return
            fi
            local T
            T=$(tg_state_get tunnel)
            local CFG="$CONFIG_DIR/$T.json"
            if grep -q '"traffic_limit_gb"' "$CFG"; then
                sed -i -E "s/\"traffic_limit_gb\": *[0-9]+(\.[0-9]+)?/\"traffic_limit_gb\": $text/" "$CFG"
            else
                sed -i "s/\"token\": \"\([^\"]*\)\"/\"token\": \"\1\",\n  \"traffic_limit_gb\": $text/" "$CFG"
            fi
            create_limit_watcher "$T"
            tg_state_clear
            tg_send "$(tg_tunnel_info_text "$T")" "$(tg_kb_tunnel_menu "$T")"
            ;;
        setbw)
            if ! [[ "$text" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                tg_send "Invalid number, send a number in Mbps (0 = unlimited):" ""
                return
            fi
            local T
            T=$(tg_state_get tunnel)
            local CFG="$CONFIG_DIR/$T.json"
            if grep -q '"bandwidth_limit_mbps"' "$CFG"; then
                sed -i -E "s/\"bandwidth_limit_mbps\": *[0-9]+(\.[0-9]+)?/\"bandwidth_limit_mbps\": $text/" "$CFG"
            else
                sed -i "s/\"token\": \"\([^\"]*\)\"/\"token\": \"\1\",\n  \"bandwidth_limit_mbps\": $text/" "$CFG"
            fi
            systemctl restart "${APP_NAME}-$T" >/dev/null 2>&1
            tg_state_clear
            tg_send "Bandwidth limit updated and tunnel restarted." "$(tg_kb_tunnel_menu "$T")"
            ;;
        edit_port)
            tg_state_set eport "$text"
            tg_state_set step edit_ports
            tg_send "Send public ports, comma separated (or - to keep current):" ""
            ;;
        edit_host)
            tg_state_set ehost "$text"
            tg_state_set step edit_ports
            tg_send "Send ports to forward, comma separated (or - to keep current):" ""
            ;;
        edit_ports)
            tg_state_set eports "$text"
            tg_finalize_edit
            ;;
        diag_custom_host)
            tg_state_set dhost "$text"
            tg_state_set step diag_custom_port
            tg_send "Send the port to test:" ""
            ;;
        diag_custom_port)
            local DH
            DH=$(tg_state_get dhost)
            tg_state_clear
            tg_run_diagnostics "$chat_id" "$DH" "$text"
            ;;
        *)
            ;;
    esac
}

tg_finalize_edit() {
    local T MODE
    T=$(tg_state_get ename)
    MODE=$(tg_state_get emode)
    local CFG="$CONFIG_DIR/$T.json"
    local TOKEN
    TOKEN=$(get_json_value "$CFG" token)
    local TRANSPORT
    TRANSPORT=$(tg_state_get etransport)
    local PORT PORTS
    PORT=$(tg_state_get eport)
    PORTS=$(tg_state_get eports)

    if [ "$MODE" == "server" ]; then
        local OLDBIND OLDPORTS
        OLDBIND=$(get_json_value "$CFG" bind_addr)
        OLDPORTS=$(grep -oP '"\d+"\s*:\s*"0\.0\.0\.0:\K\d+' "$CFG" | paste -sd, -)
        if [ "$PORT" == "-" ] || [ -z "$PORT" ]; then
            PORT=${OLDBIND##*:}
        fi
        if [ "$PORTS" == "-" ] || [ -z "$PORTS" ]; then
            PORTS=$OLDPORTS
        fi
        local CERT_JSON=""
        if [ "$TRANSPORT" == "wss" ] || [ "$TRANSPORT" == "wss_mux" ]; then
            local CERTF="$CONFIG_DIR/$T.crt"
            local KEYF="$CONFIG_DIR/$T.key"
            if [ ! -f "$CERTF" ]; then
                openssl req -x509 -newkey rsa:2048 -keyout "$KEYF" -out "$CERTF" -days 3650 -nodes -subj "/CN=anonymous-tunnel" >/dev/null 2>&1
            fi
            CERT_JSON=",
  \"cert\": \"$CERTF\",
  \"key\": \"$KEYF\""
        fi
        local SERVICES
        SERVICES=$(tg_build_services_json server "$PORTS")
        cat > "$CFG" <<EOF
{
  "mode": "server",
  "bind_addr": "0.0.0.0:$PORT",
  "token": "$TOKEN",
  "transport": "$TRANSPORT"$CERT_JSON,
  "services": $SERVICES
}
EOF
    else
        local OLDSERVER OLDPORTS
        OLDSERVER=$(get_json_value "$CFG" server_addr)
        OLDPORTS=$(grep -oP '"\d+"\s*:\s*"127\.0\.0\.1:\K\d+' "$CFG" | paste -sd, -)
        local SADDR
        SADDR=$(tg_state_get ehost)
        if [ "$SADDR" == "-" ] || [ -z "$SADDR" ]; then
            SADDR=$OLDSERVER
        fi
        if [ "$PORTS" == "-" ] || [ -z "$PORTS" ]; then
            PORTS=$OLDPORTS
        fi
        local SERVICES
        SERVICES=$(tg_build_services_json client "$PORTS")
        cat > "$CFG" <<EOF
{
  "mode": "client",
  "server_addr": "$SADDR",
  "token": "$TOKEN",
  "transport": "$TRANSPORT",
  "services": $SERVICES
}
EOF
    fi

    systemctl restart "${APP_NAME}-$T" >/dev/null 2>&1
    tg_state_clear
    tg_send "Tunnel <b>$T</b> updated and restarted." "$(tg_kb_tunnel_menu "$T")"
}

tg_run_diagnostics() {
    local chat_id=$1
    local host=$2
    local port=$3

    tg_send "🔍 Running diagnostics on $host:$port ..." ""

    local OUT=""
    local RESULT STATUS DETAIL

    RESULT=$(diag_dns "$host"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    OUT="${OUT}$([ "$STATUS" == "ok" ] && echo "✅" || echo "❌") DNS: $DETAIL
"
    RESULT=$(diag_ipv4 "$host"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    OUT="${OUT}$([ "$STATUS" == "ok" ] && echo "✅" || echo "❌") IPv4: $DETAIL
"
    RESULT=$(diag_ipv6 "$host"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    OUT="${OUT}$([ "$STATUS" == "ok" ] && echo "✅" || echo "❌") IPv6: $DETAIL
"
    RESULT=$(diag_tcp "$host" "$port"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    OUT="${OUT}$([ "$STATUS" == "ok" ] && echo "✅" || echo "❌") TCP: $DETAIL
"
    RESULT=$(diag_udp "$host" "$port"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    OUT="${OUT}$([ "$STATUS" == "ok" ] && echo "✅" || echo "❌") UDP: $DETAIL
"
    RESULT=$(diag_mtu "$host"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    OUT="${OUT}$([ "$STATUS" == "ok" ] && echo "✅" || echo "❌") MTU: $DETAIL
"
    RESULT=$(diag_route "$host"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    OUT="${OUT}$([ "$STATUS" == "ok" ] && echo "✅" || echo "❌") Route: $DETAIL
"
    IFS='|' read -r LOSS AVG <<< "$(diag_ping_stats "$host")"
    if [ -n "$LOSS" ]; then
        OUT="${OUT}$([ "$LOSS" -eq 0 ] && echo "✅" || echo "⚠️") Packet Loss: ${LOSS}%
"
    else
        OUT="${OUT}❌ Packet Loss: no reply
"
    fi
    if [ -n "$AVG" ]; then
        OUT="${OUT}✅ Latency: avg ${AVG}ms
"
    else
        OUT="${OUT}❌ Latency: no reply
"
    fi
    RESULT=$(diag_firewall); DETAIL="${RESULT#*|}"
    OUT="${OUT}ℹ️ Firewall: $DETAIL
"
    RESULT=$(diag_port_accessibility "$host" "$port"); STATUS="${RESULT%%|*}"; DETAIL="${RESULT#*|}"
    OUT="${OUT}$([ "$STATUS" == "ok" ] && echo "✅" || echo "❌") Port Accessibility: $DETAIL
"

    tg_send "<b>Diagnostics: $host:$port</b>
<pre>$(tg_html_escape "$OUT")</pre>" "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "m:main")")")"
}

tg_handle_callback_phase2() {
    local chat_id=$1
    local message_id=$2
    local data=$3

    case "$data" in
        cs:start)
            tg_state_clear
            tg_state_set step cs_name
            tg_edit "$chat_id" "$message_id" "Send a name for this tunnel:" ""
            return 0
            ;;
        cc:start)
            tg_state_clear
            tg_state_set step cc_name
            tg_edit "$chat_id" "$message_id" "Send a name for this tunnel:" ""
            return 0
            ;;
        cst:*)
            local N
            N=$(echo "$data" | cut -d: -f2)
            tg_state_set transport "$(tg_transport_name "$N")"
            local MSG
            MSG=$(tg_finalize_create_server)
            tg_edit "$chat_id" "$message_id" "$MSG" "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "m:tunnels")")")"
            return 0
            ;;
        cct:*)
            local N
            N=$(echo "$data" | cut -d: -f2)
            tg_state_set transport "$(tg_transport_name "$N")"
            local MSG
            MSG=$(tg_finalize_create_client)
            tg_edit "$chat_id" "$message_id" "$MSG" "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "m:tunnels")")")"
            return 0
            ;;
        et:*)
            local N
            N=$(echo "$data" | cut -d: -f2)
            tg_state_set etransport "$(tg_transport_name "$N")"
            local MODE
            MODE=$(tg_state_get emode)
            if [ "$MODE" == "server" ]; then
                tg_state_set step edit_port
                tg_edit "$chat_id" "$message_id" "Send new control port (or - to keep current):" ""
            else
                tg_state_set step edit_host
                tg_edit "$chat_id" "$message_id" "Send new server IP:PORT (or - to keep current):" ""
            fi
            return 0
            ;;
        opt:confirm)
            tg_edit "$chat_id" "$message_id" "This applies system-wide kernel/network tuning (BBR, larger buffers, higher file limits). Apply now?" "$(tg_kb "$(tg_row "$(tg_btn "✅ Apply" "opt:run")" "$(tg_btn "❌ Cancel" "m:main")")")"
            return 0
            ;;
        opt:run)
            tg_edit "$chat_id" "$message_id" "⚙️ Applying optimizations..." ""
            local CC
            CC=$(apply_kernel_optimizations)
            tg_edit "$chat_id" "$message_id" "✅ Applied. Congestion control: $CC" "$(tg_kb "$(tg_row "$(tg_btn "⬅️ Back" "m:main")")")"
            return 0
            ;;
        diag:start)
            local TCOUNT
            TCOUNT=$(list_tunnels | wc -l)
            local rows=()
            local T
            for T in $(list_tunnels); do
                rows+=("$(tg_row "$(tg_btn "$T" "diag:pick:$T")")")
            done
            rows+=("$(tg_row "$(tg_btn "✏️ Custom host" "diag:custom")")")
            rows+=("$(tg_row "$(tg_btn "⬅️ Back" "m:main")")")
            tg_edit "$chat_id" "$message_id" "Pick a tunnel to diagnose, or enter a custom host:" "$(tg_kb "${rows[@]}")"
            return 0
            ;;
        diag:pick:*)
            local T
            T=$(echo "$data" | cut -d: -f3)
            local CFG="$CONFIG_DIR/$T.json"
            local MODE HOST PORT
            MODE=$(get_json_value "$CFG" mode)
            if [ "$MODE" == "client" ]; then
                local SADDR
                SADDR=$(get_json_value "$CFG" server_addr)
                HOST=${SADDR%%:*}
                PORT=${SADDR##*:}
            else
                local BADDR
                BADDR=$(get_json_value "$CFG" bind_addr)
                HOST="127.0.0.1"
                PORT=${BADDR##*:}
            fi
            tg_edit "$chat_id" "$message_id" "Running diagnostics..." ""
            tg_run_diagnostics "$chat_id" "$HOST" "$PORT"
            return 0
            ;;
        diag:custom)
            tg_state_clear
            tg_state_set step diag_custom_host
            tg_edit "$chat_id" "$message_id" "Send the host or IP to test:" ""
            return 0
            ;;
    esac
    return 1
}

tg_handle_callback_tunnel_phase2() {
    local chat_id=$1
    local message_id=$2
    local T=$3
    local ACTION=$4

    case "$ACTION" in
        setlimit)
            tg_state_clear
            tg_state_set step setlimit
            tg_state_set tunnel "$T"
            tg_edit "$chat_id" "$message_id" "Send the traffic limit in GB (0 = unlimited):" ""
            return 0
            ;;
        setbw)
            tg_state_clear
            tg_state_set step setbw
            tg_state_set tunnel "$T"
            tg_edit "$chat_id" "$message_id" "Send the bandwidth limit in Mbps (0 = unlimited):" ""
            return 0
            ;;
        resetconfirm)
            tg_edit "$chat_id" "$message_id" "Reset traffic counter for <b>$T</b>?" "$(tg_kb "$(tg_row "$(tg_btn "✅ Yes" "t:$T:resetdo")")" "$(tg_row "$(tg_btn "❌ Cancel" "t:$T:menu")")")"
            return 0
            ;;
        resetdo)
            printf '{"rx":0,"tx":0,"updated":%s}' "$(date +%s)" > "$CONFIG_DIR/$T.stats.json"
            systemctl restart "${APP_NAME}-$T" >/dev/null 2>&1
            tg_edit "$chat_id" "$message_id" "♻️ Traffic counter reset for <b>$T</b>." "$(tg_kb_tunnel_menu "$T")"
            return 0
            ;;
        edit)
            local MODE
            MODE=$(get_json_value "$CONFIG_DIR/$T.json" mode)
            tg_state_clear
            tg_state_set ename "$T"
            tg_state_set emode "$MODE"
            tg_edit "$chat_id" "$message_id" "Choose a new transport for <b>$T</b>:" "$(tg_kb_transport et)"
            return 0
            ;;
    esac
    return 1
}

create_telegram_service() {
    local SVC="$SERVICE_DIR/${APP_NAME}-bot.service"
    cat > "$SVC" <<EOF
[Unit]
Description=Anonymous Tunnel Telegram Bot
After=network.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$INSTALL_PATH __tg_run
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${APP_NAME}-bot" >/dev/null 2>&1
}

create_telegram_notify_timer() {
    local SVC="$SERVICE_DIR/${APP_NAME}-notify.service"
    local TIMER="$SERVICE_DIR/${APP_NAME}-notify.timer"
    cat > "$SVC" <<EOF
[Unit]
Description=Anonymous Tunnel Down Notification Check

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH __tg_check_notify
EOF
    cat > "$TIMER" <<EOF
[Unit]
Description=Anonymous Tunnel Down Notification Timer

[Timer]
OnBootSec=30
OnUnitActiveSec=30
Unit=${APP_NAME}-notify.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${APP_NAME}-notify.timer" >/dev/null 2>&1
}

telegram_bot_menu() {
    banner
    echo -e "${YELLOW}${BOLD}Telegram Bot${NC}"
    if [ -f "$CONFIG_DIR/telegram.json" ]; then
        local BSTAT="🔴 Not running"
        if systemctl is-active --quiet "${APP_NAME}-bot"; then
            BSTAT="🟢 Running"
        fi
        echo -e "${CYAN}Status: ${GREEN}$BSTAT${NC}"
        echo -e "${CYAN}1. Reconfigure token / admin ID${NC}"
        echo -e "${CYAN}2. Restart bot${NC}"
        echo -e "${CYAN}3. Disable and remove bot${NC}"
        echo -e "${CYAN}0. Back${NC}"
        read -p "$(echo -e ${YELLOW}Select option: ${NC})" OPT
        case $OPT in
            1) setup_telegram_bot ;;
            2) systemctl restart "${APP_NAME}-bot" >/dev/null 2>&1; echo -e "${GREEN}Restarted.${NC}"; pause ;;
            3)
                systemctl disable --now "${APP_NAME}-bot" >/dev/null 2>&1
                systemctl disable --now "${APP_NAME}-notify.timer" >/dev/null 2>&1
                rm -f "$SERVICE_DIR/${APP_NAME}-bot.service"
                rm -f "$SERVICE_DIR/${APP_NAME}-notify.service" "$SERVICE_DIR/${APP_NAME}-notify.timer"
                rm -f "$CONFIG_DIR/telegram.json"
                systemctl daemon-reload
                echo -e "${GREEN}Telegram bot removed.${NC}"
                pause
                ;;
            0) return ;;
            *) echo -e "${RED}Invalid option.${NC}"; pause ;;
        esac
    else
        echo -e "${YELLOW}Not configured yet.${NC}"
        read -p "$(echo -e ${CYAN}Set up the Telegram bot now? - y or n: ${NC})" OK
        if [ "$OK" == "y" ]; then
            setup_telegram_bot
        fi
    fi
}

setup_telegram_bot() {
    banner
    echo -e "${YELLOW}${BOLD}Telegram Bot Setup${NC}"
    if command -v apt >/dev/null 2>&1; then
        apt install -y jq >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq >/dev/null 2>&1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}Failed to install jq, which is required for the bot.${NC}"
        pause
        return
    fi
    read -p "$(echo -e ${CYAN}Enter your bot token from @BotFather: ${NC})" BOTTOKEN
    if [ -z "$BOTTOKEN" ]; then
        echo -e "${RED}Cancelled.${NC}"
        pause
        return
    fi
    read -p "$(echo -e ${CYAN}Enter your numeric Telegram user ID - admin: ${NC})" ADMINID
    if ! [[ "$ADMINID" =~ ^-?[0-9]+$ ]]; then
        echo -e "${RED}Invalid ID, must be numeric.${NC}"
        pause
        return
    fi

    local PROXY_URL=""
    read -p "$(echo -e ${CYAN}Do you need a SOCKS5 proxy to reach Telegram - e.g. this server is in Iran - y or n: ${NC})" NEEDPROXY
    if [ "$NEEDPROXY" == "y" ]; then
        read -p "$(echo -e ${CYAN}Proxy host: ${NC})" PHOST
        read -p "$(echo -e ${CYAN}Proxy port: ${NC})" PPORT
        read -p "$(echo -e ${CYAN}Proxy username - leave empty if none: ${NC})" PUSER
        if [ -n "$PUSER" ]; then
            read -p "$(echo -e ${CYAN}Proxy password: ${NC})" PPASS
            PROXY_URL="socks5h://$PUSER:$PPASS@$PHOST:$PPORT"
        else
            PROXY_URL="socks5h://$PHOST:$PPORT"
        fi
    fi

    cat > "$CONFIG_DIR/telegram.json" <<EOF
{
  "bot_token": "$BOTTOKEN",
  "admin_id": "$ADMINID",
  "proxy": "$PROXY_URL"
}
EOF

    echo -e "${BLUE}Testing connection to Telegram...${NC}"
    local PROXY_ARGS=()
    if [ -n "$PROXY_URL" ]; then
        PROXY_ARGS=(--proxy "$PROXY_URL")
    fi
    local TESTRESULT
    TESTRESULT=$(curl -s -m 15 "${PROXY_ARGS[@]}" "https://api.telegram.org/bot${BOTTOKEN}/getMe")
    if echo "$TESTRESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
        local BOTNAME
        BOTNAME=$(echo "$TESTRESULT" | jq -r '.result.username')
        echo -e "${GREEN}Connected successfully as @$BOTNAME.${NC}"
    else
        echo -e "${RED}Could not reach Telegram with these settings.${NC}"
        echo -e "${YELLOW}Response: $TESTRESULT${NC}"
        echo -e "${YELLOW}Check your token and proxy, then try again from this menu.${NC}"
        pause
        return
    fi

    create_telegram_service
    create_telegram_notify_timer
    echo -e "${GREEN}Telegram bot configured and started.${NC}"
    echo -e "${CYAN}Send /start to your bot on Telegram now.${NC}"
    pause
}

check_traffic_limit() {
    local TNAME=$1
    local CFG="$CONFIG_DIR/$TNAME.json"
    local STATS="$CONFIG_DIR/$TNAME.stats.json"
    if [ ! -f "$CFG" ] || [ ! -f "$STATS" ]; then
        return
    fi
    local LIMIT_GB
    LIMIT_GB=$(get_json_number "$CFG" traffic_limit_gb)
    LIMIT_GB=${LIMIT_GB:-0}
    if is_zero_gb "$LIMIT_GB"; then
        return
    fi
    local RX TX
    RX=$(get_json_number "$STATS" rx)
    TX=$(get_json_number "$STATS" tx)
    RX=${RX:-0}
    TX=${TX:-0}
    local TOTAL=$((RX + TX))
    local LIMIT_BYTES
    LIMIT_BYTES=$(awk -v g="$LIMIT_GB" 'BEGIN{printf "%.0f", g*1073741824}')
    if [ "$TOTAL" -ge "$LIMIT_BYTES" ]; then
        if systemctl is-active --quiet "${APP_NAME}-$TNAME"; then
            systemctl stop "${APP_NAME}-$TNAME" >/dev/null 2>&1
            systemctl stop "${APP_NAME}-watch-$TNAME.timer" >/dev/null 2>&1
            logger -t anonymous-tunnel "tunnel $TNAME stopped: traffic limit of ${LIMIT_GB}GB exceeded" 2>/dev/null
        fi
    fi
}

create_limit_watcher() {
    local TNAME=$1
    local CFG="$CONFIG_DIR/$TNAME.json"
    local LIMIT_GB
    LIMIT_GB=$(get_json_number "$CFG" traffic_limit_gb)
    LIMIT_GB=${LIMIT_GB:-0}
    if is_zero_gb "$LIMIT_GB"; then
        remove_limit_watcher "$TNAME"
        return
    fi
    local WSVC="$SERVICE_DIR/${APP_NAME}-limit-$TNAME.service"
    local WTIMER="$SERVICE_DIR/${APP_NAME}-limit-$TNAME.timer"
    cat > "$WSVC" <<EOF
[Unit]
Description=Anonymous Tunnel Traffic Limit Check - $TNAME

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH __check_limit $TNAME
EOF
    cat > "$WTIMER" <<EOF
[Unit]
Description=Anonymous Tunnel Traffic Limit Timer - $TNAME

[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=${APP_NAME}-limit-$TNAME.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${APP_NAME}-limit-$TNAME.timer" >/dev/null 2>&1
}

remove_limit_watcher() {
    local TNAME=$1
    systemctl disable --now "${APP_NAME}-limit-$TNAME.timer" >/dev/null 2>&1
    rm -f "$SERVICE_DIR/${APP_NAME}-limit-$TNAME.service"
    rm -f "$SERVICE_DIR/${APP_NAME}-limit-$TNAME.timer"
    systemctl daemon-reload
}

set_traffic_limit() {
    local TNAME=$1
    local CFG="$CONFIG_DIR/$TNAME.json"
    local CURRENT
    CURRENT=$(get_json_number "$CFG" traffic_limit_gb)
    CURRENT=${CURRENT:-0}
    banner
    local TRX TTX TUSED
    TRX=$(get_json_number "$CONFIG_DIR/$TNAME.stats.json" rx); TRX=${TRX:-0}
    TTX=$(get_json_number "$CONFIG_DIR/$TNAME.stats.json" tx); TTX=${TTX:-0}
    TUSED=$((TRX + TTX))
    echo -e "${CYAN}Used so far: ${GREEN}$(human_bytes $TUSED)${NC}"
    if is_zero_gb "$CURRENT"; then
        echo -e "${CYAN}Current limit: ${GREEN}unlimited${NC}"
    else
        echo -e "${CYAN}Current limit: ${GREEN}${CURRENT}GB${NC}"
    fi
    read -p "$(echo -e ${CYAN}New limit in GB - decimals allowed, 0 for unlimited, leave empty to cancel: ${NC})" NEWLIMIT
    if [ -z "$NEWLIMIT" ]; then
        return
    fi
    if ! [[ "$NEWLIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo -e "${RED}Invalid number.${NC}"
        pause
        return
    fi
    if grep -q '"traffic_limit_gb"' "$CFG"; then
        sed -i -E "s/\"traffic_limit_gb\": *[0-9]+(\.[0-9]+)?/\"traffic_limit_gb\": $NEWLIMIT/" "$CFG"
    else
        sed -i "s/\"token\": \"\([^\"]*\)\"/\"token\": \"\1\",\n  \"traffic_limit_gb\": $NEWLIMIT/" "$CFG"
    fi
    create_limit_watcher "$TNAME"
    if is_zero_gb "$NEWLIMIT"; then
        echo -e "${GREEN}Traffic limit removed (unlimited).${NC}"
    else
        echo -e "${GREEN}Traffic limit set to ${NEWLIMIT}GB.${NC}"
        echo -e "${YELLOW}Note: usage is checked every 60s. If it was already stopped by a limit, use Start to bring it back up after raising the limit.${NC}"
    fi
    pause
}

reset_traffic() {
    local TNAME=$1
    banner
    read -p "$(echo -e "${YELLOW}Reset traffic counter for '$TNAME'? - y or n: ${NC}")" CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        return
    fi
    printf '{"rx":0,"tx":0,"updated":%s}' "$(date +%s)" > "$CONFIG_DIR/$TNAME.stats.json"
    systemctl restart "${APP_NAME}-$TNAME" >/dev/null 2>&1
    echo -e "${GREEN}Traffic counter reset for '$TNAME'.${NC}"
    pause
}

set_bandwidth_limit() {
    local TNAME=$1
    local CFG="$CONFIG_DIR/$TNAME.json"
    local CURRENT
    CURRENT=$(get_json_number "$CFG" bandwidth_limit_mbps)
    CURRENT=${CURRENT:-0}
    banner
    if is_zero_gb "$CURRENT"; then
        echo -e "${CYAN}Current bandwidth limit: ${GREEN}unlimited${NC}"
    else
        echo -e "${CYAN}Current bandwidth limit: ${GREEN}${CURRENT} Mbps${NC}"
    fi
    read -p "$(echo -e ${CYAN}New limit in Mbps - decimals allowed, 0 for unlimited, leave empty to cancel: ${NC})" NEWLIMIT
    if [ -z "$NEWLIMIT" ]; then
        return
    fi
    if ! [[ "$NEWLIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo -e "${RED}Invalid number.${NC}"
        pause
        return
    fi
    if grep -q '"bandwidth_limit_mbps"' "$CFG"; then
        sed -i -E "s/\"bandwidth_limit_mbps\": *[0-9]+(\.[0-9]+)?/\"bandwidth_limit_mbps\": $NEWLIMIT/" "$CFG"
    else
        sed -i "s/\"token\": \"\([^\"]*\)\"/\"token\": \"\1\",\n  \"bandwidth_limit_mbps\": $NEWLIMIT/" "$CFG"
    fi
    systemctl restart "${APP_NAME}-$TNAME" >/dev/null 2>&1
    if is_zero_gb "$NEWLIMIT"; then
        echo -e "${GREEN}Bandwidth limit removed (unlimited). Tunnel restarted to apply.${NC}"
    else
        echo -e "${GREEN}Bandwidth limit set to ${NEWLIMIT} Mbps. Tunnel restarted to apply.${NC}"
    fi
    pause
}

install_certbot_if_needed() {
    if command -v certbot >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${YELLOW}Installing certbot...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y certbot >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y certbot >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y certbot >/dev/null 2>&1
    fi
    command -v certbot >/dev/null 2>&1
}

letsencrypt_add_deploy_hook() {
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    local HOOK="/etc/letsencrypt/renewal-hooks/deploy/${APP_NAME}-restart.sh"
    cat > "$HOOK" <<EOF
#!/bin/bash
DOMAIN=\$(basename "\$RENEWED_LINEAGE")
for CFG in $CONFIG_DIR/*.json; do
    [ -f "\$CFG" ] || continue
    if grep -q "\"cert\": \"/etc/letsencrypt/live/\$DOMAIN/" "\$CFG"; then
        NAME=\$(basename "\$CFG" .json)
        systemctl restart "${APP_NAME}-\$NAME" 2>/dev/null
    fi
done
EOF
    chmod +x "$HOOK"
}

letsencrypt_issue() {
    local DOMAIN=$1
    if [ -z "$DOMAIN" ]; then
        return 1
    fi
    if ! install_certbot_if_needed; then
        echo -e "${RED}Could not install certbot automatically. Install it manually and try again.${NC}"
        return 1
    fi
    if ss -ltn 2>/dev/null | grep -q ":80 "; then
        echo -e "${YELLOW}Port 80 is currently in use. Certbot needs it free for a few seconds to verify the domain.${NC}"
        read -p "$(echo -e ${CYAN}Continue anyway? - y or n [n]: ${NC})" CONT
        if [ "$CONT" != "y" ]; then
            return 1
        fi
    fi
    read -p "$(echo -e ${CYAN}Email for renewal notices - optional, press enter to skip: ${NC})" LEEMAIL
    local EMAILARG
    if [ -n "$LEEMAIL" ]; then
        EMAILARG="-m $LEEMAIL"
    else
        EMAILARG="--register-unsafely-without-email"
    fi
    echo -e "${YELLOW}Requesting certificate for $DOMAIN...${NC}"
    certbot certonly --standalone --non-interactive --agree-tos $EMAILARG -d "$DOMAIN"
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo -e "${GREEN}Certificate obtained for $DOMAIN.${NC}"
        letsencrypt_add_deploy_hook
        return 0
    fi
    echo -e "${RED}Certificate issuance failed. Make sure $DOMAIN's DNS points to this server's IP and port 80 is reachable from the internet.${NC}"
    return 1
}

pick_tls_cert() {
    local NAME=$1
    echo -e "${CYAN}TLS certificate for this tunnel:${NC}"
    echo "  1) Auto-generate self-signed (default, no domain needed)"
    echo "  2) Get a free trusted certificate now (Let's Encrypt)"
    echo "  3) Use an existing Let's Encrypt certificate"
    read -p "$(echo -e ${CYAN}Select [1]: ${NC})" CCH
    if [ "$CCH" == "2" ]; then
        read -p "$(echo -e ${CYAN}Domain name - must already point to this server IP: ${NC})" LEDOMAIN
        if letsencrypt_issue "$LEDOMAIN"; then
            CERTF="/etc/letsencrypt/live/$LEDOMAIN/fullchain.pem"
            KEYF="/etc/letsencrypt/live/$LEDOMAIN/privkey.pem"
            return
        fi
        echo -e "${YELLOW}Falling back to self-signed.${NC}"
        CCH=1
    elif [ "$CCH" == "3" ]; then
        local CERTS=($(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README))
        if [ ${#CERTS[@]} -eq 0 ]; then
            echo -e "${RED}No existing Let's Encrypt certificates found. Falling back to self-signed.${NC}"
            CCH=1
        else
            local i=1
            for c in "${CERTS[@]}"; do
                echo "  $i) $c"
                i=$((i+1))
            done
            read -p "$(echo -e ${CYAN}Select a certificate: ${NC})" CIDX
            local SELDOMAIN=${CERTS[$((CIDX-1))]}
            if [ -n "$SELDOMAIN" ] && [ -f "/etc/letsencrypt/live/$SELDOMAIN/fullchain.pem" ]; then
                CERTF="/etc/letsencrypt/live/$SELDOMAIN/fullchain.pem"
                KEYF="/etc/letsencrypt/live/$SELDOMAIN/privkey.pem"
                return
            fi
            echo -e "${RED}Invalid selection. Falling back to self-signed.${NC}"
            CCH=1
        fi
    fi
    CERTF="$CONFIG_DIR/$NAME.crt"
    KEYF="$CONFIG_DIR/$NAME.key"
    if [ ! -f "$CERTF" ]; then
        openssl req -x509 -newkey rsa:2048 -keyout "$KEYF" -out "$CERTF" -days 3650 -nodes -subj "/CN=anonymous-tunnel" >/dev/null 2>&1
    fi
}

ssl_certificate_menu() {
    while true; do
        banner
        echo -e "${YELLOW}${BOLD}SSL Certificates (Let's Encrypt)${NC}"
        local CERTS=($(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README))
        if [ ${#CERTS[@]} -eq 0 ]; then
            echo -e "${CYAN}No certificates yet.${NC}"
        else
            echo -e "${CYAN}Existing certificates:${NC}"
            for c in "${CERTS[@]}"; do
                local EXP
                EXP=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$c/fullchain.pem" 2>/dev/null | cut -d= -f2)
                echo -e "  - ${GREEN}$c${NC} (expires: $EXP)"
            done
        fi
        echo ""
        echo -e "${CYAN}1. Get a new certificate${NC}"
        echo -e "${CYAN}2. Renew all certificates now${NC}"
        echo -e "${CYAN}0. Back${NC}"
        read -p "$(echo -e ${YELLOW}Select an option: ${NC})" SCH
        case $SCH in
            1)
                read -p "$(echo -e ${CYAN}Domain name - must already point to this server IP: ${NC})" LEDOMAIN
                if [ -n "$LEDOMAIN" ]; then
                    letsencrypt_issue "$LEDOMAIN"
                fi
                pause
                ;;
            2)
                install_certbot_if_needed >/dev/null 2>&1
                certbot renew --non-interactive
                pause
                ;;
            0) return ;;
            *) ;;
        esac
    done
}

view_live_logs() {
    local TNAME=$1
    banner
    echo -e "${YELLOW}${BOLD}Live logs for: ${GREEN}$TNAME${NC}"
    echo -e "${CYAN}Type 0 then Enter to go back.${NC}"
    echo ""
    journalctl -u "${APP_NAME}-$TNAME" -f --no-pager &
    local LOGPID=$!
    while true; do
        read -r LCH
        if [ "$LCH" == "0" ]; then
            kill "$LOGPID" >/dev/null 2>&1
            wait "$LOGPID" 2>/dev/null
            break
        fi
    done
}

human_bytes() {
    local b=$1
    if [ -z "$b" ]; then
        b=0
    fi
    if [ "$b" -lt 1024 ]; then
        echo "${b} B"
    elif [ "$b" -lt 1048576 ]; then
        echo "$(( b / 1024 )) KB"
    elif [ "$b" -lt 1073741824 ]; then
        awk -v b="$b" 'BEGIN{printf "%.2f MB", b/1048576}'
    else
        awk -v b="$b" 'BEGIN{printf "%.2f GB", b/1073741824}'
    fi
}

edit_tunnel() {
    local TNAME=$1
    local CFG="$CONFIG_DIR/$TNAME.json"
    local MODE
    MODE=$(get_json_value "$CFG" mode)
    local TOKEN
    TOKEN=$(get_json_value "$CFG" token)
    banner
    echo -e "${YELLOW}${BOLD}Editing: ${GREEN}$TNAME${NC} [$MODE]"
    echo -e "${CYAN}You can type 0 at any prompt below to cancel and go back.${NC}"

    if ! choose_transport; then
        echo -e "${YELLOW}Cancelled.${NC}"
        pause
        return
    fi

    if [ "$MODE" == "server" ]; then
        local OLDBIND OLDPORTS
        OLDBIND=$(get_json_value "$CFG" bind_addr)
        OLDPORTS=$(grep -oP '"\d+"\s*:\s*"0\.0\.0\.0:\K\d+' "$CFG" | paste -sd, -)

        read -p "$(echo -e ${CYAN}New control port [keep: ${OLDBIND##*:}] - or 0 to cancel: ${NC})" CPORT
        if [ "$CPORT" == "0" ]; then
            echo -e "${YELLOW}Cancelled.${NC}"
            pause
            return
        fi
        CPORT=${CPORT:-${OLDBIND##*:}}

        read -p "$(echo -e ${CYAN}New public ports, comma separated [keep: $OLDPORTS] - or 0 to cancel: ${NC})" PORTS
        if [ "$PORTS" == "0" ]; then
            echo -e "${YELLOW}Cancelled.${NC}"
            pause
            return
        fi
        PORTS=${PORTS:-$OLDPORTS}

        CERT_JSON=""
        if [ "$TRANSPORT" == "wss" ] || [ "$TRANSPORT" == "wss_mux" ]; then
            pick_tls_cert "$TNAME"
            CERT_JSON=",
  \"cert\": \"$CERTF\",
  \"key\": \"$KEYF\""
        fi

        SERVICES="{"
        IFS=',' read -ra PARR <<< "$PORTS"
        FIRST=1
        for P in "${PARR[@]}"; do
            P=$(echo "$P" | xargs)
            if [ "$FIRST" -eq 0 ]; then
                SERVICES="$SERVICES,"
            fi
            SERVICES="$SERVICES\"$P\":\"0.0.0.0:$P\""
            FIRST=0
        done
        SERVICES="$SERVICES}"

        cat > "$CFG" <<EOF
{
  "mode": "server",
  "bind_addr": "0.0.0.0:$CPORT",
  "token": "$TOKEN",
  "transport": "$TRANSPORT"$CERT_JSON,
  "services": $SERVICES
}
EOF
    else
        local OLDSERVER OLDPORTS
        OLDSERVER=$(get_json_value "$CFG" server_addr)
        OLDPORTS=$(grep -oP '"\d+"\s*:\s*"127\.0\.0\.1:\K\d+' "$CFG" | paste -sd, -)

        read -p "$(echo -e ${CYAN}New Iran server IP:PORT [keep: $OLDSERVER] - or 0 to cancel: ${NC})" SADDR
        if [ "$SADDR" == "0" ]; then
            echo -e "${YELLOW}Cancelled.${NC}"
            pause
            return
        fi
        SADDR=${SADDR:-$OLDSERVER}

        read -p "$(echo -e ${CYAN}New forwarded ports, comma separated [keep: $OLDPORTS] - or 0 to cancel: ${NC})" PORTS
        if [ "$PORTS" == "0" ]; then
            echo -e "${YELLOW}Cancelled.${NC}"
            pause
            return
        fi
        PORTS=${PORTS:-$OLDPORTS}

        SERVICES="{"
        IFS=',' read -ra PARR <<< "$PORTS"
        FIRST=1
        for P in "${PARR[@]}"; do
            P=$(echo "$P" | xargs)
            if [ "$FIRST" -eq 0 ]; then
                SERVICES="$SERVICES,"
            fi
            SERVICES="$SERVICES\"$P\":\"127.0.0.1:$P\""
            FIRST=0
        done
        SERVICES="$SERVICES}"

        cat > "$CFG" <<EOF
{
  "mode": "client",
  "server_addr": "$SADDR",
  "token": "$TOKEN",
  "transport": "$TRANSPORT",
  "services": $SERVICES
}
EOF
    fi

    systemctl restart "${APP_NAME}-$TNAME"
    echo -e "${GREEN}Tunnel '$TNAME' updated and restarted.${NC}"
    pause
}

create_server_tunnel() {
    check_installed || return
    banner
    echo -e "${YELLOW}${BOLD}Create Server Tunnel (Iran Server)${NC}"
    read -p "$(echo -e ${CYAN}Enter a name for this tunnel: ${NC})" TNAME
    read -p "$(echo -e ${CYAN}Enter the port for the tunnel control connection [2333]: ${NC})" CPORT
    CPORT=${CPORT:-2333}
    read -p "$(echo -e ${CYAN}Enter public ports to expose, comma separated - e.g. 443,8080: ${NC})" PORTS
    read -p "$(echo -e ${CYAN}Enter a token/password [random]: ${NC})" TOKEN
    TOKEN=${TOKEN:-$(generate_token)}
    if ! choose_transport; then
        echo -e "${YELLOW}Cancelled.${NC}"
        pause
        return
    fi

    CERT_JSON=""
    if [ "$TRANSPORT" == "wss" ] || [ "$TRANSPORT" == "wss_mux" ]; then
        pick_tls_cert "$TNAME"
        CERT_JSON=",
  \"cert\": \"$CERTF\",
  \"key\": \"$KEYF\""
    fi

    SERVICES="{"
    IFS=',' read -ra PARR <<< "$PORTS"
    FIRST=1
    for P in "${PARR[@]}"; do
        P=$(echo "$P" | xargs)
        if [ "$FIRST" -eq 0 ]; then
            SERVICES="$SERVICES,"
        fi
        SERVICES="$SERVICES\"$P\":\"0.0.0.0:$P\""
        FIRST=0
    done
    SERVICES="$SERVICES}"

    CFG="$CONFIG_DIR/$TNAME.json"
    cat > "$CFG" <<EOF
{
  "mode": "server",
  "bind_addr": "0.0.0.0:$CPORT",
  "token": "$TOKEN",
  "transport": "$TRANSPORT"$CERT_JSON,
  "services": $SERVICES
}
EOF

    create_service "$TNAME" "server"

    read -p "$(echo -e ${CYAN}Enable Auto Refresh watchdog? - y or n [y]: ${NC})" WD
    WD=${WD:-y}
    if [ "$WD" == "y" ]; then
        create_watchdog "$TNAME"
    fi

    echo -e "${GREEN}Server tunnel '$TNAME' created and started.${NC}"
    echo -e "${YELLOW}Token: ${GREEN}$TOKEN${NC}"
    pause
}

create_client_tunnel() {
    check_installed || return
    banner
    echo -e "${YELLOW}${BOLD}Create Client Tunnel (Foreign Server)${NC}"
    read -p "$(echo -e ${CYAN}Enter a name for this tunnel: ${NC})" TNAME
    read -p "$(echo -e ${CYAN}Enter the Iran server IP address: ${NC})" SIP
    read -p "$(echo -e ${CYAN}Enter the server control port [2333]: ${NC})" CPORT
    CPORT=${CPORT:-2333}
    read -p "$(echo -e ${CYAN}Enter ports to forward, comma separated - e.g. 443,8080: ${NC})" PORTS
    read -p "$(echo -e ${CYAN}Enter the token/password used on the server: ${NC})" TOKEN
    if ! choose_transport; then
        echo -e "${YELLOW}Cancelled.${NC}"
        pause
        return
    fi

    SERVICES="{"
    IFS=',' read -ra PARR <<< "$PORTS"
    FIRST=1
    for P in "${PARR[@]}"; do
        P=$(echo "$P" | xargs)
        if [ "$FIRST" -eq 0 ]; then
            SERVICES="$SERVICES,"
        fi
        SERVICES="$SERVICES\"$P\":\"127.0.0.1:$P\""
        FIRST=0
    done
    SERVICES="$SERVICES}"

    CFG="$CONFIG_DIR/$TNAME.json"
    cat > "$CFG" <<EOF
{
  "mode": "client",
  "server_addr": "$SIP:$CPORT",
  "token": "$TOKEN",
  "transport": "$TRANSPORT",
  "services": $SERVICES
}
EOF

    create_service "$TNAME" "client"

    read -p "$(echo -e ${CYAN}Enable Auto Refresh watchdog? - y or n [y]: ${NC})" WD
    WD=${WD:-y}
    if [ "$WD" == "y" ]; then
        create_watchdog "$TNAME"
    fi

    echo -e "${GREEN}Client tunnel '$TNAME' created and started.${NC}"
    pause
}

create_service() {
    local NAME=$1
    local ROLE=$2
    local SVC="$SERVICE_DIR/${APP_NAME}-$NAME.service"
    cat > "$SVC" <<EOF
[Unit]
Description=Anonymous Tunnel ($ROLE) - $NAME
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH $CONFIG_DIR/$NAME.json
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${APP_NAME}-$NAME" >/dev/null 2>&1
    systemctl restart "${APP_NAME}-$NAME"
}

manage_tunnels() {
    banner
    TUNNELS=($(list_tunnels))
    if [ ${#TUNNELS[@]} -eq 0 ]; then
        echo -e "${RED}No tunnels found.${NC}"
        pause
        return
    fi
    echo -e "${YELLOW}${BOLD}Existing Tunnels:${NC}"
    for i in "${!TUNNELS[@]}"; do
        STATUS=$(systemctl is-active "${APP_NAME}-${TUNNELS[$i]}" 2>/dev/null)
        if [ "$STATUS" == "active" ]; then
            echo -e "  $((i+1)). ${TUNNELS[$i]} - ${GREEN}Running${NC}"
        else
            echo -e "  $((i+1)). ${TUNNELS[$i]} - ${RED}Stopped${NC}"
        fi
    done
    echo ""
    read -p "$(echo -e ${CYAN}Select a tunnel number to manage - 0 to cancel: ${NC})" SEL
    if [ "$SEL" == "0" ] || [ -z "$SEL" ]; then
        return
    fi
    IDX=$((SEL-1))
    if [ -z "${TUNNELS[$IDX]}" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        pause
        return
    fi
    TNAME="${TUNNELS[$IDX]}"
    while true; do
        banner
        echo -e "${YELLOW}Managing: ${GREEN}$TNAME${NC}"
        echo -e "${CYAN}1. Start${NC}"
        echo -e "${CYAN}2. Stop${NC}"
        echo -e "${CYAN}3. Restart${NC}"
        echo -e "${CYAN}4. View Status${NC}"
        echo -e "${CYAN}5. View Logs${NC}"
        echo -e "${CYAN}6. View Config${NC}"
        if watchdog_active "$TNAME"; then
            echo -e "${CYAN}7. Disable Auto Refresh${NC} (${GREEN}enabled${NC})"
        else
            echo -e "${CYAN}7. Enable Auto Refresh${NC} (${RED}disabled${NC})"
        fi
        local CURLIMIT
        CURLIMIT=$(get_json_number "$CONFIG_DIR/$TNAME.json" traffic_limit_gb)
        CURLIMIT=${CURLIMIT:-0}
        local TRX TTX TUSED
        TRX=$(get_json_number "$CONFIG_DIR/$TNAME.stats.json" rx); TRX=${TRX:-0}
        TTX=$(get_json_number "$CONFIG_DIR/$TNAME.stats.json" tx); TTX=${TTX:-0}
        TUSED=$((TRX + TTX))
        if is_zero_gb "$CURLIMIT"; then
            echo -e "${CYAN}8. Set Traffic Limit${NC} (${GREEN}unlimited${NC}, used: $(human_bytes $TUSED))"
        else
            echo -e "${CYAN}8. Set Traffic Limit${NC} (${YELLOW}${CURLIMIT}GB${NC}, used: $(human_bytes $TUSED))"
        fi
        local CURBW
        CURBW=$(get_json_number "$CONFIG_DIR/$TNAME.json" bandwidth_limit_mbps)
        CURBW=${CURBW:-0}
        if is_zero_gb "$CURBW"; then
            echo -e "${CYAN}9. Set Bandwidth Limit${NC} (${GREEN}unlimited${NC})"
        else
            echo -e "${CYAN}9. Set Bandwidth Limit${NC} (${YELLOW}${CURBW} Mbps${NC})"
        fi
        echo -e "${CYAN}10. Reset Traffic${NC}"
        echo -e "${CYAN}11. Edit Transport / Ports${NC}"
        echo -e "${CYAN}12. Delete Tunnel${NC}"
        echo -e "${CYAN}0. Back${NC}"
        read -p "$(echo -e ${YELLOW}Select option: ${NC})" OPT
        case $OPT in
            1) systemctl start "${APP_NAME}-$TNAME"; echo -e "${GREEN}Started.${NC}"; pause ;;
            2) systemctl stop "${APP_NAME}-$TNAME"; echo -e "${GREEN}Stopped.${NC}"; pause ;;
            3) systemctl restart "${APP_NAME}-$TNAME"; echo -e "${GREEN}Restarted.${NC}"; pause ;;
            4) systemctl status "${APP_NAME}-$TNAME" --no-pager; pause ;;
            5) view_live_logs "$TNAME" ;;
            6) cat "$CONFIG_DIR/$TNAME.json"; pause ;;
            7)
                if watchdog_active "$TNAME"; then
                    remove_watchdog "$TNAME"
                    echo -e "${GREEN}Auto Refresh disabled.${NC}"
                else
                    create_watchdog "$TNAME"
                    echo -e "${GREEN}Auto Refresh enabled.${NC}"
                fi
                pause
                ;;
            8) set_traffic_limit "$TNAME" ;;
            9) set_bandwidth_limit "$TNAME" ;;
            10) reset_traffic "$TNAME" ;;
            11) edit_tunnel "$TNAME" ;;
            12)
                systemctl stop "${APP_NAME}-$TNAME" >/dev/null 2>&1
                systemctl disable "${APP_NAME}-$TNAME" >/dev/null 2>&1
                rm -f "$SERVICE_DIR/${APP_NAME}-$TNAME.service"
                rm -f "$CONFIG_DIR/$TNAME.json"
                rm -f "$CONFIG_DIR/$TNAME.crt" "$CONFIG_DIR/$TNAME.key"
                rm -f "$CONFIG_DIR/$TNAME.stats.json"
                remove_watchdog "$TNAME"
                remove_limit_watcher "$TNAME"
                systemctl daemon-reload
                echo -e "${GREEN}Tunnel deleted.${NC}"
                pause
                return
                ;;
            0) return ;;
            *) echo -e "${RED}Invalid option.${NC}"; pause ;;
        esac
    done
}

uninstall_all() {
    banner
    echo -e "${RED}${BOLD}This will remove Anonymous Tunnel, all tunnels and services.${NC}"
    read -p "$(echo -e ${YELLOW}Are you sure? - y or n: ${NC})" CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        return
    fi
    for T in $(list_tunnels); do
        systemctl stop "${APP_NAME}-$T" >/dev/null 2>&1
        systemctl disable "${APP_NAME}-$T" >/dev/null 2>&1
        rm -f "$SERVICE_DIR/${APP_NAME}-$T.service"
        remove_watchdog "$T"
        remove_limit_watcher "$T"
    done
    systemctl daemon-reload
    rm -rf "$CONFIG_DIR"
    rm -rf "$CORE_DIR"
    rm -f "$INSTALL_PATH"
    echo -e "${GREEN}Everything has been removed.${NC}"
    pause
    exit 0
}

main_menu() {
    while true; do
        banner
        show_traffic_summary
        show_tunnel_status
        echo -e "${CYAN}1. Install / Update Core${NC}"
        echo -e "${CYAN}2. Create Server Tunnel (Iran Server)${NC}"
        echo -e "${CYAN}3. Create Client Tunnel (Foreign Server)${NC}"
        echo -e "${CYAN}4. Manage Tunnels${NC}"
        echo -e "${CYAN}5. Optimize (kernel/network tuning)${NC}"
        echo -e "${CYAN}6. Network Diagnostics${NC}"
        echo -e "${CYAN}7. Telegram Bot${NC}"
        echo -e "${CYAN}8. Server Benchmark${NC}"
        echo -e "${CYAN}9. SSL Certificates (Let's Encrypt)${NC}"
        echo -e "${CYAN}10. Uninstall Everything${NC}"
        echo -e "${RED}0. Exit${NC}"
        echo -e "${CYAN}${BOLD}==============================================${NC}"
        read -p "$(echo -e ${YELLOW}Select an option: ${NC})" CHOICE
        case $CHOICE in
            1) install_core ;;
            2) create_server_tunnel ;;
            3) create_client_tunnel ;;
            4) manage_tunnels ;;
            5) optimize_kernel ;;
            6) network_diagnostics ;;
            7) telegram_bot_menu ;;
            8) run_bench ;;
            9) ssl_certificate_menu ;;
            10) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid option.${NC}"; pause ;;
        esac
    done
}

need_root

if [ "$1" == "__check_limit" ] && [ -n "$2" ]; then
    check_traffic_limit "$2"
    exit 0
fi

if [ "$1" == "__tg_run" ]; then
    run_telegram_bot
    exit 0
fi

if [ "$1" == "__tg_check_notify" ]; then
    tg_check_notify
    exit 0
fi

self_install
main_menu
