#!/bin/sh
# titian-global.sh — Opsi global + definisi tabel + MPLS domain BIRD
# untuk Titian/klish (BATCH B6, BIRD 2.16.1 Bab 3.2/3.3/3.6 + Bab 2.2).
# Pola sama seperti titian-bgp.sh / titian-function.sh: intent di
# /etc/titian/bird-global.conf (satu baris per fakta, dipersistenkan
# via titian-cfg.sh), generate menulis section BIRD
# /etc/titian/bird.d/global.conf lalu memanggil
# titian-bird.sh generate global (marker #-GLOBAL-# di bird.conf).
#
# Format bird-global.conf (satu baris per fakta):
#   include <FILE>                          (wildcard diizinkan; maks depth 8)
#   log file <PATH> [limit <N> backup <PATH>] [all|classes <c1,c2,...>]
#   log syslog [name <NAME>] [all|classes <c1,c2,...>]
#   log stderr [all|classes <c1,c2,...>]
#   log udp <ADDR> [port <N>] [all|classes <c1,c2,...>]
#       kelas log: info|warning|error|fatal|debug|trace|remote|auth|bug
#       (tanpa all/classes = semua kelas; limit+backup wajib sepasang)
#   debug protocols|channels|tables <all|off|c1,c2,...>
#       protocols: states|routes|filters|interfaces|events|packets
#       channels:  states|routes|filters|events
#       tables:    states|routes|filters (CATATAN BIRD 2.16.1: debug
#       tabel saat ini NO-OP — "for now, this does nothing" — tetap
#       diekspos apa adanya, jangan diandalkan)
#   debug commands <N>                     (0 = tanpa logging)
#   debug latency <on|off>
#   debug latency limit <TIME>             (default BIRD 1 s)
#   watchdog warning <TIME>                (default BIRD 5 s)
#   watchdog timeout <TIME>                (0 = disabled, default BIRD)
#   mrtdump file <PATH>                    (wajib agar MRTdump bisa dipakai)
#   mrtdump protocols <all|off|states|messages,...>
#   hostname <NAME>                        (hostname BIRD; beda dari
#       hostname sistem — default BIRD = uname -n)
#   graceful-restart wait <N>              (detik; default BIRD 240)
#   timeformat <route|protocol|base|log> <FORMAT> [limit <N> <FORMAT2>]
#       FORMAT = shorthand (iso long|iso long ms|iso long us|iso short|
#       iso short ms|iso short us) atau strftime(3) mengandung '%'
#       (mis. "%T.%3f"); limit = detik (shorthand iso short = 72000)
#   router-id-from <POLA...>               (mask "eth*" / prefix / '-'
#       exclude; ALTERNATIF router-id di bgp.conf — keduanya bersamaan
#       DITOLAK saat generate)
#   define <NAMA> <EKSPRESI>               (int | (AA,NN) | (A,B,C) |
#       (rt|ro,A,B) | RD ASN:u32|ASN4:u16|IP:u32 | quad | bytestring
#       (hex:... | from_hex("...") | string hex >=32 digit) | (ekspresi
#       int, mis. (2+1) — nama di dalamnya harus define terdaftar) |
#       "teks" | prefix CIDR | true|false|on|off; nama tidak boleh sama
#       dengan define-int di bgp.conf — B5 hanya literal int)
#   attribute <TIPE> <NAMA>                (TIPE: int|string|ip|quad|
#       bytestring|bgppath|clist|eclist|lclist — BIRD 2.20 MENOLAK bool,
#       prefix, pair, rd ("Custom route attribute of unsupported type");
#       nama tidak boleh sama dengan attribute-int di bgp.conf)
#   table <NETTYPE> <NAMA>                 (NETTYPE: ipv4|ipv6|ipv6-sadr|
#       vpn4|vpn6|roa4|roa6|aspa|flow4|flow6|mpls; nama unik lintas nettype;
#       master4/master6 boleh di-redefine untuk memberi opsi)
#   table-opt <NAMA> <FIELD> <NILAI>       (FIELD: sorted|trie on|off;
#       debug all|off|states|routes|filters; min-settle-time|max-settle-time
#       <TIME>; gc-threshold <N>; gc-period <TIME>)
#   template <PROTO> <NAMA> [from <INDUK>] (PROTO: bgp|rip|static|
#       direct|kernel|device|bfd|pipe; template OSPF DITOLAK — BIRD
#       belum mendukung template+from untuk OSPF; from wajib merujuk
#       template yang sama PROTO-nya; blok template kosong = valid)
#   mpls domain <NAMA>                     (EKSPERIMENTAL — subsistem
#       MPLS BIRD masih eksperimental, bisa berubah backward-incompatible)
#   mpls label-range <DOMAIN> <RANGE> <START> <LENGTH>
#       (START/LENGTH >= 1; label 20-bit: START+LENGTH-1 <= 1048575;
#       range implisit static = 16-1000, dynamic = 1000-10000)
#
# CATATAN B6 — yang TIDAK ada di script ini (sengaja, lihat laporan):
#   vrf / tx priority (3.4-6/3.4-10) = Linux-specific, N/A FreeBSD;
#   eval (3.2-26) = dev-only; konstanta predefined /etc/iproute2/rt_*
#   = path Linux, tidak ada di FreeBSD; export limit SUDAH ada di B1
#   (titian-bgp.sh, jangan duplikasi); `missing lladdr self` (BGP-109)
#   tidak terdokumentasi di mana pun — TIDAK diimplementasi.
#   Channel BGP (ipv6/multicast/mpls/vpn/flow) + blok `mpls { }`
#   per-neighbor ada di titian-bgp.sh (neighbor-set <IP> <CHAN>-<FIELD>).
#
# Urutan emit generate (top-level, sebelum protocol): include -> cli ->
# log -> debug -> watchdog -> mrtdump -> hostname -> graceful restart
# wait -> timeformat -> router id from -> define -> attribute -> table
# -> mpls domain -> template.

STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CONF="$STATE_ROOT/bird-global.conf"
BGP_CONF="$STATE_ROOT/bgp.conf"
# Pager global: output show >1 layar lewat less (titian-page.sh).
# Prologue dipanggil SESUDAH setup warna/TTY bila ada, SEBELUM output pertama.
SBIN_DIR=$(dirname "$0")
. "$SBIN_DIR/titian-page.sh"
# Hanya subcommand baca yang dipager: set/generate/commit TIDAK —
# output-nya harus tetap streaming/langsung, bukan tertahan sampai EXIT.
case "${1:-}" in show*|status) titian_page_begin ;; esac

SECTION_DIR="$STATE_ROOT/bird.d"
SECTION="$SECTION_DIR/global.conf"
PROG="titian-global"
err() { echo "Error($PROG): $*" >&2; exit 33; }
die() { echo "$PROG: $*" >&2; exit 1; }

touch_conf() {
    if [ ! -f "$CONF" ]; then
        mkdir -p "$(dirname "$CONF")" 2>/dev/null
        printf '# bird-global.conf - generated by klish, do not edit by hand\n' > "$CONF" \
            || die "cannot create $CONF"
        chmod 600 "$CONF" 2>/dev/null || true
    fi
}

# upsert <regex-untuk-hapus> <baris-baru>
upsert() {
    _re="$1"; _line="$2"
    touch_conf
    _tmp="$CONF.tmp.$$"
    grep -v "$_re" "$CONF" > "$_tmp" 2>/dev/null || true
    printf '%s\n' "$_line" >> "$_tmp"
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    chmod 600 "$CONF" 2>/dev/null || true
}

dellines() {
    _re="$1"
    touch_conf
    _tmp="$CONF.tmp.$$"
    grep -v "$_re" "$CONF" > "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
}

append_once() { # append_once <baris> — tambah hanya bila belum ada persis
    touch_conf
    grep -qxF "$1" "$CONF" 2>/dev/null || printf '%s\n' "$1" >> "$CONF"
    chmod 600 "$CONF" 2>/dev/null || true
}

