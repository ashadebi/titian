#!/bin/sh
# titian-static.sh — Static routes intent (BIRD `protocol static`) untuk Titian/klish.
# Pola sama seperti titian-bfd.sh: intent di /etc/titian/static.conf
# (tmpfs, dipersistenkan via titian-cfg.sh), generate menulis section
# BIRD /etc/titian/bird.d/static.conf lalu memanggil titian-bird.sh
# generate static (render + validasi + birdc). Section ditulis ulang
# UTUH tiap apply.
#
# Sintaks BIRD 2.16.1 yang dipakai (docs resmi bird.network,
# User's Guide 2.16.1, §6.17 Static):
#   protocol static [static4|static6] {
#       check link;
#       igp table <name>;
#       ipv4; | ipv6;
#       route <prefix> via <ip> [weight N] [bfd] [dev "<iface>"] [onlink]
#                      [via ...];
#       route <prefix> via "<iface>";
#       route <prefix> recursive <ip>;
#       route <prefix> blackhole|unreachable|prohibit;
#       route <prefix> via <ip> {
#           ospf_metric1 = N; ospf_metric2 = N; ospf_tag = N;
#           bgp_community.add((AA, NN));
#           bgp_large_community.add((AA, X, NN));
#       };
#   }
# B13 (S30): blok filter per-route UMUM — statement filter apa pun
# (set:/unset:/method:/accept/reject + if COND then STMT [else STMT])
# via `route filter-add` / `route filter-if` (intent `fstmt`, urut SEQ);
# `route-attr-set` tetap sebagai jalan pintas 7 field.
# Satu instance = satu network type: route IPv4 -> `protocol static
# static4`, route IPv6 -> `protocol static static6`. `check link` dan
# `igp table` adalah opsi level protokol (sama di kedua instance).
# Default BIRD: check link off; igp table = tabel protokol itu sendiri.
# `weight` = angka 1..256 (teks docs menulis "weight switch" — itu typo
# docs; contoh memakai `weight 2`, konsisten dengan ecmp weight 1..256).
#
# TIDAK diimplementasi di batch ini (lihat laporan B4):
#   - `mpls` per-route / per-nexthop (S5/S13): subsistem MPLS
#     eksperimental, belum ada di Titian.
# B9: route ROA / ASPA (S8-S9) DIIMPLEMENTASI — sebagai instance static
#   terpisah (static_roa4/static_roa6/static_aspa_<tabel>) dengan channel
#   roa4/roa6/aspa + `table <T>;`. Tabel: param opsional, bila kosong
#   diambil tabel roa4/roa6/aspa PERTAMA dari bird-global.conf (table-add);
#   bila tidak ada -> generate rc=33. CATATAN: binding channel roa/aspa
#   di `protocol static` BELUM terverifikasi `bird -p` (docs Bab 6.17
#   hanya memberi sintaks route-nya) — lihat laporan B9 §7.
#   - Import/export filter channel: channel static dibiarkan default
#     (bare `ipv4;` / `ipv6;`); filter generik menyusul batch filter.
#
# B8 — Flowspec RFC 5575 (S10, S16-S29): `route flow4 { ... };` /
# `route flow6 { ... };` + channel `flow4 { table <name>; };` /
# `flow6 { table <name>; };` (BIRD 2.20: flow4 DAN flow6 wajib punya
# tabel; satu protocol static hanya boleh satu tipe channel — flow
# dipisah ke protocol staticflow4/staticflow6 sendiri).
# dst v4 WAJIB (generate menolak flow4 tanpa dst); dst/src v6 boleh
# `offset N` (abaikan N bit pertama, 0..128). proto hanya flow4,
# next-header/label hanya flow6. numbers-match: daftar angka/rentang
# koma (`80..90,120..124`) atau operator relasional (=,!=,<,<=,>,>=,
# true,false) dengan &&/||. bitmask: value/mask atau !value/mask
# (negasi: value harus 0 atau = mask); tcp-flags mask maks 0xfff.
# label = SATU nilai 0..0xfffff (tanpa mask — BIRD 2.20 menolak
# value/mask). fragment: dont_fragment|is_fragment|
# first_fragment|last_fragment (boleh &&/||/!).
#
# Format static.conf (satu baris per fakta):
#   check-link on|off
#   igp-table <name>
#   route <prefix> via <nexthop> [weight N] [bfd] [dev <iface>] [onlink]
#   route <prefix> via-iface <iface>
#   route <prefix> recursive <ip>
#   route <prefix> blackhole|unreachable|prohibit
#   route <prefix> attr ospf-metric1 <N>
#   route <prefix> attr ospf-metric2 <N>
#   route <prefix> attr ospf-tag <N>
#   route <prefix> attr bgp-community <AS:NN>
#   route <prefix> attr bgp-large-community <AA:X:NN>
#   route <prefix> attr ra-preference <RA_PREF_LOW|RA_PREF_MEDIUM|RA_PREF_HIGH>
#   route <prefix> attr ra-lifetime <N>
#   flow-table <4|6> <name>              (tabel flow4/flow6 dari global)
#   flowroute <4|6> <ID> <field> <value>  (field: dst|dst-offset|src|
#       src-offset|proto|port|dport|sport|icmp-type|icmp-code|tcp-flags|
#       length|dscp|fragment|next-header|label)
#
# Ini BIRD `protocol static` — BERBEDA dari static route kernel
# (`ip route ...` di conf-route-fbsd.xml / titian-route.sh, yang
# menulis langsung ke tabel kernel via `route add`). Jangan dicampur:
# route BIRD static hidup di tabel routing BIRD dan hanya masuk kernel
# bila channel kernel mengekspornya.

STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CONF="$STATE_ROOT/static.conf"
SECTION_DIR="$STATE_ROOT/bird.d"
# Pager global: output show >1 layar lewat less (titian-page.sh).
# Prologue dipanggil SESUDAH setup warna/TTY bila ada, SEBELUM output pertama.
SBIN_DIR=$(dirname "$0")
. "$SBIN_DIR/titian-page.sh"
# Hanya subcommand baca yang dipager: set/generate/commit TIDAK —
# output-nya harus tetap streaming/langsung, bukan tertahan sampai EXIT.
case "${1:-}" in show) titian_page_begin ;; esac

SECTION="$SECTION_DIR/static.conf"
PROG="titian-static"
err() { echo "Error($PROG): $*" >&2; exit 33; }
die() { echo "$PROG: $*" >&2; exit 1; }

touch_conf() {
    if [ ! -f "$CONF" ]; then
        mkdir -p "$(dirname "$CONF")" 2>/dev/null
        printf '# static.conf - generated by klish, do not edit by hand\n' > "$CONF" \
            || die "cannot create $CONF"
        chmod 600 "$CONF" 2>/dev/null || true
    fi
}

# upsert <regex-untuk-hapus> <baris-baru>
# Ganti DI TEMPAT: baris pertama yang cocok diganti baris baru (posisi
# dipertahankan), duplikat lain dibuang; append hanya bila belum ada.
# (Dulu hapus + append di akhir — replay startup-config memindahkan
# baris ke akhir file tiap restart: sink blackhole yang di-replay lebih
# dulu dari via (via-add aman diulang, tidak bergerak) sehingga urutan
# intent membalik dan bird.conf flip; B27-ordering, 18 Nov 2026.)
upsert() {
    _re="$1"; _line="$2"
    touch_conf
    _tmp="$CONF.tmp.$$"
    awk -v re="$_re" -v line="$_line" '
        $0 ~ re {
            if (!done) { print line; done=1 }
            next
        }
        { print }
        END { if (!done) print line }
    ' "$CONF" > "$_tmp" 2>/dev/null || true
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

has_facts() {
    [ -f "$CONF" ] || return 1
    grep -v '^[[:space:]]*#' "$CONF" 2>/dev/null | grep -q '[^[:space:]]'
}

# --- validasi ---
# valid_prefix <prefix>: CIDR dengan plen numerik sesuai keluarga.
# $1=prefix. Gagal -> err rc=33.
valid_prefix() {
    _p="$1"
    case "$_p" in
        */*) ;;
        *) err "prefix harus CIDR (mis. 10.0.0.0/8 atau 2001:db8::/32): $_p" ;;
    esac
    _ip="${_p%/*}"; _plen="${_p#*/}"
    [ -n "$_ip" ] || err "prefix tidak valid: $_p"
    case "$_plen" in ''|*[!0-9]*) err "prefix length harus angka: $_p" ;; esac
    case "$_ip" in
        *:*)
            [ "$_plen" -le 128 ] 2>/dev/null || err "prefix length IPv6 harus 0..128: $_p" ;;
        *)
            case "$_ip" in *.*.*.*) ;;
                *) err "prefix IPv4 tidak valid: $_p" ;;
            esac
            [ "$_plen" -le 32 ] 2>/dev/null || err "prefix length IPv4 harus 0..32: $_p" ;;
    esac
}

# valid_ip <ip>: alamat IP (v4/v6, boleh suffix %zone untuk link-local).
# $1=ip, $2=konteks pesan. Gagal -> err rc=33.
valid_ip() {
    _ip="${1%%\%*}"
    case "$_ip" in
        *:*)
            case "$_ip" in *[!0-9a-fA-F:]*) err "$2 bukan alamat IPv6 valid: $1" ;; esac ;;
        *.*.*.*)
            case "$_ip" in *[!0-9.]*) err "$2 bukan alamat IPv4 valid: $1" ;; esac ;;
        *) err "$2 bukan alamat IP valid: $1" ;;
    esac
}

# prefix_family <prefix>: cetak 4 atau 6.
prefix_family() {
    case "$1" in *:* ) echo 6 ;; *) echo 4 ;; esac
}

ip_family() {
    case "${1%%\%*}" in *:* ) echo 6 ;; *) echo 4 ;; esac
}

# route_kind <prefix>: cetak via|recursive|blackhole|unreachable|prohibit|none.
route_kind() {
    _p="$1"
    awk -v p="$_p" '$1=="route" && $2==p {
        if ($3=="via" || $3=="via-iface") { print "via"; exit }
        if ($3=="recursive") { print "recursive"; exit }
        if ($3=="blackhole" || $3=="unreachable" || $3=="prohibit") { print $3; exit }
    }' "$CONF" 2>/dev/null
    [ -n "$(awk -v p="$_p" '$1=="route" && $2==p && ($3=="via" || $3=="via-iface" || $3=="recursive" || $3=="blackhole" || $3=="unreachable" || $3=="prohibit") {print 1; exit}' "$CONF" 2>/dev/null)" ] || echo "none"
}

# check_kind_conflict <prefix> <kind-baru>: tolak bila prefix sudah
# punya kind lain (via/recursive/sink saling eksklusif per prefix).
check_kind_conflict() {
    _p="$1"; _new="$2"; _cur=$(route_kind "$_p")
    case "$_cur" in
        none) return 0 ;;
        "$_new") return 0 ;;
        via)
            case "$_new" in via) return 0 ;; esac ;;
        blackhole|unreachable|prohibit)
            # Ganti jenis sink (blackhole -> prohibit, dst) diizinkan:
            # route-sink-set menghapus sink lama dulu.
            case "$_new" in blackhole|unreachable|prohibit) return 0 ;; esac ;;
    esac
    err "route $_p sudah $_cur — tidak bisa tambah $_new di prefix yang sama (hapus dulu: no route $_p)"
}

