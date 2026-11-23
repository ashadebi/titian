#!/bin/sh
# TITIAN — tempel/lepas filter BIRD ke protokol lewat CLI (bird-view).
# Pola: cari blok protokol di bird.d/*.conf -> edit baris import/export
# blok ipv4 -> check section (parse saja) -> lolos baru generate section.
# Gagal check = fragment dikembalikan dari backup, tidak ada perubahan
# diterapkan. Generate gagal setelah check lolos hanya diperingatkan,
# sama seperti titian-comm.sh (fragmen sudah teredit, bird.conf sudah
# tertulis tapi belum di-configure; ulangi generate).
# Detach mengembalikan default: import all / export none (keadaan
# pra-tempel bgp_mikrotik; diumumkan di output).
# Perintah ini menerima NAMA FILTER, bukan nilai community. Dukungan
# well-known attribute hidup di titian-comm.sh (community add menerima
# no-export/no-advertise/no-peer/blackhole) dan tetap berlaku sesudah
# filter ditempel, karena community add me-regenerate section filter
# yang kini dirujuk protokol.
# Batasan: hanya baris import/export satu baris di blok ipv4 yang
# didukung (indentasi spasi, sesuai fragmen yang ada). Filter inline
# multi-baris (import filter { ... }) ditolak tertutup, tanpa perubahan.
# POSIX sh. Dipanggil dari bird-view sebagai ${RT_SBIN}/titian-filter.sh.
DIR=$(dirname "$0")
ROOT=$(dirname "$DIR")
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
BIRDD="$STATE_ROOT/bird.d"
FILTER="$BIRDD/filter.conf"
BIRD_SH="$DIR/titian-bird.sh"
err() { echo "Error: $*" >&2; exit 33; }
[ -d "$BIRDD" ] || err "bird.d tidak ada: $BIRDD"
[ -f "$FILTER" ] || err "filter.conf tidak ada: $FILTER"
[ -x "$BIRD_SH" ] || err "titian-bird.sh tidak ada: $BIRD_SH"

valid_name() {
    case "$1" in ''|*[!A-Za-z0-9_]*) return 1 ;; *) return 0 ;; esac
}

# find_proto NAME -> cetak path fragmen (satu baris). Gagal bila tidak
# ditemukan, atau ditemukan di lebih dari satu fragmen.
find_proto() {
    local name=$1 f n files
    files=""
    n=0
    for f in "$BIRDD"/*.conf; do
        [ -f "$f" ] || continue
        if grep -Eq "^ *protocol +[A-Za-z0-9_]+ +$name *[{]" "$f" 2>/dev/null; then
            files="$files $f"
            n=$((n + 1))
        fi
    done
    case $n in
        0) err "protokol $name tidak ditemukan di $BIRDD/*.conf (tulis dulu ke fragmen, lalu generate)" ;;
        1) ;;
        *) err "protokol $name ditemukan di lebih dari satu fragmen:$files (rapikan dulu)" ;;
    esac
    echo "${files# }"
}

# section_of FRAG -> nama section (basename tanpa .conf). Gagal bila
# bukan section yang bisa di-generate titian-bird.sh.
section_of() {
    local base=${1##*/}
    local sec=${base%.conf}
    case "$sec" in
        function|filter|protocol|static|bgp|ospf|direct|bfd|pipe) echo "$sec" ;;
        *) err "fragmen $base bukan section generate (function|filter|protocol|static|bgp|ospf|direct|bfd|pipe)" ;;
    esac
}

filter_defined() {
    grep -Eq "^filter $1 *[{]" "$FILTER" 2>/dev/null
}