# --- validator (semua gagal -> rc 33 via err) ---
valid_uint() { # <nilai> <label> — bilangan >= 0
    case "$1" in ''|*[!0-9]*) err "$2 harus bilangan >= 0: $1" ;; esac
}
valid_u32() { # <nilai> <label> — 0..4294967295
    valid_uint "$1" "$2"
    [ "$1" -le 4294967295 ] 2>/dev/null || err "$2 harus 0..4294967295: $1"
}
valid_port() { # <nilai> <label> — 1..65535
    valid_uint "$1" "$2"
    [ "$1" -ge 1 ] 2>/dev/null || err "$2 harus 1..65535 (port 0 tidak valid): $1"
    [ "$1" -le 65535 ] 2>/dev/null || err "$2 harus 1..65535: $1"
}
valid_name() { # <nilai> <label> — simbol BIRD [A-Za-z0-9_]
    case "$1" in ''|*[!A-Za-z0-9_]*) err "$2 harus nama BIRD [A-Za-z0-9_]: $1" ;; esac
}
valid_symbol() { # <nilai> <label> — simbol BIRD boleh '-' (bird_ident ubah '-' -> '_' saat generate)
    case "$1" in ''|*[!A-Za-z0-9_-]*) err "$2 harus nama BIRD [A-Za-z0-9_-]: $1" ;; esac
}
valid_nospace() { # <nilai> <label> — satu token tanpa spasi
    case "$1" in ''|*[[:space:]]*) err "$2 tidak boleh kosong/mengandung spasi: $1" ;; esac
}
valid_onoff() { # <nilai> <label>
    case "$1" in on|off) ;; *) err "$2 harus on|off: $1" ;; esac
}
valid_ipv4() { # <nilai> <label> — 4 oktet 0..255
    _v="$1"; _l="$2"
    case "$_v" in *:*|*[!0-9.]*) err "$_l harus alamat IPv4: $_v" ;; esac
    _o1=$(echo "$_v" | cut -d. -f1); _o2=$(echo "$_v" | cut -d. -f2)
    _o3=$(echo "$_v" | cut -d. -f3); _o4=$(echo "$_v" | cut -d. -f4)
    [ "$(echo "$_v" | awk -F. '{print NF}')" = "4" ] || err "$_l harus alamat IPv4 (4 oktet): $_v"
    for _o in "$_o1" "$_o2" "$_o3" "$_o4"; do
        case "$_o" in ''|*[!0-9]*) err "$_l harus alamat IPv4: $_v" ;; esac
        [ "$_o" -le 255 ] 2>/dev/null || err "$_l harus alamat IPv4 (oktet 0..255): $_v"
    done
}
valid_ipv6() { # <nilai> <label> — IPv6, '::' maks sekali, grup 1-4 hex
    _v="$1"; _l="$2"
    case "$_v" in *:*) ;; *) err "$_l harus alamat IPv6: $_v" ;; esac
    case "$_v" in *[!0-9A-Fa-f:.]*) err "$_l harus alamat IPv6 (karakter tidak valid): $_v" ;; esac
    case "$_v" in *[!:]:) err "$_l harus alamat IPv6 (':' tunggal di akhir): $_v" ;; esac
    case "$_v" in :[!:]*) err "$_l harus alamat IPv6 (':' di awal tanpa '::'): $_v" ;; esac
    _t=${_v#*::}
    case "$_t" in *::*) err "$_l harus alamat IPv6 ('::' hanya boleh sekali): $_v" ;; esac
    _dc=0; case "$_v" in *::*) _dc=1 ;; esac
    _ng=0; _r="$_v"
    case "$_r" in *.*)
        _tail=${_r##*:}
        valid_ipv4 "$_tail" "$_l"
        _r=${_r%:*}
        _ng=2 ;;
    esac
    while [ -n "$_r" ]; do
        case "$_r" in *:*) _g=${_r%%:*}; _r=${_r#*:} ;; *) _g="$_r"; _r="" ;; esac
        [ -z "$_g" ] && continue
        case "$_g" in ?|??|???|????) ;; *) err "$_l harus alamat IPv6 (grup 1-4 digit hex): $_v" ;; esac
        _ng=$((_ng + 1))
    done
    if [ "$_dc" = "1" ]; then
        [ "$_ng" -le 7 ] 2>/dev/null || err "$_l harus alamat IPv6 (terlalu banyak grup untuk '::'): $_v"
    else
        [ "$_ng" -eq 8 ] 2>/dev/null || err "$_l harus alamat IPv6 (tanpa '::' harus 8 grup): $_v"
    fi
}
valid_prefix() { # <nilai> <label> — CIDR IPv4
    _v="$1"; _l="$2"
    case "$_v" in */*) ;; *) err "$_l harus prefix CIDR: $_v" ;; esac
    _ip=${_v%/*}; _len=${_v#*/}
    valid_ipv4 "$_ip" "$_l"
    case "$_len" in ''|*[!0-9]*) err "$_l panjang prefix harus bilangan: $_v" ;; esac
    [ "$_len" -le 32 ] 2>/dev/null || err "$_l panjang prefix harus 0..32: $_v"
}
valid_time() { # <nilai> <label> — waktu BIRD: angka + satuan opsional ms|us|s|m|h|d
    _v="$1"; _l="$2"
    _n="$_v"
    case "$_n" in *ms|*us) _n=${_n%??} ;; *s|*m|*h|*d) _n=${_n%?} ;; esac
    case "$_n" in ''|*[!0-9.]*) err "$_l harus waktu BIRD (mis. 5, 5s, 500ms, 1.5s): $_v" ;; esac
    case "$_n" in *.*.*) err "$_l harus waktu BIRD (satu titik desimal saja): $_v" ;; esac
    case "$_n" in .|*.) err "$_l harus waktu BIRD: $_v" ;; esac
}
valid_class_list() { # <csv> <daftar-diizinkan-csv> <label>
    _rest="$1"
    while [ -n "$_rest" ]; do
        case "$_rest" in *,*) _one=${_rest%%,*}; _rest=${_rest#*,} ;; *) _one="$_rest"; _rest="" ;; esac
        case ",$2," in *",$_one,"*) ;; *) err "$3 kelas tidak dikenal: $_one (boleh: $2)" ;; esac
    done
}
valid_debug_spec() { # <SPEC> <daftar-kelas> <label> — all|off|daftar-koma
    case "$1" in all|off) return 0 ;; esac
    valid_class_list "$1" "$2" "$3"
}
debug_spec_to_bird() { # <SPEC> -> "all" | "off" | "{ a, b }"
    case "$1" in all|off) printf '%s' "$1"; return 0 ;; esac
    printf '{ %s }' "$(printf '%s' "$1" | sed 's/,/, /g')"
}
class_suffix() { # <all|classes CSV|kosong> -> "" | " all" | " { a, b }"
    case "$1" in
        '') printf '' ;;
        all) printf ' all' ;;
        classes) printf ' { %s }' "$(printf '%s' "$2" | sed 's/,/, /g')" ;;
    esac
}
valid_nettype() { # <nettype> <label>
    case "$1" in ipv4|ipv6|ipv6-sadr|vpn4|vpn6|roa4|roa6|aspa|flow4|flow6|mpls) ;; *)
        err "$2 harus ipv4|ipv6|ipv6-sadr|vpn4|vpn6|roa4|roa6|aspa|flow4|flow6|mpls: $1" ;;
    esac
}
nettype_to_bird() { # ipv6-sadr -> "ipv6 sadr", lainnya apa adanya
    case "$1" in ipv6-sadr) printf 'ipv6 sadr' ;; *) printf '%s' "$1" ;; esac
}
valid_timeformat() { # <FORMAT> <label> — shorthand atau strftime mengandung '%'
    case "$1" in
        'iso long'|'iso long ms'|'iso long us'|'iso short'|'iso short ms'|'iso short us') return 0 ;;
    esac
    case "$1" in *%*) return 0 ;; esac
    err "$2 harus shorthand (iso long|iso long ms|iso long us|iso short|iso short ms|iso short us) atau format strftime mengandung '%': $1"
}
table_exists() { grep -q "^table [^ ]* $1\$" "$CONF" 2>/dev/null; }
table_nettype() { grep "^table [^ ]* $1\$" "$CONF" 2>/dev/null | head -1 | awk '{print $2}'; }
template_exists() { grep -q "^template $1 $2\( \|$\)" "$CONF" 2>/dev/null; }

# bird_ident <nama> — ubah nama menjadi identifier BIRD yang valid.
bird_ident() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
}

# --- include ---
cmd_include_add() { # include-add <FILE>
    [ -n "$1" ] || err "include butuh FILE"
    case "$1" in *\"*|*\;*) err "include FILE tidak boleh mengandung '\"' atau ';': $1" ;; esac
    valid_nospace "$1" "include"
    append_once "include $1"
    echo "include $1 ditambahkan"
}
cmd_include_del() {
    [ -n "$1" ] || err "include-del butuh FILE"
    dellines "^include $1\$"
    echo "include $1 dihapus"
}

# --- cli socket (B7, Bab 4.2: BC6/BC7) ---
# Intent: `cli <PATH>` atau `cli <PATH> restrict`; generate menulis
# `cli "<PATH>";` atau `cli "<PATH>" { restrict; };`.
cmd_cli_add() { # cli-add <PATH> [restrict]
    [ -n "$1" ] || err "cli-add butuh PATH socket"
    case "$1" in *\"*|*\;*) err "cli PATH tidak boleh mengandung '\"' atau ';': $1" ;; esac
    valid_nospace "$1" "cli socket"
    case "${2:-}" in ''|restrict) ;; *) err "cli-add argumen ke-2 harus 'restrict': $2" ;; esac
    dellines "^cli $1\( restrict\)\?\$"
    if [ -n "${2:-}" ]; then append_once "cli $1 restrict"; else append_once "cli $1"; fi
    echo "cli socket $1 ditambahkan${2:+ (restrict)}"
}
cmd_cli_del() { # cli-del <PATH>
    [ -n "$1" ] || err "cli-del butuh PATH socket"
    dellines "^cli $1\( restrict\)\?\$"
    echo "cli socket $1 dihapus"
}

