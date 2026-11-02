#!/bin/sh
# TITIAN — kelola community BGP lewat CLI (bird-view).
# Pola: edit bird.d/filter.conf -> generate check filter (parse saja) ->
# lolos baru generate filter (backup + birdc configure). Gagal parse =
# file dikembalikan dari backup, tidak ada perubahan diterapkan.
# Bentuk community yang diterima:
#   AA:NN            standard, mis. 64512:300
#   no-export | no-advertise | no-peer | blackhole   (well-known)
#   rt:AA:NN | ro:AA:NN      extended community
#   large:AA:X:NN            large community
# Aksi import-match: reject | localpref:N | med:N
# POSIX sh. Dipanggil dari bird-view sebagai ${RT_SBIN}/titian-comm.sh.
DIR=$(dirname "$0")
ROOT=$(dirname "$DIR")
FILTER="$ROOT/etc/bird.d/filter.conf"
BIRD_SH="$DIR/titian-bird.sh"
err() { echo "Error: $*" >&2; exit 33; }
[ -f "$FILTER" ] || err "filter.conf tidak ada: $FILTER"
[ -x "$BIRD_SH" ] || err "titian-bird.sh tidak ada: $BIRD_SH"

# norm COMM -> "TYPE|EXPR|ADDLINE-EXPR"
#   TYPE: std|ext|large ; EXPR: (AA, NN) | (rt, AA, NN) | (AA, X, NN)
norm() {
    case "$1" in
        no-export)    echo "std|(65535, 65281)" ;;
        no-advertise) echo "std|(65535, 65282)" ;;
        no-peer)      echo "std|(65535, 65283)" ;;
        blackhole)    echo "std|(65535, 666)" ;;
        rt:*|ro:*)
            kind=${1%%:*}; rest=${1#*:}
            aa=${rest%%:*}; nn=${rest#*:}
            case "$aa" in ''|*[!0-9]*) err "community tidak valid: $1" ;; esac
            case "$nn" in ''|*[!0-9]*) err "community tidak valid: $1" ;; esac
            echo "ext|($kind, $aa, $nn)" ;;
        large:*)
            rest=${1#large:}
            aa=${rest%%:*}; rest2=${rest#*:}
            x=${rest2%%:*}; nn=${rest2#*:}
            case "$aa" in ''|*[!0-9]*) err "community tidak valid: $1" ;; esac
            case "$x" in ''|*[!0-9]*) err "community tidak valid: $1" ;; esac
            case "$nn" in ''|*[!0-9]*) err "community tidak valid: $1" ;; esac
            echo "large|($aa, $x, $nn)" ;;
        *:*)
            aa=${1%%:*}; nn=${1#*:}
            case "$aa" in ''|*[!0-9]*) err "community tidak valid: $1" ;; esac
            case "$nn" in ''|*[!0-9]*) err "community tidak valid: $1" ;; esac
            [ "$aa" -le 65535 ] 2>/dev/null || err "AS di luar 0-65535: $1"
            [ "$nn" -le 65535 ] 2>/dev/null || err "NN di luar 0-65535: $1"
            echo "std|($aa, $nn)" ;;
        *) err "community tidak valid: $1 (AA:NN | no-export | no-advertise | no-peer | blackhole | rt:AA:NN | large:AA:X:NN)" ;;
    esac
}

# norm_action ACT -> filter statement (tanpa indent, tanpa ;)
norm_action() {
    case "$1" in
        reject) echo "reject" ;;
        localpref:*)
            n=${1#localpref:}
            case "$n" in ''|*[!0-9]*) err "aksi tidak valid: $1" ;; esac
            echo "bgp_local_pref = $n" ;;
        med:*)
            n=${1#med:}
            case "$n" in ''|*[!0-9]*) err "aksi tidak valid: $1" ;; esac
            echo "bgp_med = $n" ;;
        *) err "aksi tidak valid: $1 (reject | localpref:N | med:N)" ;;
    esac
}

