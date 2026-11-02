#!/bin/bash
Path=/sys/class/net
Ifaces () {
    ls  $Path/ | \
    egrep -v "\." |egrep "eth|ens|ge|xe"
}
for f in $(Ifaces); do
    dev=$(basename $f)
    driver=$(readlink $Path/$f/device/driver/module)
    if [ $driver ]; then
        driver=$(basename $driver)
    fi
    addr=$(cat $Path/$f/address)
    operstate=$(cat $Path/$f/operstate)
    printf "%10s [%s]: %6s [%s]\n" "$dev" "$addr" "$driver" "$operstate"
done