#!/bin/sh
# TITIAN BSDRP — commit: terapkan semua niat pending + cek penghalang.
# Semantik (feature-list §1): commit = tulis file + service langsung
# naik. `save` = `config save` (persist ke partisi cfg); commit tanpa
# save = jalan sekarang, hilang setelah reboot (rc.conf di RAM disk).
#
# Urutan commit:
#   1. mutual exclusion bird vs FRR (dua arah) — BLOKIR bila konflik.
#   2. validasi varian bird3 atas bird.conf (braces `case`, `scope`).
#   3. terapkan niat dirty: routing (bird/frr), firewall,
#      traffic-shape, pppoe, wireguard, monitoring.
# Gagal di langkah mana pun = BERHENTI (exit 33), tidak ada terap paksa
# untuk langkah itu; langkah sebelumnya yang sudah diterapkan tetap
# diterapkan (dilaporkan apa adanya).
# POSIX sh.
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
SBIN_DIR=$(dirname "$0")
BIRD_SH="$SBIN_DIR/titian-bird.sh"
FRR_SH="$SBIN_DIR/titian-frr.sh"
FW_SH="$SBIN_DIR/titian-fw.sh"
TS_SH="$SBIN_DIR/titian-traffic-shape.sh"
PPPOE_SH="$SBIN_DIR/titian-pppoe.sh"
WG_SH="$SBIN_DIR/titian-wireguard.sh"
MON_SH="$SBIN_DIR/titian-monitoring.sh"
err() { echo "Error(commit): $*" >&2; exit 33; }

apply_routing() {
    # Niat bird/frr dari $STATE_ROOT/netstate/routing.intent.
    local intent="$STATE_ROOT/netstate/routing.intent"
    [ -f /var/run/routing.dirty ] || [ -f "$intent" ] || return 0
    _bird=$(sed -n 's/^bird //p' "$intent" 2>/dev/null | head -1)
    _frr=$(sed -n 's/^frr //p' "$intent" 2>/dev/null | head -1)
    if [ "$_bird" = "yes" ]; then
        if command -v sysrc >/dev/null 2>&1; then sysrc bird_enable="YES" >/dev/null || err "sysrc bird_enable gagal"; fi
        if [ -n "$(pgrep -x bird 2>/dev/null | head -1)" ]; then
            sh "$BIRD_SH" check filter >/dev/null 2>&1 || true
            _birdc=$(command -v birdc 2>/dev/null || echo birdc)
            $_birdc configure 2>&1 | grep -v '^BIRD' || true
            echo "commit: bird already jalan — config at-reload (birdc configure)"
        else
            if command -v service >/dev/null 2>&1; then service bird start || err "service bird start gagal"; else echo "(service tidak ada — lewati: service bird start)"; fi
            echo "commit: bird enabled + started"
        fi
    elif [ "$_bird" = "no" ]; then
        # Berhenti DULU — pakai `onestop` (FreeBSD) agar tetap berhenti
        # walau bird_enable sudah NO. `onestop` gagal di Linux -> fallback `stop`.
        if command -v service >/dev/null 2>&1; then service bird onestop 2>/dev/null || service bird stop 2>/dev/null || true; fi
        if command -v sysrc >/dev/null 2>&1; then sysrc bird_enable="NO" >/dev/null || err "sysrc bird_enable gagal"; fi
        echo "commit: bird disabled + stopped"
    fi
    if [ "$_frr" = "yes" ] || [ "$_frr" = "no" ]; then
        sh "$FRR_SH" frr-apply || exit 33
    fi
    rm -f /var/run/routing.dirty
}

apply_firewall() {
    [ -f /var/run/firewall.dirty ] || return 0
    _en=$(sed -n 's/^enable //p' /usr/local/etc/firewall.conf 2>/dev/null | head -1)
    if [ "$_en" = "yes" ]; then
        if command -v sysrc >/dev/null 2>&1; then
            sysrc pf_enable="YES" >/dev/null
            sysrc firewall_enable="YES" >/dev/null
        fi
        if command -v service >/dev/null 2>&1; then service firewall restart || err "service firewall restart gagal"; else sh "$FW_SH" apply-all || err "firewall apply gagal"; fi
        echo "commit: firewall enabled + applied"
    else
        if command -v service >/dev/null 2>&1; then service firewall stop 2>/dev/null || true; else sh "$FW_SH" apply-all || true; fi
        echo "commit: firewall disabled (anchors at-flush, pf tetap loaded)"
    fi
    rm -f /var/run/firewall.dirty
}

apply_traffic_shape() {
    [ -f /var/run/traffic-shape.dirty ] || return 0
    _en=$(sed -n 's/^enable //p' /usr/local/etc/traffic-shape.conf 2>/dev/null | head -1)
    if [ "$_en" = "yes" ]; then
        if command -v sysrc >/dev/null 2>&1; then sysrc traffic_shape_enable="YES" >/dev/null; fi
        if command -v service >/dev/null 2>&1; then service traffic-shape restart || err "service traffic-shape restart gagal"; else sh "$TS_SH" apply-all || err "traffic-shape apply gagal"; fi
        echo "commit: traffic-shape enabled + applied"
    else
        if command -v service >/dev/null 2>&1; then service traffic-shape stop 2>/dev/null || true; else sh "$TS_SH" apply --flush || true; fi
        echo "commit: traffic-shape disabled + flushed"
    fi
    rm -f /var/run/traffic-shape.dirty
}

apply_pppoe() {
    [ -f /var/run/pppoe.dirty ] || return 0
    sh "$PPPOE_SH" apply || exit 33
    rm -f /var/run/pppoe.dirty
}

apply_wireguard() {
    [ -f /var/run/wireguard.dirty ] || return 0
    sh "$WG_SH" apply-all || exit 33
    rm -f /var/run/wireguard.dirty
}

apply_monitoring() {
    [ -f /var/run/monitoring.dirty ] || return 0
    sh "$MON_SH" apply || exit 33
    rm -f /var/run/monitoring.dirty
}

do_check() {
    # Cek saja, tanpa menerapkan: exclusion + validasi bird.conf.
    sh "$BIRD_SH" check-exclusion commit || exit 33
    if [ -f /usr/local/etc/bird.conf ]; then
        sh "$BIRD_SH" validate-config /usr/local/etc/bird.conf || exit 33
    fi
    echo "commit check: OK (no  konflik bird/FRR, bird.conf pass validasi varian)"
}

do_commit() {
    do_check || exit 33
    apply_routing || exit 33
    apply_firewall || exit 33
    apply_traffic_shape || exit 33
    apply_pppoe || exit 33
    apply_wireguard || exit 33
    apply_monitoring || exit 33
    echo "commit: done"
}

do_apply_all() {
    # Dipakai boot (titian-boot.sh sesudah replay): terapkan semua niat
    # tanpa validasi ulang yang ketat — tapi exclusion TETAP diperiksa.
    sh "$BIRD_SH" check-exclusion commit || exit 33
    apply_routing || exit 33
    apply_firewall || exit 33
    apply_traffic_shape || exit 33
    apply_pppoe || exit 33
    apply_wireguard || exit 33
    apply_monitoring || exit 33
    echo "commit apply-all: done"
}

case "${1:-}" in
    check) do_check ;;
    commit) do_commit ;;
    apply-all) do_apply_all ;;
    *) echo "Usage: $0 {check|commit|apply-all}" >&2; exit 2 ;;
esac
