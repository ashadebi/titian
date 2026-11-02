#!/bin/sh
# TITIAN Fase 1 — perintah show (interfaces, route, neighbor).
# Perbedaan dari rtcli: show interfaces MENAMPILKAN inet6 (rtcli
# sengaja membuangnya dengan egrep -v inet6).
# POSIX sh.
OS=$(uname -s)

interfaces_linux() {
    printf "\n"
    printf "Codes: State, u - Up, D - Down, L - Loopback. \n"
    printf "  %-11s%-19s%8s    %s\n" "Interface" "IP Address" "state" "Description"
    printf "  %-11s%-19s%8s    %s\n" "---------" "----------" "-----" "-----------"
    for f in $(ls /sys/class/net 2>/dev/null | sort); do
        dev=$f
        # Hanya direktori = interface nyata (lewati berkas non-interface
        # seperti bonding_masters — lihat titian-if-list.sh).
        [ -d "/sys/class/net/$dev" ] || continue
        operstate=$(cat /sys/class/net/$dev/operstate 2>/dev/null)
        alias=$(cat /sys/class/net/$dev/ifalias 2>/dev/null)
        case "$operstate" in
            up) operstate="u" ;;
            *)  operstate="D" ;;
        esac
        case "$dev" in
            lo*) operstate="L" ;;
        esac
        addrs=$(ip -o addr show dev "$dev" 2>/dev/null | awk '{if ($5=="peer") print $4 " peer " $6; else print $4}')
        if [ -z "$addrs" ]; then
            printf "  %-11s%-19s%8s    %s\n" "$dev" "-" "$operstate" "$alias"
        else
            first=1
            for a in $addrs; do
                if [ "$first" -eq 1 ]; then
                    printf "  %-11s%-19s%8s    %s\n" "$dev" "$a" "$operstate" "$alias"
                    first=0
                else
                    printf "  %-11s%-19s\n" "" "$a"
                fi
            done
        fi
    done
    printf "\n"
}

interfaces_fbsd() {
    printf "\n"
    printf "Codes: State, u - Up, D - Down, L - Loopback. \n"
    printf "  %-11s%-19s%8s    %s\n" "Interface" "IP Address" "state" "Description"
    printf "  %-11s%-19s%8s    %s\n" "---------" "----------" "-----" "-----------"
    ifconfig -a 2>/dev/null | awk '
        /^[a-z0-9]+:/ {
            if (dev != "") { flush() }
            split($1, n, ":"); dev = n[1]
            flags = $0
            state = (flags ~ /UP/) ? "u" : "D"
            if (dev ~ /^lo/) state = "L"
            desc = ""; naddr = 0
        }
        /^[[:space:]]*inet6? / {
            # $2 = address; PtP: inet A --> B
            if ($1 == "inet") {
                if ($3 == "-->") addrs[++naddr] = $2 " peer " $4
                else addrs[++naddr] = $2
            } else {
                # inet6 A prefixlen N ...
                for (i = 1; i <= NF; i++) if ($i == "prefixlen") { addrs[++naddr] = $2 "/" $(i+1) }
            }
        }
        /^[[:space:]]*description: / { desc = substr($0, index($0, ":") + 2) }
        function flush() {
            if (naddr == 0) {
                printf("  %-11s%-19s%8s    %s\n", dev, "-", state, desc)
            } else {
                for (i = 1; i <= naddr; i++) {
                    if (i == 1) printf("  %-11s%-19s%8s    %s\n", dev, addrs[i], state, desc)
                    else printf("  %-11s%-19s\n", "", addrs[i])
                }
            }
        }
        END { if (dev != "") flush() }
    '
    printf "\n"
}

