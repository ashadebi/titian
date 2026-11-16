#!/bin/sh
# TITIAN BSDRP — FRR (net/frr10) via klish.
# - Enable/disable TIDAK langsung start/stop service: hanya mencatat
#   niat di $STATE_ROOT/netstate/routing.intent (format sama dengan
#   titian-bird.sh) + menandai /var/run/routing.dirty; yang menaikkan
#   service adalah `commit` (titian-commit.sh -> frr-apply di sini).
#   Alasan: commit = tulis file + service langsung naik.
# - Config dasar (router-id, log syslog) berlaku LANGSUNG via vtysh
#   (running) + `write memory` agar persisten — model native FRR.
# - CLI FRR sendiri tetap `vtysh` via perintah `cli`; script ini
#   TIDAK mendefinisikan/menyentuh `cli`.
# - FRR LENGKAP (15 Nov 2026): BGP / OSPF / route-map / prefix-list /
#   community-list via klish — intent di /etc/titian/frr.conf,
#   diterapkan saat `commit` (frr-apply-config: rekonsiliasi intent
#   vs running-config via vtysh + write memory). Lihat blok besar
#   di bawah (sebelum `case`).
# - `bgp default local-preference` TIDAK dibuat (pakai route-map
#   `set local-preference` per neighbor — cara idiomatik FRR).
# POSIX sh.
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
SBIN_DIR=$(dirname "$0")
BIRD_SH="$SBIN_DIR/titian-bird.sh"
INTENT="$STATE_ROOT/netstate/routing.intent"
DIRTY=/var/run/routing.dirty
FRR_CONF=/usr/local/etc/frr/frr.conf
err() { echo "Error: $*" >&2; exit 33; }

have_vtysh() { command -v vtysh >/dev/null 2>&1; }

vtysh_cmd() {
    # $* = perintah vtysh (satu string -c). Gagal lantang bila vtysh tak ada.
    have_vtysh || err "vtysh tidak ditemukan (FRR tidak terpasang di image ini?)"
    vtysh -c "$*" || err "vtysh gagal: $*"
}

sysrc_val() {
    command -v sysrc >/dev/null 2>&1 || return 1
    sysrc -n "$1" 2>/dev/null
}

set_intent() {
    # $1 = yes|no (niat frr)
    mkdir -p "$(dirname "$INTENT")" 2>/dev/null
    touch "$INTENT" 2>/dev/null
    _tmp="$INTENT.tmp.$$"
    grep -v "^frr " "$INTENT" > "$_tmp" 2>/dev/null || true
    printf 'frr %s\n' "$1" >> "$_tmp"
    mv "$_tmp" "$INTENT" || err "gagal tulis $INTENT"
    touch "$DIRTY" 2>/dev/null || true
}

intent_val() {
    [ -f "$INTENT" ] || { echo "unset"; return 0; }
    _v=$(sed -n 's/^frr //p' "$INTENT" 2>/dev/null | head -1)
    printf '%s' "${_v:-unset}"
}

svc() {
    # svc <name> <action>: gagal-aman bila `service` tak ada (uji Linux).
    if command -v service >/dev/null 2>&1; then
        service "$1" "$2"
    else
        echo "(service no  at host ini — lewati: service $1 $2)"
    fi
}

stop_frr_daemons() {
    # Matikan SEMUA daemon FRR (watchfrr + zebra/bgpd/ospfd/ripd/
    # staticd/mgmtd). `service frr stop` hanya mematikan watchfrr;
    # keenam daemon lain tertinggal yatim (tes 14) dan zebra yatim
    # bisa berebut tabel route dengan BIRD. Beri waktu berhenti
    # bersih, paksa (-9) bila masih ada sesudah 5 detik.
    _daemons="watchfrr zebra bgpd ospfd ripd staticd mgmtd"
    _i=0
    while [ "$_i" -lt 10 ]; do
        _left=""
        for _d in $_daemons; do
            if command -v pgrep >/dev/null 2>&1; then
                pgrep -x "$_d" >/dev/null 2>&1 && _left="$_left $_d"
            fi
        done
        [ -z "$_left" ] && return 0
        if [ "$_i" = "0" ]; then
            for _d in $_daemons; do
                if command -v pkill >/dev/null 2>&1; then
                    pkill -x "$_d" 2>/dev/null || true
                fi
            done
        fi
        sleep 0.5 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    # Masih ada yang bandel — paksa.
    if command -v pkill >/dev/null 2>&1; then
        for _d in $_daemons; do pkill -9 -x "$_d" 2>/dev/null || true; done
        sleep 0.5 2>/dev/null || sleep 1
    fi
    return 0
}

do_check() {
    have_vtysh || err "FRR tidak terpasang (vtysh tidak ditemukan)"
    exit 0
}

do_enable() {
    have_vtysh || err "FRR tidak terpasang (vtysh tidak ditemukan)"
    # Mutual exclusion: tolak bila BIRD aktif (sysrc / service / proses / niat).
    sh "$BIRD_SH" check-exclusion frr || exit 33
    set_intent yes
    echo "router frr enable (pending commit — service frr naik saat commit)"
}

do_disable() {
    set_intent no
    echo "router frr disable (pending commit — service frr berhenti saat commit)"
}

do_apply() {
    # Dipanggil commit (dan boot). Terapkan niat: sysrc + service.
    local want
    want=$(intent_val)
    [ "$want" = "unset" ] && { echo "frr: tidak ada niat pending"; rm -f "$DIRTY"; return 0; }
    if [ "$want" = "yes" ]; then
        # Periksa ulang konflik SEBELUM menaikkan service.
        sh "$BIRD_SH" check-exclusion frr || exit 33
        if command -v sysrc >/dev/null 2>&1; then sysrc frr_enable="YES" >/dev/null || err "sysrc frr_enable gagal"; fi
        if [ -n "$(pgrep -x zebra 2>/dev/null | head -1)" ]; then
            echo "frr: zebra already jalan (not at-restart)"
        else
            svc frr start || err "service frr start gagal"
        fi
        echo "frr: enabled + running"
    else
        # Berhenti DULU — pakai `onestop` (FreeBSD) agar tetap berhenti
        # walau frr_enable sudah NO (dari commit sebelumnya yang gagal).
        # `onestop` gagal di Linux -> fallback ke `stop`. Lalu matikan
        # SEMUA daemon (stop_frr_daemons) — `service frr stop` hanya
        # mematikan watchfrr (tes 14: 6 daemon yatim tertinggal).
        svc frr onestop 2>/dev/null || svc frr stop 2>/dev/null || true
        stop_frr_daemons
        if command -v sysrc >/dev/null 2>&1; then sysrc frr_enable="NO" >/dev/null || err "sysrc frr_enable gagal"; fi
        echo "frr: disabled + stopped"
    fi
    rm -f "$DIRTY"
    return 0
}

