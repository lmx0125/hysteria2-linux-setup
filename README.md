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

## 🔗 AstraLink import link

If you entered an AstraLink panel address (e.g. `astralink.lmx0125.top`) when the installer asked for
the traffic-reporting endpoint, the script also turns on traffic reporting and panel-managed auth —
and prints **a single share link you can import as-is** once it finishes:

```
hysteria2://<password>@<public-ip>:<port>/?insecure=1&sni=<domain>&rk=<report-key>&pa=1#Hysteria2-<domain>
```

Paste that whole line into AstraLink → **Nodes → New node → Share link** and create the node:
the protocol, address, port and parameters are parsed from the link, and `rk=` (the traffic-report
key) plus `pa=1` (panel-managed auth) are filled in as well — no copying `NODE_KEY` by hand, no
remembering to flip the auth switch. The same string is written to
`/usr/local/hysteria/astralink-node.txt` (mode 600) on the node, so you can `cat` it later if the
install output has scrolled away, or when reinstalling or moving to another machine.

- `rk` and `pa` are AstraLink-specific query parameters. Other clients (Hiddify / sing-box / Clash)
  ignore unknown parameters, so the line still works as an ordinary hysteria2 share link.
- With traffic reporting off (panel address left empty) the installer prints the same line minus
  `rk` / `pa`: a plain hysteria2 share link, so the old paste-to-import flow keeps working.

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
