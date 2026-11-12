#!/bin/sh
# TITIAN — parameter tuning interface (mtu, qlen, speed, offload, coalesce).
# Dipakai perintah `mtu`/`qlen`/`speed` di semua if-view dan perintah di view
# `options` (Linux) / `options` FreeBSD, kedua OS.
#
# Dua jalur persistensi (tanpa daemon/service baru):
#  1. running-config: tiap perintah punya CONFIG di tree, jadi `save`
#     + replay startup-config saat boot menjalankannya lagi.
#  2. cermin deklaratif titian-persist.sh: nilai dicatat di
#     netstate/<iface>.tuning, lalu ditulis ke
#       Debian: [Link] MTUBytes/TransmitQueueLength di
#               /etc/systemd/network/00-titian-<iface>.network
#               (offload/coalesce TIDAK punya padanan networkd — jalur
#               replay + apply-all di titian-boot.sh yang membawanya).
#       FreeBSD: opsi `mtu` + flag offload (-tso/-lro/rxcsum/...)
#               di baris ifconfig_<iface> blok #-TITIAN-# rc.conf.
#     titian-boot.sh menjalankan `titian-tune.sh apply-all` sehabis
#     replay (best-effort, idempotent) sebagai jaring pengaman bila
#     replay baris view `options` (nested) gagal.
#
# Semantik `no <param>` (perintah `no mtu`, `no tso`, dsb.):
#   menghapus catatan titian + mengembalikan nilai live ke nilai
#   SEBELUM Titian pertama kali menyetel kunci itu (dicatat di
#   <iface>.tuning.prev saat set pertama; bila tidak tercatat —
#   mis. `no` tanpa pernah set — dipakai default konvensional.
#   Prev HANYA dicatat bila nilai live saat itu berbeda dari target
#   (set yang sama dengan nilai live — mis. replay saat restart —
#   tidak menimpa prev; bila tidak, replay akan "mencatat" nilai
#   Titian sendiri sebagai "sebelum", dan `no` menjadi no-op).
#   mtu 1500, qlen 1000, tso/gro/gso/rx/tx/sg on, lro off,
#   rx-usecs 0, adaptive-rx off). Bila driver menolak ubah nilai live,
#   perintah tetap sukses dengan peringatan: nilai live bertahan
#   sampai reboot, dan cermin sudah bersih sehingga boot berikutnya
#   memakai default driver. CATATAN: `no` berarti "lupakan setelan
#   Titian", BUKAN "setelan persisten ke default" — bila mau nilai
#   default bertahan melewati reboot, pakai bentuk set-nya
#   (mis. `lro off`, bukan `no lro`).
#
# Batasan per-OS (jujur, bukan diam):
#   - speed: Linux saja (ethtool -s). FreeBSD tidak butuh speed-set
#     untuk lagg (terbukti merespons LACP dengan benar tanpa itu),
#     dan media/mediaopt vtnet tidak berefek pada lagg — jadi tidak
#     ada perintah speed di view FreeBSD (bukan ditolak, memang tidak
#     ada; pola yang sama dengan qlen/coalesce Linux saja).
#   - qlen (txqueuelen): Linux saja. FreeBSD tidak punya padanan
#     per-interface yang setara.
#   - coalesce (rx-usecs/adaptive-rx): Linux (ethtool -C) saja.
#     FreeBSD tidak punya knob generik yang setara.
#   - offload FreeBSD: hanya tso/lro/rx/tx (ifconfig: tso/-tso,
#     lro/-lro, rxcsum/-rxcsum, txcsum/-txcsum). gro/gso/sg tidak
#     punya padanan ifconfig -> ditolak bersih dengan pesan.
#   - ethtool: bila biner tidak ada, perintah offload/coalesce Linux
#     gagal bersih (bukan diam).
# POSIX sh (jalan di dash Debian dan sh FreeBSD).
set -u
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
STATE_DIR=${TITIAN_STATE_DIR:-/etc/titian/netstate}
PERSIST=${RT_SBIN:-$ROOT/sbin}/titian-persist.sh

err() { echo "Error: $*" >&2; exit 33; }
warn() { echo "Warning(tune): $*" >&2; }

