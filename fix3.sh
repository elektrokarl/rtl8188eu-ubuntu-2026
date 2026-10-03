#!/bin/bash
set -e

WORK_DIR="/tmp/rtl8188eu_fix"

echo "=== Finale WLAN-Treiber-Reparatur (Realtek RTL8188EUS) ==="

# 1. Aufräumen alter Versuche
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 2. Treiber-Quellcode abrufen (Absturzsicher bei instabilem WLAN)
echo "[1/4] Lade Treiber-Quellcode herunter..."
sudo modprobe rtl8xxxu 2>/dev/null || true

until git clone https://github.com/lwfinger/rtl8188eu.git .; do
    echo "[!] Download abgebrochen. Setze WLAN zurück und versuche es erneut..."
    sudo modprobe -r rtl8xxxu 2>/dev/null || true
    sleep 2
    sudo modprobe rtl8xxxu 2>/dev/null || true
    sleep 5
done

# 3. Kbuild-Fix für Kernel 6.x/7.x: Subdirectory Include-Pfade erzwingen
echo "[2/4] Wende Kernel 7.0 Build-Fix an..."
sed -i '1i ccflags-y += -I$(src)/include\nsubdir-ccflags-y += -I$(src)/include' Makefile

# 4. Kompilieren
echo "[3/4] Kompiliere Treiber..."
make -j$(nproc) KCFLAGS="-I$WORK_DIR/include"

# 5. Installieren, Blacklisten & Modul laden
echo "[4/4] Installiere Modul und schalte um..."
sudo make install
sudo depmod -a

echo "blacklist rtl8xxxu" | sudo tee /etc/modprobe.d/blacklist-rtl8xxxu.conf > /dev/null

sudo modprobe -r rtl8xxxu 2>/dev/null || true
sudo modprobe 8188eu

echo ""
echo "=== ERFOLGREICH ABGESCHLOSEN ==="
echo "Aktuell geladenes Treiber-Modul:"
lsmod | grep -E "8188eu|rtl8xxxu"
