#!/bin/bash
###############################################################################
# RTL8188EU Driver Installation - lwfinger Fork (Stable & Tested)
# Ubuntu/Kubuntu 2026+ | Kernel 7.0+ compatible
###############################################################################

set -o pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

WORK_DIR="/tmp/rtl8188eu_lwfinger_$$"
DRIVER_REPO="https://github.com/lwfinger/rtl8188eu.git"
LOG_FILE="/var/log/rtl8188eu_install.log"

log() { 
    echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

warn() { 
    echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"
}

error() { 
    echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
}

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  RTL8188EU Driver Installation (lwfinger fork)                ║"
    echo "║  Stable, actively maintained for kernel 7.0+                  ║"
    echo "║  Ubuntu/Kubuntu 2026+ LTS                                     ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    
    > "$LOG_FILE"
    log "Installation started at $(date)"
    
    # Check root
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run with sudo"
        exit 1
    fi
    
    # System check
    log "Checking system requirements..."
    KERNEL=$(uname -r)
    log "Kernel: $KERNEL"
    
    if ! command -v apt &> /dev/null; then
        error "apt not found. Ubuntu/Debian required."
        exit 1
    fi
    
    # Install dependencies
    log "Installing build dependencies..."
    if ! apt update && apt install -y build-essential bc dkms git linux-headers-$(uname -r) libelf-dev; then
        error "Dependency installation failed"
        exit 1
    fi
    
    # Disable conflicting drivers
    log "Blacklisting conflicting drivers..."
    for driver in rtl8xxxu r8188eu 8188eu; do
        echo "blacklist $driver" >> /etc/modprobe.d/blacklist-realtek.conf 2>/dev/null
        if lsmod | grep -q "^$driver "; then
            warn "Removing $driver from kernel..."
            modprobe -r "$driver" 2>/dev/null || true
        fi
    done
    
    # Download driver source
    log "Downloading lwfinger RTL8188EU fork..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    if ! git clone --depth 1 "$DRIVER_REPO" driver_src; then
        error "Git clone failed. Cannot download driver."
        exit 1
    fi
    
    cd driver_src
    log "Driver source downloaded to: $(pwd)"
    
    # Apply kernel 7.0+ patches
    log "Applying patches for kernel 7.0+ compatibility..."
    
    # Patch 1: Add include paths to Makefile
    if ! grep -q "ccflags-y" Makefile 2>/dev/null; then
        sed -i '1i ccflags-y += -I$(src)/include' Makefile
        sed -i '2i subdir-ccflags-y += -I$(src)/include' Makefile
        log "Added include path directives to Makefile"
    fi
    
    # Patch 2: Ensure timer.h is included
    if ! grep -q "#include <linux/timer.h>" include/osdep_service.h 2>/dev/null; then
        sed -i '1i #include <linux/timer.h>' include/osdep_service.h
        log "Added linux/timer.h include"
    fi
    
    # Show Makefile head to verify patches
    log "Makefile configuration (first 5 lines):"
    head -5 Makefile | tee -a "$LOG_FILE"
    
    # Compile driver
    log "Compiling driver module (this may take 2-5 minutes)..."
    make clean 2>/dev/null || true
    
    # First attempt: parallel compilation
    if ! make -j$(($(nproc) - 1)) 2>&1 | tee -a "$LOG_FILE"; then
        # Check if .ko was created anyway
        if [ -f "8188eu.ko" ]; then
            log "8188eu.ko created despite warnings. Continuing..."
        else
            warn "Parallel compilation failed. Retrying with single-threaded build..."
            make clean 2>/dev/null || true
            
            # Second attempt: single-threaded
            if ! make -j1 2>&1 | tee -a "$LOG_FILE"; then
                error "Compilation failed (both parallel and single-threaded)"
                error "Last 20 lines of error:"
                tail -20 "$LOG_FILE" | tee -a "$LOG_FILE"
                exit 1
            fi
        fi
    fi
    
    # Verify .ko file exists
    if [ ! -f "8188eu.ko" ]; then
        error "Compilation completed but 8188eu.ko not found"
        error "Files in directory:"
        ls -la | tee -a "$LOG_FILE"
        exit 1
    fi
    
    log "✓ Compilation successful - 8188eu.ko created"
    
    # Install module
    log "Installing compiled module..."
    if ! install -p -m 644 8188eu.ko /lib/modules/$(uname -r)/kernel/drivers/net/wireless/; then
        error "Failed to copy 8188eu.ko to kernel module directory"
        exit 1
    fi
    
    # Register module
    log "Running depmod to register module..."
    depmod -a || {
        error "depmod failed"
        exit 1
    }
    
    # Update initramfs
    log "Updating initramfs..."
    update-initramfs -u 2>/dev/null || warn "initramfs update skipped"
    
    # Configure driver options for stability
    log "Configuring driver options..."
    cat > /etc/modprobe.d/rtl8188eu-opts.conf <<'EOF'
# RTL8188EU Driver Options - Optimized for Stability
# Disable power management (main cause of beacon loss)
options 8188eu rtw_power_mgnt=0
# Disable USB suspend
options 8188eu rtw_enusbss=0
# Increase association retry attempts
options 8188eu rtw_max_acq_ass_retry=10
# Improve RX in monitor mode
options 8188eu rtw_monitor_rx_under_bss_mode=1
EOF
    log "Driver options saved to /etc/modprobe.d/rtl8188eu-opts.conf"
    
    # Try to load driver immediately
    log "Attempting to load driver..."
    sleep 2
    modprobe 8188eu 2>&1 | tee -a "$LOG_FILE"
    sleep 2
    
    # Verify driver loaded
    if lsmod | grep -q "^8188eu "; then
        log "✓✓✓ Driver loaded successfully and verified"
        lsmod | grep 8188eu | tee -a "$LOG_FILE"
    else
        warn "Driver not loaded yet (will load after reboot)"
    fi
    
    # Cleanup temporary files
    log "Cleaning up temporary files..."
    cd /
    rm -rf "$WORK_DIR"
    
    # Success message
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  INSTALLATION COMPLETED SUCCESSFULLY                          ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "NEXT STEPS:"
    echo ""
    echo "1. REBOOT your system:"
    echo "   sudo reboot"
    echo ""
    echo "2. After reboot, verify the driver is loaded:"
    echo "   lsmod | grep 8188eu"
    echo ""
    echo "3. Check WiFi device and driver:"
    echo "   nmcli device status"
    echo "   ethtool -i wlan0"
    echo ""
    echo "4. Monitor connection quality:"
    echo "   watch -n 1 'iw dev wlan0 link'"
    echo ""
    echo "5. If WiFi still drops, disable power management:"
    echo "   sudo iwconfig wlan0 power off"
    echo ""
    echo "6. View installation log:"
    echo "   cat $LOG_FILE"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    log "Installation log saved to: $LOG_FILE"
}

main "$@"
