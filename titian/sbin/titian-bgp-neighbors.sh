#!/bin/sh
# TITIAN — daftar IP neighbor BGP untuk completion klish (VAR Get_bgp_neighbors).
# Sumber: intent bgp.conf — baris "neighbor <IP> ...".
# Satu IP per baris, unik, terurut.
# Dipakai PARAM completion="${Get_bgp_neighbors}" (neighbor, no neighbor).
# Keluar kosong (rc 0) bila belum ada neighbor / file intent belum ada.
# POSIX sh.
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CONF="$STATE_ROOT/bgp.conf"
[ -f "$CONF" ] || exit 0
awk '$1 == "neighbor" { print $2 }' "$CONF" 2>/dev/null | sort -u
