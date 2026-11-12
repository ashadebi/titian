#!/bin/sh
# TITIAN Fase 1 — operasi address interface (dipakai perintah
# `ip address` / `ipv6 address` di semua if-view, Linux + FreeBSD).
# Aturan pengalamatan (wajib, diuji di kedua VM):
#  - /31 (RFC 3021): kedua alamat host valid, tidak ada network/
#    broadcast terbuang. Linux: JANGAN pakai `brd +` untuk /31
#    (dan /32); FreeBSD: ifconfig menerima /31 apa adanya.
#  - PtP custom gaya MikroTik/PPP: local + peer sembarang, contoh
#    103.50.128.1 peer 10.10.10.10 (1 IP publik per link).
#    Linux: ip addr add <local> peer <peer> dev <iface>
#    FreeBSD: /32 lokal + host route ke peer (destination-address ifconfig
#    DIABAIKAN diam-diam di interface Ethernet broadcast — terbukti 28 Okt:
#    ifconfig hanya menempel broadcast, tanpa route ke peer).
#    Linux: ip addr add <local> peer <peer> dev <iface>
#  - Validasi: PTYPE tree hanya filter lapis pertama; helper ini
#    memvalidasi CIDR (v4 ketat, v6 ringan) lalu tool OS menjadi
#    gate ketat terakhir — input tidak valid gagal bersih (exit != 0),
#    tidak pernah tersimpan setengah jalan.
# POSIX sh (jalan di dash Debian dan sh FreeBSD).
set -u
OS=$(uname -s)

err() { echo "Error: $*" >&2; exit 33; }

# split_cidr <cidr> -> ADDR, PREFIX (PREFIX kosong bila tanpa /)
split_cidr() {
    case "$1" in
        */*) ADDR=${1%/*}; PREFIX=${1#*/} ;;
        *)   ADDR=$1; PREFIX="" ;;
    esac
}

valid_v4() {
    # $1 = dotted quad; return 0 bila valid
    local a rest o
    rest=$1
    for i in 1 2 3 4; do
        case "$rest" in
            *.*) o=${rest%%.*}; rest=${rest#*.} ;;
            *)   o=$rest; rest="" ;;
        esac
        case "$o" in
            ''|*[!0-9]*) return 1 ;;
        esac
        # tolak oktet kosong / leading zero berlebih? izinkan 0-255
        if [ "$o" -gt 255 ] 2>/dev/null; then return 1; fi
        # pastikan tidak ada sisa setelah oktet ke-4
        if [ "$i" -eq 4 ] && [ -n "$rest" ]; then return 1; fi
    done
    # pastikan tepat 4 oktet (tidak kurang)
    case "$1" in
        *.*.*.*) return 0 ;;
        *) return 1 ;;
    esac
}

valid_prefix_v4() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ] 2>/dev/null && [ "$1" -le 32 ] 2>/dev/null
}

valid_v6() {
    # ringan: hanya heksadesimal/titik-dua (+ titik untuk embedded v4)
    case "$1" in
        *:*)
            case "$1" in
                *[!0-9a-fA-F:.*]*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

valid_prefix_v6() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ] 2>/dev/null && [ "$1" -le 128 ] 2>/dev/null
}

# --- state persisten (sumber regenerasi .network/rc.conf) ---
STATE_DIR=${TITIAN_STATE_DIR:-/etc/titian/netstate}
state_add() {
    # $1=iface $2=line ("inet <cidr>" | "inet <local> peer <peer>" | "inet6 <cidr>")
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    f="$STATE_DIR/$1.addr"
    touch "$f" 2>/dev/null || return 0
    grep -qxF "$2" "$f" 2>/dev/null || echo "$2" >> "$f"
}
state_del() {
    # $1=iface $2=line-prefix-match (hapus baris yang diawali prefix ini)
    f="$STATE_DIR/$1.addr"
    [ -f "$f" ] || return 0
    esc=$(printf '%s' "$2" | sed 's/[.[\*^$]/\\&/g')
    grep -v "^$esc" "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f" 2>/dev/null || true
}