# apply: check dulu, lolos baru generate; gagal -> restore backup.
apply() {
    cp -f "$FILTER" "$FILTER.cli-bak" || err "gagal backup $FILTER"
    if ! "$BIRD_SH" check filter >/tmp/titian-comm-check.out 2>&1; then
        cat /tmp/titian-comm-check.out >&2
        cp -f "$FILTER.cli-bak" "$FILTER"
        err "parse GAGAL, filter.conf dikembalikan (tidak ada perubahan diterapkan)"
    fi
    "$BIRD_SH" generate filter || {
        echo "PERINGATAN: generate filter gagal setelah check lolos; backup filter: $FILTER.cli-bak" >&2
        exit 33
    }
}

list_add() {
    name=$1; spec=$(norm "$2"); expr=${spec#*|}
    case "$name" in ''|*[!A-Za-z0-9_]*) err "nama list tidak valid: $name (huruf/angka/_)" ;; esac
    line="define $name = $expr;"
    if grep -qF -- "$line" "$FILTER"; then echo "sudah ada: $line"; return 0; fi
    if grep -q "^define $name " "$FILTER"; then err "nama $name sudah didefinisikan dgn nilai lain (hapus dulu)"; fi
    echo "$line" >> "$FILTER" || err "gagal tulis $FILTER"
    apply
}

list_del() {
    name=$1
    case "$name" in ''|*[!A-Za-z0-9_]*) err "nama list tidak valid: $name" ;; esac
    grep -q "^define $name " "$FILTER" || { echo "tidak ada: define $name"; return 0; }
    grep -v "^define $name " "$FILTER" > "$FILTER.tmp" || err "gagal edit $FILTER"
    mv "$FILTER.tmp" "$FILTER" || err "gagal tulis $FILTER"
    apply
}

list_show() {
    grep '^define ' "$FILTER" || echo "(tidak ada community list)"
}

# export-add COMM: sisipkan add-line ke cabang static di bgp_export_attr.
export_add() {
    spec=$(norm "$1"); type=${spec%%|*}; expr=${spec#*|}
    case "$type" in
        std)   add="        bgp_community.add($expr);" ;;
        ext)   add="        bgp_ext_community.add($expr);" ;;
        large) add="        bgp_large_community.add($expr);" ;;
    esac
    awk -v add="$add" '
        /^filter bgp_export_attr \{/ { infilter = 1 }
        infilter && /if source = RTS_STATIC then \{/ { instatic = 1 }
        infilter && instatic && $0 == add { found = 1 }
        infilter && instatic && !inserted && /^ *accept;/ { print add; inserted = 1 }
        { print }
        END {
            if (found) exit 2
            if (!infilter || !instatic || !inserted) exit 3
        }
    ' "$FILTER" > "$FILTER.tmp"; rc=$?
    case $rc in
        2) rm -f "$FILTER.tmp"; echo "sudah ada: $add"; return 0 ;;
        3) rm -f "$FILTER.tmp"; err "filter bgp_export_attr / cabang RTS_STATIC tidak ditemukan di $FILTER" ;;
        0) mv "$FILTER.tmp" "$FILTER" || err "gagal tulis $FILTER"; apply ;;
        *) rm -f "$FILTER.tmp"; err "gagal edit $FILTER" ;;
    esac
}

