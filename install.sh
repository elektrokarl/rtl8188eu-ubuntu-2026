#!/bin/bash
###############################################################################
# RTL8188EU Driver Installation - Kernel 7.0+ - PATCH-BASED FIX
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WORK_DIR="/tmp/rtl8188eu_$$"
LOG_FILE="/var/log/rtl8188eu_install.log"

log() { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1" | tee -a "$LOG_FILE"; }

banner() {
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║  RTL8188EU Driver - Kernel 7.0+                             ║
║  Patch-based fix: EXTRA_CFLAGS & del_timer_sync              ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

[ "$EUID" -eq 0 ] || { error "Run with sudo"; }

: > "$LOG_FILE"
banner

log "Started: $(date)"
log "Kernel: $(uname -r)"

# ============================================================================
# STEP 1: Install Build Dependencies
# ============================================================================
log "Installing dependencies..."
apt update >/dev/null 2>&1
apt install -y build-essential bc linux-headers-$(uname -r) libelf-dev git curl patch >/dev/null 2>&1
log "Dependencies ready"

# ============================================================================
# STEP 2: DOWNLOAD DRIVER SOURCE FIRST (WiFi still alive)
# ============================================================================
log "Downloading driver source..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if git clone --depth 1 https://github.com/lwfinger/rtl8188eu.git driver_src 2>/dev/null; then
    log "Downloaded via git"
elif curl -sL https://github.com/lwfinger/rtl8188eu/archive/refs/heads/master.zip -o driver.zip 2>/dev/null; then
    log "Downloaded via ZIP"
    unzip -q driver.zip 2>/dev/null
    mv rtl8188eu-master driver_src
else
    error "Failed to download driver"
fi

cd "$WORK_DIR/driver_src" || error "Failed to enter driver directory"
log "Driver source ready"

# ============================================================================
# STEP 3: NOW remove conflicting drivers (after download succeeds)
# ============================================================================
log "Disabling conflicting drivers..."
cat > /etc/modprobe.d/blacklist-realtek.conf <<'MODPROBE'
blacklist rtl8xxxu
blacklist r8188eu
MODPROBE

for driver in rtl8xxxu r8188eu 8188eu; do
    if lsmod | grep -q "^$driver "; then
        warn "Unloading $driver..."
        modprobe -r "$driver" 2>/dev/null || true
    fi
done
log "Old drivers disabled"

# ============================================================================
# STEP 4: Apply kernel 7.0 patch
# ============================================================================
log "Patching for kernel 7.0+..."

# Patch 1: Fix Makefile - EXTRA_CFLAGS -> ccflags-y
if grep -q "EXTRA_CFLAGS" Makefile; then
    sed -i 's/EXTRA_CFLAGS/ccflags-y/g' Makefile
    log "Makefile patched: EXTRA_CFLAGS -> ccflags-y"
else
    log "Makefile already patched"
fi

# Patch 2: Fix timer API - del_timer_sync -> timer_delete_sync
if grep -q "del_timer_sync" include/osdep_service.h; then
    sed -i 's/del_timer_sync/timer_delete_sync/g' include/osdep_service.h
    log "Timer API patched: del_timer_sync -> timer_delete_sync"
else
    log "Timer API already patched"
fi

# ============================================================================
# STEP 5: Compile
# ============================================================================
log "Compiling driver..."
make clean 2>/dev/null || true

NCORES=$(($(nproc) - 1))
[ $NCORES -lt 1 ] && NCORES=1

info "Building with $NCORES cores..."
if ! make -j$NCORES 2>&1 | tee -a "$LOG_FILE" | tail -30; then
    error "Compilation failed. See: $LOG_FILE"
fi

[ -f "8188eu.ko" ] || error "8188eu.ko not created"
log "Module ready: $(ls -lh 8188eu.ko | awk '{print $5}')"

# ============================================================================
# STEP 6: Install Module
# ============================================================================
log "Installing module..."
mkdir -p /lib/modules/$(uname -r)/kernel/drivers/net/wireless/
install -p -m 644 8188eu.ko /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ || error "Installation failed"
depmod -a 2>/dev/null || true
update-initramfs -u 2>/dev/null || true
log "Module installed"

# ============================================================================
# STEP 7: Configure
# ============================================================================
log "Configuring driver..."
cat > /etc/modprobe.d/rtl8188eu.conf <<'CONFIG'
options 8188eu rtw_power_mgnt=0
options 8188eu rtw_enusbss=0
options 8188eu rtw_max_acq_ass_retry=10
CONFIG

# ============================================================================
# STEP 8: Load
# ============================================================================
log "Attempting to load driver..."
if modprobe 8188eu 2>&1 >/dev/null; then
    sleep 2
    if lsmod | grep -q "^8188eu "; then
        log "✓✓✓ Driver loaded and active NOW"
    else
        warn "Driver will load after reboot"
    fi
else
    warn "Load will happen after reboot"
fi

# ============================================================================
# STEP 9: Cleanup
# ============================================================================
rm -rf "$WORK_DIR"
log "Cleanup complete"

# ============================================================================
# Done
# ============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✓ Installation Complete!                                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Next: sudo reboot"
echo ""
echo "After reboot:"
echo "  - Verify: lsmod | grep 8188eu"
echo "  - Check: nmcli device status"
echo ""
echo "Log: $LOG_FILE"
echo ""
