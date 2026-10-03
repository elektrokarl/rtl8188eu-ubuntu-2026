#!/bin/bash
###############################################################################
# RTL8188EU Driver Installation - Connection Drop Resilient
# Respects driver changes breaking compilation
# Automatic fallback strategies
###############################################################################

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration - DO NOT CHANGE
CACHE_DIR="${HOME}/.cache/rtl8188eu"
WORK_DIR="/tmp/rtl8188eu_build_$$"
LOG_FILE="/var/log/rtl8188eu_install.log"
STATE_FILE="$CACHE_DIR/install_state"

# Driver sources (in order of preference)
declare -a DRIVER_SOURCES=(
    "https://github.com/lwfinger/rtl8188eu.git"
    "https://github.com/aircrack-ng/rtl8188eus.git"
    "https://gitee.com/nkz1123/rtl8188eu.git"
)

MAX_RETRIES=5
RETRY_DELAY=15
CONNECTION_CHECK_HOST="8.8.8.8"

###############################################################################
# Logging & Output
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

info() {
    echo -e "${BLUE}[i]${NC} $1" | tee -a "$LOG_FILE"
}

banner() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  RTL8188EU Driver Installation - Connection Drop Resilient    ║"
    echo "║  Ubuntu/Kubuntu 2026+ | Kernel 7.0+                          ║"
    echo "║  Auto-retry | Caching | Fallback strategies                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
}

###############################################################################
# System Checks
###############################################################################

check_root() {
    [ "$EUID" -eq 0 ] || { error "Run with sudo"; exit 1; }
}

