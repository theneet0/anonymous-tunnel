# Anonymous Tunnel

[![Release](https://img.shields.io/github/v/release/theneet0/anonymous-tunnel?color=blue&style=flat-square)](https://github.com/theneet0/anonymous-tunnel/releases)
[![Go Version](https://img.shields.io/badge/Go-1.21+-00ADD8?style=flat-square&logo=go)](https://golang.org)
[![Platform](https://img.shields.io/badge/Platform-Linux%20(Multi--Arch)-orange?style=flat-square)](https://github.com/theneet0/anonymous-tunnel)

High-performance, multiplexed, encrypted reverse tunneling solution designed for restricted network environments. Featuring automated CI/CD releases across multiple architectures, zero server-side compilation dependencies, Telegram Bot remote management, traffic quota enforcement, and systemd watchdog supervision.

---

## Quick Installation

Choose the installation method suited for your server environment:

### Option A: High-Speed CDN Installation (jsDelivr - Recommended for Iran servers)
Optimized for restricted networks and bypasses GitHub throttling/censorship:

```bash
bash <(curl -Ls https://cdn.jsdelivr.net/gh/theneet0/anonymous-tunnel@main/install-cdn.sh)
```

Or using `wget`:

```bash
bash <(wget -qO- https://cdn.jsdelivr.net/gh/theneet0/anonymous-tunnel@main/install-cdn.sh)
```

### Option B: Direct GitHub Installation
Direct download from GitHub repository with mirror fallback:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/theneet0/anonymous-tunnel/main/install.sh)
```

Or using `wget`:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/theneet0/anonymous-tunnel/main/install.sh)
```

---

### Launching the Manager

Once installed, simply launch the manager anytime:

```bash
sudo anonymous-tunnel
```

---

## Architecture & Decoupled Core

The project decouples the **Go Networking Core Engine** from the **Bash Interactive Management Layer**:

```
+-------------------------------------------------------------+
|                 Anonymous Tunnel Manager (Bash)             |
|   - Interactive CLI Menu & One-Click Setup                  |
|   - Systemd Service & Watchdog Generator                    |
|   - Network Diagnostics, Speedtest & Ookla Benchmark        |
|   - Let's Encrypt Automated Certificate Hooks               |
|   - Telegram Bot with Remote Tunnel / Core Control          |
+-------------------------------------------------------------+
                               |
               Downloads Pre-Compiled Binary
                               v
+-------------------------------------------------------------+
|            Anonymous Tunnel Core (Go Engine)                |
|   - Static CGO_ENABLED=0 Stripped ELF Binary                |
|   - X25519 ECDH Key Exchange + AES-GCM Encryption           |
|   - Multiplexed Stream Pools & Dynamic Port Forwarding       |
|   - Real-time Rate Limiting & Live Stats Reporting          |
+-------------------------------------------------------------+
```

### Supported Architectures

Binaries are compiled and published automatically via GitHub Actions:

- `linux-amd64` (Standard x86_64 VPS)
- `linux-arm64` (ARM64 / aarch64, e.g. Oracle Cloud ARM, Apple Silicon VPS, Raspberry Pi 4/5)
- `linux-armv7` (32-bit ARM v7)
- `linux-armv6` (32-bit ARM v6)
- `linux-386` (32-bit x86)

---

## Transports Supported

1. **TCP**: Standard direct connection with TCP_NODELAY optimization.
2. **TCP Mux**: Multi-stream multiplexing over an active connection pool.
3. **TCP + Stealth**: TLS ClientHello preamble mimicry to bypass heuristic DPI filters.
4. **TCP + PCK**: Anti-throttle packet shaping and chaff injection to disguise traffic patterns.
5. **WS**: HTTP/1.1 WebSocket upgrade handshake.
6. **WS Mux**: Multiplexed streams over WebSocket connections.
7. **WSS**: TLS-encrypted WebSocket with custom or Let's Encrypt certificates.
8. **WSS Mux**: Multiplexed streams encapsulated inside WSS.
9. **UDP + FEC**: Forward Error Correction over UDP with XOR parity matrices for high-loss networks.

---

## Core Features

- **Decoupled Multi-CDN Distribution**: No Go compiler or toolchain needed on target servers. Binaries and management scripts are distributed via high-speed jsDelivr Multi-CDN network (optimized for Iranian servers & restricted networks) and GitHub Releases with automatic mirror fallback (`ghproxy.net`).
- **Telegram Bot Remote Control**: Manage, start, stop, restart, monitor bandwidth, inspect live logs, and update the core directly from Telegram.
- **Auto-Refresh Watchdog**: Integrated systemd timer checking tunnel liveness every 30 seconds.
- **Traffic & Bandwidth Quotas**: Real-time traffic meter with automatic suspension upon reaching GB quotas.
- **Kernel Optimization**: One-click system-wide tuning enabling BBR congestion control, 8MB TCP buffer allocations, and high file descriptor limits (`1048576`).
- **Comprehensive Diagnostics**: Built-in DNS, IPv4/IPv6 ping, MTU path discovery, route tracing, and firewall rule detection.

---

## Building from Source

To manually compile the core engine:

```bash
cd core
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o core main.go
```

Cross-compiling for ARM64:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o core-arm64 main.go
```

---

## License

Released under the [MIT License](LICENSE).