valid_name() {
    # $1=nama $2=konteks: [A-Za-z0-9_]+ (nama tabel BIRD / igp table).
    case "$1" in
        ''|*[!A-Za-z0-9_]*) err "$2 harus nama BIRD [A-Za-z0-9_]: $1" ;;
    esac
}

cmd_static_touch() {
    touch_conf
    echo "Static"
}

cmd_check_link_set() {
    case "$1" in
        on|off) upsert '^check-link ' "check-link $1" ;;
        *) err "check-link harus on|off: $1" ;;
    esac
    echo "Static check-link = $1"
}

cmd_igp_table_set() {
    [ -n "$1" ] || err "igp-table butuh nama tabel"
    valid_name "$1" "igp-table"
    upsert '^igp-table ' "igp-table $1"
    echo "Static igp-table = $1"
}

cmd_igp_table_del() {
    dellines '^igp-table '
    echo "Static igp-table dihapus (kembali ke tabel protokol)"
}

valid_num() {
    # valid_num <nilai> <lo> <hi> <label> — bilangan bulat dalam range.
    case "$1" in ''|*[!0-9]*) err "$4 harus bilangan $2..$3: $1" ;; esac
    [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null || \
        err "$4 harus bilangan $2..$3: $1"
}

cond_validate() {
    # cond_validate <COND> — validasi ekspresi filter bentuk ringkas
    # (mis. net~10.0.0.0/8) via titian-bgp.sh cond-to-bird. Bila script
    # itu tidak ada (deploy parsial), fallback validasi ringan.
    _bgpsh="$(dirname "$0")/titian-bgp.sh"
    if [ -x "$_bgpsh" ]; then
        "$_bgpsh" cond-to-bird "$1" >/dev/null
    else
        case "$1" in *[\;\{\}]* ) err "where: ekspresi mengandung karakter terlarang (; { })" ;; esac
    fi
}

cond_translate() {
    # cond_translate <COND> -> terjemahan BIRD (stdout); gagal rc=33.
    # Dipakai di generate untuk bentuk `import/export where <COND>`.
    _bgpsh="$(dirname "$0")/titian-bgp.sh"
    if [ -x "$_bgpsh" ]; then
        "$_bgpsh" cond-to-bird "$1" || exit 33
    else
        err "penerjemah kondisi tidak tersedia (titian-bgp.sh tidak ditemukan di $(dirname "$0"))"
    fi
}

klish_unescape() {
    printf '%s' "$1" | sed -e 's/\\>/>/g' -e 's/\\</</g' -e 's/\\(/(/g' -e 's/\\)/)/g' -e 's/\\&/\&/g' -e 's/\\|/|/g' -e 's/\\;/;/g' -e 's/\\\\/\\/g'
}

bgp_stmt_to_bird() { # bgp_stmt_to_bird <STMT> -> terjemahan BIRD (stdout); gagal rc=33.
    # Dipakai validasi + generate statement filter per-route (S30, B13).
    _bgpsh="$(dirname "$0")/titian-bgp.sh"
    if [ -x "$_bgpsh" ]; then
        "$_bgpsh" stmt-to-bird "$1" || exit 33
    else
        err "penerjemah statement tidak tersedia (titian-bgp.sh tidak ditemukan di $(dirname "$0"))"
    fi
}

bgp_cond_to_bird() { # bgp_cond_to_bird <COND> -> terjemahan BIRD (stdout); gagal rc=33.
    # Dipakai generate `route-filter-if` (S30, B13) — sama dengan cond_translate.
    cond_translate "$1"
}

cmd_disabled_set() { # disabled-set on|off (Bab 3.4-1; berlaku instance static4/static6)
    case "$1" in
        on|off) upsert '^disabled ' "disabled $1" ;;
        *) err "disabled harus on|off: $1" ;;
    esac
    echo "Static disabled = $1"
}

cmd_disabled_del() { # disabled-del
    dellines '^disabled '
    echo "Static disabled dihapus (default BIRD: protokol aktif)"
}

cmd_from_set() { # from-set TEMPLATE (Bab 3.2-15/16; template static)
    [ -n "$1" ] || err "from butuh nama template static"
    valid_name "$1" "from"
    upsert '^from ' "from $1"
    echo "Static from = $1"
}

cmd_from_del() { # from-del
    dellines '^from '
    echo "Static from dihapus"
}

cmd_channel_set() { # channel-set <ipv4|ipv6> <preference|import|export> <nilai...>
    # (Bab 3.5-3/4/5; channel static4/static6; where = filter inline
    # bentuk ringkas, mis. net~10.0.0.0/8 — diterjemahkan saat generate.)
    _ch="$1"; _f="$2"; shift 2
    case "$_ch" in ipv4|ipv6) ;; *) err "channel harus ipv4|ipv6: $_ch" ;; esac
    case "$_f" in
        preference)
            [ -n "$1" ] || err "channel $_ch preference butuh nilai 0..65535"
            valid_num "$1" 0 65535 "preference"
            upsert "^channel $_ch preference " "channel $_ch preference $1" ;;
        import|export)
            [ -n "$1" ] || err "channel $_ch $_f butuh all|none|filter <nama>|where <ekspresi>"
            _val="$*"
            case "$1" in
                all|none) upsert "^channel $_ch $_f " "channel $_ch $_f $1" ;;
                filter) [ -n "$2" ] || err "channel $_ch $_f filter butuh nama filter"
                    valid_name "$2" "nama filter"
                    upsert "^channel $_ch $_f " "channel $_ch $_f filter $2" ;;
                where)
                    shift
                    [ -n "$*" ] || err "channel $_ch $_f where butuh ekspresi filter bentuk ringkas (mis. where net~10.0.0.0/8)"
                    cond_validate "$*" || exit 33
                    upsert "^channel $_ch $_f " "channel $_ch $_f where $*" ;;
                *) err "channel $_ch $_f harus all|none|filter <nama>|where <ekspresi>: $1" ;;
            esac
            echo "Static channel $_ch $_f = $_val"
            return 0 ;;
        *) err "channel field harus preference|import|export: $_f" ;;
    esac
    echo "Static channel $_ch $_f = $*"
}

cmd_channel_del() { # channel-del <ipv4|ipv6> <preference|import|export>
    _ch="$1"; _f="$2"
    case "$_ch" in ipv4|ipv6) ;; *) err "channel harus ipv4|ipv6: $_ch" ;; esac
    case "$_f" in
        preference|import|export) dellines "^channel $_ch $_f " ;;
        *) err "channel field harus preference|import|export: $_f" ;;
    esac
    echo "Static channel $_ch $_f dihapus (default BIRD)"
}

cmd_route_touch() {
    _p="$1"
    [ -n "$_p" ] || err "route butuh prefix CIDR"
    valid_prefix "$_p"
    touch_conf
    echo "Static route $_p"
}

cmd_route_del() {
    _p="$1"
    [ -n "$_p" ] || err "route-del butuh prefix CIDR"
    # Hapus SEMUA baris route prefix ini (via/recursive/sink/attr).
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" '$1!="route" || $2!=p' "$CONF" 2>/dev/null > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p dihapus"
}

cmd_route_via_add() {
    _p="$1"; _nh="$2"
    [ -n "$_p" ] && [ -n "$_nh" ] || err "route-via-add butuh PREFIX NEXTHOP"
    valid_prefix "$_p"
    valid_ip "$_nh" "nexthop"
    [ "$(prefix_family "$_p")" = "$(ip_family "$_nh")" ] || \
        err "nexthop $_nh beda keluarga dengan prefix $_p (v4 vs v6)"
    check_kind_conflict "$_p" via
    # Aman diulang: via yang sama sudah ada -> tidak duplikat.
    if awk -v p="$_p" -v nh="$_nh" '$1=="route" && $2==p && $3=="via" && $4==nh {f=1} END{exit !f}' "$CONF" 2>/dev/null; then
        echo "Static route $_p via $_nh sudah ada"
        return 0
    fi
    touch_conf
    printf 'route %s via %s\n' "$_p" "$_nh" >> "$CONF"
    echo "Static route $_p via $_nh"
}

cmd_route_via_del() {
    _p="$1"; _nh="$2"
    [ -n "$_p" ] && [ -n "$_nh" ] || err "route-via-del butuh PREFIX NEXTHOP"
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" -v nh="$_nh" '!($1=="route" && $2==p && $3=="via" && $4==nh)' "$CONF" 2>/dev/null > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p via $_nh dihapus"
}

cmd_route_via_set() {
    # route-via-set <PREFIX> <NEXTHOP> <field> <value>
    # field: weight|bfd|dev|onlink
    _p="$1"; _nh="$2"; _f="$3"; _v="$4"
    [ -n "$_p" ] && [ -n "$_nh" ] && [ -n "$_f" ] || \
        err "route-via-set butuh PREFIX NEXTHOP FIELD VALUE"
    # Nilai kosong hanya sah untuk `dev` (= hapus dev, via `no dev`).
    [ -n "$_v" ] || [ "$_f" = "dev" ] || \
        err "route-via-set butuh PREFIX NEXTHOP FIELD VALUE"
    case "$_f" in
        weight)
            case "$_v" in ''|*[!0-9]*) err "weight harus bilangan 1..256: $_v" ;; esac
            [ "$_v" -ge 1 ] 2>/dev/null && [ "$_v" -le 256 ] 2>/dev/null || \
                err "weight harus bilangan 1..256: $_v" ;;
        bfd|onlink)
            case "$_v" in on|off) ;; *) err "$_f harus on|off: $_v" ;; esac ;;
        dev)
            case "$_v" in ''|*[!A-Za-z0-9_.-]*) err "dev harus nama interface: $_v" ;; esac ;;
        *) err "field nexthop tidak dikenal: $_f (weight|bfd|dev|onlink)" ;;
    esac
    awk -v p="$_p" -v nh="$_nh" '$1=="route" && $2==p && $3=="via" && $4==nh {f=1} END{exit !f}' "$CONF" 2>/dev/null || \
        err "nexthop $_nh belum ada di route $_p (tambah dulu: via $_nh)"
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" -v nh="$_nh" -v f="$_f" -v v="$_v" '
        $1=="route" && $2==p && $3=="via" && $4==nh {
            # kumpulkan opsi lama (field 5..), buang field yang diubah
            w=""; bfd=""; dev=""; onlink=""
            for (i=5; i<=NF; i++) {
                if ($i=="weight") { w=$(i+1); i++ }
                else if ($i=="bfd") { bfd="bfd" }
                else if ($i=="dev") { dev=$(i+1); i++ }
                else if ($i=="onlink") { onlink="onlink" }
            }
            if (f=="weight") w=v
            else if (f=="bfd") bfd=(v=="on" ? "bfd" : "")
            else if (f=="dev") dev=v
            else if (f=="onlink") onlink=(v=="on" ? "onlink" : "")
            out="route " p " via " nh
            if (w!="") out=out " weight " w
            if (bfd!="") out=out " bfd"
            if (dev!="") out=out " dev " dev
            if (onlink!="") out=out " onlink"
            print out; next
        }
        { print }
    ' "$CONF" > "$_tmp" || die "cannot write $CONF"
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p via $_nh $_f = $_v"
}

