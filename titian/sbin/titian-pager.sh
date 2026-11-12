#!/bin/sh
# titian-pager.sh — page long output like `less`, Cisco-style.
# Usage: titian-pager.sh <file> [no-more]
#   file     : file to display
#   no-more  : if "no-more", bypass paging (dump all at once)
# Behaviour:
#   - stdout not a TTY          -> cat (no paging, e.g. piped/scripted)
#   - terminal length is 0      -> cat (paging disabled)
#   - arg "no-more" given       -> cat (one-shot bypass)
#   - otherwise                 -> less -F -X (quit-if-one-screen, keep content on screen)
# Terminal length is stored in $STATE_ROOT/terminal-length (default 24).
# Set it with: terminal length <0-512>   (0 = paging off)
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
_len_file="$STATE_ROOT/terminal-length"
_len=24
[ -f "$_len_file" ] && _len="$(cat "$_len_file" 2>/dev/null)" || true
case "$_len" in ''|*[!0-9]*) _len=24 ;; esac
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
    less -F -X "$_file"
else
    # fallback: more (always present on FreeBSD base)
    more "$_file"
fi
