#!/bin/bash
# wifi-mitigate.sh - collect WiFi/USB/disk diagnostics and apply persistent,
# connection-safe mitigations (no module reloads, no interface restarts).
#
# Usage: sudo bash wifi-mitigate.sh [collect|apply|all]   (default: all)
#
# Safety: the interface carrying the default route is detected and never
# touched live. All changes are written to config files and take effect on
# the next reboot (or per-device sysfs/iw knobs that do not drop the link).

set -u
MODE="${1:-all}"
OUT="${OUT:-$HOME/wifi-diag-$(date +%Y%m%d-%H%M%S)}"
RTL_IDS="0bda:8179 0bda:0179 0bda:8176"   # RTL8188EU / 8188CU family

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
mkdir -p "$OUT"
say() { echo "[wifi-mitigate] $*"; }

# Interface carrying our own connection (never touch it live)
ACTIVE_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
say "Active default-route interface: ${ACTIVE_IF:-none}"

run() { local f="$1"; shift; { echo "# $*"; timeout 20 "$@" 2>&1; } > "$OUT/$f.txt"; }

collect() {
    say "Collecting diagnostics into $OUT"
    run kernel      uname -a
    run ip-link     ip -s link
    run ip-route    ip route
    run nmcli-dev   nmcli -f all device show
    run nmcli-con   nmcli connection show
    run iw-dev      iw dev
    run iw-reg      iw reg get
    run rfkill      rfkill list
    run lsusb       lsusb -t
    run lsmod       lsmod
    run modprobe-d  sh -c 'grep -r . /etc/modprobe.d/ 2>/dev/null'
    run nm-conf     sh -c 'grep -r . /etc/NetworkManager/conf.d/ 2>/dev/null'
    run dmesg-wifi  sh -c "dmesg -T | grep -Ei 'wlp|wlx|wlan|rtl8|iwlwifi|cfg80211|usb [0-9]|xhci'"
    run dmesg-disk  sh -c "dmesg -T | grep -Ei 'ata[0-9]|nvme|I/O error|EXT4-fs|blk_update'"
    run journal-nm  journalctl -b -u NetworkManager -u wpa_supplicant --no-pager -n 500
    run journal-prev journalctl -b -1 -p warning --no-pager -n 500
    run power       sh -c 'for d in /sys/bus/usb/devices/*; do [ -f $d/power/control ] && echo "$d $(cat $d/product 2>/dev/null) control=$(cat $d/power/control) autosuspend=$(cat $d/power/autosuspend_delay_ms 2>/dev/null)"; done'
    for i in $(iw dev 2>/dev/null | awk '/Interface/ {print $2}'); do
        run "iw-$i-link"    iw dev "$i" link
        run "iw-$i-station" iw dev "$i" station dump
        run "iw-$i-power"   iw dev "$i" get power_save
    done
    command -v smartctl >/dev/null && for d in /dev/sd? /dev/nvme?n1; do
        [ -e "$d" ] && run "smart-$(basename "$d")" smartctl -H -A "$d"
    done
    run ping-gw sh -c 'ping -c 10 -i 0.3 -W 1 "$(ip route | awk "/default/ {print \$3; exit}")"'
    tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null &&
        say "Bundle: $OUT.tar.gz"
}

apply() {
    say "Applying persistent mitigations"

    # 1. Disable NetworkManager WiFi power-save and MAC randomisation during scans
    #    (both are well-known causes of association timeouts / beacon loss).
    cat > /etc/NetworkManager/conf.d/99-wifi-stability.conf <<'EOF'
[connection]
wifi.powersave = 2

[device]
wifi.scan-rand-mac-address = no
EOF

    # 2. Prevent USB autosuspend of the Realtek dongle (reset loop trigger).
    {
        for id in $RTL_IDS; do
            echo "ACTION==\"add|change\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"${id%:*}\", ATTR{idProduct}==\"${id#*:}\", TEST==\"power/control\", ATTR{power/control}=\"on\""
        done
    } > /etc/udev/rules.d/99-rtl8188eu-nosuspend.rules

    # 3. Module options: no power-save / aggressive aggregation on both radios.
    cat > /etc/modprobe.d/wifi-stability.conf <<'EOF'
# Intel (iwlwifi): disable power saving, software crypto off by default
options iwlwifi power_save=0 uapsd_disable=1
options iwlmvm power_scheme=1
# Realtek in-kernel driver: no USB DMA aggregation, no 40MHz on 2.4GHz
options rtl8xxxu dma_aggregation=0 ht40_2g=0
EOF

    # 4. Live, link-safe tweaks: only on interfaces that are NOT carrying our route.
    for i in $(iw dev 2>/dev/null | awk '/Interface/ {print $2}'); do
        if [ "$i" = "${ACTIVE_IF:-}" ]; then
            say "Skipping live changes on $i (active connection) - applies after reboot"
            continue
        fi
        iw dev "$i" set power_save off 2>/dev/null && say "power_save off on $i"
    done
    for d in /sys/bus/usb/devices/*; do
        for id in $RTL_IDS; do
            [ "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" = "$id" ] &&
                echo on > "$d/power/control" 2>/dev/null && say "USB autosuspend off for $d"
        done
    done

    # 5. Reload NM config only (SIGHUP) - does not drop active connections.
    pkill -HUP NetworkManager 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    command -v update-initramfs >/dev/null && update-initramfs -u >/dev/null 2>&1 || true

    say "Done. Reboot when convenient (module options apply on next load)."
    say "Also check: SATA errors (ata1 'failed command' / hard resetting link) point to a"
    say "failing disk/cable; they stall the system and look like WiFi drops. See SMART output."
}

case "$MODE" in
    collect) collect ;;
    apply)   apply ;;
    all)     collect; apply ;;
    *) echo "Usage: $0 [collect|apply|all]"; exit 1 ;;
esac