do_set_router_id() {
    local id=$1
    case "$id" in
        *.*.*.*) ;;
        *) err "router-id harus IPv4: $id" ;;
    esac
    # vtysh menerima beberapa -c berurutan dalam satu sesi.
    have_vtysh || err "vtysh tidak ditemukan"
    vtysh -c "configure terminal" -c "router-id $id" -c "end" -c "write memory" \
        || err "gagal set router-id $id via vtysh"
    echo "frr: router-id $id (running + write memory)"
}

do_del_router_id() {
    have_vtysh || err "vtysh tidak ditemukan"
    vtysh -c "configure terminal" -c "no router-id" -c "end" -c "write memory" \
        || err "gagal hapus router-id via vtysh"
    echo "frr: router-id deleted (running + write memory)"
}

do_set_log() {
    # $1 = syslog|none
    have_vtysh || err "vtysh tidak ditemukan"
    if [ "$1" = "syslog" ]; then
        vtysh -c "configure terminal" -c "log syslog" -c "end" -c "write memory" \
            || err "gagal set log syslog via vtysh"
        echo "frr: log syslog (running + write memory)"
    else
        vtysh -c "configure terminal" -c "no log syslog" -c "end" -c "write memory" \
            || err "gagal matikan log syslog via vtysh"
        echo "frr: log syslog dimatikan (running + write memory)"
    fi
}

do_write_memory() {
    vtysh_cmd "write memory"
    echo "frr: running-config ditulis to $FRR_CONF"
}

frr_version() {
    local v=""
    if have_vtysh; then
        v=$(vtysh --version 2>/dev/null | head -1 | sed -n 's/.* \([0-9][0-9.]*\).*/\1/p')
    fi
    if [ -z "$v" ] && command -v pkg >/dev/null 2>&1; then
        v=$(pkg info -x '^frr[0-9]*$' 2>/dev/null | head -1 | sed -n 's/^frr[0-9]*-\([0-9][0-9.]*\).*/\1/p')
    fi
    printf '%s' "${v:-unknown}"
}

do_show() {
    local want fver fen frn zpid
    want=$(intent_val); fver=$(frr_version)
    fen=no; frn="not running"
    [ "$(sysrc_val frr_enable 2>/dev/null)" = "YES" ] && fen="enabled"
    zpid=$(pgrep -x zebra 2>/dev/null | head -1)
    [ -n "$zpid" ] && frn="running, pid $zpid"
    echo "FRR: $fver (intent: $want, rc: $fen, $frn)"
    if command -v service >/dev/null 2>&1; then
        service frr status 2>&1 | sed 's/^/  /'
    fi
    if have_vtysh && [ -n "$zpid" ]; then
        echo "-- daemons (vtysh show version):"
        vtysh -c "show version" 2>/dev/null | head -5 | sed 's/^/  /'
    fi
}

do_show_version() {
    local fver zpid
    fver=$(frr_version)
    zpid=$(pgrep -x zebra 2>/dev/null | head -1)
    if [ -n "$zpid" ]; then
        echo "FRR $fver (running, pid $zpid)"
    else
        echo "FRR $fver (not running)"
    fi
    if have_vtysh; then
        vtysh -c "show version" 2>/dev/null | sed -n '1,8p'
    fi
}

# ============================================================
# FRR LENGKAP — BGP / OSPF / route-map / prefix-list /
# community-list via klish (15 Nov 2026).
#
# Model: intent di $FRR_INTENT (/etc/titian/frr.conf, satu baris
# per fakta — pola sama seperti titian-bgp.sh). Perintah klish
# HANYA menulis intent (tidak langsung vtysh — beda dengan
# router-id/log di atas yang langsung, itu model native FRR
# untuk config dasar). `commit` memanggil frr-apply-config
# (titian-commit.sh, sesudah apply_routing menaikkan FRR):
# rekonsiliasi intent vs running-config FRR via vtysh, lalu
# `write memory`.
#
# Alasan intent + commit (bukan langsung vtysh): config bisa
# dimasukkan sebelum FRR jalan; commit = satu titik apply yang
# konsisten dengan BIRD; hapus (`no ...`) ikut terhapus dari
# running-config lewat rekonsiliasi — tanpa ini, config yang
# dihapus dari intent akan tertinggal di frr.conf (daemon
# tidak pernah tahu config itu dihapus).
#
# Rekonsiliasi: bandingkan intent dengan `vtysh show
# running-config`. Entri yang ada di running tapi tidak di
# intent dihapus (`no ...`). Entri yang ada di intent
# diterapkan (idempotent — set ulang tidak masalah).
# Route-map dan prefix-list/community-list dihapus + dibuat
# ulang utuh tiap apply (policy object: murah, tidak memutus
# sesi BGP; cara ini memastikan match/set yang dihapus dari
# intent ikut hilang dari running). Neighbor/network/OSPF
# diterapkan inkremental (hapus yang basi, tambah yang baru)
# agar sesi BGP tidak flap tiap commit.
#
# CATATAN — config yang dikelola klish vs manual vtysh:
# frr-apply-config menganggap intent klish sebagai sumber
# kebenaran untuk kategori yang dikelolanya (router bgp,
# router ospf, route-map, ip prefix-list, ip community-list).
# Config manual di vtysh dalam kategori itu akan DIHAPUS saat
# commit bila tidak ada di intent. Config di luar kategori
# itu (mis. router-id global, log syslog) tidak disentuh.
#
# Format $FRR_INTENT (satu baris per fakta):
#   bgp local-as <AS>
#   bgp router-id <IP>
#   bgp neighbor <IP> remote-as <AS>
#   bgp neighbor <IP> description <teks>
#   bgp neighbor <IP> route-map <NAME> in|out
#   bgp neighbor <IP> prefix-list <NAME> in|out
#   bgp neighbor <IP> send-community
#   bgp neighbor <IP> timers <keepalive> <hold>
#   bgp network <prefix>
#   ospf router-id <IP>
#   ospf network <prefix> area <ID>
#   ospf redistribute connected|static
#   prefix-list <NAME> seq <N> permit|deny <prefix|any> [ge <N>] [le <N>]
#   route-map <NAME> <SEQ> permit|deny
#   route-map <NAME> <SEQ> match ip address prefix-list <PL>
#   route-map <NAME> <SEQ> match community <CL>
#   route-map <NAME> <SEQ> set local-preference <N>
#   route-map <NAME> <SEQ> set metric <N>
#   route-map <NAME> <SEQ> set community <VAL> [additive]
#   route-map <NAME> <SEQ> set as-path prepend <AS> [AS...]
#   community-list <NAME> permit <VAL>
# ============================================================

FRR_INTENT="$STATE_ROOT/frr.conf"

# --- validasi ringan (klish PTYPE sudah validasi di depan; ini lapis kedua) ---
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

