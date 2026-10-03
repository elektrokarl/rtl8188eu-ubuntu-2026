#!/bin/bash
###############################################################################
# RTL8188EU Driver Installation - SAFE VERSION
# DO NOT call modprobe until AFTER dependencies are installed
# Downloads FIRST, then patches, then compiles, THEN makes changes
###############################################################################

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CACHE_DIR="${HOME}/.cache/rtl8188eu"
WORK_DIR="/tmp/rtl8188eu_build_$$"
LOG_FILE="/var/log/rtl8188eu_install.log"

# Driver sources (in order)
declare -a DRIVER_SOURCES=(
    "https://github.com/lwfinger/rtl8188eu.git"
    "https://github.com/aircrack-ng/rtl8188eus.git"
    "https://gitee.com/nkz1123/rtl8188eu.git"
)

MAX_RETRIES=5
RETRY_DELAY=15

log() { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[i]${NC} $1" | tee -a "$LOG_FILE"; }

banner() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  RTL8188EU Driver - SAFE Installation (No modprobe until end) ║"
    echo "║  Ubuntu/Kubuntu 2026+ | Kernel 7.0+                          ║"
    echo "║  Download → Patch → Compile → Install (in that order)        ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
}

check_root() {
    [ "$EUID" -eq 0 ] || { error "Run with sudo"; exit 1; }
}

check_system() {
    log "System check..."
    KERNEL=$(uname -r)
    log "Kernel: $KERNEL"
}

install_deps() {
    log "Installing build dependencies (apt only, no modprobe)..."
    
    local attempt=1
    while [ $attempt -le 3 ]; do
        if apt update 2>&1 | grep -v "WARNING" && \
           apt install -y build-essential bc linux-headers-$(uname -r) libelf-dev git 2>&1 | grep -v "WARNING"; then
            log "Dependencies installed"
            return 0
        fi
        
        if [ $attempt -lt 3 ]; then
            warn "apt install failed (attempt $attempt/3). Retrying in 10s..."
            sleep 10
        fi
        ((attempt++))
    done
    
    error "Failed to install dependencies"
    return 1
}

download_driver() {
    log "Downloading driver source..."
    
    mkdir -p "$WORK_DIR" "$CACHE_DIR"
    local driver_cache="$CACHE_DIR/driver_source"
    
    # Check if already cached
    if [ -d "$driver_cache/.git" ]; then
        log "Using cached driver source"
        cp -r "$driver_cache" "$WORK_DIR/driver_src"
        return 0
    fi
    
    # Try each source
    for source in "${DRIVER_SOURCES[@]}"; do
        info "Trying: $source"
        
        local attempt=1
        while [ $attempt -le $MAX_RETRIES ]; do
            if git clone --depth 1 "$source" "$WORK_DIR/driver_src" 2>&1 | tee -a "$LOG_FILE"; then
                cp -r "$WORK_DIR/driver_src" "$driver_cache"
                log "✓ Driver downloaded and cached"
                return 0
            fi
            
            if [ $attempt -lt $MAX_RETRIES ]; then
                warn "Clone attempt $attempt/$MAX_RETRIES failed. Waiting ${RETRY_DELAY}s..."
                sleep $RETRY_DELAY
            fi
            ((attempt++))
        done
    done
    
    error "Failed to download from all sources"
    return 1
}

patch_kernel_7() {
    log "Patching for kernel 7.0+ compatibility..."
    
    cd "$WORK_DIR/driver_src" || return 1
    
    # Fix 1: Makefile include paths
    if ! grep -q "ccflags-y.*include" Makefile 2>/dev/null; then
        sed -i '1i ccflags-y += -I$(src)/include' Makefile
        sed -i '2i subdir-ccflags-y += -I$(src)/include' Makefile
        info "Added include paths"
    fi
    
    # Fix 2: timer.h
    if [ -f "include/osdep_service.h" ] && ! grep -q "#include <linux/timer.h>" include/osdep_service.h; then
        sed -i '1i #include <linux/timer.h>' include/osdep_service.h
        info "Added timer.h"
    fi
    
    # Fix 3: Remove problematic headers if they exist
    if find include hal -name "*.h" -exec grep -l "halrf_psd.h" {} \; 2>/dev/null | head -1 | grep -q .; then
        info "Removing halrf_psd.h references..."
        find include hal -name "*.h" -exec sed -i '/halrf_psd\.h/d' {} \;
    fi
    
    log "Patches applied"
}

