#!/bin/sh
# TITIAN BSDRP — BIRD per-section generator + deteksi varian bird2/bird3
# + mutual exclusion bird vs FRR.
# Desain: files/klish-bird2-bird3.md (§1 deteksi, §2a-e adaptasi, §2f
# mutual exclusion). Satu image hanya berisi SATU varian bird (binari +
# rc script sama, CONFLICTS di ports tree).
#
# Urutan wajib generate: render -> validasi varian (braces `case` +
# atribut `scope`) -> backup config lama -> bird -p -c (cek sintaks;
# gagal = BERHENTI, tidak ada terap paksa) -> birdc configure.
# Section hidup di /etc/titian/bird.d/<section>.conf; bird.conf
# dipotong per marker gaya titian (#-BGP-# ... #-ENDBGP-#, dst).
# Satu section ditulis ulang tanpa menyentuh section lain.
#
# Enable/disable BIRD TIDAK langsung start/stop service: perintah
# `router bird enable` hanya mencatat niat + menandai dirty; yang
# menaikkan service adalah `commit` (titian-commit.sh), yang
# memeriksa ulang mutual exclusion di sana. Alasan: commit = tulis
# file + service langsung naik (feature-list §1-§2); enable di tengah
# sesi tanpa commit tidak boleh mengubah service yang jalan.
# POSIX sh.
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
SBIN_DIR=$(dirname "$0")
BIRD_SH="$SBIN_DIR/titian-bird.sh"
INTENT="$STATE_ROOT/netstate/routing.intent"
DIRTY=/var/run/routing.dirty
err() { echo "Error: $*" >&2; exit 33; }
warn_bird() {
    # $* = pesan. "Warning" oranye (kuning) bila stderr terminal.
    if [ -t 2 ]; then printf '%% \033[33mWarning:\033[0m %s\n' "$*" >&2
    else echo "% Warning: $*" >&2; fi
}

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

# ---------------- deteksi varian (§1) ----------------
# Urutan sumber (pertama yang berhasil dipakai):
#   1. /etc/version.build (bird_version=2|3)
#   2. bird -v (runtime truth; menang atas version.build + peringatan)
#   3. pkg info -x '^bird[23]$'
#   4. birdc show status (bila daemon jalan)
# Output: "<variant> <version>" — mis. "2 2.20.0", "3 3.4.0", atau "none"
# bila bird tidak terpasang sama sekali. Versi "unknown" bila varian
# diketahui tapi nomor versinya tidak bisa dibaca.
# Sengaja dideteksi per panggilan (bukan cache sekali saat klish start):
# murah (baca file + `bird -v`) dan tidak pernah basi bila binari
# diganti manual pasca-install.
detect_variant() {
    local vb="" bv="" bver="unknown" variant=""
    if [ -f /etc/version.build ]; then
        vb=$(sed -n 's/^bird_version=//p' /etc/version.build 2>/dev/null | head -1 | tr -d '[:space:]')
        case "$vb" in 2|3) ;; *) vb="" ;; esac
    fi
    if command -v bird >/dev/null 2>&1 || [ -x /usr/sbin/bird ] || [ -x /usr/local/sbin/bird ]; then
        bv=$("$(bird_bin)" -v 2>&1 | head -1)
        case "$bv" in
            *"BIRD version 2."*) variant=2; bver=$(printf '%s' "$bv" | sed -n 's/.*BIRD version \([0-9.]*\).*/\1/p') ;;
            *"BIRD version 3."*) variant=3; bver=$(printf '%s' "$bv" | sed -n 's/.*BIRD version \([0-9.]*\).*/\1/p') ;;
        esac
        [ -n "$bver" ] || bver="unknown"
    fi
    if [ -n "$variant" ] && [ -n "$vb" ] && [ "$variant" != "$vb" ]; then
        warn_bird "bird on disk is ${bver} but this image was built with bird${vb}"
    fi
    if [ -z "$variant" ]; then
        if [ -n "$vb" ]; then
            variant="$vb"
        elif command -v pkg >/dev/null 2>&1; then
            if pkg info -x '^bird3$' >/dev/null 2>&1; then variant=3
            elif pkg info -x '^bird2$' >/dev/null 2>&1; then variant=2; fi
        fi
        if [ -z "$variant" ] && command -v birdc >/dev/null 2>&1; then
            bv=$(birdc show status 2>/dev/null | grep -i 'BIRD version' | head -1)
            case "$bv" in
                *" 2."*) variant=2; bver=$(printf '%s' "$bv" | sed -n 's/.*BIRD version \([0-9.]*\).*/\1/p') ;;
                *" 3."*) variant=3; bver=$(printf '%s' "$bv" | sed -n 's/.*BIRD version \([0-9.]*\).*/\1/p') ;;
            esac
        fi
    fi
    if [ -z "$variant" ]; then
        echo "none"
    else
        echo "$variant ${bver:-unknown}"
    fi
}

