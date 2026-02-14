#!/usr/bin/env ash

# blue-merle probe library for GL-XE3000 (Puli AX)

BM_MHI_DEV="/dev/mhi_DUN"

bm_log() {
    logger -p notice -t blue-merle "$1"
}

# Send an AT command directly to the modem via /dev/mhi_DUN.
# Used for EGMR commands that gl_modem doesn't handle.
bm_at_direct() {
    local cmd="$1"
    exec 3<>"$BM_MHI_DEV"
    printf '%s\r' "$cmd" >&3
    local line="" result="" i=0
    while [ $i -lt 10 ]; do
        read -r -t 2 line <&3 || break
        result="$result$line
"
        case "$line" in
            *OK*|*ERROR*) break;;
        esac
        i=$((i + 1))
    done
    exec 3>&-
    echo "$result"
}

# Check if IMEI writes work on this modem (RM520N-GL support is firmware-dependent)
# Caches result in /tmp so we only probe once per boot.
bm_can_write_imei() {
    local cache="/tmp/blue-merle-imei-capable"
    if [ -f "$cache" ]; then
        [ "$(cat "$cache")" = "1" ]
        return $?
    fi

    if [ ! -c "$BM_MHI_DEV" ]; then
        echo 0 > "$cache"
        bm_log "IMEI write not supported: $BM_MHI_DEV not found"
        return 1
    fi

    local resp
    resp=$(bm_at_direct 'AT+EGMR=0,7')
    if echo "$resp" | grep -q "[0-9]"; then
        echo 1 > "$cache"
        return 0
    fi

    echo 0 > "$cache"
    bm_log "IMEI write not supported on this modem firmware"
    return 1
}
