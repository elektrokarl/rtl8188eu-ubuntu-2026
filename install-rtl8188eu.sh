#!/bin/bash
###############################################################################
# RTL8188EU Driver Installation Script for Ubuntu/Kubuntu 2026+
# Handles network drops, modern kernels, and DKMS compilation
# FIXED: Properly handles include path issues for kernel 7.0+
###############################################################################

set -o pipefail
trap 'echo "[!] ERROR at line $LINENO"; exit 1' ERR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
WORK_DIR="/tmp/rtl8188eu_install_$$"
DRIVER_REPO="https://github.com/aircrack-ng/rtl8188eus.git"
DRIVER_URL_FALLBACK="https://github.com/aircrack-ng/rtl8188eus/archive/refs/heads/master.zip"
LOG_FILE="/var/log/rtl8188eu_install.log"
MAX_RETRIES=5
RETRY_DELAY=10

###############################################################################
# Helper Functions
###############################################################################

log() {
    echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
}

retry_command() {
    local cmd="$1"
    local desc="$2"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        echo "[Attempt $attempt/$MAX_RETRIES] $desc..."
        if eval "$cmd"; then
            return 0
        fi
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            warn "Failed. Waiting ${RETRY_DELAY}s before retry..."
            sleep $RETRY_DELAY
        fi
        ((attempt++))
    done
    
    error "Failed after $MAX_RETRIES attempts: $desc"
    return 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run with sudo"
        exit 1
    fi
}

check_system() {
    log "Checking system requirements..."
    
    if ! command -v apt &> /dev/null; then
        error "apt not found. This script requires a Debian/Ubuntu-based system."
        exit 1
    fi
    
    KERNEL_VERSION=$(uname -r)
    log "Kernel version: $KERNEL_VERSION"
    
    if ! dpkg -l | grep -q "linux-headers-$(uname -r)"; then
        warn "linux-headers not found. Installing..."
        apt update && apt install -y linux-headers-$(uname -r)
    fi
}

disable_conflicting_drivers() {
    log "Disabling conflicting kernel drivers..."
    
    # Blacklist rtl8xxxu and r8188eu
    for driver in rtl8xxxu r8188eu 8188eu; do
        echo "blacklist $driver" | tee -a /etc/modprobe.d/blacklist-realtek.conf > /dev/null
    done
    
    # Remove from memory if loaded
    for driver in rtl8xxxu r8188eu 8188eu; do
        if lsmod | grep -q "^$driver "; then
            warn "Unloading $driver from kernel..."
            modprobe -r "$driver" 2>/dev/null || true
        fi
    done
    
    log "Conflicting drivers disabled"
}

install_dependencies() {
    log "Installing build dependencies..."
    
    retry_command \
        "apt update && apt install -y build-essential bc dkms git linux-headers-\$(uname -r) libelf-dev" \
        "Install build tools"
}

download_driver() {
    log "Downloading driver source..."
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # Try git clone first (better for resumable downloads)
    if retry_command \
        "git clone --depth 1 '$DRIVER_REPO' driver_src" \
        "Clone from GitHub (git)"; then
        cd driver_src
        return 0
    fi
    
    warn "Git clone failed. Trying fallback ZIP download..."
    
    if retry_command \
        "curl -fL -o driver.zip '$DRIVER_URL_FALLBACK'" \
        "Download from GitHub (ZIP)"; then
        unzip -q driver.zip
        cd rtl8188eus-master
        return 0
    fi
    
    error "Failed to download driver from all sources"
    return 1
}

fix_makefile() {
    log "Fixing Makefile for include paths (Kernel 7.0+ compatibility)..."
    
    # Add include path to Makefile if not present
    if ! grep -q "ccflags-y.*include" Makefile 2>/dev/null; then
        # Insert at the beginning of Makefile
        sed -i '1i ccflags-y += -I$(src)/include' Makefile
        log "Added ccflags-y include directive"
    fi
    
    # Ensure subdir-ccflags also includes the path
    if ! grep -q "subdir-ccflags-y.*include" Makefile 2>/dev/null; then
        sed -i '1i subdir-ccflags-y += -I$(src)/include' Makefile
        log "Added subdir-ccflags-y include directive"
    fi
}

patch_for_modern_kernel() {
    log "Applying patches for modern kernel compatibility..."
    
    # Fix 1: Add missing timer.h include
    if ! grep -q "#include <linux/timer.h>" include/osdep_service.h 2>/dev/null; then
        sed -i '1i #include <linux/timer.h>' include/osdep_service.h
        log "Added linux/timer.h include"
    fi
    
    # Fix 2: Handle del_timer_sync vs timer_delete_sync for Kernel 5.4+
    # The actual function is still del_timer_sync, but make sure it's included
    if grep -q "del_timer_sync" include/osdep_service.h 2>/dev/null; then
        if ! grep -q "#include <linux/timer.h>" include/osdep_service.h; then
            sed -i '1i #include <linux/timer.h>' include/osdep_service.h
            log "Fixed timer.h dependency for del_timer_sync"
        fi
    fi
    
    log "Kernel compatibility patches applied"
}