bird_variant() { detect_variant | awk '{print $1}'; }
bird_version() { detect_variant | awk '{print $2}'; }

# ---------------- status service/proses ----------------
# Semua helper ini gagal-aman: bila sysrc/service/pgrep tidak ada
# (mis. saat diuji di Linux), hasilnya "bukan YES / tidak jalan".
sysrc_val() {
    # $1 = nama variabel rc.conf
    command -v sysrc >/dev/null 2>&1 || return 1
    sysrc -n "$1" 2>/dev/null
}

bird_enabled() {
    [ "$(sysrc_val bird_enable 2>/dev/null)" = "YES" ]
}

frr_enabled() {
    [ "$(sysrc_val frr_enable 2>/dev/null)" = "YES" ]
}

proc_pid() {
    # $1 = nama proses; cetak pid pertama atau kosong
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x "$1" 2>/dev/null | head -1
    else
        ps -ax 2>/dev/null | awk -v n="$1" '$5 == n || $NF == n {print $1; exit}'
    fi
}

bird_pid() { proc_pid bird; }
zebra_pid() { proc_pid zebra; }

bird_running() { [ -n "$(bird_pid)" ]; }
frr_running() { [ -n "$(zebra_pid)" ]; }

frr_version() {
    local v=""
    if command -v vtysh >/dev/null 2>&1; then
        v=$(vtysh --version 2>/dev/null | head -1 | sed -n 's/.* \([0-9][0-9.]*\).*/\1/p')
    fi
    if [ -z "$v" ] && command -v pkg >/dev/null 2>&1; then
        v=$(pkg info -x '^frr[0-9]*$' 2>/dev/null | head -1 | sed -n 's/^frr[0-9]*-\([0-9][0-9.]*\).*/\1/p')
    fi
    printf '%s' "${v:-unknown}"
}

