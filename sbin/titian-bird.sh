#!/bin/sh
# TITIAN Fase 1 — generator BIRD per section.
# Urutan wajib: render -> backup config lama -> bird -p -c (cek sintaks;
# gagal = BERHENTI, tidak ada terap paksa) -> birdc configure.
# Section hidup di /opt/titian/etc/bird.d/<section>.conf; bird.conf
# dipotong per marker gaya rtcli (#-BGP-# ... #-ENDBGP-#, dst).
# Satu section ditulis ulang tanpa menyentuh section lain.
# POSIX sh.
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
err() { echo "Error: $*" >&2; exit 33; }

conf_path() {
    if [ "$OS" = "FreeBSD" ]; then
        echo "/usr/local/etc/bird.conf"
    else
        echo "/etc/bird/bird.conf"
    fi
}

bird_bin() {
    command -v bird 2>/dev/null || { [ -x /usr/sbin/bird ] && echo /usr/sbin/bird; } || \
        { [ -x /usr/local/sbin/bird ] && echo /usr/local/sbin/bird; } || echo bird
}

birdc_bin() {
    command -v birdc 2>/dev/null || { [ -x /usr/sbin/birdc ] && echo /usr/sbin/birdc; } || \
        { [ -x /usr/local/sbin/birdc ] && echo /usr/local/sbin/birdc; } || echo birdc
}

# section -> MARKER (tanpa #- pembungkus)
marker_of() {
    case "$1" in
        function) echo "FUNCTION" ;;
        filter)   echo "FILTER" ;;
        protocol) echo "PROTOCOL" ;;
        static)   echo "PROTOCOL-STATIC" ;;
        bgp)      echo "BGP" ;;
        ospf)     echo "OSPF" ;;
        direct)   echo "DIRECT" ;;
        bfd)      echo "BFD" ;;
        pipe)     echo "PIPE" ;;
        *)        err "section tidak dikenal: $1 (function|filter|protocol|static|bgp|ospf|direct|bfd|pipe)" ;;
    esac
}

render() {
    # $1=section -> cetak bird.conf baru ke stdout; gagal bila marker hilang
    local section=$1 mark sm em conf src
    mark=$(marker_of "$section")
    sm="#-${mark}-#"
    em="#-END${mark}-#"
    conf=$(conf_path)
    src="$ROOT/etc/bird.d/$section.conf"
    [ -f "$src" ] || err "sumber section tidak ada: $src"
    [ -f "$conf" ] || err "bird.conf tidak ada: $conf"
    grep -qF -- "$sm" "$conf" || err "marker $sm tidak ditemukan di $conf"
    grep -qF -- "$em" "$conf" || err "marker $em tidak ditemukan di $conf"
    awk -v sm="$sm" -v em="$em" -v src="$src" '
        $0 == sm { print; while ((getline line < src) > 0) print line; skip = 1; next }
        $0 == em { skip = 0; print; next }
        skip { next }
        { print }
    ' "$conf"
}

do_check() {
    # $1=section: render + parse saja, tanpa tulis
    local section=$1 tmp bird
    tmp=$(mktemp /tmp/titian-bird-check.XXXXXX) || err "gagal mktemp"
    render "$section" > "$tmp" || { rm -f "$tmp"; exit 33; }
    bird=$(bird_bin)
    if "$bird" -p -c "$tmp" 2>&1; then
        echo "parse OK: section $section"
        rm -f "$tmp"
        return 0
    else
        echo "parse GAGAL: section $section (tidak ada perubahan diterapkan)" >&2
        rm -f "$tmp"
        exit 33
    fi
}

do_generate() {
    # $1=section: render -> backup -> parse -> terap -> birdc configure
    local section=$1 tmp bird birdc conf bakdir ts
    tmp=$(mktemp /tmp/titian-bird-gen.XXXXXX) || err "gagal mktemp"
    render "$section" > "$tmp" || { rm -f "$tmp"; exit 33; }
    bird=$(bird_bin)
    if ! out=$("$bird" -p -c "$tmp" 2>&1); then
        echo "$out" >&2
        echo "parse GAGAL: section $section (tidak ada perubahan diterapkan)" >&2
        rm -f "$tmp"
        exit 33
    fi
    conf=$(conf_path)
    bakdir="$ROOT/etc/bird-backup"
    mkdir -p "$bakdir" || err "gagal mkdir $bakdir"
    ts=$(date +%Y%m%d-%H%M%S)
    cp -f "$conf" "$bakdir/bird.conf.$ts" || { rm -f "$tmp"; err "gagal backup $conf"; }
    cp -f "$conf" "$bakdir/bird.conf.bak"
    cat "$tmp" > "$conf" || { rm -f "$tmp"; err "gagal tulis $conf (backup: $bakdir/bird.conf.$ts)"; }
    rm -f "$tmp"
    echo "backup: $bakdir/bird.conf.$ts"
    echo "parse OK: section $section"
    birdc=$(birdc_bin)
    echo "--- birdc configure ---"
    out=$("$birdc" configure 2>&1); rc=$?
    echo "$out" | grep -v '^BIRD'
    if [ "$rc" -ne 0 ]; then
        echo "PERINGATAN: birdc configure gagal (config sudah tertulis; backup: $bakdir/bird.conf.$ts)" >&2
        exit 33
    fi
}

case "${1:-}" in
    conf-path) conf_path ;;
    check)     do_check "${2:-}" ;;
    generate)  do_generate "${2:-}" ;;
    *) echo "Usage: $0 {conf-path|check|generate} [section]" >&2; exit 2 ;;
esac
