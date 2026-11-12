#!/bin/sh
# TITIAN — operasi interface VXLAN (Linux + FreeBSD).
# Model: netstate <iface>.vxlan (baris "kunci nilai") = sumber kebenaran
# parameter; setiap perubahan parameter = recreate interface dari netstate.
# Alasan recreate seragam kedua OS (terbukti saat prototipe 1 Nov 2026):
#  - Linux: id VNI dan dstport TIDAK bisa diubah live
#    ("Error: Cannot change VNI." / "Cannot change port."); tidak ada
#    perintah noremote/nogroup; "local none" ditolak (harus alamat valid).
#  - FreeBSD: "-vxlanlocal" ditolak ("bad value"); vxlanport bukan
#    parameter settable (port tetap 4789).
# Jadi: vni/local/remote/group/dstport diubah lewat hapus + buat ulang
# dengan parameter baru. Alamat dipulihkan dari netstate <iface>.addr
# via titian-if.sh (state_add idempotent, tidak duplikat); MTU dari
# <iface>.tuning (set langsung, tanpa menyentuh bookkeeping
# .tuning.prev titian-tune.sh). Recreate = flap singkat. MAC interface
# TERNYATA STABIL untuk nama yang sama di lab ini (terbukti: hapus+buat
# ulang + reboot penuh tidak mengubah MAC di kedua OS; nama sama + VNI
# berbeda pun MAC-nya sama — jadi bukan turunan VNI; mekanisme pastinya
# tidak diidentifikasi, jangan jadikan jaminan umum).
# POSIX sh (jalan di dash Debian dan sh FreeBSD).
set -u
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
SBIN=$ROOT/sbin
STATE_DIR=${TITIAN_STATE_DIR:-/etc/titian/netstate}

err() { echo "Error: $*" >&2; exit 33; }
warn() {
    if [ -t 2 ]; then printf '\033[33mWarning(vxlan):\033[0m %s\n' "$*" >&2
    else echo "Warning(vxlan): $*" >&2; fi
}

valid_v4() {
    # $1 = dotted quad; return 0 bila valid (salinan titian-if.sh)
    local rest o i
    rest=$1
    for i in 1 2 3 4; do
        case "$rest" in
            *.*) o=${rest%%.*}; rest=${rest#*.} ;;
            *)   o=$rest; rest="" ;;
        esac
        case "$o" in
            ''|*[!0-9]*) return 1 ;;
        esac
        if [ "$o" -gt 255 ] 2>/dev/null; then return 1; fi
        if [ "$i" -eq 4 ] && [ -n "$rest" ]; then return 1; fi
    done
    case "$1" in
        *.*.*.*) return 0 ;;
        *) return 1 ;;
    esac
}

is_mcast() {
    # $1 dotted quad -> 0 bila 224.0.0.0-239.255.255.255
    local o
    o=${1%%.*}
    [ "$o" -ge 224 ] 2>/dev/null && [ "$o" -le 239 ] 2>/dev/null
}

vxfile() { printf '%s/%s.vxlan' "$STATE_DIR" "$1"; }

vx_get() {
    # $1=iface $2=key -> nilai (kosong bila tidak ada)
    grep "^$2 " "$(vxfile "$1")" 2>/dev/null | tail -1 | awk '{print $2}'
}

vx_set() {
    # $1=iface $2=key $3=value — ganti-atau-tambah
    local f tmp
    f=$(vxfile "$1")
    mkdir -p "$STATE_DIR" 2>/dev/null
    touch "$f" 2>/dev/null
    tmp="$f.tmp"
    grep -v "^$2 " "$f" 2>/dev/null > "$tmp" || true
    echo "$2 $3" >> "$tmp"
    mv "$tmp" "$f" 2>/dev/null || true
}

vx_unset() {
    # $1=iface $2=key — hapus baris kunci (no-op bila file tidak ada)
    local f
    f=$(vxfile "$1")
    [ -f "$f" ] || return 0
    grep -v "^$2 " "$f" 2>/dev/null > "$f.tmp" || true
    mv "$f.tmp" "$f" 2>/dev/null || true
}

