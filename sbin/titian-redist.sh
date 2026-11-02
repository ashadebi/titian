#!/bin/sh
# TITIAN — kelola redistribusi route ke peer BGP lewat CLI (bird-view).
#   redistribute static enable|disable : ekspor route RTS_STATIC ke BGP
#     (toggle via guard line di bgp_export_attr; isi cabang dipertahankan)
#   redistribute direct enable|disable : protokol direct + cabang RTS_DEVICE
#     (route connected interface -> BGP)
#   redistribute show : status static/direct + cabang export terkait
# Pola: edit section -> generate check (parse saja) -> lolos baru generate.
# POSIX sh. Dipanggil dari bird-view sebagai ${RT_SBIN}/titian-redist.sh.
DIR=$(dirname "$0")
ROOT=$(dirname "$DIR")
FILTER="$ROOT/etc/bird.d/filter.conf"
DIRECT="$ROOT/etc/bird.d/direct.conf"
BIRD_SH="$DIR/titian-bird.sh"
err() { echo "Error: $*" >&2; exit 33; }
[ -f "$FILTER" ] || err "filter.conf tidak ada: $FILTER"
[ -x "$BIRD_SH" ] || err "titian-bird.sh tidak ada: $BIRD_SH"

# apply SECTION: check dulu, lolos baru generate; gagal -> tidak terap.
apply() {
    if ! "$BIRD_SH" check "$1" >/tmp/titian-redist-check.out 2>&1; then
        cat /tmp/titian-redist-check.out >&2
        err "parse GAGAL section $1 (tidak ada perubahan diterapkan)"
    fi
    "$BIRD_SH" generate "$1" || err "generate $1 gagal setelah check lolos"
}

# --- static: guard line di ATAS bgp_export_attr (blokir SEMUA cabang static,
# termasuk cabang net-spesifik seperti /25 yang dievaluasi sebelum cabang
# RTS_STATIC; guard lokal-cabang tidak cukup) ---
GUARD="    if source = RTS_STATIC then reject;"
static_state() {
    if grep -qF -- "$GUARD" "$FILTER"; then echo "disabled"; else echo "enabled"; fi
}
static_enable() {
    if [ "$(static_state)" = "enabled" ]; then echo "static export sudah aktif"; return 0; fi
    awk -v g="$GUARD" '
        /^filter bgp_export_attr/ { infilter = 1 }
        infilter && $0 == g { next }
        { print }
    ' "$FILTER" > "$FILTER.tmp" || err "gagal edit $FILTER"
    mv "$FILTER.tmp" "$FILTER" || err "gagal tulis $FILTER"
    apply filter
    echo "static export: enabled"
}
static_disable() {
    if [ "$(static_state)" = "disabled" ]; then echo "static export sudah nonaktif"; return 0; fi
    awk -v g="$GUARD" '
        /^filter bgp_export_attr/ { infilter = 1; print; print g; inserted = 1; next }
        { print }
        END { if (!infilter || !inserted) exit 3 }
    ' "$FILTER" > "$FILTER.tmp"; rc=$?
    case $rc in
        3) rm -f "$FILTER.tmp"; err "filter bgp_export_attr tidak ditemukan di $FILTER" ;;
        0) mv "$FILTER.tmp" "$FILTER" || err "gagal tulis $FILTER"; apply filter; echo "static export: disabled" ;;
        *) rm -f "$FILTER.tmp"; err "gagal edit $FILTER" ;;
    esac
}

# --- direct: protocol direct + cabang RTS_DEVICE di bgp_export_attr ---
DEVBR="    if source = RTS_DEVICE then accept;"
direct_state() {
    if grep -q "protocol direct" "$DIRECT" 2>/dev/null && grep -qF -- "$DEVBR" "$FILTER"; then echo "enabled"; else echo "disabled"; fi
}
direct_enable() {
    if [ "$(direct_state)" = "enabled" ]; then echo "direct export sudah aktif"; return 0; fi
    # 1) cabang RTS_DEVICE di filter (sisip sebelum reject akhir bgp_export_attr)
    if ! grep -qF -- "$DEVBR" "$FILTER"; then
        awk -v b="$DEVBR" '
            /^filter bgp_export_attr/ { infilter = 1 }
            infilter && !inserted && /^ *reject;$/ { print b; inserted = 1 }
            { print }
            END { if (!infilter || !inserted) exit 3 }
        ' "$FILTER" > "$FILTER.tmp"; rc=$?
        case $rc in
            3) rm -f "$FILTER.tmp"; err "filter bgp_export_attr tidak ditemukan di $FILTER" ;;
            0) mv "$FILTER.tmp" "$FILTER" || err "gagal tulis $FILTER" ;;
            *) rm -f "$FILTER.tmp"; err "gagal edit $FILTER" ;;
        esac
        apply filter
    fi
    # 2) protokol direct (interface PtP lab; default per-OS bila tanpa argumen)
    if [ -n "$1" ]; then iface=$1; elif [ "$(uname -s)" = "FreeBSD" ]; then iface=vtnet1; else iface=enp9s0; fi
    printf 'protocol direct direct1 {\n    interface "%s";\n    ipv4;\n}\n' "$iface" > "$DIRECT" || err "gagal tulis $DIRECT"
    apply direct
    echo "direct export: enabled (interface $iface)"
}
direct_disable() {
    if [ "$(direct_state)" = "disabled" ]; then echo "direct export sudah nonaktif"; return 0; fi
    awk -v b="$DEVBR" '
        $0 == b { next }
        { print }
    ' "$FILTER" > "$FILTER.tmp" || err "gagal edit $FILTER"
    mv "$FILTER.tmp" "$FILTER" || err "gagal tulis $FILTER"
    apply filter
    printf '# TITIAN bird.d/direct.conf — protokol direct nonaktif.\n' > "$DIRECT" || err "gagal tulis $DIRECT"
    apply direct
    echo "direct export: disabled"
}

redist_show() {
    echo "static export: $(static_state)"
    echo "direct export: $(direct_state)"
    echo "--- cabang export (filter) ---"
    grep -E "RTS_STATIC|RTS_DEVICE" "$FILTER" || echo "(tidak ada cabang RTS_*)"
    echo "--- direct.conf ---"
    cat "$DIRECT" 2>/dev/null || echo "(tidak ada direct.conf)"
}

case "${1:-}" in
    static-enable)  static_enable ;;
    static-disable) static_disable ;;
    direct-enable)  direct_enable "$2" ;;
    direct-disable) direct_disable ;;
    show)           redist_show ;;
    *) echo "Usage: $0 {static-enable|static-disable|direct-enable [iface]|direct-disable|show}" >&2; exit 2 ;;
esac
