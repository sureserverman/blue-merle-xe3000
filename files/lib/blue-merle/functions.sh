#!/usr/bin/env ash

# This script provides helper functions for blue-merle

. /lib/blue-merle/probe.sh

UNICAST_MAC_GEN () {
    loc_mac_numgen=`python3 -c "import random; print(f'{random.randint(0,2**48) & 0b111111101111111111111111111111111111111111111111:0x}'.zfill(12))"`
    loc_mac_formatted=$(echo "$loc_mac_numgen" | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\)\(..\).*$/\1:\2:\3:\4:\5:\6/')
    echo "$loc_mac_formatted"
}

# randomize BSSID
RESET_BSSIDS () {
    uci set wireless.@wifi-iface[1].macaddr=`UNICAST_MAC_GEN`
    uci set wireless.@wifi-iface[0].macaddr=`UNICAST_MAC_GEN`
    uci commit wireless
    # you need to reset wifi for changes to apply, i.e. executing "wifi"
}


RANDOMIZE_MACADDR () {
    uci set network.@device[1].macaddr=`UNICAST_MAC_GEN`
    uci set glconfig.general.macclone_addr=`UNICAST_MAC_GEN`
    uci commit network
}

READ_ICCID() {
    gl_modem -B $BM_MODEM_BUS AT AT+CCID
}


READ_IMEI() {
    local imei
    imei=$(gl_modem -B $BM_MODEM_BUS AT AT+GSN | grep -w -E "[0-9]{14,15}")
    if [ -z "$imei" ]; then
        bm_log "Failed to read IMEI"
        return 1
    fi
    echo "$imei"
}

READ_IMSI() {
    local imsi
    imsi=$(gl_modem -B $BM_MODEM_BUS AT AT+CIMI | grep -w -E "[0-9]{6,15}")
    if [ -z "$imsi" ]; then
        bm_log "Failed to read IMSI"
        return 1
    fi
    echo "$imsi"
}


GENERATE_IMEI() {
    local seed=$(head -100 /dev/urandom | tr -dc "0123456789" | head -c10)
    local imei=$(lua /lib/blue-merle/luhn.lua $seed)
    echo -n $imei
}

SET_IMEI() {
    local imei="$1"
    if [ ${#imei} -eq 14 ]; then
        python3 /lib/blue-merle/imei_generate.py -s "$imei"
    else
        echo "IMEI is ${#imei} not 14 characters long"
        return 1
    fi
}

CHECK_ABORT() {
    if [ "$(cat /tmp/sim_change_switch 2>/dev/null)" = "off" ]; then
        bm_log "SIM change aborted."
        echo "SIM change aborted."
        sleep 1
        exit 1
    fi
}