# --- log ---
# log-add <DEST...> — bentuk:
#   file <PATH> [limit <N> backup <PATH>] [all|classes <CSV>]
#   syslog [name <NAME>] [all|classes <CSV>]
#   stderr [all|classes <CSV>]
#   udp <ADDR> [port <N>] [all|classes <CSV>]
cmd_log_add() {
    _dest="$1"; shift
    _line="log $_dest"
    case "$_dest" in
        file)
            [ -n "$1" ] || err "log file butuh PATH"
            valid_nospace "$1" "log file"
            _line="$_line $1"; shift
            if [ "$1" = "limit" ]; then
                [ -n "$2" ] && [ "$3" = "backup" ] && [ -n "$4" ] || err "log file limit butuh: limit <N> backup <PATH>"
                valid_uint "$2" "log file limit"
                valid_nospace "$4" "log file backup"
                _line="$_line limit $2 backup $4"; shift 4
            fi
            ;;
        syslog)
            if [ "$1" = "name" ]; then
                [ -n "$2" ] || err "log syslog name butuh NAMA"
                valid_nospace "$2" "log syslog name"
                _line="$_line name $2"; shift 2
            fi
            ;;
        stderr) ;;
        udp)
            [ -n "$1" ] || err "log udp butuh ADDR"
            case "$1" in *:*) valid_ipv6 "$1" "log udp" ;; *) valid_ipv4 "$1" "log udp" ;; esac
            _line="$_line $1"; shift
            if [ "$1" = "port" ]; then
                [ -n "$2" ] || err "log udp port butuh nomor"
                valid_port "$2" "log udp port"
                _line="$_line port $2"; shift 2
            fi
            ;;
        *) err "log dest harus file|syslog|stderr|udp: $_dest" ;;
    esac
    case "$1" in
        all) _line="$_line all"; shift ;;
        classes)
            [ -n "$2" ] || err "log classes butuh daftar kelas (info,warning,error,fatal,debug,trace,remote,auth,bug)"
            valid_class_list "$2" "info,warning,error,fatal,debug,trace,remote,auth,bug" "log"
            _line="$_line classes $2"; shift 2
            ;;
        '') ;;
        *) err "log akhir baris harus all atau classes <daftar>: $1" ;;
    esac
    [ -z "$1" ] || err "log: argumen berlebih: $*"
    append_once "$_line"
    echo "$_line ditambahkan"
}
cmd_log_del() { # log-del <DEST...> — hapus semua baris log ke destinasi itu
    _dest="$1"; shift
    case "$_dest" in
        file) [ -n "$1" ] || err "log-del file butuh PATH"; dellines "^log file $1\( \|$\)" ;;
        syslog) dellines "^log syslog\( \|$\)" ;;
        stderr) dellines "^log stderr\( \|$\)" ;;
        udp) [ -n "$1" ] || err "log-del udp butuh ADDR"; dellines "^log udp $1\( \|$\)" ;;
        *) err "log-del dest harus file|syslog|stderr|udp: $_dest" ;;
    esac
    echo "log $_dest dihapus"
}

# --- debug ---
cmd_debug_set() { # debug-set protocols|channels|tables <SPEC>
    _kind="$1"; _spec="$2"
    [ -n "$_kind" ] && [ -n "$_spec" ] || err "debug-set butuh KIND + SPEC (all|off|kelas,...)"
    case "$_kind" in
        protocols) valid_debug_spec "$_spec" "states,routes,filters,interfaces,events,packets" "debug protocols" ;;
        channels) valid_debug_spec "$_spec" "states,routes,filters,events" "debug channels" ;;
        tables) valid_debug_spec "$_spec" "states,routes,filters" "debug tables" ;;
        *) err "debug-set KIND harus protocols|channels|tables: $_kind" ;;
    esac
    upsert "^debug $_kind " "debug $_kind $_spec"
    echo "debug $_kind $_spec"
}
cmd_debug_del() {
    case "$1" in protocols|channels|tables) ;; *) err "debug-del KIND harus protocols|channels|tables: $1" ;; esac
    dellines "^debug $1 "
    echo "debug $1 dihapus (default BIRD off)"
}
cmd_debug_commands_set() { # debug-commands-set <N>
    [ -n "$1" ] || err "debug-commands-set butuh angka"
    valid_uint "$1" "debug commands"
    upsert '^debug commands ' "debug commands $1"
    echo "debug commands $1"
}
cmd_debug_commands_del() { dellines '^debug commands '; echo "debug commands dihapus (default BIRD 0)"; }
cmd_debug_latency_set() { # debug-latency-set <on|off>
    [ -n "$1" ] || err "debug-latency-set butuh on|off"
    valid_onoff "$1" "debug latency"
    upsert '^debug latency ' "debug latency $1"
    echo "debug latency $1"
}
cmd_debug_latency_del() { dellines '^debug latency '; echo "debug latency dihapus (default BIRD off)"; }
cmd_debug_latency_limit_set() { # debug-latency-limit-set <TIME>
    [ -n "$1" ] || err "debug-latency-limit-set butuh WAKTU"
    valid_time "$1" "debug latency limit"
    upsert '^debug latency limit ' "debug latency limit $1"
    echo "debug latency limit $1"
}
cmd_debug_latency_limit_del() { dellines '^debug latency limit '; echo "debug latency limit dihapus (default BIRD 1 s)"; }

# --- watchdog ---
cmd_watchdog_warning_set() {
    [ -n "$1" ] || err "watchdog-warning-set butuh WAKTU"
    valid_time "$1" "watchdog warning"
    upsert '^watchdog warning ' "watchdog warning $1"
    echo "watchdog warning $1"
}
cmd_watchdog_warning_del() { dellines '^watchdog warning '; echo "watchdog warning dihapus (default BIRD 5 s)"; }
cmd_watchdog_timeout_set() {
    [ -n "$1" ] || err "watchdog-timeout-set butuh WAKTU (0 = disabled)"
    valid_time "$1" "watchdog timeout"
    upsert '^watchdog timeout ' "watchdog timeout $1"
    echo "watchdog timeout $1"
}
cmd_watchdog_timeout_del() { dellines '^watchdog timeout '; echo "watchdog timeout dihapus (default BIRD disabled)"; }

# --- mrtdump ---
cmd_mrtdump_file_set() {
    [ -n "$1" ] || err "mrtdump-file-set butuh PATH"
    valid_nospace "$1" "mrtdump file"
    upsert '^mrtdump file ' "mrtdump file $1"
    echo "mrtdump file $1"
}
cmd_mrtdump_file_del() { dellines '^mrtdump file '; echo "mrtdump file dihapus"; }
cmd_mrtdump_protocols_set() {
    [ -n "$1" ] || err "mrtdump-protocols-set butuh SPEC (all|off|states|messages,...)"
    valid_debug_spec "$1" "states,messages" "mrtdump protocols"
    upsert '^mrtdump protocols ' "mrtdump protocols $1"
    echo "mrtdump protocols $1"
}
cmd_mrtdump_protocols_del() { dellines '^mrtdump protocols '; echo "mrtdump protocols dihapus (default BIRD off)"; }

# --- hostname / graceful restart wait / timeformat / router-id-from ---
cmd_hostname_set() {
    [ -n "$1" ] || err "hostname-set butuh NAMA"
    case "$1" in *\"*|*\;*) err "hostname tidak boleh mengandung '\"' atau ';': $1" ;; esac
    valid_nospace "$1" "hostname"
    upsert '^hostname ' "hostname $1"
    echo "hostname BIRD $1 (beda dari hostname sistem)"
}
cmd_hostname_del() { dellines '^hostname '; echo "hostname BIRD dihapus (default uname -n)"; }
cmd_gr_wait_set() {
    [ -n "$1" ] || err "graceful-restart-wait-set butuh detik"
    valid_uint "$1" "graceful restart wait"
    upsert '^graceful-restart wait ' "graceful-restart wait $1"
    echo "graceful restart wait $1"
}
cmd_gr_wait_del() { dellines '^graceful-restart wait '; echo "graceful restart wait dihapus (default BIRD 240)"; }