cmd_route_via_iface_add() {
    _p="$1"; _if="$2"
    [ -n "$_p" ] && [ -n "$_if" ] || err "route-via-iface-add butuh PREFIX INTERFACE"
    valid_prefix "$_p"
    case "$_if" in ''|*[!A-Za-z0-9_.-]*) err "interface harus nama interface: $_if" ;; esac
    check_kind_conflict "$_p" via
    if awk -v p="$_p" -v i="$_if" '$1=="route" && $2==p && $3=="via-iface" && $4==i {f=1} END{exit !f}' "$CONF" 2>/dev/null; then
        echo "Static route $_p via \"$_if\" sudah ada"
        return 0
    fi
    touch_conf
    printf 'route %s via-iface %s\n' "$_p" "$_if" >> "$CONF"
    echo "Static route $_p via \"$_if\""
}

cmd_route_via_iface_del() {
    _p="$1"; _if="$2"
    [ -n "$_p" ] && [ -n "$_if" ] || err "route-via-iface-del butuh PREFIX INTERFACE"
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" -v i="$_if" '!($1=="route" && $2==p && $3=="via-iface" && $4==i)' "$CONF" 2>/dev/null > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p via \"$_if\" dihapus"
}

cmd_route_recursive_set() {
    _p="$1"; _nh="$2"
    [ -n "$_p" ] && [ -n "$_nh" ] || err "route-recursive-set butuh PREFIX NEXTHOP"
    valid_prefix "$_p"
    valid_ip "$_nh" "nexthop recursive"
    [ "$(prefix_family "$_p")" = "$(ip_family "$_nh")" ] || \
        err "nexthop $_nh beda keluarga dengan prefix $_p (v4 vs v6)"
    check_kind_conflict "$_p" recursive
    upsert "^route $_p recursive " "route $_p recursive $_nh"
    echo "Static route $_p recursive $_nh"
}

cmd_route_recursive_del() {
    _p="$1"
    [ -n "$_p" ] || err "route-recursive-del butuh PREFIX"
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" '!($1=="route" && $2==p && $3=="recursive")' "$CONF" 2>/dev/null > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p recursive dihapus"
}

# --- mpls per-route (Bab 2.5-4; B14) ---
# `mpls <label>` — label MPLS statis pada route (berlaku untuk via,
# recursive, dan sink; emit sesudah prefix, sebelum nexthop).
# `recursive-mpls <a/b/...>` — stack label untuk nexthop rekursif
# (maks 8 label, maks BIRD 2.2-11); hanya untuk route recursive.
cmd_route_mpls_set() {
    _p="$1"; _n="$2"
    [ -n "$_p" ] && [ -n "$_n" ] || err "route-mpls-set butuh PREFIX LABEL"
    valid_prefix "$_p"
    case "$_n" in ''|*[!0-9]*) err "label MPLS harus bilangan 0..1048575: $_n" ;; esac
    [ "$_n" -le 1048575 ] 2>/dev/null || err "label MPLS harus bilangan 0..1048575: $_n"
    [ "$(route_kind "$_p")" != "none" ] || \
        err "route $_p belum ada — tambah via/recursive/sink dulu sebelum mpls"
    upsert "^route $_p mpls " "route $_p mpls $_n"
    echo "Static route $_p mpls = $_n"
}

cmd_route_mpls_del() {
    _p="$1"
    [ -n "$_p" ] || err "route-mpls-del butuh PREFIX"
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" '!($1=="route" && $2==p && $3=="mpls")' "$CONF" 2>/dev/null > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p mpls dihapus"
}

cmd_route_recursive_mpls_set() {
    _p="$1"; _s="$2"
    [ -n "$_p" ] && [ -n "$_s" ] || err "route-recursive-mpls-set butuh PREFIX STACK"
    valid_prefix "$_p"
    [ "$(route_kind "$_p")" = "recursive" ] || \
        err "route $_p bukan recursive — recursive-mpls hanya untuk route recursive"
    _n=0; _rest="$_s"
    while [ -n "$_rest" ]; do
        case "$_rest" in */*) _one=${_rest%%/*}; _rest=${_rest#*/} ;; *) _one="$_rest"; _rest="" ;; esac
        case "$_one" in ''|*[!0-9]*) err "stack MPLS harus label 0..1048575 dipisah '/': $_s" ;; esac
        [ "$_one" -le 1048575 ] 2>/dev/null || err "label MPLS harus 0..1048575: $_one (stack $_s)"
        _n=$((_n+1))
    done
    [ "$_n" -ge 1 ] && [ "$_n" -le 8 ] || err "stack MPLS maks 8 label (maks BIRD 2.2-11): $_s"
    upsert "^route $_p recursive-mpls " "route $_p recursive-mpls $_s"
    echo "Static route $_p recursive-mpls = $_s"
}

cmd_route_recursive_mpls_del() {
    _p="$1"
    [ -n "$_p" ] || err "route-recursive-mpls-del butuh PREFIX"
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" '!($1=="route" && $2==p && $3=="recursive-mpls")' "$CONF" 2>/dev/null > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p recursive-mpls dihapus"
}

cmd_route_sink_set() {
    _p="$1"; _k="$2"
    [ -n "$_p" ] && [ -n "$_k" ] || err "route-sink-set butuh PREFIX KIND"
    valid_prefix "$_p"
    case "$_k" in
        blackhole|unreachable|prohibit) ;;
        *) err "sink harus blackhole|unreachable|prohibit: $_k" ;;
    esac
    check_kind_conflict "$_p" "$_k"
    # Sink menggantikan sink lama (satu sink per prefix). Ganti DI
    # TEMPAT agar urutan intent tidak berubah tiap replay (dulu hapus +
    # append di akhir — replay memindahkan blackhole ke akhir file;
    # B27-ordering, 18 Nov 2026).
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" -v k="$_k" '
        $1=="route" && $2==p && ($3=="blackhole" || $3=="unreachable" || $3=="prohibit") {
            if (!done) { print "route " p " " k; done=1 }
            next
        }
        { print }
        END { if (!done) print "route " p " " k }
    ' "$CONF" > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p $_k"
}

cmd_route_sink_del() {
    _p="$1"
    [ -n "$_p" ] || err "route-sink-del butuh PREFIX"
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" '!($1=="route" && $2==p && ($3=="blackhole" || $3=="unreachable" || $3=="prohibit"))' "$CONF" 2>/dev/null > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p sink dihapus"
}

cmd_route_attr_set() {
    # route-attr-set <PREFIX> <field> <value>
    # field: ospf-metric1|ospf-metric2|ospf-tag|bgp-community|bgp-large-community|ra-preference|ra-lifetime
    _p="$1"; _f="$2"; _v="$3"
    [ -n "$_p" ] && [ -n "$_f" ] && [ -n "$_v" ] || \
        err "route-attr-set butuh PREFIX FIELD VALUE"
    valid_prefix "$_p"
    case "$_f" in
        ospf-metric1|ospf-metric2|ospf-tag)
            case "$_v" in ''|*[!0-9]*) err "$_f harus bilangan: $_v" ;; esac ;;
        bgp-community)
            case "$_v" in [0-9]*:[0-9]*) ;;
                *) err "bgp-community harus AS:NN (mis. 65535:65281): $_v" ;;
            esac ;;
        bgp-large-community)
            case "$_v" in [0-9]*:[0-9]*:[0-9]*) ;;
                *) err "bgp-large-community harus AA:X:NN (mis. 64512:1:1): $_v" ;;
            esac ;;
        ra-preference)
            case "$_v" in RA_PREF_LOW|RA_PREF_MEDIUM|RA_PREF_HIGH) ;;
                *) err "ra-preference harus RA_PREF_LOW|RA_PREF_MEDIUM|RA_PREF_HIGH: $_v" ;;
            esac ;;
        ra-lifetime)
            case "$_v" in ''|*[!0-9]*) err "ra-lifetime harus bilangan 0..4294967295: $_v" ;; esac
            [ "$_v" -le 4294967295 ] 2>/dev/null || err "ra-lifetime harus 0..4294967295: $_v" ;;
        *) err "field atribut tidak dikenal: $_f (ospf-metric1|ospf-metric2|ospf-tag|bgp-community|bgp-large-community|ra-preference|ra-lifetime)" ;;
    esac
    # Atribut menempel pada route yang SUDAH ada (via/recursive/sink).
    [ "$(route_kind "$_p")" != "none" ] || \
        err "route $_p belum ada — tambah via/recursive/sink dulu sebelum atribut"
    upsert "^route $_p attr $_f " "route $_p attr $_f $_v"
    echo "Static route $_p $_f = $_v"
}

cmd_route_attr_del() {
    _p="$1"; _f="$2"
    [ -n "$_p" ] && [ -n "$_f" ] || err "route-attr-del butuh PREFIX FIELD"
    _tmp="$CONF.tmp.$$"
    awk -v p="$_p" -v f="$_f" '!($1=="route" && $2==p && $3=="attr" && $4==f)' "$CONF" 2>/dev/null > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p $_f dihapus"
}