# --- state file <iface>.tuning ---
tune_set() {
    # $1=iface $2=line ("mtu 9000" | "qlen 1000" | "offload tso on" |
    # "coalesce rx-usecs 125" | "coalesce adaptive-rx on")
    local iface=$1 line=$2 key f
    key=${line%% *}
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    f="$STATE_DIR/$iface.tuning"
    touch "$f" 2>/dev/null || return 0
    case "$line" in
        'offload '*)
            # hapus baris offload <feat> lama apa pun nilainya (on->off
            # harus menggantikan, bukan menumpuk dua baris)
            _feat=${line#offload }; _feat=${_feat%% *}
            grep -v "^offload $_feat " "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f" 2>/dev/null || true ;;
        'coalesce '*)
            _kind=${line#coalesce }; _kind=${_kind%% *}
            grep -v "^coalesce $_kind " "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f" 2>/dev/null || true ;;
        *) grep -v "^$key " "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f" 2>/dev/null || true ;;
    esac
    echo "$line" >> "$f"
}
tune_del() {
    # $1=iface $2=prefix ("mtu" | "qlen" | "offload tso" | "coalesce rx-usecs")
    local f="$STATE_DIR/$1.tuning"
    [ -f "$f" ] || return 0
    grep -v "^$2 " "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f" 2>/dev/null || true
}
tune_get() {
    # $1=iface $2=prefix -> nilai (kolom terakhir) atau kosong
    local f="$STATE_DIR/$1.tuning"
    [ -f "$f" ] || return 0
    grep "^$2 " "$f" 2>/dev/null | tail -1 | awk '{print $NF}'
}
# --- nilai sebelum-set pertama (untuk `no` yang mengembalikan) ---
tune_prev_get() {
    # $1=iface $2=key ("mtu"|"qlen"|"offload tso"|"coalesce rx-usecs")
    local f="$STATE_DIR/$1.tuning.prev"
    [ -f "$f" ] || return 0
    grep "^$2=" "$f" 2>/dev/null | tail -1 | cut -d= -f2-
}
tune_prev_set() {
    # $1=iface $2=key $3=nilai-awal: catat hanya bila belum tercatat
    local f="$STATE_DIR/$1.tuning.prev"
    [ -n "$(tune_prev_get "$1" "$2")" ] && return 0
    [ -n "$3" ] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    touch "$f" 2>/dev/null || return 0
    echo "$2=$3" >> "$f"
}
tune_prev_del() {
    local f="$STATE_DIR/$1.tuning.prev"
    [ -f "$f" ] || return 0
    grep -v "^$2=" "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f" 2>/dev/null || true
}
live_mtu() {
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i == "mtu") {print $(i+1); exit}}'
    else
        cat "/sys/class/net/$1/mtu" 2>/dev/null
    fi
}
live_offload() {
    # $1=iface $2=feat -> on|off (kosong bila tak terbaca)
    local line
    if [ "$OS" = "FreeBSD" ]; then
        case "$2" in
            tso) (fbsd_opt_has "$1" TSO4 || fbsd_opt_has "$1" TSO6) && echo on || echo off ;;
            lro) fbsd_opt_has "$1" LRO && echo on || echo off ;;
            rx)  fbsd_opt_has "$1" RXCSUM && echo on || echo off ;;
            tx)  fbsd_opt_has "$1" TXCSUM && echo on || echo off ;;
            *) echo "" ;;
        esac
    else
        line=$(ethtool -k "$1" 2>/dev/null | grep "^$(offload_ethtool_name "$2"): " | head -1)
        echo "$line" | awk '{print $2}'
    fi
}
sync() {
    # Regenerasi cermin + reload networkd, lalu pasang ulang slave bond
    # bila interface ini anggota bond (regen+reload memicu reconfigure
    # networkd yang melepas slave — attach-bond menutup celah itu).
    # No-op untuk interface biasa (tanpa file .bond).
    [ -x "$PERSIST" ] && "$PERSIST" sync-if "$1" 2>/dev/null || true
    [ -x "$PERSIST" ] && "$PERSIST" attach-bond "$1" 2>/dev/null || true
}

valid_int() {
    # $1=nilai $2=min $3=max
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}

iface_exists() {
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$1" >/dev/null 2>&1
    else
        [ -d "/sys/class/net/$1" ]
    fi
}

