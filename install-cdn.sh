#!/bin/bash
# ==========================================================
# Anonymous Tunnel - Quick CDN Installer (jsDelivr CDN)
# Optimized for Iranian servers & restricted network environments
# ==========================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this installer as root (sudo).${NC}"
    exit 1
fi

APP_NAME="anonymous-tunnel"
INSTALL_PATH="/usr/local/bin/$APP_NAME"
CORE_DIR="/usr/local/lib/$APP_NAME"
BIN_PATH="$CORE_DIR/core"
CONFIG_DIR="/etc/$APP_NAME"
SOURCE_CONF="$CONFIG_DIR/source.conf"
GITHUB_REPO="theneet0/anonymous-tunnel"
BRANCH="main"

# jsDelivr CDN Primary URLs & Multi-CDN Mirrors
SCRIPT_CDN_URL="https://cdn.jsdelivr.net/gh/${GITHUB_REPO}@${BRANCH}/anonymous-tunnel.sh"
SCRIPT_MIRRORS=(
    "https://fastly.jsdelivr.net/gh/${GITHUB_REPO}@${BRANCH}/anonymous-tunnel.sh"
    "https://gcore.jsdelivr.net/gh/${GITHUB_REPO}@${BRANCH}/anonymous-tunnel.sh"
    "https://testingcf.jsdelivr.net/gh/${GITHUB_REPO}@${BRANCH}/anonymous-tunnel.sh"
    "https://raw.githubusercontent.com/${GITHUB_REPO}/${BRANCH}/anonymous-tunnel.sh"
    "https://ghproxy.net/https://raw.githubusercontent.com/${GITHUB_REPO}/${BRANCH}/anonymous-tunnel.sh"
)

mkdir -p "$CONFIG_DIR" "$CORE_DIR"

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
        apt update -y >/dev/null 2>&1 && apt install -y curl wget >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget >/dev/null 2>&1
    fi
}

download_file() {
    local url=$1
    local dest=$2
    local timeout=15

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$timeout" -m 90 "$url" -o "$dest" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$timeout" -O "$dest" "$url" 2>/dev/null
    else
        return 1
    fi
}

download_with_fallback() {
    local primary=$1
    local dest=$2
    shift 2
    local mirrors=("$@")

    if download_file "$primary" "$dest" && [ -s "$dest" ]; then
        return 0
    fi

    for mirror in "${mirrors[@]}"; do
        echo -e "${YELLOW}CDN node busy or timed out, trying mirror: ${mirror%%/gh*}...${NC}"
        if download_file "$mirror" "$dest" && [ -s "$dest" ]; then
            return 0
        fi
    done
    return 1
}

echo -e "${CYAN}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}    ANONYMOUS TUNNEL - JSDELIVR CDN INSTALLER${NC}"
echo -e "${CYAN}${BOLD}==============================================${NC}"
echo -e "${BLUE}CDN Network: ${GREEN}cdn.jsdelivr.net (High-Speed / Iran Optimized)${NC}"

ensure_downloader

# 1. Download Anonymous Tunnel Manager Script via CDN
echo -e "${BLUE}Downloading Anonymous Tunnel Manager script...${NC}"
TMP_SCRIPT="/tmp/anonymous-tunnel-script.tmp"
rm -f "$TMP_SCRIPT"

if download_with_fallback "$SCRIPT_CDN_URL" "$TMP_SCRIPT" "${SCRIPT_MIRRORS[@]}"; then
    mv "$TMP_SCRIPT" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo -e "${GREEN}✓ Manager script installed to ${INSTALL_PATH}${NC}"
else
    echo -e "${RED}Failed to download Anonymous Tunnel script via CDN and mirrors.${NC}"
    rm -f "$TMP_SCRIPT"
    exit 1
fi

# 2. Detect Arch & Download Precompiled Core Binary via jsDelivr CDN
ARCH_SUFFIX=$(detect_arch)
if [ -n "$ARCH_SUFFIX" ]; then
    ASSET_NAME="anonymous-tunnel-core-${ARCH_SUFFIX}"
    CORE_CDN_URL="https://cdn.jsdelivr.net/gh/${GITHUB_REPO}@${BRANCH}/bin/${ASSET_NAME}"
    CORE_MIRRORS=(
        "https://fastly.jsdelivr.net/gh/${GITHUB_REPO}@${BRANCH}/bin/${ASSET_NAME}"
        "https://gcore.jsdelivr.net/gh/${GITHUB_REPO}@${BRANCH}/bin/${ASSET_NAME}"
        "https://testingcf.jsdelivr.net/gh/${GITHUB_REPO}@${BRANCH}/bin/${ASSET_NAME}"
        "https://github.com/${GITHUB_REPO}/releases/latest/download/${ASSET_NAME}"
        "https://ghproxy.net/https://github.com/${GITHUB_REPO}/releases/latest/download/${ASSET_NAME}"
    )
    TMP_CORE="/tmp/${ASSET_NAME}.tmp"
    rm -f "$TMP_CORE"

    echo -e "${BLUE}Detected Architecture: ${CYAN}${ARCH_SUFFIX}${NC}"
    echo -e "${BLUE}Downloading Anonymous Tunnel Core binary via jsDelivr CDN...${NC}"

    if download_with_fallback "$CORE_CDN_URL" "$TMP_CORE" "${CORE_MIRRORS[@]}"; then
        chmod +x "$TMP_CORE"
        mv "$TMP_CORE" "$BIN_PATH"
        echo -e "${GREEN}✓ Core binary installed to ${BIN_PATH}${NC}"
    else
        echo -e "${YELLOW}Warning: Core binary download timed out. You can install it from the manager menu.${NC}"
        rm -f "$TMP_CORE"
    fi
else
    echo -e "${YELLOW}Warning: Unknown architecture ($(uname -m)). Core can be built or downloaded manually.${NC}"
fi

# 3. Save CDN preference for future updates
echo 'DOWNLOAD_SOURCE="cdn"' > "$SOURCE_CONF"

echo -e "${CYAN}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}Anonymous Tunnel installed successfully via jsDelivr CDN!${NC}"
echo -e "${YELLOW}Next time just run: ${GREEN}sudo anonymous-tunnel${NC}"
echo -e "${CYAN}${BOLD}==============================================${NC}"
sleep 1

exec "$INSTALL_PATH"
