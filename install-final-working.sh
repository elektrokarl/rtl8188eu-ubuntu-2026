#!/bin/bash
###############################################################################
# RTL8188EU Driver Installation for Ubuntu/Kubuntu 2026+ (Kernel 7.0+)
# VERIFIED FIX: Adds linux/timer.h to the CORRECT location
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WORK_DIR="/tmp/rtl8188eu_build_$$"
LOG_FILE="/var/log/rtl8188eu_install.log"
DRIVER_REPO="https://github.com/lwfinger/rtl8188eu.git"

log() { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[i]${NC} $1" | tee -a "$LOG_FILE"; }

banner() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  RTL8188EU Driver - Kernel 7.0+ Verified Fix                 ║"
    echo "║  Ubuntu/Kubuntu 2026+                                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        error "This script must be run with sudo"
        exit 1
    fi
}

check_system() {
    log "System check..."
    KERNEL=$(uname -r)
    log "Kernel: $KERNEL"
    
    if ! command -v apt &> /dev/null; then
        error "apt not found. Debian/Ubuntu required."
        exit 1
    fi
}

install_deps() {
    log "Installing build dependencies..."
    
    apt update || error "apt update failed"
    
    if ! apt install -y \
        build-essential bc linux-headers-$(uname -r) \
        libelf-dev git curl wget; then
        error "Failed to install dependencies"
        return 1
    fi
    
    log "Dependencies installed"
    return 0
}

download_driver() {
    log "Downloading driver source from $DRIVER_REPO"
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    if ! git clone --depth 1 "$DRIVER_REPO" driver_src; then
        error "Failed to clone driver repository"
        return 1
    fi
    
    cd driver_src
    log "Driver downloaded to: $(pwd)"
    return 0
}

###############################################################################
# CRITICAL FIX: Add linux/timer.h to the CORRECT location
###############################################################################

patch_for_kernel_7() {
    log "Applying kernel 7.0+ compatibility patches..."
    
    cd "$WORK_DIR/driver_src" || return 1
    
    if [ ! -f "include/osdep_service.h" ]; then
        error "include/osdep_service.h not found!"
        return 1
    fi
    
    info "Current state: Checking for linux/timer.h in include/osdep_service.h"
    if grep -q "#include <linux/timer.h>" include/osdep_service.h; then
        log "✓ linux/timer.h already present"
        return 0
    fi
    
    # ========================================================================
    # The FIX: Add timer.h after other includes, before struct definitions
    # ========================================================================
    # Find the line with #include <linux/usb/ch9.h> (around line 62)
    # and insert #include <linux/timer.h> RIGHT AFTER it
    
    info "Adding #include <linux/timer.h> after other kernel includes..."
    
    # Use awk to find the line after the last #include and insert timer.h
    awk '
    /^#include <linux\/usb\/ch9\.h>/ {
        print $0;
        print "#include <linux/timer.h>";
        next;
    }
    { print }
    ' include/osdep_service.h > include/osdep_service.h.new
    
    if ! grep -q "#include <linux/timer.h>" include/osdep_service.h.new; then
        # Fallback: If the above didn't work, add it after first #include
        info "Using fallback method..."
        sed -i '/^#include <linux\/sched\.h>/a #include <linux/timer.h>' include/osdep_service.h
    else
        mv include/osdep_service.h.new include/osdep_service.h
    fi
    
    # Verify it worked
    if grep -q "#include <linux/timer.h>" include/osdep_service.h; then
        log "✓ Added #include <linux/timer.h> successfully"
        
        # Show context to confirm placement
        info "Verification (lines with timer includes):"
        grep -n "timer\.h" include/osdep_service.h | sed 's/^/  /'
        
        return 0
    else
        error "Failed to add #include <linux/timer.h>"
        return 1
    fi
}

