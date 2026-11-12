#!/bin/sh
# TITIAN Fase 1 — perintah show (interfaces, route, neighbor).
# Perbedaan dari titian: show interfaces MENAMPILKAN inet6 (titian
# sengaja membuangnya dengan egrep -v inet6).
# POSIX sh.
OS=$(uname -s)

# --- warna status (hanya bila stdout terminal; bila di-pipe, polos) ---
# Pola: kode warna dicetak sebagai argumen printf TERPISAH sebelum field
# status, reset sesudahnya — jadi lebar kolom printf tetap benar.
if [ -t 1 ]; then _SHOW_COLOR=1; else _SHOW_COLOR=0; fi
# _ESC = byte ESC asli (printf '%s' tidak menafsir \033, jadi konstanta
# harus berisi byte ESC, bukan string literal "\033").
_ESC=$(printf '\033')
_C_RED="${_ESC}[31m"; _C_GREEN="${_ESC}[32m"; _C_YELLOW="${_ESC}[33m"; _C_CYAN="${_ESC}[36m"; _C_RESET="${_ESC}[0m"
# Kembalikan kode warna untuk sebuah status (kosong bila bukan tty).
# up/u -> hijau, down/D/disabled -> merah, L (loopback) -> cyan, warning -> kuning/oranye.
status_color() {
    if [ "$_SHOW_COLOR" -eq 0 ]; then printf ''; return 0; fi
    case "$1" in
        up|u|UP) printf '%s' "$_C_GREEN" ;;
        down|D|DOWN|disabled) printf '%s' "$_C_RED" ;;
        L) printf '%s' "$_C_CYAN" ;;
        warning|WARNING) printf '%s' "$_C_YELLOW" ;;
        *) printf '' ;;
    esac
    return 0
}
status_reset() {
    if [ "$_SHOW_COLOR" -eq 0 ]; then printf ''; else printf '%s' "$_C_RESET"; fi
    return 0
}

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
            printf "  %-11s%-19s%s%8s%s    %s\n" "$dev" "-" "$(status_color "$operstate")" "$operstate" "$(status_reset)" "$alias"
        else
            first=1
            for a in $addrs; do
                if [ "$first" -eq 1 ]; then
                    printf "  %-11s%-19s%s%8s%s    %s\n" "$dev" "$a" "$(status_color "$operstate")" "$operstate" "$(status_reset)" "$alias"
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
    ifconfig -a 2>/dev/null | awk -v C_UP="$_C_GREEN" -v C_DOWN="$_C_RED" -v C_LOOP="$_C_CYAN" -v C_RESET="$_C_RESET" -v USE_COLOR="$_SHOW_COLOR" '
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
            # warna state: u=hijau, D=merah, L=cyan (hanya bila tty).
            # Kode warna sebagai argumen printf terpisah (sebelum/sesudah
            # field) supaya lebar kolom %8s tetap benar.
            if (USE_COLOR == 1) {
                if (state == "u") sc = C_UP
                else if (state == "D") sc = C_DOWN
                else sc = C_LOOP
                sr = C_RESET
            } else { sc = ""; sr = "" }
            if (naddr == 0) {
                printf("  %-11s%-19s%s%8s%s    %s\n", dev, "-", sc, state, sr, desc)
            } else {
                for (i = 1; i <= naddr; i++) {
                    if (i == 1) printf("  %-11s%-19s%s%8s%s    %s\n", dev, addrs[i], sc, state, sr, desc)
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
        printf "  %-11s %s%-9s%s %s%-6s%s %s\n" "$dev" "$(status_color "$admin")" "$admin" "$(status_reset)" "$(status_color "$link")" "$link" "$(status_reset)" "$addrs"
    done
    printf "\n"
}

terse_fbsd() {
    printf "\n"
    printf "  %-11s %-9s %-6s %s\n" "Interface" "Admin" "Link" "IP Address"
    printf "  %-11s %-9s %-6s %s\n" "---------" "-----" "----" "----------"
    ifconfig -a 2>/dev/null | awk -v C_UP="$_C_GREEN" -v C_DOWN="$_C_RED" -v C_RESET="$_C_RESET" -v USE_COLOR="$_SHOW_COLOR" '
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
            # warna: up=hijau, down/disabled=merah (hanya bila tty).
            # Kode warna sebagai argumen printf terpisah supaya lebar
            # kolom %-9s / %-6s tetap benar.
            if (USE_COLOR == 1) {
                ac = (admin == "up") ? C_UP : C_DOWN; ar = C_RESET
                lc = (link == "up") ? C_UP : C_DOWN; lr = C_RESET
            } else { ac = ""; ar = ""; lc = ""; lr = "" }
            a = "-"
            for (i = 1; i <= naddr; i++) a = (i == 1) ? addrs[i] : a ", " addrs[i]
            printf("  %-11s %s%-9s%s %s%-6s%s %s\n", dev, ac, admin, ar, lc, link, lr, a)
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
        printf "Interface %s: admin %s%s%s, link %s%s%s, mtu %s, mac %s" "$dev" "$(status_color "$admin")" "$admin" "$(status_reset)" "$(status_color "$link")" "$link" "$(status_reset)" "$mtu" "$mac"
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
        printf "Interface %s: admin %s%s%s, link %s%s%s\n" "$dev" "$(status_color "$admin")" "$admin" "$(status_reset)" "$(status_color "$link")" "$link" "$(status_reset)"
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
            echo "(detail hardware setara ethtool/udev not tersedia at FreeBSD; pakai pciconf -lv)"
        fi
    else
        if [ ! -d "/sys/class/net/$iface" ]; then
            echo "Error: interface $iface not found at system (show 'show interfaces' for list)." >&2; exit 33
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
