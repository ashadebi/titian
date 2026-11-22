#!/bin/sh
# TITIAN — daftar community yang sedang dipakai (export + import) untuk
# completion klish (VAR Get_comm_values).
# Sumber: $STATE_ROOT/bird.d/filter.conf
#   - export: baris bgp[_ext|_large]_community.add((...)); di filter
#     bgp_export_attr (cabang static)
#   - import: baris "if (...) ~ bgp[_ext|_large]_community then ..." di
#     filter bgp_import_comm
# Nilai dikembalikan ke bentuk CLI (kebalikan norm() di titian-comm.sh):
#   (64512, 300) -> 64512:300 ; (65535, 65281) -> no-export ;
#   (65535, 65282) -> no-advertise ; (65535, 65283) -> no-peer ;
#   (65535, 666) -> blackhole ; (rt, AA, NN) -> rt:AA:NN ;
#   (ro, AA, NN) -> ro:AA:NN ; (AA, X, NN) -> large:AA:X:NN
# Satu nilai per baris, unik, terurut.
# Dipakai PARAM completion="${Get_comm_values}" (community export delete,
# community import delete).
# Keluar kosong (rc 0) bila belum ada / file belum ada.
# POSIX sh.
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
FILTER="$STATE_ROOT/bird.d/filter.conf"
[ -f "$FILTER" ] || exit 0
awk '
function rev(t,    s, n, p, a, b) {
    s = t
    gsub(/[()]/, "", s)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    n = split(s, p, /[[:space:]]*,[[:space:]]*/)
    if (n == 2) {
        a = p[1]; b = p[2]
        if (a == "65535" && b == "65281") return "no-export"
        if (a == "65535" && b == "65282") return "no-advertise"
        if (a == "65535" && b == "65283") return "no-peer"
        if (a == "65535" && b == "666") return "blackhole"
        return a ":" b
    }
    if (n == 3) {
        if (p[1] == "rt" || p[1] == "ro") return p[1] ":" p[2] ":" p[3]
        return "large:" p[1] ":" p[2] ":" p[3]
    }
    return ""
}
# export: bgp_community.add((...)); — buang "add(" di depan dan ");" di akhir
/community\.add\(/ {
    line = $0
    sub(/^.*\.add\(/, "", line)
    sub(/\);[[:space:]]*$/, "", line)
    r = rev(line)
    if (r != "") print r
    next
}
# import: if (...) ~ bgp_community then ... — ambil grup kurung pertama
/~ bgp_.*community then/ {
    if (match($0, /\([^)]*\)/)) {
        r = rev(substr($0, RSTART, RLENGTH))
        if (r != "") print r
    }
}
' "$FILTER" 2>/dev/null | sort -u