# --- B13: filter per-route umum (S30, docs §6.17 3e) ---
# Bentuk intent: `route <PREFIX> fstmt <SEQ> <STMT>` — STMT satu token
# (tanpa spasi) dalam bahasa statement filter yang sama dengan filter
# bernama (stmt_to_bird): set:ATTR=NILAI | unset:ATTR |
# method:OBJ.METHOD(args) | accept | reject; atau
# `route <PREFIX> fstmt <SEQ> if <COND> then <THEN> [else <ELSE>]`.
# Urutan eksekusi = urutan SEQ (naik); atribut route-attr-set dicetak
# DULU (kanonik), baru fstmt. Generate menerjemahkan via titian-bgp.sh
# (cond-to-bird + stmt-to-bird); bird -p adalah otoritas akhir.
_next_fstmt_seq() { # <PREFIX> -> SEQ berikutnya (1 bila belum ada)
    _nfs=$(grep "^route $1 fstmt " "$CONF" 2>/dev/null | awk '{print $4}' | sort -n | tail -1)
    [ -n "$_nfs" ] && printf '%s' $((_nfs + 1)) || printf '1'
}
cmd_route_filter_add() { # route-filter-add <PREFIX> <STMT>
    _p="$1"; _s=$(klish_unescape "$2")
    [ -n "$_p" ] && [ -n "$_s" ] || err "route-filter-add butuh PREFIX STMT (satu token, mis. set:ospf_metric1=20)"
    valid_prefix "$_p"
    [ "$(route_kind "$_p")" != "none" ] || \
        err "route $_p belum ada — tambah via/recursive/sink dulu sebelum filter"
    bgp_stmt_to_bird "$_s" >/dev/null || exit 33
    _seq=$(_next_fstmt_seq "$_p")
    _line="route $_p fstmt $_seq $_s"
    touch_conf; _tmp="$CONF.tmp.$$"
    awk -v line="$_line" '$0 != line' "$CONF" > "$_tmp" 2>/dev/null || true
    printf '%s\n' "$_line" >> "$_tmp"
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p filter #$_seq: $_s"
}
cmd_route_filter_if() { # route-filter-if <PREFIX> <COND> <THEN> [ELSE]
    _p="$1"; _c=$(klish_unescape "$2"); _t=$(klish_unescape "$3"); _e=$(klish_unescape "$4")
    [ -n "$_p" ] && [ -n "$_c" ] && [ -n "$_t" ] || err "route-filter-if butuh PREFIX COND THEN [ELSE]"
    valid_prefix "$_p"
    [ "$(route_kind "$_p")" != "none" ] || \
        err "route $_p belum ada — tambah via/recursive/sink dulu sebelum filter"
    cond_validate "$_c" || exit 33
    bgp_stmt_to_bird "$_t" >/dev/null || exit 33
    [ -n "$_e" ] && { bgp_stmt_to_bird "$_e" >/dev/null || exit 33; }
    _seq=$(_next_fstmt_seq "$_p")
    _line="route $_p fstmt $_seq if $_c then $_t"
    [ -n "$_e" ] && _line="$_line else $_e"
    touch_conf; _tmp="$CONF.tmp.$$"
    awk -v line="$_line" '$0 != line' "$CONF" > "$_tmp" 2>/dev/null || true
    printf '%s\n' "$_line" >> "$_tmp"
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    echo "Static route $_p filter #$_seq: if $_c then $_t${_e:+ else $_e}"
}
cmd_route_filter_del() { # route-filter-del <PREFIX> [SEQ] — hapus satu statement / semua
    _p="$1"; _s="$2"
    [ -n "$_p" ] || err "route-filter-del butuh PREFIX [SEQ]"
    _tmp="$CONF.tmp.$$"
    if [ -n "$_s" ]; then
        case "$_s" in ''|*[!0-9]*) err "route-filter-del SEQ harus bilangan: $_s" ;; esac
        awk -v p="$_p" -v s="$_s" '!($1=="route" && $2==p && $3=="fstmt" && $4==s)' "$CONF" 2>/dev/null > "$_tmp" || true
        echo "Static route $_p filter #$_s dihapus"
    else
        awk -v p="$_p" '!($1=="route" && $2==p && $3=="fstmt")' "$CONF" 2>/dev/null > "$_tmp" || true
        echo "Static route $_p semua filter dihapus"
    fi
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
}

