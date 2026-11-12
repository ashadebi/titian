#!/bin/sh
# TITIAN — perintah `system sysctl` (kernel parameter, kedua OS).
# Bukan restorasi rtcli: tree lama TIDAK punya perintah sysctl sama
# sekali; ini fitur baru.
#
# Jalur persistensi (tanpa daemon/service baru):
#  1. running-config: perintah punya CONFIG di tree, jadi `save` +
#     replay startup-config menjalankannya lagi.
#  2. cermin OS-native (diterapkan otomatis saat boot oleh OS sendiri):
#       Debian: /etc/sysctl.d/99-titian.conf (systemd-sysctl)
#       FreeBSD: blok marker #-TITIAN-# ... #-ENDTITIAN-# di
#               /etc/sysctl.conf (rc sysctl). Baris di luar blok
#               tidak pernah disentuh.
#  Sumber cermin = state file $STATE_ROOT/sysctl.titian (bukan parsing
#  file OS). Nilai sebelum-set pertama dicatat di sysctl.titian.prev
#  agar `no system sysctl` bisa mengembalikan nilai live semula;
#  bila nilai awal tidak tercatat, nilai live bertahan sampai reboot
#  (cermin sudah bersih sehingga boot berikutnya memakai default).
#
# Validasi: key harus berbentuk MIB bertitik dan HARUS dikenali kernel
# yang sedang jalan (`sysctl -n key` sukses) — ini otomatis membedakan
# kunci Linux (net.ipv4.*) dari FreeBSD (net.inet.*). Nilai menolak
# karakter kontrol dan metakarakter shell (; | & ` $ < > \ " ') agar
# aman ditulis ke file cermin; vektor berspasi (mis. tcp_rmem
# "4096 87380 6291456") diizinkan — tulis pakai tanda kutip di CLI.
# POSIX sh (jalan di dash Debian dan sh FreeBSD).
set -u
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
STATE="$STATE_ROOT/sysctl.titian"
PREV="$STATE_ROOT/sysctl.titian.prev"

err() { echo "Error: $*" >&2; exit 33; }
warn() {
    if [ -t 2 ]; then printf '\033[33mWarning(sysctl):\033[0m %s\n' "$*" >&2
    else echo "Warning(sysctl): $*" >&2; fi
}

valid_key() {
    # MIB bertitik: segmen alfanumerik/underscore, minimal satu titik
    case "$1" in
        *.*)
            case "$1" in
                *[!A-Za-z0-9_.]*) return 1 ;;
                *..*|.*|*.) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}
valid_value() {
    # tolak kosong dan metakarakter shell (karakter kontrol praktis
    # tidak mungkin lewat baris perintah klish; nilai vektor berspasi
    # diizinkan)
    case "$1" in
        '') return 1 ;;
        *';'*|*'|'*|*'&'*|*'`'*|*'$'*|*'<'*|*'>'*|*'\'*|*'"'*|*"'"*) return 1 ;;
        *) return 0 ;;
    esac
}

state_set() {
    # $1=key $2=value: ganti baris key di state (tanpa duplikat)
    local esc
    mkdir -p "$ROOT/etc" 2>/dev/null || return 0
    touch "$STATE" 2>/dev/null || return 0
    esc=$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')
    grep -v "^$esc=" "$STATE" > "$STATE.tmp" 2>/dev/null; mv "$STATE.tmp" "$STATE" 2>/dev/null || true
    echo "$1=$2" >> "$STATE"
}
state_del() {
    local esc
    [ -f "$STATE" ] || return 0
    esc=$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')
    grep -v "^$esc=" "$STATE" > "$STATE.tmp" 2>/dev/null; mv "$STATE.tmp" "$STATE" 2>/dev/null || true
}
prev_get() {
    # format file: key=nilai-awal (nilai sysctl praktis tak mengandung '=')
    local esc
    [ -f "$PREV" ] || return 0
    esc=$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')
    grep "^$esc=" "$PREV" 2>/dev/null | tail -1 | cut -d= -f2-
}
prev_set() {
    # catat nilai awal hanya bila key belum pernah dicatat
    local cur esc
    [ -n "$(prev_get "$1")" ] && return 0
    cur=$(sysctl -n "$1" 2>/dev/null) || return 0
    mkdir -p "$ROOT/etc" 2>/dev/null || return 0
    touch "$PREV" 2>/dev/null || return 0
    esc=$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')
    grep -v "^$esc=" "$PREV" > "$PREV.tmp" 2>/dev/null; mv "$PREV.tmp" "$PREV" 2>/dev/null || true
    echo "$1=$cur" >> "$PREV"
}
prev_del() {
    local esc
    [ -f "$PREV" ] || return 0
    esc=$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')
    grep -v "^$esc=" "$PREV" > "$PREV.tmp" 2>/dev/null; mv "$PREV.tmp" "$PREV" 2>/dev/null || true
}

