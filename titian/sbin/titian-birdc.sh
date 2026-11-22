#!/bin/sh
# TITIAN B7 — perintah birdc sebagai perintah show/operasional klish.
# Program BIRD (perintah user 16 Nov 2026 07:38): Bab 4 birdc 4.1/4.2/4.3
# (BIRD-READ-ch6-other-birdc.md + BIRD-READ-ch6-bgp.md Tabel 5 No. 130-146)
# + BC1-BC18 (BIRD-COVERAGE.md).
#
# Aturan:
#   - Perintah show/operasional di sini HANYA memanggil birdc (baca saja
#     atau aksi runtime); TIDAK PERNAH menulis file intent/section apa pun.
#     Regression anchor BGP (BIRD-ANCHOR-*.conf) tidak boleh berubah.
#   - birdc tidak ada -> show: pesan skip rc=0 (bukan error); perintah yang
#     mengubah state (configure/enable/disable/restart/reload/debug/down/
#     eval/echo/dump/mrt/timeformat sesi): rc=33 + pesan jelas.
#   - birdc ada tapi daemon tidak jalan -> show: pesan soft rc=0 (pola
#     titian-bfd.sh / titian-ospf.sh); state: rc=33.
#   - `show bgp` ASLI TIDAK ADA di BIRD 2.16.1 (temuan B0/B1). `show bgp
#     summary` di sini adalah KOMPOSISI klish: `birdc show protocols all
#     bgp_<IP>` + `birdc show route protocol bgp_<IP> count` per neighbor
#     dari intent bgp.conf. Jangan klaim sebagai perintah birdc asli.
#   - `down` / `graceful-restart` IREVERSIBEL: perintah telanjang hanya
#     mencetak instruksi konfirmasi (rc=0, tanpa aksi); eksekusi hanya
#     lewat `down confirm` / `graceful-restart confirm`.
# POSIX sh.
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
BGP_CONF="$STATE_ROOT/bgp.conf"
BIRDC_CONF="$STATE_ROOT/birdc.conf"
PROG="titian-birdc"
# Pager global: output show >1 layar lewat less (titian-page.sh).
# Prologue dipanggil SESUDAH setup warna/TTY bila ada, SEBELUM output pertama.
SBIN_DIR=$(dirname "$0")
. "$SBIN_DIR/titian-page.sh"
# Hanya subcommand baca yang dipager: set/generate/commit TIDAK —
# output-nya harus tetap streaming/langsung, bukan tertahan sampai EXIT.
case "${1:-}" in show-*|birdc-passthrough) titian_page_begin ;; esac

err() { echo "Error($PROG): $*" >&2; exit 33; }

birdc_bin() {
    command -v birdc 2>/dev/null || { [ -x /usr/sbin/birdc ] && echo /usr/sbin/birdc; } || \
        { [ -x /usr/local/sbin/birdc ] && echo /usr/local/sbin/birdc; } || echo birdc
}

# birdc_sock — cetak "-s <path>" bila socket utama dikonfigurasi via klish
# (BC8, B13; intent $STATE_ROOT/birdc.conf, baris `socket <PATH>`), kosong
# bila default. Dipakai SEMUA pemanggilan birdc di file ini (+ titian-bird.sh)
# agar satu pengaturan socket berlaku di seluruh Titian.
birdc_sock() {
    _s=$(grep '^socket ' "$BIRDC_CONF" 2>/dev/null | head -1 | cut -d' ' -f2-)
    [ -n "$_s" ] && printf '%s' "-s $_s"
}

klish_unescape() {
    printf '%s' "$1" | sed -e 's/\\>/>/g' -e 's/\\</</g' -e 's/\\(/(/g' -e 's/\\)/)/g' -e 's/\\&/\&/g' -e 's/\\|/|/g' -e 's/\\;/;/g' -e 's/\\\\/\\/g'
}

