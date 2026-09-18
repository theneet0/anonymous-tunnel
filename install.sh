#!/bin/bash
# ==========================================================
# Anonymous Tunnel - Quick GitHub Installer
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

SCRIPT_URL="https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/anonymous-tunnel.sh"
MIRROR_SCRIPT_URL="https://ghproxy.net/https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/anonymous-tunnel.sh"
CDN_SCRIPT_URL="https://cdn.jsdelivr.net/gh/$GITHUB_REPO@$BRANCH/anonymous-tunnel.sh"

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

echo -e "${CYAN}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}      ANONYMOUS TUNNEL - GITHUB INSTALLER${NC}"
echo -e "${CYAN}${BOLD}==============================================${NC}"

ensure_downloader

# 1. Download Manager Script
echo -e "${BLUE}Downloading Anonymous Tunnel Manager script...${NC}"
TMP_SCRIPT="/tmp/anonymous-tunnel-script.tmp"
rm -f "$TMP_SCRIPT"

if download_file "$SCRIPT_URL" "$TMP_SCRIPT" && [ -s "$TMP_SCRIPT" ]; then
    echo -e "${GREEN}✓ Downloaded directly from GitHub.${NC}"
elif download_file "$MIRROR_SCRIPT_URL" "$TMP_SCRIPT" && [ -s "$TMP_SCRIPT" ]; then
    echo -e "${GREEN}✓ Downloaded via GitHub mirror.${NC}"
elif download_file "$CDN_SCRIPT_URL" "$TMP_SCRIPT" && [ -s "$TMP_SCRIPT" ]; then
    echo -e "${GREEN}✓ Downloaded via jsDelivr CDN fallback.${NC}"
else
    echo -e "${RED}Failed to download Anonymous Tunnel script.${NC}"
    rm -f "$TMP_SCRIPT"
    exit 1
fi

mv "$TMP_SCRIPT" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
echo -e "${GREEN}✓ Manager script installed to ${INSTALL_PATH}${NC}"

# 2. Detect Arch & Download Precompiled Core Binary
ARCH_SUFFIX=$(detect_arch)
if [ -n "$ARCH_SUFFIX" ]; then
    ASSET_NAME="anonymous-tunnel-core-${ARCH_SUFFIX}"
    PRIMARY_URL="https://github.com/$GITHUB_REPO/releases/latest/download/${ASSET_NAME}"
    MIRROR_URL="https://ghproxy.net/https://github.com/$GITHUB_REPO/releases/latest/download/${ASSET_NAME}"
    CDN_URL="https://cdn.jsdelivr.net/gh/$GITHUB_REPO@$BRANCH/bin/${ASSET_NAME}"
    TMP_CORE="/tmp/${ASSET_NAME}.tmp"
    rm -f "$TMP_CORE"

    echo -e "${BLUE}Detected Architecture: ${CYAN}${ARCH_SUFFIX}${NC}"
    echo -e "${BLUE}Downloading Anonymous Tunnel Core binary...${NC}"

    if download_file "$PRIMARY_URL" "$TMP_CORE" && [ -s "$TMP_CORE" ]; then
        echo -e "${GREEN}✓ Core binary downloaded directly from GitHub Releases.${NC}"
    elif download_file "$MIRROR_URL" "$TMP_CORE" && [ -s "$TMP_CORE" ]; then
        echo -e "${GREEN}✓ Core binary downloaded via mirror.${NC}"
    elif download_file "$CDN_URL" "$TMP_CORE" && [ -s "$TMP_CORE" ]; then
        echo -e "${GREEN}✓ Core binary downloaded via jsDelivr CDN fallback.${NC}"
    else
        echo -e "${YELLOW}Warning: Core binary download failed or timed out. You can install it from the main menu.${NC}"
    fi

    if [ -s "$TMP_CORE" ]; then
        chmod +x "$TMP_CORE"
        mv "$TMP_CORE" "$BIN_PATH"
        echo -e "${GREEN}✓ Core binary installed to ${BIN_PATH}${NC}"
    fi
    rm -f "$TMP_CORE"
fi

# 3. Save GitHub as preferred source
echo 'DOWNLOAD_SOURCE="github"' > "$SOURCE_CONF"

echo -e "${CYAN}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}Anonymous Tunnel installed successfully!${NC}"
echo -e "${YELLOW}Next time just run: ${GREEN}sudo anonymous-tunnel${NC}"
echo -e "${CYAN}${BOLD}==============================================${NC}"
sleep 1

exec "$INSTALL_PATH"