intent_val() {
    # $1 = bird|frr -> yes|no|unset
    [ -f "$INTENT" ] || { echo "unset"; return 0; }
    sed -n "s/^$1 //p" "$INTENT" 2>/dev/null | head -1
    [ -n "$(sed -n "s/^$1 //p" "$INTENT" 2>/dev/null | head -1)" ] || echo "unset"
}

set_intent() {
    # $1 = bird|frr, $2 = yes|no
    mkdir -p "$(dirname "$INTENT")" 2>/dev/null
    touch "$INTENT" 2>/dev/null
    _tmp="$INTENT.tmp.$$"
    grep -v "^$1 " "$INTENT" > "$_tmp" 2>/dev/null || true
    printf '%s %s\n' "$1" "$2" >> "$_tmp"
    mv "$_tmp" "$INTENT" || err "gagal tulis $INTENT"
    touch "$DIRTY" 2>/dev/null || true
}

# ---------------- mutual exclusion (§2f) ----------------
# check-exclusion <bird|frr|commit>: gagal (exit 33) + pesan jelas bila
# routing daemon lawan aktif — dicek dari TIGA sumber: niat di rc.conf
# (sysrc), status service, dan proses yang jalan (bird/zebra).
check_exclusion() {
    local want=$1 zpid bpid bver variant
    variant=$(bird_variant); bver=$(bird_version); zpid=$(zebra_pid); bpid=$(bird_pid)
    case "$want" in
        bird)
            if frr_enabled || frr_running || [ "$(intent_val frr)" = "yes" ]; then
                [ -n "$zpid" ] && warn_bird "FRR is currently running (zebra pid $zpid, frr_enable=$(sysrc_val frr_enable 2>/dev/null || echo NO))"
                [ -z "$zpid" ] && warn_bird "FRR is enabled (frr_enable=$(sysrc_val frr_enable 2>/dev/null || echo NO))"
                echo "% Bird and FRR cannot run at the same time." >&2
                exit 33
            fi
            ;;
        frr)
            if bird_enabled || bird_running || [ "$(intent_val bird)" = "yes" ]; then
                if [ "$variant" = "none" ]; then
                    warn_bird "BIRD is enabled/running (bird_enable=$(sysrc_val bird_enable 2>/dev/null || echo NO))"
                else
                    warn_bird "BIRD $bver is enabled/running (bird${variant}, bird_enable=$(sysrc_val bird_enable 2>/dev/null || echo NO)${bpid:+, pid $bpid})"
                fi
                echo "% Bird and FRR cannot run at the same time." >&2
                exit 33
            fi
            ;;
        commit)
            # Dua arah: niat bird + frr lawan hidup, atau sebaliknya.
            if [ "$(intent_val bird)" = "yes" ] && ( frr_enabled || frr_running ); then
                echo "% Error: commit blocked — FRR is running. Disable FRR first:" >&2
                echo "%   no router frr enable" >&2
                echo "%   commit" >&2
                exit 33
            fi
            if [ "$(intent_val frr)" = "yes" ] && ( bird_enabled || bird_running ); then
                if [ "$variant" = "none" ]; then
                    echo "% Error: commit blocked — BIRD is running (bird_enable=$(sysrc_val bird_enable 2>/dev/null || echo NO))." >&2
                else
                    echo "% Error: commit blocked — BIRD $bver is running (bird_enable=$(sysrc_val bird_enable 2>/dev/null || echo NO))." >&2
                fi
                echo "% Disable BIRD first:" >&2
                echo "%   no router bird enable" >&2
                echo "%   commit" >&2
                exit 33
            fi
            # Konflik niat-vs-niat (kedua enable, belum ada yang jalan).
            if [ "$(intent_val bird)" = "yes" ] && [ "$(intent_val frr)" = "yes" ]; then
                echo "% Error: commit blocked — both BIRD and FRR are enabled. Disable one first." >&2
                exit 33
            fi
            ;;
        *) err "check-exclusion butuh: bird|frr|commit" ;;
    esac
    return 0
}