# --- readback: perintah set WAJIB membuktikan nilai live berubah.
# (Pelajaran dari virtio lab: `ethtool -C ... adaptive-rx on` exit 0
# tapi nilai live tetap off — tanpa readback, CLI akan mencatat
# setelan palsu. Karena itu SET yang gagal readback = gagal total,
# tanpa mencatat apa pun.)
readback_mtu() {
    # $1=iface $2=mtu-harapan -> 0 bila cocok
    # FreeBSD: mtu ada di baris flags yang sama ("vtnet1: flags=... mtu
    # 1400"), BUKAN di baris sendiri — awk harus memindai semua kolom.
    local cur
    if [ "$OS" = "FreeBSD" ]; then
        cur=$(ifconfig "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i == "mtu") {print $(i+1); exit}}')
    else
        cur=$(cat "/sys/class/net/$1/mtu" 2>/dev/null)
    fi
    [ "$cur" = "$2" ]
}
fbsd_opt_tokens() {
    # $1=iface -> daftar token options=<> dipisah koma (baris options
    # utama saja; baris "nd6 options=" sengaja dikecualikan)
    ifconfig "$1" 2>/dev/null | awk '/^[[:space:]]options=/{print; exit}' | sed 's/.*<//; s/>.*//'
}
fbsd_opt_has() {
    # $1=iface $2=token -> 0 bila token PERSIS ada (cocok koma, bukan
    # substring: "TSO" tidak boleh cocok "VLAN_HWTSO", "RXCSUM" tidak
    # boleh cocok "RXCSUM_IPV6")
    local toks
    toks=$(fbsd_opt_tokens "$1")
    case ",$toks," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

# --- mtu ---
mtu_set() {
    # $1=iface $2=mtu (tree MTU ptype: 68-9000)
    local iface=$1 mtu=$2
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    valid_int "$mtu" 68 9000 || err "mtu harus 68-9000 (batas ptype MTU tree): $mtu"
    _cur=$(live_mtu "$iface"); [ "$_cur" != "$mtu" ] && tune_prev_set "$iface" "mtu" "$_cur"
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$iface" mtu "$mtu" || err "gagal set mtu $mtu di $iface"
    else
        ip link set dev "$iface" mtu "$mtu" || err "gagal set mtu $mtu di $iface"
    fi
    readback_mtu "$iface" "$mtu" || err "mtu $iface tidak berubah menjadi $mtu (perintah diterima tapi nilai live menolak — tidak dicatat)"
    tune_set "$iface" "mtu $mtu"
    sync "$iface"
}
mtu_del() {
    local iface=$1 prev
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    prev=$(tune_prev_get "$iface" "mtu")
    [ -n "$prev" ] || prev=1500
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$iface" mtu "$prev" 2>/dev/null || warn "gagal kembalikan mtu live ke $prev di $iface (cermin tetap dibersihkan)"
    else
        ip link set dev "$iface" mtu "$prev" 2>/dev/null || warn "gagal kembalikan mtu live ke $prev di $iface (cermin tetap dibersihkan)"
    fi
    tune_del "$iface" "mtu"
    tune_prev_del "$iface" "mtu"
    sync "$iface"
}

# --- qlen (Linux saja) ---
qlen_set() {
    # $1=iface $2=qlen
    local iface=$1 q=$2
    [ "$OS" = "FreeBSD" ] && err "qlen (txqueuelen) tidak punya padanan di FreeBSD"
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    valid_int "$q" 0 100000 || err "qlen harus 0-100000: $q"
    _cur=$(cat "/sys/class/net/$iface/tx_queue_len" 2>/dev/null); [ "$_cur" != "$q" ] && tune_prev_set "$iface" "qlen" "$_cur"
    # Dipakai bentuk panjang `txqueuelen` (terdokumentasi); bentuk
    # singkat `qlen` dari tree lama TERVERIFIKASI juga jalan di
    # iproute2 Debian 13 (diuji: qlen 5000 mengubah txqueuelen) —
    # yang diperbaiki di sini adalah exit code yang dicek +
    # persistensi, bukan sintaksnya.
    ip link set dev "$iface" txqueuelen "$q" || err "gagal set txqueuelen $q di $iface"
    [ "$(cat "/sys/class/net/$iface/tx_queue_len" 2>/dev/null)" = "$q" ] || err "txqueuelen $iface tidak berubah menjadi $q (tidak dicatat)"
    tune_set "$iface" "qlen $q"
    sync "$iface"
}
qlen_del() {
    local iface=$1 prev
    [ "$OS" = "FreeBSD" ] && err "qlen (txqueuelen) tidak punya padanan di FreeBSD"
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    prev=$(tune_prev_get "$iface" "qlen")
    [ -n "$prev" ] || prev=1000
    ip link set dev "$iface" txqueuelen "$prev" 2>/dev/null || warn "gagal kembalikan txqueuelen live ke $prev di $iface (cermin tetap dibersihkan)"
    tune_del "$iface" "qlen"
    tune_prev_del "$iface" "qlen"
    sync "$iface"
}

# --- offload ---
offload_feat_ok() {
    # $1=feat -> 0 bila dikenal
    case "$1" in tso|gro|lro|gso|rx|tx|sg) return 0 ;; *) return 1 ;; esac
}
offload_default() {
    # $1=feat -> default konvensional
    case "$1" in lro) echo "off" ;; *) echo "on" ;; esac
}
offload_ethtool_name() {
    # $1=feat -> nama baris ethtool -k
    case "$1" in
        tso) echo "tcp-segmentation-offload" ;;
        gro) echo "generic-receive-offload" ;;
        lro) echo "large-receive-offload" ;;
        gso) echo "generic-segmentation-offload" ;;
        rx)  echo "rx-checksumming" ;;
        tx)  echo "tx-checksumming" ;;
        sg)  echo "scatter-gather" ;;
    esac
}
offload_readback() {
    # $1=iface $2=feat $3=on|off -> 0 bila nilai live cocok
    local iface=$1 feat=$2 val=$3 line state flag
    if [ "$OS" = "FreeBSD" ]; then
        case "$feat:$val" in
            tso:on)  fbsd_opt_has "$iface" TSO4 || fbsd_opt_has "$iface" TSO6 ;;
            tso:off) ! fbsd_opt_has "$iface" TSO4 && ! fbsd_opt_has "$iface" TSO6 ;;
            lro:on)  fbsd_opt_has "$iface" LRO ;;
            lro:off) ! fbsd_opt_has "$iface" LRO ;;
            rx:on)   fbsd_opt_has "$iface" RXCSUM ;;
            rx:off)  ! fbsd_opt_has "$iface" RXCSUM ;;
            tx:on)   fbsd_opt_has "$iface" TXCSUM ;;
            tx:off)  ! fbsd_opt_has "$iface" TXCSUM ;;
            *) return 1 ;;
        esac
    else
        line=$(ethtool -k "$iface" 2>/dev/null | grep "^$(offload_ethtool_name "$feat"): " | head -1)
        state=$(echo "$line" | awk '{print $2}')
        [ "$state" = "$val" ]
    fi
}
offload_set() {
    # $1=iface $2=feat $3=on|off
    local iface=$1 feat=$2 val=$3 flag
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    offload_feat_ok "$feat" || err "fitur offload tidak dikenal: $feat (tso gro lro gso rx tx sg)"
    case "$val" in on|off) ;; *) err "nilai offload harus on|off: $val" ;; esac
    _cur=$(live_offload "$iface" "$feat"); [ "$_cur" != "$val" ] && tune_prev_set "$iface" "offload $feat" "$_cur"
    if [ "$OS" = "FreeBSD" ]; then
        case "$feat" in
            tso) flag=tso ;; lro) flag=lro ;;
            rx)  flag=rxcsum ;; tx) flag=txcsum ;;
            *) err "offload $feat tidak punya padanan ifconfig di FreeBSD (yang tersedia: tso lro rx tx)" ;;
        esac
        if [ "$val" = "off" ]; then flag="-$flag"; fi
        ifconfig "$iface" "$flag" || err "gagal set $feat $val di $iface (driver mungkin tidak mendukung)"
    else
        command -v ethtool >/dev/null 2>&1 || err "ethtool tidak ditemukan di host ini"
        ethtool -K "$iface" "$feat" "$val" || err "gagal set $feat $val di $iface (fitur mungkin [fixed] oleh driver)"
    fi
    offload_readback "$iface" "$feat" "$val" || err "$feat $iface tidak berubah menjadi $val (perintah diterima tapi nilai live menolak — tidak dicatat)"
    tune_set "$iface" "offload $feat $val"
    sync "$iface"
}
offload_del() {
    # $1=iface $2=feat -> kembalikan nilai sebelum-set pertama;
    # bila tak tercatat, pakai default konvensional
    local iface=$1 feat=$2 def
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    offload_feat_ok "$feat" || err "fitur offload tidak dikenal: $feat"
    def=$(tune_prev_get "$iface" "offload $feat")
    [ -n "$def" ] || def=$(offload_default "$feat")
    # pakai jalur set tapi tanpa mencatat (lalu hapus catatan)
    if [ "$OS" = "FreeBSD" ]; then
        case "$feat" in
            tso) flag=tso ;; lro) flag=lro ;;
            rx)  flag=rxcsum ;; tx) flag=txcsum ;;
            *) warn "offload $feat tidak punya padanan ifconfig di FreeBSD; catatan tetap dihapus" ;;
        esac
        if [ -n "${flag:-}" ]; then
            if [ "$def" = "off" ]; then flag="-$flag"; fi
            ifconfig "$iface" "$flag" 2>/dev/null || warn "gagal kembalikan $feat live ke $def di $iface (cermin tetap dibersihkan)"
        fi
    else
        if command -v ethtool >/dev/null 2>&1; then
            ethtool -K "$iface" "$feat" "$def" 2>/dev/null || warn "gagal kembalikan $feat live ke $def di $iface (cermin tetap dibersihkan)"
        fi
    fi
    tune_del "$iface" "offload $feat"
    tune_prev_del "$iface" "offload $feat"
    sync "$iface"
}