have_birdc() {
    _b=$(birdc_bin)
    case "$_b" in /*) [ -x "$_b" ] ;; *) command -v "$_b" >/dev/null 2>&1 ;; esac
}

# run_ro <label> <birdc-args...> — perintah read-only (show).
# birdc tidak ada -> skip rc=0. birdc gagal -> catatan rc=0; bedakan
# daemon down vs perintah gagal (mis. protokol OSPF/RIP tidak ada):
# bila `birdc show status` jalan, daemon UP dan gagalnya ada di perintah.
run_ro() {
    _label=$1; shift
    if ! have_birdc; then
        echo "(birdc tidak ada — $_label dilewati; BIRD belum terpasang di image ini)"
        return 0
    fi
    _birdc=$(birdc_bin)
    if _out=$("$_birdc" $(birdc_sock) "$@" 2>&1); then
        printf '%s\n' "$_out" | grep -v '^BIRD'
    elif "$_birdc" $(birdc_sock) show status >/dev/null 2>&1; then
        # B13: cetak dulu jawaban asli birdc (mis. "No import table in
        # channel ..." — BIRD memberi rc=1 untuk channel tanpa import/
        # export table; itu JAWABAN, bukan perintah salah), baru diagnosa.
        printf '%s\n' "$_out" | grep -v '^BIRD'
        echo "(birdc $_label gagal — daemon BIRD jalan; kemungkinan protokol tidak ada / argumen tidak valid: birdc $* gagal)"
    else
        echo "(BIRD tidak jalan — $_label gagal: birdc $* gagal)"
    fi
    return 0
}

# run_state <label> <birdc-args...> — perintah yang mengubah state.
# birdc tidak ada -> rc=33. birdc gagal -> rc=33 + output apa adanya.
run_state() {
    _label=$1; shift
    if ! have_birdc; then
        err "birdc tidak ada — $_label tidak bisa jalan (BIRD belum terpasang di image ini)"
    fi
    _birdc=$(birdc_bin)
    if _out=$("$_birdc" $(birdc_sock) "$@" 2>&1); then
        printf '%s\n' "$_out" | grep -v '^BIRD'
        return 0
    fi
    printf '%s\n' "$_out" | grep -v '^BIRD'
    err "$_label gagal (birdc $* rc != 0)"
}

# run_state_one <label> <perintah> — seperti run_state, tapi seluruh perintah
# diteruskan sebagai SATU argumen ke birdc (B13). WAJIB untuk perintah yang
# mengandung string dikutip (mis. `configure "/tmp/file.conf"`) — bentuk
# multi-argumen GAGAL di birdc 2.20.0 ("syntax error, unexpected '/'",
# terverifikasi live B13); bentuk satu-argumen jalan untuk semua perintah.
run_state_one() {
    _label=$1; _cmd=$2
    if ! have_birdc; then
        err "birdc tidak ada — $_label tidak bisa jalan (BIRD belum terpasang di image ini)"
    fi
    _birdc=$(birdc_bin)
    if _out=$("$_birdc" $(birdc_sock) "$_cmd" 2>&1); then
        printf '%s\n' "$_out" | grep -v '^BIRD'
        return 0
    fi
    printf '%s\n' "$_out" | grep -v '^BIRD'
    err "$_label gagal (birdc \"$_cmd\" rc != 0)"
}

# --- validator (semua gagal -> rc 33 via err) ---
valid_proto_name() { # <nilai> <label> — nama/simbol BIRD [A-Za-z0-9_]
    case "$1" in ''|*[!A-Za-z0-9_]*) err "$2 harus nama BIRD [A-Za-z0-9_]: $1" ;; esac
}
valid_filter_name() { # <nilai> <label> — nama filter Titian boleh '-' (mis. F-RB3011-IN)
    case "$1" in ''|*[!A-Za-z0-9_-]*) err "$2 harus nama filter [A-Za-z0-9_-]: $1" ;; esac
}
valid_proto_pattern() { # <nilai> <label> — nama atau pola birdc (* ? . -)
    case "$1" in ''|*[!A-Za-z0-9_.*?-]*) err "$2 harus nama/pola protokol [A-Za-z0-9_.*?-]: $1" ;; esac
}
valid_iface() { # <nilai> <label> — nama interface OS
    case "$1" in ''|*[!A-Za-z0-9_.-]*) err "$2 harus nama interface [A-Za-z0-9_.-]: $1" ;; esac
}
valid_nospace() { # <nilai> <label>
    case "$1" in ''|*[[:space:]]*) err "$2 tidak boleh kosong/mengandung spasi: $1" ;; esac
}
valid_prefix() { # <nilai> <label> — IP atau prefix v4/v6
    case "$1" in
        *:*)
            case "$1" in *[!0-9A-Fa-f:/.]*) err "$2 harus prefix IPv6: $1" ;; esac
            _pl=${1##*/}; case "$1" in */*) [ "$_pl" -le 128 ] 2>/dev/null || err "$2 panjang prefix IPv6 harus 0..128: $1" ;; esac
            ;;
        *.*)
            printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' || err "$2 harus IP/prefix IPv4: $1"
            _pl=${1##*/}; case "$1" in */*) [ "$_pl" -le 32 ] 2>/dev/null || err "$2 panjang prefix IPv4 harus 0..32: $1" ;; esac
            printf '%s' "${1%%/*}" | awk -F. '{ for (i=1;i<=NF;i++) if ($i>255) exit 1 }' || err "$2 oktet IPv4 harus 0..255: $1"
            ;;
        *) err "$2 harus IP atau prefix (IPv4/IPv6): $1" ;;
    esac
}
valid_class_list() { # <csv> <daftar-diizinkan-csv> <label>
    _rest="$1"
    while [ -n "$_rest" ]; do
        case "$_rest" in *,*) _one=${_rest%%,*}; _rest=${_rest#*,} ;; *) _one="$_rest"; _rest="" ;; esac
        case ",$2," in *",$_one,"*) ;; *) err "$3 kelas tidak dikenal: $_one (boleh: $2)" ;; esac
    done
}
valid_debug_spec() { # <SPEC> <label> — all|off|daftar-koma kelas protokol
    case "$1" in all|off) return 0 ;; esac
    valid_class_list "$1" "states,routes,filters,interfaces,events,packets" "$2"
}
debug_spec_to_bird() { # <SPEC> -> "all" | "off" | "{ a, b }"
    case "$1" in all|off) printf '%s' "$1"; return 0 ;; esac
    printf '{ %s }' "$(printf '%s' "$1" | sed 's/,/, /g')"
}
valid_echo_spec() { # <SPEC> <label> — all|off|daftar-koma kelas log
    case "$1" in all|off) return 0 ;; esac
    valid_class_list "$1" "info,warning,error,fatal,debug,trace,remote,auth,bug" "$2"
}
valid_timeformat() { # <FORMAT> <label> — shorthand BIRD atau strftime '%'
    case "$1" in
        'iso long'|'iso long ms'|'iso long us'|'iso short'|'iso short ms'|'iso short us') return 0 ;;
    esac
    case "$1" in *%*) return 0 ;; esac
    err "$2 harus shorthand (iso long|iso long ms|iso long us|iso short|iso short ms|iso short us) atau format strftime mengandung '%': $1"
}
valid_no_semi() { # <nilai> <label> — tolak pemisah perintah birdc
    case "$1" in '') err "$2 tidak boleh kosong" ;; *';'*) err "$2 tidak boleh mengandung ';': $1" ;; esac
    case "$1" in *'
'*) err "$2 tidak boleh mengandung baris baru" ;; esac
}
valid_dump_file() { # <path> <label> — absolut, belum ada (birdc menolak file yang sudah ada)
    case "$1" in /*) ;; *) err "$2 harus path absolut: $1" ;; esac
    case "$1" in *' '*|*';'*|*\"*|*'`'*|*'$'*) err "$2 tidak boleh mengandung spasi/';'/kutip/'\$': $1" ;; esac
    [ -e "$1" ] && err "$2 sudah ada: $1 (birdc dump menolak file yang sudah ada — hapus/pindah dulu)"
}

# --- show (read-only) ---
cmd_show_status() { run_ro "show status" show status; }
cmd_show_protocols() {
    [ -n "${1:-}" ] && valid_proto_name "$1" "show protocols <nama>"
    if [ -n "${1:-}" ]; then run_ro "show protocols $1" show protocols "$1";
    else run_ro "show protocols" show protocols; fi
}
cmd_show_protocols_all() {
    [ -n "${1:-}" ] && valid_proto_name "$1" "show protocols all <nama>"
    if [ -n "${1:-}" ]; then run_ro "show protocols all $1" show protocols all "$1";
    else run_ro "show protocols all" show protocols all; fi
}
cmd_show_symbols() { # [KIND] — table|filter|function|protocol|template|roa|symbol
    if [ -n "${1:-}" ]; then
        case "$1" in table|filter|function|protocol|template|roa|symbol) ;;
            *) err "show symbols KIND harus table|filter|function|protocol|template|roa|symbol: $1" ;;
        esac
        run_ro "show symbols $1" show symbols "$1"
    else
        run_ro "show symbols" show symbols
    fi
}
cmd_show_interfaces_bird() { # [summary]
    if [ -n "${1:-}" ]; then
        [ "$1" = "summary" ] || err "show interfaces bird hanya menerima 'summary': $1"
        run_ro "show interfaces summary" show interfaces summary
    else
        run_ro "show interfaces" show interfaces
    fi
}
cmd_show_route() { run_ro "show route" show route; }
cmd_show_route_all() { run_ro "show route all" show route all; }
cmd_show_route_count() { run_ro "show route count" show route count; }
cmd_show_route_stats() { run_ro "show route stats" show route stats; }
cmd_show_route_for() { valid_prefix "$1" "show route for <prefix>"; run_ro "show route for $1" show route for "$1"; }
cmd_show_route_in() { valid_prefix "$1" "show route in <prefix>"; run_ro "show route in $1" show route in "$1"; }
cmd_show_route_table() { # <nama>|all
    if [ "$1" = "all" ]; then run_ro "show route table all" show route table all; return 0; fi
    valid_proto_name "$1" "show route table <nama>"; run_ro "show route table $1" show route table "$1"
}
cmd_show_route_protocol() { valid_proto_name "$1" "show route protocol <nama>"; run_ro "show route protocol $1" show route protocol "$1"; }
cmd_show_route_export() { valid_proto_pattern "$1" "show route export <nama>"; run_ro "show route export $1" show route export "$1"; }
cmd_show_route_preexport() { valid_proto_pattern "$1" "show route preexport <nama>"; run_ro "show route preexport $1" show route preexport "$1"; }
cmd_show_route_noexport() { valid_proto_pattern "$1" "show route noexport <nama>"; run_ro "show route noexport $1" show route noexport "$1"; }
cmd_show_route_where() {
    valid_no_semi "$1" "show route where <kondisi>"
    run_ro "show route where $1" show route where "$1"
}
cmd_show_route_filter() { # show-route-filter <COND> — birdc show route filter { if COND then accept; } (B12/5-14 + 5-161; bentuk bernama TIDAK didukung BIRD 2.20 — F3.10 tetap)
    [ -n "$1" ] || err "show route filter butuh COND bentuk ringkas (mis. net~10.0.0.0/8)"
    valid_no_semi "$1" "show route filter <kondisi>"
    _bgpsh="$(dirname "$0")/titian-bgp.sh"
    [ -x "$_bgpsh" ] || err "show route filter butuh $_bgpsh (tidak ditemukan)"
    _bird=$(TITIAN_STATE_ROOT="$STATE_ROOT" sh "$_bgpsh" cond-to-bird "$1" 2>&1) || { echo "Error($PROG): kondisi tidak valid: $_bird" >&2; exit 33; }
    run_ro "show route filter { if $_bird then accept; }" show route filter '{' if "$_bird" then 'accept;' '}'
}

# --- B13: subcommand show route BGP-132, configure BGP-135, passthrough BC1, socket BC8 ---
cmd_show_route_primary() { # show-route-primary — show route primary [count]
    run_ro "show route primary" show route primary "$@"
}
cmd_show_route_filtered() { # show-route-filtered — show route filtered [count]
    run_ro "show route filtered" show route filtered "$@"
}
valid_proto_channel() { # <nilai> <label> — PROTO.CHANNEL (dua simbol BIRD)
    case "$1" in *.*) _a=${1%%.*}; _b=${1#*.} ;;
        *) err "$2 harus bentuk PROTO.CHANNEL (mis. bgp_10_99_40_2.ipv4): $1" ;; esac
    valid_proto_name "$_a" "$2 (protokol)"
    valid_proto_name "$_b" "$2 (channel)"
}
cmd_show_route_import_table() { # show-route-import-table <PROTO.CHANNEL>
    valid_proto_channel "$1" "show route import table <PROTO.CHANNEL>"
    run_ro "show route import table $1" show route import table "$1"
}
cmd_show_route_export_table() { # show-route-export-table <PROTO.CHANNEL>
    valid_proto_channel "$1" "show route export table <PROTO.CHANNEL>"
    run_ro "show route export table $1" show route export table "$1"
}
cmd_configure_adv() { # configure-adv [soft] [file PATH] [timeout [NUM]] — BGP-135
    # Urutan argumen mengikuti sintaks BIRD: configure [soft] ["<file>"]
    # [timeout [<num>]] (docs Bab 23). `configure` polos = 'configure reload'
    # (bukan di sini). Selalu diteruskan sebagai SATU argumen ke birdc —
    # bentuk multi-argumen gagal untuk path file berkutip (B13, live).
    _soft=""; _file=""; _timeout=""; _tnum=""
    while [ $# -gt 0 ]; do
        case "$1" in
            '') shift ;;
            soft) [ -z "$_soft" ] || err "configure-adv: 'soft' ganda"; _soft=1; shift ;;
            file)
                [ -z "$_file" ] || err "configure-adv: 'file' ganda"
                shift; [ -n "${1:-}" ] || err "configure-adv: 'file' butuh PATH (absolut, ada, bisa dibaca)"
                _file="$1"; shift ;;
            timeout)
                [ -z "$_timeout" ] || err "configure-adv: 'timeout' ganda"
                _timeout=1; shift
                case "${1:-}" in ''|*[!0-9]*) ;; *) _tnum="$1"; shift ;; esac ;;
            *) err "configure-adv: argumen tidak dikenal: $1 (boleh: soft | file PATH | timeout [NUM])" ;;
        esac
    done
    [ -n "$_soft" ] || [ -n "$_file" ] || [ -n "$_timeout" ] || \
        err "configure-adv butuh minimal satu dari: soft | file PATH | timeout [NUM] (configure polos = 'configure reload')"
    if [ -n "$_file" ]; then
        case "$_file" in /*) ;; *) err "configure-adv: file harus path absolut: $_file" ;; esac
        case "$_file" in *';'*|*\"*|*'`'*|*'$'*|*' '*) err "configure-adv: file tidak boleh mengandung spasi/';'/kutip/'\$': $_file" ;; esac
        [ -f "$_file" ] || err "configure-adv: file tidak ada: $_file"
        [ -r "$_file" ] || err "configure-adv: file tidak bisa dibaca: $_file"
    fi
    if [ -n "$_tnum" ]; then
        [ "$_tnum" -ge 1 ] 2>/dev/null || err "configure-adv: timeout harus bilangan >= 1 (detik): $_tnum"
    fi
    _cmd="configure"
    [ -n "$_soft" ] && _cmd="$_cmd soft"
    [ -n "$_file" ] && _cmd="$_cmd \"$_file\""
    if [ -n "$_timeout" ]; then _cmd="$_cmd timeout"; [ -n "$_tnum" ] && _cmd="$_cmd $_tnum"; fi
    run_state_one "configure ${_cmd#configure }" "$_cmd"
}
cmd_birdc_passthrough() { # birdc-passthrough <PERINTAH> — BC1
    # Satu string perintah BIRD, diteruskan utuh (satu argv) ke birdc.
    # `down` dan `graceful restart` DIBLOK — keduanya mematikan daemon dan
    # wajib lewat gerbang konfirmasi dua langkah ('down confirm' /
    # 'graceful-restart confirm', F3.10), bukan lewat passthrough.
    _c=$(klish_unescape "${1:-}")
    [ -n "$_c" ] || err "birdc butuh perintah (kutip seluruhnya, mis. birdc \"show status\")"
    case "$_c" in *';'*|*'
'*) err "birdc: perintah tidak boleh mengandung ';' atau baris baru: $_c" ;; esac
    _w=${_c%% *}
    case "$_w" in
        down) err "birdc: 'down' TIDAK boleh lewat passthrough — pakai 'down confirm' (dua langkah, ireversibel)" ;;
        graceful) err "birdc: 'graceful restart' TIDAK boleh lewat passthrough — pakai 'graceful-restart confirm' (dua langkah, ireversibel)" ;;
    esac
    run_state_one "birdc $_c" "$_c"
}
cmd_birdc_socket() { # birdc-socket [PATH] — BC8; kosong = tampilkan, berisi = set
    if [ -z "${1:-}" ]; then
        _cur=$(grep '^socket ' "$BIRDC_CONF" 2>/dev/null | head -1 | cut -d' ' -f2-)
        if [ -n "$_cur" ]; then
            echo "birdc socket: $_cur"
            [ -S "$_cur" ] && echo "(socket ada; panggilan birdc klish memakai -s $_cur)" || \
                echo "(PERINGATAN: socket tidak ada — panggilan birdc akan gagal; kembalikan default: birdc socket-del)"
        else
            echo "birdc socket: default (bird.ctl)"
            echo "Daemon BIRD memakai socket default /var/run/bird.ctl (rc script tanpa -s)."
        fi
        echo "Untuk memindah socket DAEMON: rc.conf bird_flags=\"-s <path>\" + restart bird (jendela maintenance, konsol)."
        return 0
    fi
    _p="$1"
    case "$_p" in /*) ;; *) err "birdc socket harus path absolut: $_p" ;; esac
    case "$_p" in *' '*|*';'*|*\"*|*'`'*|*'$'*) err "birdc socket tidak boleh mengandung spasi/';'/kutip/'\$': $_p" ;; esac
    [ -S "$_p" ] || err "birdc socket $_p bukan socket UNIX yang ada — daemon harus jalan dengan socket itu dulu (lihat catatan daemon di atas)"
    have_birdc || err "birdc tidak ada — socket tidak bisa diverifikasi"
    _birdc=$(birdc_bin)
    "$_birdc" -s "$_p" show status >/dev/null 2>&1 || err "birdc socket $_p tidak menjawab (birdc -s $_p show status gagal)"
    mkdir -p "$STATE_ROOT" 2>/dev/null || true
    printf 'socket %s\n' "$_p" > "$BIRDC_CONF" || err "tidak bisa menulis $BIRDC_CONF"
    echo "birdc socket diset: $_p (terverifikasi: birdc -s $_p show status OK)"
    echo "Catatan: ini socket SISI KLIEN. Socket daemon dipindah via rc.conf bird_flags=\"-s $_p\" + restart bird (jendela maintenance)."
}
cmd_birdc_socket_del() { # birdc-socket-del — kembali ke default (BC8)
    rm -f "$BIRDC_CONF" 2>/dev/null || true
    echo "birdc socket dikembalikan ke default (bird.ctl)"
}

cmd_show_bgp_summary() {
    # KOMPOSISI klish (BUKAN perintah birdc asli — BIRD tidak punya
    # `show bgp summary`): per neighbor dari intent bgp.conf.
    if ! have_birdc; then
        echo "(birdc tidak ada — show bgp summary dilewati; BIRD belum terpasang di image ini)"
        return 0
    fi
    [ -f "$BGP_CONF" ] || { echo "(belum ada neighbor BGP di bgp.conf — show bgp summary kosong)"; return 0; }
    _ips=$(grep '^neighbor ' "$BGP_CONF" 2>/dev/null | awk '{print $2}' | sort -u)
    [ -n "$_ips" ] || { echo "(belum ada neighbor BGP di bgp.conf — show bgp summary kosong)"; return 0; }
    for _ip in $_ips; do
        _pn=$(grep "^neighbor $_ip protocol-name " "$BGP_CONF" 2>/dev/null | head -1 | awk '{print $4}')
        if [ -n "$_pn" ]; then
            _proto=$(printf '%s' "$_pn" | tr -c 'A-Za-z0-9_' '_')
        else
            _proto="bgp_$(printf '%s' "$_ip" | tr -c 'A-Za-z0-9_' '_')"
        fi
        echo "=== BGP neighbor $_ip (protocol $_proto) ==="
        run_ro "show protocols all $_proto" show protocols all "$_proto"
        run_ro "show route protocol $_proto count" show route protocol "$_proto" count
    done
    return 0
}
# OSPF detail (Bab 4.3 No. 10-14; `show ospf` + `show ospf neighbor` sudah
# ada di titian-ospf.sh — di sini hanya varian birdc yang belum ada).
cmd_show_ospf_interface() {
    [ -n "${2:-}" ] && [ -z "${1:-}" ] && err "interface butuh nama instance dulu: cmd_show_ospf_interface <nama> <interface>"
    [ -n "${1:-}" ] && valid_proto_name "$1" "show ospf interface <nama>"
    [ -n "${2:-}" ] && valid_iface "$2" "show ospf interface <interface>"
    if [ -n "${2:-}" ]; then run_ro "show ospf interface" show ospf interface "$1" "\"$2\"";
    elif [ -n "${1:-}" ]; then run_ro "show ospf interface $1" show ospf interface "$1";
    else run_ro "show ospf interface" show ospf interface; fi
}
cmd_show_ospf_neighbors() {
    [ -n "${2:-}" ] && [ -z "${1:-}" ] && err "interface butuh nama instance dulu: cmd_show_ospf_neighbors <nama> <interface>"
    [ -n "${1:-}" ] && valid_proto_name "$1" "show ospf neighbors <nama>"
    [ -n "${2:-}" ] && valid_iface "$2" "show ospf neighbors <interface>"
    if [ -n "${2:-}" ]; then run_ro "show ospf neighbors" show ospf neighbors "$1" "\"$2\"";
    elif [ -n "${1:-}" ]; then run_ro "show ospf neighbors $1" show ospf neighbors "$1";
    else run_ro "show ospf neighbors" show ospf neighbors; fi
}
cmd_show_ospf_state() {
    if [ -n "${1:-}" ] && [ "$1" != "all" ]; then valid_proto_name "$1" "show ospf state <nama>"; fi
    if [ -n "${1:-}" ]; then run_ro "show ospf state $1" show ospf state "$1";
    else run_ro "show ospf state" show ospf state; fi
}
cmd_show_ospf_topology() {
    if [ -n "${1:-}" ] && [ "$1" != "all" ]; then valid_proto_name "$1" "show ospf topology <nama>"; fi
    if [ -n "${1:-}" ]; then run_ro "show ospf topology $1" show ospf topology "$1";
    else run_ro "show ospf topology" show ospf topology; fi
}
cmd_show_ospf_lsadb() { run_ro "show ospf lsadb" show ospf lsadb; }
# RIP detail (Bab 4.3 No. 15-16; `show rip` sudah ada di titian-rip.sh).
cmd_show_rip_interfaces() {
    [ -n "${2:-}" ] && [ -z "${1:-}" ] && err "interface butuh nama instance dulu: cmd_show_rip_interfaces <nama> <interface>"
    [ -n "${1:-}" ] && valid_proto_name "$1" "show rip interfaces <nama>"
    [ -n "${2:-}" ] && valid_iface "$2" "show rip interfaces <interface>"
    if [ -n "${2:-}" ]; then run_ro "show rip interfaces" show rip interfaces "$1" "\"$2\"";
    elif [ -n "${1:-}" ]; then run_ro "show rip interfaces $1" show rip interfaces "$1";
    else run_ro "show rip interfaces" show rip interfaces; fi
}
cmd_show_rip_neighbors() {
    [ -n "${2:-}" ] && [ -z "${1:-}" ] && err "interface butuh nama instance dulu: cmd_show_rip_neighbors <nama> <interface>"
    [ -n "${1:-}" ] && valid_proto_name "$1" "show rip neighbors <nama>"
    [ -n "${2:-}" ] && valid_iface "$2" "show rip neighbors <interface>"
    if [ -n "${2:-}" ]; then run_ro "show rip neighbors" show rip neighbors "$1" "\"$2\"";
    elif [ -n "${1:-}" ]; then run_ro "show rip neighbors $1" show rip neighbors "$1";
    else run_ro "show rip neighbors" show rip neighbors; fi
}

# --- operasional (mengubah state runtime; birdc wajib ada) ---
cmd_configure() { run_state "configure" configure; }
cmd_configure_check() { run_state "configure check" configure check; }
cmd_configure_confirm() { run_state "configure confirm" configure confirm; }
cmd_configure_undo() { run_state "configure undo" configure undo; }
cmd_proto_enable() { valid_proto_pattern "$1" "enable <nama>"; run_state "enable $1" enable "$1"; }
cmd_proto_disable() { valid_proto_pattern "$1" "disable <nama>"; run_state "disable $1" disable "$1"; }
cmd_proto_restart() { valid_proto_pattern "$1" "restart <nama>"; run_state "restart $1" restart "$1"; }
cmd_reload() { valid_proto_pattern "$1" "reload <nama>"; run_state "reload $1" reload "$1"; }
cmd_reload_all() { run_state "reload all" reload all; }
cmd_debug() { # <proto|pattern|all> <spec>
    valid_proto_pattern "$1" "debug <protokol>"
    valid_debug_spec "$2" "debug"
    _spec=$(debug_spec_to_bird "$2")
    run_state "debug $1 $2" debug "$1" "$_spec"
}
cmd_debug_all() { run_state "debug all all" debug all all; }
cmd_debug_off() { run_state "debug all off" debug all off; }
cmd_down() {
    echo "PERINGATAN: 'down' mematikan daemon BIRD (ireversibel untuk sesi routing yang jalan)."
    echo "Untuk eksekusi, jalankan: down confirm"
    echo "(Bila graceful restart yang dimaksud, pakai: graceful-restart confirm)"
    return 0
}
cmd_down_confirm() { run_state "down" down; }
cmd_graceful_restart() {
    echo "PERINGATAN: 'graceful-restart' mematikan daemon BIRD untuk graceful restart (sesi routing berhenti sampai BIRD naik lagi)."
    echo "Untuk eksekusi, jalankan: graceful-restart confirm"
    return 0
}
cmd_graceful_restart_confirm() { run_state "graceful restart" graceful restart; }
cmd_eval() { valid_no_semi "$1" "eval <ekspresi>"; run_state "eval $1" eval "$1"; }
cmd_echo() { valid_echo_spec "$1" "echo"; _spec=$(debug_spec_to_bird "$1"); run_state "echo $1" echo "$_spec"; }
cmd_dump() { # <kind> <file>
    case "$1" in resources|sockets|interfaces|neighbors|attributes|routes|protocols) ;;
        *) err "dump KIND harus resources|sockets|interfaces|neighbors|attributes|routes|protocols: $1" ;;
    esac
    valid_dump_file "$2" "dump $1 <file>"
    run_state "dump $1 $2" dump "$1" "\"$2\""
}
cmd_mrt_dump_table() { # <table|pattern> <file> [filter|where — belum diekspos]
    valid_proto_pattern "$1" "mrt dump table <tabel>"
    valid_dump_file "$2" "mrt dump table $1 to <file>"
    run_state "mrt dump table $1 to $2" mrt dump table "$1" to "\"$2\""
}
cmd_timeformat_session() { # <format> [limit <format2>]
    valid_timeformat "$1" "timeformat <format>"
    if [ -n "${2:-}" ]; then
        valid_timeformat "$2" "timeformat limit <format2>"
        run_state "timeformat $1 limit $2" timeformat "\"$1\"" limit "\"$2\""
    else
        run_state "timeformat $1" timeformat "\"$1\""
    fi
}

case "${1:-}" in
    show-status) cmd_show_status ;;
    show-protocols) shift; cmd_show_protocols "$@" ;;
    show-protocols-all) shift; cmd_show_protocols_all "$@" ;;
    show-symbols) shift; cmd_show_symbols "$@" ;;
    show-interfaces-bird) shift; cmd_show_interfaces_bird "$@" ;;
    show-route) cmd_show_route ;;
    show-route-all) cmd_show_route_all ;;
    show-route-count) cmd_show_route_count ;;
    show-route-stats) cmd_show_route_stats ;;
    show-route-for) shift; cmd_show_route_for "$@" ;;
    show-route-in) shift; cmd_show_route_in "$@" ;;
    show-route-table) shift; cmd_show_route_table "$@" ;;
    show-route-protocol) shift; cmd_show_route_protocol "$@" ;;
    show-route-export) shift; cmd_show_route_export "$@" ;;
    show-route-preexport) shift; cmd_show_route_preexport "$@" ;;
    show-route-noexport) shift; cmd_show_route_noexport "$@" ;;
    show-route-where) shift; cmd_show_route_where "$@" ;;
    show-route-filter) shift; cmd_show_route_filter "$@" ;;
    show-route-primary) shift; cmd_show_route_primary "$@" ;;
    show-route-filtered) shift; cmd_show_route_filtered "$@" ;;
    show-route-import-table) shift; cmd_show_route_import_table "$@" ;;
    show-route-export-table) shift; cmd_show_route_export_table "$@" ;;
    show-bgp-summary) cmd_show_bgp_summary ;;
    show-ospf-interface) shift; cmd_show_ospf_interface "$@" ;;
    show-ospf-neighbors) shift; cmd_show_ospf_neighbors "$@" ;;
    show-ospf-state) shift; cmd_show_ospf_state "$@" ;;
    show-ospf-topology) shift; cmd_show_ospf_topology "$@" ;;
    show-ospf-lsadb) cmd_show_ospf_lsadb ;;
    show-rip-interfaces) shift; cmd_show_rip_interfaces "$@" ;;
    show-rip-neighbors) shift; cmd_show_rip_neighbors "$@" ;;
    configure) cmd_configure ;;
    configure-check) cmd_configure_check ;;
    configure-confirm) cmd_configure_confirm ;;
    configure-undo) cmd_configure_undo ;;
    configure-adv) shift; cmd_configure_adv "$@" ;;
    birdc-passthrough) shift; cmd_birdc_passthrough "$@" ;;
    birdc-socket) shift; cmd_birdc_socket "$@" ;;
    birdc-socket-del) cmd_birdc_socket_del ;;
    proto-enable) shift; cmd_proto_enable "$@" ;;
    proto-disable) shift; cmd_proto_disable "$@" ;;
    proto-restart) shift; cmd_proto_restart "$@" ;;
    reload-both) shift; cmd_reload "$@" ;;
    reload-all) cmd_reload_all ;;
    debug) shift; cmd_debug "$@" ;;
    debug-all) cmd_debug_all ;;
    debug-off) cmd_debug_off ;;
    down) cmd_down ;;
    down-confirm) cmd_down_confirm ;;
    graceful-restart) cmd_graceful_restart ;;
    graceful-restart-confirm) cmd_graceful_restart_confirm ;;
    eval) shift; cmd_eval "$@" ;;
    echo) shift; cmd_echo "$@" ;;
    dump) shift; cmd_dump "$@" ;;
    mrt-dump-table) shift; cmd_mrt_dump_table "$@" ;;
    timeformat-session) shift; cmd_timeformat_session "$@" ;;
    *) echo "Usage: $0 {show-status|show-protocols [NAME]|show-protocols-all [NAME]|show-symbols [KIND]|show-interfaces-bird [summary]|show-route|show-route-all|show-route-count|show-route-stats|show-route-for PREFIX|show-route-in PREFIX|show-route-table NAME|all|show-route-protocol NAME|show-route-export NAME|show-route-preexport NAME|show-route-noexport NAME|show-route-where COND|show-route-filter COND|show-route-primary [count]|show-route-filtered [count]|show-route-import-table PROTO.CHANNEL|show-route-export-table PROTO.CHANNEL|show-bgp-summary|show-ospf-interface [NAME] [IFACE]|show-ospf-neighbors [NAME] [IFACE]|show-ospf-state [all|NAME]|show-ospf-topology [all|NAME]|show-ospf-lsadb|show-rip-interfaces [NAME] [IFACE]|show-rip-neighbors [NAME] [IFACE]|configure|configure-check|configure-confirm|configure-undo|configure-adv [soft] [file PATH] [timeout [NUM]]|birdc-passthrough \"PERINTAH\"|birdc-socket [PATH]|birdc-socket-del|proto-enable NAME|proto-disable NAME|proto-restart NAME|reload-both NAME|reload-all|debug PROTO SPEC|debug-all|debug-off|down|down-confirm|graceful-restart|graceful-restart-confirm|eval EXPR|echo SPEC|dump KIND FILE|mrt-dump-table TABLE FILE|timeformat-session FMT [limit FMT2]}" >&2; exit 2 ;;
esac
