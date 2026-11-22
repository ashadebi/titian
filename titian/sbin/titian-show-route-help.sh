#!/bin/sh
# titian-show-route-help.sh — daftar sub-perintah `show route` (enable-view)
# yang SAMA dengan yang ditampilkan `show route ?`, tapi lewat pager global.
#
# Latar: `?` (help/completion inline) dirender klish sendiri di dalam line
# editor (libtinyrl) — SEBELUM perintah dieksekusi, tanpa ACTION apa pun —
# jadi prologue pager (yang membungkus stdout ACTION) TIDAK BISA
# mencegatnya, dan klish 2.2.5 tidak punya opsi/hook pager untuk `?`
# (terbukti 20 Nov 2026: `clish --help` tanpa opsi pager; `strings`
# libclish/libtinyrl/liblub tanpa "pager"/"less"/"PAGER"; `terminal
# length 0` tidak mengubah output `?`). Perintah ini adalah alternatif
# yang dipager: `show route help`.
#
# Daftar dibaca dari XML enable-view (en-show-birdc.xml) saat runtime,
# jadi selalu sinkron dengan definisi perintah: sub-perintah satu kata
# setelah "show route" (diurut abjad, seperti tampilan `?`), ditambah
# `<cr>` (perintah dasar `show route`, dengan teks help-nya) di akhir.
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

# Cari XML enable-view: override env (mock) > lokasi mesin (flat, yang
# dibaca klish via -x /opt/titian/etc/clish-en) > tree/ > staging.
XML="${TITIAN_ROUTE_HELP_XML:-}"
if [ -z "$XML" ]; then
    for _c in "$SBIN_DIR/../etc/clish-en/en-show-birdc.xml" \
             "$SBIN_DIR/../etc/clish-en/tree/en-show-birdc.xml" \
             "$SBIN_DIR/../tree/en-show-birdc.xml"; do
        if [ -f "$_c" ]; then XML="$_c"; break; fi
    done
fi
if [ -z "$XML" ] || [ ! -f "$XML" ]; then
    echo "Error(titian-show-route-help): XML en-show-birdc.xml tidak ditemukan." >&2
    exit 33
fi

# Parse XML: pasangan (nama, help) untuk COMMAND "show route" dan
# "show route <satu-kata>". Tag pembuka COMMAND bisa multi-baris; help
# bisa di baris yang sama atau berikutnya — kumpulkan sampai '>' penutup.
_all=$(awk '
function flush() {
    if (curname == "") return
    if (curname ~ /^show route [^ ]+$/) {
        print substr(curname, 12) "\t" curhelp
    } else if (curname == "show route") {
        print "<cr>\t" curhelp
    }
    curname = ""; curhelp = ""
}
function parse(b,   n, h) {
    if (b !~ /name="show route/) return
    n = b; sub(/.*name="/, "", n); sub(/".*/, "", n)
    h = ""
    if (b ~ /help="/) { h = b; sub(/.*help="/, "", h); sub(/".*/, "", h) }
    curname = n; curhelp = h
}
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
' "$XML")

if [ -z "$_all" ]; then
    echo "Error(titian-show-route-help): tidak ada sub-perintah show route di $XML." >&2
    exit 33
fi

# Urut abjad seperti tampilan `?`; <cr> selalu terakhir.
_list=$(printf '%s\n' "$_all" | grep -v '^<cr>' | LC_ALL=C sort)
_cr=$(printf '%s\n' "$_all" | grep '^<cr>' | head -1)

# Dekode entitas XML (&lt; &gt; &quot; &amp; — &amp; terakhir supaya tidak
# ganda-dekode) — sed yang sama dipakai titian-birdc.sh (klish_unescape).
_decode() {
    sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e 's/&amp;/\&/g'
}

if [ "$_LANG" = "indonesian" ]; then
    _hdr="Sub-perintah show route (sama seperti 'show route ?', dipager):"
    _tip="Tip: 'show route ?' menampilkan daftar yang sama (tanpa pager)."
else
    _hdr="Sub-commands show route (same as 'show route ?', paged):"
    _tip="Tip: 'show route ?' shows the same list (without pager)."
fi

{
    echo "$_hdr"
    printf '%s\n' "$_list" | awk -F'\t' '{ printf "  %-11s %s\n", $1, $2 }'
    printf '%s\n' "$_cr" | awk -F'\t' '{ printf "  %-11s %s\n", $1, $2 }'
    echo "$_tip"
} | _decode
