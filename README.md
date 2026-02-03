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

---

## 📦 Requirements

- **Linux VPS**
- **Root access** (or sudo)
- Internet connection
- At least 64M (128M recommend) of DRAM

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
