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
BFD_SH="$SBIN_DIR/titian-bfd.sh"
GLOBAL_SH="$SBIN_DIR/titian-global.sh"
OSPF_SH="$SBIN_DIR/titian-ospf.sh"
AGG_SH="$SBIN_DIR/titian-aggregator.sh"
MRT_SH="$SBIN_DIR/titian-mrt.sh"
RADV_SH="$SBIN_DIR/titian-radv.sh"
RPKI_SH="$SBIN_DIR/titian-rpki.sh"
BMP_SH="$SBIN_DIR/titian-bmp.sh"
BABEL_SH="$SBIN_DIR/titian-babel.sh"
L3VPN_SH="$SBIN_DIR/titian-l3vpn.sh"
FRR_SH="$SBIN_DIR/titian-frr.sh"
FW_SH="$SBIN_DIR/titian-fw.sh"
TS_SH="$SBIN_DIR/titian-traffic-shape.sh"
PPPOE_SH="$SBIN_DIR/titian-pppoe.sh"
WG_SH="$SBIN_DIR/titian-wireguard.sh"
MON_SH="$SBIN_DIR/titian-monitoring.sh"
err() { echo "Error(commit): $*" >&2; exit 33; }

# birdc_sock — salinan titian-birdc.sh (BC8, B13): cetak "-s <path>" bila
# socket utama dikonfigurasi via klish ($STATE_ROOT/birdc.conf), kosong bila
# default. Dipakai semua pemanggilan birdc di file ini.
birdc_sock() {
    _s=$(grep '^socket ' "$STATE_ROOT/birdc.conf" 2>/dev/null | head -1 | cut -d' ' -f2-)
    [ -n "$_s" ] && printf '%s' "-s $_s"
}

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
            $_birdc $(birdc_sock) configure 2>&1 | grep -v '^BIRD' || true
            echo "commit: bird already jalan — config at-reload (birdc configure)"
        else
            if command -v service >/dev/null 2>&1; then service bird start || err "service bird start gagal"; else echo "(service tidak ada — lewati: service bird start)"; fi
            echo "commit: bird enabled + started"
        fi
    elif [ "$_bird" = "no" ]; then
        # Hanya stop + cetak bila BIRD benar-benar jalan/enabled.
        # Niat `bird no` bisa tertinggal dari commit sebelumnya (mis.
        # langkah 1 switch BIRD->FRR) — mencetak "disabled + stopped"
        # lagi di commit FRR enable menyesatkan (tes 14, T3).
        if [ -n "$(pgrep -x bird 2>/dev/null | head -1)" ] || [ "$(sysrc -n bird_enable 2>/dev/null)" = "YES" ]; then
            # Berhenti DULU — pakai `onestop` (FreeBSD) agar tetap berhenti
            # walau bird_enable sudah NO. `onestop` gagal di Linux -> fallback `stop`.
            if command -v service >/dev/null 2>&1; then service bird onestop 2>/dev/null || service bird stop 2>/dev/null || true; fi
            if command -v sysrc >/dev/null 2>&1; then sysrc bird_enable="NO" >/dev/null || err "sysrc bird_enable gagal"; fi
            echo "commit: bird disabled + stopped"
        else
            # Sudah berhenti di commit sebelumnya — pastikan rc NO saja,
            # tanpa pesan yang menyesatkan.
            if command -v sysrc >/dev/null 2>&1; then sysrc bird_enable="NO" >/dev/null || err "sysrc bird_enable gagal"; fi
        fi
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

apply_ipoe() {
    # IPoE server (isc-dhcpd): start if ipoe.conf has enable + pool, else stop.
    _intent="${STATE_ROOT:-/etc/titian}/ipoe.conf"
    if [ -f "$_intent" ] && grep -q "^enable$" "$_intent" 2>/dev/null && grep -q "^pool " "$_intent" 2>/dev/null; then
        sh "$SBIN_DIR/titian-dhcp.sh" server-start || exit 33
    else
        sh "$SBIN_DIR/titian-dhcp.sh" server-stop 2>/dev/null || true
    fi
}

apply_global() {
    # B6: opsi global + tabel + MPLS domain + template BIRD — generate
    # section bila bird-global.conf ada. Dijalankan PALING AWAL di
    # antara apply BIRD — tabel/template dipakai protokol lain.
    # Dilewati bila belum pernah ada config global.
    _intent="${STATE_ROOT:-/etc/titian}/bird-global.conf"
    if [ -f "$_intent" ]; then
        sh "$GLOBAL_SH" generate || exit 33
    fi
}

