#!/bin/bash

# Configuration
LOG_FILE="$HOME/wifi_telemetry.csv"
INTERFACE="wlxbcfce7292407" # Your Realtek USB interface
GATEWAY_IP=$(ip route | grep default | awk '{print $3}' | head -n 1)

# Write CSV Header if file doesn't exist
if [ ! -f "$LOG_FILE" ]; then
    echo "Timestamp,Interface,Signal_dBm,Tx_Bitrate_Mbps,Rx_Bitrate_Mbps,Ping_Gateway_ms,Packet_Loss_Pct,Driver_State" > "$LOG_FILE"
fi

# Get current timestamp
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# 1. Get Wireless Link Telemetry via 'iw'
IW_OUTPUT=$(iw dev "$INTERFACE" link 2>/dev/null)

if echo "$IW_OUTPUT" | grep -q "Connected to"; then
    SIGNAL=$(echo "$IW_OUTPUT" | grep -i "signal:" | awk '{print $2}')
    TX_RATE=$(echo "$IW_OUTPUT" | grep -i "tx bitrate:" | awk '{print $3}')
    RX_RATE=$(echo "$IW_OUTPUT" | grep -i "rx bitrate:" | awk '{print $3}')
    STATE="Connected"
else
    SIGNAL="N/A"
    TX_RATE="0"
    RX_RATE="0"
    STATE="Disconnected"
fi

# 2. Latency & Packet Loss to Gateway (Send 5 rapid pings)
if [ -n "$GATEWAY_IP" ]; then
    PING_OUT=$(ping -c 5 -i 0.2 -W 1 "$GATEWAY_IP" 2>/dev/null)
    
    # Extract latency (avg) and packet loss percentage
    LOSS=$(echo "$PING_OUT" | grep -oP '\d+(?=% packet loss)')
    AVG_PING=$(echo "$PING_OUT" | grep -oP 'rtt min/avg/max/mdev = \d+\.\d+/\K\d+\.\d+')
    
    [ -z "$LOSS" ] && LOSS="100"
    [ -z "$AVG_PING" ] && AVG_PING="TIMEOUT"
else
    LOSS="100"
    AVG_PING="NO_GATEWAY"
fi

# 3. Append row to CSV
echo "$TIMESTAMP,$INTERFACE,$SIGNAL,$TX_RATE,$RX_RATE,$AVG_PING,$LOSS,$STATE" >> "$LOG_FILE"
