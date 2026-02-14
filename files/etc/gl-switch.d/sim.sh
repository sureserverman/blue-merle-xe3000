#!/bin/sh

# blue-merle switch hook for GL-XE3000 (Puli AX)

action=$1
logger -p notice -t blue-merle-toggle "Called... ${action}"

if [ "$action" = "on" ]; then
    echo "on" > /tmp/sim_change_switch
    flock -n /tmp/blue-merle-switch.lock logger -p notice -t blue-merle-toggle "Running Stage 1" || logger -p notice -t blue-merle-toggle "Lockfile busy"
    flock -n /tmp/blue-merle-switch.lock timeout 90 /usr/bin/blue-merle-switch-stage1

elif [ "$action" = "off" ]; then
    if [ -f /tmp/blue-merle-stage1 ]; then
        flock -n /tmp/blue-merle-switch.lock || logger -p notice -t blue-merle-toggle "Lockfile busy" &
        flock -n /tmp/blue-merle-switch.lock timeout 90 /usr/bin/blue-merle-switch-stage2
    else
        logger -p notice -t blue-merle-toggle "No Stage 1; Toggling Off"
    fi
    echo "off" > /tmp/sim_change_switch

else
    echo "off" > /tmp/sim_change_switch
fi

logger -p notice -t blue-merle-toggle "Finished Switch $action"
sleep 1
