#!/bin/bash
Path=/sys/class/net

Ifaces_dev () {
    ls  $Path/ |egrep -v "_|-"
}

Interface_ip_summary () {
printf "\n"
printf "Codes: State, u - Up, D - Down, L - Loopback. \n"
printf "%8s %13s %18s %12s\n" "Interface" "IP Address" "state" "Description"
printf "%8s %13s %18s %12s\n" "---------" "----------" "-----" "-----------"

for f in $(Ifaces_dev); do
    dev=$(basename $f)
    mac=$(cat $Path/$f/address)
    operstate=$(cat $Path/$f/operstate)
    alias=$(cat $Path/$f/ifalias)
    if [ "$operstate" = "up" ];then
        operstate="u"
    else
        operstate="D"
    fi
    if [[ $dev == *"lo"* ]];then
        operstate="L"
    fi
    addrcount=$(ip -o addr show $dev |egrep -v "inet6" |awk '{print $4}'|wc -l)
    addr=$(ip -o addr show $dev |egrep -v "inet6" |awk '{print $4}')
    if [ $addrcount -eq 1 ]; then
        printf '%s %s %s %s\n' $dev $addr $operstate $alias | awk '{ printf("  %-11s%-19s%8s    %s\n", $1, $2, $3, $4); }'
    elif [ $addrcount -gt 1 ]; then
        waddr1=$(echo ${addr} |awk '{print $1}')
        waddr2=$(ip -o addr show $dev |egrep -v "inet6" |awk '{print $4}' |grep -v "^$waddr1$")
        printf '%s %s %s %s\n' $dev $waddr1 $operstate $alias | awk '{ printf("  %-11s%-19s%8s    %s\n", $1, $2, $3, $4); }'
        for a in ${waddr2}; do
            printf "%s %s\n" "          "  "  $a"
        done
    else
        printf '%s %s %s %s\n' $dev "-" $operstate $alias | awk '{ printf("  %-11s%-19s%8s    %s\n", $1, $2, $3, $4); }'
    fi
done
printf "\n"
}

case $1 in
    all)
        Interface_ip_summary
    ;;
    *)
        echo "Usage: $0 {all}"
        exit 1 ;;
esac