is_ipv4() {
    # IPv4 dotted-quad (tepat 4 oktet, tiap 0-255).
    _ip="$1"
    case "$_ip" in *.*.*.*) ;; *) return 1 ;; esac
    case "$_ip" in *.*.*.*.*) return 1 ;; esac
    _o1=$(echo "$_ip" | cut -d. -f1)
    _o2=$(echo "$_ip" | cut -d. -f2)
    _o3=$(echo "$_ip" | cut -d. -f3)
    _o4=$(echo "$_ip" | cut -d. -f4)
    for _o in "$_o1" "$_o2" "$_o3" "$_o4"; do
        is_uint "$_o" || return 1
        [ "$_o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

is_prefix() {
    # Prefix CIDR atau "any" (prefix-list FRR menerima `deny any`).
    [ "$1" = "any" ] && return 0
    case "$1" in */*) ;;
        *) return 1 ;;
    esac
    is_ipv4 "${1%/*}" || return 1
    _m="${1#*/}"
    is_uint "$_m" || return 1
    [ "$_m" -ge 0 ] 2>/dev/null && [ "$_m" -le 32 ] 2>/dev/null || return 1
    return 0
}

is_community() {
    # Community standard AS:NN atau well-known FRR (lihat panduan §9c.4).
    case "$1" in
        no-export|no-advertise|local-AS|no-peer|blackhole) return 0 ;;
        *:*)
            _ca="${1%%:*}"; _cb="${1##*:}"
            is_uint "$_ca" && is_uint "$_cb" && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

is_area() {
    # Area OSPF: angka atau IPv4 (0 / 0.0.0.0).
    is_uint "$1" && return 0
    is_ipv4 "$1" && return 0
    return 1
}

# --- intent helpers (pola sama seperti titian-bgp.sh) ---
touch_frr_conf() {
    if [ ! -f "$FRR_INTENT" ]; then
        mkdir -p "$(dirname "$FRR_INTENT")" 2>/dev/null
        printf '# frr.conf - intent klish FRR, do not edit by hand\n' > "$FRR_INTENT" \
            || { echo "titian-frr: cannot create $FRR_INTENT" >&2; exit 1; }
        chmod 600 "$FRR_INTENT" 2>/dev/null || true
    fi
}

# frr_upsert <regex-untuk-hapus> <baris-baru>
frr_upsert() {
    _re="$1"; _line="$2"
    touch_frr_conf
    _tmp="$FRR_INTENT.tmp.$$"
    grep -v "$_re" "$FRR_INTENT" > "$_tmp" 2>/dev/null || true
    printf '%s\n' "$_line" >> "$_tmp"
    mv "$_tmp" "$FRR_INTENT" || { echo "titian-frr: cannot write $FRR_INTENT" >&2; exit 1; }
    chmod 600 "$FRR_INTENT" 2>/dev/null || true
}

frr_dellines() {
    _re="$1"
    touch_frr_conf
    _tmp="$FRR_INTENT.tmp.$$"
    grep -v "$_re" "$FRR_INTENT" > "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$FRR_INTENT" || { echo "titian-frr: cannot write $FRR_INTENT" >&2; exit 1; }
}

# _in_facts <file> <baris> -> 0 bila baris persis (fixed string) ada di file
_in_facts() {
    grep -Fxq -- "$2" "$1" 2>/dev/null
}

# --- BGP ---
cmd_bgp_set_local_as() {
    [ -n "$1" ] || err "local-as butuh nomor AS"
    is_uint "$1" || err "local-as harus angka: $1"
    frr_upsert '^bgp local-as ' "bgp local-as $1"
    echo "FRR local-as set to $1 (pending commit)"
}

cmd_bgp_del() {
    # no router bgp — hapus SEMUA intent BGP (neighbor/network/
    # router-id BGP). Route-map/prefix-list/community-list TIDAK
    # ikut dihapus (policy object, bisa dipakai lagi — sama
    # seperti FRR: `no router bgp` tidak menghapus policy).
    frr_dellines '^bgp '
    echo "FRR BGP dihapus dari intent (pending commit — neighbor/network BGP ikut terhapus dari running-config saat commit)"
}

cmd_bgp_set_router_id() {
    [ -n "$1" ] || err "bgp router-id butuh alamat IP"
    is_ipv4 "$1" || err "bgp router-id harus IPv4: $1"
    frr_upsert '^bgp router-id ' "bgp router-id $1"
    echo "FRR bgp router-id set to $1 (pending commit)"
}

cmd_bgp_del_router_id() {
    frr_dellines '^bgp router-id '
    echo "FRR bgp router-id dihapus (pending commit)"
}

cmd_bgp_neighbor_touch() {
    _ip="$1"
    [ -n "$_ip" ] || err "neighbor-touch butuh IP"
    touch_frr_conf
    echo "FRR BGP neighbor $_ip"
}

cmd_bgp_neighbor_add() {
    _ip="$1"; _as="$2"
    [ -n "$_ip" ] && [ -n "$_as" ] || err "neighbor butuh IP + remote-as"
    is_ipv4 "$_ip" || err "neighbor harus IPv4: $_ip"
    is_uint "$_as" || err "remote-as harus angka: $_as"
    frr_upsert "^bgp neighbor $_ip remote-as " "bgp neighbor $_ip remote-as $_as"
    echo "FRR BGP neighbor $_ip remote-as $_as (pending commit)"
    echo "CATATAN: FRR 10.x WAJIB route-map in DAN out per neighbor eBGP — tanpa itu 0 prefix tukar (tes 14)."
}

cmd_bgp_neighbor_del() {
    _ip="$1"
    [ -n "$_ip" ] || err "neighbor-del butuh IP"
    frr_dellines "^bgp neighbor $_ip "
    echo "FRR BGP neighbor $_ip dihapus (pending commit)"
}

cmd_bgp_neighbor_set() {
    # neighbor-set <IP> <field> <value...>
    # field: description|route-map|prefix-list|send-community|timers
    _ip="$1"; _f="$2"; shift 2
    [ -n "$_ip" ] && [ -n "$_f" ] || err "neighbor-set butuh IP field value"
    case "$_f" in
        description)
            [ -n "$1" ] || err "description butuh teks"
            frr_upsert "^bgp neighbor $_ip description " "bgp neighbor $_ip description $*"
            echo "FRR BGP neighbor $_ip description = $* (pending commit)" ;;
        route-map)
            _nm="$1"; _dir="$2"
            [ -n "$_nm" ] && [ -n "$_dir" ] || err "route-map butuh NAMA in|out"
            case "$_dir" in in|out) ;; *) err "route-map arah harus in|out: $_dir" ;; esac
            frr_upsert "^bgp neighbor $_ip route-map [^ ]* $_dir\$" "bgp neighbor $_ip route-map $_nm $_dir"
            echo "FRR BGP neighbor $_ip route-map $_nm $_dir (pending commit)" ;;
        prefix-list)
            _nm="$1"; _dir="$2"
            [ -n "$_nm" ] && [ -n "$_dir" ] || err "prefix-list butuh NAMA in|out"
            case "$_dir" in in|out) ;; *) err "prefix-list arah harus in|out: $_dir" ;; esac
            frr_upsert "^bgp neighbor $_ip prefix-list [^ ]* $_dir\$" "bgp neighbor $_ip prefix-list $_nm $_dir"
            echo "FRR BGP neighbor $_ip prefix-list $_nm $_dir (pending commit)" ;;
        send-community)
            frr_upsert "^bgp neighbor $_ip send-community" "bgp neighbor $_ip send-community"
            echo "FRR BGP neighbor $_ip send-community (pending commit)" ;;
        timers)
            _k="$1"; _h="$2"
            [ -n "$_k" ] && [ -n "$_h" ] || err "timers butuh keepalive + holdtime"
            is_uint "$_k" || err "timers keepalive harus angka: $_k"
            is_uint "$_h" || err "timers holdtime harus angka: $_h"
            frr_upsert "^bgp neighbor $_ip timers " "bgp neighbor $_ip timers $_k $_h"
            echo "FRR BGP neighbor $_ip timers $_k $_h (pending commit)" ;;
        *) err "field neighbor FRR tidak dikenal: $_f" ;;
    esac
}