export_del() {
    spec=$(norm "$1"); type=${spec%%|*}; expr=${spec#*|}
    case "$type" in
        std)   add="        bgp_community.add($expr);" ;;
        ext)   add="        bgp_ext_community.add($expr);" ;;
        large) add="        bgp_large_community.add($expr);" ;;
    esac
    awk -v add="$add" '
        /^filter bgp_export_attr \{/ { infilter = 1 }
        infilter && /if source = RTS_STATIC then \{/ { instatic = 1 }
        infilter && instatic && $0 == add { skipped = 1; next }
        { print }
        END { if (!skipped) exit 2 }
    ' "$FILTER" > "$FILTER.tmp"; rc=$?
    case $rc in
        2) rm -f "$FILTER.tmp"; echo "tidak ada: $add"; return 0 ;;
        0) mv "$FILTER.tmp" "$FILTER" || err "gagal tulis $FILTER"; apply ;;
        *) rm -f "$FILTER.tmp"; err "gagal edit $FILTER" ;;
    esac
}

export_show() {
    sed -n '/^filter bgp_export_attr {/,/^}/p' "$FILTER" || echo "(filter bgp_export_attr tidak ada)"
}

# import-add COMM ACTION: hapus match lama utk community tsb, sisip baru di atas.
import_add() {
    spec=$(norm "$1"); type=${spec%%|*}; expr=${spec#*|}
    act=$(norm_action "$2")
    case "$type" in
        std)   m="    if $expr ~ bgp_community then $act;" ;;
        ext)   m="    if $expr ~ bgp_ext_community then $act;" ;;
        large) m="    if $expr ~ bgp_large_community then $act;" ;;
    esac
    # pola match lama: baris "if EXPR ~ bgp_*_community then ..."
    # PORTABEL: jangan escape \( \) (awk -v memproses backslash berbeda di
    # gawk vs BSD awk sehingga match gagal di FreeBSD); pakai kelas [(] [)].
    pat="^ *if $(printf '%s' "$expr" | sed 's/(/[(]/g; s/)/[)]/g') ~ bgp_"
    awk -v m="$m" -v pat="$pat" '
        /^filter bgp_import_comm \{/ { inimport = 1; print; print m; inserted = 1; next }
        inimport && $0 ~ pat { next }
        { print }
        END { if (!inserted) exit 3 }
    ' "$FILTER" > "$FILTER.tmp"; rc=$?
    case $rc in
        3) rm -f "$FILTER.tmp"; err "filter bgp_import_comm tidak ditemukan di $FILTER" ;;
        0) mv "$FILTER.tmp" "$FILTER" || err "gagal tulis $FILTER"; apply ;;
        *) rm -f "$FILTER.tmp"; err "gagal edit $FILTER" ;;
    esac
}

import_del() {
    spec=$(norm "$1"); type=${spec%%|*}; expr=${spec#*|}
    pat="^ *if $(printf '%s' "$expr" | sed 's/(/[(]/g; s/)/[)]/g') ~ bgp_"
    awk -v pat="$pat" '
        /^filter bgp_import_comm \{/ { inimport = 1 }
        inimport && $0 ~ pat { skipped = 1; next }
        { print }
        END { if (!skipped) exit 2 }
    ' "$FILTER" > "$FILTER.tmp"; rc=$?
    case $rc in
        2) rm -f "$FILTER.tmp"; echo "tidak ada match untuk $expr"; return 0 ;;
        0) mv "$FILTER.tmp" "$FILTER" || err "gagal tulis $FILTER"; apply ;;
        *) rm -f "$FILTER.tmp"; err "gagal edit $FILTER" ;;
    esac
}

import_show() {
    sed -n '/^filter bgp_import_comm {/,/^}/p' "$FILTER" || echo "(filter bgp_import_comm tidak ada)"
}

case "${1:-}" in
    list-add)     list_add "$2" "$3" ;;
    list-del)     list_del "$2" ;;
    list-show)    list_show ;;
    export-add)   export_add "$2" ;;
    export-del)   export_del "$2" ;;
    export-show)  export_show ;;
    import-add)   import_add "$2" "$3" ;;
    import-del)   import_del "$2" ;;
    import-show)  import_show ;;
    *) echo "Usage: $0 {list-add|list-del|list-show|export-add|export-del|export-show|import-add|import-del|import-show} ..." >&2; exit 2 ;;
esac
