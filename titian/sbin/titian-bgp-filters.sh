#!/bin/sh
# TITIAN — daftar nama filter BGP untuk completion klish (VAR Get_bgp_filters).
# Sumber: intent bgp.conf — satu nama per baris, unik, terurut.
# Dipakai PARAM completion="${Get_bgp_filters}" (import/export filter,
# filter, no filter). Nama filter keluar apa adanya dalam bentuk CLI
# (boleh '-', mis. F-RB3011-IN; bird_ident ubah '-' -> '_' saat generate).
# Keluar kosong (rc 0) bila belum ada filter / file intent belum ada.
# POSIX sh.
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CONF="$STATE_ROOT/bgp.conf"
[ -f "$CONF" ] || exit 0
awk '$1 == "filter" { print $2 }' "$CONF" 2>/dev/null | sort -u