cmd_bgp_neighbor_unset() {
    # neighbor-unset <IP> <field> [direction]
    # field: description|route-map|prefix-list|send-community|timers
    _ip="$1"; _f="$2"; _dir="$3"
    [ -n "$_ip" ] && [ -n "$_f" ] || err "neighbor-unset butuh IP field"
    case "$_f" in
        description) frr_dellines "^bgp neighbor $_ip description " ;;
        route-map)
            case "$_dir" in in|out) ;; *) err "route-map unset butuh arah in|out" ;; esac
            frr_dellines "^bgp neighbor $_ip route-map [^ ]* $_dir\$" ;;
        prefix-list)
            case "$_dir" in in|out) ;; *) err "prefix-list unset butuh arah in|out" ;; esac
            frr_dellines "^bgp neighbor $_ip prefix-list [^ ]* $_dir\$" ;;
        send-community) frr_dellines "^bgp neighbor $_ip send-community" ;;
        timers) frr_dellines "^bgp neighbor $_ip timers " ;;
        *) err "field neighbor FRR tidak dikenal: $_f" ;;
    esac
    echo "FRR BGP neighbor $_ip $_f${_dir:+ $_dir} dihapus (pending commit)"
}

cmd_bgp_network_add() {
    _p="$1"
    [ -n "$_p" ] || err "network butuh prefix (mis. 10.99.40.0/24)"
    is_prefix "$_p" || err "network harus prefix CIDR: $_p"
    frr_upsert "^bgp network $_p\$" "bgp network $_p"
    echo "FRR BGP network $_p ditambahkan (pending commit)"
}

cmd_bgp_network_del() {
    _p="$1"
    [ -n "$_p" ] || err "network-del butuh prefix"
    frr_dellines "^bgp network $_p\$"
    echo "FRR BGP network $_p dihapus (pending commit)"
}

# --- OSPF ---
cmd_ospf_touch() {
    touch_frr_conf
    echo "FRR OSPF"
}

cmd_ospf_del() {
    # no router ospf — hapus SEMUA intent OSPF.
    frr_dellines '^ospf '
    echo "FRR OSPF dihapus dari intent (pending commit)"
}

cmd_ospf_set_router_id() {
    [ -n "$1" ] || err "ospf router-id butuh alamat IP"
    is_ipv4 "$1" || err "ospf router-id harus IPv4: $1"
    frr_upsert '^ospf router-id ' "ospf router-id $1"
    echo "FRR ospf router-id set to $1 (pending commit)"
}

cmd_ospf_del_router_id() {
    frr_dellines '^ospf router-id '
    echo "FRR ospf router-id dihapus (pending commit)"
}

cmd_ospf_network_add() {
    _p="$1"; _a="$2"
    [ -n "$_p" ] && [ -n "$_a" ] || err "ospf network butuh prefix + area"
    is_prefix "$_p" || err "ospf network harus prefix CIDR: $_p"
    is_area "$_a" || err "ospf area harus angka atau IPv4: $_a"
    frr_upsert "^ospf network $_p area " "ospf network $_p area $_a"
    echo "FRR OSPF network $_p area $_a (pending commit)"
}

cmd_ospf_network_del() {
    _p="$1"; _a="$2"
    [ -n "$_p" ] && [ -n "$_a" ] || err "ospf network-del butuh prefix + area"
    frr_dellines "^ospf network $_p area $_a\$"
    echo "FRR OSPF network $_p area $_a dihapus (pending commit)"
}

cmd_ospf_redist_add() {
    _s="$1"
    case "$_s" in connected|static) ;; *) err "redistribute harus connected|static: $_s" ;; esac
    frr_upsert "^ospf redistribute $_s\$" "ospf redistribute $_s"
    echo "FRR OSPF redistribute $_s (pending commit)"
}

cmd_ospf_redist_del() {
    _s="$1"
    case "$_s" in connected|static) ;; *) err "redistribute harus connected|static: $_s" ;; esac
    frr_dellines "^ospf redistribute $_s\$"
    echo "FRR OSPF redistribute $_s dihapus (pending commit)"
}

# --- prefix-list ---
cmd_prefix_list_add() {
    # prefix-list-add <NAME> <SEQ> <permit|deny> <PREFIX> [LE] [GE]
    # LE/GE kosong = tidak dipakai. Di intent ditulis `ge N` dulu
    # bila ada (FRR menulis `ge X le Y`).
    _n="$1"; _s="$2"; _a="$3"; _p="$4"; _le="$5"; _ge="$6"
    [ -n "$_n" ] && [ -n "$_s" ] && [ -n "$_a" ] && [ -n "$_p" ] || err "prefix-list butuh NAMA SEQ permit|deny PREFIX"
    is_uint "$_s" || err "prefix-list seq harus angka: $_s"
    case "$_a" in permit|deny) ;; *) err "prefix-list aksi harus permit|deny: $_a" ;; esac
    is_prefix "$_p" || err "prefix-list prefix harus CIDR atau any: $_p"
    [ -z "$_le" ] || { is_uint "$_le" || err "prefix-list le harus angka: $_le"; }
    [ -z "$_ge" ] || { is_uint "$_ge" || err "prefix-list ge harus angka: $_ge"; }
    _line="prefix-list $_n seq $_s $_a $_p"
    [ -n "$_ge" ] && _line="$_line ge $_ge"
    [ -n "$_le" ] && _line="$_line le $_le"
    frr_upsert "^prefix-list $_n seq $_s " "$_line"
    echo "FRR prefix-list $_n seq $_s $_a $_p${_ge:+ ge $_ge}${_le:+ le $_le} (pending commit)"
}

