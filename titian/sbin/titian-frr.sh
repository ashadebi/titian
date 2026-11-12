#!/bin/sh
# TITIAN BSDRP — FRR (net/frr10) via klish.
# - Enable/disable TIDAK langsung start/stop service: hanya mencatat
#   niat di $ROOT/etc/netstate/routing.intent (format sama dengan
#   titian-bird.sh) + menandai /var/run/routing.dirty; yang menaikkan
#   service adalah `commit` (titian-commit.sh -> frr-apply di sini).
#   Alasan: commit = tulis file + service langsung naik.
# - Config dasar (router-id, log syslog) berlaku LANGSUNG via vtysh
#   (running) + `write memory` agar persisten — model native FRR.
# - CLI FRR sendiri tetap `vtysh` via perintah `cli`; script ini
#   TIDAK mendefinisikan/menyentuh `cli`.
# POSIX sh.
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
SBIN_DIR=$(dirname "$0")
BIRD_SH="$SBIN_DIR/titian-bird.sh"
INTENT="$ROOT/etc/netstate/routing.intent"
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
        echo "(service tidak ada di host ini — lewati: service $1 $2)"
    fi
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
            echo "frr: zebra sudah jalan (tidak di-restart)"
        else
            svc frr start || err "service frr start gagal"
        fi
        echo "frr: enabled + running"
    else
        if command -v sysrc >/dev/null 2>&1; then sysrc frr_enable="NO" >/dev/null || err "sysrc frr_enable gagal"; fi
        svc frr stop 2>/dev/null || true
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
    echo "frr: router-id dihapus (running + write memory)"
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
    echo "frr: running-config ditulis ke $FRR_CONF"
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
    *) echo "Usage: $0 {check|frr-enable|frr-disable|frr-apply|set-router-id IP|del-router-id|set-log syslog|none|write-memory|show|show-version}" >&2; exit 2 ;;
esac