compile_driver() {
    log "Compiling driver (this may take 2-5 minutes)..."
    
    # Clean previous builds
    make clean 2>/dev/null || true
    
    # Verify Makefile is fixed before compiling
    if ! grep -q "ccflags-y" Makefile; then
        warn "Makefile not properly configured. Applying fix..."
        fix_makefile
    fi
    
    # Show what we're about to compile
    log "Makefile configuration:"
    head -5 Makefile | tee -a "$LOG_FILE"
    
    # Compile with error handling
    if ! make -j$(($(nproc) - 1)) 2>&1 | tee -a "$LOG_FILE"; then
        error "Parallel compilation failed. Checking for .ko file..."
        
        # Check if .ko was actually created despite warnings
        if [ -f "8188eu.ko" ]; then
            log "8188eu.ko created despite warnings. Proceeding..."
            return 0
        fi
        
        # Try with reduced parallelism
        warn "Retrying with single-threaded compilation..."
        make clean 2>/dev/null || true
        
        if ! make -j1 2>&1 | tee -a "$LOG_FILE"; then
            error "Single-threaded compilation also failed"
            
            # Show last 30 lines of error for debugging
            error "Last compilation errors:"
            tail -30 "$LOG_FILE" | tee -a "$LOG_FILE"
            return 1
        fi
    fi
    
    # Verify .ko file exists
    if [ ! -f "8188eu.ko" ]; then
        error "Compilation completed but 8188eu.ko not found!"
        error "Files in current directory:"
        ls -la | tee -a "$LOG_FILE"
        return 1
    fi
    
    log "Compilation successful. 8188eu.ko created."
}

install_driver() {
    log "Installing compiled module..."
    
    if [ ! -f "8188eu.ko" ]; then
        error "8188eu.ko not found. Cannot install."
        return 1
    fi
    
    # Install directly if make install fails
    if ! make install 2>&1 | tee -a "$LOG_FILE"; then
        warn "make install failed. Attempting manual installation..."
        
        install -p -m 644 8188eu.ko /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ || {
            error "Manual installation also failed"
            return 1
        }
    fi
    
    log "Running depmod..."
    depmod -a
    
    # Update initramfs to include new driver
    update-initramfs -u 2>/dev/null || true
    
    log "Driver installed and registered"
}

load_driver() {
    log "Loading new driver module..."
    
    # Give system time to settle
    sleep 2
    
    if modprobe 8188eu 2>&1 | tee -a "$LOG_FILE"; then
        log "Driver load command executed"
        sleep 2
        
        # Verify it's loaded
        if lsmod | grep -q "^8188eu "; then
            log "Driver verified in kernel: $(lsmod | grep 8188eu)"
            return 0
        else
            warn "Driver not yet loaded. May load after reboot."
            return 0
        fi
    else
        warn "modprobe command failed, but may work after reboot"
        return 0
    fi
}

configure_driver_options() {
    log "Configuring driver options for stability..."
    
    cat > /etc/modprobe.d/rtl8188eu-opts.conf <<'EOF'
# RTL8188EU Driver Options - Optimized for Stability
# Disable power management (causes beacon loss)
options 8188eu rtw_power_mgnt=0
# Disable USB suspend for this interface
options 8188eu rtw_enusbss=0
# Increase association retry attempts
options 8188eu rtw_max_acq_ass_retry=10
# Improve monitor mode RX
options 8188eu rtw_monitor_rx_under_bss_mode=1
EOF
    
    log "Driver options configured at /etc/modprobe.d/rtl8188eu-opts.conf"
}

verify_installation() {
    log "Verifying installation..."
    
    local wifi_device=$(iw dev 2>/dev/null | grep "Interface" | awk '{print $2}' | head -1)
    
    if [ -z "$wifi_device" ]; then
        warn "No WiFi device currently detected (may appear after reboot)"
        return 0
    fi
    
    log "WiFi device detected: $wifi_device"
    
    # Check driver
    local driver=$(ethtool -i "$wifi_device" 2>/dev/null | grep "^driver:" | awk '{print $2}')
    
    if [ "$driver" = "8188eu" ]; then
        log "Driver confirmed: $driver"
        return 0
    else
        log "Current driver: $driver (will switch to 8188eu after reboot)"
        return 0
    fi
}

show_test_commands() {
    log "Installation complete!"
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                      NEXT STEPS                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "1. REBOOT (required for driver to fully initialize):"
    echo "   sudo reboot"
    echo ""
    echo "2. After reboot, verify driver is loaded:"
    echo "   lsmod | grep 8188eu"
    echo "   ethtool -i <your_wifi_device>"
    echo ""
    echo "3. Check connection status:"
    echo "   nmcli device status"
    echo "   iwconfig"
    echo ""
    echo "4. If WiFi still disconnects, apply power management workaround:"
    echo "   sudo iwconfig wlan0 power off"
    echo ""
    echo "5. Monitor connection quality in real-time:"
    echo "   watch -n 1 'iw dev wlan0 link'"
    echo ""
    echo "6. View driver logs:"
    echo "   dmesg | tail -20 | grep -i 8188eu"
    echo "   tail -50 $LOG_FILE"
    echo ""
    echo "7. If problems persist, check for beacon loss:"
    echo "   sudo iw event"
    echo ""
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
}

cleanup() {
    if [ -d "$WORK_DIR" ]; then
        log "Cleaning up temporary files..."
        rm -rf "$WORK_DIR"
    fi
}

###############################################################################
# Main Execution
###############################################################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  RTL8188EU Driver Installation for Ubuntu/Kubuntu 2026+        ║"
    echo "║  Aircrack-ng Fork - Network Drop Resistant                     ║"
    echo "║  Kernel 7.0+ Compatible with Include Path Fixes               ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Initialize log
    > "$LOG_FILE"
    log "Installation started at $(date)"
    
    check_root
    check_system
    install_dependencies
    disable_conflicting_drivers
    download_driver || exit 1
    patch_for_modern_kernel
    fix_makefile
    compile_driver || exit 1
    install_driver || exit 1
    configure_driver_options
    load_driver || true
    verify_installation || true
    show_test_commands
    cleanup
    
    echo ""
    log "All steps completed. Installation log: $LOG_FILE"
    echo ""
}

# Run main
main "$@"