cmd_prefix_list_del() {
    _n="$1"
    [ -n "$_n" ] || err "prefix-list-del butuh NAMA"
    frr_dellines "^prefix-list $_n "
    echo "FRR prefix-list $_n dihapus (pending commit)"
}

# --- route-map ---
cmd_route_map_add() {
    # route-map-add <NAME> <permit|deny> <SEQ>
    _n="$1"; _a="$2"; _s="$3"
    [ -n "$_n" ] && [ -n "$_a" ] && [ -n "$_s" ] || err "route-map butuh NAMA permit|deny SEQ"
    case "$_a" in permit|deny) ;; *) err "route-map aksi harus permit|deny: $_a" ;; esac
    is_uint "$_s" || err "route-map seq harus angka: $_s"
    frr_upsert "^route-map $_n $_s " "route-map $_n $_s $_a"
    echo "FRR route-map $_n $_a $_s (pending commit)"
}

cmd_route_map_del() {
    _n="$1"
    [ -n "$_n" ] || err "route-map-del butuh NAMA"
    frr_dellines "^route-map $_n "
    echo "FRR route-map $_n dihapus (pending commit)"
}

cmd_route_map_set() {
    # route-map-set <NAME:ACTION:SEQ> <match|set> <args...>
    # (ID digabung satu var ber-delimiter ':' — klish 2.2.5 tidak
    # memecah viewid multi-var dengan benar: ${frr_rm} menelan
    # sisa string, ${frr_rm_seq} kosong. Dipisah di sini.)
    _id="$1"; _k="$2"; shift 2
    _n="${_id%%:*}"; _s="${_id##*:}"
    [ -n "$_n" ] && [ -n "$_s" ] && [ -n "$_k" ] || err "route-map-set butuh NAMA SEQ match|set ..."
    is_uint "$_s" || err "route-map seq harus angka: $_s"
    case "$_k" in
        match)
            case "$1" in
                prefix-list)
                    [ -n "$2" ] || err "match prefix-list butuh NAMA"
                    frr_upsert "^route-map $_n $_s match ip address prefix-list " "route-map $_n $_s match ip address prefix-list $2"
                    echo "FRR route-map $_n $_s match ip address prefix-list $2 (pending commit)" ;;
                community)
                    [ -n "$2" ] || err "match community butuh NAMA"
                    frr_upsert "^route-map $_n $_s match community " "route-map $_n $_s match community $2"
                    echo "FRR route-map $_n $_s match community $2 (pending commit)" ;;
                *) err "match FRR tidak dikenal: $1 (pakai: prefix-list|community)" ;;
            esac
            ;;
        set)
            case "$1" in
                local-preference)
                    [ -n "$2" ] || err "set local-preference butuh angka"
                    is_uint "$2" || err "set local-preference harus angka: $2"
                    frr_upsert "^route-map $_n $_s set local-preference " "route-map $_n $_s set local-preference $2"
                    echo "FRR route-map $_n $_s set local-preference $2 (pending commit)" ;;
                metric)
                    [ -n "$2" ] || err "set metric butuh angka"
                    is_uint "$2" || err "set metric harus angka: $2"
                    frr_upsert "^route-map $_n $_s set metric " "route-map $_n $_s set metric $2"
                    echo "FRR route-map $_n $_s set metric $2 (pending commit)" ;;
                community)
                    [ -n "$2" ] || err "set community butuh nilai (AS:NN atau no-export/no-advertise/local-AS/no-peer/blackhole)"
                    is_community "$2" || err "set community harus AS:NN atau well-known: $2"
                    if [ "$3" = "additive" ]; then
                        frr_upsert "^route-map $_n $_s set community " "route-map $_n $_s set community $2 additive"
                        echo "FRR route-map $_n $_s set community $2 additive (pending commit)"
                    else
                        frr_upsert "^route-map $_n $_s set community " "route-map $_n $_s set community $2"
                        echo "FRR route-map $_n $_s set community $2 (pending commit)"
                    fi ;;
                as-path)
                    # as-path prepend <AS> [AS...] — $2 harus "prepend".
                    # Daftar AS tiba sebagai SATU argumen string
                    # ("65000 65000" dari param STRING klish) — pecah
                    # dulu ke kata-kata sebelum validasi per AS.
                    [ "$2" = "prepend" ] || err "set as-path hanya mendukung prepend: set as-path prepend <AS...>"
                    shift 2
                    [ -n "$1" ] || err "set as-path prepend butuh minimal 1 AS"
                    _aslist="$*"
                    for _as in $_aslist; do is_uint "$_as" || err "set as-path prepend AS harus angka: $_as"; done
                    frr_upsert "^route-map $_n $_s set as-path prepend " "route-map $_n $_s set as-path prepend $_aslist"
                    echo "FRR route-map $_n $_s set as-path prepend $_aslist (pending commit)" ;;
                *) err "set FRR tidak dikenal: $1 (pakai: local-preference|metric|community|as-path)" ;;
            esac
            ;;
        *) err "route-map-set butuh match|set: $_k" ;;
    esac
}

cmd_route_map_unset() {
    # route-map-unset <NAME:ACTION:SEQ> <match|set> — hapus SEMUA baris
    # match (atau set) entry itu.
    _id="$1"; _k="$2"
    _n="${_id%%:*}"; _s="${_id##*:}"
    [ -n "$_n" ] && [ -n "$_s" ] && [ -n "$_k" ] || err "route-map-unset butuh NAMA SEQ match|set"
    case "$_k" in
        match) frr_dellines "^route-map $_n $_s match " ;;
        set) frr_dellines "^route-map $_n $_s set " ;;
        *) err "route-map-unset butuh match|set: $_k" ;;
    esac
    echo "FRR route-map $_n $_s $_k dihapus (pending commit)"
}

# --- community-list ---
cmd_community_list_add() {
    _n="$1"; _v="$2"
    [ -n "$_n" ] && [ -n "$_v" ] || err "community-list butuh NAMA NILAI"
    is_community "$_v" || err "community-list nilai harus AS:NN atau well-known: $_v"
    frr_upsert "^community-list $_n " "community-list $_n permit $_v"
    echo "FRR community-list $_n permit $_v (pending commit)"
}

cmd_community_list_del() {
    _n="$1"
    [ -n "$_n" ] || err "community-list-del butuh NAMA"
    frr_dellines "^community-list $_n "
    echo "FRR community-list $_n dihapus (pending commit)"
}