mirror_linux() {
    local f=/etc/sysctl.d/99-titian.conf
    mkdir -p /etc/sysctl.d 2>/dev/null || { warn "tidak bisa mkdir /etc/sysctl.d"; return 0; }
    {
        echo "# TITIAN — dikelola perintah 'system sysctl'; do not edit manual"
        echo "# (diterapkan saat boot by systemd-sysctl; delete lewat 'no system sysctl <key>')"
        if [ -f "$STATE" ]; then
            # grep exit 1 bila state kosong (semua key dihapus) — itu
            # BUKAN gagal tulis; jangan biarkan statusnya menggagalkan mv
            grep -v '^$' "$STATE" 2>/dev/null || true
        fi
    } > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || { warn "gagal tulis $f"; return 0; }
}
mirror_freebsd() {
    local rc=/etc/sysctl.conf tmp
    tmp=$(mktemp /tmp/titian-sysctl.XXXXXX) || { warn "gagal mktemp"; return 0; }
    {
        if [ -f "$rc" ]; then
            awk '/^#-TITIAN-#/{skip=1; next} /^#-ENDTITIAN-#/{skip=0; next} !skip {print}' "$rc"
        fi
        echo "#-TITIAN-#"
        if [ -f "$STATE" ]; then
            # lihat mirror_linux: grep exit 1 saat state kosong != gagal
            grep -v '^$' "$STATE" 2>/dev/null || true
        fi
        echo "#-ENDTITIAN-#"
    } > "$tmp" 2>/dev/null
    if [ -f "$rc" ]; then
        cp -f "$rc" /etc/sysctl.conf.titian-bak 2>/dev/null || true
    fi
    cat "$tmp" > "$rc" 2>/dev/null || { warn "gagal tulis $rc"; rm -f "$tmp"; return 0; }
    rm -f "$tmp"
}
mirror() { if [ "$OS" = "FreeBSD" ]; then mirror_freebsd; else mirror_linux; fi; }

sysctl_set() {
    # $1=key $2=value
    local key=$1 val=$2 cur
    valid_key "$key" || err "key sysctl tidak valid (harus MIB bertitik, ex: net.ipv4.ip_forward): $key"
    valid_value "$val" || err "nilai sysctl ditolak (kosong / mengandung karakter kontrol atau metakarakter shell): $val"
    cur=$(sysctl -n "$key" 2>/dev/null) || err "key tidak dikenali kernel $OS ini: $key (kunci Linux net.ipv4.* tidak ada di FreeBSD dan sebaliknya)"
    prev_set "$key"
    if [ "$OS" = "FreeBSD" ]; then
        sysctl "$key=$val" >/dev/null 2>&1 || err "gagal set $key=$val (nilai di luar rentang yang diizinkan kernel?)"
    else
        sysctl -w "$key=$val" >/dev/null 2>&1 || err "gagal set $key=$val (nilai di luar rentang yang diizinkan kernel?)"
    fi
    state_set "$key" "$val"
    mirror
    echo "sysctl $key: $cur -> $val (live + persisten)"
}
sysctl_del() {
    # $1=key: hapus dari state+cermin; kembalikan nilai live semula bila tercatat
    local key=$1 prev
    valid_key "$key" || err "key sysctl tidak valid: $key"
    prev=$(prev_get "$key")
    state_del "$key"
    prev_del "$key"
    mirror
    if [ -n "$prev" ]; then
        if [ "$OS" = "FreeBSD" ]; then
            sysctl "$key=$prev" >/dev/null 2>&1 || warn "gagal kembalikan $key live ke $prev"
        else
            sysctl -w "$key=$prev" >/dev/null 2>&1 || warn "gagal kembalikan $key live ke $prev"
        fi
        echo "sysctl $key: deleted from mirror, value live dikembalikan to $prev"
    else
        echo "sysctl $key: deleted from mirror; value live bertahan sampai reboot (boot berikutnya memakai default OS)"
    fi
}