# --- B8: Flowspec (RFC 5575, docs §6.17 S16-S29) ---
_flow_num_dec() { # <nilai> -> cetak desimal; gagal -> return 1
    case "$1" in
        0x*) _h=${1#0x}; case "$_h" in ''|*[!0-9a-fA-F]*) return 1 ;; esac; printf '%d' $(( 0x$_h )) 2>/dev/null || return 1 ;;
        ''|*[!0-9]*) return 1 ;;
        *) printf '%s' "$1" ;;
    esac
}
valid_flow_num_atom() { # <atom> <maks> <label>
    _a="$1"; _mx="$2"; _l="$3"
    case "$_a" in true|false) return 0 ;; esac
    case "$_a" in '='*|'!'*|'<'*|'>'*) _a=$(printf '%s' "$_a" | sed 's/^[=!<>]*//') ;; esac
    case "$_a" in
        *..*)
            _lo=${_a%%..*}; _hi=${_a#*..}
            case "$_lo" in ''|*[!0-9]*) err "$_l harus bilangan/rentang: $1" ;; esac
            case "$_hi" in ''|*[!0-9]*) err "$_l harus bilangan/rentang: $1" ;; esac
            [ "$_lo" -le "$_mx" ] 2>/dev/null || err "$_l harus 0..$_mx: $1"
            [ "$_hi" -le "$_mx" ] 2>/dev/null || err "$_l harus 0..$_mx: $1"
            [ "$_lo" -le "$_hi" ] 2>/dev/null || err "$_l range harus A<=B: $1" ;;
        *)
            case "$_a" in ''|*[!0-9]*) err "$_l harus bilangan 0..$_mx: $1" ;; esac
            [ "$_a" -le "$_mx" ] 2>/dev/null || err "$_l harus 0..$_mx: $1" ;;
    esac
}
valid_flow_numbers() { # <nilai> <maks> <label> — numbers-match
    _v="$1"; _mx="$2"; _l="$3"
    [ -n "$_v" ] || err "$_l tidak boleh kosong"
    _norm=$(printf '%s' "$_v" | sed 's/&&/,/g; s/||/,/g')
    _rest="$_norm"
    while [ -n "$_rest" ]; do
        case "$_rest" in *,*) _one=${_rest%%,*}; _rest=${_rest#*,} ;; *) _one="$_rest"; _rest="" ;; esac
        [ -n "$_one" ] || err "$_l mengandung elemen kosong (koma ganda?): $1"
        valid_flow_num_atom "$_one" "$_mx" "$_l"
    done
}
valid_flow_bitmask() { # <nilai> <mask-maks-desimal> <label> — value/mask | !value/mask
    _v="$1"; _mx="$2"; _l="$3"
    _neg=0; case "$_v" in '!'*) _neg=1; _v=${_v#!} ;; esac
    case "$_v" in */*) ;; *) err "$_l bitmask harus value/mask atau !value/mask: $1" ;; esac
    _val=${_v%%/*}; _msk=${_v#*/}
    _vald=$(_flow_num_dec "$_val") || err "$_l bitmask value harus bilangan (desimal/0x): $1"
    _mskd=$(_flow_num_dec "$_msk") || err "$_l bitmask mask harus bilangan (desimal/0x): $1"
    [ "$_vald" -le "$_mx" ] 2>/dev/null || err "$_l bitmask value harus 0..$_mx: $1"
    [ "$_mskd" -le "$_mx" ] 2>/dev/null || err "$_l bitmask mask harus 0..$_mx: $1"
    if [ "$_neg" = "1" ]; then
        { [ "$_vald" -eq 0 ] 2>/dev/null || [ "$_vald" -eq "$_mskd" ] 2>/dev/null; } || err "$_l bitmask negasi (!value/mask) butuh value 0 atau = mask: $1"
    fi
}
valid_flow_fragment() { # <nilai> <label>
    _v="$1"; _l="$2"
    [ -n "$_v" ] || err "$_l tidak boleh kosong"
    _norm=$(printf '%s' "$_v" | sed 's/&&/,/g; s/||/,/g')
    _rest="$_norm"
    while [ -n "$_rest" ]; do
        case "$_rest" in *,*) _one=${_rest%%,*}; _rest=${_rest#*,} ;; *) _one="$_rest"; _rest="" ;; esac
        _one=${_one#!}
        case "$_one" in dont_fragment|is_fragment|first_fragment|last_fragment) ;; *) err "$_l fragment harus dont_fragment|is_fragment|first_fragment|last_fragment (boleh &&/||/!): $1" ;; esac
    done
}
# --- pemecah ctx single-var (refactor persistensi, pola route-map FRR) ---
# Konteks flow view di-encode SATU var `static_flow_ctx` = `<FAM>:<ID>`
# (FAM 4|6 tanpa `:`, ID nama tanpa `:` — split pada `:` PERTAMA).
split_flow_ctx() { # <FAM:ID> -> _CX_FAM _CX_ID
    case "$1" in
        4:*|6:*)
            _CX_FAM="${1%%:*}"; _CX_ID="${1#*:}" ;;
        *) err "ctx flowroute harus <4|6>:<ID>: $1" ;;
    esac
    [ -n "$_CX_ID" ] || err "ctx flowroute butuh ID: $1"
}
# _flow_rate_bits <N>: bilangan bulat byte/detik -> bit IEEE-754 single
# (heksadesimal 0x........) untuk community traffic-rate RFC 5575.
# Teruji vs Python struct.pack('<f') untuk 0,1,1000,1jt,1M,2^23,2^24,
# 123456789, 65535, 2^32-1 (semua cocok).
_flow_rate_bits() {
    awk -v n="$1" 'function bits(x,    e,m,f) {
        if (x == 0) return "0x00000000"
        e = 0; while (x >= 2) { x = x / 2; e++ }
        f = (x - 1) * 8388608; m = int(f + 0.5)
        if (m >= 8388608) { m = 0; e++ }
        return sprintf("0x%08X", (e + 127) * 8388608 + m)
    } BEGIN { print bits(n) }'
}
# emit_flow_actions <FAM> <ID>: cetak baris `bgp_ext_community.add(...)`
# (indent 12 spasi) untuk tiap aksi di intent, urut kemunculan.
# Encoding RFC 5575 (teruji pola bird-flowspec-daemon + Sambuz):
#   rate-limit N  -> (generic, 0x80060000, <floatbits(N)>)
#   discard       -> (generic, 0x80060000, 0x00000000)  (rate 0 = drop)
#   redirect A:NN -> (generic, 0x80080000+A, NN)        (route-target)
#   mark DSCP     -> (generic, 0x80090000, DSCP)        (traffic-marking)
emit_flow_actions() {
    _fam="$1"; _id="$2"
    grep "^flowroute $_fam $_id action " "$CONF" 2>/dev/null | while read -r _ _ _ _ _kind _arg; do
        case "$_kind" in
            rate-limit)
                _bits=$(_flow_rate_bits "$_arg")
                printf '            bgp_ext_community.add((generic, 0x80060000, %s));\n' "$_bits" ;;
            discard)
                printf '            bgp_ext_community.add((generic, 0x80060000, 0x00000000));\n' ;;
            redirect)
                _as=${_arg%%:*}; _nn=${_arg#*:}
                printf '            bgp_ext_community.add((generic, 0x%08X, 0x%08X));\n' $((0x80080000 + _as)) "$_nn" ;;
            mark)
                printf '            bgp_ext_community.add((generic, 0x80090000, 0x%08X));\n' "$_arg" ;;
        esac
    done
}
flow_field_value() { # <FAM> <ID> <field> -> nilai (kolom 5)
    awk -v f="$1" -v i="$2" -v fld="$3" '$1=="flowroute" && $2==f && $3==i && $4==fld {print $5; exit}' "$CONF" 2>/dev/null
}
cmd_flowroute_touch() { # flowroute-touch <CTX FAM:ID>
    split_flow_ctx "$1"
    _fam="$_CX_FAM"; _id="$_CX_ID"
    case "$_fam" in 4|6) ;; *) err "flowroute butuh keluarga 4|6: $_fam" ;; esac
    [ -n "$_id" ] || err "flowroute butuh ID (nama aturan)"
    valid_name "$_id" "flowroute"
    touch_conf
    echo "Static flowroute $_fam $_id"
}
cmd_flowroute_set() { # flowroute-set <CTX FAM:ID> <field> <value>
    split_flow_ctx "$1"; _fam="$_CX_FAM"; _id="$_CX_ID"; _f="$2"; _v="$3"
    case "$_fam" in 4|6) ;; *) err "flowroute butuh keluarga 4|6: $_fam" ;; esac
    [ -n "$_id" ] && [ -n "$_f" ] && [ -n "$_v" ] || err "flowroute-set butuh CTX FIELD VALUE"
    valid_name "$_id" "flowroute"
    case "$_f" in
        action)
            # B.7: aksi flowspec RFC 5575 — SATU baris per jenis (boleh
            # beberapa jenis sekaligus: rate-limit + redirect + mark).
            # Nilai = "<kind> [arg]": rate-limit N | discard |
            # redirect AS:NN | mark DSCP. Di-emit sebagai
            # bgp_ext_community di blok filter route (emit_flowroutes).
            _kind="${_v%% *}"
            case "$_v" in *" "*) _arg="${_v#* }" ;; *) _arg="" ;; esac
            case "$_kind" in
                rate-limit)
                    [ -n "$_arg" ] || err "action rate-limit butuh N (byte/detik)"
                    case "$_arg" in ''|*[!0-9]*) err "rate-limit harus bilangan 0..4294967295: $_arg" ;; esac
                    [ "$_arg" -le 4294967295 ] 2>/dev/null || err "rate-limit harus 0..4294967295: $_arg"
                    upsert "^flowroute $_fam $_id action rate-limit " "flowroute $_fam $_id action rate-limit $_arg" ;;
                discard)
                    upsert "^flowroute $_fam $_id action discard " "flowroute $_fam $_id action discard" ;;
                redirect)
                    [ -n "$_arg" ] || err "action redirect butuh AS:NN (route-target, AS 2-byte)"
                    case "$_arg" in *:*) ;; *) err "redirect harus AS:NN: $_arg" ;; esac
                    _as=${_arg%%:*}; _nn=${_arg#*:}
                    case "$_as" in ''|*[!0-9]*) err "redirect AS harus 1..65535: $_as" ;; esac
                    [ "$_as" -ge 1 ] 2>/dev/null && [ "$_as" -le 65535 ] 2>/dev/null || err "redirect AS harus 1..65535: $_as"
                    case "$_nn" in ''|*[!0-9]*) err "redirect NN harus bilangan 0..4294967295: $_nn" ;; esac
                    [ "$_nn" -le 4294967295 ] 2>/dev/null || err "redirect NN harus 0..4294967295: $_nn"
                    upsert "^flowroute $_fam $_id action redirect " "flowroute $_fam $_id action redirect $_arg" ;;
                mark)
                    [ -n "$_arg" ] || err "action mark butuh DSCP (0..63)"
                    case "$_arg" in ''|*[!0-9]*) err "mark DSCP harus 0..63: $_arg" ;; esac
                    [ "$_arg" -le 63 ] 2>/dev/null || err "mark DSCP harus 0..63: $_arg"
                    upsert "^flowroute $_fam $_id action mark " "flowroute $_fam $_id action mark $_arg" ;;
                *) err "action flowspec tidak dikenal: $_kind (rate-limit|discard|redirect|mark)" ;;
            esac
            echo "Static flowroute $_fam $_id action = $_v"
            return 0 ;;
        dst|src)
            valid_prefix "$_v"
            if [ "$_fam" = "4" ]; then
                case "$_v" in *:* ) err "flowroute $_fam $_f harus prefix IPv4: $_v" ;; esac
            else
                case "$_v" in *:* ) ;; *) err "flowroute $_fam $_f harus prefix IPv6: $_v" ;; esac
            fi ;;
        dst-offset|src-offset)
            [ "$_fam" = "6" ] || err "flowroute $_f hanya untuk flow6 (offset IPv6): $_f"
            case "$_v" in ''|*[!0-9]*) err "$_f harus bilangan 0..128: $_v" ;; esac
            [ "$_v" -le 128 ] 2>/dev/null || err "$_f harus 0..128: $_v" ;;
        proto)
            [ "$_fam" = "4" ] || err "flowroute proto hanya untuk flow4 (flow6 pakai next-header)"
            valid_flow_numbers "$_v" 255 "$_f" ;;
        port|dport|sport) valid_flow_numbers "$_v" 65535 "$_f" ;;
        icmp-type|icmp-code) valid_flow_numbers "$_v" 255 "$_f" ;;
        tcp-flags) valid_flow_bitmask "$_v" 4095 "$_f" ;;
        length) valid_flow_numbers "$_v" 65535 "$_f" ;;
        dscp) valid_flow_numbers "$_v" 63 "$_f" ;;
        fragment) valid_flow_fragment "$_v" "$_f" ;;
        next-header)
            [ "$_fam" = "6" ] || err "flowroute next-header hanya untuk flow6 (flow4 pakai proto)"
            valid_flow_numbers "$_v" 255 "$_f" ;;
        label)
            [ "$_fam" = "6" ] || err "flowroute label hanya untuk flow6"
            # BIRD 2.20: label = SATU nilai 0..0xfffff (tanpa mask).
            # Bentuk value/mask DITOLAK bird -p ("unexpected '/'").
            case "$_v" in */*) err "flowroute label harus satu nilai 0..0xfffff (tanpa mask — BIRD 2.20 menolak value/mask): $_v" ;; esac
            _d=$(_flow_num_dec "$_v") || err "flowroute label harus bilangan (desimal/0x): $_v"
            [ "$_d" -le 1048575 ] 2>/dev/null || err "flowroute label harus 0..0xfffff: $_v" ;;
        *) err "field flowroute tidak dikenal: $_f (dst|dst-offset|src|src-offset|proto|port|dport|sport|icmp-type|icmp-code|tcp-flags|length|dscp|fragment|next-header|label|action)" ;;
    esac
    upsert "^flowroute $_fam $_id $_f " "flowroute $_fam $_id $_f $_v"
    echo "Static flowroute $_fam $_id $_f = $_v"
}
cmd_flowroute_unset() { # flowroute-unset <CTX FAM:ID> <field> [KIND-bila-action]
    split_flow_ctx "$1"; _fam="$_CX_FAM"; _id="$_CX_ID"; _f="$2"; _kind="$3"
    case "$_fam" in 4|6) ;; *) err "flowroute butuh keluarga 4|6: $_fam" ;; esac
    [ -n "$_id" ] && [ -n "$_f" ] || err "flowroute-unset butuh CTX FIELD"
    case "$_f" in
        action)
            [ -n "$_kind" ] || err "flowroute-unset action butuh KIND (rate-limit|discard|redirect|mark)"
            dellines "^flowroute $_fam $_id action $_kind "
            echo "Static flowroute $_fam $_id action $_kind dihapus" ;;
        *)
            dellines "^flowroute $_fam $_id $_f "
            echo "Static flowroute $_fam $_id $_f dihapus (kembali ke default BIRD)" ;;
    esac
}
cmd_flowroute_del() { # flowroute-del <CTX FAM:ID>
    split_flow_ctx "$1"; _fam="$_CX_FAM"; _id="$_CX_ID"
    case "$_fam" in 4|6) ;; *) err "flowroute butuh keluarga 4|6: $_fam" ;; esac
    [ -n "$_id" ] || err "flowroute-del butuh CTX"
    dellines "^flowroute $_fam $_id "
    echo "Static flowroute $_fam $_id dihapus"
}
cmd_flow_table_set() { # flow-table-set <4|6> <NAME>
    # BIRD 2.20: channel flow4 DAN flow6 sama-sama punya opsi table
    # (`flow4 { table <name>; };` teruji bird -p exit 0). Koreksi F3.2:
    # klaim lama "flow4 tidak punya opsi table" (docs §6.17 S4) SALAH
    # untuk BIRD 2.20 — tanpa table, channel flow ditolak
    # ("Routing table not specified").
    _fam="$1"; _name="$2"
    case "$_fam" in 4|6) ;; *) err "flow-table-set butuh FAM 4|6 + NAMA" ;; esac
    [ -n "$_name" ] || err "flow-table-set butuh FAM NAMA"
    valid_name "$_name" "flow-table"
    _gfile="$STATE_ROOT/bird-global.conf"
    [ -f "$_gfile" ] || err "flow-table $_name belum didefinisikan (bird-global.conf belum ada — definisikan dulu: global -> table-add flow$_fam $_name)"
    grep -q "^table flow$_fam $_name\$" "$_gfile" 2>/dev/null || \
        err "flow-table $_name bukan tabel flow$_fam di bird-global.conf (global -> table-add flow$_fam $_name)"
    upsert "^flow-table $_fam " "flow-table $_fam $_name"
    echo "Static flow-table $_fam = $_name"
}
cmd_flow_table_del() { # flow-table-del <4|6>
    _fam="$1"
    case "$_fam" in 4|6) ;; *) err "flow-table-del butuh FAM 4|6" ;; esac
    dellines "^flow-table $_fam "
    echo "Static flow-table $_fam dihapus"
}

cmd_mpls_table_set() { # mpls-table-set <NAME>
    # BIRD 2.20: route berlabel MPLS butuh channel `mpls` DAN tabel MPLS
    # DAN domain MPLS (B14, Bab 2.5-4 — teruji bird -p rc=0):
    #   tanpa channel -> "Route ... has MPLS label, but MPLS channel not specified"
    #   tanpa table   -> "Routing table not specified"
    #   tanpa domain  -> "No MPLS domain defined"
    # Tabel + domain didefinisikan di bird global view (B6):
    #   table-add mpls <NAMA>  +  mpls-domain-add <NAMA>.
    _name="$1"
    [ -n "$_name" ] || err "mpls-table-set butuh NAMA"
    valid_name "$_name" "mpls-table"
    _gfile="$STATE_ROOT/bird-global.conf"
    [ -f "$_gfile" ] || err "mpls-table $_name belum didefinisikan (bird-global.conf belum ada — definisikan dulu: global -> table-add mpls $_name)"
    grep -q "^table mpls $_name\$" "$_gfile" 2>/dev/null || \
        err "mpls-table $_name bukan tabel mpls di bird-global.conf (global -> table-add mpls $_name)"
    grep -q '^mpls domain ' "$_gfile" 2>/dev/null || \
        err "belum ada MPLS domain di bird-global.conf — definisikan dulu: global -> mpls-domain-add <NAMA>"
    upsert "^mpls-table " "mpls-table $_name"
    echo "Static mpls-table = $_name"
}
cmd_mpls_table_del() { # mpls-table-del
    dellines "^mpls-table "
    echo "Static mpls-table dihapus"
}
# emit_flowroutes <FAM>: cetak blok `route flow4/6 { ... };` per ID.
emit_flowroutes() {
    _fam="$1"
    set -f
    for _id in $(grep "^flowroute $_fam " "$CONF" 2>/dev/null | awk '{print $3}' | awk '!s[$0]++'); do
        _dst=$(flow_field_value "$_fam" "$_id" dst)
        _dstoff=$(flow_field_value "$_fam" "$_id" dst-offset)
        _src=$(flow_field_value "$_fam" "$_id" src)
        _srcoff=$(flow_field_value "$_fam" "$_id" src-offset)
        if [ "$_fam" = "4" ]; then
            [ -n "$_dst" ] || err "flowroute 4 $_id: dst WAJIB untuk flow4 (docs §6.17 S16)"
        else
            _ncomp=$(grep -c "^flowroute $_fam $_id " "$CONF" 2>/dev/null)
            [ "$_ncomp" -ge 1 ] 2>/dev/null || err "flowroute 6 $_id: butuh minimal 1 komponen"
        fi
        printf '    route flow%s {\n' "$_fam"
        [ -n "$_dst" ] && { printf '        dst %s' "$_dst"; [ -n "$_dstoff" ] && printf ' offset %s' "$_dstoff"; printf ';\n'; }
        [ -n "$_src" ] && { printf '        src %s' "$_src"; [ -n "$_srcoff" ] && printf ' offset %s' "$_srcoff"; printf ';\n'; }
        _v=$(flow_field_value "$_fam" "$_id" proto); [ -n "$_v" ] && printf '        proto %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" port); [ -n "$_v" ] && printf '        port %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" dport); [ -n "$_v" ] && printf '        dport %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" sport); [ -n "$_v" ] && printf '        sport %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" icmp-type); [ -n "$_v" ] && printf '        icmp type %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" icmp-code); [ -n "$_v" ] && printf '        icmp code %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" tcp-flags); [ -n "$_v" ] && printf '        tcp flags %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" length); [ -n "$_v" ] && printf '        length %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" dscp); [ -n "$_v" ] && printf '        dscp %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" fragment); [ -n "$_v" ] && printf '        fragment %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" next-header); [ -n "$_v" ] && printf '        next header %s;\n' "$_v"
        _v=$(flow_field_value "$_fam" "$_id" label); [ -n "$_v" ] && printf '        label %s;\n' "$_v"
        # B.7: bila ada aksi, route ditutup dengan blok filter kedua
        # (`} { bgp_ext_community.add(...); };`) — bentuk standar BIRD
        # untuk atribut route statis (teruji pola bird-flowspec-daemon).
        _acts=$(emit_flow_actions "$_fam" "$_id")
        if [ -n "$_acts" ]; then
            printf '    } {\n%s\n    };\n' "$_acts"
        else
            printf '    };\n'
        fi
    done
    set +f
}

# --- generate ---
# emit_attrs <prefix>: cetak statement atribut BIRD (satu per baris,
# indent 12 spasi) untuk blok filter per-route.
emit_attrs() {
    _p="$1"
    awk -v p="$_p" '$1=="route" && $2==p && $3=="attr" {
        if ($4=="ospf-metric1") print "            ospf_metric1 = " $5 ";"
        else if ($4=="ospf-metric2") print "            ospf_metric2 = " $5 ";"
        else if ($4=="ospf-tag") print "            ospf_tag = " $5 ";"
        else if ($4=="bgp-community") {
            split($5, c, ":"); print "            bgp_community.add((" c[1] ", " c[2] "));"
        } else if ($4=="bgp-large-community") {
            split($5, c, ":"); print "            bgp_large_community.add((" c[1] ", " c[2] ", " c[3] "));"
        } else if ($4=="ra-preference") print "            ra_preference = " $5 ";"
          else if ($4=="ra-lifetime") print "            ra_lifetime = " $5 ";"
    }' "$CONF" 2>/dev/null
}

# emit_fstmts <prefix>: cetak statement filter umum (satu per baris,
# indent 12 spasi) dari intent `route <P> fstmt <SEQ> ...`, urut SEQ naik.
# Diterjemahkan via titian-bgp.sh (cond-to-bird + stmt-to-bird); gagal
# -> return 33 (generate berhenti; bird -p otoritas akhir).
emit_fstmts() {
    _p="$1"
    _ftmp="$CONF.fstmt.$$"
    grep "^route $_p fstmt " "$CONF" 2>/dev/null | sort -t' ' -k4,4n > "$_ftmp" || true
    _frc=0
    while IFS= read -r _fl; do
        [ -n "$_fl" ] || continue
        _fr=${_fl#*fstmt }
        _fr=${_fr#* }
        case "$_fr" in
            'if '*)
                _fr2=${_fr#if }
                _fc=${_fr2%%' then '*}
                _fr3=${_fr2#*' then '}
                case "$_fr3" in
                    *' else '*)
                        _ft=${_fr3%%' else '*}; _fe=${_fr3#*' else '}
                        _fbc=$(bgp_cond_to_bird "$_fc") || { _frc=33; break; }
                        _fbt=$(bgp_stmt_to_bird "$_ft") || { _frc=33; break; }
                        _fbe=$(bgp_stmt_to_bird "$_fe") || { _frc=33; break; }
                        printf '            if %s then %s; else %s;\n' "$_fbc" "$_fbt" "$_fbe"
                        ;;
                    *)
                        _fbc=$(bgp_cond_to_bird "$_fc") || { _frc=33; break; }
                        _fbt=$(bgp_stmt_to_bird "$_fr3") || { _frc=33; break; }
                        printf '            if %s then %s;\n' "$_fbc" "$_fbt"
                        ;;
                esac
                ;;
            *)
                _fbs=$(bgp_stmt_to_bird "$_fr") || { _frc=33; break; }
                printf '            %s;\n' "$_fbs"
                ;;
        esac
    done < "$_ftmp"
    rm -f "$_ftmp"
    return $_frc
}

# emit_routes <family 4|6>: cetak statement `route ...;` untuk prefix
# keluarga itu, urut kemunculan pertama di intent.
emit_routes() {
    _fam="$1"
    set -f
    for _p in $(grep '^route ' "$CONF" 2>/dev/null | awk '{print $2}' | awk '!s[$0]++'); do
        [ "$(prefix_family "$_p")" = "$_fam" ] || continue
        _attrs=$(emit_attrs "$_p")
        _fstmts=$(emit_fstmts "$_p") || exit 33
        _sink=$(awk -v p="$_p" '$1=="route" && $2==p && ($3=="blackhole" || $3=="unreachable" || $3=="prohibit") {print $3; exit}' "$CONF" 2>/dev/null)
        _rec=$(awk -v p="$_p" '$1=="route" && $2==p && $3=="recursive" {print $4; exit}' "$CONF" 2>/dev/null)
        # MPLS per-route (B14, Bab 2.5-4): label statis sesudah prefix;
        # stack rekursif sesudah nexthop recursive.
        _mpls=$(awk -v p="$_p" '$1=="route" && $2==p && $3=="mpls" {print $4; exit}' "$CONF" 2>/dev/null)
        _rmpls=$(awk -v p="$_p" '$1=="route" && $2==p && $3=="recursive-mpls" {print $4; exit}' "$CONF" 2>/dev/null)
        if [ -n "$_sink" ]; then
            _stmt="    route $_p${_mpls:+ mpls $_mpls} $_sink"
        elif [ -n "$_rec" ]; then
            _stmt="    route $_p${_mpls:+ mpls $_mpls} recursive $_rec${_rmpls:+ mpls $_rmpls}"
        else
            _stmt="    route $_p${_mpls:+ mpls $_mpls}"
            # via IP (urut file) + via interface
            _stmt="$_stmt$(awk -v p="$_p" '$1=="route" && $2==p && $3=="via" {
                s=" via " $4
                for (i=5; i<=NF; i++) {
                    if ($i=="weight") { s=s " weight " $(i+1); i++ }
                    else if ($i=="bfd") { s=s " bfd" }
                    else if ($i=="dev") { s=s " dev \"" $(i+1) "\""; i++ }
                    else if ($i=="onlink") { s=s " onlink" }
                }
                printf "%s", s
            }' "$CONF" 2>/dev/null)"
            _stmt="$_stmt$(awk -v p="$_p" '$1=="route" && $2==p && $3=="via-iface" { printf " via \"%s\"", $4 }' "$CONF" 2>/dev/null)"
        fi
        _block="$_attrs"
        [ -n "$_block" ] && [ -n "$_fstmts" ] && _block="$_block
$_fstmts"
        [ -z "$_block" ] && _block="$_fstmts"
        if [ -n "$_block" ]; then
            printf '%s {\n%s\n    };\n' "$_stmt" "$_block"
        else
            printf '%s;\n' "$_stmt"
        fi
    done
    set +f
}

# valid_spec <SPEC> <debug|mrtdump> — validasi daftar kelas koma (Bab 3.4-2/3,
# salinan _rip_valid_spec; B9).
valid_spec() {
    _vs_spec="$1"; _vs_kind="$2"
    [ -n "$_vs_spec" ] || err "$_vs_kind butuh all|off|kelas,kelas,..."
    case "$_vs_spec" in all|off) return 0 ;; esac
    _vs_rest="$_vs_spec"
    while [ -n "$_vs_rest" ]; do
        case "$_vs_rest" in *,*) _vs_done=${_vs_rest%%,*}; _vs_rest=${_vs_rest#*,} ;; *) _vs_done="$_vs_rest"; _vs_rest="" ;; esac
        if [ "$_vs_kind" = "debug" ]; then
            case "$_vs_done" in states|routes|filters|interfaces|events|packets) ;; *) err "debug kelas tidak dikenal: $_vs_done (boleh: states|routes|filters|interfaces|events|packets)" ;; esac
        else
            case "$_vs_done" in states|messages) ;; *) err "mrtdump kelas tidak dikenal: $_vs_done (boleh: states|messages)" ;; esac
        fi
    done
}
# emit_dbg <SPEC> <debug|mrtdump> — satu baris debug/mrtdump (indent 4 spasi).
emit_dbg() {
    case "$1" in all|off) echo "    $2 $1;" ;; *) echo "    $2 { $(printf '%s' "$1" | sed 's/,/, /g') };" ;; esac
}

# emit_static_head <NAMA> — header `protocol static <NAMA> [from <T> {]`
# + opsi global (disabled, check link, igp table, debug, mrtdump).
# Memakai variabel generate: _from, _dis, _checklink, _igp, _dbg, _mrt.
emit_static_head() {
    if [ -n "$_from" ]; then echo "protocol static $1 from $_from {"; else echo "protocol static $1 {"; fi
    case "$_dis" in on) echo "    disabled;" ;; esac
    [ "$_checklink" = "on" ] && echo "    check link;"
    [ -n "$_igp" ] && echo "    igp table $_igp;"
    [ -n "$_dbg" ] && emit_dbg "$_dbg" debug
    [ -n "$_mrt" ] && emit_dbg "$_mrt" mrtdump
}

# emit_static_channel <ipv4|ipv6> — blok channel bila ada opsi
# (preference/import/export), else baris `<ch>;` polos. Default BIRD
# Bab 3.5 bila channel diekspos: import all, export none.
emit_static_channel() {
    _sc="$1"
    _pref=$(grep "^channel $_sc preference " "$CONF" 2>/dev/null | head -1 | awk '{print $4}')
    _imp=$(grep "^channel $_sc import " "$CONF" 2>/dev/null | head -1 | awk '{$1=""; $2=""; $3=""; sub(/^ +/, ""); print}')
    _exp=$(grep "^channel $_sc export " "$CONF" 2>/dev/null | head -1 | awk '{$1=""; $2=""; $3=""; sub(/^ +/, ""); print}')
    if [ -z "$_pref" ] && [ -z "$_imp" ] && [ -z "$_exp" ]; then
        echo "    $_sc;"
        return 0
    fi
    echo "    $_sc {"
    [ -n "$_pref" ] && echo "        preference $_pref;"
    if [ -n "$_imp" ]; then
        case "$_imp" in
            where\ *) _wcond=${_imp#where }; _wbird=$(cond_translate "$_wcond") || exit 33; echo "        import where $_wbird;" ;;
            *) echo "        import $_imp;" ;;
        esac
    else
        echo "        import all;"
    fi
    if [ -n "$_exp" ]; then
        case "$_exp" in
            where\ *) _wcond=${_exp#where }; _wbird=$(cond_translate "$_wcond") || exit 33; echo "        export where $_wbird;" ;;
            *) echo "        export $_exp;" ;;
        esac
    else
        echo "        export none;"
    fi
    echo "    };"
}

# valid_asn <nilai> <label> — AS 1..4294967295 (B9; script ini belum punya).
valid_asn() {
    case "$1" in ''|*[!0-9]*) err "$2 harus AS 1..4294967295: $1" ;; esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 4294967295 ] 2>/dev/null || err "$2 harus AS 1..4294967295: $1"
}

cmd_debug_set() { # B9: debug-set SPEC (Bab 3.4-2)
    [ -n "$1" ] || err "debug butuh all|off|kelas,kelas,..."
    valid_spec "$1" debug
    upsert '^debug ' "debug $1"
    echo "Static debug = $1"
}
cmd_debug_del() {
    dellines '^debug '
    echo "Static debug dihapus (default BIRD off)"
}
cmd_mrtdump_set() { # B9: mrtdump-set SPEC (Bab 3.4-3)
    [ -n "$1" ] || err "mrtdump butuh all|off|states,messages"
    valid_spec "$1" mrtdump
    upsert '^mrtdump ' "mrtdump $1"
    echo "Static mrtdump = $1"
}
cmd_mrtdump_del() {
    dellines '^mrtdump '
    echo "Static mrtdump dihapus (default BIRD off)"
}
cmd_roa_add() { # B9: roa-add PREFIX MAXLEN AS [TABLE] (S8)
    _p="$1"; _m="$2"; _a="$3"; _t="$4"
    [ -n "$_p" ] && [ -n "$_m" ] && [ -n "$_a" ] || err "roa-add butuh PREFIX MAXLEN AS [TABLE]"
    valid_prefix "$_p"
    case "$_m" in ''|*[!0-9]*) err "roa max-length harus bilangan: $_m" ;; esac
    _plen=${_p#*/}; _fam=$(prefix_family "$_p")
    [ "$_m" -ge "$_plen" ] 2>/dev/null || err "roa max-length ($_m) tidak boleh < prefix length ($_plen)"
    if [ "$_fam" = "4" ]; then [ "$_m" -le 32 ] 2>/dev/null || err "roa max-length IPv4 harus <= 32: $_m"
    else [ "$_m" -le 128 ] 2>/dev/null || err "roa max-length IPv6 harus <= 128: $_m"; fi
    valid_asn "$_a" "roa AS"
    [ -n "$_t" ] && valid_name "$_t" "roa table"
    dellines "^roa $_p "
    if [ -n "$_t" ]; then printf 'roa %s %s %s %s\n' "$_p" "$_m" "$_a" "$_t" >> "$CONF"
    else printf 'roa %s %s %s\n' "$_p" "$_m" "$_a" >> "$CONF"; fi
    chmod 600 "$CONF" 2>/dev/null || true
    echo "Static ROA $_p max $_m as $_a${_t:+ table $_t}"
}
cmd_roa_del() { # B9: roa-del PREFIX
    [ -n "$1" ] || err "roa-del butuh PREFIX"
    dellines "^roa $1 "
    echo "Static ROA $1 dihapus"
}
cmd_aspa_providers_add() { # B9: aspa-providers-add ASN LIST [TABLE] (S9)
    _a="$1"; _l="$2"; _t="$3"
    [ -n "$_a" ] && [ -n "$_l" ] || err "aspa-providers-add butuh ASN LIST [TABLE]"
    valid_asn "$_a" "aspa client ASN"
    _rest="$_l"
    while [ -n "$_rest" ]; do
        case "$_rest" in *,*) _one=${_rest%%,*}; _rest=${_rest#*,} ;; *) _one="$_rest"; _rest="" ;; esac
        valid_asn "$_one" "aspa provider ASN"
    done
    [ -n "$_t" ] && valid_name "$_t" "aspa table"
    dellines "^aspa providers $_a "
    dellines "^aspa transit $_a\$"
    if [ -n "$_t" ]; then printf 'aspa providers %s %s %s\n' "$_a" "$_l" "$_t" >> "$CONF"
    else printf 'aspa providers %s %s\n' "$_a" "$_l" >> "$CONF"; fi
    chmod 600 "$CONF" 2>/dev/null || true
    echo "Static ASPA $_a providers $_l${_t:+ table $_t}"
}
cmd_aspa_transit_add() { # B9: aspa-transit-add ASN [TABLE] (S9)
    _a="$1"; _t="$2"
    [ -n "$_a" ] || err "aspa-transit-add butuh ASN [TABLE]"
    valid_asn "$_a" "aspa client ASN"
    [ -n "$_t" ] && valid_name "$_t" "aspa table"
    dellines "^aspa providers $_a "
    dellines "^aspa transit $_a\$"
    if [ -n "$_t" ]; then printf 'aspa transit %s %s\n' "$_a" "$_t" >> "$CONF"
    else printf 'aspa transit %s\n' "$_a" >> "$CONF"; fi
    chmod 600 "$CONF" 2>/dev/null || true
    echo "Static ASPA $_a transit${_t:+ table $_t}"
}
cmd_aspa_del() { # B9: aspa-del ASN
    [ -n "$1" ] || err "aspa-del butuh ASN"
    dellines "^aspa providers $1 "
    dellines "^aspa transit $1\$"
    echo "Static ASPA $1 dihapus"
}
# resolve_roa_table <NETTYPE> -> nama tabel pertama di bird-global.conf.
resolve_roa_table() {
    grep "^table $1 " "$STATE_ROOT/bird-global.conf" 2>/dev/null | head -1 | awk '{print $3}'
}
# emit_roa_aspa — blok instance static-roa4/roa6/aspa (B9, S8/S9).
emit_roa_aspa() {
    _dbg="$1"; _mrt="$2"
    set -f
    for _fam in 4 6; do
        for _tab in $(grep "^roa " "$CONF" 2>/dev/null | awk -v f="$_fam" '{ if (($2 ~ /:/ && f==6) || ($2 !~ /:/ && f==4)) print ($5=="" ? "__NOTABLE__" : $5) }' | awk '!s[$0]++'); do
            [ "$_tab" = "__NOTABLE__" ] && _tab=""
            if [ -z "$_tab" ]; then
                _tab=$(resolve_roa_table "roa$_fam")
                [ -n "$_tab" ] || err "static ROA IPv$_fam tanpa tabel: buat dulu tabel roa$_fam (global table-add roa$_fam <nama>) atau isi param TABLE di roa-route"
            fi
            echo "protocol static static_roa${_fam}_$_tab {"
            [ -n "$_dbg" ] && emit_dbg "$_dbg" debug
            [ -n "$_mrt" ] && emit_dbg "$_mrt" mrtdump
            echo "    roa$_fam { table $_tab; };"
            _first=$(resolve_roa_table "roa$_fam")
            grep "^roa " "$CONF" 2>/dev/null | awk -v f="$_fam" -v t="$_tab" -v first="$_first" '{ tab=($5=="" ? "" : $5); if ((($2 ~ /:/ && f==6) || ($2 !~ /:/ && f==4)) && ((tab=="" && t==first) || tab==t)) printf "    route %s max %s as %s;\n", $2, $3, $4 }'
            echo "}"
            echo ""
        done
    done
    for _tab in $(grep "^aspa " "$CONF" 2>/dev/null | awk '{print ($5=="" ? "__NOTABLE__" : $5)}' | awk '!s[$0]++'); do
        [ "$_tab" = "__NOTABLE__" ] && _tab=""
        if [ -z "$_tab" ]; then
            _tab=$(resolve_roa_table aspa)
            [ -n "$_tab" ] || err "static ASPA tanpa tabel: buat dulu tabel aspa (global table-add aspa <nama>) atau isi param TABLE di aspa-route"
        fi
        echo "protocol static static_aspa_$_tab {"
        [ -n "$_dbg" ] && emit_dbg "$_dbg" debug
        [ -n "$_mrt" ] && emit_dbg "$_mrt" mrtdump
        echo "    aspa { table $_tab; };"
        _first=$(resolve_roa_table aspa)
        grep "^aspa " "$CONF" 2>/dev/null | awk -v t="$_tab" -v first="$_first" '{ tab=($5=="" ? "" : $5); if ((tab=="" && t==first) || tab==t) { if ($2=="providers") printf "    route aspa %s providers %s;\n", $3, $4; else printf "    route aspa %s transit;\n", $3 } }'
        echo "}"
        echo ""
    done
    set +f
}

