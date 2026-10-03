#!/bin/bash

# Enable strict error handling, but allow controlled fallbacks
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}    FAIL-SAFE WI-FI RECOVERY & CLEANUP SCRIPT       ${NC}"
echo -e "${BLUE}=====================================================${NC}"

# ---------------------------------------------------------
# MITIGATION 1: Release Package Manager Locks Safely
# ---------------------------------------------------------
echo -e "\n${YELLOW}[1/7] Resolving Package Manager Locks...${NC}"
sudo systemctl unmask packagekit 2>/dev/null || true

if pgrep -x "packagekitd" > /dev/null; then
    PK_PID=$(pgrep -x "packagekitd")
    echo -e "${RED}Stopping packagekitd (PID: $PK_PID)...${NC}"
    sudo kill -9 $PK_PID 2>/dev/null || true
    sleep 1
fi

# Clean up stale locks if left behind
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true

# ---------------------------------------------------------
# MITIGATION 2: Purge Broken DKMS & Source Directories
# ---------------------------------------------------------
echo -e "${YELLOW}[2/7] Purging broken third-party DKMS installations...${NC}"
sudo dkms remove -m 8188eu -v 1.0 --all 2>/dev/null || true
sudo dkms remove -m rtl8188eu --all 2>/dev/null || true

sudo rm -rf /usr/src/8188eu* /usr/src/rtl8188eu* /var/lib/dkms/8188eu* 2>/dev/null || true
sudo rm -rf ~/rtl8188eu ~/rtl8188eus 2>/dev/null || true
echo -e "${GREEN}[OK] DKMS tree cleaned.${NC}"

# ---------------------------------------------------------
# MITIGATION 3: Remove All Driver Blacklists Globally
# ---------------------------------------------------------
echo -e "${YELLOW}[3/7] Searching and removing driver blacklists across /etc/modprobe.d/...${NC}"

# Specific known script files
sudo rm -f /etc/modprobe.d/blacklist-rtl8188.conf
sudo rm -f /etc/modprobe.d/blacklist-builtin-wifi.conf
sudo rm -f /etc/modprobe.d/blacklist-custom.conf

# Strip blacklists embedded inside other config files
TARGET_DRIVERS=("iwlwifi" "iwlmvm" "rtl8xxxu" "r8188eu" "8188eu")
for driver in "${TARGET_DRIVERS[@]}"; do
    MATCHES=$(grep -rl "blacklist $driver" /etc/modprobe.d/ 2>/dev/null || true)
    if [ -n "$MATCHES" ]; then
        echo -e "${RED}Removing blacklist entry for '$driver' from:${NC} $MATCHES"
        for file in $MATCHES; do
            sudo sed -i "/blacklist $driver/d" "$file"
        done
    fi
done
echo -e "${GREEN}[OK] Blacklists removed.${NC}"

# ---------------------------------------------------------
# MITIGATION 4: Verify & Install Linux Firmware Packages
# ---------------------------------------------------------
echo -e "${YELLOW}[4/7] Verifying core wireless firmware availability...${NC}"
sudo apt update -y
sudo apt install -y --reinstall linux-firmware wireless-regdb

# ---------------------------------------------------------
# MITIGATION 5: Reload Kernel Driver Modules Cleanly
# ---------------------------------------------------------
echo -e "${YELLOW}[5/7] Resetting and force-loading kernel modules...${NC}"
sudo depmod -a

# Unload dependent modules first to avoid 'module in use' lockups
sudo modprobe -r iwlmvm 2>/dev/null || true
sudo modprobe -r iwlwifi 2>/dev/null || true
sudo modprobe -r rtl8xxxu 2>/dev/null || true
sudo modprobe -r r8188eu 2>/dev/null || true

sleep 1

# Load clean kernel drivers
echo -e "Loading internal Intel Wi-Fi module (iwlwifi)..."
sudo modprobe iwlwifi || echo -e "${YELLOW}[WARN] Could not load iwlwifi${NC}"

echo -e "Loading USB Realtek Wi-Fi module (rtl8xxxu / r8188eu)..."
sudo modprobe rtl8xxxu 2>/dev/null || sudo modprobe r8188eu || echo -e "${YELLOW}[WARN] Native Realtek module not found${NC}"

# ---------------------------------------------------------
# MITIGATION 6: Reset NetworkManager Soft Blocks & States
# ---------------------------------------------------------
echo -e "${YELLOW}[6/7] Resetting NetworkManager radio switches and rfkill...${NC}"

# Unblock RF-kill
sudo rfkill unblock wifi 2>/dev/null || true
sudo rfkill unblock all 2>/dev/null || true

# Clear NetworkManager disabled state file if it turned Wi-Fi off persistently
NM_STATE="/var/lib/NetworkManager/NetworkManager.state"
if [ -f "$NM_STATE" ]; then
    sudo sed -i 's/WirelessEnabled=false/WirelessEnabled=true/g' "$NM_STATE"
fi

sudo systemctl restart NetworkManager
sleep 2

# Force NM soft-radio on
nmcli radio wifi on 2>/dev/null || true

# ---------------------------------------------------------
# MITIGATION 7: Rebuild Ramdisk (initramfs)
# ---------------------------------------------------------
echo -e "${YELLOW}[7/7] Updating initramfs to persist driver changes on boot...${NC}"
sudo update-initramfs -u -k "$(uname -r)"

# ---------------------------------------------------------
# VERIFICATION & SYSTEM DIAGNOSTICS
# ---------------------------------------------------------
echo -e "\n${BLUE}=====================================================${NC}"
echo -e "${BLUE}               SYSTEM DIAGNOSTIC RESULTS            ${NC}"
echo -e "${BLUE}=====================================================${NC}"

# 1. Check rfkill
echo -n "RFKILL Status: "
if rfkill list wifi | grep -q "blocked: yes"; then
    echo -e "${RED}[BLOCKED] Wi-Fi is soft or hard blocked! Press Fn + Wi-Fi key.${NC}"
else
    echo -e "${GREEN}[OK] Wi-Fi is unblocked.${NC}"
fi

# 2. Check loaded modules
echo -n "Active Drivers: "
LOADED=$(lsmod | grep -E "iwlwifi|rtl8xxxu|r8188eu" | awk '{print $1}' | tr '\n' ' ')
if [ -n "$LOADED" ]; then
    echo -e "${GREEN}[OK] Loaded ($LOADED)${NC}"
else
    echo -e "${RED}[FAIL] No Wi-Fi drivers active in memory.${NC}"
fi

# 3. Check Network Interfaces
echo -n "Network Interfaces: "
IFACES=$(ip link | grep -E "wlan|wlp" | awk -F: '{print $2}' | tr -d ' ')
if [ -n "$IFACES" ]; then
    echo -e "${GREEN}[OK] Found interfaces: $IFACES${NC}"
else
    echo -e "${YELLOW}[INFO] Interface pending full system reboot.${NC}"
fi

echo -e "${BLUE}=====================================================${NC}\n"
echo -e "${GREEN}Script execution finished! Please reboot your system now:${NC}"
echo -e "Run: ${RED}sudo reboot${NC}"
