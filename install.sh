#!/bin/bash
# Anonymous Tunnel - Quick Installer
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run this installer as root."
    exit 1
fi

APP_NAME="anonymous-tunnel"
INSTALL_PATH="/usr/local/bin/$APP_NAME"
GITHUB_REPO="theneet0/anonymous-tunnel"
SCRIPT_URL="https://raw.githubusercontent.com/$GITHUB_REPO/main/anonymous-tunnel.sh"
MIRROR_SCRIPT_URL="https://ghproxy.net/https://raw.githubusercontent.com/$GITHUB_REPO/main/anonymous-tunnel.sh"

echo "Installing Anonymous Tunnel Manager..."

if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL --connect-timeout 10 -m 30"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO- --timeout=10"
else
    if command -v apt >/dev/null 2>&1; then
        apt update -y >/dev/null 2>&1 && apt install -y curl >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl >/dev/null 2>&1
    fi
    FETCH="curl -fsSL --connect-timeout 10 -m 30"
fi

if ! $FETCH "$SCRIPT_URL" > "$INSTALL_PATH" 2>/dev/null || [ ! -s "$INSTALL_PATH" ]; then
    echo "Direct GitHub download failed or timed out. Trying mirror..."
    $FETCH "$MIRROR_SCRIPT_URL" > "$INSTALL_PATH"
fi

chmod +x "$INSTALL_PATH"
echo "Anonymous Tunnel installed successfully to $INSTALL_PATH"
exec "$INSTALL_PATH"