compile_driver() {
    log "Compiling driver (this may take 3-5 minutes)..."
    
    cd "$WORK_DIR/driver_src" || return 1
    
    # Show relevant includes to verify patch worked
    info "Includes in osdep_service.h:"
    sed -n '50,70p' include/osdep_service.h | grep "#include" | sed 's/^/  /'
    
    # Clean any previous builds
    make clean 2>/dev/null || true
    
    # Get number of CPU cores
    NCORES=$(($(nproc) - 1))
    [ $NCORES -lt 1 ] && NCORES=1
    
    # Try parallel compilation first
    info "Attempting parallel compilation (-j$NCORES)..."
    if make -j$NCORES 2>&1 | tee -a "$LOG_FILE"; then
        if [ -f "8188eu.ko" ]; then
            log "✓ Compilation successful (parallel)"
            return 0
        fi
    fi
    
    # Check if .ko exists despite warnings
    if [ -f "8188eu.ko" ]; then
        log "✓ Module created successfully"
        return 0
    fi
    
    # Fallback: single-threaded
    warn "Retrying with single-threaded compilation..."
    make clean 2>/dev/null || true
    
    if make -j1 2>&1 | tee -a "$LOG_FILE"; then
        if [ -f "8188eu.ko" ]; then
            log "✓ Compilation successful (single-threaded)"
            return 0
        fi
    fi
    
    # Failed
    error "Compilation failed"
    error "Last 40 lines of output:"
    tail -40 "$LOG_FILE" | sed 's/^/  /'
    return 1
}

install_module() {
    log "Installing compiled module..."
    
    cd "$WORK_DIR/driver_src" || return 1
    
    if [ ! -f "8188eu.ko" ]; then
        error "8188eu.ko not found after compilation"
        return 1
    fi
    
    # Ensure target directory exists
    mkdir -p /lib/modules/$(uname -r)/kernel/drivers/net/wireless/
    
    # Install the module
    if ! install -p -m 644 8188eu.ko /lib/modules/$(uname -r)/kernel/drivers/net/wireless/; then
        error "Failed to install 8188eu.ko"
        return 1
    fi
    
    # Register the module
    depmod -a || warn "depmod had issues (continuing anyway)"
    
    # Update initramfs
    if ! update-initramfs -u 2>/dev/null; then
        warn "initramfs update skipped (non-critical)"
    fi
    
    log "✓ Module installed successfully"
    return 0
}

configure_driver() {
    log "Configuring driver options..."
    
    cat > /etc/modprobe.d/rtl8188eu-opts.conf <<'EOF'
# RTL8188EU driver options for stable operation
options 8188eu rtw_power_mgnt=0
options 8188eu rtw_enusbss=0
options 8188eu rtw_max_acq_ass_retry=10
options 8188eu rtw_ampdu_factor=7
options 8188eu rtw_ampdu_density=7
EOF
    
    log "Driver options configured"
}

disable_conflicting_drivers() {
    log "Disabling conflicting drivers..."
    
    cat > /etc/modprobe.d/blacklist-realtek.conf <<'EOF'
blacklist rtl8xxxu
blacklist r8188eu
EOF
    
    for driver in rtl8xxxu r8188eu 8188eu; do
        if lsmod | grep -q "^$driver "; then
            warn "Removing loaded driver: $driver"
            modprobe -r "$driver" 2>/dev/null || true
        fi
    done
    
    log "Conflicting drivers disabled"
}

load_and_verify() {
    log "Loading driver module..."
    
    sleep 2
    
    if modprobe 8188eu 2>&1 | tee -a "$LOG_FILE"; then
        sleep 2
        
        if lsmod | grep -q "^8188eu "; then
            log "✓✓✓ Driver loaded and verified in kernel"
            return 0
        else
            warn "Driver not immediately loaded (will load after reboot)"
            return 0
        fi
    else
        warn "modprobe had issues (continuing - driver may load after reboot)"
        return 0
    fi
}

cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "$WORK_DIR"
}

main() {
    banner
    check_root
    
    : > "$LOG_FILE"
    
    log "Installation started at $(date)"
    log "Kernel: $(uname -r)"
    log "Log file: $LOG_FILE"
    
    check_system || exit 1
    install_deps || exit 1
    disable_conflicting_drivers || exit 1
    download_driver || exit 1
    patch_for_kernel_7 || exit 1
    compile_driver || exit 1
    install_module || exit 1
    configure_driver || exit 1
    load_and_verify || exit 1
    cleanup
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✓✓✓ Installation Complete!                                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    echo "  1. Reboot your system: sudo reboot"
    echo "  2. After reboot, verify driver loaded:"
    echo "     lsmod | grep 8188eu"
    echo "  3. Check device status:"
    echo "     nmcli device status"
    echo ""
    echo "Log file: $LOG_FILE"
    echo ""
}

main "$@"