# --- coalesce (Linux saja) ---
coalesce_set() {
    # $1=iface $2=kind $3=value ; kind=rx-usecs|adaptive-rx
    local iface=$1 kind=$2 val=$3
    [ "$OS" = "FreeBSD" ] && err "coalesce tidak punya padanan generik di FreeBSD"
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    command -v ethtool >/dev/null 2>&1 || err "ethtool tidak ditemukan di host ini"
    case "$kind" in
        rx-usecs)
            valid_int "$val" 0 1000 || err "rx-usecs harus 0-1000: $val"
            _cur=$(ethtool -c "$iface" 2>/dev/null | awk '/^RX-usecs:/{print $2}'); [ "$_cur" != "$val" ] && tune_prev_set "$iface" "coalesce rx-usecs" "$_cur"
            ethtool -C "$iface" rx-usecs "$val" || err "gagal set rx-usecs $val di $iface"
            _live=$(ethtool -c "$iface" 2>/dev/null | awk '/^RX-usecs:/{print $2}')
            [ "$_live" = "$val" ] || err "rx-usecs $iface tidak berubah menjadi $val (live: ${_live:-?} — driver mengabaikan setelan; tidak dicatat)"
            ;;
        adaptive-rx)
            case "$val" in on|off) ;; *) err "adaptive-rx harus on|off: $val" ;; esac
            _cur=$(ethtool -c "$iface" 2>/dev/null | awk '/^Adaptive RX:/{print $3}'); [ "$_cur" != "$val" ] && tune_prev_set "$iface" "coalesce adaptive-rx" "$_cur"
            ethtool -C "$iface" adaptive-rx "$val" || err "gagal set adaptive-rx $val di $iface"
            _live=$(ethtool -c "$iface" 2>/dev/null | awk '/^Adaptive RX:/{print $3}')
            [ "$_live" = "$val" ] || err "adaptive-rx $iface tidak berubah menjadi $val (live: ${_live:-?} — driver mengabaikan setelan; tidak dicatat)"
            ;;
        *) err "jenis coalesce tidak dikenal: $kind (rx-usecs adaptive-rx)" ;;
    esac
    tune_set "$iface" "coalesce $kind $val"
    sync "$iface"
}
coalesce_del() {
    # $1=iface $2=kind -> kembalikan nilai sebelum-set pertama;
    # bila tak tercatat, pakai default (rx-usecs 0, adaptive-rx off)
    local iface=$1 kind=$2 def
    [ "$OS" = "FreeBSD" ] && err "coalesce tidak punya padanan generik di FreeBSD"
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    if command -v ethtool >/dev/null 2>&1; then
        case "$kind" in
            rx-usecs)
                def=$(tune_prev_get "$iface" "coalesce rx-usecs"); [ -n "$def" ] || def=0
                ethtool -C "$iface" rx-usecs "$def" 2>/dev/null || warn "gagal kembalikan rx-usecs live ke $def di $iface (cermin tetap dibersihkan)" ;;
            adaptive-rx)
                def=$(tune_prev_get "$iface" "coalesce adaptive-rx"); [ -n "$def" ] || def=off
                ethtool -C "$iface" adaptive-rx "$def" 2>/dev/null || warn "gagal kembalikan adaptive-rx live ke $def di $iface (cermin tetap dibersihkan)" ;;
            *) err "jenis coalesce tidak dikenal: $kind" ;;
        esac
    fi
    tune_del "$iface" "coalesce $kind"
    tune_prev_del "$iface" "coalesce $kind"
    sync "$iface"
}