iface_exists() {
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$1" >/dev/null 2>&1
    else
        [ -d "/sys/class/net/$1" ]
    fi
}

iface_up() {
    # return 0 bila interface UP (admin up, bukan LOWER_UP saja)
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$1" 2>/dev/null | head -1 | grep -q "UP,"
    else
        ip link show "$1" 2>/dev/null | head -1 | grep -qE "[<,]UP[,>]"
    fi
}

iface_up_set() {
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$1" up 2>/dev/null || true
    else
        ip link set "$1" up 2>/dev/null || true
    fi
}

do_create() {
    # $1=iface — buat bila belum ada (placeholder: Linux id 1 dstport
    # 4789; FreeBSD bare create), lalu tandai managed + sentuh .vxlan.
    # Bila interface sudah ada (mis. sisa prototipe mentah), adopsi:
    # tandai managed + sentuh .vxlan tanpa mengubah parameter live-nya.
    local iface=$1
    if [ "$OS" = "FreeBSD" ]; then
        kldload if_vxlan 2>/dev/null || true
        if ! grep -qx 'if_vxlan_load="YES"' /boot/loader.conf 2>/dev/null; then
            echo 'if_vxlan_load="YES"' >> /boot/loader.conf 2>/dev/null || \
                warn "gagal tulis /boot/loader.conf (modul tidak persisten reboot)"
        fi
        if ! iface_exists "$iface"; then
            ifconfig "$iface" create || err "gagal create $iface"
        fi
    else
        if ! iface_exists "$iface"; then
            ip link add "$iface" type vxlan id 1 dstport 4789 || err "gagal create $iface"
            ip link set "$iface" down 2>/dev/null || true
        fi
    fi
    "$SBIN/titian-persist.sh" mark-if "$iface" 2>/dev/null || true
    mkdir -p "$STATE_DIR" 2>/dev/null
    touch "$(vxfile "$iface")" 2>/dev/null
}

