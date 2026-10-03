# RTL8188EU Driver for Ubuntu/Kubuntu 2026+

A robust, production-ready installation script for the Realtek RTL8188EU USB WiFi adapter on Ubuntu/Kubuntu with kernel 7.0+ support.

## Problem Statement

The RTL8188EU USB WiFi adapter has poor support in the Linux kernel's built-in `rtl8xxxu` driver, causing:
- **Beacon loss** – `CTRL-EVENT-BEACON-LOSS` repeated in logs
- **Association timeouts** – WiFi disconnects after ~30 seconds
- **Network drops** – Connection dies unpredictably
- **Kernel compilation errors** – Missing includes on kernel 7.0+

This script uses the **Aircrack-ng fork** of the RTL8188EU driver, which is actively maintained and properly configured for modern kernels.

## Features

✅ **Network Drop Resilience**
- Download retries with exponential backoff  
- Handles WiFi disconnections during installation
- Falls back to ZIP download if git fails

✅ **Kernel 7.0+ Compatibility**
- Auto-fixes include path issues in Makefile
- Patches missing `linux/timer.h` dependencies
- Handles both parallel and single-threaded compilation

✅ **Modern Kubuntu Support**
- Works with Ubuntu 26.04 LTS and earlier
- Proper DKMS integration for future kernel updates
- Automatic driver option configuration

✅ **Comprehensive Logging**
- Full installation log at `/var/log/rtl8188eu_install.log`
- Clear error messages and recovery steps
- Post-install verification and testing instructions

## Installation

### Quick Start

```bash
# Download the script
wget https://raw.githubusercontent.com/elektrokarl/rtl8188eu-ubuntu-2026/main/install-rtl8188eu.sh

# Make it executable
chmod +x install-rtl8188eu.sh

# Run with sudo
sudo bash install-rtl8188eu.sh

# Reboot when complete
sudo reboot
```

### What the Script Does

1. **System Check** – Verifies kernel and build tools
2. **Disable Conflicting Drivers** – Blacklists `rtl8xxxu` and `r8188eu`
3. **Install Dependencies** – `build-essential`, `dkms`, `linux-headers`, etc.
4. **Download Driver** – Clones Aircrack-ng fork from GitHub (with retries)
5. **Apply Patches** – Fixes include paths and timer APIs for kernel 7.0+
6. **Fix Makefile** – Adds proper `ccflags-y` directives
7. **Compile** – Builds the `8188eu.ko` module
8. **Install** – Moves module to `/lib/modules/...`
9. **Configure** – Sets optimal driver options (power management disabled)
10. **Verify** – Checks module is loaded and ready

## After Installation

### Verify Driver is Loaded

```bash
lsmod | grep 8188eu
```

Expected output:
```
8188eu                315392  0
```

### Check Driver Details

```bash
ethtool -i wlan0  # Replace wlan0 with your WiFi device
```

Expected output includes:
```
driver: 8188eu
```

### Monitor Connection Quality

```bash
# Real-time WiFi link status
watch -n 1 'iw dev wlan0 link'

# Check for beacon loss or disconnections
sudo iw event

# View driver logs
dmesg | tail -20 | grep -i 8188eu
```

### If WiFi Still Disconnects

Disable power management:

```bash
sudo iwconfig wlan0 power off
```

Make it permanent by adding to your WiFi connection profile or system startup.

## Troubleshooting

### Script Fails at Download

The script has built-in retry logic. If your WiFi drops:
1. Check your connection: `ping 8.8.8.8`
2. The script will automatically retry after 10 seconds
3. Maximum 5 attempts before giving up

### Compilation Fails

Check the log:
```bash
tail -100 /var/log/rtl8188eu_install.log
```

Common issues:
- **Missing kernel headers**: Script installs them automatically
- **Include path errors**: Script applies patches automatically
- **Parallel compilation error**: Script falls back to `-j1`

### Driver Not Loading After Reboot

```bash
# Check if it's blacklisted
cat /etc/modprobe.d/blacklist-realtek.conf

# Manually load the driver
sudo modprobe 8188eu

# Verify it loaded
lsmod | grep 8188eu
```

### WiFi Device Not Recognized

```bash
# Check USB connection
lsusb | grep Realtek

# Should show:
# Bus 001 Device 002: ID 0b05:18f0 ASUSTek Computer, Inc. Realtek 8188EUS [USB-N10 Nano]

# Check kernel sees it
dmesg | grep -i 8188
```

## System Requirements

- **OS**: Ubuntu 22.04 LTS or newer (including 26.04 LTS)
- **Kernel**: 5.4+ (tested up to 7.0.0-38-generic)
- **Hardware**: Realtek RTL8188EU USB WiFi adapter
- **Internet**: For downloading driver source (can be flaky)
- **Sudo**: Required for installation

## Driver Configuration

The script creates `/etc/modprobe.d/rtl8188eu-opts.conf` with optimal settings:

```bash
# Disable power management (main cause of beacon loss)
options 8188eu rtw_power_mgnt=0

# Disable USB suspend
options 8188eu rtw_enusbss=0

# Increase association retry attempts
options 8188eu rtw_max_acq_ass_retry=10

# Improve RX in monitor mode
options 8188eu rtw_monitor_rx_under_bss_mode=1
```

These options are automatically set by the script and take effect after reboot.

## Performance Expectations

With this driver and proper configuration:
- **Beacon loss**: Reduced or eliminated
- **Connection stability**: Significantly improved
- **Speed**: Up to 150 Mbps (USB 2.0 limit, chip supports 150 Mbps)
- **Range**: Similar to stock driver

Note: This is a 1x1 802.11n adapter from ~2012. Performance depends on your WiFi environment.

## Known Limitations

1. **Still a USB 2.0 adapter** – Limited to ~150 Mbps throughput
2. **Single antenna** – Weaker range than modern dual-antenna cards
3. **No WiFi 6/6E support** – This is a 2.4/5GHz 802.11n adapter only
4. **Requires reboot** – Driver changes take effect only after restart

## License

This installation script is provided as-is. The RTL8188EU driver source is provided by Aircrack-ng under the GPL license.

## Support

For issues:
1. Check `/var/log/rtl8188eu_install.log` for installation errors
2. Review `dmesg | grep -i 8188eu` for runtime errors
3. Test connection with: `iw event` and `watch -n 1 'iw dev wlan0 link'`
4. Report issues on the Aircrack-ng GitHub: https://github.com/aircrack-ng/rtl8188eus
