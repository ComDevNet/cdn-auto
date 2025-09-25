<h1 align="center"> CDN Auto </h1>

> This is a tool to simplify some of the actions done on the CDN Server. It is designed to be run on a Raspberry Pi running the CDN Server but will still work on any Rachel OS. It is not designed to be run on a Windows machine. Do not run the install script on your machine.

<!-- Image -->
<p align="center">
  <img src="./img/shot.png" alt="Screenshot" width="600">
</p>

## Installation

```bash
git clone https://github.com/ComDevNet/cdn-auto.git
cd cdn-auto
chmod +x install.sh
./install.sh
```

## Usage

```bash
./main.sh
```

## Things Simplified

- [x] Update the system
- [x] Update the Rachel Interface
- [x] Update Script
- [x] Connect VPN
- [x] Check VPN Status
- [x] Change Interface (git branching)
- [x] System Configuration
- [x] Shutdown System
- [x] Reboot System
- [x] Collect Logs
- [x] Process Logs
- [x] Collect Content Request File
- [x] Disconnect from VPN Network
- [x] Change Wifi Name
- [x] Add wifi Password
- [x] Upload Data to Server
- [x] Troubleshoot System

---

## ⚙️ Automation

This project includes a powerful automation module for scheduling the entire log processing pipeline. It can be installed as a systemd service to run automatically, even when no user is logged in.

**[For full details, see the Automation Module Documentation](./scripts/data/automation/README.md)**
