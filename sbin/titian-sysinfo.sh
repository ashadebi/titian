#!/bin/sh
# TITIAN Fase 1 — banner startup clish (pengganti ACTION Linux-only
# di startup.xml rtcli: free, /proc/loadavg).
# POSIX sh.
OS=$(uname -s)
date
if [ "$OS" = "FreeBSD" ]; then
    phys=$(sysctl -n hw.physmem 2>/dev/null)
    user=$(sysctl -n hw.usermem 2>/dev/null)
    if [ -n "$phys" ] && [ -n "$user" ]; then
        used=$(( (phys - user) / 1024 / 1024 ))
        total=$(( phys / 1024 / 1024 ))
        echo "Memory Usage: ${used}/${total}MB"
    fi
    df -h / 2>/dev/null | awk 'NR==2{printf "Disk Usage: %s/%s (%s)\n", $3, $2, $5}'
    sysctl -n vm.loadavg 2>/dev/null | awk '{print "CPU Load:", $2, $3, $4}'
else
    free -m 2>/dev/null | awk 'NR==2{printf "Memory Usage: %s/%sMB (%.2f%%)\n", $3,$2,$3*100/$2 }'
    df -h 2>/dev/null | awk '$NF=="/"{printf "Disk Usage: %d/%dGB (%s)\n", $3,$2,$5}'
    awk '{print "CPU Load:", $1, $2, $3}' /proc/loadavg 2>/dev/null
fi
echo