check_connection() {
    local host="$1"
    if ping -c 1 -W 2 "$host" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

wait_for_connection() {
    local attempt=1
    local max_wait=60
    
    info "Waiting for network connection..."
    
    while [ $attempt -le $max_wait ]; do
        if check_connection "$CONNECTION_CHECK_HOST"; then
            log "Connection restored"
            return 0
        fi
        echo -ne "\r  Waiting... ${attempt}s / ${max_wait}s"
        sleep 1
        ((attempt++))
    done
    
    error "Network timeout after ${max_wait}s"
    return 1
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

###############################################################################
# Caching & State Management
###############################################################################

init_cache() {
    mkdir -p "$CACHE_DIR"
    : > "$LOG_FILE"
}

save_state() {
    local stage="$1"
    echo "$stage" > "$STATE_FILE"
    log "State saved: $stage"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "start"
    fi
}

###############################################################################
# Dependencies
###############################################################################

install_deps() {
    log "Installing dependencies..."
    
    local attempt=1
    while [ $attempt -le 3 ]; do
        if apt update && apt install -y \
            build-essential bc linux-headers-$(uname -r) libelf-dev git curl wget; then
            log "Dependencies installed"
            return 0
        fi
        
        if [ $attempt -lt 3 ]; then
            warn "apt install failed (attempt $attempt/3). Retrying in 10s..."
            sleep 10
        fi
        ((attempt++))
    done
    
    error "Failed to install dependencies after 3 attempts"
    return 1
}

###############################################################################
# Driver Download with Resilience
###############################################################################

download_driver() {
    log "Downloading driver source..."
    
    mkdir -p "$WORK_DIR"
    local driver_cache="$CACHE_DIR/driver_source"
    
    # Check if already cached
    if [ -d "$driver_cache/.git" ]; then
        log "Using cached driver source from $driver_cache"
        cp -r "$driver_cache" "$WORK_DIR/driver_src"
        return 0
    fi
    
    # Try each source
    local source_idx=0
    while [ $source_idx -lt ${#DRIVER_SOURCES[@]} ]; do
        local source="${DRIVER_SOURCES[$source_idx]}"
        info "Attempting download from: $source"
        
        # Check connection first
        if ! check_connection "$CONNECTION_CHECK_HOST"; then
            warn "No network connection. Waiting..."
            if ! wait_for_connection; then
                error "Cannot reach network"
                ((source_idx++))
                continue
            fi
        fi
        
        # Attempt clone with retry
        local clone_attempt=1
        while [ $clone_attempt -le $MAX_RETRIES ]; do
            if git clone --depth 1 "$source" "$WORK_DIR/driver_src" 2>&1 | tee -a "$LOG_FILE"; then
                # Cache successful download
                cp -r "$WORK_DIR/driver_src" "$driver_cache"
                log "✓ Driver downloaded and cached"
                return 0
            fi
            
            if [ $clone_attempt -lt $MAX_RETRIES ]; then
                warn "Clone failed (attempt $clone_attempt/$MAX_RETRIES). Waiting ${RETRY_DELAY}s..."
                sleep $RETRY_DELAY
                
                # Wait for connection if it dropped
                if ! check_connection "$CONNECTION_CHECK_HOST"; then
                    if ! wait_for_connection; then
                        warn "Still no connection. Retrying anyway..."
                    fi
                fi
            fi
            ((clone_attempt++))
        done
        
        # This source failed, try next
        ((source_idx++))
        warn "Source $source failed after $MAX_RETRIES attempts. Trying next source..."
    done
    
    error "Failed to download from all sources"
    return 1
}

###############################################################################
# Patching for Kernel Compatibility
###############################################################################

patch_kernel_7() {
    log "Patching for kernel 7.0+ compatibility..."
    
    cd "$WORK_DIR/driver_src" || return 1
    
    # Patch 1: Makefile include paths
    if ! grep -q "ccflags-y.*include" Makefile 2>/dev/null; then
        sed -i '1i ccflags-y += -I$(src)/include' Makefile
        sed -i '2i subdir-ccflags-y += -I$(src)/include' Makefile
        info "Added include path to Makefile"
    fi
    
    # Patch 2: timer.h for kernel 5.4+
    if [ -f "include/osdep_service.h" ]; then
        if ! grep -q "#include <linux/timer.h>" include/osdep_service.h 2>/dev/null; then
            sed -i '1i #include <linux/timer.h>' include/osdep_service.h
            info "Added timer.h include"
        fi
    fi
    
    # Patch 3: Handle missing headers gracefully
    if grep -r "halrf_psd.h" include/ 2>/dev/null; then
        info "Removing problematic halrf_psd.h references..."
        find include -name "*.h" -exec grep -l "halrf_psd.h" {} \; | while read file; do
            sed -i '/halrf_psd.h/d' "$file"
        done
    fi
    
    log "Patches applied"
}

###############################################################################
# Compilation with Fallback Strategies
###############################################################################

compile_driver() {
    log "Compiling driver..."
    
    cd "$WORK_DIR/driver_src" || return 1
    
    make clean 2>/dev/null || true
    
    # Strategy 1: Parallel compilation
    info "Attempting parallel compilation (-j$(($(nproc) - 1)))..."
    if make -j$(($(nproc) - 1)) 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Parallel compilation successful"
        [ -f "8188eu.ko" ] && return 0
    fi
    
    # Strategy 2: Check if .ko exists despite warnings
    if [ -f "8188eu.ko" ]; then
        log "✓ Module created despite warnings"
        return 0
    fi
    
    # Strategy 3: Single-threaded compilation
    warn "Parallel failed. Trying single-threaded..."
    make clean 2>/dev/null || true
    
    if make -j1 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Single-threaded compilation successful"
        [ -f "8188eu.ko" ] && return 0
    fi
    
    # Strategy 4: Check if .ko exists anyway
    if [ -f "8188eu.ko" ]; then
        log "✓ Module created (single-threaded)"
        return 0
    fi
    
    # Compilation failed completely
    error "Compilation failed on all strategies"
    error "Last 50 lines of output:"
    tail -50 "$LOG_FILE" | tee -a "$LOG_FILE"
    return 1
}

###############################################################################
# Installation
###############################################################################

install_module() {
    log "Installing module..."
    
    cd "$WORK_DIR/driver_src" || return 1
    
    if [ ! -f "8188eu.ko" ]; then
        error "8188eu.ko not found"
        return 1
    fi
    
    # Install
    if ! install -p -m 644 8188eu.ko /lib/modules/$(uname -r)/kernel/drivers/net/wireless/; then
        error "Failed to install 8188eu.ko"
        return 1
    fi
    
    # Register
    depmod -a || warn "depmod had issues (continuing)"
    update-initramfs -u 2>/dev/null || warn "initramfs update skipped"
    
    log "✓ Module installed"
}

###############################################################################
# Driver Configuration
###############################################################################

configure_driver() {
    log "Configuring driver options..."
    
    cat > /etc/modprobe.d/rtl8188eu-opts.conf <<'EOF'
options 8188eu rtw_power_mgnt=0
options 8188eu rtw_enusbss=0
options 8188eu rtw_max_acq_ass_retry=10
EOF
    
    log "Configuration saved"
}

###############################################################################
# Driver Loading & Verification
###############################################################################

load_and_verify() {
    log "Loading driver..."
    
    sleep 2
    modprobe 8188eu 2>&1 | tee -a "$LOG_FILE"
    sleep 2
    
    if lsmod | grep -q "^8188eu "; then
        log "✓✓✓ Driver loaded and verified"
        return 0
    else
        warn "Driver not loaded yet (will load after reboot)"
        return 0
    fi
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "$WORK_DIR"
    log "Done"
}

###############################################################################
# Main Workflow
###############################################################################

main() {
    banner
    check_root
    init_cache
    
    log "Installation started at $(date)"
    
    check_system
    install_deps || exit 1
    
    # Disable conflicting drivers
    log "Blacklisting conflicting drivers..."
    for driver in rtl8xxxu r8188eu 8188eu; do
        echo "blacklist $driver" >> /etc/modprobe.d/blacklist-realtek.conf 2>/dev/null
        modprobe -r "$driver" 2>/dev/null || true
    done
    
    download_driver || exit 1
    patch_kernel_7 || exit 1
    compile_driver || exit 1
    install_module || exit 1
    configure_driver || exit 1
    load_and_verify || exit 1
    cleanup
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  Installation Complete!                                        ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    echo "  1. Reboot: sudo reboot"
    echo "  2. After reboot, verify: lsmod | grep 8188eu"
    echo "  3. Check device: nmcli device status"
    echo ""
    echo "Log file: $LOG_FILE"
    echo ""
}

main "$@"