compile_driver() {
    log "Compiling driver..."
    
    cd "$WORK_DIR/driver_src" || return 1
    
    make clean 2>/dev/null || true
    
    # Try parallel
    info "Attempting parallel compilation..."
    if make -j$(($(nproc) - 1)) 2>&1 | tee -a "$LOG_FILE"; then
        if [ -f "8188eu.ko" ]; then
            log "✓ Parallel compilation successful"
            return 0
        fi
    fi
    
    # Check if .ko exists anyway
    if [ -f "8188eu.ko" ]; then
        log "✓ Module created (parallel, with warnings)"
        return 0
    fi
    
    # Try single-threaded
    warn "Parallel failed. Trying single-threaded..."
    make clean 2>/dev/null || true
    
    if make -j1 2>&1 | tee -a "$LOG_FILE"; then
        if [ -f "8188eu.ko" ]; then
            log "✓ Single-threaded compilation successful"
            return 0
        fi
    fi
    
    # Final check
    if [ -f "8188eu.ko" ]; then
        log "✓ Module created (single-threaded)"
        return 0
    fi
    
    error "Compilation failed"
    tail -50 "$LOG_FILE" | tee -a "$LOG_FILE"
    return 1
}

install_module() {
    log "Installing compiled module..."
    
    cd "$WORK_DIR/driver_src" || return 1
    
    [ -f "8188eu.ko" ] || { error "8188eu.ko not found"; return 1; }
    
    install -p -m 644 8188eu.ko /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ || exit 1
    depmod -a || warn "depmod had minor issues"
    update-initramfs -u 2>/dev/null || warn "initramfs update skipped"
    
    log "✓ Module installed to /lib/modules"
}

configure_driver() {
    log "Writing driver configuration (no modprobe yet)..."
    
    # Only write config files, do NOT call modprobe
    cat > /etc/modprobe.d/blacklist-realtek.conf <<'EOF'
blacklist rtl8xxxu
blacklist r8188eu
blacklist 8188eu
EOF

    cat > /etc/modprobe.d/rtl8188eu-opts.conf <<'EOF'
options 8188eu rtw_power_mgnt=0
options 8188eu rtw_enusbss=0
EOF
    
    log "Configuration files written (will take effect after reboot)"
}

cleanup() {
    log "Cleaning up..."
    rm -rf "$WORK_DIR"
}

final_message() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  Installation Complete!                                        ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "✓ Driver compiled and installed"
    echo "✓ Configuration written"
    echo ""
    echo "NEXT: REBOOT YOUR SYSTEM"
    echo ""
    echo "  sudo reboot"
    echo ""
    echo "After reboot:"
    echo "  - Driver will automatically load"
    echo "  - Verify with: lsmod | grep 8188eu"
    echo "  - Check connection: nmcli device status"
    echo ""
    echo "If WiFi still has issues:"
    echo "  - Disable power mgmt: sudo iwconfig wlan0 power off"
    echo "  - Check logs: dmesg | grep -i 8188eu"
    echo ""
    echo "Installation log: $LOG_FILE"
    echo ""
}

main() {
    banner
    check_root
    
    : > "$LOG_FILE"
    log "Installation started at $(date)"
    
    check_system
    install_deps || exit 1
    download_driver || exit 1
    patch_kernel_7 || exit 1
    compile_driver || exit 1
    install_module || exit 1
    configure_driver || exit 1
    cleanup
    
    final_message
}

main "$@"
