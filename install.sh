#!/bin/bash
###############################################################################
# RTL8188EU Driver Installation - Kernel 7.0+ (CORRECT ORDER)
# DOWNLOAD FIRST, THEN REMOVE DRIVER (to keep WiFi alive)
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
║  RTL8188EU Driver Installation - Kernel 7.0+                ║
║  Download FIRST | Remove Driver AFTER | Compile | Install   ║
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
apt install -y build-essential bc linux-headers-$(uname -r) libelf-dev git curl unzip >/dev/null 2>&1
log "Dependencies ready"

# ============================================================================
# STEP 2: DOWNLOAD DRIVER SOURCE FIRST (WiFi still alive)
# ============================================================================
log "Downloading driver source..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if git clone --depth 1 https://github.com/lwfinger/rtl8188eu.git driver_src 2>/dev/null; then
    log "Downloaded via git"
elif curl -sL https://github.com/lwfinger/rtl8188eu/archive/refs/heads/master.zip -o driver.zip; then
    log "Downloaded via ZIP (git failed)"
    unzip -q driver.zip
    mv rtl8188eu-master driver_src
else
    error "Failed to download driver from all sources"
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
# STEP 4: PATCH - Add linux/timer.h to correct location
# ============================================================================
log "Patching for kernel 7.0+..."

if ! grep -q "#include <linux/timer.h>" include/osdep_service.h; then
    sed -i '/#include <linux\/usb\/ch9\.h>/a #include <linux/timer.h>' include/osdep_service.h
    
    if ! grep -q "#include <linux/timer.h>" include/osdep_service.h; then
        error "Failed to patch include/osdep_service.h"
    fi
    
    info "Patch applied:"
    grep -n "timer.h" include/osdep_service.h | sed 's/^/  /'
else
    log "Patch already present"
fi

# ============================================================================
# STEP 5: Compile
# ============================================================================
log "Compiling driver..."
make clean 2>/dev/null || true

NCORES=$(($(nproc) - 1))
[ $NCORES -lt 1 ] && NCORES=1

info "Building with $NCORES cores..."
if make -j$NCORES 2>&1 | tail -20 >> "$LOG_FILE"; then
    log "Compilation succeeded"
else
    warn "Parallel build had issues, retrying single-threaded..."
    make clean 2>/dev/null || true
    make -j1 2>&1 | tail -20 >> "$LOG_FILE" || error "Compilation failed"
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
log "Module installed to /lib/modules"

# ============================================================================
# STEP 7: Configure Options
# ============================================================================
log "Configuring driver options..."
cat > /etc/modprobe.d/rtl8188eu.conf <<'CONFIG'
options 8188eu rtw_power_mgnt=0
options 8188eu rtw_enusbss=0
options 8188eu rtw_max_acq_ass_retry=10
CONFIG

# ============================================================================
# STEP 8: Load (optional - may not work until reboot)
# ============================================================================
log "Attempting to load driver..."
if modprobe 8188eu 2>&1; then
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