# --- graceful restart recovery (flag -R saat bird start; Bab 2.4-2; B14) ---
# Intent `graceful-restart recovery on|off` di bird-global.conf; setter
# LANGSUNG menerapkan ke rc.conf via sysrc bird_flags (bukan config
# BIRD — tidak ada langkah commit untuknya; intent adalah source of truth
# dan sysrc disinkronkan saat set). TIDAK perlu patch rc script bird:
# rc.subr FreeBSD SUDAH meneruskan ${bird_flags} otomatis ke daemon
# (terbukti live B14: ps menunjukkan `bird -R ...` sekali dengan rc
# script port asli; patch command_args malah menduplikasi -R). Tanpa
# sysrc (mock/Linux) hanya intent yang ditulis + catatan ke stderr.
apply_bird_flags() { # <"-R"|""> — set/hapus bird_flags di rc.conf
    if command -v sysrc >/dev/null 2>&1; then
        if [ -n "$1" ]; then
            sysrc bird_flags="$1" >/dev/null || err "sysrc bird_flags gagal"
        else
            sysrc -x bird_flags >/dev/null 2>&1 || true
        fi
    else
        echo "(sysrc tidak ada di host ini — bird_flags tidak diterapkan; intent tetap tersimpan)" >&2
    fi
}
cmd_gr_recovery_set() { # graceful-restart-recovery-set on|off
    [ -n "$1" ] || err "graceful-restart-recovery-set butuh on|off"
    case "$1" in
        on) upsert '^graceful-restart recovery ' "graceful-restart recovery on"
            apply_bird_flags "-R"
            echo "graceful restart recovery ON (bird start berikutnya pakai flag -R)" ;;
        off) upsert '^graceful-restart recovery ' "graceful-restart recovery off"
            apply_bird_flags ""
            echo "graceful restart recovery OFF (bird start tanpa -R)" ;;
        *) err "graceful-restart recovery harus on|off: $1" ;;
    esac
}
cmd_gr_recovery_del() {
    dellines '^graceful-restart recovery '
    apply_bird_flags ""
    echo "graceful restart recovery dihapus (default OFF — bird start tanpa -R)"
}
cmd_timeformat_set() { # timeformat-set <KIND> <FORMAT...> [limit <N> <FORMAT2...>]
    _kind="$1"; shift
    case "$_kind" in route|protocol|base|log) ;; *) err "timeformat KIND harus route|protocol|base|log: $_kind" ;; esac
    [ -n "$1" ] || err "timeformat-set butuh FORMAT"
    _fmt=""; _lim=""; _fmt2=""
    while [ -n "$1" ]; do
        if [ "$1" = "limit" ]; then
            shift
            [ -n "$1" ] || err "timeformat limit butuh detik"
            valid_uint "$1" "timeformat limit"
            _lim="$1"; shift
            _fmt2="$*"
            break
        fi
        _fmt="${_fmt:+$_fmt }$1"; shift
    done
    case "$_fmt" in *\"*) err "timeformat FORMAT tidak boleh mengandung '\"': $_fmt" ;; esac
    valid_timeformat "$_fmt" "timeformat $_kind"
    if [ -n "$_lim" ]; then
        [ -n "$_fmt2" ] || err "timeformat limit butuh FORMAT2 sesudah detik"
        case "$_fmt2" in *\"*) err "timeformat FORMAT2 tidak boleh mengandung '\"': $_fmt2" ;; esac
        valid_timeformat "$_fmt2" "timeformat $_kind (limit)"
        upsert "^timeformat $_kind " "timeformat $_kind $_fmt limit $_lim $_fmt2"
    else
        upsert "^timeformat $_kind " "timeformat $_kind $_fmt"
    fi
    echo "timeformat $_kind $_fmt${_lim:+ limit $_lim $_fmt2}"
}
cmd_timeformat_del() {
    case "$1" in route|protocol|base|log) ;; *) err "timeformat-del KIND harus route|protocol|base|log: $1" ;; esac
    dellines "^timeformat $1 "
    echo "timeformat $1 dihapus (default BIRD iso short ms / iso long ms)"
}
cmd_router_id_from_set() { # router-id-from-set <POLA...> — mask/prefix/'-' exclude
    [ -n "$1" ] || err "router-id-from-set butuh POLA (mis. \"eth*\" 192.168.0.0/16)"
    _pat="$*"
    case "$_pat" in *\;*) err "router-id-from POLA tidak boleh mengandung ';': $_pat" ;; esac
    for _tok in $_pat; do
        _t="$_tok"
        case "$_t" in -*) _t=${_t#-} ;; esac
        case "$_t" in
            '') ;; # token '-' saja
            *\"*) _t=$(printf '%s' "$_t" | tr -d '"') ;;
        esac
        [ -z "$_t" ] && continue
        case "$_t" in */*)
            valid_prefix "$_t" "router-id-from" ;;
            *)
            case "$_t" in *[!A-Za-z0-9_*?.-]*) err "router-id-from token tidak valid (mask/prefix): $_tok" ;; esac ;;
        esac
    done
    upsert '^router-id-from ' "router-id-from $_pat"
    echo "router id from $_pat"
}
cmd_router_id_from_del() { dellines '^router-id-from '; echo "router-id-from dihapus"; }

# --- B8: validator define tambahan (Bab 5.2) ---
_g_valid_bytestring() { # <nilai> <label> — bytestring
    _gv="$1"; _gl="$2"
    case "$_gv" in
        from_hex\(\"*\"\))
            _gh=$(printf '%s' "$_gv" | sed 's/^from_hex("//; s/")$//')
            case "$_gh" in ''|*[!0-9a-fA-F.:-]*) err "$_gl from_hex: isi harus digit hex + pemisah . : - : $_gv" ;; esac
            case "$_gh" in *[0-9a-fA-F]*) ;; *) err "$_gl from_hex: butuh minimal 1 digit hex: $_gv" ;; esac ;;
        'hex:'*)
            _gh=${_gv#hex:}
            case "$_gh" in ''|*[!0-9a-fA-F:]*) err "$_gl bytestring hex: harus byte hex dipisah ':' (mis. hex:0e:10:20): $_gv" ;; esac ;;
        *)
            case "$_gv" in *[!0-9a-fA-F]*) err "$_gl bytestring tanpa prefix hex: wajib string hex (tanpa spasi): $_gv" ;; esac
            _gn=${#_gv}
            [ $(( _gn % 2 )) -eq 0 ] || err "$_gl bytestring tanpa prefix hex: jumlah digit harus genap: $_gv"
            [ "$_gn" -ge 32 ] || err "$_gl bytestring tanpa prefix hex: wajib >= 16 byte (32 digit hex); yang pendek wajib prefix hex: : $_gv" ;;
    esac
}
_g_valid_rd() { # <nilai> <label> — RD: ASN:u32 | ASN4:u16 | IP:u32
    _gv="$1"; _gl="$2"
    case "$_gv" in *:*) ;; *) err "$_gl harus RD (ASN:u32 | ASN4:u16 | IP:u32): $_gv" ;; esac
    _gr1=${_gv%%:*}; _gr2=${_gv#*:}
    case "$_gr2" in *:*|''|*[!0-9]*) err "$_gl RD bagian kedua harus angka: $_gv" ;; esac
    case "$_gr1" in *.*)
        valid_ipv4 "$_gr1" "$_gl (RD IP)"
        [ "$_gr2" -le 65535 ] 2>/dev/null || err "$_gl RD bentuk IP:u32 butuh u32 0..65535: $_gv" ;;
        *)
        case "$_gr1" in ''|*[!0-9]*) err "$_gl RD ASN harus angka: $_gv" ;; esac
        [ "$_gr1" -le 4294967295 ] 2>/dev/null || err "$_gl RD ASN harus 0..4294967295: $_gv"
        [ "$_gr2" -le 4294967295 ] 2>/dev/null || err "$_gl RD bagian kedua harus 0..4294967295: $_gv"
        { [ "$_gr1" -le 65535 ] 2>/dev/null || [ "$_gr2" -le 65535 ] 2>/dev/null; } || err "$_gl RD butuh bentuk ASN:u32 (ASN 0..65535) atau ASN4:u16 (u16 0..65535): $_gv" ;;
    esac
}
_g_valid_ec() { # <nilai> <label> — EC (rt|ro, A, B)
    _gv="$1"; _gl="$2"
    case "$_gv" in '('*')') ;; *) err "$_gl harus EC (rt|ro, A, B): $_gv" ;; esac
    _ge=${_gv#(}; _ge=${_ge%)}
    case "$_ge" in *,*,*) ;; *) err "$_gl EC harus tepat 3 komponen: $_gv" ;; esac
    _gk=${_ge%%,*}; _grest=${_ge#*,}
    case "$_gk" in rt|ro) ;; *) err "$_gl EC tipe harus rt|ro: $_gv" ;; esac
    _ga=${_grest%%,*}; _gb=${_grest#*,}
    case "$_gb" in *,*) err "$_gl EC harus tepat 3 komponen: $_gv" ;; esac
    case "$_ga" in ''|*[!0-9]*) err "$_gl EC A harus angka: $_gv" ;; esac
    case "$_gb" in ''|*[!0-9]*) err "$_gl EC B harus angka: $_gv" ;; esac
    [ "$_ga" -le 4294967295 ] 2>/dev/null || err "$_gl EC A harus 0..4294967295: $_gv"
    [ "$_gb" -le 4294967295 ] 2>/dev/null || err "$_gl EC B harus 0..4294967295: $_gv"
    { [ "$_ga" -le 65535 ] 2>/dev/null || [ "$_gb" -le 65535 ] 2>/dev/null; } || err "$_gl EC butuh bentuk (rt|ro, ASN16, u32) atau (rt|ro, ASN32, u16): $_gv"
}
_g_valid_lc() { # <nilai> <label> — LC (A,B,C): A 0..4294967295, B/C 0..65535
    _gv="$1"; _gl="$2"
    case "$_gv" in '('*')') ;; *) err "$_gl harus LC (A,B,C): $_gv" ;; esac
    _ge=${_gv#(}; _ge=${_ge%)}
    case "$_ge" in *,*,*) ;; *) err "$_gl LC harus tepat 3 komponen: $_gv" ;; esac
    _ga=${_ge%%,*}; _gr=${_ge#*,}; _gb=${_gr%%,*}; _gc=${_gr#*,}
    case "$_gc" in *,*) err "$_gl LC harus tepat 3 komponen: $_gv" ;; esac
    case "$_ga" in ''|*[!0-9]*) err "$_gl LC A harus angka: $_gv" ;; esac
    case "$_gb" in ''|*[!0-9]*) err "$_gl LC B harus angka: $_gv" ;; esac
    case "$_gc" in ''|*[!0-9]*) err "$_gl LC C harus angka: $_gv" ;; esac
    [ "$_ga" -le 4294967295 ] 2>/dev/null || err "$_gl LC A harus 0..4294967295: $_gv"
    [ "$_gb" -le 65535 ] 2>/dev/null || err "$_gl LC B harus 0..65535: $_gv"
    [ "$_gc" -le 65535 ] 2>/dev/null || err "$_gl LC C harus 0..65535: $_gv"
}
_g_valid_int_expr() { # <dalam-kurung> <label> — ekspresi int (2+1), nama harus define terdaftar
    _gi="$1"; _gl="$2"
    [ -n "$_gi" ] || err "$_gl ekspresi int kosong: ()"
    _gnp=$(printf '%s' "$_gi" | tr -d '()')
    case "$_gnp" in *[!0-9A-Za-z_+*/.-]*) err "$_gl ekspresi int mengandung karakter tidak valid: ($_gi)" ;; esac
    _go=$(printf '%s' "$_gi" | tr -cd '(' | wc -c); _gc2=$(printf '%s' "$_gi" | tr -cd ')' | wc -c)
    [ "$_go" = "$_gc2" ] || err "$_gl ekspresi int kurung tidak seimbang: ($_gi)"
    printf '%s' "$_gi" | tr -cs 'A-Za-z0-9_' '\n' | while IFS= read -r _gw; do
        case "$_gw" in ''|*[!0-9]*) ;; *) continue ;; esac
        case "$_gw" in *[!A-Za-z0-9_]*) err "$_gl ekspresi int kata tidak valid: $_gw" ;; esac
        grep -q "^define $_gw " "$CONF" 2>/dev/null || [ "$_gw" = "true" ] || [ "$_gw" = "false" ] || err "$_gl ekspresi int memakai nama '$_gw' yang belum didefinisikan (define $_gw dulu)"
    done || exit 33
}

