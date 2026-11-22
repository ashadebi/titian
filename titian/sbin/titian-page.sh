#!/bin/sh
# titian-page.sh — shared global pager prologue (SOURCE, do not execute).
# Usage (top of a show script, after TTY/color setup, before any output):
#   . "$SBIN_DIR/titian-page.sh"
#   titian_page_begin
# Behaviour (mirrors titian-pager.sh):
#   - stdout not a TTY          -> no-op (piped/scripted output stays plain)
#   - terminal length is 0      -> no-op (paging disabled)
#   - otherwise                 -> stdout captured to a temp file; on EXIT
#     stdout is restored and the file is paged via titian-pager.sh
#     (less -F -X -R: quit-if-one-screen, keep content, render ANSI).
#     The temp file is removed and the script's exit code is preserved.
# Terminal length is stored in $STATE_ROOT/terminal-length (default 24).
# Set it with: terminal length <0-512>   (0 = paging off)
#   or: terminal no-more / terminal more
# POSIX sh. FreeBSD /bin/sh supports `trap ... EXIT` + mktemp.
# NOTE (set -u): the re-entry guard uses ${_TITIAN_PAGE_TMP:-} so scripts
# with `set -u` (titian-fw/traffic-shape/sysctl/checkpoint) do not abort
# with "parameter not set" on first call. That is the ONLY deviation
# from the prototype verbatim text; logic is otherwise identical.
titian_page_begin() {
    [ -n "${_TITIAN_PAGE_TMP:-}" ] && return 0
    [ -t 1 ] || return 0
    _len_file="${TITIAN_STATE_ROOT:-/etc/titian}/terminal-length"
    _len=24
    [ -f "$_len_file" ] && _len="$(cat "$_len_file" 2>/dev/null)" || true
    case "$_len" in ''|*[!0-9]*) _len=24 ;; esac
    [ "$_len" = "0" ] && return 0
    _TITIAN_PAGE_TMP=$(mktemp /tmp/titian-page.XXXXXX 2>/dev/null) || return 0
    _TITIAN_PAGE_PAGER="${TITIAN_PAGER:-${SBIN_DIR:-$(dirname "$0")}/titian-pager.sh}"
    [ -x "$_TITIAN_PAGE_PAGER" ] || _TITIAN_PAGE_PAGER="${TITIAN_ROOT:-/opt/titian}/sbin/titian-pager.sh"
    exec 3>&1
    exec > "$_TITIAN_PAGE_TMP"
    trap '_rc=$?; exec 1>&3 3>&-; if [ -s "$_TITIAN_PAGE_TMP" ]; then if [ -x "$_TITIAN_PAGE_PAGER" ]; then sh "$_TITIAN_PAGE_PAGER" "$_TITIAN_PAGE_TMP"; else cat "$_TITIAN_PAGE_TMP"; fi; fi; rm -f "$_TITIAN_PAGE_TMP"; exit $_rc' EXIT
}