# edit_frag FRAG PROTO DIR STMT -> ganti baris import/export di blok ipv4.
# rc: 0 diganti, 5 sudah sama (no-op), 2 protokol tak ada, 3 blok ipv4
# tak ada, 4 baris import/export tak ada, 6 protokol ganda dalam satu
# fragmen, 7 filter inline (tidak didukung).
edit_frag() {
    local frag=$1 proto=$2 dir=$3 stmt=$4 kw
    if [ "$dir" = import ]; then kw=import; else kw=export; fi
    awk -v proto="$proto" -v kw="$kw" -v stmt="$stmt" '
        BEGIN {
            pstart = "^ *protocol +[A-Za-z0-9_]+ +" proto " *[{]"
            inproto = 0; depth = 0; inipv4 = 0; ipv4base = 0
            found_proto = 0; found_ipv4 = 0; replaced = 0; already = 0
            blocks = 0; inline = 0
        }
        {
            line = $0
            if (line ~ /^ *#/) { print line; next }
            tmp = line
            o = gsub(/[{]/, "&", tmp)
            tmp = line
            c = gsub(/[}]/, "&", tmp)
            if (!inproto && line ~ pstart) {
                inproto = 1; found_proto = 1; depth = 0; blocks++
            }
            if (inproto && !inipv4 && line ~ /^ *ipv4 *[{]/) {
                inipv4 = 1; found_ipv4 = 1; ipv4base = depth
            }
            out = line
            if (inproto && inipv4 && !replaced && !already && !inline) {
                if (line ~ kw " +filter +[{]") {
                    inline = 1
                } else if (index(line, stmt) > 0) {
                    already = 1
                } else if (sub(kw " +[^;]+;", stmt, out)) {
                    replaced = 1
                }
            }
            print out
            depth = depth + o - c
            if (inipv4 && depth <= ipv4base) inipv4 = 0
            if (inproto && depth == 0) inproto = 0
        }
        END {
            if (blocks > 1) exit 6
            if (inline) exit 7
            if (already) exit 5
            if (!found_proto) exit 2
            if (!found_ipv4) exit 3
            if (!replaced) exit 4
            exit 0
        }
    ' "$frag" > "$frag.tmp"
    return $?
}

# show_frag FRAG PROTO -> cetak baris import/export blok ipv4.
# rc: 0 ok, 2/3/4/6 sama seperti edit_frag.
show_frag() {
    local frag=$1 proto=$2
    awk -v proto="$proto" '
        BEGIN {
            pstart = "^ *protocol +[A-Za-z0-9_]+ +" proto " *[{]"
            inproto = 0; depth = 0; inipv4 = 0; ipv4base = 0
            found_proto = 0; found_ipv4 = 0; found_any = 0; blocks = 0
        }
        {
            line = $0
            if (line ~ /^ *#/) next
            tmp = line
            o = gsub(/[{]/, "&", tmp)
            tmp = line
            c = gsub(/[}]/, "&", tmp)
            if (!inproto && line ~ pstart) {
                inproto = 1; found_proto = 1; depth = 0; blocks++
            }
            if (inproto && !inipv4 && line ~ /^ *ipv4 *[{]/) {
                inipv4 = 1; found_ipv4 = 1; ipv4base = depth
            }
            if (inproto && inipv4) {
                i = index(line, "import")
                if (i > 0) {
                    s = substr(line, i); j = index(s, ";")
                    if (j > 0) { print "  " substr(s, 1, j); found_any = 1 }
                }
                i = index(line, "export")
                if (i > 0) {
                    s = substr(line, i); j = index(s, ";")
                    if (j > 0) { print "  " substr(s, 1, j); found_any = 1 }
                }
            }
            depth = depth + o - c
            if (inipv4 && depth <= ipv4base) inipv4 = 0
            if (inproto && depth == 0) inproto = 0
        }
        END {
            if (blocks > 1) exit 6
            if (!found_proto) exit 2
            if (!found_ipv4) exit 3
            if (!found_any) exit 4
            exit 0
        }
    ' "$frag"
    return $?
}

# apply SECTION FRAG: check dulu, lolos baru generate; gagal check ->
# fragment dikembalikan dari backup pra-edit (.cli-bak dibuat pemanggil
# SEBELUM edit; backup di sini akan percuma karena file sudah teredit).
apply() {
    local sec=$1 frag=$2
    if ! "$BIRD_SH" check "$sec" >/tmp/titian-filter-check.out 2>&1; then
        cat /tmp/titian-filter-check.out >&2
        cp -f "$frag.cli-bak" "$frag"
        err "parse GAGAL, $frag dikembalikan (tidak ada perubahan diterapkan)"
    fi
    "$BIRD_SH" generate "$sec" || {
        echo "Warning: generate $sec failed after check pass; fragmen tetap teredit, backup pra-edit: $frag.cli-bak" >&2
        exit 33
    }
}

# edit_finish FRAG RC: mv tmp bila rc=0, hapus tmp bila bukan.
edit_finish() {
    if [ "$2" = 0 ]; then
        mv -f "$1.tmp" "$1" || err "gagal tulis $1"
    else
        rm -f "$1.tmp"
    fi
}

edit_err() {
    # $1=rc $2=frag $3=proto $4=dir
    case "$1" in
        2) err "protokol $3 tidak ditemukan di $2" ;;
        3) err "blok ipv4 tidak ditemukan di protokol $3 ($2)" ;;
        4) err "baris $4 tidak ditemukan di blok ipv4 protokol $3 (hanya baris satu baris didukung)" ;;
        6) err "protokol $3 ganda dalam $2 (rapikan dulu)" ;;
        7) err "filter inline multi-baris untuk $4 di $3 tidak didukung (edit manual)" ;;
        *) err "gagal edit $2 (rc=$1)" ;;
    esac
}