# --- v4 ---
addr_add() {
    # $1=iface $2=cidr $3=peer (boleh kosong)
    local iface=$1 cidr=$2 peer=$3
    split_cidr "$cidr"
    valid_v4 "$ADDR" || err "alamat IPv4 tidak valid: $cidr"
    if [ -n "$PREFIX" ]; then
        valid_prefix_v4 "$PREFIX" || err "prefix IPv4 tidak valid: $cidr"
    else
        PREFIX=32
    fi
    if [ -n "$peer" ]; then
        valid_v4 "$peer" || err "peer IPv4 tidak valid: $peer"
        if [ "$OS" = "FreeBSD" ]; then
            ifconfig "$iface" inet "$ADDR" -alias >/dev/null 2>&1
            ifconfig "$iface" inet "$ADDR" netmask 255.255.255.255 alias 2>/dev/null || \
                ifconfig "$iface" inet "$ADDR" netmask 255.255.255.255 alias || err "gagal set PtP $ADDR peer $peer di $iface"
            # route get TIDAK bisa jadi guard: ia fallback ke default route (exit 0)
            # meski host route belum ada. Hapus dulu (idempotent) lalu tambah.
            route delete -host "$peer" >/dev/null 2>&1 || true
            route add -host "$peer" -iface "$iface" >/dev/null 2>&1 || err "gagal tambah route peer $peer di $iface"
        else
            ip addr replace "$ADDR" peer "$peer" dev "$iface" || err "gagal set PtP $ADDR peer $peer di $iface"
        fi
        state_add "$iface" "inet $ADDR peer $peer"
        return 0
    fi
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$iface" inet "$ADDR/$PREFIX" -alias >/dev/null 2>&1
        ifconfig "$iface" inet "$ADDR/$PREFIX" alias || err "gagal set $cidr di $iface"
    else
        if [ "$PREFIX" -eq 31 ] || [ "$PREFIX" -eq 32 ]; then
            # RFC 3021: /31 tanpa broadcast; /32 juga tanpa brd
            ip addr replace "$ADDR/$PREFIX" dev "$iface" || err "gagal set $cidr di $iface"
        else
            ip addr replace "$ADDR/$PREFIX" brd + dev "$iface" || err "gagal set $cidr di $iface"
        fi
    fi
    state_add "$iface" "inet $ADDR/$PREFIX"
}

addr_set() {
    # seperti addr-add tapi menggantikan semua alamat v4 iface (semantik lo rtcli)
    local iface=$1 cidr=$2 peer=$3
    if [ "$OS" = "FreeBSD" ]; then
        # hapus semua inet (bukan inet6) yang ada di iface
        ifconfig "$iface" 2>/dev/null | awk '/^[[:space:]]*inet /{print $2}' | while read -r a; do
            ifconfig "$iface" inet "$a" -alias >/dev/null 2>&1
        done
    else
        ip -4 addr flush dev "$iface" 2>/dev/null
    fi
    addr_add "$iface" "$cidr" "$peer"
}

addr_del() {
    # $1=iface $2=cidr $3=peer (boleh kosong)
    local iface=$1 cidr=$2 peer=$3
    split_cidr "$cidr"
    valid_v4 "$ADDR" || err "alamat IPv4 tidak valid: $cidr"
    if [ -n "$peer" ]; then
        valid_v4 "$peer" || err "peer IPv4 tidak valid: $peer"
        if [ "$OS" = "FreeBSD" ]; then
            # hapus /32 + host route (idempotent: absen = sukses)
            ifconfig "$iface" inet "$ADDR" -alias >/dev/null 2>&1 || true
            route delete -host "$peer" >/dev/null 2>&1 || true
        else
            ip addr del "$ADDR" peer "$peer" dev "$iface" 2>/dev/null || \
                ip addr del "$ADDR" dev "$iface" || err "gagal hapus PtP $ADDR peer $peer di $iface"
        fi
        state_del "$iface" "inet $ADDR peer $peer"
        return 0
    fi
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$iface" inet "$ADDR" -alias || err "gagal hapus $cidr di $iface"
    else
        if [ -n "$PREFIX" ]; then
            ip addr del "$ADDR/$PREFIX" dev "$iface" || err "gagal hapus $cidr di $iface"
        else
            ip addr del "$ADDR" dev "$iface" || err "gagal hapus $cidr di $iface"
        fi
    fi
    state_del "$iface" "inet $ADDR/"
}