# --- apply: rekonsiliasi intent -> running-config FRR ---
do_apply_config() {
    # Rekonsiliasi intent FRR ($FRR_INTENT) dengan running-config
    # FRR via vtysh + write memory. Dipanggil commit
    # (titian-commit.sh, sesudah apply_routing menaikkan FRR) dan
    # apply-all (boot). Bila FRR belum jalan -> lewati (config
    # diterapkan di commit berikutnya sesudah FRR jalan).
    [ -f "$FRR_INTENT" ] || return 0
    _zpid=$(pgrep -x zebra 2>/dev/null | head -1)
    [ -n "$_zpid" ] || { echo "frr: zebra belum jalan — intent FRR (BGP/OSPF/policy) diterapkan saat FRR jalan + commit"; return 0; }
    have_vtysh || err "vtysh tidak ditemukan"
    # Tunggu vtysh responsif (daemon baru naik sesudah commit enable).
    _i=0
    while [ "$_i" -lt 20 ]; do
        vtysh -c "show version" >/dev/null 2>&1 && break
        sleep 0.5 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    vtysh -c "show version" >/dev/null 2>&1 || err "vtysh tidak responsif sesudah 10 detik (FRR belum siap?)"
    _tmpd=$(mktemp -d /tmp/titian-frr-apply.XXXXXX) || err "gagal mktemp"
    _run="$_tmpd/running.conf"
    _runfacts="$_tmpd/run.facts"
    _wantfacts="$_tmpd/want.facts"
    _batch="$_tmpd/batch.txt"
    _out="$_tmpd/vtysh.out"
    vtysh -c "show running-config" > "$_run" 2>/dev/null || { rm -rf "$_tmpd"; err "gagal baca running-config FRR via vtysh"; }
    # Parse running-config -> fakta ternormalisasi. FRR mengindentasi
    # isi section dengan SATU spasi (dibuang dulu agar pola seragam).
    awk '
    {
        sub(/^ /, "")
    }
    /^router bgp / { sec="bgp"; print "bgp_as " $3; next }
    /^router ospf/ { sec="ospf"; next }
    /^route-map / { sec="rm"; print "route_map " $2 " " $4 " " $3; next }
    /^ip prefix-list / { sec=""; print "prefix_list " $3; next }
    /^bgp community-list / { sec=""; print "community_list " $4; next }
    /^!/ { sec=""; next }
    /^exit$/ { sec=""; next }
    /^end$/ { sec=""; next }
    sec=="bgp" && /^neighbor / {
        ip=$2
        if ($3 == "remote-as") print "bgp_neighbor " ip " remote-as " $4
        else if ($3 == "description") { rest=""; for (i=4;i<=NF;i++) rest=rest (i>4?" ":"") $i; print "bgp_neighbor " ip " description " rest }
        else if ($3 == "route-map") print "bgp_neighbor " ip " route-map " $4 " " $5
        else if ($3 == "prefix-list") print "bgp_neighbor " ip " prefix-list " $4 " " $5
        else if ($3 == "send-community") print "bgp_neighbor " ip " send-community"
        else if ($3 == "timers") print "bgp_neighbor " ip " timers " $4 " " $5
        next
    }
    sec=="bgp" && /^bgp router-id / { print "bgp_router_id " $3; next }
    sec=="bgp" && /^bgp default local-preference / { print "bgp_default_local_pref " $4; next }
    sec=="bgp" && /^network / { print "bgp_network " $2; next }
    sec=="ospf" && /^ospf router-id / { print "ospf_router_id " $3; next }
    sec=="ospf" && /^network / { print "ospf_network " $2 " area " $4; next }
    sec=="ospf" && /^redistribute / { print "ospf_redist " $2; next }
    ' "$_run" > "$_runfacts" || { rm -rf "$_tmpd"; err "gagal parse running-config FRR"; }
    # Intent -> fakta (format sama). Baris match/set route-map
    # TIDAK ikut — route-map dihapus + dibuat ulang utuh, bukan
    # di-diff per baris.
    grep -v '^#' "$FRR_INTENT" 2>/dev/null | grep -v '^$' | grep -v '^route-map [^ ]* [^ ]* match ' | grep -v '^route-map [^ ]* [^ ]* set ' | sed \
        -e 's/^bgp local-as /bgp_as /' \
        -e 's/^bgp router-id /bgp_router_id /' \
        -e 's/^bgp neighbor /bgp_neighbor /' \
        -e 's/^bgp network /bgp_network /' \
        -e 's/^ospf router-id /ospf_router_id /' \
        -e 's/^ospf network /ospf_network /' \
        -e 's/^ospf redistribute /ospf_redist /' \
        -e 's/^prefix-list \([^ ]*\) .*/prefix_list \1/' \
        -e 's/^route-map \([^ ]*\) \([^ ]*\) \([^ ]*\)$/route_map \1 \2 \3/' \
        -e 's/^community-list \([^ ]*\) .*/community_list \1/' > "$_wantfacts"
    # Normalisasi area OSPF di KEDUA sisi fakta: FRR menampilkan
    # area sebagai dotted-quad (`area 0` -> `area 0.0.0.0` di
    # running-config), sementara intent menyimpan apa yang user
    # ketik (`0` atau `0.0.0.0`). Tanpa normalisasi, tiap commit
    # akan menghapus + menambah ulang network OSPF yang sama
    # (churn OSPF yang tidak perlu).
    _norm_area() {
        awk '{
            if ($1 == "ospf_network" && $4 ~ /^[0-9]+$/) {
                a=$4
                $4 = int(a/16777216) "." int(a/65536)%256 "." int(a/256)%256 "." a%256
            }
            print
        }' "$1" > "$1.norm" && mv "$1.norm" "$1"
    }
    _norm_area "$_runfacts"
    _norm_area "$_wantfacts"
    # --- bangun batch vtysh ---
    # Catatan (uji live 16 Nov 2026, bug 4): batch ini diumpan ke
    # `vtysh -f` (mode config-file via mgmtd), BUKAN ke sesi CLI
    # interaktif. Karena itu JANGAN ada baris `configure terminal`
    # (ditolak semua daemon: `% Unknown command`) dan perintah
    # community-list WAJIB `bgp community-list standard ...`
    # (`ip community-list ...` bukan sintaks FRR 10.7.1 — ditolak
    # semua daemon). `end` di akhir TETAP valid di mode ini.
    # Urutan: hapus instance (AS berubah / BGP-OSPF dihapus) ->
    # policy object (prefix-list, community-list, route-map:
    # hapus + buat ulang) -> BGP -> OSPF. Policy dulu agar saat
    # neighbor di-attach ke route-map, route-map-nya sudah ada.
    {
        _want_as=$(sed -n 's/^bgp_as //p' "$_wantfacts" | head -1)
        _run_as=$(sed -n 's/^bgp_as //p' "$_runfacts" | head -1)
        if [ -n "$_run_as" ] && [ "$_run_as" != "$_want_as" ]; then
            echo "no router bgp"
        fi
        if ! grep -q '^ospf_' "$_wantfacts" 2>/dev/null && grep -q '^ospf_' "$_runfacts" 2>/dev/null; then
            echo "no router ospf"
        fi
        # prefix-list: hapus semua di running, buat ulang dari intent
        grep '^prefix_list ' "$_runfacts" 2>/dev/null | awk '{print $2}' | sort -u | while IFS= read -r _n; do
            echo "no ip prefix-list $_n"
        done
        grep '^prefix-list ' "$FRR_INTENT" 2>/dev/null | while IFS= read -r _line; do
            echo "ip $_line"
        done
        # community-list: hapus semua di running, buat ulang dari intent
        grep '^community_list ' "$_runfacts" 2>/dev/null | awk '{print $2}' | sort -u | while IFS= read -r _n; do
            echo "no bgp community-list standard $_n"
        done
        grep '^community-list ' "$FRR_INTENT" 2>/dev/null | while IFS= read -r _line; do
            _n=$(echo "$_line" | awk '{print $2}'); _v=$(echo "$_line" | awk '{print $4}')
            echo "bgp community-list standard $_n permit $_v"
        done
        # route-map: hapus semua entry di running, buat ulang dari intent
        grep '^route_map ' "$_runfacts" 2>/dev/null | while IFS= read -r _line; do
            _n=$(echo "$_line" | awk '{print $2}'); _s=$(echo "$_line" | awk '{print $3}'); _a=$(echo "$_line" | awk '{print $4}')
            echo "no route-map $_n $_a $_s"
        done
        awk '$1=="route-map" && NF==4' "$FRR_INTENT" 2>/dev/null | while IFS= read -r _line; do
            _n=$(echo "$_line" | awk '{print $2}'); _s=$(echo "$_line" | awk '{print $3}'); _a=$(echo "$_line" | awk '{print $4}')
            echo "route-map $_n $_a $_s"
            grep "^route-map $_n $_s match " "$FRR_INTENT" 2>/dev/null | sed 's/^route-map [^ ]* [^ ]* match / match /'
            grep "^route-map $_n $_s set " "$FRR_INTENT" 2>/dev/null | sed 's/^route-map [^ ]* [^ ]* set / set /'
            echo "exit"
        done
        # BGP
        if [ -n "$_want_as" ]; then
            echo "router bgp $_want_as"
            _w=$(sed -n 's/^bgp_router_id //p' "$_wantfacts" | head -1)
            _r=$(sed -n 's/^bgp_router_id //p' "$_runfacts" | head -1)
            if [ -n "$_w" ]; then echo " bgp router-id $_w"; elif [ -n "$_r" ]; then echo " no bgp router-id"; fi
            # neighbor basi -> hapus
            grep '^bgp_neighbor .* remote-as ' "$_runfacts" 2>/dev/null | while IFS= read -r _line; do
                _in_facts "$_wantfacts" "$_line" || echo " no neighbor $(echo "$_line" | awk '{print $2}')"
            done
            # neighbor diinginkan -> tambah (remote-as beda -> hapus dulu)
            grep '^bgp_neighbor .* remote-as ' "$_wantfacts" 2>/dev/null | while IFS= read -r _line; do
                _nip=$(echo "$_line" | awk '{print $2}'); _ras=$(echo "$_line" | awk '{print $4}')
                _rras=$(sed -n "s/^bgp_neighbor $_nip remote-as //p" "$_runfacts" | head -1)
                if [ -n "$_rras" ] && [ "$_rras" != "$_ras" ]; then
                    echo " no neighbor $_nip"
                fi
                echo " neighbor $_nip remote-as $_ras"
            done
            # neighbor attrs basi -> hapus (hanya untuk neighbor yang tetap ada)
            grep '^bgp_neighbor ' "$_runfacts" 2>/dev/null | grep -v ' remote-as ' | while IFS= read -r _line; do
                _nip=$(echo "$_line" | awk '{print $2}')
                grep -q "^bgp_neighbor $_nip remote-as " "$_wantfacts" 2>/dev/null || continue
                _in_facts "$_wantfacts" "$_line" || {
                    case "$_line" in
                        *" description "*) echo " no neighbor $_nip description" ;;
                        *" route-map "*) _nm=$(echo "$_line" | awk '{print $4}'); _dr=$(echo "$_line" | awk '{print $5}'); echo " no neighbor $_nip route-map $_nm $_dr" ;;
                        *" prefix-list "*) _nm=$(echo "$_line" | awk '{print $4}'); _dr=$(echo "$_line" | awk '{print $5}'); echo " no neighbor $_nip prefix-list $_nm $_dr" ;;
                        *" send-community"*) echo " no neighbor $_nip send-community" ;;
                        *" timers "*) echo " no neighbor $_nip timers" ;;
                    esac
                }
            done
            # neighbor attrs diinginkan -> terapkan
            grep '^bgp_neighbor ' "$_wantfacts" 2>/dev/null | grep -v ' remote-as ' | while IFS= read -r _line; do
                _nip=$(echo "$_line" | awk '{print $2}')
                case "$_line" in
                    *" description "*) _tx=$(echo "$_line" | sed 's/^bgp_neighbor [^ ]* description //'); echo " neighbor $_nip description $_tx" ;;
                    *" route-map "*) _nm=$(echo "$_line" | awk '{print $4}'); _dr=$(echo "$_line" | awk '{print $5}'); echo " neighbor $_nip route-map $_nm $_dr" ;;
                    *" prefix-list "*) _nm=$(echo "$_line" | awk '{print $4}'); _dr=$(echo "$_line" | awk '{print $5}'); echo " neighbor $_nip prefix-list $_nm $_dr" ;;
                    *" send-community"*) echo " neighbor $_nip send-community" ;;
                    *" timers "*) _k=$(echo "$_line" | awk '{print $4}'); _h=$(echo "$_line" | awk '{print $5}'); echo " neighbor $_nip timers $_k $_h" ;;
                esac
            done
            # BGP networks basi -> hapus
            grep '^bgp_network ' "$_runfacts" 2>/dev/null | while IFS= read -r _line; do
                _in_facts "$_wantfacts" "$_line" || echo " no network $(echo "$_line" | awk '{print $2}')"
            done
            # BGP networks diinginkan -> terapkan
            grep '^bgp_network ' "$_wantfacts" 2>/dev/null | while IFS= read -r _line; do
                echo " network $(echo "$_line" | awk '{print $2}')"
            done
            echo "exit"
        fi
        # OSPF
        if grep -q '^ospf_' "$_wantfacts" 2>/dev/null; then
            echo "router ospf"
            _w=$(sed -n 's/^ospf_router_id //p' "$_wantfacts" | head -1)
            _r=$(sed -n 's/^ospf_router_id //p' "$_runfacts" | head -1)
            if [ -n "$_w" ]; then echo " ospf router-id $_w"; elif [ -n "$_r" ]; then echo " no ospf router-id"; fi
            grep '^ospf_network ' "$_runfacts" 2>/dev/null | while IFS= read -r _line; do
                _in_facts "$_wantfacts" "$_line" || { _p=$(echo "$_line" | awk '{print $2}'); _a=$(echo "$_line" | awk '{print $4}'); echo " no network $_p area $_a"; }
            done
            grep '^ospf_network ' "$_wantfacts" 2>/dev/null | while IFS= read -r _line; do
                _p=$(echo "$_line" | awk '{print $2}'); _a=$(echo "$_line" | awk '{print $4}'); echo " network $_p area $_a"
            done
            grep '^ospf_redist ' "$_runfacts" 2>/dev/null | while IFS= read -r _line; do
                _in_facts "$_wantfacts" "$_line" || echo " no redistribute $(echo "$_line" | awk '{print $2}')"
            done
            grep '^ospf_redist ' "$_wantfacts" 2>/dev/null | while IFS= read -r _line; do
                echo " redistribute $(echo "$_line" | awk '{print $2}')"
            done
            echo "exit"
        fi
        echo "end"
    } > "$_batch"
    # Jalankan batch via vtysh -f. Penanda gagal yang NYATA:
    # - `line N: % Unknown command...` (perintah ditolak per-baris),
    # - `Unknown command` di mana pun,
    # - `processing failure` per-daemon.
    # JANGAN pakai pola longgar `^%`: mgmtd SELALU mencetak
    # `% Configuration applied with notes:` (bahkan saat apply
    # bersih/idempotent — teruji live 16 Nov: rc=0 + hanya baris
    # itu yang mengandung `%`). Pola longgar itu membuat commit
    # abort + write memory tidak pernah jalan (bug 4b).
    vtysh -f "$_batch" > "$_out" 2>&1
    _rc=$?
    if [ "$_rc" -ne 0 ] || grep -qE 'line [0-9]+: %|Unknown command|processing failure' "$_out" 2>/dev/null; then
        echo "--- output vtysh (batch FRR) ---" >&2
        cat "$_out" >&2
        cp "$_batch" /tmp/titian-frr-apply-failed.txt 2>/dev/null || true
        rm -rf "$_tmpd"
        err "vtysh menolak sebagian perintah FRR (rc=$_rc); intent tetap tersimpan di $FRR_INTENT — perbaiki intent lalu commit lagi (batch gagal tersimpan di /tmp/titian-frr-apply-failed.txt)"
    fi
    vtysh -c "write memory" >/dev/null 2>&1 || { rm -rf "$_tmpd"; err "write memory FRR gagal"; }
    echo "frr: BGP/OSPF/policy diterapkan dari intent + write memory"
    rm -rf "$_tmpd"
    return 0
}