apply_protocol() {
    # Kernel + Device (BIRD): generate section protocol bila ada intent
    # kernel.conf dan/atau device.conf. Dilewati bila belum pernah ada
    # config keduanya (protocol.conf contoh tetap dipakai apa adanya).
    # Dijalankan PALING AWAL di antara apply BIRD — device/kernel adalah
    # fondasi yang dipakai protokol lain.
    _k="${STATE_ROOT:-/etc/titian}/kernel.conf"
    _d="${STATE_ROOT:-/etc/titian}/device.conf"
    if [ -f "$_k" ] || [ -f "$_d" ]; then
        sh "$SBIN_DIR/titian-protocol.sh" generate || exit 33
    fi
}

apply_direct() {
    # Direct (BIRD): generate section bila direct.conf ada.
    # Dilewati bila belum pernah ada config direct (bird.d/direct.conf
    # lama pra-B4 — mis. dari `redistribute direct enable` sebelum
    # intent ada — tidak ditimpa).
    _intent="${STATE_ROOT:-/etc/titian}/direct.conf"
    if [ -f "$_intent" ]; then
        sh "$SBIN_DIR/titian-direct.sh" generate || exit 33
    fi
}

apply_pipe() {
    # Pipe (BIRD): generate section bila pipe.conf ada.
    _intent="${STATE_ROOT:-/etc/titian}/pipe.conf"
    if [ -f "$_intent" ]; then
        sh "$SBIN_DIR/titian-pipe.sh" generate || exit 33
    fi
}

apply_bfd() {
    # BFD (BIRD): generate section bila bfd.conf ada (file dibuat saat
    # user masuk view bfd). WAJIB sebelum apply_bgp — birdc configure
    # gagal bila neighbor BGP pakai `bfd on;` tanpa `protocol bfd`.
    # Dilewati bila belum pernah ada config BFD.
    _intent="${STATE_ROOT:-/etc/titian}/bfd.conf"
    if [ -f "$_intent" ]; then
        sh "$BFD_SH" generate || exit 33
    fi
}

apply_static() {
    # Static (BIRD): generate section bila static.conf ada.
    # Sesudah apply_bfd — route dengan BFD per-nexthop butuh section
    # `protocol bfd` sudah ter-generate.
    _intent="${STATE_ROOT:-/etc/titian}/static.conf"
    if [ -f "$_intent" ]; then
        sh "$SBIN_DIR/titian-static.sh" generate || exit 33
    fi
}

apply_rip() {
    # RIP/RIPng (BIRD): generate section bila rip.conf ada.
    # Sesudah apply_static, sebelum apply_bgp — RIP tidak bergantung
    # pada BFD maupun BGP.
    _intent="${STATE_ROOT:-/etc/titian}/rip.conf"
    if [ -f "$_intent" ]; then
        sh "$SBIN_DIR/titian-rip.sh" generate || exit 33
    fi
}

apply_ospf() {
    # OSPF BIRD (v2/v3): generate section bila ospf.conf ada.
    # Sesudah apply_rip, sebelum apply_bgp — OSPF interface `bfd`
    # butuh section `protocol bfd` (apply_bfd sudah jalan lebih dulu).
    _intent="${STATE_ROOT:-/etc/titian}/ospf.conf"
    if [ -f "$_intent" ]; then
        sh "$OSPF_SH" generate || exit 33
    fi
}

apply_aggregator() {
    # Aggregator (BIRD, Bab 6.1): generate section bila aggregator.conf ada.
    # Sesudah apply_ospf, sebelum apply_function — aggregator membaca
    # tabel routing (bisa berisi route OSPF/BGP) dan menulis ke tabel
    # tujuan; generate sesudah OSPF agar section OSPF sudah terbaru.
    _intent="${STATE_ROOT:-/etc/titian}/aggregator.conf"
    if [ -f "$_intent" ]; then
        sh "$AGG_SH" generate || exit 33
    fi
}

apply_mrt() {
    # MRT (BIRD, Bab 6.10): generate section bila mrt.conf ada.
    # Sesudah apply_ospf, sebelum apply_function — MRT dump membaca
    # tabel routing; tidak ada dependensi ke function/BGP.
    _intent="${STATE_ROOT:-/etc/titian}/mrt.conf"
    if [ -f "$_intent" ]; then
        sh "$MRT_SH" generate || exit 33
    fi
}

