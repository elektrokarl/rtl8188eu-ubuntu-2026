#!/bin/bash

echo "=== WLAN-Fix (Robust gegen Verbindungsabbrüche) ==="

# Hintergrunde-Watchdog: Hält das WLAN alive, falls es während des Downloads abstürzt
keep_alive() {
    while true; do
        if ! ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
            echo -e "\n[Watchdog] Verbindung weg! Lade rtl8xxxu neu..."
            sudo modprobe -r rtl8xxxu 2>/dev/null
            sudo modprobe rtl8xxxu 2>/dev/null
            sleep 3
        fi
        sleep 2
    done
}

# Watchdog im Hintergrund starten
keep_alive &
WATCHDOG_PID=$!

# Aufräumen beim Beenden
trap "kill $WATCHDOG_PID 2>/dev/null" EXIT

cd /tmp
rm -rf rtl8188eu

echo "[1/3] Lade Treiber-Quellcode von GitHub (wiederholt bei Abbruch)..."
until git clone https://github.com/lwfinger/rtl8188eu.git; do
    echo "[!] Download fehlgeschlagen. Warte auf Reconnect..."
    rm -rf rtl8188eu
    sleep 3
done

# Watchdog beenden, da Internet nicht mehr benötigt wird
kill $WATCHDOG_PID 2>/dev/null

echo "[2/3] Kompiliere und installiere Treiber lokal..."
cd rtl8188eu
make -j$(nproc)
sudo make install

echo "[3/3] Deaktiviere instabilen Treiber & aktiviere neuen Treiber..."
echo "blacklist rtl8xxxu" | sudo tee /etc/modprobe.d/blacklist-rtl8xxxu.conf > /dev/null
sudo modprobe -r rtl8xxxu 2>/dev/null || true
sudo modprobe 8188eu

echo ""
echo "=== ERFOLGREICH ABGESCHLOSSEN ==="
echo "Aktuell geladenes Modul:"
lsmod | grep -E "8188eu|rtl8xxxu"
