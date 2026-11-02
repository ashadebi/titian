#!/bin/bash
# file: udev_generator.sh
# debian family
# base pci-path, not unpredictable eth number!
# pattern butuh tambahan.

# lspci mode
Path_PCI_G="$(lspci |egrep -i "ethernet controller" |egrep -v -i "10 Gigabit|vmxnet3|10-Gigabit"| awk '{print $1}')"
Path_PCI_10G=$(lspci |egrep -i "ethernet controller" |egrep -i "10 Gigabit|vmxnet3|10-Gigabit"| awk '{print $1}')
# udevadm mode
## manual: udevadm info -e |egrep "^E.*[0-9]/net/"
#
PrintHeader () {
echo '## Udev generator, [eth, en* or any] to [ge, xe, ***] ##'
echo "# `date`"; echo ""
}
#
PrintComment () {
    echo "# Oldname: $BName, Driver: $driver, pci-id: $oneG"
}
Print1 () {
    PrintComment
    echo "ACTION==\"add\", SUBSYSTEM==\"net\", DRIVERS==\"?*\", ATTR{address}==\"$address\", NAME=\"$Pref$StartN\""
}
Print2 () {
    PrintComment
    echo "ACTION==\"add\", SUBSYSTEM==\"net\", DRIVERS==\"?*\", ATTR{address}==\"$address\", NAME=\"$Pref$StartNplus\""
}

Gen_func () {
# Generate funct [0-9]+ 
    if test -z $StartN; then
        StartN=0
        address=$(cat "/sys$NamePath/address")
        driver=$(readlink "/sys$NamePath/device/driver/module")
        if [ $NamePath ]; then BName=$(basename $NamePath); fi
        if [ $driver ]; then driver=$(basename $driver); fi
        Print1
        echo ""
    elif test ! -z $StartN; then
        address=$(cat "/sys$NamePath/address")
        driver=$(readlink "/sys$NamePath/device/driver/module")
            if [ $NamePath ]; then BName=$(basename $NamePath); fi
            if [ $driver ]; then driver=$(basename $driver); fi
        StartNplus=$(($StartN + 1))
        Print2
        StartN=$StartNplus
        printf "\n"
    fi
}

Find_1G () {
    StartN=""
    Pref=ge
    #printf "%s# Use prefix: $Pref\n\n"
    for oneG in $Path_PCI_G; do
        NamePath=$(udevadm info -e |egrep "^E.*$oneG/net/" | awk -F "=" '{print $2}')
        ## print $Pref[0-9]+
        Gen_func
    done
}

Find_10G () {
    StartN=""
    Pref=xe
    #printf "%s# Use prefix: $Pref\n\n"
    for oneG in $Path_PCI_10G; do
        NamePath=$(udevadm info -e |egrep "^E.*$oneG/net/" | awk -F "=" '{print $2}')
        ## print $Pref[0-9]+
        Gen_func
    done
}

if [ ! -x "/usr/bin/lspci" ]; then
    printf "Error: \"/usr/bin/lspci\"\n"
else
    # call funct
    PrintHeader
    Find_1G
    printf "\n"
    Find_10G
    echo '# manual copy/replace, file: /etc/udev/rules.d/70-net.rules'
fi