# --- show (vtysh passthrough) ---
do_show_ip() {
    # $1 = perintah vtysh lengkap, mis. "show ip bgp"
    _zpid=$(pgrep -x zebra 2>/dev/null | head -1)
    [ -n "$_zpid" ] || err "FRR belum jalan (enable dulu: router frr enable + commit)"
    have_vtysh || err "vtysh tidak ditemukan"
    vtysh -c "$1" || err "vtysh gagal: $1"
}


case "${1:-}" in
    check) do_check ;;
    frr-enable) do_enable ;;
    frr-disable) do_disable ;;
    frr-apply) do_apply ;;
    set-router-id) do_set_router_id "${2:-}" ;;
    del-router-id) do_del_router_id ;;
    set-log) do_set_log "${2:-}" ;;
    write-memory) do_write_memory ;;
    show) do_show ;;
    show-version) do_show_version ;;
    bgp-set-local-as) shift; cmd_bgp_set_local_as "$@" ;;
    bgp-del) cmd_bgp_del ;;
    bgp-set-router-id) shift; cmd_bgp_set_router_id "$@" ;;
    bgp-del-router-id) cmd_bgp_del_router_id ;;
    bgp-neighbor-touch) shift; cmd_bgp_neighbor_touch "$@" ;;
    bgp-neighbor-add) shift; cmd_bgp_neighbor_add "$@" ;;
    bgp-neighbor-del) shift; cmd_bgp_neighbor_del "$@" ;;
    bgp-neighbor-set) shift; cmd_bgp_neighbor_set "$@" ;;
    bgp-neighbor-unset) shift; cmd_bgp_neighbor_unset "$@" ;;
    bgp-network-add) shift; cmd_bgp_network_add "$@" ;;
    bgp-network-del) shift; cmd_bgp_network_del "$@" ;;
    ospf-touch) cmd_ospf_touch ;;
    ospf-del) cmd_ospf_del ;;
    ospf-set-router-id) shift; cmd_ospf_set_router_id "$@" ;;
    ospf-del-router-id) cmd_ospf_del_router_id ;;
    ospf-network-add) shift; cmd_ospf_network_add "$@" ;;
    ospf-network-del) shift; cmd_ospf_network_del "$@" ;;
    ospf-redist-add) shift; cmd_ospf_redist_add "$@" ;;
    ospf-redist-del) shift; cmd_ospf_redist_del "$@" ;;
    prefix-list-add) shift; cmd_prefix_list_add "$@" ;;
    prefix-list-del) shift; cmd_prefix_list_del "$@" ;;
    route-map-add) shift; cmd_route_map_add "$@" ;;
    route-map-del) shift; cmd_route_map_del "$@" ;;
    route-map-set) shift; cmd_route_map_set "$@" ;;
    route-map-unset) shift; cmd_route_map_unset "$@" ;;
    community-list-add) shift; cmd_community_list_add "$@" ;;
    community-list-del) shift; cmd_community_list_del "$@" ;;
    frr-apply-config) do_apply_config ;;
    show-ip-bgp) do_show_ip "show ip bgp" ;;
    show-ip-bgp-summary) do_show_ip "show ip bgp summary" ;;
    show-ip-ospf) do_show_ip "show ip ospf" ;;
    show-ip-ospf-neighbor) do_show_ip "show ip ospf neighbor" ;;
    show-ip-route) do_show_ip "show ip route" ;;
    *) echo "Usage: $0 {check|frr-enable|frr-disable|frr-apply|set-router-id IP|del-router-id|set-log syslog|none|write-memory|show|show-version|bgp-set-local-as AS|bgp-del|bgp-set-router-id IP|bgp-del-router-id|bgp-neighbor-touch IP|bgp-neighbor-add IP AS|bgp-neighbor-del IP|bgp-neighbor-set IP FIELD VALUE|bgp-neighbor-unset IP FIELD [DIR]|bgp-network-add PREFIX|bgp-network-del PREFIX|ospf-touch|ospf-del|ospf-set-router-id IP|ospf-del-router-id|ospf-network-add PREFIX AREA|ospf-network-del PREFIX AREA|ospf-redist-add connected|static|ospf-redist-del connected|static|prefix-list-add NAME SEQ permit|deny PREFIX [LE] [GE]|prefix-list-del NAME|route-map-add NAME permit|deny SEQ|route-map-del NAME|route-map-set NAME:ACTION:SEQ match|set ...|route-map-unset NAME:ACTION:SEQ match|set|community-list-add NAME VALUE|community-list-del NAME|frr-apply-config|show-ip-bgp|show-ip-bgp-summary|show-ip-ospf|show-ip-ospf-neighbor|show-ip-route}" >&2; exit 2 ;;
esac
