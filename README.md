<h1 align="center"> Rachel Auto Tool </h1>

> This is a tool to automate some of the basic tasks done on the Rachel Pi. It is designed to be run on a Raspberry Pi running the CDN Rachel but will still work on any Rachel OS. It is not designed to be run on a Windows machine.

## Installation
```
git clone https://github.com/ComDevNet/rachel-auto-tool.git
cd rachel-auto-tool
chmod +x install.sh
./install.sh
``` 

## Usage
```
./main.sh
```
## Things Automated
- [x] Update the system
- [x] Update the Rachel Interface
- [x] Connect VPN
- [x] Check VPN Status
- [x] Download Logs
- [x] Update Script
- [ ] Process Logs -> (Download Logs v2)
- [ ] Upload Logs to Server