meaning() {
    # $1=key -> satu baris arti (kunci yang dikenal; sisanya "-")
    case "$1" in
        net.ipv4.ip_forward|net.inet.ip.forwarding) echo "router wajib 1: kernel meneruskan paket antar interface; 0 = host biasa (endpoint)." ;;
        net.ipv6.conf.all.forwarding|net.inet6.ip6.forwarding) echo "seperti ip_forward, untuk IPv6." ;;
        net.ipv4.conf.all.rp_filter|net.ipv4.conf.default.rp_filter) echo "reverse-path filter: 1=strict (tolak paket dari jalur tak terduga — merusak routing asimetris), 2=loose (disarankan untuk router), 0=mati." ;;
        net.core.netdev_max_backlog) echo "panjang antrean paket masuk sebelum diproses; naikkan bila drop RX saat burst." ;;
        net.core.rmem_max|net.core.wmem_max) echo "buffer socket maksimum yang boleh diminta aplikasi (menaikkan ini saja tanpa tcp_rmem/tcp_wmem tidak berefek)." ;;
        net.ipv4.tcp_rmem|net.ipv4.tcp_wmem) echo "buffer TCP min/default/maks (tiga angka); naikkan maks untuk sesi throughput tinggi/latensi tinggi (BGP jarak jauh, transfer besar)." ;;
        net.inet.tcp.sendbuf_max|net.inet.tcp.recvbuf_max) echo "buffer TCP maksimum FreeBSD; naikkan untuk sesi throughput tinggi/latensi tinggi." ;;
        net.ipv4.tcp_congestion_control) echo "algoritma congestion control TCP (cubic/bbr bila tersedia)." ;;
        *) echo "-" ;;
    esac
}
sysctl_show() {
    echo "Sysctl that dikelola Titian ($OS) — value live current:"
    if [ ! -s "$STATE" ]; then
        echo "  (none yet — pakai 'system sysctl <key> <value>' for menambah)"
        return 0
    fi
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        live=$(sysctl -n "$k" 2>/dev/null || echo "?")
        echo "  $k = $live  (tersimpan: $v)"
        echo "    arti: $(meaning "$k")"
    done < "$STATE"
}
sysctl_apply() {
    # terapkan ulang semua baris state (perbaikan manual; boot OS
    # sudah menerapkan cermin sendiri sehingga tidak di-hook ke boot)
    [ -f "$STATE" ] || return 0
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        if [ "$OS" = "FreeBSD" ]; then
            sysctl "$k=$v" >/dev/null 2>&1 || true
        else
            sysctl -w "$k=$v" >/dev/null 2>&1 || true
        fi
    done < "$STATE"
}

case "${1:-}" in
    set) sysctl_set "$2" "$3" ;;
    del) sysctl_del "$2" ;;
    show) sysctl_show ;;
    apply) sysctl_apply ;;
    mirror) mirror ;;
    *) echo "Usage: $0 {set|del|show|apply|mirror} ..." >&2; exit 2 ;;
esac