# --- define / attribute ---
cmd_define_add() { # define-add <NAMA> <EKSPRESI>
    [ -n "$1" ] && [ -n "$2" ] || err "define-add butuh NAMA + EKSPRESI"
    valid_name "$1" "define"
    _e="$2"
    _g_is_int=0
    case "$_e" in
        ''|*\;*) err "define EKSPRESI tidak boleh kosong/mengandung ';': $_e" ;;
    esac
    case "$_e" in
        *[!0-9]*) ;; # bukan int murni — lanjut ke bentuk lain
        *) # digit murni: int bila muat u32 (<=10 digit); string digit yang
           # lebih panjang jatuh ke bawah sebagai kandidat bytestring
           if [ "${#_e}" -le 10 ]; then valid_u32 "$_e" "define"; _g_is_int=1; fi ;;
    esac
    case "$_e" in
        'from_hex("*")') _g_valid_bytestring "$_e" "define" ;;
        'hex:'*) _g_valid_bytestring "$_e" "define" ;;
        '('*')')
            # Bentuk berkurung — urutan penting: EC dulu (mengandung koma),
            # lalu LC (2 koma), pair (1 koma), terakhir ekspresi int.
            _g_inner=${_e#(}; _g_inner=${_g_inner%)}
            case "$_g_inner" in
                rt,*|ro,*) _g_valid_ec "$_e" "define" ;;
                *,*,*) _g_valid_lc "$_e" "define" ;;
                *,*)
                    _pa=${_g_inner%%,*}; _a=${_pa}; _n=${_g_inner#*,}
                    case "$_a" in ''|*[!0-9]*) err "define pair AS harus angka: $_e" ;; esac
                    case "$_n" in ''|*[!0-9]*) err "define pair NN harus angka: $_e" ;; esac
                    [ "$_a" -le 65535 ] 2>/dev/null || err "define pair AS harus 0..65535: $_e"
                    [ "$_n" -le 65535 ] 2>/dev/null || err "define pair NN harus 0..65535: $_e"
                    ;;
                *) _g_valid_int_expr "$_g_inner" "define" ;;
            esac
            ;;
        \"*\") ;; # string ber-quote
        */*) valid_prefix "$_e" "define" ;;
        true|false|on|off) ;;
        *:*)
            case "$_e" in *:*:*) err "define EKSPRESI harus int | (AA,NN) | (A,B,C) | (rt|ro,A,B) | RD | quad | bytestring | (ekspresi-int) | \"teks\" | prefix CIDR | true|false|on|off: $_e" ;; esac
            _g_valid_rd "$_e" "define" ;;
        *.*)
            case "$_e" in *[!0-9.]*) err "define EKSPRESI harus int | (AA,NN) | (A,B,C) | (rt|ro,A,B) | RD | quad | bytestring | (ekspresi-int) | \"teks\" | prefix CIDR | true|false|on|off: $_e" ;; esac
            valid_ipv4 "$_e" "define (quad)" ;;
        *)
            # Sisa: int murni (sudah divalidasi) atau bytestring hex tanpa
            # prefix (huruf a-f, >=32 digit genap).
            [ "$_g_is_int" = "1" ] && : || {
                case "$_e" in *[!0-9a-fA-F]*) err "define EKSPRESI harus int | (AA,NN) | (A,B,C) | (rt|ro,A,B) | RD | quad | bytestring | (ekspresi-int) | \"teks\" | prefix CIDR | true|false|on|off: $_e" ;; esac
                _g_valid_bytestring "$_e" "define"
            } ;;
    esac
    if [ -f "$BGP_CONF" ] && grep -q "^define-int $1 " "$BGP_CONF" 2>/dev/null; then
        err "define $1 sudah ada sebagai define-int di bgp.conf (B5) — hapus dulu salah satunya"
    fi
    upsert "^define $1 " "define $1 $_e"
    echo "define $1 = $_e"
}
cmd_define_del() {
    [ -n "$1" ] || err "define-del butuh NAMA"
    dellines "^define $1 "
    echo "define $1 dihapus"
}
cmd_attribute_add() { # attribute-add <TIPE> <NAMA>
    [ -n "$1" ] && [ -n "$2" ] || err "attribute-add butuh TIPE + NAMA"
    case "$1" in int|string|ip|quad|bytestring|bgppath|clist|eclist|lclist) ;;
        *) err "attribute TIPE harus int|string|ip|quad|bytestring|bgppath|clist|eclist|lclist: $1" ;;
    esac
    valid_name "$2" "attribute"
    if [ -f "$BGP_CONF" ] && grep -q "^attribute-int $2\$" "$BGP_CONF" 2>/dev/null; then
        err "attribute $2 sudah ada sebagai attribute-int di bgp.conf (B5) — hapus dulu salah satunya"
    fi
    upsert "^attribute [^ ]* $2\$" "attribute $1 $2"
    echo "attribute $1 $2"
}
cmd_attribute_del() {
    [ -n "$1" ] || err "attribute-del butuh NAMA"
    dellines "^attribute [^ ]* $1\$"
    echo "attribute $1 dihapus"
}

# --- table ---
cmd_table_add() { # table-add <NETTYPE> <NAMA>
    [ -n "$1" ] && [ -n "$2" ] || err "table-add butuh NETTYPE + NAMA"
    valid_nettype "$1" "table"
    valid_symbol "$2" "table"
    case "$2" in ipv4|ipv6|ipv6-sadr|vpn4|vpn6|roa4|roa6|aspa|flow4|flow6|mpls)
        err "table NAMA tidak boleh sama dengan keyword nettype: $2" ;;
    esac
    if table_exists "$2"; then
        _old=$(table_nettype "$2")
        [ "$_old" = "$1" ] || err "table $2 sudah ada sebagai $_old (nama tabel unik lintas nettype)"
        echo "table $1 $2 sudah ada"
        return 0
    fi
    touch_conf
    printf 'table %s %s\n' "$1" "$2" >> "$CONF"
    chmod 600 "$CONF" 2>/dev/null || true
    echo "table $1 $2 ditambahkan"
}
cmd_table_del() { # table-del <NAMA> — hapus definisi + semua opsinya
    [ -n "$1" ] || err "table-del butuh NAMA"
    dellines "^table [^ ]* $1\$"
    dellines "^table-opt $1 "
    echo "table $1 dihapus"
}
cmd_table_set() { # table-set <NAMA> <FIELD> <NILAI>
    [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || err "table-set butuh NAMA FIELD NILAI"
    case "$1" in
        master4|master6)
            # B.6: tabel master BIRD selalu ada (built-in) — table-set
            # boleh langsung. Redefine implisit ke intent (`table ipv4
            # master4` / `table ipv6 master6`) agar emitter + guard
            # mengenalinya; bentuk telanjang `table master4 {...}` DITOLAK
            # bird -p ("unexpected TABLE") — wajib prefix nettype.
            if ! table_exists "$1"; then
                touch_conf
                case "$1" in
                    master4) printf 'table ipv4 master4\n' >> "$CONF" ;;
                    master6) printf 'table ipv6 master6\n' >> "$CONF" ;;
                esac
                chmod 600 "$CONF" 2>/dev/null || true
            fi ;;
        *)
            table_exists "$1" || err "table-set: table $1 belum didefinisikan (table-add dulu)" ;;
    esac
    case "$2" in
        sorted|trie)
            valid_onoff "$3" "table $2"
            if [ "$2" = "trie" ]; then
                # BIRD 2.20: trie hanya untuk tabel prefix (ipv4/ipv6/ipv6-sadr);
                # flow4/flow6/mpls menolak ("Trie option not supported").
                _nt=$(grep "^table [^ ]* $1\$" "$CONF" 2>/dev/null | awk '{print $2}' | head -1)
                case "$_nt" in flow4|flow6|mpls) err "table $1: trie tidak didukung untuk tabel $_nt (BIRD 2.20: hanya ipv4/ipv6/ipv6-sadr)" ;; esac
            fi
            ;;
        debug)
            valid_debug_spec "$3" "states,routes,filters" "table debug"
            ;;
        min-settle-time|max-settle-time)
            valid_time "$3" "table $2"
            ;;
        gc-threshold)
            valid_uint "$3" "table gc-threshold"
            ;;
        gc-period)
            valid_time "$3" "table gc-period"
            ;;
        *) err "table-set FIELD harus sorted|trie|debug|min-settle-time|max-settle-time|gc-threshold|gc-period: $2" ;;
    esac
    upsert "^table-opt $1 $2 " "table-opt $1 $2 $3"
    echo "table $1 $2 $3"
}
cmd_table_unset() { # table-unset <NAMA> <FIELD>
    [ -n "$1" ] && [ -n "$2" ] || err "table-unset butuh NAMA FIELD"
    case "$2" in sorted|trie|debug|min-settle-time|max-settle-time|gc-threshold|gc-period) ;;
        *) err "table-unset FIELD harus sorted|trie|debug|min-settle-time|max-settle-time|gc-threshold|gc-period: $2" ;;
    esac
    dellines "^table-opt $1 $2 "
    echo "table $1 $2 dihapus (default BIRD)"
}
cmd_show_tables() {
    touch_conf
    grep '^table ' "$CONF" 2>/dev/null | while read -r _ _nt _nm; do
        _opts=$(grep "^table-opt $_nm " "$CONF" 2>/dev/null | awk '{printf "%s=%s ", $3, $4}')
        printf '%s %s%s\n' "$_nt" "$_nm" "${_opts:+ [$_opts]}"
    done
}

# --- template ---
cmd_template_add() { # template-add <PROTO> <NAMA> [from <INDUK>]
    [ -n "$1" ] && [ -n "$2" ] || err "template-add butuh PROTO + NAMA"
    case "$1" in
        ospf) err "template OSPF tidak didukung BIRD (template + from belum diimplementasikan untuk OSPF) — pakai instans OSPF langsung" ;;
        bgp|rip|static|direct|kernel|device|bfd|pipe) ;;
        *) err "template PROTO harus bgp|rip|static|direct|kernel|device|bfd|pipe: $1" ;;
    esac
    valid_symbol "$2" "template"
    _from=""
    if [ -n "$3" ]; then
        [ "$3" = "from" ] && [ -n "$4" ] || err "template-add bentuk: template-add PROTO NAMA [from INDUK]"
        [ "$4" = "$2" ] && err "template $2 tidak boleh from dirinya sendiri"
        valid_symbol "$4" "template from"
        _from=" from $4"
    fi
    [ -z "$5" ] || err "template-add: argumen berlebih: $5"
    _other=$(grep "^template [^ ]* $2 " "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
    if [ -n "$_other" ] && [ "$_other" != "$1" ]; then
        err "template $2 sudah ada sebagai template $_other (nama template unik lintas protokol)"
    fi
    upsert "^template $1 $2 " "template $1 $2$_from"
    echo "template $1 $2$_from"
}
cmd_template_del() {
    [ -n "$1" ] && [ -n "$2" ] || err "template-del butuh PROTO + NAMA"
    dellines "^template $1 $2 "
    echo "template $1 $2 dihapus"
}

# --- mpls ---
cmd_mpls_domain_add() { # mpls-domain-add <NAMA>
    [ -n "$1" ] || err "mpls-domain-add butuh NAMA"
    valid_symbol "$1" "mpls domain"
    append_once "mpls domain $1"
    echo "mpls domain $1 ditambahkan (EKSPERIMENTAL)"
}
cmd_mpls_domain_del() {
    [ -n "$1" ] || err "mpls-domain-del butuh NAMA"
    dellines "^mpls domain $1\$"
    dellines "^mpls label-range $1 "
    echo "mpls domain $1 dihapus (label-range di dalamnya ikut dihapus)"
}
cmd_mpls_label_range_add() { # mpls-label-range-add <DOMAIN> <RANGE> <START> <LENGTH>
    [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] || err "mpls-label-range-add butuh DOMAIN RANGE START LENGTH"
    valid_symbol "$1" "mpls domain"
    valid_symbol "$2" "mpls label range"
    valid_uint "$3" "mpls label range start"
    valid_uint "$4" "mpls label range length"
    [ "$3" -ge 1 ] 2>/dev/null || err "mpls label range start harus >= 1 (0 tidak valid): $3"
    [ "$4" -ge 1 ] 2>/dev/null || err "mpls label range length harus >= 1 (0 tidak valid): $4"
    [ "$3" -le 1048575 ] 2>/dev/null || err "mpls label range start harus 0..1048575 (label 20-bit): $3"
    [ $(( $3 + $4 - 1 )) -le 1048575 ] 2>/dev/null || err "mpls label range start+length-1 harus <= 1048575 (label 20-bit): $3 + $4"
    grep -q "^mpls domain $1\$" "$CONF" 2>/dev/null || err "mpls label-range: domain $1 belum didefinisikan (mpls-domain-add dulu)"
    upsert "^mpls label-range $1 $2 " "mpls label-range $1 $2 $3 $4"
    echo "mpls domain $1 label range $2 start $3 length $4 (EKSPERIMENTAL)"
}
cmd_mpls_label_range_del() {
    [ -n "$1" ] && [ -n "$2" ] || err "mpls-label-range-del butuh DOMAIN RANGE"
    dellines "^mpls label-range $1 $2 "
    echo "mpls label-range $1 $2 dihapus"
}

cmd_show() {
    touch_conf
    echo "--- bird-global.conf (intent) ---"
    cat "$CONF"
    echo "--- bird.d/global.conf (section, bila ada) ---"
    [ -f "$SECTION" ] && cat "$SECTION" || echo "(belum di-generate)"
}

# --- generate: intent -> bird.d/global.conf (sintaks BIRD) ---
# BIRD 2.20: nilai TIME wajib bersatuan (s/ms/us) — angka polos ditolak
# ("unexpected ';', expecting S or MS or US"). Intent boleh polos (= detik);
# bird_time menormalisasi angka polos -> <n>s saat emit.
bird_time() { # <nilai> — normalisasi waktu BIRD
    case "$1" in
        *ms|*us|*s|*m|*h|*d) printf '%s' "$1" ;;
        *) printf '%ss' "$1" ;;
    esac
}
cmd_generate() {
    touch_conf
    # Guard lintas-file (intent bisa diedit tangan):
    # router-id (bgp.conf) vs router-id-from (di sini) = alternatif, tidak boleh bersamaan.
    if grep -q '^router-id-from ' "$CONF" 2>/dev/null && [ -f "$BGP_CONF" ] && grep -q '^router-id ' "$BGP_CONF" 2>/dev/null; then
        err "router-id-from tidak bisa dipakai bersama router-id di bgp.conf (keduanya alternatif penentu router id — hapus salah satunya)"
    fi
    # define / attribute tidak boleh duplikat dengan define-int / attribute-int (B5, bgp.conf).
    for _dn in $(grep '^define ' "$CONF" 2>/dev/null | awk '{print $2}'); do
        if [ -f "$BGP_CONF" ] && grep -q "^define-int $_dn " "$BGP_CONF" 2>/dev/null; then
            err "define $_dn sudah ada sebagai define-int di bgp.conf — hapus dulu salah satunya"
        fi
    done
    for _an in $(grep '^attribute ' "$CONF" 2>/dev/null | awk '{print $3}'); do
        if [ -f "$BGP_CONF" ] && grep -q "^attribute-int $_an\$" "$BGP_CONF" 2>/dev/null; then
            err "attribute $_an sudah ada sebagai attribute-int di bgp.conf — hapus dulu salah satunya"
        fi
    done
    # Nama tabel unik lintas nettype (tambah tangan bisa menduplikasi).
    _dup=$(grep '^table ' "$CONF" 2>/dev/null | awk '{print $3}' | sort | uniq -d | head -1)
    [ -n "$_dup" ] && err "table $_dup didefinisikan lebih dari sekali (nama tabel unik lintas nettype)"
    # table-opt wajib merujuk tabel yang ada.
    for _on in $(grep '^table-opt ' "$CONF" 2>/dev/null | awk '{print $2}' | sort -u); do
        table_exists "$_on" || err "table-opt merujuk table yang tidak ada: $_on"
    done
    # template from wajib merujuk template yang sama PROTO-nya.
    while read -r _ _tp _tn _f _fp; do
        [ "$_f" = "from" ] || continue
        [ "$_fp" = "$_tn" ] && err "template $_tn tidak boleh from dirinya sendiri"
        template_exists "$_tp" "$_fp" || err "template $_tp $_tn from $_fp: template induk $_fp tidak ada (template-add $_tp $_fp dulu)"
    done <<EOF
$(grep '^template ' "$CONF" 2>/dev/null)
EOF
    mkdir -p "$SECTION_DIR" 2>/dev/null || die "cannot mkdir $SECTION_DIR"
    _tmp="$SECTION.tmp.$$"
    {
        echo "# global.conf - generated by titian-global.sh, do not edit by hand"
        # --- include ---
        _inc=$(grep '^include ' "$CONF" 2>/dev/null | sed 's/^include \(.*\)/include "\1";/')
        [ -n "$_inc" ] && { printf '%s\n' "$_inc"; echo ""; }
        # --- cli sockets (B7, Bab 4.2) ---
        while read -r _ _p _r; do
            case "$_r" in restrict) echo "cli \"$_p\" { restrict; };" ;; *) echo "cli \"$_p\";" ;; esac
        done <<EOF
$(grep '^cli ' "$CONF" 2>/dev/null)
EOF
        # --- log ---
        _log_done=0
        while read -r _ _dest _rest; do
            case "$_dest" in
                file)
                    _p=${_rest%% *}; _r=${_rest#* }
                    [ "$_p" = "$_rest" ] && _r=""
                    _out="log \"$_p\""
                    case "$_r" in limit\ *)
                        _r2=${_r#limit }; _lim=${_r2%% *}; _r3=${_r2#* }
                        _bakfull=${_r3#backup }; _bak=${_bakfull%% *}
                        case "$_bakfull" in *' '*) _r=${_bakfull#* } ;; *) _r="" ;; esac
                        # BIRD 2.20: log file rotation positional, TANPA kata kunci
                        # `limit`/`backup` (bird -p: "unexpected LIMIT") — bentuk benar:
                        # log "<file>" <size> "<backup>" { ... }; (size+backup sepasang).
                        _out="$_out $_lim \"$_bak\""
                        ;;
                    esac
                    case "$_r" in
                        all) _out="$_out all" ;;
                        classes\ *) _out="$_out { $(printf '%s' "${_r#classes }" | sed 's/,/, /g') }" ;;
                        '') ;;
                    esac
                    echo "$_out;"
                    _log_done=1
                    ;;
                syslog)
                    _out="log syslog"
                    case "$_rest" in name\ *)
                        _nm=${_rest#name }; _nm=${_nm%% *}; _r=${_rest#* }
                        _out="$_out name $_nm"
                        case "$_r" in *\ *\ *) _r=${_r#* * } ;; *) _r="" ;; esac
                        ;;
                        *) _r="$_rest" ;;
                    esac
                    case "$_r" in
                        all) _out="$_out all" ;;
                        classes\ *) _out="$_out { $(printf '%s' "${_r#classes }" | sed 's/,/, /g') }" ;;
                        '') ;;
                    esac
                    echo "$_out;"
                    _log_done=1
                    ;;
                stderr)
                    _out="log stderr"
                    case "$_rest" in
                        all) _out="$_out all" ;;
                        classes\ *) _out="$_out { $(printf '%s' "${_rest#classes }" | sed 's/,/, /g') }" ;;
                        '') ;;
                    esac
                    echo "$_out;"
                    _log_done=1
                    ;;
                udp)
                    _a=${_rest%% *}; _r=${_rest#* }
                    [ "$_a" = "$_rest" ] && _r=""
                    _out="log udp $_a"
                    case "$_r" in port\ *)
                        _pn=${_r#port }; _pn=${_pn%% *}
                        _out="$_out port $_pn"
                        case "$_r" in *\ *\ *) _r=${_r#* * } ;; *) _r="" ;; esac
                        ;;
                    esac
                    case "$_r" in
                        all) _out="$_out all" ;;
                        classes\ *) _out="$_out { $(printf '%s' "${_r#classes }" | sed 's/,/, /g') }" ;;
                        '') ;;
                    esac
                    echo "$_out;"
                    _log_done=1
                    ;;
            esac
        done <<EOF
$(grep '^log ' "$CONF" 2>/dev/null)
EOF
        [ "$_log_done" = "1" ] && echo ""
        # --- debug ---
        _dbg=$(grep '^debug ' "$CONF" 2>/dev/null)
        if [ -n "$_dbg" ]; then
            printf '%s\n' "$_dbg" | while read -r _ _kind _spec; do
                case "$_kind" in
                    protocols|channels|tables) echo "debug $_kind $(debug_spec_to_bird "$_spec");" ;;
                    commands) echo "debug commands $_spec;" ;;
                    latency)
                        case "$_spec" in
                            limit) _lv=$(grep '^debug latency limit ' "$CONF" | head -1 | awk '{print $4}'); echo "debug latency limit $(bird_time "$_lv");" ;;
                            *) echo "debug latency $_spec;" ;;
                        esac
                        ;;
                esac
            done
            echo ""
        fi
        # --- watchdog ---
        # TIME bertipe satuan (lihat bird_time di atas): intent polos -> <n>s.
        _wd=$(grep '^watchdog ' "$CONF" 2>/dev/null)
        if [ -n "$_wd" ]; then
            printf '%s\n' "$_wd" | while read -r _ _kind _val; do
                echo "watchdog $_kind $(bird_time "$_val");"
            done
            echo ""
        fi
        # --- mrtdump ---
        _mrt=$(grep '^mrtdump ' "$CONF" 2>/dev/null)
        if [ -n "$_mrt" ]; then
            printf '%s\n' "$_mrt" | while read -r _ _kind _spec; do
                case "$_kind" in
                    file) echo "mrtdump \"$_spec\";" ;;
                    protocols) echo "mrtdump protocols $(debug_spec_to_bird "$_spec");" ;;
                esac
            done
            echo ""
        fi
        # --- hostname ---
        _hn=$(grep '^hostname ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
        [ -n "$_hn" ] && { echo "hostname \"$_hn\";"; echo ""; }
        # --- graceful restart wait ---
        _grw=$(grep '^graceful-restart wait ' "$CONF" 2>/dev/null | head -1 | awk '{print $3}')
        [ -n "$_grw" ] && { echo "graceful restart wait $_grw;"; echo ""; }
        # --- timeformat ---
        _tf=$(grep '^timeformat ' "$CONF" 2>/dev/null)
        if [ -n "$_tf" ]; then
            printf '%s\n' "$_tf" | while read -r _ _kind _rest; do
                case "$_rest" in *' limit '*)
                    _fmt=${_rest%%' limit '*}; _lr=${_rest#*' limit '}
                    _lim=${_lr%% *}; _fmt2=${_lr#* }
                    # BIRD 2.20: timeformat limit positional, TANPA kata kunci `limit`
                    # (bird -p: "unexpected LIMIT") — bentuk benar:
                    # timeformat <kind> "<fmt>" <detik> "<fmt2>";
                    echo "timeformat $_kind \"$_fmt\" $_lim \"$_fmt2\";"
                    ;;
                    *) echo "timeformat $_kind \"$_rest\";" ;;
                esac
            done
            echo ""
        fi
        # --- router id from ---
        _rif=$(grep '^router-id-from ' "$CONF" 2>/dev/null | head -1 | sed 's/^router-id-from //')
        if [ -n "$_rif" ]; then
            _out="router id from"
            for _tok in $_rif; do
                case "$_tok" in
                    -) _out="$_out -" ;;
                    -*) _t=${_tok#-}; _t=$(printf '%s' "$_t" | tr -d '"')
                        case "$_t" in */*) _out="$_out - $_t" ;; *) _out="$_out - \"$_t\"" ;; esac ;;
                    *) _t=$(printf '%s' "$_tok" | tr -d '"')
                        case "$_t" in */*) _out="$_out $_t" ;; *) _out="$_out \"$_t\"" ;; esac ;;
                esac
            done
            echo "$_out;"
            echo ""
        fi
        # --- define ---
        _def=$(grep '^define ' "$CONF" 2>/dev/null | sed 's/^define \([A-Za-z0-9_]*\) \(.*\)/define \1 = \2;/')
        [ -n "$_def" ] && { printf '%s\n' "$_def"; echo ""; }
        # --- attribute ---
        _at=$(grep '^attribute ' "$CONF" 2>/dev/null | sed 's/^attribute \([A-Za-z0-9_]*\) \([A-Za-z0-9_]*\)/attribute \1 \2;/')
        [ -n "$_at" ] && { printf '%s\n' "$_at"; echo ""; }
        # --- table ---
        for _tn in $(grep '^table ' "$CONF" 2>/dev/null | awk '{print $3}' | sort -u); do
            _nt=$(table_nettype "$_tn")
            _opts=$(grep "^table-opt $_tn " "$CONF" 2>/dev/null)
            if [ -z "$_opts" ]; then
                echo "$(nettype_to_bird "$_nt") table $(bird_ident "$_tn");"
            else
                echo "$(nettype_to_bird "$_nt") table $(bird_ident "$_tn") {"
                printf '%s\n' "$_opts" | while read -r _ _ _f _v; do
                    case "$_f" in
                        sorted|trie) echo "    $_f $_v;" ;;
                        debug) echo "    debug $(debug_spec_to_bird "$_v");" ;;
                        min-settle-time) echo "    min settle time $_v;" ;;
                        max-settle-time) echo "    max settle time $_v;" ;;
                        gc-threshold) echo "    gc threshold $_v;" ;;
                        gc-period) echo "    gc period $_v;" ;;
                    esac
                done
                echo "};"
            fi
        done
        grep -q '^table ' "$CONF" 2>/dev/null && echo ""
        # --- mpls domain (EKSPERIMENTAL) ---
        for _dm in $(grep '^mpls domain ' "$CONF" 2>/dev/null | awk '{print $3}' | sort -u); do
            _lrs=$(grep "^mpls label-range $_dm " "$CONF" 2>/dev/null)
            if [ -z "$_lrs" ]; then
                echo "mpls domain $(bird_ident "$_dm");"
            else
                echo "mpls domain $(bird_ident "$_dm") {"
                printf '%s\n' "$_lrs" | while read -r _ _ _ _rng _st _ln; do
                    echo "    label range $(bird_ident "$_rng") {"
                    echo "        start $_st;"
                    echo "        length $_ln;"
                    echo "    };"
                done
                echo "};"
            fi
        done
        grep -q '^mpls domain ' "$CONF" 2>/dev/null && echo ""
        # --- template ---
        _tpl=$(grep '^template ' "$CONF" 2>/dev/null)
        if [ -n "$_tpl" ]; then
            printf '%s\n' "$_tpl" | while read -r _ _tp _tn _f _fp; do
                if [ "$_f" = "from" ]; then
                    echo "template $_tp $(bird_ident "$_tn") from $(bird_ident "$_fp") {"
                else
                    echo "template $_tp $(bird_ident "$_tn") {"
                fi
                echo "};"
            done
        fi
    } > "$_tmp" || die "cannot write $_tmp"
    mv "$_tmp" "$SECTION" || die "cannot write $SECTION"
    chmod 644 "$SECTION" 2>/dev/null || true
    echo "global section ditulis: $SECTION"
    _birdsh="$(dirname "$0")/titian-bird.sh"
    if [ -x "$_birdsh" ]; then
        "$_birdsh" generate global || exit 33
    else
        echo "Warning: $_birdsh tidak ditemukan; section hanya ditulis, belum di-apply" >&2
    fi
}

case "$1" in
    touch) touch_conf; echo "bird-global" ;;
    include-add) shift; cmd_include_add "$@" ;;
    include-del) shift; cmd_include_del "$@" ;;
    cli-add) shift; cmd_cli_add "$@" ;;
    cli-del) shift; cmd_cli_del "$@" ;;
    log-add) shift; cmd_log_add "$@" ;;
    log-del) shift; cmd_log_del "$@" ;;
    debug-set) shift; cmd_debug_set "$@" ;;
    debug-del) shift; cmd_debug_del "$@" ;;
    debug-commands-set) shift; cmd_debug_commands_set "$@" ;;
    debug-commands-del) cmd_debug_commands_del ;;
    debug-latency-set) shift; cmd_debug_latency_set "$@" ;;
    debug-latency-del) cmd_debug_latency_del ;;
    debug-latency-limit-set) shift; cmd_debug_latency_limit_set "$@" ;;
    debug-latency-limit-del) cmd_debug_latency_limit_del ;;
    watchdog-warning-set) shift; cmd_watchdog_warning_set "$@" ;;
    watchdog-warning-del) cmd_watchdog_warning_del ;;
    watchdog-timeout-set) shift; cmd_watchdog_timeout_set "$@" ;;
    watchdog-timeout-del) cmd_watchdog_timeout_del ;;
    mrtdump-file-set) shift; cmd_mrtdump_file_set "$@" ;;
    mrtdump-file-del) cmd_mrtdump_file_del ;;
    mrtdump-protocols-set) shift; cmd_mrtdump_protocols_set "$@" ;;
    mrtdump-protocols-del) cmd_mrtdump_protocols_del ;;
    hostname-set) shift; cmd_hostname_set "$@" ;;
    hostname-del) cmd_hostname_del ;;
    graceful-restart-wait-set) shift; cmd_gr_wait_set "$@" ;;
    graceful-restart-wait-del) cmd_gr_wait_del ;;
    graceful-restart-recovery-set) shift; cmd_gr_recovery_set "$@" ;;
    graceful-restart-recovery-del) cmd_gr_recovery_del ;;
    timeformat-set) shift; cmd_timeformat_set "$@" ;;
    timeformat-del) shift; cmd_timeformat_del "$@" ;;
    router-id-from-set) shift; cmd_router_id_from_set "$@" ;;
    router-id-from-del) cmd_router_id_from_del ;;
    define-add) shift; cmd_define_add "$@" ;;
    define-del) shift; cmd_define_del "$@" ;;
    attribute-add) shift; cmd_attribute_add "$@" ;;
    attribute-del) shift; cmd_attribute_del "$@" ;;
    table-add) shift; cmd_table_add "$@" ;;
    table-del) shift; cmd_table_del "$@" ;;
    table-set) shift; cmd_table_set "$@" ;;
    table-unset) shift; cmd_table_unset "$@" ;;
    show-tables) cmd_show_tables ;;
    template-add) shift; cmd_template_add "$@" ;;
    template-del) shift; cmd_template_del "$@" ;;
    mpls-domain-add) shift; cmd_mpls_domain_add "$@" ;;
    mpls-domain-del) shift; cmd_mpls_domain_del "$@" ;;
    mpls-label-range-add) shift; cmd_mpls_label_range_add "$@" ;;
    mpls-label-range-del) shift; cmd_mpls_label_range_del "$@" ;;
    generate) cmd_generate ;;
    show|status) cmd_show ;;
    *) echo "Usage: $0 {touch|include-add FILE|include-del FILE|cli-add PATH [restrict]|cli-del PATH|log-add DEST...|log-del DEST...|debug-set KIND SPEC|debug-del KIND|debug-commands-set N|debug-commands-del|debug-latency-set on|off|debug-latency-del|debug-latency-limit-set TIME|debug-latency-limit-del|watchdog-warning-set TIME|watchdog-warning-del|watchdog-timeout-set TIME|watchdog-timeout-del|mrtdump-file-set PATH|mrtdump-file-del|mrtdump-protocols-set SPEC|mrtdump-protocols-del|hostname-set NAME|hostname-del|graceful-restart-wait-set N|graceful-restart-wait-del|graceful-restart-recovery-set on|off|graceful-restart-recovery-del|timeformat-set KIND FORMAT [limit N FORMAT2]|timeformat-del KIND|router-id-from-set PATTERN...|router-id-from-del|define-add NAME EXPR|define-del NAME|attribute-add TYPE NAME|attribute-del NAME|table-add NETTYPE NAME|table-del NAME|table-set NAME FIELD VALUE|table-unset NAME FIELD|show-tables|template-add PROTO NAME [from PARENT]|template-del PROTO NAME|mpls-domain-add NAME|mpls-domain-del NAME|mpls-label-range-add DOMAIN RANGE START LENGTH|mpls-label-range-del DOMAIN RANGE|generate|show}" >&2; exit 2 ;;
esac