# ---------------- validasi varian (§2a, §2d) ----------------
# validate-config <file>: tolak (exit 33, tunjuk baris) bila:
#   - varian bird3 + config mengandung atribut route `scope` (dihapus di 3.1)
#   - varian bird3 + cabang `case` multi-command TANPA braces
#   - varian bird2 + `case` tanpa braces: hanya peringatan (diterima).
# Heuristik satu baris: cabang `N:` / `else:` yang isi sesudah `:` tidak
# mengandung `{` dan mengandung >= 2 pernyataan (`;`) = multi-command.
# Cabang multi-baris tanpa braces TIDAK terdeteksi heuristik ini — tetap
# ditangkap `bird -p` bila sintaksnya salah di bird3.
validate_config() {
    local file=$1 variant
    variant=$(bird_variant)
    [ "$variant" = "none" ] && return 0
    awk -v variant="$variant" '
        { line=$0; sub(/#.*/, "", line) }
        line ~ /(^|[^A-Za-z0-9_])scope([^A-Za-z0-9_]|$)/ {
            if (variant == "3") {
                printf "%% Error: route attribute \x27scope\x27 was removed in BIRD 3; use a custom attribute instead (line %d)\n", NR > "/dev/stderr"
                bad=1
            }
        }
        line ~ /^[[:space:]]*([0-9]+|else):/ {
            rest=line; sub(/^[^:]*:/, "", rest)
            if (rest !~ /\{/) {
                n=gsub(/;/, ";", rest)
                if (n >= 2) {
                    if (variant == "3") {
                        printf "%% Error: bird3 requires braces around multi-command case branch (line %d)\n", NR > "/dev/stderr"
                        bad=1
                    } else {
                        printf "%% Warning: case branch without braces (line %d) — braces recommended for BIRD 3 compatibility\n", NR > "/dev/stderr"
                    }
                }
            }
        }
        END { exit bad ? 33 : 0 }
    ' "$file" || exit 33
    return 0
}

# ---------------- generator (asli titian-bird.sh + validasi) ----------------
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
    src="$STATE_ROOT/bird.d/$section.conf"
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
    # $1=section: render + validasi varian + parse saja, tanpa tulis
    local section=$1 tmp bird
    tmp=$(mktemp /tmp/titian-bird-check.XXXXXX) || err "gagal mktemp"
    render "$section" > "$tmp" || { rm -f "$tmp"; exit 33; }
    validate_config "$tmp" || { rm -f "$tmp"; exit 33; }
    bird=$(bird_bin)
    if "$bird" -p -c "$tmp" 2>&1; then
        echo "parse OK: section $section"
        rm -f "$tmp"
        return 0
    else
        echo "parse Failed: section $section (no  perubahan diterapkan)" >&2
        rm -f "$tmp"
        exit 33
    fi
}

do_generate() {
    # $1=section: render -> validasi varian -> backup -> parse -> terap -> birdc configure
    local section=$1 tmp bird birdc conf bakdir ts
    tmp=$(mktemp /tmp/titian-bird-gen.XXXXXX) || err "gagal mktemp"
    render "$section" > "$tmp" || { rm -f "$tmp"; exit 33; }
    validate_config "$tmp" || { rm -f "$tmp"; exit 33; }
    bird=$(bird_bin)
    if ! out=$("$bird" -p -c "$tmp" 2>&1); then
        echo "$out" >&2
        echo "parse Failed: section $section (no  perubahan diterapkan)" >&2
        rm -f "$tmp"
        exit 33
    fi
    conf=$(conf_path)
    bakdir="$STATE_ROOT/bird-backup"
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
        echo "Warning: birdc configure failed (config already tertulis; backup: $bakdir/bird.conf.$ts)" >&2
        exit 33
    fi
}

# ---------------- perintah varian-spesifik ----------------
do_reload_filters() {
    # §2b: reload filter saja — bird2 `birdc reload`, bird3 `birdc reload filters`
    local variant birdc out rc
    variant=$(bird_variant)
    [ "$variant" = "none" ] && err "no BIRD installed in this image (build with BIRD_VERSION=2 or 3)"
    birdc=$(birdc_bin)
    if [ "$variant" = "3" ]; then
        out=$("$birdc" reload filters 2>&1); rc=$?
    else
        out=$("$birdc" reload 2>&1); rc=$?
    fi
    echo "$out" | grep -v '^BIRD'
    [ "$rc" -ne 0 ] && exit 33
    return 0
}

do_set_threads() {
    # §2c: `threads` hanya bird3. Generator tidak pernah menulisnya
    # kecuali user mengaturnya eksplisit di sini.
    local n=$1 variant bver conf
    case "$n" in ''|*[!0-9]*) err "threads harus bilangan 1-32: $n" ;; esac
    [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le 32 ] 2>/dev/null || err "threads harus bilangan 1-32: $n"
    variant=$(bird_variant); bver=$(bird_version)
    [ "$variant" = "none" ] && err "no BIRD installed in this image (build with BIRD_VERSION=2 or 3)"
    [ "$variant" = "3" ] || err "'threads' is a BIRD 3 option; this image runs BIRD $bver"
    conf=$(conf_path)
    [ -f "$conf" ] || err "bird.conf tidak ada: $conf"
    _tmp=$(mktemp /tmp/titian-bird-threads.XXXXXX) || err "gagal mktemp"
    if grep -q '^threads [0-9][0-9]*;' "$conf"; then
        sed "s/^threads [0-9][0-9]*;/threads $n;/" "$conf" > "$_tmp"
    else
        # sisipkan sesudah baris pertama (opsi global, paling atas)
        awk -v n="$n" 'NR==1 {print; print "threads " n ";"; next} {print}' "$conf" > "$_tmp"
    fi
    validate_config "$_tmp" || { rm -f "$_tmp"; exit 33; }
    if ! out=$("$(bird_bin)" -p -c "$_tmp" 2>&1); then
        echo "$out" >&2; rm -f "$_tmp"
        err "parse GAGAL: threads $n (bird.conf tidak diubah)"
    fi
    cp -f "$conf" "$STATE_ROOT/bird-backup/bird.conf.threads-bak" 2>/dev/null || true
    cat "$_tmp" > "$conf" || { rm -f "$_tmp"; err "gagal tulis $conf"; }
    rm -f "$_tmp"
    echo "threads $n ditulis to $conf"
    out=$("$(birdc_bin)" configure 2>&1); rc=$?
    echo "$out" | grep -v '^BIRD'
    [ "$rc" -ne 0 ] && err "birdc configure gagal sesudah threads $n"
}

do_bird_enable() {
    local variant
    variant=$(bird_variant)
    [ "$variant" = "none" ] && err "no BIRD installed in this image (build with BIRD_VERSION=2 or 3)"
    check_exclusion bird
    set_intent bird yes
    echo "router bird enable (pending commit — service bird naik saat commit)"
}

do_bird_disable() {
    set_intent bird no
    echo "router bird disable (pending commit — service bird berhenti saat commit)"
}

# ---------------- show routing / show version (§2e) ----------------
do_show_routing() {
    local variant bver bpid ben brn fver fen frn
    variant=$(bird_variant); bver=$(bird_version)
    bpid=$(bird_pid); ben=no; brn="not running"
    bird_enabled && ben="enabled"
    bird_running && brn="running, pid $bpid"
    if [ "$variant" = "none" ]; then
        echo "Routing daemon: BIRD not installed (build with BIRD_VERSION=2 or 3)"
    else
        echo "Routing daemon: BIRD $bver (bird${variant}, $ben, $brn)"
    fi
    fver=$(frr_version); fen=no; frn="not running"
    frr_enabled && fen="enabled"
    frr_running && frn="running, pid $(zebra_pid)"
    if [ "$fver" = "unknown" ] && ! frr_enabled && ! frr_running; then
        echo "FRR: disabled, not running"
    else
        echo "FRR: $fver ($fen, $frn)"
    fi
}

do_show_version() {
    local variant bver bsdrp build fver frn
    variant=$(bird_variant); bver=$(bird_version)
    bsdrp="BSDRP"; build=""
    if [ -f /etc/version.build ]; then
        _v=$(grep -E '^(version|bsdrp_version)=' /etc/version.build 2>/dev/null | head -1 | cut -d= -f2-)
        _b=$(grep -E '^(build|version\.build|n)=' /etc/version.build 2>/dev/null | head -1 | cut -d= -f2-)
        [ -z "$_b" ] && _b=$(sed -n 's/^.*\(n[0-9]\{6,\}\).*$/\1/p' /etc/version.build 2>/dev/null | head -1)
        [ -n "$_v" ] && bsdrp="BSDRP $_v"
        [ -n "$_b" ] && build=" ($_b)"
    fi
    fver=$(frr_version); frn="not running"
    frr_running && frn="running, pid $(zebra_pid)"
    if [ "$variant" = "none" ]; then
        echo "$bsdrp$build, bird_version=none (BIRD not installed), FRR $fver ($frn)"
    else
        echo "$bsdrp$build, bird_version=$variant (BIRD $bver), FRR $fver ($frn)"
    fi
}

case "${1:-}" in
    conf-path) conf_path ;;
    detect) detect_variant ;;
    check)     do_check "${2:-}" ;;
    validate-config) validate_config "${2:-}" ;;
    generate)  do_generate "${2:-}" ;;
    reload-filters) do_reload_filters ;;
    set-threads) do_set_threads "${2:-}" ;;
    bird-enable) do_bird_enable ;;
    bird-disable) do_bird_disable ;;
    check-exclusion) check_exclusion "${2:-}" ;;
    show-routing) do_show_routing ;;
    show-version) do_show_version ;;
    *) echo "Usage: $0 {conf-path|detect|check|generate|reload-filters|set-threads N|bird-enable|bird-disable|check-exclusion bird|frr|commit|show-routing|show-version} [section]" >&2; exit 2 ;;
esac