# --- v6 ---
addr6_add() {
    # $1=iface $2=cidr $3=peer (peer v6 hanya Linux; FreeBSD gated di XML)
    local iface=$1 cidr=$2 peer=$3
    split_cidr "$cidr"
    valid_v6 "$ADDR" || err "alamat IPv6 tidak valid: $cidr"
    if [ -n "$PREFIX" ]; then
        valid_prefix_v6 "$PREFIX" || err "prefix IPv6 tidak valid: $cidr"
    else
        PREFIX=128
    fi
    if [ -n "$peer" ]; then
        if [ "$OS" = "FreeBSD" ]; then
            err "peer IPv6 belum didukung di FreeBSD (gated)"
        fi
        valid_v6 "$peer" || err "peer IPv6 tidak valid: $peer"
        ip -6 addr replace "$ADDR" peer "$peer" dev "$iface" || err "gagal set PtP v6 $ADDR peer $peer di $iface"
        state_add "$iface" "inet6 $ADDR peer $peer"
        return 0
    fi
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$iface" inet6 "$ADDR/$PREFIX" -alias >/dev/null 2>&1
        ifconfig "$iface" inet6 "$ADDR/$PREFIX" alias || err "gagal set $cidr di $iface"
    else
        ip -6 addr replace "$ADDR/$PREFIX" dev "$iface" || err "gagal set $cidr di $iface"
    fi
    state_add "$iface" "inet6 $ADDR/$PREFIX"
}

addr6_del() {
    # $1=iface $2=cidr $3=peer (boleh kosong)
    local iface=$1 cidr=$2 peer=$3
    split_cidr "$cidr"
    valid_v6 "$ADDR" || err "alamat IPv6 tidak valid: $cidr"
    if [ -n "$peer" ]; then
        if [ "$OS" = "FreeBSD" ]; then
            err "peer IPv6 belum didukung di FreeBSD (gated)"
        fi
        ip -6 addr del "$ADDR" peer "$peer" dev "$iface" 2>/dev/null || \
            ip -6 addr del "$ADDR" dev "$iface" || err "gagal hapus PtP v6 $ADDR peer $peer di $iface"
        state_del "$iface" "inet6 $ADDR peer $peer"
        return 0
    fi
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$iface" inet6 "$ADDR" -alias || err "gagal hapus $cidr di $iface"
    else
        if [ -n "$PREFIX" ]; then
            ip -6 addr del "$ADDR/$PREFIX" dev "$iface" || err "gagal hapus $cidr di $iface"
        else
            ip -6 addr del "$ADDR" dev "$iface" || err "gagal hapus $cidr di $iface"
        fi
    fi
    state_del "$iface" "inet6 $ADDR/"
}

case "${1:-}" in
    addr-add)  addr_add "$2" "$3" "${4:-}" ;;
    addr-set)  addr_set "$2" "$3" "${4:-}" ;;
    addr-del)  addr_del "$2" "$3" "${4:-}" ;;
    addr6-add) addr6_add "$2" "$3" "${4:-}" ;;
    addr6-del) addr6_del "$2" "$3" "${4:-}" ;;
    *) echo "Usage: $0 {addr-add|addr-set|addr-del|addr6-add|addr6-del} <iface> <cidr> [peer]" >&2; exit 2 ;;
esac