do_recreate() {
    # $1=iface — hapus + buat ulang dari netstate (.vxlan + .addr +
    # .tuning), pulihkan up-state live. Dipanggil setiap perubahan
    # parameter dan oleh apply-all bila interface hilang.
    local iface=$1 vni loc remote group dev dstport up f line rest a p mtu
    vni=$(vx_get "$iface" vni)
    loc=$(vx_get "$iface" local)
    remote=$(vx_get "$iface" remote)
    group=$(vx_get "$iface" group)
    dev=$(vx_get "$iface" dev)
    dstport=$(vx_get "$iface" dstport)
    [ -n "$dstport" ] || dstport=4789
    up=0
    if iface_exists "$iface"; then
        if iface_up "$iface"; then up=1; fi
    fi
    if [ "$OS" = "FreeBSD" ]; then
        kldload if_vxlan 2>/dev/null || true
        if iface_exists "$iface"; then
            ifconfig "$iface" destroy 2>/dev/null || true
        fi
        ifconfig "$iface" create || err "gagal recreate $iface"
        if [ -n "$vni" ]; then
            ifconfig "$iface" vxlanid "$vni" || err "gagal set vni $vni"
        fi
        if [ -n "$loc" ]; then
            ifconfig "$iface" vxlanlocal "$loc" || err "gagal set local $loc"
        fi
        if [ -n "$remote" ]; then
            ifconfig "$iface" vxlanremote "$remote" || err "gagal set remote $remote"
        elif [ -n "$group" ]; then
            if [ -z "$dev" ]; then err "group butuh dev (netstate rusak?)"; fi
            ifconfig "$iface" vxlangroup "$group" vxlandev "$dev" || err "gagal set group $group dev $dev"
        fi
        # dstport FreeBSD tetap 4789 (bukan parameter settable) — tidak ada aksi
    else
        if iface_exists "$iface"; then
            ip link del "$iface" 2>/dev/null || true
        fi
        # bangun perintah add tanpa eval (set -- bergeser)
        if [ -n "$vni" ]; then
            set -- ip link add "$iface" type vxlan id "$vni"
        else
            set -- ip link add "$iface" type vxlan id 1
        fi
        if [ -n "$remote" ]; then
            set -- "$@" remote "$remote"
        elif [ -n "$group" ]; then
            set -- "$@" group "$group"
            if [ -n "$dev" ]; then set -- "$@" dev "$dev"; fi
        fi
        if [ -n "$loc" ]; then set -- "$@" local "$loc"; fi
        set -- "$@" dstport "$dstport"
        "$@" || err "gagal recreate $iface"
    fi
    # MTU dari .tuning (set langsung; jangan panggil titian-tune.sh
    # agar bookkeeping .tuning.prev tidak berubah saat recreate)
    f="$STATE_DIR/$iface.tuning"
    if [ -f "$f" ]; then
        mtu=$(grep '^mtu ' "$f" 2>/dev/null | tail -1 | awk '{print $2}')
        if [ -n "$mtu" ]; then
            if [ "$OS" = "FreeBSD" ]; then
                ifconfig "$iface" mtu "$mtu" 2>/dev/null || true
            else
                ip link set dev "$iface" mtu "$mtu" 2>/dev/null || true
            fi
        fi
    fi
    # alamat dari .addr (titian-if.sh state_add idempotent)
    f="$STATE_DIR/$iface.addr"
    if [ -f "$f" ]; then
        while IFS= read -r line; do
            case "$line" in
                'inet '*)
                    rest=${line#inet }
                    case "$rest" in
                        *' peer '*)
                            a=${rest%% peer *}; p=${rest##* peer }
                            "$SBIN/titian-if.sh" addr-add "$iface" "$a" "$p" 2>/dev/null || warn "gagal pulihkan $line"
                            ;;
                        *) "$SBIN/titian-if.sh" addr-add "$iface" "$rest" "" 2>/dev/null || warn "gagal pulihkan $line" ;;
                    esac
                    ;;
                'inet6 '*)
                    rest=${line#inet6 }
                    case "$rest" in
                        *' peer '*)
                            a=${rest%% peer *}; p=${rest##* peer }
                            "$SBIN/titian-if.sh" addr6-add "$iface" "$a" "$p" 2>/dev/null || warn "gagal pulihkan $line"
                            ;;
                        *) "$SBIN/titian-if.sh" addr6-add "$iface" "$rest" "" 2>/dev/null || warn "gagal pulihkan $line" ;;
                    esac
                    ;;
            esac
        done < "$f"
    fi
    # segarkan cermin deklaratif sekali (bukan per alamat)
    "$SBIN/titian-persist.sh" sync-if "$iface" 2>/dev/null || true
    if [ "$up" -eq 1 ]; then iface_up_set "$iface"; fi
}

do_set() {
    # $1=iface $2=key $3=value [$4=value2 untuk group: dev]
    local iface=$1 key=$2 val=$3 val2=${4:-}
    case "$key" in
        vni)
            case "$val" in ''|*[!0-9]*) err "vni harus angka 1-16777215" ;; esac
            if ! [ "$val" -ge 1 ] 2>/dev/null || ! [ "$val" -le 16777215 ] 2>/dev/null; then
                err "vni di luar 1-16777215: $val"
            fi
            ;;
        local|remote)
            valid_v4 "$val" || err "$key bukan IPv4 valid: $val"
            if is_mcast "$val"; then err "$key tidak boleh multicast: $val"; fi
            ;;
        group)
            valid_v4 "$val" || err "group bukan IPv4 valid: $val"
            is_mcast "$val" || err "group harus multicast 224.0.0.0-239.255.255.255: $val"
            if [ -z "$val2" ]; then err "group butuh dev: group <mcast> dev <iface>"; fi
            if [ "$OS" = "FreeBSD" ]; then
                ifconfig "$val2" >/dev/null 2>&1 || err "dev tidak ada: $val2 (lihat 'show interfaces' untuk daftar)"
            else
                [ -d "/sys/class/net/$val2" ] || err "dev tidak ada: $val2 (lihat 'show interfaces' untuk daftar)"
            fi
            ;;
        dstport)
            case "$val" in ''|*[!0-9]*) err "dstport harus angka 1-65535" ;; esac
            if ! [ "$val" -ge 1 ] 2>/dev/null || ! [ "$val" -le 65535 ] 2>/dev/null; then
                err "dstport di luar 1-65535: $val"
            fi
            if [ "$OS" = "FreeBSD" ] && [ "$val" != "4789" ]; then
                err "FreeBSD: vxlan port tetap 4789 (tidak bisa diubah via ifconfig)"
            fi
            ;;
        *) err "kunci tidak dikenal: $key" ;;
    esac
    # remote <-> group saling eksklusif
    if [ "$key" = "remote" ]; then
        vx_unset "$iface" group; vx_unset "$iface" dev
    fi
    if [ "$key" = "group" ]; then
        vx_unset "$iface" remote
        vx_set "$iface" dev "$val2"
    fi
    vx_set "$iface" "$key" "$val"
    if ! iface_exists "$iface"; then do_create "$iface"; fi
    do_recreate "$iface"
}