# --- speed (Linux saja; gerbang LACP 802.3ad di atas virtio) ---
# Driver bonding 802.3ad wajib speed/duplex non-nol untuk kalkulasi
# LACP port key; virtio_net default melaporkan Unknown sehingga slave
# MII down dan tidak ada LACPDU yang dikirim (log: failed to get link
# speed/duplex). ethtool -s adalah kondisi perlu DAN cukup di lab ini
# (terbukti A/B reboot, gali LACP 1 Nov 2026): nilai arbitrer untuk
# link virtual, tapi harus sama di semua slave satu bond.
# State: satu baris "speed <nilai> duplex <full|half>" di .tuning
# (persistensi = replay startup-config + apply-all, sama seperti
# offload/coalesce yang tidak punya padanan networkd).
speed_ok() {
    case "$1" in 10|100|1000|2500|5000|10000|25000|40000|50000|100000) return 0 ;; *) return 1 ;; esac
}
live_speed_duplex() {
    # $1=iface -> "Speed/Duplex" live, mis "1000/Full" atau "Unknown/Unknown"
    local sp dp
    sp=$(ethtool "$1" 2>/dev/null | awk -F': ' '/^[[:space:]]*Speed:/{print $2; exit}')
    dp=$(ethtool "$1" 2>/dev/null | awk -F': ' '/^[[:space:]]*Duplex:/{print $2; exit}')
    case "$sp" in *'Mb/s') sp=${sp%Mb/s} ;; *) sp="Unknown" ;; esac
    case "$dp" in Full|full) dp="Full" ;; Half|half) dp="Half" ;; *) dp="Unknown" ;; esac
    echo "$sp/$dp"
}
speed_set() {
    # $1=iface $2=speed $3=duplex (kosong -> full)
    local iface=$1 sp=$2 dp=${3:-full} want cur live
    [ "$OS" = "FreeBSD" ] && err "speed tidak punya padanan di FreeBSD (lagg FreeBSD tidak butuh speed-set untuk merespons LACP)"
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    speed_ok "$sp" || err "speed harus salah satu dari 10 100 1000 2500 5000 10000 25000 40000 50000 100000 (Mb/s): $sp"
    case "$dp" in full|Full) dp=full ;; half|Half) dp=half ;; *) err "duplex harus full|half: $dp" ;; esac
    command -v ethtool >/dev/null 2>&1 || err "ethtool tidak ditemukan di host ini"
    if [ "$dp" = "full" ]; then want="$sp/Full"; else want="$sp/Half"; fi
    cur=$(live_speed_duplex "$iface")
    [ "$cur" != "$want" ] && tune_prev_set "$iface" "speed" "$cur"
    ethtool -s "$iface" speed "$sp" duplex "$dp" || err "gagal set speed $sp duplex $dp di $iface (driver menolak — tidak dicatat)"
    live=$(live_speed_duplex "$iface")
    [ "$live" = "$want" ] || err "speed $iface tidak berubah menjadi $want (live: $live — driver mengabaikan setelan; tidak dicatat)"
    tune_set "$iface" "speed $sp duplex $dp"
    sync "$iface"
}
speed_del() {
    # $1=iface: hapus catatan speed; live hanya bisa dikembalikan bila
    # nilai sebelum-set pertama tercatat DAN bukan Unknown (driver
    # tidak punya operasi unset — nilai live bertahan sampai reboot).
    local iface=$1 prev psp pdp
    [ "$OS" = "FreeBSD" ] && err "speed tidak punya padanan di FreeBSD"
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    prev=$(tune_prev_get "$iface" "speed")
    if [ -n "$prev" ] && [ "$prev" != "Unknown/Unknown" ]; then
        psp=${prev%%/*}; pdp=${prev##*/}
        case "$pdp" in
            Full) pdp=full ;;
            Half) pdp=half ;;
            *) pdp="" ;;
        esac
        if [ -n "$pdp" ] && command -v ethtool >/dev/null 2>&1; then
            ethtool -s "$iface" speed "$psp" duplex "$pdp" 2>/dev/null || warn "gagal kembalikan speed live ke $prev di $iface (cermin tetap dibersihkan)"
        fi
    else
        warn "tidak ada nilai speed sebelum-set yang bisa dikembalikan (driver tidak punya operasi unset): nilai live bertahan sampai reboot, cermin sudah bersih sehingga boot berikutnya memakai default driver"
    fi
    tune_del "$iface" "speed"
    tune_prev_del "$iface" "speed"
    sync "$iface"
}
speed_set_quiet() {
    # seperti speed_set tapi tanpa tulis state/sync (dipakai apply)
    [ "$OS" = "FreeBSD" ] && return 0
    command -v ethtool >/dev/null 2>&1 || return 0
    ethtool -s "$1" speed "$2" duplex "$3" 2>/dev/null || true
}

