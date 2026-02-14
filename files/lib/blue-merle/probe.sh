#!/usr/bin/env ash

# blue-merle probe library for GL-XE3000 (Puli AX)

bm_log() {
    logger -p notice -t blue-merle "$1"
}

# Check if IMEI writes work on this modem (RM520N-GL support is firmware-dependent)
# Caches result in /tmp so we only probe once per boot.
bm_can_write_imei() {
    local cache="/tmp/blue-merle-imei-capable"
    if [ -f "$cache" ]; then
        [ "$(cat "$cache")" = "1" ]
        return $?
    fi

    if [ ! -c /dev/mhi_DUN ]; then
        echo 0 > "$cache"
        bm_log "IMEI write not supported: /dev/mhi_DUN not found"
        return 1
    fi

    local resp
    resp=$(python3 -c "
import serial
try:
    with serial.Serial('/dev/mhi_DUN', 9600, timeout=3, exclusive=True) as ser:
        ser.write(b'AT+EGMR=0,7\r')
        output = ser.read(64)
        if b'EGMR' in output or b'OK' in output:
            print('OK')
except:
    pass
" 2>/dev/null)

    if [ "$resp" = "OK" ]; then
        echo 1 > "$cache"
        return 0
    fi

    echo 0 > "$cache"
    bm_log "IMEI write not supported on this modem firmware"
    return 1
}
