#!/bin/sh
# TITIAN — daftar nama community list untuk completion klish (VAR Get_comm_lists).
# Sumber: baris "define <nama> = ..." di $STATE_ROOT/bird.d/filter.conf
# (tempat yang sama dibaca 'community list show').
# Satu nama per baris, unik, terurut.
# Dipakai PARAM completion="${Get_comm_lists}" (community list delete).
# Keluar kosong (rc 0) bila belum ada list / file belum ada.
# POSIX sh.
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
FILTER="$STATE_ROOT/bird.d/filter.conf"
[ -f "$FILTER" ] || exit 0
grep '^define ' "$FILTER" 2>/dev/null | awk '{print $2}' | sort -u
