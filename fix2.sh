#!/bin/bash
set -e

echo "=== WLAN-Fix für Realtek RTL8188EUS ==="

WORK_DIR="/tmp/rtl8188eu_fix"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 1. Sicherstellen, dass altes Modul läuft & Repository klonen (mit Wiederholung)
echo "[1/4] Lade Treiber-Quellcode herunter..."
sudo modprobe rtl8xxxu 2>/dev/null || true

until git clone https://github.com/lwfinger/rtl8188eu.git .; do
    echo "[!] Download abgebrochen. Lade Modul neu und versuche es erneut..."
    sudo modprobe -r rtl8xxxu 2>/dev/null || true
    sleep 1
    sudo modprobe rtl8xxxu 2>/dev/null || true
    sleep 4
done

# 2. Kompilieren mit explizitem Include-Pfad für neuere Kernel
echo "[2/4] Kompiliere Treiber..."
make -j$(nproc) USER_EXTRA_CFLAGS="-I$WORK_DIR/include"

# 3. Treiber im System installieren
echo "[3/4] Installiere Modul..."
sudo make install

# 4. Instabilen Treiber sperren & neuen aktivieren
echo "[4/4] Aktiviere neues Modul (8188eu)..."
echo "blacklist rtl8xxxu" | sudo tee /etc/modprobe.d/blacklist-rtl8xxxu.conf > /dev/null
sudo modprobe -r rtl8xxxu 2>/dev/null || true
sudo modprobe 8188eu

echo ""
echo "=== FERTIG! Status des WLAN-Moduls: ==="
lsmod | grep -E "8188eu|rtl8xxxu"