do_unset() {
    # $1=iface $2=key — hapus kunci dari netstate lalu recreate tanpa kunci itu
    local iface=$1 key=$2
    case "$key" in
        vni|local|remote|dstport) vx_unset "$iface" "$key" ;;
        group) vx_unset "$iface" group; vx_unset "$iface" dev ;;
        *) err "kunci tidak dikenal: $key" ;;
    esac
    if iface_exists "$iface"; then do_recreate "$iface"; fi
}

do_delete() {
    # $1=iface — hapus device saja (drop-if dipegang ACTION tree)
    if [ "$OS" = "FreeBSD" ]; then
        if iface_exists "$1"; then ifconfig "$1" destroy 2>/dev/null || true; fi
    else
        if iface_exists "$1"; then ip link del "$1" 2>/dev/null || true; fi
    fi
}

apply_all() {
    # jaring pengaman boot: vxlan yang tercatat di netstate tapi
    # interfacenya hilang (replay gagal) dibangun ulang + di-up.
    # No-op bila interface sudah ada (replay berhasil).
    local m iface
    for m in "$STATE_DIR"/*.vxlan; do
        [ -e "$m" ] || continue
        iface=$(basename "$m" .vxlan)
        if ! iface_exists "$iface"; then
            do_recreate "$iface" 2>/dev/null || warn "apply-vxlan gagal untuk $iface"
            iface_up_set "$iface"
        fi
    done
}

show_one() {
    # $1=iface — satu blok seragam kedua OS
    local iface=$1 out state mtu vni loc remote group dev port addrs fdb unit vx
    if [ "$OS" = "FreeBSD" ]; then
        out=$(ifconfig "$iface" 2>/dev/null) || { echo "$iface: tidak ada"; return 0; }
        state=DOWN
        echo "$out" | head -1 | grep -q "UP," && state=UP
        mtu=$(echo "$out" | sed -n 's/.*mtu \([0-9][0-9]*\).*/\1/p' | head -1)
        vx=$(echo "$out" | grep -a "vxlan " | head -1)
        vni=$(echo "$vx" | sed -n 's/.*vni \([0-9][0-9]*\).*/\1/p')
        loc=$(echo "$vx" | sed -n 's/.*local \([0-9.]*\):.*/\1/p')
        port=$(echo "$vx" | sed -n 's/.*local [0-9.]*:\([0-9][0-9]*\).*/\1/p')
        remote=$(echo "$vx" | sed -n 's/.*remote \([0-9.]*\):.*/\1/p')
        group=$(echo "$vx" | sed -n 's/.*group \([0-9.]*\):.*/\1/p')
        addrs=$(echo "$out" | grep -a -E "^[[:space:]]*inet6? " | sed 's/^[[:space:]]*//')
        unit=${iface#vxlan}
        fdb=$(sysctl "net.link.vxlan.$unit.ftable.dump" 2>/dev/null | grep -a "0x" | sed 's/^ *//')
        printf '%s: %s, mtu %s\n' "$iface" "$state" "${mtu:-?}"
        if [ -n "$remote" ]; then
            printf '  VNI %s  local %s  remote %s  dstport %s\n' "${vni:-?}" "${loc:-?}" "$remote" "${port:-4789}"
        elif [ -n "$group" ]; then
            printf '  VNI %s  local %s  group %s  dstport %s\n' "${vni:-?}" "${loc:-?}" "$group" "${port:-4789}"
        else
            printf '  VNI %s  local %s  peer -  dstport %s\n' "${vni:-?}" "${loc:-?}" "${port:-4789}"
        fi
        [ -n "$addrs" ] && echo "$addrs" | sed 's/^/  /'
        if [ -n "$fdb" ]; then echo "$fdb" | sed 's/^/  FDB: /'; else echo "  FDB: (kosong)"; fi
    else
        if ! iface_exists "$iface"; then echo "$iface: tidak ada"; return 0; fi
        out=$(ip -d link show "$iface" 2>/dev/null)
        state=DOWN
        echo "$out" | head -1 | grep -qE "[<,]UP[,>]" && state=UP
        mtu=$(echo "$out" | sed -n 's/.*mtu \([0-9][0-9]*\).*/\1/p' | head -1)
        vx=$(echo "$out" | grep -a "vxlan " | head -1)
        vni=$(echo "$vx" | sed -n 's/.*id \([0-9][0-9]*\).*/\1/p')
        loc=$(echo "$vx" | sed -n 's/.*local \([0-9.]*\).*/\1/p')
        remote=$(echo "$vx" | sed -n 's/.*remote \([0-9.]*\).*/\1/p')
        group=$(echo "$vx" | sed -n 's/.*group \([0-9.]*\).*/\1/p')
        dev=$(echo "$vx" | sed -n 's/.*dev \([A-Za-z0-9_@.-]*\).*/\1/p')
        port=$(echo "$vx" | sed -n 's/.*dstport \([0-9][0-9]*\).*/\1/p')
        addrs=$(ip addr show "$iface" 2>/dev/null | grep -a -E "^[[:space:]]*inet6? " | sed 's/^[[:space:]]*//')
        printf '%s: %s, mtu %s\n' "$iface" "$state" "${mtu:-?}"
        if [ -n "$remote" ]; then
            printf '  VNI %s  local %s  remote %s  dstport %s\n' "${vni:-?}" "${loc:-?}" "$remote" "${port:-?}"
        elif [ -n "$group" ]; then
            printf '  VNI %s  local %s  group %s dev %s  dstport %s\n' "${vni:-?}" "${loc:-?}" "$group" "${dev:-?}" "${port:-?}"
        else
            printf '  VNI %s  local %s  peer -  dstport %s\n' "${vni:-?}" "${loc:-?}" "${port:-?}"
        fi
        [ -n "$addrs" ] && echo "$addrs" | sed 's/^/  /'
        fdb=$(bridge fdb show dev "$iface" 2>/dev/null)
        if [ -n "$fdb" ]; then echo "$fdb" | sed 's/^/  FDB: /'; else echo "  FDB: (kosong)"; fi
    fi
}

do_show() {
    # $1=iface opsional (kosong = semua interface vxlan)
    local list iface
    if [ -n "${1:-}" ]; then
        list="$1"
    else
        if [ "$OS" = "FreeBSD" ]; then
            list=$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^vxlan[0-9]+$' | sort)
        else
            list=$(ls /sys/class/net 2>/dev/null | grep -E '^vxlan[0-9]+$' | sort)
        fi
    fi
    if [ -z "$list" ]; then echo "tidak ada interface vxlan"; return 0; fi
    for iface in $list; do show_one "$iface"; done
}

case "${1:-}" in
    create) do_create "$2" ;;
    set) do_set "$2" "$3" "$4" "${5:-}" ;;
    unset) do_unset "$2" "$3" ;;
    delete) do_delete "$2" ;;
    exists) iface_exists "$2" ;;
    recreate) do_recreate "$2" ;;
    apply-all) apply_all ;;
    show) do_show "${2:-}" ;;
    *) echo "Usage: $0 {create|set|unset|delete|exists|recreate|apply-all|show} <iface> [key value...]" >&2; exit 2 ;;
esac
exit 0