cmd_generate() {
    touch_conf
    set -f
    mkdir -p "$SECTION_DIR" 2>/dev/null || die "cannot mkdir $SECTION_DIR"
    _tmp="$SECTION.tmp.$$"
    if has_facts; then
        # BFD per-nexthop butuh `protocol bfd` — sama seperti BGP:
        # tolak dengan pesan jelas bila tidak ada config BFD.
        if grep -q '^route .* via .* bfd' "$CONF" 2>/dev/null; then
            _bfds="$(dirname "$0")/titian-bfd.sh"
            if [ -x "$_bfds" ]; then
                "$_bfds" has-facts || err "static route memakai BFD per-nexthop tapi protocol bfd belum dikonfigurasi (router bird -> bfd -> interface ...)"
            else
                err "static route memakai BFD tapi $_bfds tidak ditemukan"
            fi
        fi
        _checklink=$(grep '^check-link ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
        _igp=$(grep '^igp-table ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
        _dbg=$(grep '^debug ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
        _mrt=$(grep '^mrtdump ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
        _dis=$(grep '^disabled ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
        _from=$(grep '^from ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
        # `from` wajib merujuk template static yang ada di bird-global.conf
        # (template hanya didefinisikan di sana; bila belum ada, gagal jelas).
        if [ -n "$_from" ]; then
            _gf="$STATE_ROOT/bird-global.conf"
            [ -f "$_gf" ] && grep -q "^template static $_from\( \|$\)" "$_gf" 2>/dev/null || \
                err "static: from template static $_from tidak ada di bird-global.conf (template-add static $_from dulu)"
        fi
        _has4=$(grep '^route ' "$CONF" 2>/dev/null | awk '{print $2}' | grep -v ':' | head -1)
        _has6=$(grep '^route ' "$CONF" 2>/dev/null | awk '{print $2}' | grep ':' | head -1)
        # Flowroute = instance TERPISAH (BIRD 2.20: satu protocol static
        # hanya boleh satu tipe channel — "Different channel type" bila
        # ipv4+flow4 atau ipv6+flow6 dicampur). staticflow4/staticflow6
        # WAJIB punya tabel (tanpa table: "Routing table not specified").
        _hasflow4=""
        _hasflow6=""
        [ -n "$(grep '^flowroute 4 ' "$CONF" 2>/dev/null | head -1)" ] && _hasflow4="flow4"
        [ -n "$(grep '^flowroute 6 ' "$CONF" 2>/dev/null | head -1)" ] && _hasflow6="flow6"
        [ -n "$(grep '^flow-table 4 ' "$CONF" 2>/dev/null | head -1)" ] && _hasflow4="flow4"
        [ -n "$(grep '^flow-table 6 ' "$CONF" 2>/dev/null | head -1)" ] && _hasflow6="flow6"
        _flowtab4=$(grep '^flow-table 4 ' "$CONF" 2>/dev/null | head -1 | awk '{print $3}')
        _flowtab6=$(grep '^flow-table 6 ' "$CONF" 2>/dev/null | head -1 | awk '{print $3}')
        [ -n "$_hasflow4" ] && [ -z "$_flowtab4" ] && err "static flow4 butuh tabel (flow-table-set 4 <NAMA> dulu — tanpa table BIRD menolak: Routing table not specified)"
        [ -n "$_hasflow6" ] && [ -z "$_flowtab6" ] && err "static flow6 butuh tabel (flow-table-set 6 <NAMA> dulu — tanpa table BIRD menolak: Routing table not specified)"
        # MPLS per-route (B14, Bab 2.5-4): route berlabel butuh channel
        # `mpls` + tabel + domain; tanpa ketiganya BIRD menolak config.
        _mpls4=""; _mpls6=""
        for _p in $(grep '^route ' "$CONF" 2>/dev/null | awk '$3=="mpls" || $3=="recursive-mpls" {print $2}' | awk '!s[$0]++'); do
            case "$_p" in *:* ) _mpls6=1 ;; *) _mpls4=1 ;; esac
        done
        _mplstab=$(grep '^mpls-table ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
        if [ -n "$_mpls4" ] || [ -n "$_mpls6" ]; then
            [ -n "$_mplstab" ] || err "static route berlabel MPLS tapi mpls-table belum diset (mpls-table-set <NAMA> dulu — tanpa table BIRD menolak: Routing table not specified)"
            _gfile="$STATE_ROOT/bird-global.conf"
            grep -q "^table mpls $_mplstab\$" "$_gfile" 2>/dev/null || \
                err "mpls-table $_mplstab bukan tabel mpls di bird-global.conf (global -> table-add mpls $_mplstab)"
            grep -q '^mpls domain ' "$_gfile" 2>/dev/null || \
                err "static route berlabel MPLS tapi belum ada MPLS domain di bird-global.conf (global -> mpls-domain-add <NAMA> dulu — tanpa domain BIRD menolak: No MPLS domain defined)"
        fi
        {
            echo "# static.conf - generated by titian-static.sh, do not edit by hand"
            if [ -n "$_has4" ]; then
                emit_static_head static4
                emit_static_channel ipv4
                [ -n "$_mpls4" ] && echo "    mpls { table $_mplstab; import all; export all; };"
                emit_routes 4
                echo "}"
                echo ""
            fi
            if [ -n "$_hasflow4" ]; then
                echo "protocol static staticflow4 {"
                echo "    flow4 { table $_flowtab4; };"
                emit_flowroutes 4
                echo "}"
                echo ""
            fi
            if [ -n "$_has6" ]; then
                emit_static_head static6
                emit_static_channel ipv6
                [ -n "$_mpls6" ] && echo "    mpls { table $_mplstab; import all; export all; };"
                emit_routes 6
                echo "}"
                echo ""
            fi
            if [ -n "$_hasflow6" ]; then
                echo "protocol static staticflow6 {"
                echo "    flow6 { table $_flowtab6; };"
                emit_flowroutes 6
                echo "}"
                echo ""
            fi
            if [ -z "$_has4" ] && [ -z "$_hasflow4" ] && [ -z "$_has6" ] && [ -z "$_hasflow6" ]; then
                # Hanya opsi global (check-link/igp-table/debug/mrtdump),
                # tanpa route: satu instance v4 agar opsi tetap hidup.
                emit_static_head static4
                emit_static_channel ipv4
                echo "}"
                echo ""
            fi
            emit_roa_aspa "$_dbg" "$_mrt"
        } > "$_tmp" || die "cannot write $_tmp"
    else
        {
            echo "# static.conf - generated by titian-static.sh, do not edit by hand"
            echo "# (tidak ada config static — protocol static tidak dibuat)"
        } > "$_tmp" || die "cannot write $_tmp"
    fi
    mv "$_tmp" "$SECTION" || die "cannot write $SECTION"
    chmod 644 "$SECTION" 2>/dev/null || true
    set +f
    echo "Static section ditulis: $SECTION"
    _birdsh="$(dirname "$0")/titian-bird.sh"
    if [ -x "$_birdsh" ]; then
        "$_birdsh" generate static || exit 33
    else
        echo "Warning: $_birdsh tidak ditemukan; section hanya ditulis, belum di-apply" >&2
    fi
}

birdc_bin() {
    command -v birdc 2>/dev/null || { [ -x /usr/sbin/birdc ] && echo /usr/sbin/birdc; } || \
        { [ -x /usr/local/sbin/birdc ] && echo /usr/local/sbin/birdc; } || echo birdc
}
# birdc_sock — salinan titian-birdc.sh (BC8, B13): cetak "-s <path>" bila
# socket utama dikonfigurasi via klish ($STATE_ROOT/birdc.conf), kosong bila
# default. Dipakai semua pemanggilan birdc di file ini.
birdc_sock() {
    _s=$(grep '^socket ' "$STATE_ROOT/birdc.conf" 2>/dev/null | head -1 | cut -d' ' -f2-)
    [ -n "$_s" ] && printf '%s' "-s $_s"
}


cmd_show() {
    touch_conf
    echo "--- static.conf (intent) ---"
    cat "$CONF"
    echo "--- bird.d/static.conf (section, bila ada) ---"
    [ -f "$SECTION" ] && cat "$SECTION" || echo "(belum di-generate)"
    echo "--- birdc show protocol static ---"
    _birdc=$(birdc_bin)
    _done=0
    for _inst in static4 static6; do
        if grep -q "protocol static $_inst" "$SECTION" 2>/dev/null; then
            if _out=$("$_birdc" $(birdc_sock) show protocol "$_inst" 2>&1); then
                echo "$_out" | grep -v '^BIRD'
                _done=1
            fi
        fi
    done
    [ "$_done" = "0" ] && echo "(BIRD tidak jalan / belum ada instance static — birdc show protocol gagal)"
    return 0
}

case "$1" in
    static-touch) cmd_static_touch ;;
    has-facts) has_facts ;;
    debug-set) shift; cmd_debug_set "$@" ;;
    debug-del) cmd_debug_del ;;
    mrtdump-set) shift; cmd_mrtdump_set "$@" ;;
    mrtdump-del) cmd_mrtdump_del ;;
    roa-add) shift; cmd_roa_add "$@" ;;
    roa-del) shift; cmd_roa_del "$@" ;;
    aspa-providers-add) shift; cmd_aspa_providers_add "$@" ;;
    aspa-transit-add) shift; cmd_aspa_transit_add "$@" ;;
    aspa-del) shift; cmd_aspa_del "$@" ;;
    check-link-set) shift; cmd_check_link_set "$@" ;;
    igp-table-set) shift; cmd_igp_table_set "$@" ;;
    igp-table-del) cmd_igp_table_del ;;
    disabled-set) shift; cmd_disabled_set "$@" ;;
    disabled-del) cmd_disabled_del ;;
    from-set) shift; cmd_from_set "$@" ;;
    from-del) cmd_from_del ;;
    channel-set) shift; cmd_channel_set "$@" ;;
    channel-del) shift; cmd_channel_del "$@" ;;
    route-touch) shift; cmd_route_touch "$@" ;;
    route-del) shift; cmd_route_del "$@" ;;
    route-via-add) shift; cmd_route_via_add "$@" ;;
    route-via-del) shift; cmd_route_via_del "$@" ;;
    route-via-set) shift; cmd_route_via_set "$@" ;;
    route-via-iface-add) shift; cmd_route_via_iface_add "$@" ;;
    route-via-iface-del) shift; cmd_route_via_iface_del "$@" ;;
    route-recursive-set) shift; cmd_route_recursive_set "$@" ;;
    route-recursive-del) shift; cmd_route_recursive_del "$@" ;;
    route-mpls-set) shift; cmd_route_mpls_set "$@" ;;
    route-mpls-del) shift; cmd_route_mpls_del "$@" ;;
    route-recursive-mpls-set) shift; cmd_route_recursive_mpls_set "$@" ;;
    route-recursive-mpls-del) shift; cmd_route_recursive_mpls_del "$@" ;;
    route-sink-set) shift; cmd_route_sink_set "$@" ;;
    route-sink-del) shift; cmd_route_sink_del "$@" ;;
    route-attr-set) shift; cmd_route_attr_set "$@" ;;
    route-attr-del) shift; cmd_route_attr_del "$@" ;;
    route-filter-add) shift; cmd_route_filter_add "$@" ;;
    route-filter-if) shift; cmd_route_filter_if "$@" ;;
    route-filter-del) shift; cmd_route_filter_del "$@" ;;
    flowroute-touch) shift; cmd_flowroute_touch "$@" ;;
    flowroute-set) shift; cmd_flowroute_set "$@" ;;
    flowroute-unset) shift; cmd_flowroute_unset "$@" ;;
    flowroute-del) shift; cmd_flowroute_del "$@" ;;
    flow-table-set) shift; cmd_flow_table_set "$@" ;;
    flow-table-del) shift; cmd_flow_table_del "$@" ;;
    mpls-table-set) shift; cmd_mpls_table_set "$@" ;;
    mpls-table-del) shift; cmd_mpls_table_del "$@" ;;
    generate) cmd_generate ;;
    show) cmd_show ;;
    *) echo "Usage: $0 {static-touch|has-facts|check-link-set on|off|igp-table-set NAME|igp-table-del|disabled-set on|off|disabled-del|from-set TEMPLATE|from-del|channel-set ipv4|ipv6 preference N|import|export all|none|filter NAME|where COND|channel-del ipv4|ipv6 preference|import|export|debug-set SPEC|debug-del|mrtdump-set SPEC|mrtdump-del|roa-add PREFIX MAXLEN AS [TABLE]|roa-del PREFIX|aspa-providers-add ASN LIST [TABLE]|aspa-transit-add ASN [TABLE]|aspa-del ASN|route-touch PREFIX|route-del PREFIX|route-via-add PREFIX IP|route-via-del PREFIX IP|route-via-set PREFIX IP FIELD VALUE|route-via-iface-add PREFIX IFACE|route-via-iface-del PREFIX IFACE|route-recursive-set PREFIX IP|route-recursive-del PREFIX|route-mpls-set PREFIX LABEL|route-mpls-del PREFIX|route-recursive-mpls-set PREFIX STACK|route-recursive-mpls-del PREFIX|route-sink-set PREFIX KIND|route-sink-del PREFIX|route-attr-set PREFIX FIELD VALUE|route-attr-del PREFIX FIELD|route-filter-add PREFIX STMT|route-filter-if PREFIX COND THEN [ELSE]|route-filter-del PREFIX [SEQ]|flowroute-touch CTX|flowroute-set CTX FIELD VALUE|flowroute-unset CTX FIELD [KIND]|flowroute-del CTX|flow-table-set 4|6 NAME|flow-table-del 4|6|mpls-table-set NAME|mpls-table-del|generate|show}" >&2; exit 2 ;;
esac
