#!/bin/bash
###############################################################################
# RTL8188EU Driver Installation Script for Ubuntu/Kubuntu 2026+
# Handles network drops, modern kernels, and DKMS compilation
# Uses Aircrack-ng fork for maximum stability
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

patch_for_modern_kernel() {
    log "Applying patches for modern kernel compatibility..."
    
    # Fix missing timer.h include (Kernel 5.4+)
    if ! grep -q "#include <linux/timer.h>" Makefile.defs 2>/dev/null; then
        sed -i '1i #include <linux/timer.h>' include/osdep_service.h 2>/dev/null || true
    fi
    
    # Handle del_timer_sync() issue in Kernel 7.0+
    if grep -r "del_timer_sync" include/ &>/dev/null; then
        warn "Applying timer API compatibility patch..."
        sed -i 's/del_timer_sync/timer_delete_sync/g' include/osdep_service.h 2>/dev/null || true
    fi
    
    log "Patches applied (or were not needed)"
}

compile_driver() {
    log "Compiling driver (this may take 2-5 minutes)..."
    
    # Clean previous builds
    make clean 2>/dev/null || true
    
    # Compile with error handling
    if ! make -j$(($(nproc) - 1)); then
        error "Compilation failed. Checking for known issues..."
        
        # Try with reduced parallelism
        warn "Retrying with single-threaded compilation..."
        if ! make clean && make -j1; then
            error "Compilation failed even with -j1"
            return 1
        fi
    fi
    
    log "Compilation successful"
}

install_driver() {
    log "Installing compiled module..."
    
    if ! make install; then
        error "Installation failed"
        return 1
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
    
    if modprobe 8188eu; then
        log "Driver loaded successfully"
        sleep 2
        
        # Verify it's loaded
        if lsmod | grep -q "^8188eu "; then
            log "Driver verified in kernel"
            return 0
        fi
    fi
    
    error "Failed to load driver"
    return 1
}

configure_driver_options() {
    log "Configuring driver options for stability..."
    
    cat > /etc/modprobe.d/rtl8188eu-opts.conf <<EOF
# RTL8188EU Driver Options - Optimized for Stability
options 8188eu rtw_power_mgnt=0
options 8188eu rtw_enusbss=0
options 8188eu rtw_max_acq_ass_retry=10
options 8188eu rtw_monitor_rx_under_bss_mode=1
EOF
    
    log "Driver options configured"
}

verify_installation() {
    log "Verifying installation..."
    
    local wifi_device=$(iw dev | grep "Interface" | awk '{print $2}' | head -1)
    
    if [ -z "$wifi_device" ]; then
        error "No WiFi device found!"
        return 1
    fi
    
    log "WiFi device detected: $wifi_device"
    
    # Check driver
    local driver=$(ethtool -i "$wifi_device" 2>/dev/null | grep "^driver:" | awk '{print $2}')
    
    if [ "$driver" = "8188eu" ]; then
        log "Driver confirmed: $driver"
        return 0
    else
        warn "Driver mismatch. Got: $driver (expected: 8188eu)"
        return 1
    fi
}

show_test_commands() {
    log "Installation complete!"
    echo ""
    echo "======== Next Steps ========"
    echo ""
    echo "1. REBOOT (required for driver to fully initialize):"
    echo "   sudo reboot"
    echo ""
    echo "2. After reboot, test connection with:"
    echo "   nmcli device status"
    echo "   iwconfig"
    echo ""
    echo "3. If WiFi disconnects, apply power management workaround:"
    echo "   sudo iwconfig wlan0 power off"
    echo ""
    echo "4. Monitor connection quality:"
    echo "   watch -n 1 'iw dev wlan0 link'"
    echo ""
    echo "5. View driver logs:"
    echo "   dmesg | grep -i 8188eu"
    echo "   tail -f $LOG_FILE"
    echo ""
    echo "============================"
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
    compile_driver || exit 1
    install_driver || exit 1
    configure_driver_options
    load_driver || exit 1
    verify_installation || warn "Verification incomplete (may succeed after reboot)"
    show_test_commands
    cleanup
    
    echo ""
    log "All steps completed. Installation log: $LOG_FILE"
    echo ""
}

# Run main
main "$@"
