# Hysteria2 Linux Auto Deploy

An automated script to install and configure a **Hysteria2** node on **Linux** with minimal effort.  
This tool is designed for lightweight environments and one-click setup.

---

## 🚀 Features

- 🧩 Automatically installs required dependencies  
- ⚙️ Downloads and configures **Hysteria2**  
- 🔁 Sets up **OpenRC** or **Systemd** service for auto start  
- 📦 Supports configuration file generation  
- 🔍 Detects public IPv4 automatically  
- 🔒 Runs securely as a non-root service (optional)
- 🔗 Prints a one-line **AstraLink import link** at the end (traffic reporting key + panel-managed auth included)

---

## 📦 Requirements

- **Linux VPS**
- **Root access** (or sudo)
- Internet connection
- At least 64M (128M recommend) of DRAM — hysteria2 itself sits around 40 MB
  RSS in practice, and the buffers are limits rather than reservations, so a
  64 MB box is fine for one node; from 128 MB up the installer grants the full
  16 MB UDP buffer ceiling

---

## ⚡ Performance notes

The installer tunes the host for long-RTT / high-BDP links. Stock settings
silently throttle a Hysteria2 server, which shows up as a *collapse* as soon as
more than one TCP flow shares the tunnel — a multi-connection speed test reads
~0 while a single download is fine.

- `/etc/sysctl.d/99-hysteria.conf` — UDP socket buffer ceiling, scaled to the
  machine's RAM (4 MB below 64 MB, 8 MB below 128 MB, 16 MB from 128 MB up).
  Linux defaults `net.core.rmem_max`/`wmem_max` to 208 KB, and anything QUIC
  asks for above that is silently capped, so a long-RTT connection keeps
  losing packets. These are limits, not reservations — idle cost is zero.
- `congestion: {type: bbr, bbrProfile: aggressive}` in the server config —
  upstream's recommendation for high bandwidth-delay products. Switch to
  `conservative` if `aggressive` misbehaves on your line.
- `quic: {init/maxStreamReceiveWindow, init/maxConnReceiveWindow}` — multi-MB
  receive windows so a single stream is not window-limited on a 100 ms+ RTT path.

How to verify after deploying: download a large file through the node with one
connection (baseline), then start 4-8 parallel downloads of the same file. The
parallel run should aggregate *more* than the single one, not collapse to near
zero. To revert: delete `/etc/sysctl.d/99-hysteria.conf` and drop the
`congestion` / `quic` blocks from `/usr/local/hysteria/config.yaml`.

---

## 🔗 AstraLink 一键导入链接

安装时「流量上报面板地址」填了 AstraLink 面板（例如 `astralink.lmx0125.top`）的话，
脚本除了开启流量上报与面板托管认证，还会在最后打印**一条可直接导入的分享链接**：

```
hysteria2://<密码>@<公网IP>:<端口>/?insecure=1&sni=<域名>&rk=<上报密钥>&pa=1#Hysteria2-<域名>
```

把这一整行复制到 AstraLink 后台 **节点管理 → 新建节点 → 分享链接**，点「创建节点」就行：
协议 / 地址 / 端口 / 参数会自动解析，`rk=`（流量上报密钥）与 `pa=1`（面板托管认证）也会
一并填好 —— 不用再手工复制 `NODE_KEY`，也不用记得去打开托管认证开关。
同一份内容还会写到节点的 `/usr/local/hysteria/astralink-node.txt`（权限 600），
安装输出滚屏之后（或重装、换机器时）可以 `cat` 出来再导入。

- `rk` / `pa` 是 AstraLink 专有查询参数，其它客户端（Hiddify / sing-box / Clash）会忽略它们，
  所以这条链接同时仍是一条能直接用的 hysteria2 分享链接。
- 不开流量上报（面板地址留空）时打印的是同一条链接，只是不带 `rk` / `pa`，
  就是一条普通 hysteria2 分享链接，粘贴导入的老流程照样可用。

---

## 🧠 Overview

This project includes all the main features needed to automatically deploy and manage a **Hysteria2** node on Linux.  
It aims to simplify setup for servers, VPS, or embedded systems.

---

## ⚙️ Installation

Run the following command to install and deploy:
(you need bash environment first)

If you are using alpine linux, you may run this command firstly.
```ash
apk add --no-cache bash
```
then
```bash
wget -qO- https://raw.githubusercontent.com/lmx0125/hysteria2-linux-setup/main/install.sh | bash
