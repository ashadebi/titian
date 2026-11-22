#!/bin/sh
# titian-pager.sh — page long output like `less`, Cisco-style.
# Usage:
#   titian-pager.sh <file> [no-more]   — page a file
#   titian-pager.sh --stream [no-more] — page stdin directly (streaming)
#     (for ACTION XML that pipes `birdc ...` output directly, and for
#     route-table dumps too large for a temp file: `birdc show route`
#     penuh = 57 MB, sementara /tmp di mesin test hanya tmpfs 32M
#     dengan ~18M kosong — temp file di sana ENOSPC (terbukti live
#     20 Nov 2026). Mode stream TIDAK memakai temp file: stdin pipe
#     langsung ke `less`, yang membaca tombol dari /dev/tty sendiri
#     bila stdin-nya pipe (terbukti PTY: Space scroll, `q` keluar).)
#   file     : file to display
#   no-more  : if "no-more", bypass paging (dump all at once)
# Behaviour:
#   - stdout not a TTY          -> cat (no paging, e.g. piped/scripted)
#   - terminal length is 0      -> cat (paging disabled)
#   - arg "no-more" given       -> cat (one-shot bypass)
#   - otherwise                 -> less -F -X -R (quit-if-one-screen, keep
#     content on screen, render ANSI colours)
# Terminal length is stored in $STATE_ROOT/terminal-length (default 24).
# Set it with: terminal length <0-512>   (0 = paging off)
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
_len_file="$STATE_ROOT/terminal-length"
_len=24
[ -f "$_len_file" ] && _len="$(cat "$_len_file" 2>/dev/null)" || true
case "$_len" in ''|*[!0-9]*) _len=24 ;; esac
# --- mode --stream: stdin langsung ke less (tanpa temp file) ---
if [ "$1" = "--stream" ]; then
    _nom="$2"
    if [ "$_nom" = "no-more" ] || [ "$_len" = "0" ] || [ ! -t 1 ]; then
        cat
        exit 0
    fi
    if command -v less >/dev/null 2>&1; then
        # stdin = pipe data; less membaca tombol dari /dev/tty sendiri.
        less -F -X -R
    else
        # fallback: more (always present on FreeBSD base)
        more
    fi
    exit $?
fi
_file="$1"
_nom="$2"
if [ -z "$_file" ] || [ ! -f "$_file" ]; then
    echo "Error: pager file not found: ${_file:-<empty>}" >&2
    exit 1
fi
if [ "$_nom" = "no-more" ] || [ "$_len" = "0" ] || [ ! -t 1 ]; then
    cat "$_file"
    exit 0
fi
if command -v less >/dev/null 2>&1; then
    less -F -X -R "$_file"
else
    # fallback: more (always present on FreeBSD base)
    more "$_file"
fi