# --- apply ulang (jaring pengaman boot; idempotent) ---
apply_iface() {
    # $1=iface: terapkan semua baris .tuning live (tanpa tulis ulang state)
    local iface=$1 f line a b c
    f="$STATE_DIR/$iface.tuning"
    [ -f "$f" ] || return 0
    iface_exists "$iface" || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line; a=${1:-}; b=${2:-}; c=${3:-}
        case "$a" in
            mtu) if [ "$OS" = "FreeBSD" ]; then ifconfig "$iface" mtu "$b" 2>/dev/null || true; else ip link set dev "$iface" mtu "$b" 2>/dev/null || true; fi ;;
            qlen) [ "$OS" != "FreeBSD" ] && ip link set dev "$iface" txqueuelen "$b" 2>/dev/null || true ;;
            offload) offload_set_quiet "$iface" "$b" "$c" ;;
            coalesce) coalesce_set_quiet "$iface" "$b" "$c" ;;
            speed) speed_set_quiet "$iface" "$b" "${d:-full}" ;;
        esac
    done < "$f"
}
offload_set_quiet() {
    # seperti offload_set tapi tanpa tulis state/sync (dipakai apply)
    local iface=$1 feat=$2 val=$3 flag
    if [ "$OS" = "FreeBSD" ]; then
        case "$feat" in
            tso) flag=tso ;; lro) flag=lro ;;
            rx)  flag=rxcsum ;; tx) flag=txcsum ;; *) return 0 ;;
        esac
        [ "$val" = "off" ] && flag="-$flag"
        ifconfig "$iface" "$flag" 2>/dev/null || true
    else
        command -v ethtool >/dev/null 2>&1 || return 0
        ethtool -K "$iface" "$feat" "$val" 2>/dev/null || true
    fi
}
coalesce_set_quiet() {
    local iface=$1 kind=$2 val=$3
    [ "$OS" = "FreeBSD" ] && return 0
    command -v ethtool >/dev/null 2>&1 || return 0
    case "$kind" in
        rx-usecs) ethtool -C "$iface" rx-usecs "$val" 2>/dev/null || true ;;
        adaptive-rx) ethtool -C "$iface" adaptive-rx "$val" 2>/dev/null || true ;;
    esac
}
apply_all() {
    local m iface
    for m in "$STATE_DIR"/*.tuning; do
        [ -e "$m" ] || continue
        iface=$(basename "$m" .tuning)
        apply_iface "$iface"
    done
}

# --- show tuning (dipakai `show interfaces tuning <iface>`) ---
show_iface() {
    local iface=$1
    iface_exists "$iface" || err "interface $iface tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
    echo "Tuning $iface ($OS) — nilai live + arti singkat"
    echo "  (nilai bertanda * = pernah di-set lewat Titian / tercatat di cermin)"
    if [ "$OS" = "FreeBSD" ]; then
        _show_fbsd "$iface"
    else
        _show_linux "$iface"
    fi
}
_mark() {
    # $1=iface $2=prefix -> "*" bila tercatat, "" bila tidak
    [ -n "$(tune_get "$1" "$2")" ] && echo "*" || echo ""
}
_show_linux() {
    local iface=$1 m mtu q
    m=$(_mark "$iface" "mtu")
    mtu=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo "?")
    echo "  mtu${m}: $mtu — ukuran paket terbesar yang boleh lewat interface; 1500 = default Ethernet, 9000 = jumbo (wajib didukung seluruh path, kalau tidak paket di-drop/difragmentasi)."
    q=$(cat "/sys/class/net/$iface/tx_queue_len" 2>/dev/null || echo "?")
    m=$(_mark "$iface" "qlen")
    echo "  txqueuelen${m}: $q — panjang antrean kirim; antrean besar menahan burst tapi menambah latensi antre (bufferbloat). Default 1000 (1G), 10000 (10G)."
    if command -v ethtool >/dev/null 2>&1; then
        _sp=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/^[[:space:]]*Speed:/{print $2; exit}')
        _dp=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/^[[:space:]]*Duplex:/{print $2; exit}')
        [ -n "$_sp" ] || _sp="(tidak dilaporkan driver)"
        [ -n "$_dp" ] || _dp="(tidak dilaporkan driver)"
        echo "  speed$(_mark "$iface" "speed"): $_sp / $_dp — kecepatan + duplex yang dilaporkan driver; WAJIB non-nol + full untuk bonding 802.3ad (tanpa ini slave MII down dan tidak ada LACPDU yang dikirim). Nilai arbitrer untuk link virtual, tapi harus sama di semua slave satu bond."
    else
        echo "  speed: ethtool tidak tersedia di host ini (tidak bisa dibaca)."
    fi
    if command -v ethtool >/dev/null 2>&1; then
        ethtool -k "$iface" 2>/dev/null | awk '/^[a-z0-9-]+:/{print}' | while read -r line; do
            feat=${line%%:*}; rest=${line#*:}
            case "$feat" in
                tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload|rx-checksumming|tx-checksumming|scatter-gather)
                    case "$feat" in
                        tcp-segmentation-offload) short=tso; meaning="NIC memotong segmen TCP besar jadi paket MTU; hemat CPU untuk trafik lokal, tidak memengaruhi paket yang di-forward." ;;
                        generic-segmentation-offload) short=gso; meaning="Versi software dari TSO di kernel; hemat CPU untuk trafik lokal." ;;
                        generic-receive-offload) short=gro; meaning="Kernel menggabung paket-paket receive searah jadi satu segmen besar; hemat CPU receive. Aman untuk router (beda dengan LRO hardware)." ;;
                        large-receive-offload) short=lro; meaning="Hardware menggabung paket receive; HARUS off di router/bridge karena bisa merusak semantik forwarding." ;;
                        rx-checksumming) short=rx; meaning="NIC menghitung checksum paket masuk; hemat CPU, hampir selalu on." ;;
                        tx-checksumming) short=tx; meaning="NIC menghitung checksum paket keluar; hemat CPU, hampir selalu on." ;;
                        scatter-gather) short=sg; meaning="NIC mengirim dari banyak buffer memori sekaligus; prasyarat TSO/GSO, hampir selalu on." ;;
                    esac
                    m=$(_mark "$iface" "offload $short")
                    echo "  $short${m}: $(echo "$rest" | awk '{print $1}') — $meaning"
                    ;;
            esac
        done
        _c=$(ethtool -c "$iface" 2>/dev/null)
        _rxu=$(echo "$_c" | awk '/^RX-usecs:/{print $2}'); [ -n "$_rxu" ] || _rxu="(tidak dilaporkan driver)"
        _arx=$(echo "$_c" | awk '/^Adaptive RX:/{print $3}'); [ -n "$_arx" ] || _arx="(tidak dilaporkan driver)"
        echo "  rx-usecs$(_mark "$iface" "coalesce rx-usecs"): $_rxu — jeda tunda interupsi receive (mikrodetik); nilai besar = interupsi lebih jarang (hemat CPU, latensi naik), 0 = interupsi segera. Default driver, umum 125."
        echo "  adaptive-rx$(_mark "$iface" "coalesce adaptive-rx"): $_arx — driver menyesuaikan rx-usecs otomatis ikut beban; on untuk beban campuran, off bila latensi harus deterministik. Default off."
    else
        echo "  offload/coalesce: ethtool tidak tersedia di host ini (tidak bisa dibaca)."
    fi
}
_show_fbsd() {
    local iface=$1 out
    out=$(ifconfig "$iface" 2>/dev/null)
    echo "  mtu$(_mark "$iface" "mtu"): $(echo "$out" | awk '{for(i=1;i<=NF;i++) if ($i == "mtu") {print $(i+1); exit}}') — ukuran paket terbesar; 1500 = default, 9000 = jumbo (wajib didukung seluruh path)."
    echo "  qlen: (tidak ada padanan FreeBSD — txqueuelen adalah konsep Linux.)"
    echo "  flags ifconfig: options=<$(fbsd_opt_tokens "$iface")>"
    if fbsd_opt_has "$iface" TSO4 || fbsd_opt_has "$iface" TSO6; then _tso=on; else _tso=off; fi
    if fbsd_opt_has "$iface" LRO; then _lro=on; else _lro=off; fi
    if fbsd_opt_has "$iface" RXCSUM; then _rx=on; else _rx=off; fi
    if fbsd_opt_has "$iface" TXCSUM; then _tx=on; else _tx=off; fi
    echo "    tso$(_mark "$iface" "offload tso"): $_tso (flag TSO4/TSO6) — NIC memotong segmen TCP; hemat CPU trafik lokal."
    echo "    lro$(_mark "$iface" "offload lro"): $_lro — HARUS off di router/bridge (bisa merusak forwarding); pakai GRO tidak tersedia di FreeBSD, jadi biarkan off."
    echo "    rxcsum$(_mark "$iface" "offload rx"): $_rx — checksum receive oleh NIC; hampir selalu on."
    echo "    txcsum$(_mark "$iface" "offload tx"): $_tx — checksum transmit oleh NIC; hampir selalu on."
    echo "    gro/gso/sg: tidak punya padanan ifconfig di FreeBSD."
    echo "  coalesce: tidak punya padanan generik di FreeBSD."
}

case "${1:-}" in
    mtu) mtu_set "$2" "$3" ;;
    mtu-del) mtu_del "$2" ;;
    qlen) qlen_set "$2" "$3" ;;
    qlen-del) qlen_del "$2" ;;
    offload) offload_set "$2" "$3" "$4" ;;
    offload-del) offload_del "$2" "$3" ;;
    coalesce) coalesce_set "$2" "$3" "$4" ;;
    coalesce-del) coalesce_del "$2" "$3" ;;
    speed) speed_set "$2" "$3" "${4:-}" ;;
    speed-del) speed_del "$2" ;;
    apply) apply_iface "$2" ;;
    apply-all) apply_all ;;
    show) show_iface "$2" ;;
    *) echo "Usage: $0 {mtu|mtu-del|qlen|qlen-del|offload|offload-del|coalesce|coalesce-del|speed|speed-del|apply|apply-all|show} ..." >&2; exit 2 ;;
esac
