#!/usr/bin/env ash

# blue-merle probe library for GL-XE3000 (Puli AX)
# All AT commands go through gl_modem. No serial fallbacks.

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

    local resp
    resp=$(gl_modem AT 'AT+EGMR=0,7' 2>/dev/null)
    if echo "$resp" | grep -q "[0-9]"; then
        echo 1 > "$cache"
        return 0
    fi

    echo 0 > "$cache"
    bm_log "IMEI write not supported on this modem firmware"
    return 1
}