# Status tiga nilai (permintaan user): admin up/disabled dari flag UP,
# link up/down dari operstate/LOWER_UP (Linux) atau status (FreeBSD).
# terse = satu baris per interface sistem (bukan hanya yang terkonfigurasi).
terse_linux() {
    printf "\n"
    printf "  %-11s %-9s %-6s %s\n" "Interface" "Admin" "Link" "IP Address"
    printf "  %-11s %-9s %-6s %s\n" "---------" "-----" "----" "----------"
    for dev in $(ls /sys/class/net 2>/dev/null | sort); do
        # Hanya direktori = interface nyata (lewati berkas non-interface
        # seperti bonding_masters — lihat titian-if-list.sh).
        [ -d "/sys/class/net/$dev" ] || continue
        flags_hex=$(cat /sys/class/net/$dev/flags 2>/dev/null)
        [ -n "$flags_hex" ] || flags_hex=0x0
        flags=$((flags_hex))
        if [ $((flags & 1)) -eq 1 ]; then admin="up"; else admin="disabled"; fi
        operstate=$(cat /sys/class/net/$dev/operstate 2>/dev/null)
        # lo: operstate=unknown + flags tanpa LOWER_UP (0x9) -> LOOPBACK (0x8) yang menandakan link up.
        link="down"
        if [ "$admin" = "up" ]; then
            if [ "$operstate" = "up" ] || [ $((flags & 65536)) -ne 0 ] || [ $((flags & 8)) -ne 0 ]; then link="up"; fi
        fi
        addrs=$(ip -o addr show dev "$dev" 2>/dev/null | awk '{if ($5=="peer") print $4 " peer " $6; else print $4}' | paste -sd ", " -)
        [ -z "$addrs" ] && addrs="-"
        printf "  %-11s %-9s %-6s %s\n" "$dev" "$admin" "$link" "$addrs"
    done
    printf "\n"
}

terse_fbsd() {
    printf "\n"
    printf "  %-11s %-9s %-6s %s\n" "Interface" "Admin" "Link" "IP Address"
    printf "  %-11s %-9s %-6s %s\n" "---------" "-----" "----" "----------"
    ifconfig -a 2>/dev/null | awk '
        /^[a-z0-9]+:/ {
            if (dev != "") flush()
            split($1, n, ":"); dev = n[1]
            f = $2; sub(/^.*</, "", f); sub(/>.*$/, "", f)
            admin = (f ~ /(^|,)UP(,|$)/) ? "up" : "disabled"
            link = (dev ~ /^lo/) ? "up" : "down"
            naddr = 0
        }
        /^[[:space:]]*status: / { link = ($2 == "active") ? "up" : "down" }
        /^[[:space:]]*inet6? / {
            if ($1 == "inet") {
                if ($3 == "-->") addrs[++naddr] = $2 " peer " $4
                else addrs[++naddr] = $2
            } else {
                for (i = 1; i <= NF; i++) if ($i == "prefixlen") addrs[++naddr] = $2 "/" $(i+1)
            }
        }
        function flush() {
            a = "-"
            for (i = 1; i <= naddr; i++) a = (i == 1) ? addrs[i] : a ", " addrs[i]
            printf("  %-11s %-9s %-6s %s\n", dev, admin, link, a)
        }
        END { if (dev != "") flush() }
    '
    printf "\n"
}

# all = blok detail per interface sistem (admin/link, mtu, mac, alamat, counter).
all_linux() {
    printf "\n"
    for dev in $(ls /sys/class/net 2>/dev/null | sort); do
        # Hanya direktori = interface nyata (lewati berkas non-interface
        # seperti bonding_masters — lihat titian-if-list.sh).
        [ -d "/sys/class/net/$dev" ] || continue
        flags_hex=$(cat /sys/class/net/$dev/flags 2>/dev/null)
        [ -n "$flags_hex" ] || flags_hex=0x0
        flags=$((flags_hex))
        if [ $((flags & 1)) -eq 1 ]; then admin="up"; else admin="disabled"; fi
        operstate=$(cat /sys/class/net/$dev/operstate 2>/dev/null)
        # lo: operstate=unknown + flags tanpa LOWER_UP (0x9) -> LOOPBACK (0x8) yang menandakan link up.
        link="down"
        if [ "$admin" = "up" ]; then
            if [ "$operstate" = "up" ] || [ $((flags & 65536)) -ne 0 ] || [ $((flags & 8)) -ne 0 ]; then link="up"; fi
        fi
        mtu=$(cat /sys/class/net/$dev/mtu 2>/dev/null)
        mac=$(cat /sys/class/net/$dev/address 2>/dev/null)
        alias=$(cat /sys/class/net/$dev/ifalias 2>/dev/null)
        printf "Interface %s: admin %s, link %s, mtu %s, mac %s" "$dev" "$admin" "$link" "$mtu" "$mac"
        [ -n "$alias" ] && printf ", description \"%s\"" "$alias"
        printf "\n"
        ip -o addr show dev "$dev" 2>/dev/null | awk '{if ($5=="peer") print "    " $3 " " $4 " peer " $6; else print "    " $3 " " $4}'
        ip -s link show "$dev" 2>/dev/null | awk '/RX:/ {getline; rx=$1" bytes, "$2" packets, "$3" errors, "$4" dropped"} /TX:/ {getline; tx=$1" bytes, "$2" packets, "$3" errors, "$4" dropped"} END {if (rx != "") {print "    RX: " rx; print "    TX: " tx}}'
        printf "\n"
    done
}

