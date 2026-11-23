#!/bin/sh
# TITIAN — daftar nama protocol BGP custom untuk completion klish
# (VAR Get_bgp_protonames).
# Sumber: intent bgp.conf — baris "neighbor <IP> protocol-name <Nama>".
# Satu nama per baris, unik, terurut.
# Dipakai PARAM completion="${Get_bgp_protonames}" (protocol-name).
# Keluar kosong (rc 0) bila belum ada / file intent belum ada.
# POSIX sh.
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CONF="$STATE_ROOT/bgp.conf"
[ -f "$CONF" ] || exit 0
awk '$1 == "neighbor" && $3 == "protocol-name" { print $4 }' "$CONF" 2>/dev/null | sort -u