do_attach() {
    local proto=$1 dir=$2 filt=$3 frag sec stmt rc
    valid_name "$proto" || err "nama protokol tidak valid: $proto"
    valid_name "$filt" || err "nama filter tidak valid: $filt"
    case "$dir" in import|export) ;; *) err "arah tidak valid: $dir (import|export)" ;; esac
    frag=$(find_proto "$proto") || exit 33
    sec=$(section_of "$frag") || exit 33
    filter_defined "$filt" || err "filter $filt tidak didefinisikan di $FILTER (buat dulu di filter.conf)"
    cp -f "$frag" "$frag.cli-bak" || err "gagal backup $frag"
    stmt="$dir filter $filt;"
    edit_frag "$frag" "$proto" "$dir" "$stmt"; rc=$?
    edit_finish "$frag" "$rc"
    case $rc in
        5) echo "sudah ditempel: $proto $dir -> filter $filt (section $sec)"; return 0 ;;
        0) ;;
        *) edit_err "$rc" "$frag" "$proto" "$dir" ;;
    esac
    apply "$sec" "$frag" || exit 33
    echo "ditempel: $proto $dir -> filter $filt (section $sec)"
}

do_detach() {
    local proto=$1 dir=$2 frag sec stmt rc
    valid_name "$proto" || err "nama protokol tidak valid: $proto"
    case "$dir" in import|export) ;; *) err "arah tidak valid: $dir (import|export)" ;; esac
    frag=$(find_proto "$proto") || exit 33
    sec=$(section_of "$frag") || exit 33
    cp -f "$frag" "$frag.cli-bak" || err "gagal backup $frag"
    if [ "$dir" = import ]; then stmt="import all;"; else stmt="export none;"; fi
    edit_frag "$frag" "$proto" "$dir" "$stmt"; rc=$?
    edit_finish "$frag" "$rc"
    case $rc in
        5) echo "sudah default: $proto $dir -> $stmt (section $sec)"; return 0 ;;
        0) ;;
        *) edit_err "$rc" "$frag" "$proto" "$dir" ;;
    esac
    apply "$sec" "$frag" || exit 33
    echo "dilepas: $proto $dir -> $stmt (default; section $sec)"
}

do_show() {
    local proto=$1 frag sec rc
    valid_name "$proto" || err "nama protokol tidak valid: $proto"
    frag=$(find_proto "$proto") || exit 33
    sec=$(section_of "$frag") || exit 33
    echo "$proto (section $sec):"
    show_frag "$frag" "$proto"; rc=$?
    case $rc in
        0) return 0 ;;
        *) edit_err "$rc" "$frag" "$proto" "import/export" ;;
    esac
}

case "${1:-}" in
    attach) do_attach "$2" "$3" "$4" ;;
    detach) do_detach "$2" "$3" ;;
    show)   do_show "$2" ;;
    *) echo "Usage: $0 {attach <proto> <import|export> <filter>|detach <proto> <import|export>|show <proto>}" >&2; exit 2 ;;
esac