all_fbsd() {
    printf "\n"
    for dev in $(ifconfig -l 2>/dev/null); do
        out=$(ifconfig "$dev" 2>/dev/null) || continue
        line=$(printf "%s\n" "$out" | head -1)
        f=$(printf "%s" "$line" | awk '{f=$2; sub(/^.*</, "", f); sub(/>.*$/, "", f); print f}')
        case ",$f," in *,UP,*) admin="up" ;; *) admin="disabled" ;; esac
        case "$dev" in
            lo*) link="up" ;;
            *) link=$(printf "%s\n" "$out" | awk '/^[[:space:]]*status: / {print ($2 == "active") ? "up" : "down"; exit}'); [ -z "$link" ] && link="down" ;;
        esac
        printf "Interface %s: admin %s, link %s\n" "$dev" "$admin" "$link"
        printf "%s\n" "$out" | sed 's/^/    /'
        netstat -I "$dev" -b 2>/dev/null | awk 'NR > 1 && $3 ~ /^<Link/ {printf("    counters: RX %s packets, %s bytes; TX %s packets, %s bytes\n", $5, $8, $9, $11); exit}'
        printf "\n"
    done
}

if_detail() {
    # $1=iface [$2=detail]
    local iface=$1 detail=${2:-}
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$iface" 2>/dev/null || { echo "Error: interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)." >&2; exit 33; }
        if [ -n "$detail" ]; then
            echo "(detail hardware setara ethtool/udev tidak tersedia di FreeBSD; pakai pciconf -lv)"
        fi
    else
        if [ ! -d "/sys/class/net/$iface" ]; then
            echo "Error: interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)." >&2; exit 33
        fi
        printf "\n"
        ip -d link show "$iface"
        ip -d addr show "$iface" | grep inet
        printf "\n"
        if [ -n "$detail" ]; then
            if command -v ethtool >/dev/null 2>&1; then ethtool "$iface"; printf "\n"; fi
            if command -v udevadm >/dev/null 2>&1; then udevadm info "/sys/class/net/$iface"; printf "\n"; fi
        fi
    fi
}

case "${1:-}" in
    interfaces)
        if [ "$OS" = "FreeBSD" ]; then interfaces_fbsd; else interfaces_linux; fi
        ;;
    if-detail)
        if_detail "$2" "${3:-}"
        ;;
    terse)
        if [ "$OS" = "FreeBSD" ]; then terse_fbsd; else terse_linux; fi
        ;;
    all)
        if [ "$OS" = "FreeBSD" ]; then all_fbsd; else all_linux; fi
        ;;
    route)
        if [ "$OS" = "FreeBSD" ]; then
            if [ -n "${2:-}" ]; then netstat -rn -f inet 2>/dev/null | grep -F -- "$2" || true
            else netstat -rn -f inet 2>/dev/null; fi
        else
            if [ -n "${2:-}" ]; then ip route show "$2"; else ip route show; fi
        fi
        ;;
    route6)
        if [ "$OS" = "FreeBSD" ]; then
            if [ -n "${2:-}" ]; then netstat -rn -f inet6 2>/dev/null | grep -F -- "$2" || true
            else netstat -rn -f inet6 2>/dev/null; fi
        else
            if [ -n "${2:-}" ]; then ip -6 route show "$2"; else ip -6 route show; fi
        fi
        ;;
    neighbor)
        if [ "$OS" = "FreeBSD" ]; then
            if [ -n "${2:-}" ]; then arp -a 2>/dev/null | grep -F -- "$2" || true
            else arp -a 2>/dev/null; fi
        else
            if [ -n "${2:-}" ]; then ip -d neighbor show dev "$2"; else ip -d neighbor show; fi
        fi
        ;;
    *) echo "Usage: $0 {interfaces|if-detail|terse|all|route|route6|neighbor} [arg]" >&2; exit 2 ;;
esac
