#!/bin/sh
# titian-help.sh — daftar perintah dipager (alternatif `?` yang TIDAK BISA dipager).
#   titian-help.sh show  -> sub-perintah `show` (sama seperti `show ?`, 36 entri)
#   titian-help.sh all   -> semua perintah top-level (sama seperti `?` di prompt, 27 entri)
#
# Latar: `?` (help/completion inline) dirender klish sendiri di dalam line
# editor (libtinyrl) — SEBELUM perintah dieksekusi, tanpa ACTION apa pun —
# jadi prologue pager (yang membungkus stdout ACTION) TIDAK BISA
# mencegatnya, dan klish 2.2.5 tidak punya opsi/hook pager untuk `?`
# (terbukti 20 Nov 2026: `clish --help` tanpa opsi pager; `strings`
# libclish/libtinyrl/liblub tanpa "pager"/"less"/"PAGER"; `terminal
# length 0` tidak mengubah output `?`). Perintah ini adalah alternatif
# yang dipager, mengikuti pola `show route help` (titian-show-route-help.sh).
#
# Daftar dibaca dari SEMUA XML clish-en saat runtime (view-aware), jadi
# selalu sinkron dengan definisi perintah: hanya COMMAND di view
# enable-view + namespace yang di-include ke enable-view (ping-view,
# syshw-view) yang tampil — persis seperti yang ditampilkan `?` di view
# itu (terbukti cocok 1:1 dengan pengukuran live HELP2-PROBE.py 20 Nov:
# `show ?` = 36 entri, `?` prompt = 27 entri incl. `!`).
# COMMAND yang dikomentari (<!-- -->) dilewati parser; tidak ada baris
# yang berisi tag sekaligus komentar di tree ini (terverifikasi 20 Nov).
# Entitas XML di-decode. XML dir hilang / daftar kosong -> rc 33.
# POSIX sh. FreeBSD /bin/sh.
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
SBIN_DIR=$(dirname "$0")
. "$SBIN_DIR/titian-page.sh"
titian_page_begin

# Bahasa help: baca state file yang ditulis `titian-help-lang.py set`
# (default english bila file tidak ada / isi tidak dikenal). Header + tip
# perintah help ini mengikuti bahasa yang sama dengan isi daftar (XML).
_help_lang() {
    _f="$STATE_ROOT/help-language"
    if [ -f "$_f" ]; then
        _l=$(tr -d ' \t\r\n' < "$_f" 2>/dev/null)
        case "$_l" in
            indonesian|english) printf '%s' "$_l"; return ;;
        esac
    fi
    printf 'english'
}
_LANG=$(_help_lang)

MODE="$1"
case "$MODE" in
    show|all) ;;
    *) echo "Error(titian-help): mode harus 'show' atau 'all'." >&2; exit 33 ;;
esac

# Cari direktori XML: override env (mock) > lokasi mesin (flat, yang
# dibaca klish via -x /opt/titian/etc/clish-en) > tree/ staging.
XMLDIR="${TITIAN_HELP_XML_DIR:-}"
if [ -z "$XMLDIR" ]; then
    for _d in "$SBIN_DIR/../etc/clish-en" "$SBIN_DIR/../tree"; do
        if [ -d "$_d" ]; then XMLDIR="$_d"; break; fi
    done
fi
if [ -z "$XMLDIR" ] || [ ! -d "$XMLDIR" ]; then
    echo "Error(titian-help): direktori XML clish-en tidak ditemukan." >&2
    exit 33
fi

# Parse semua XML: lacak VIEW aktif, lewati komentar, kumpulkan COMMAND
# (tag pembuka bisa multi-baris). Hanya view enable-view/ping-view/
# syshw-view. Mode show: "show <satu-kata>" (buang prefix "show ");
# mode all: perintah satu kata. Dedup + urut abjad seperti tampilan `?`.
_list=$(awk -v mode="$MODE" '
function flush() {
    if (curname == "") return
    if (view == "enable-view" || view == "ping-view" || view == "syshw-view") {
        if (mode == "show") {
            if (curname ~ /^show [^ ]+$/) print substr(curname, 6) "\t" curhelp
        } else {
            if (curname ~ /^[^ ]+$/) print curname "\t" curhelp
        }
    }
    curname = ""; curhelp = ""
}
function parse(b,   n, h) {
    if (b !~ /name="/) return
    n = b; sub(/.*name="/, "", n); sub(/".*/, "", n)
    h = ""
    if (b ~ /help="/) { h = b; sub(/.*help="/, "", h); sub(/".*/, "", h) }
    curname = n; curhelp = h
}
FNR == 1 { view = ""; curname = ""; curhelp = ""; in_cmd = 0; in_comment = 0 }
in_comment {
    if ($0 ~ /-->/) in_comment = 0
    next
}
/<!--/ {
    if ($0 !~ /-->/) in_comment = 1
    next
}
/<VIEW / {
    flush()
    v = $0; sub(/.*name="/, "", v); sub(/".*/, "", v); view = v
    next
}
/<\/VIEW>/ { flush(); view = ""; next }
/<COMMAND/ {
    flush()
    in_cmd = 1; buf = $0
    if ($0 ~ />/) { parse(buf); in_cmd = 0 }
    next
}
in_cmd {
    buf = buf "\n" $0
    if ($0 ~ />/) { parse(buf); in_cmd = 0 }
    next
}
END { flush() }
' "$XMLDIR"/*.xml | LC_ALL=C sort -u)

if [ -z "$_list" ]; then
    echo "Error(titian-help): tidak ada perintah ditemukan di $XMLDIR." >&2
    exit 33
fi

# Dekode entitas XML (&lt; &gt; &quot; &amp; — &amp; terakhir supaya tidak
# ganda-dekode) — sed yang sama dipakai titian-birdc.sh (klish_unescape).
_decode() {
    sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e 's/&amp;/\&/g'
}

if [ "$_LANG" = "indonesian" ]; then
    _hdr_show="Sub-perintah show (sama seperti 'show ?', dipager):"
    _tip_show="Tip: 'show ?' menampilkan daftar yang sama (tanpa pager)."
    _hdr_all="Perintah top-level (sama seperti '?' di prompt, dipager):"
    _tip_all="Tip: '?' di prompt menampilkan daftar yang sama (tanpa pager)."
else
    _hdr_show="Sub-commands show (same as 'show ?', paged):"
    _tip_show="Tip: 'show ?' shows the same list (without pager)."
    _hdr_all="Top-level commands (same as '?' at the prompt, paged):"
    _tip_all="Tip: '?' at the prompt shows the same list (without pager)."
fi

if [ "$MODE" = "show" ]; then
    {
        echo "$_hdr_show"
        printf '%s\n' "$_list" | awk -F'\t' '{ printf "  %-16s %s\n", $1, $2 }'
        echo "$_tip_show"
    } | _decode
else
    {
        echo "$_hdr_all"
        printf '  %-18s %s\n' "!" "Comments"
        printf '%s\n' "$_list" | awk -F'\t' '{ printf "  %-18s %s\n", $1, $2 }'
        echo "$_tip_all"
    } | _decode
fi