apply_radv() {
    # RAdv (BIRD, Bab 6.14): generate section bila radv.conf ada.
    # Sesudah apply_ospf, sebelum apply_function — RAdv mengiklankan
    # prefix dari tabel ipv6; tidak ada dependensi ke function/BGP.
    _intent="${STATE_ROOT:-/etc/titian}/radv.conf"
    if [ -f "$_intent" ]; then
        sh "$RADV_SH" generate || exit 33
    fi
}

apply_rpki() {
    # RPKI (BIRD, Bab 6.16): generate section bila rpki.conf ada.
    # Sesudah apply_radv, sebelum apply_function — tabel ROA/ASPA
    # dipakai filter BGP (roa_check/aspa_check).
    _intent="${STATE_ROOT:-/etc/titian}/rpki.conf"
    if [ -f "$_intent" ]; then
        sh "$RPKI_SH" generate || exit 33
    fi
}

apply_bmp() {
    # BMP (BIRD, Bab 6.5): generate section bila bmp.conf ada.
    _intent="${STATE_ROOT:-/etc/titian}/bmp.conf"
    if [ -f "$_intent" ]; then
        sh "$BMP_SH" generate || exit 33
    fi
}

apply_babel() {
    # Babel (BIRD, Bab 6.2): generate section bila babel.conf ada.
    _intent="${STATE_ROOT:-/etc/titian}/babel.conf"
    if [ -f "$_intent" ]; then
        sh "$BABEL_SH" generate || exit 33
    fi
}

apply_l3vpn() {
    # L3VPN (BIRD, Bab 6.9): generate section bila l3vpn.conf ada.
    # Sesudah apply_babel — L3VPN memakai tabel vpn/mpls yang
    # didefinisikan di global (apply_global sudah jalan paling awal).
    _intent="${STATE_ROOT:-/etc/titian}/l3vpn.conf"
    if [ -f "$_intent" ]; then
        sh "$L3VPN_SH" generate || exit 33
    fi
}

apply_function() {
    # B5: fungsi filter BIRD — generate section bila function.intent ada.
    # Sesudah apply_ospf, sebelum apply_bgp — filter BGP yang memanggil
    # fungsi (call:NAMA) butuh definisi fungsi sudah ter-generate saat
    # bird -p mem-parse bird.conf. Dilewati bila belum pernah ada fungsi
    # (function.conf contoh tetap dipakai apa adanya).
    _intent="${STATE_ROOT:-/etc/titian}/function.intent"
    if [ -f "$_intent" ]; then
        sh "$SBIN_DIR/titian-function.sh" generate || exit 33
    fi
}

apply_bgp() {
    # BGP (BIRD): generate section bila bgp.conf ada + local-as diset.
    # Bila tidak ada neighbor, generate tetap jalan (section kosong) agar
    # marker BGP di bird.conf tetap valid; birdc configure no-op.
    _intent="${STATE_ROOT:-/etc/titian}/bgp.conf"
    if [ -f "$_intent" ] && grep -q "^local-as " "$_intent" 2>/dev/null; then
        sh "$SBIN_DIR/titian-bgp.sh" generate || exit 33
    fi
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
    apply_ipoe || exit 33
    apply_global || exit 33
    apply_protocol || exit 33
    apply_direct || exit 33
    apply_pipe || exit 33
    apply_bfd || exit 33
    apply_static || exit 33
    apply_rip || exit 33
    apply_ospf || exit 33
    apply_aggregator || exit 33
    apply_mrt || exit 33
    apply_radv || exit 33
    apply_rpki || exit 33
    apply_bmp || exit 33
    apply_babel || exit 33
    apply_l3vpn || exit 33
    apply_function || exit 33
    apply_bgp || exit 33
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
    apply_ipoe || exit 33
    apply_global || exit 33
    apply_protocol || exit 33
    apply_direct || exit 33
    apply_pipe || exit 33
    apply_bfd || exit 33
    apply_static || exit 33
    apply_rip || exit 33
    apply_ospf || exit 33
    apply_aggregator || exit 33
    apply_mrt || exit 33
    apply_radv || exit 33
    apply_rpki || exit 33
    apply_bmp || exit 33
    apply_babel || exit 33
    apply_l3vpn || exit 33
    apply_function || exit 33
    apply_bgp || exit 33
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
