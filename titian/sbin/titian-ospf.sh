#!/bin/sh
# titian-ospf.sh — OSPF BIRD (`protocol ospf [v2|v3]`) untuk Titian/klish.
# Pola sama seperti titian-rip.sh: intent di /etc/titian/ospf.conf
# (tmpfs, dipersistenkan via titian-cfg.sh), generate menulis section
# BIRD /etc/titian/bird.d/ospf.conf lalu memanggil titian-bird.sh
# generate ospf (render ke marker #-OSPF-# ... #-ENDOSPF-# di
# bird.conf + validasi + birdc). Section ditulis ulang UTUH tiap apply.
#
# INI OSPF BIRD — BUKAN OSPF FRR (tree/conf-frr.xml, `router ospf`,
# daemon berbeda). Jangan campur: OSPF BIRD punya konsep area block,
# `instance id`, RFC 5838, `stub router`, `merge external`,
# Grace-LSA — yang tidak ada padanannya 1:1 di FRR.
#
# Sintaks BIRD 2.16.1 yang dipakai (docs resmi bird.network,
# User's Guide 2.16.1, Bab 6.11 OSPF; ekstraksi lengkap di
# BIRD-READ-ch6-ospf-rip-static.md §1):
#   protocol ospf ospf4 {            # v2, IPv4 (instance `ospf`)
#       rfc1583compat <switch>;
#       rfc5838 <switch>;
#       instance id <num>;
#       stub router <switch>;
#       tick <num>;
#       ecmp <switch> [limit <num>];
#       merge external <switch>;
#       graceful restart <switch>|aware;
#       graceful restart time <num>;
#       debug all|off|{ states, routes, filters, interfaces, events, packets };
#       mrtdump all|off|{ states, messages };
#       ipv4 {
#           preference <number>;
#           import keep filtered <switch>;
#           import all|none|filter <name>;
#           export all|none|filter <name>;   # atau export filter
#               { ospf_metric1 = N; ospf_metric2 = N; ospf_tag = N;
#                 accept; };  (bila export-ospf-metric*/tag di-set)
#       };
#       area <id> {
#           stub; | nssa;
#           summary <switch>;
#           default nssa <switch>;
#           default cost <num>;  default cost2 <num>;
#           translator <switch>;  translator stability <num>;
#           networks { <prefix>; <prefix> hidden; };
#           external { <prefix>; <prefix> hidden; <prefix> tag <num>; };
#           stubnet <prefix>; | stubnet <prefix> {
#               hidden <switch>; summary <switch>; cost <num>; };
#           interface "<pattern>" [instance <num>] {
#               cost <num>;  stub <switch>;
#               hello <num>;  poll <num>;  retransmit <num>;
#               transmit delay <num>;  priority <num>;  wait <num>;
#               dead count <num>;  dead <num>;
#               rx buffer [normal|large|<num>];  tx length <num>;
#               type broadcast|bcast|pointopoint|ptp|nonbroadcast|
#                    nbma|pointomultipoint|ptmp;
#               link lsa suppression <switch>;
#               strict nonbroadcast <switch>;  real broadcast <switch>;
#               ptp netmask <switch>;  ptp address <switch>;
#               check link <switch>;  bfd <switch>;
#               ecmp weight <num>;
#               ttl security <switch>|tx only;
#               tx class|dscp <num>;
#               authentication none|simple|cryptographic;
#               password "<text>" { id <num>; generate from "<date>";
#                   generate to "<date>"; accept from "<date>";
#                   accept to "<date>"; from "<date>"; to "<date>";
#                   algorithm (keyed md5|keyed sha1|hmac sha1|
#                   hmac sha256|hmac sha384|hmac sha512|blake2s128|
#                   blake2s256|blake2b256|blake2b512); };
#               neighbors { <ip>; <ip> eligible; };
#           };
#           virtual link <router-id> [instance <num>] {
#               hello <num>;  retransmit <num>;  wait <num>;
#               dead count <num>;  dead <num>;
#               authentication none|simple|cryptographic;
#               password "<text>" { ... sama seperti di atas ... };
#           };
#       };
#   }
#   protocol ospf v3 ospf6 { ... }   # v3, IPv6 (instance `ospf6`);
#                                    # channel ipv4 di v3 = RFC 5838.
# Satu instance = satu channel (v2: IPv4; v3: IPv6, atau IPv4 via
# RFC 5838 — untuk IPv4+IPv6 butuh dua instance). Tanpa channel,
# channel default dibuat otomatis — klish selalu menulis channel
# eksplisit (default import all / export all).
#
# Default BIRD (docs 2.16.1, TERVERIFIKASI Batch B0 — ditulis di help
# klish, TIDAK ditulis di section kecuali user mengaturnya eksplisit):
# rfc1583compat no; rfc5838 yes; instance id 0; stub router no;
# tick 1; ecmp enabled bila Kernel mendukung, limit 16; merge external
# no; graceful restart aware; graceful restart time 120; area:
# summary no; default nssa no; default cost 1000; default cost2 =
# (tidak dipakai — pakai metric type 1 / default cost bila tidak
# di-set); translator no; translator stability 40; networks/external
# = daftar kosong; interface: cost 10; stub no; hello 10; poll 20;
# retransmit 5; transmit delay 1; priority 1; wait 4x hello;
# rx buffer resize dinamis (large = 65535); tx length MTU interface;
# type auto-detect; link lsa suppression no; strict nonbroadcast no;
# real broadcast no; ptp netmask no (unnumbered) / yes (beralamat);
# ptp address no (unnumbered + graceful restart) / yes (lainnya);
# check link yes; bfd no; ecmp weight 1 (range 1..256); ttl security
# no; authentication none (algo kunci default v2 = Keyed-MD5,
# v3 = HMAC-SHA-256); ospf_metric2 default 10000; ospf_tag default 0.
#
# Default yang TIDAK ditebak (docs 2.16.1 tidak menyebut angka) —
# dijadikan OPSIONAL tanpa default palsu, didokumentasikan di sini
# dan di help klish:
#   - `dead` / `dead count` (interface maupun virtual link): hanya
#     rumus (tetangga down bila tidak ada pesan selama dead count x
#     hello); bila `dead` DAN `dead count` dipakai bersama, `dead`
#     yang menang. Nilai contoh di docs (dead count 8) BUKAN default.
#   - `default cost2` tanpa angka: bila tidak di-set, cost memakai
#     metric type 1 (`default cost`).
#   - `hidden`/`summary`/`cost` per stubnet: tidak dinyatakan docs.
#   - hello/retransmit/wait/dead count/dead virtual link: tidak
#     dinyatakan terpisah untuk vlink (vlink berperilaku sebagai
#     interface PtP — lihat default interface di atas).
#
# PENAMAAN (anti-bingung, lihat BIRD-COVERAGE.md O5):
#   - `stub-router` (level protokol, RFC 6987) vs area `stub` vs
#     interface `stub` — tiga perintah klish berbeda di tiga view
#     berbeda, masing-masing dengan help yang menyebut levelnya.
#
# TIDAK diimplementasi di batch ini:
#   - O34 `secondary` (interface): HANYA ada di blok template docs
#     (Bab 6.11 L3869), TIDAK ADA entri deskripsi — arti + default
#     tidak terverifikasi dari docs; cek `bird -p` / source BIRD
#     sebelum masuk klish (lihat BIRD-COVERAGE.md §3 O34).
#   - O48 `tx priority` (interface): Linux-specific (Bab 3.4-10 =
#     N/A); tidak ada padanan FreeBSD.
#   - O67 `ospf_router_id`: atribut route READ-ONLY (hanya dibaca di
#     filter) — tidak bisa di-set; tidak ada perintah klish untuknya.
#     Router-ID OSPF = router-id BIRD global (`router-id`, sudah DONE).
#   - O65 stub router + GR interlock: catatan implementasi, bukan
#     opsi sendiri; graceful restart lokal penuh butuh dukungan
#     protokol lain (mis. Kernel `graceful restart`, Bab 6.8).
#   - `ospf_metric1` / `ospf_metric2` / `ospf_tag` sebagai filter
#     umum (Bab 5): hanya didukung sebagai atribut export channel
#     (export-ospf-metric1 / export-ospf-metric2 / export-ospf-tag
#     di bawah, bila export all); penulisan bebas di filter menyusul
#     batch filter. (Set per-route via static sudah ada, B4.)
#
# Format ospf.conf (satu baris per fakta; <I> = ospf|ospf6,
# <A> = id area, <P> = pola interface, <R> = router-id vlink):
#   instance <I> rfc1583compat <on|off>
#   instance <I> rfc5838 <on|off>
#   instance <I> instance-id <N>          (0..255)
#   instance <I> stub-router <on|off>
#   instance <I> tick <N>
#   instance <I> ecmp <on|off>
#   instance <I> ecmp-limit <N>
#   instance <I> merge-external <on|off>
#   instance <I> graceful-restart <off|aware|on>
#   instance <I> graceful-restart-time <N>
#   instance <I> channel <ipv4|ipv6>
#   instance <I> import <all|none|filter NAME>
#   instance <I> export <all|none|filter NAME>
#   instance <I> export-ospf-metric1 <N>  (1..65535)
#   instance <I> export-ospf-metric2 <N>  (1..65535, default BIRD 10000)
#   instance <I> export-ospf-tag <N>      (0..4294967295, default BIRD 0)
#   instance <I> area <A> stub            (flag telanjang)
#   instance <I> area <A> nssa            (flag telanjang)
#   instance <I> area <A> summary <on|off>
#   instance <I> area <A> default-nssa <on|off>
#   instance <I> area <A> default-cost <N>
#   instance <I> area <A> default-cost2 <N>
#   instance <I> area <A> translator <on|off>
#   instance <I> area <A> translator-stability <N>
#   instance <I> area <A> network <PREFIX> [hidden]
#   instance <I> area <A> external <PREFIX> [hidden] [tag <N>]
#   instance <I> area <A> stubnet <PREFIX>
#   instance <I> area <A> stubnet <PREFIX> <field> <value>
#     field stubnet: hidden|summary <on|off>, cost <N>
#   instance <I> area <A> interface <P> instance <N>
#   instance <I> area <A> interface <P> <field> <value>
#     field: cost|stub|hello|poll|retransmit|transmit-delay|
#       priority|wait|dead-count|dead|rx-buffer|tx-length|type|
#       link-lsa-suppression|strict-nonbroadcast|real-broadcast|
#       ptp-netmask|ptp-address|check-link|bfd|ecmp-weight|
#       ttl-security|tx-class|tx-dscp|authentication
#   instance <I> area <A> interface <P> password <TEXT>
#   instance <I> area <A> interface <P> password <TEXT> <field> <value>
#     field password: id|generate-from|generate-to|accept-from|
#       accept-to|from|to|algorithm
#     (TEXT tanpa spasi, tanpa `"` dan tanpa `\`; tanggal ditulis
#     `YYYY-MM-DD` saja (BIRD 2.20.0 menolak tanggal+jam di password —
#     B24; tanggal+jam lama di intent dipangkas ke tanggal saat generate);
#     algorithm ditulis `hmac-sha256` dst dan diubah jadi `hmac sha256`
#     saat generate.)
#   instance <I> area <A> interface <P> neighbor <IP> [eligible]
#   instance <I> area <A> vlink <R> instance <N>
#   instance <I> area <A> vlink <R> <field> <value>
#     field: hello|retransmit|wait|dead-count|dead|authentication
#   instance <I> area <A> vlink <R> password <TEXT>
#   instance <I> area <A> vlink <R> password <TEXT> <field> <value>
#
# Urutan apply (titian-commit.sh): apply_ospf sesudah apply_rip,
# sebelum apply_bgp. OSPF interface `bfd` butuh `protocol bfd`
# (apply_bfd sudah jalan lebih dulu) — bila BFD belum ada, BIRD
# menolak `bfd yes;` saat parse; generate tetap menulis apa yang
# diminta user (BIRD yang memutuskan).

STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CONF="$STATE_ROOT/ospf.conf"
SECTION_DIR="$STATE_ROOT/bird.d"
SECTION="$SECTION_DIR/ospf.conf"
PROG="titian-ospf"
err() { echo "Error($PROG): $*" >&2; exit 33; }
die() { echo "$PROG: $*" >&2; exit 1; }

touch_conf() {
    if [ ! -f "$CONF" ]; then
        mkdir -p "$(dirname "$CONF")" 2>/dev/null
        printf '# ospf.conf - generated by klish, do not edit by hand\n' > "$CONF" \
            || die "cannot create $CONF"
        chmod 600 "$CONF" 2>/dev/null || true
    fi
}

# re_esc <teks> — escape karakter regex (untuk pola interface yang
# boleh mengandung `*`, dan id area IPv4 yang mengandung `.`) agar
# grep -v tidak salah hapus.
re_esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\./\\./g' -e 's/\*/\\*/g' \
        -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/\^/\\^/g' -e 's/\$/\\$/g'
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

has_facts() {
    [ -f "$CONF" ] || return 1
    grep -v '^[[:space:]]*#' "$CONF" 2>/dev/null | grep -q '[^[:space:]]'
}

# --- validasi ---
valid_inst() {
    case "$1" in
        ospf|ospf6) ;;
        *) err "instance harus ospf|ospf6: $1" ;;
    esac
}

valid_num() {
    # $1=nilai $2=lo $3=hi $4=nama field. Bilangan bulat dalam range.
    case "$1" in ''|*[!0-9]*) err "$4 harus bilangan $2..$3: $1" ;; esac
    [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null || \
        err "$4 harus bilangan $2..$3: $1"
}

valid_onoff() {
    case "$1" in
        on|off) ;;
        *) err "$2 harus on|off: $1" ;;
    esac
}

valid_name() {
    # $1=nama $2=konteks: simbol BIRD [A-Za-z_][A-Za-z0-9_]*.
    case "$1" in
        ''|*[!A-Za-z0-9_]*) err "$2 harus nama BIRD [A-Za-z0-9_]: $1" ;;
    esac
    case "$1" in [A-Za-z_]*) ;; *) err "$2 harus diawali huruf/underscore: $1" ;; esac
}

valid_ip() {
    # $1=ip $2=konteks. Gagal -> err rc=33.
    _ip="${1%%\%*}"
    case "$_ip" in
        *:*)
            case "$_ip" in *[!0-9a-fA-F:]*) err "$2 bukan alamat IPv6 valid: $1" ;; esac ;;
        *.*.*.*)
            case "$_ip" in *[!0-9.]*) err "$2 bukan alamat IPv4 valid: $1" ;; esac ;;
        *) err "$2 bukan alamat IP valid: $1" ;;
    esac
}

valid_ip4() {
    # $1=ip $2=konteks: harus IPv4 dotted quad, tiap oktet 0..255.
    case "$1" in
        *:*|*[!0-9.]*) err "$2 harus alamat IPv4: $1" ;;
    esac
    _o1=${1%%.*}; _rest=${1#*.}
    _o2=${_rest%%.*}; _rest=${_rest#*.}
    _o3=${_rest%%.*}; _o4=${_rest#*.}
    case "$_o4" in *.*) err "$2 harus alamat IPv4 (4 oktet): $1" ;; esac
    for _o in "$_o1" "$_o2" "$_o3" "$_o4"; do
        case "$_o" in ''|*[!0-9]*) err "$2 harus alamat IPv4: $1" ;; esac
        [ "$_o" -ge 0 ] 2>/dev/null && [ "$_o" -le 255 ] 2>/dev/null || \
            err "$2 harus alamat IPv4 (oktet 0..255): $1"
    done
}

ip_family() {
    case "${1%%\%*}" in *:* ) echo 6 ;; *) echo 4 ;; esac
}

valid_pattern() {
    # $1=pola interface $2=konteks: satu token, tanpa spasi.
    case "$1" in
        ''|*[[:space:]]*) err "$2 butuh satu pola interface tanpa spasi: $1" ;;
    esac
}

valid_password() {
    # $1=password: tanpa spasi, tanpa `"`, tanpa `\` (masuk string
    # BIRD ber-quote ganda).
    case "$1" in
        '' ) err "password tidak boleh kosong" ;;
        *[[:space:]]*) err "password tidak boleh mengandung spasi: $1" ;;
        *\"*) err 'password tidak boleh mengandung `"`: hapus karakter itu' ;;
        *\\*) err 'password tidak boleh mengandung `\`: hapus karakter itu' ;;
    esac
}

# B24 (17 Nov 2026): BIRD 2.20.0 password dates = TANGGAL SAJA — datetime
# (bentuk T maupun spasi) DITOLAK bird -p "Invalid date/time" (B18 t7/t8/o1;
# B24 t2/t3/t5/t6/t8/t9). Cermin valid_bfd_date titian-bfd.sh.
valid_date() {
    # $1=tanggal $2=konteks: YYYY-MM-DD saja.
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) err "$2 harus tanggal YYYY-MM-DD saja (BIRD 2.20.0 menolak tanggal+jam di password): $1" ;;
    esac
}

# date_to_bird <nilai> — pertahanan intent lama: tanggal+jam yang tersimpan
# sebelum B24 (validator lama menerima datetime) dipangkas ke tanggal saja
# saat emit, karena BIRD menolak datetime apa pun di password. Arah aman:
# kunci berlaku sejak 00:00 tanggal itu (lebih awal), bukan config ditolak.
date_to_bird() {
    _d="${1%%T*}"; _d="${_d%% *}"; printf '%s' "$_d"
}

valid_area_id() {
    # $1=id area: integer 0..4294967295 ATAU alamat IPv4 (mis. 0.0.0.0).
    # Backbone = 0 / 0.0.0.0.
    case "$1" in
        *.*) valid_ip4 "$1" "area id" ;;
        ''|*[!0-9]*) err "area id harus integer 0..4294967295 atau alamat IPv4 (mis. 0.0.0.0): $1" ;;
        *) valid_num "$1" 0 4294967295 "area id" ;;
    esac
}

valid_prefix() {
    # $1=prefix CIDR $2=konteks: IP/len, len sesuai keluarga.
    case "$1" in
        */*) _ip=${1%%/*}; _len=${1##*/} ;;
        *) err "$2 harus prefix CIDR (IP/len, mis. 10.0.0.0/8): $1" ;;
    esac
    valid_ip "$_ip" "$2"
    case "$_len" in ''|*[!0-9]*) err "$2 panjang prefix harus bilangan: $1" ;; esac
    if [ "$(ip_family "$_ip")" = "6" ]; then
        [ "$_len" -ge 0 ] 2>/dev/null && [ "$_len" -le 128 ] 2>/dev/null || \
            err "$2 panjang prefix IPv6 harus 0..128: $1"
    else
        [ "$_len" -ge 0 ] 2>/dev/null && [ "$_len" -le 32 ] 2>/dev/null || \
            err "$2 panjang prefix IPv4 harus 0..32: $1"
    fi
}

# inst_has <ospf|ospf6>: exit 0 bila ada >=1 fakta instance itu.
inst_has() {
    grep -q "^instance $1 " "$CONF" 2>/dev/null
}

# area_has <inst> <area>: exit 0 bila area itu punya fakta.
area_has() {
    _are=$(re_esc "$2")
    grep -q "^instance $1 area $_are " "$CONF" 2>/dev/null
}

cmd_ospf_touch() {
    # $1 = ospf|ospf6
    valid_inst "$1"
    touch_conf
    echo "OSPF $1"
}

# --- opsi level instance ---
cmd_switch_set() {
    # switch-set <inst> <field> <on|off> — field protokol boolean.
    # disabled (Bab 3.4-1): protokol tidak di-start saat configure.
    _i="$1"; _f="$2"; _v="$3"
    valid_inst "$_i"
    valid_onoff "$_v" "$_f"
    case "$_f" in
        rfc1583compat|rfc5838|stub-router|merge-external|disabled) ;;
        *) err "field switch protokol tidak dikenal: $_f" ;;
    esac
    upsert "^instance $_i $_f " "instance $_i $_f $_v"
    echo "OSPF $_i $_f = $_v"
}

cmd_switch_del() {
    # switch-del <inst> <field> — kembali ke default BIRD.
    _i="$1"; _f="$2"
    valid_inst "$_i"
    case "$_f" in
        rfc1583compat|rfc5838|stub-router|merge-external|disabled) ;;
        *) err "field switch protokol tidak dikenal: $_f" ;;
    esac
    dellines "^instance $_i $_f "
    echo "OSPF $_i $_f dihapus (default BIRD)"
}

cmd_router_id_set() { # router-id-set INST IP (Bab 3.4-4; router id per-protocol)
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "router-id butuh alamat IP"
    valid_ip4 "$_v" "router-id"
    upsert "^instance $_i router-id " "instance $_i router-id $_v"
    echo "OSPF $_i router-id = $_v"
}

cmd_router_id_del() { # router-id-del INST (kembali ke router id global)
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i router-id "
    echo "OSPF $_i router-id dihapus (router id global BIRD)"
}

cmd_description_set() { # description-set INST TEKS... (Bab 3.4-5; label protokol)
    _i="$1"; shift
    valid_inst "$_i"
    [ -n "$*" ] || err "description butuh teks"
    upsert "^instance $_i description " "instance $_i description $*"
    echo "OSPF $_i description = $*"
}

cmd_description_del() { # description-del INST
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i description "
    echo "OSPF $_i description dihapus"
}

cmd_instance_id_set() {
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "instance-id butuh nilai"
    valid_num "$_v" 0 255 "instance-id"
    upsert "^instance $_i instance-id " "instance $_i instance-id $_v"
    echo "OSPF $_i instance-id = $_v"
}

cmd_instance_id_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i instance-id "
    echo "OSPF $_i instance-id dihapus (default BIRD 0)"
}

cmd_tick_set() {
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "tick butuh nilai"
    valid_num "$_v" 1 86400 "tick"
    upsert "^instance $_i tick " "instance $_i tick $_v"
    echo "OSPF $_i tick = $_v"
}

cmd_tick_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i tick "
    echo "OSPF $_i tick dihapus (default BIRD 1)"
}

cmd_ecmp_set() {
    _i="$1"; _v="$2"
    valid_inst "$_i"
    valid_onoff "$_v" "ecmp"
    upsert "^instance $_i ecmp " "instance $_i ecmp $_v"
    echo "OSPF $_i ecmp = $_v"
}

cmd_ecmp_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i ecmp "
    dellines "^instance $_i ecmp-limit "
    echo "OSPF $_i ecmp dihapus (default BIRD: enabled bila Kernel mendukung)"
}

cmd_ecmp_limit_set() {
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "ecmp-limit butuh nilai"
    valid_num "$_v" 1 256 "ecmp-limit"
    upsert "^instance $_i ecmp-limit " "instance $_i ecmp-limit $_v"
    echo "OSPF $_i ecmp-limit = $_v"
}

cmd_ecmp_limit_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i ecmp-limit "
    echo "OSPF $_i ecmp-limit dihapus (default BIRD 16)"
}

cmd_gr_set() {
    # graceful-restart <inst> <off|aware|on>
    _i="$1"; _v="$2"
    valid_inst "$_i"
    case "$_v" in
        off|aware|on) ;;
        *) err "graceful-restart harus off|aware|on: $_v" ;;
    esac
    upsert "^instance $_i graceful-restart " "instance $_i graceful-restart $_v"
    echo "OSPF $_i graceful-restart = $_v"
}

cmd_gr_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i graceful-restart "
    echo "OSPF $_i graceful-restart dihapus (default BIRD aware)"
}

cmd_gr_time_set() {
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "graceful-restart-time butuh nilai"
    valid_num "$_v" 1 86400 "graceful-restart-time"
    upsert "^instance $_i graceful-restart-time " "instance $_i graceful-restart-time $_v"
    echo "OSPF $_i graceful-restart-time = $_v"
}

cmd_gr_time_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i graceful-restart-time "
    echo "OSPF $_i graceful-restart-time dihapus (default BIRD 120)"
}

cmd_channel_set() {
    # channel-set <inst> <ipv4|ipv6> — v2 (ospf) HANYA ipv4; v3
    # (ospf6) ipv6, atau ipv4 via RFC 5838 (O66).
    # B14 (Bab 2.3-3): SATU channel per instance — BIRD 2.20 menolak
    # channel kedua ("Different channel type" / "Multiple ipv4 channels").
    # Setter nilai-tunggal ini menjaga invarian itu: ganti channel hanya
    # sesudah `no channel` (hapus dulu), bukan diam-diam menimpa.
    _i="$1"; _v="$2"
    valid_inst "$_i"
    case "$_v" in
        ipv4)
            # v2 (ospf) = IPv4; v3 (ospf6) = IPv4 via RFC 5838 (O66).
            ;;
        ipv6)
            [ "$_i" = "ospf6" ] || err "channel ipv6 tidak berlaku di instance ospf (v2, IPv4 saja) — pakai ospfv3 untuk IPv6"
            ;;
        *) err "channel harus ipv4|ipv6: $_v" ;;
    esac
    _old=$(grep "^instance $_i channel " "$CONF" 2>/dev/null | head -1 | awk '{print $4}')
    if [ -n "$_old" ] && [ "$_old" != "$_v" ]; then
        err "OSPF $_i sudah punya channel $_old — satu instance satu channel (BIRD 2.20 menolak channel kedua); hapus dulu dengan 'no channel' sebelum ganti ke $_v"
    fi
    upsert "^instance $_i channel " "instance $_i channel $_v"
    echo "OSPF $_i channel = $_v"
}

cmd_channel_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i channel "
    echo "OSPF $_i channel dihapus (default: ospf=ipv4, ospf6=ipv6)"
}

cmd_chan_set() {
    # chan-set <inst> <import|export> <all|none|filter NAME|where COND>
    # (Bab 3.5-4/5; where = filter inline bentuk ringkas, mis.
    # net~10.0.0.0/8 — diterjemahkan ke BIRD saat generate.)
    _i="$1"; _d="$2"; _v="$3"; _n="$4"
    valid_inst "$_i"
    case "$_d" in import|export) ;; *) err "channel harus import|export: $_d" ;; esac
    case "$_v" in
        all|none) upsert "^instance $_i $_d " "instance $_i $_d $_v" ;;
        filter)
            [ -n "$_n" ] || err "$_d filter butuh NAMA filter"
            valid_name "$_n" "nama filter"
            upsert "^instance $_i $_d " "instance $_i $_d filter $_n" ;;
        where)
            [ -n "$_n" ] || err "$_d where butuh ekspresi filter bentuk ringkas (mis. where net~10.0.0.0/8)"
            cond_validate "$_n" || exit 33
            upsert "^instance $_i $_d " "instance $_i $_d where $_n" ;;
        *) err "$_d harus all|none|filter NAME|where COND: $_v" ;;
    esac
    echo "OSPF $_i $_d = $_v${_n:+ $_n}"
}

_ospf_valid_spec() { # <SPEC> <debug|mrtdump> — validasi daftar kelas koma
    _op_spec="$1"; _op_kind="$2"
    [ -n "$_op_spec" ] || err "$_op_kind butuh all|off|kelas,kelas,..."
    case "$_op_spec" in all|off) return 0 ;; esac
    _op_rest="$_op_spec"
    while [ -n "$_op_rest" ]; do
        case "$_op_rest" in *,*) _op_done=${_op_rest%%,*}; _op_rest=${_op_rest#*,} ;; *) _op_done="$_op_rest"; _op_rest="" ;; esac
        if [ "$_op_kind" = "debug" ]; then
            case "$_op_done" in states|routes|filters|interfaces|events|packets) ;; *) err "debug kelas tidak dikenal: $_op_done (boleh: states|routes|filters|interfaces|events|packets)" ;; esac
        else
            case "$_op_done" in states|messages) ;; *) err "mrtdump kelas tidak dikenal: $_op_done (boleh: states|messages)" ;; esac
        fi
    done
}
cmd_preference_set() { # B8: preference-set INST N (0..65535, Bab 3.5-3)
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "preference butuh nilai"
    valid_num "$_v" 0 65535 "preference"
    upsert "^instance $_i preference " "instance $_i preference $_v"
    echo "OSPF $_i preference = $_v"
}
cmd_preference_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i preference "
    echo "OSPF $_i preference dihapus (default BIRD tergantung protokol)"
}

cmd_limit_set() { # B9: limit-set INST import|receive|export N|off [ACTION] (Bab 3.5-8/9/10)
    # Bentuk split seperti BGP (B6): limit + limit-action dua baris intent.
    _i="$1"; _k="$2"; _v="$3"; _a="$4"
    valid_inst "$_i"
    case "$_k" in import|receive|export) ;; *) err "$_k harus import|receive|export" ;; esac
    [ -n "$_v" ] || err "$_k-limit butuh angka atau off"
    case "$_v" in off) ;; *) valid_num "$_v" 0 4294967295 "$_k-limit" ;; esac
    if [ -n "$_a" ]; then
        case "$_a" in warn|block|restart|disable) ;; *) err "$_k-limit-action harus warn|block|restart|disable: $_a" ;; esac
        [ "$_v" = "off" ] && err "$_k-limit off tidak boleh pakai action — hapus action dulu"
    fi
    upsert "^instance $_i $_k-limit " "instance $_i $_k-limit $_v"
    if [ -n "$_a" ]; then
        upsert "^instance $_i $_k-limit-action " "instance $_i $_k-limit-action $_a"
        echo "OSPF $_i $_k-limit = $_v action $_a"
    else
        echo "OSPF $_i $_k-limit = $_v"
    fi
}
cmd_limit_action_set() { # B9: limit-action-set INST KIND warn|block|restart|disable
    _i="$1"; _k="$2"; _a="$3"
    valid_inst "$_i"
    case "$_k" in import|receive|export) ;; *) err "$_k harus import|receive|export" ;; esac
    case "$_a" in warn|block|restart|disable) ;; *) err "$_k-limit-action harus warn|block|restart|disable: $_a" ;; esac
    _lim=$(get_inst_field "$_i" "$_k-limit")
    [ -n "$_lim" ] || err "$_k-limit-action tanpa $_k-limit — set dulu $_k-limit"
    [ "$_lim" = "off" ] && err "$_k-limit off tidak boleh pakai action — hapus action dulu"
    upsert "^instance $_i $_k-limit-action " "instance $_i $_k-limit-action $_a"
    echo "OSPF $_i $_k-limit-action = $_a"
}
cmd_limit_del() { # B9: limit-del INST KIND — hapus limit + action-nya
    _i="$1"; _k="$2"
    valid_inst "$_i"
    case "$_k" in import|receive|export) ;; *) err "$_k harus import|receive|export" ;; esac
    dellines "^instance $_i $_k-limit "
    dellines "^instance $_i $_k-limit-action "
    echo "OSPF $_i $_k-limit dihapus (default BIRD tanpa limit)"
}
cmd_ikf_set() { # B8: import-keep-filtered-set INST on|off (Bab 3.5-6)
    _i="$1"; _v="$2"
    valid_inst "$_i"
    valid_onoff "$_v" "import-keep-filtered"
    upsert "^instance $_i import-keep-filtered " "instance $_i import-keep-filtered $_v"
    echo "OSPF $_i import-keep-filtered = $_v"
}
cmd_ikf_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i import-keep-filtered "
    echo "OSPF $_i import-keep-filtered dihapus (default BIRD off)"
}
cmd_debug_set() { # B8: debug-set INST SPEC (Bab 3.4-2)
    _i="$1"; _v="$2"
    valid_inst "$_i"
    _ospf_valid_spec "$_v" debug
    upsert "^instance $_i debug " "instance $_i debug $_v"
    echo "OSPF $_i debug = $_v"
}
cmd_debug_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i debug "
    echo "OSPF $_i debug dihapus (default BIRD off)"
}
cmd_mrtdump_set() { # B8: mrtdump-set INST SPEC (Bab 3.4-3)
    _i="$1"; _v="$2"
    valid_inst "$_i"
    _ospf_valid_spec "$_v" mrtdump
    upsert "^instance $_i mrtdump " "instance $_i mrtdump $_v"
    echo "OSPF $_i mrtdump = $_v"
}
cmd_mrtdump_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i mrtdump "
    echo "OSPF $_i mrtdump dihapus (default BIRD off)"
}
cmd_export_attr_set() {
    # export-attr-set <inst> <metric1|metric2|tag> <N>
    _i="$1"; _f="$2"; _v="$3"
    valid_inst "$_i"
    [ -n "$_v" ] || err "export-ospf-$_f butuh nilai"
    case "$_f" in
        metric1) valid_num "$_v" 1 65535 "export-ospf-metric1" ;;
        metric2) valid_num "$_v" 1 65535 "export-ospf-metric2" ;;
        tag) valid_num "$_v" 0 4294967295 "export-ospf-tag" ;;
        *) err "field export OSPF tidak dikenal: $_f (metric1|metric2|tag)" ;;
    esac
    upsert "^instance $_i export-ospf-$_f " "instance $_i export-ospf-$_f $_v"
    echo "OSPF $_i export-ospf-$_f = $_v"
}

cmd_export_attr_del() {
    _i="$1"; _f="$2"
    valid_inst "$_i"
    case "$_f" in
        metric1|metric2|tag) ;;
        *) err "field export OSPF tidak dikenal: $_f" ;;
    esac
    dellines "^instance $_i export-ospf-$_f "
    echo "OSPF $_i export-ospf-$_f dihapus (default BIRD: metric2 10000, tag 0)"
}

# --- area ---
cmd_area_add() {
    _i="$1"; _a="$2"
    valid_inst "$_i"
    [ -n "$_a" ] || err "area-add butuh id area (mis. 0 atau 0.0.0.0)"
    valid_area_id "$_a"
    # Koreksi F3.2: area-add HARUS persisten (sebelumnya no-op — hanya
    # touch + echo, area hilang; generate lalu emit protocol tanpa area
    # yang ditolak BIRD "No configured areas in OSPF"). Baris telanjang
    # `instance <I> area <A>` ditangkap emitter (emit_area) + dihapus
    # area-del (sudah menangani pola bare line).
    _are=$(re_esc "$_a")
    upsert "^instance $_i area $_are\$" "instance $_i area $_a"
    echo "OSPF $_i area $_a"
}

cmd_area_del() {
    _i="$1"; _a="$2"
    valid_inst "$_i"
    [ -n "$_a" ] || err "area-del butuh id area"
    valid_area_id "$_a"
    _are=$(re_esc "$_a")
    dellines "^instance $_i area $_are "
    dellines "^instance $_i area $_are\$"
    echo "OSPF $_i area $_a dihapus"
}

cmd_area_flag_set() {
    # area-flag-set <inst> <area> <stub|nssa> — flag telanjang BIRD.
    _i="$1"; _a="$2"; _f="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    case "$_f" in stub|nssa) ;; *) err "flag area harus stub|nssa: $_f" ;; esac
    _are=$(re_esc "$_a")
    touch_conf
    _tmp="$CONF.tmp.$$"
    grep -v "^instance $_i area $_are $_f\$" "$CONF" > "$_tmp" 2>/dev/null || true
    printf 'instance %s area %s %s\n' "$_i" "$_a" "$_f" >> "$_tmp"
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    chmod 600 "$CONF" 2>/dev/null || true
    echo "OSPF $_i area $_a $_f"
}

cmd_area_flag_del() {
    _i="$1"; _a="$2"; _f="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    case "$_f" in stub|nssa) ;; *) err "flag area harus stub|nssa: $_f" ;; esac
    _are=$(re_esc "$_a")
    dellines "^instance $_i area $_are $_f\$"
    echo "OSPF $_i area $_a $_f dihapus"
}

cmd_area_set() {
    # area-set <inst> <area> <field> <value>
    _i="$1"; _a="$2"; _f="$3"; _v="$4"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_f" ] && [ -n "$_v" ] || err "area-set butuh INSTANCE AREA FIELD VALUE"
    _are=$(re_esc "$_a")
    case "$_f" in
        summary|default-nssa|translator)
            valid_onoff "$_v" "$_f"
            upsert "^instance $_i area $_are $_f " "instance $_i area $_a $_f $_v" ;;
        default-cost|default-cost2)
            valid_num "$_v" 1 65535 "$_f"
            upsert "^instance $_i area $_are $_f " "instance $_i area $_a $_f $_v" ;;
        translator-stability)
            valid_num "$_v" 1 86400 "$_f"
            upsert "^instance $_i area $_are $_f " "instance $_i area $_a $_f $_v" ;;
        *) err "field area OSPF tidak dikenal: $_f (summary|default-nssa|default-cost|default-cost2|translator|translator-stability)" ;;
    esac
    echo "OSPF $_i area $_a $_f = $_v"
}

cmd_area_unset() {
    _i="$1"; _a="$2"; _f="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_f" ] || err "area-unset butuh INSTANCE AREA FIELD"
    _are=$(re_esc "$_a")
    case "$_f" in
        summary|default-nssa|default-cost|default-cost2|translator|translator-stability)
            dellines "^instance $_i area $_are $_f " ;;
        stub|nssa)
            err "flag $_f dihapus via area-flag-del (bukan area-unset)" ;;
        *) err "field area OSPF tidak dikenal: $_f" ;;
    esac
    echo "OSPF $_i area $_a $_f dihapus (kembali ke default BIRD)"
}

# --- networks / external (area IP ranges) ---
cmd_network_add() {
    # network-add <inst> <area> <PREFIX> [hidden]
    _i="$1"; _a="$2"; _p="$3"; _h="$4"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_p" ] || err "network-add butuh PREFIX"
    valid_prefix "$_p" "network"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_p")
    case "$_h" in ''|hidden) ;; *) err "network-add argumen ke-4 harus kosong|hidden: $_h" ;; esac
    # Jangan pakai upsert di sini: baris telanjang `network PREFIX`
    # (ujung baris) tidak cocok dengan regex upsert yang berakhir
    # spasi — hapus dulu kedua varian, lalu tambah.
    dellines "^instance $_i area $_are network $_pre "
    dellines "^instance $_i area $_are network $_pre\$"
    printf 'instance %s area %s network %s%s\n' "$_i" "$_a" "$_p" "${_h:+ $_h}" >> "$CONF"
    echo "OSPF $_i area $_a network $_p${_h:+ $_h}"
}

cmd_network_del() {
    _i="$1"; _a="$2"; _p="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_p" ] || err "network-del butuh PREFIX"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_p")
    dellines "^instance $_i area $_are network $_pre "
    dellines "^instance $_i area $_are network $_pre\$"
    echo "OSPF $_i area $_a network $_p dihapus"
}

cmd_external_add() {
    # external-add <inst> <area> <PREFIX> [hidden] [tag <N>]
    # Dipanggil klish sebagai: external-add I A PREFIX [hidden] [tag N]
    # dengan argumen posisi: $4=hidden-atau-kosong, $5=tag-atau-kosong,
    # $6=nilai-tag.
    _i="$1"; _a="$2"; _p="$3"; _h="$4"; _tk="$5"; _tv="$6"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_p" ] || err "external-add butuh PREFIX"
    valid_prefix "$_p" "external"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_p")
    case "$_h" in ''|hidden) ;; *) err "external-add argumen hidden harus kosong|hidden: $_h" ;; esac
    # Pertahankan atribut yang tidak disebut dari baris yang sudah ada
    # (hidden dan tag independen — `external-tag` tidak boleh menghapus
    # hidden, `external-hidden` tidak boleh menghapus tag).
    _existing=$(grep "^instance $_i area $_are external $_pre\( \|$\)" "$CONF" 2>/dev/null | head -1)
    _e7=$(printf '%s' "$_existing" | awk '{print $7}')
    _e8=$(printf '%s' "$_existing" | awk '{print $8}')
    _e9=$(printf '%s' "$_existing" | awk '{print $9}')
    if [ -z "$_h" ] && [ "$_e7" = "hidden" ]; then _h="hidden"; fi
    if [ -z "$_tk" ]; then
        if [ "$_e7" = "tag" ]; then _tk="tag"; _tv="$_e8";
        elif [ "$_e8" = "tag" ]; then _tk="tag"; _tv="$_e9"; fi
    fi
    _line="instance $_i area $_a external $_p"
    if [ -n "$_tk" ]; then
        [ "$_tk" = "tag" ] || err "external-add argumen ke-5 harus tag: $_tk"
        [ -n "$_tv" ] || err "external tag butuh nilai"
        valid_num "$_tv" 0 4294967295 "external tag"
        _line="$_line${_h:+ $_h} tag $_tv"
    else
        _line="$_line${_h:+ $_h}"
    fi
    # Jangan pakai upsert: baris telanjang `external PREFIX` (ujung
    # baris) tidak cocok dengan regex upsert yang berakhir spasi.
    dellines "^instance $_i area $_are external $_pre "
    dellines "^instance $_i area $_are external $_pre\$"
    printf '%s\n' "$_line" >> "$CONF"
    echo "OSPF $_i area $_a external $_p${_h:+ $_h}${_tk:+ tag $_tv}"
}

cmd_external_del() {
    _i="$1"; _a="$2"; _p="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_p" ] || err "external-del butuh PREFIX"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_p")
    dellines "^instance $_i area $_are external $_pre "
    dellines "^instance $_i area $_are external $_pre\$"
    echo "OSPF $_i area $_a external $_p dihapus"
}

# --- stubnet ---
cmd_stubnet_add() {
    _i="$1"; _a="$2"; _p="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_p" ] || err "stubnet-add butuh PREFIX"
    valid_prefix "$_p" "stubnet"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_p")
    touch_conf
    if grep -q "^instance $_i area $_are stubnet $_pre\$" "$CONF" 2>/dev/null || \
       grep -q "^instance $_i area $_are stubnet $_pre " "$CONF" 2>/dev/null; then
        echo "OSPF $_i area $_a stubnet $_p sudah ada"
        return 0
    fi
    printf 'instance %s area %s stubnet %s\n' "$_i" "$_a" "$_p" >> "$CONF"
    echo "OSPF $_i area $_a stubnet $_p"
}

cmd_stubnet_del() {
    _i="$1"; _a="$2"; _p="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_p" ] || err "stubnet-del butuh PREFIX"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_p")
    dellines "^instance $_i area $_are stubnet $_pre\$"
    dellines "^instance $_i area $_are stubnet $_pre "
    echo "OSPF $_i area $_a stubnet $_p dihapus"
}

cmd_stubnet_set() {
    # stubnet-set <inst> <area> <PREFIX> <field> <value>
    _i="$1"; _a="$2"; _p="$3"; _f="$4"; _v="$5"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_p" ] && [ -n "$_f" ] && [ -n "$_v" ] || \
        err "stubnet-set butuh INSTANCE AREA PREFIX FIELD VALUE"
    valid_prefix "$_p" "stubnet"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_p")
    grep -q "^instance $_i area $_are stubnet $_pre\$" "$CONF" 2>/dev/null || \
    grep -q "^instance $_i area $_are stubnet $_pre " "$CONF" 2>/dev/null || \
        err "stubnet $_p belum ada di area $_a (tambah dulu: stubnet $_p)"
    case "$_f" in
        hidden|summary)
            valid_onoff "$_v" "$_f"
            upsert "^instance $_i area $_are stubnet $_pre $_f " "instance $_i area $_a stubnet $_p $_f $_v" ;;
        cost)
            valid_num "$_v" 1 65535 "stubnet cost"
            upsert "^instance $_i area $_are stubnet $_pre $_f " "instance $_i area $_a stubnet $_p $_f $_v" ;;
        *) err "field stubnet tidak dikenal: $_f (hidden|summary|cost)" ;;
    esac
    echo "OSPF $_i area $_a stubnet $_p $_f = $_v"
}

cmd_stubnet_unset() {
    _i="$1"; _a="$2"; _p="$3"; _f="$4"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_p" ] && [ -n "$_f" ] || err "stubnet-unset butuh INSTANCE AREA PREFIX FIELD"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_p")
    case "$_f" in
        hidden|summary|cost)
            dellines "^instance $_i area $_are stubnet $_pre $_f " ;;
        *) err "field stubnet tidak dikenal: $_f" ;;
    esac
    echo "OSPF $_i area $_a stubnet $_p $_f dihapus"
}

# --- interface (di dalam area) ---
cmd_interface_add() {
    _i="$1"; _a="$2"; _pat="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_pat" ] || err "interface-add butuh pola interface (mis. ge*)"
    valid_pattern "$_pat" "interface"
    # Koreksi F3.2: interface-add HARUS persisten (sebelumnya no-op —
    # hanya touch + echo; interface hilang bila belum ada field yang
    # di-set). Baris telanjang ditangkap emitter (emit_iface) + dihapus
    # interface-del (sudah menangani pola bare line).
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_pat")
    upsert "^instance $_i area $_are interface $_pre\$" "instance $_i area $_a interface $_pat"
    echo "OSPF $_i area $_a interface $_pat"
}

cmd_interface_del() {
    _i="$1"; _a="$2"; _pat="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_pat" ] || err "interface-del butuh pola interface"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_pat")
    dellines "^instance $_i area $_are interface $_pre "
    dellines "^instance $_i area $_are interface $_pre\$"
    echo "OSPF $_i area $_a interface $_pat dihapus"
}

cmd_interface_set() {
    # interface-set <inst> <area> <PATTERN> <field> <value>
    _i="$1"; _a="$2"; _pat="$3"; _f="$4"; _v="$5"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_pat" ] && [ -n "$_f" ] && [ -n "$_v" ] || \
        err "interface-set butuh INSTANCE AREA PATTERN FIELD VALUE"
    valid_pattern "$_pat" "interface"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_pat")
    case "$_f" in
        instance)
            valid_num "$_v" 0 255 "interface instance id"
            upsert "^instance $_i area $_are interface $_pre instance " "instance $_i area $_a interface $_pat instance $_v" ;;
        cost)
            valid_num "$_v" 1 65535 "cost"
            upsert "^instance $_i area $_are interface $_pre cost " "instance $_i area $_a interface $_pat cost $_v" ;;
        stub|check-link|bfd|link-lsa-suppression|strict-nonbroadcast|real-broadcast|ptp-netmask|ptp-address)
            valid_onoff "$_v" "$_f"
            upsert "^instance $_i area $_are interface $_pre $_f " "instance $_i area $_a interface $_pat $_f $_v" ;;
        hello|poll|retransmit|transmit-delay|wait)
            valid_num "$_v" 1 86400 "$_f"
            upsert "^instance $_i area $_are interface $_pre $_f " "instance $_i area $_a interface $_pat $_f $_v" ;;
        dead-count|dead)
            # TIDAK ADA angka default di docs — opsional, tanpa default
            # palsu; bila dead dan dead count dipakai bersama, dead
            # yang menang (precedence BIRD).
            valid_num "$_v" 1 65535 "$_f"
            upsert "^instance $_i area $_are interface $_pre $_f " "instance $_i area $_a interface $_pat $_f $_v" ;;
        priority)
            valid_num "$_v" 0 255 "priority"
            upsert "^instance $_i area $_are interface $_pre priority " "instance $_i area $_a interface $_pat priority $_v" ;;
        rx-buffer)
            case "$_v" in
                normal|large)
                    upsert "^instance $_i area $_are interface $_pre rx-buffer " "instance $_i area $_a interface $_pat rx-buffer $_v" ;;
                *)
                    valid_num "$_v" 1 65535 "rx-buffer"
                    upsert "^instance $_i area $_are interface $_pre rx-buffer " "instance $_i area $_a interface $_pat rx-buffer $_v" ;;
            esac ;;
        tx-length)
            valid_num "$_v" 1 65535 "tx-length"
            upsert "^instance $_i area $_are interface $_pre tx-length " "instance $_i area $_a interface $_pat tx-length $_v" ;;
        type)
            case "$_v" in
                broadcast|bcast|pointopoint|ptp|nonbroadcast|nbma|pointomultipoint|ptmp)
                    upsert "^instance $_i area $_are interface $_pre type " "instance $_i area $_a interface $_pat type $_v" ;;
                *) err "type harus broadcast|bcast|pointopoint|ptp|nonbroadcast|nbma|pointomultipoint|ptmp: $_v" ;;
            esac ;;
        ecmp-weight)
            valid_num "$_v" 1 256 "ecmp-weight"
            upsert "^instance $_i area $_are interface $_pre ecmp-weight " "instance $_i area $_a interface $_pat ecmp-weight $_v" ;;
        ttl-security)
            case "$_v" in
                on|off|tx-only) upsert "^instance $_i area $_are interface $_pre ttl-security " "instance $_i area $_a interface $_pat ttl-security $_v" ;;
                *) err "ttl-security harus on|off|tx-only: $_v" ;;
            esac ;;
        tx-class)
            valid_num "$_v" 0 255 "tx-class"
            upsert "^instance $_i area $_are interface $_pre tx-class " "instance $_i area $_a interface $_pat tx-class $_v" ;;
        tx-dscp)
            valid_num "$_v" 0 63 "tx-dscp"
            upsert "^instance $_i area $_are interface $_pre tx-dscp " "instance $_i area $_a interface $_pat tx-dscp $_v" ;;
        authentication)
            case "$_v" in
                none|cryptographic)
                    upsert "^instance $_i area $_are interface $_pre authentication " "instance $_i area $_a interface $_pat authentication $_v" ;;
                simple)
                    [ "$_i" = "ospf6" ] && err "authentication simple TIDAK tersedia di OSPFv3 (hanya OSPFv2) — pakai cryptographic"
                    upsert "^instance $_i area $_are interface $_pre authentication " "instance $_i area $_a interface $_pat authentication $_v" ;;
                *) err "authentication harus none|simple|cryptographic: $_v" ;;
            esac ;;
        *) err "field interface OSPF tidak dikenal: $_f (instance|cost|stub|hello|poll|retransmit|transmit-delay|priority|wait|dead-count|dead|rx-buffer|tx-length|type|link-lsa-suppression|strict-nonbroadcast|real-broadcast|ptp-netmask|ptp-address|check-link|bfd|ecmp-weight|ttl-security|tx-class|tx-dscp|authentication)" ;;
    esac
    case "$_f" in
        hello|poll|retransmit|transmit-delay|wait|dead-count|dead)
            # B.5: timer OSPF hanya dibaca saat interface di-(re)inisialisasi
            # daemon — perubahan live via `birdc configure` TIDAK diterapkan
            # tanpa restart OSPF. CLI TIDAK auto-restart (keputusan desain,
            # lihat HASIL.md); operator restart manual bila perlu
            # (`birdc restart ospf4`).
            echo "Perhatian: timer OSPF $_f = $_v tersimpan di intent, baru berlaku sesudah OSPF di-restart (birdc restart ospf4) — CLI tidak auto-restart" >&2 ;;
    esac
    echo "OSPF $_i area $_a interface $_pat $_f = $_v"
}

cmd_interface_unset() {
    _i="$1"; _a="$2"; _pat="$3"; _f="$4"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_pat" ] && [ -n "$_f" ] || err "interface-unset butuh INSTANCE AREA PATTERN FIELD"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_pat")
    case "$_f" in
        instance|cost|stub|hello|poll|retransmit|transmit-delay|priority|wait|dead-count|dead|rx-buffer|tx-length|type|link-lsa-suppression|strict-nonbroadcast|real-broadcast|ptp-netmask|ptp-address|check-link|bfd|ecmp-weight|ttl-security|tx-class|tx-dscp|authentication)
            dellines "^instance $_i area $_are interface $_pre $_f " ;;
        password|neighbor)
            err "$_f dihapus via password-del / neighbor-del" ;;
        *) err "field interface OSPF tidak dikenal: $_f" ;;
    esac
    echo "OSPF $_i area $_a interface $_pat $_f dihapus (kembali ke default BIRD)"
}

# --- neighbors (NBMA, per interface) ---
cmd_neighbor_add() {
    # neighbor-add <inst> <area> <PATTERN> <IP> [eligible]
    _i="$1"; _a="$2"; _pat="$3"; _ip="$4"; _el="$5"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_pat" ] && [ -n "$_ip" ] || err "neighbor-add butuh INSTANCE AREA PATTERN IP"
    valid_pattern "$_pat" "interface"
    valid_ip "$_ip" "neighbor"
    case "$_el" in ''|eligible) ;; *) err "neighbor-add argumen ke-5 harus kosong|eligible: $_el" ;; esac
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_pat"); _ipe=$(re_esc "$_ip")
    # Jangan pakai upsert: baris telanjang `neighbor IP` (ujung baris)
    # tidak cocok dengan regex upsert yang berakhir spasi.
    dellines "^instance $_i area $_are interface $_pre neighbor $_ipe "
    dellines "^instance $_i area $_are interface $_pre neighbor $_ipe\$"
    printf 'instance %s area %s interface %s neighbor %s%s\n' "$_i" "$_a" "$_pat" "$_ip" "${_el:+ $_el}" >> "$CONF"
    echo "OSPF $_i area $_a interface $_pat neighbor $_ip${_el:+ $_el}"
}

cmd_neighbor_del() {
    _i="$1"; _a="$2"; _pat="$3"; _ip="$4"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_pat" ] && [ -n "$_ip" ] || err "neighbor-del butuh INSTANCE AREA PATTERN IP"
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_pat"); _ipe=$(re_esc "$_ip")
    dellines "^instance $_i area $_are interface $_pre neighbor $_ipe "
    dellines "^instance $_i area $_are interface $_pre neighbor $_ipe\$"
    echo "OSPF $_i area $_a interface $_pat neighbor $_ip dihapus"
}

# --- virtual link (di dalam area transit) ---
cmd_vlink_add() {
    _i="$1"; _a="$2"; _r="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_r" ] || err "vlink-add butuh router-id ABR ujung jauh (IPv4)"
    valid_ip4 "$_r" "virtual link id"
    touch_conf
    echo "OSPF $_i area $_a virtual link $_r"
}

cmd_vlink_del() {
    _i="$1"; _a="$2"; _r="$3"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_r" ] || err "vlink-del butuh router-id"
    valid_ip4 "$_r" "virtual link id"
    _are=$(re_esc "$_a"); _re2=$(re_esc "$_r")
    dellines "^instance $_i area $_are vlink $_re2 "
    dellines "^instance $_i area $_are vlink $_re2\$"
    echo "OSPF $_i area $_a virtual link $_r dihapus"
}

cmd_vlink_set() {
    # vlink-set <inst> <area> <RID> <field> <value>
    _i="$1"; _a="$2"; _r="$3"; _f="$4"; _v="$5"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_r" ] && [ -n "$_f" ] && [ -n "$_v" ] || \
        err "vlink-set butuh INSTANCE AREA ROUTER-ID FIELD VALUE"
    valid_ip4 "$_r" "virtual link id"
    _are=$(re_esc "$_a"); _re2=$(re_esc "$_r")
    case "$_f" in
        instance)
            valid_num "$_v" 0 255 "vlink instance id"
            upsert "^instance $_i area $_are vlink $_re2 instance " "instance $_i area $_a vlink $_r instance $_v" ;;
        hello|retransmit|wait)
            valid_num "$_v" 1 86400 "$_f"
            upsert "^instance $_i area $_are vlink $_re2 $_f " "instance $_i area $_a vlink $_r $_f $_v" ;;
        dead-count|dead)
            # Sama seperti interface: default vlink TIDAK dinyatakan
            # terpisah di docs — opsional, tanpa default palsu.
            valid_num "$_v" 1 65535 "$_f"
            upsert "^instance $_i area $_are vlink $_re2 $_f " "instance $_i area $_a vlink $_r $_f $_v" ;;
        authentication)
            case "$_v" in
                none|cryptographic)
                    upsert "^instance $_i area $_are vlink $_re2 authentication " "instance $_i area $_a vlink $_r authentication $_v" ;;
                simple)
                    [ "$_i" = "ospf6" ] && err "authentication simple TIDAK tersedia di OSPFv3 (hanya OSPFv2) — pakai cryptographic"
                    upsert "^instance $_i area $_are vlink $_re2 authentication " "instance $_i area $_a vlink $_r authentication $_v" ;;
                *) err "authentication harus none|simple|cryptographic: $_v" ;;
            esac ;;
        *) err "field virtual link tidak dikenal: $_f (instance|hello|retransmit|wait|dead-count|dead|authentication)" ;;
    esac
    case "$_f" in
        hello|retransmit|wait|dead-count|dead)
            # B.5: sama seperti interface — timer vlink baru berlaku
            # sesudah OSPF di-restart; CLI tidak auto-restart.
            echo "Perhatian: timer OSPF vlink $_f = $_v tersimpan di intent, baru berlaku sesudah OSPF di-restart (birdc restart ospf4) — CLI tidak auto-restart" >&2 ;;
    esac
    echo "OSPF $_i area $_a virtual link $_r $_f = $_v"
}

cmd_vlink_unset() {
    _i="$1"; _a="$2"; _r="$3"; _f="$4"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_r" ] && [ -n "$_f" ] || err "vlink-unset butuh INSTANCE AREA ROUTER-ID FIELD"
    _are=$(re_esc "$_a"); _re2=$(re_esc "$_r")
    case "$_f" in
        instance|hello|retransmit|wait|dead-count|dead|authentication)
            dellines "^instance $_i area $_are vlink $_re2 $_f " ;;
        password)
            err "password dihapus via password-del (scope vlink)" ;;
        *) err "field virtual link tidak dikenal: $_f" ;;
    esac
    echo "OSPF $_i area $_a virtual link $_r $_f dihapus (kembali ke default BIRD)"
}

# --- password (per interface ATAU per virtual link — rotasi kunci) ---
# $1=inst $2=area $3=scope (interface|vlink) $4=parent (pola/RID)
cmd_password_add() {
    # password-add <inst> <area> <interface|vlink> <PARENT> <TEXT>
    _i="$1"; _a="$2"; _sc="$3"; _par="$4"; _pw="$5"
    valid_inst "$_i"
    valid_area_id "$_a"
    case "$_sc" in
        interface) valid_pattern "$_par" "interface" ;;
        vlink) valid_ip4 "$_par" "virtual link id" ;;
        *) err "scope password harus interface|vlink: $_sc" ;;
    esac
    [ -n "$_pw" ] || err "password-add butuh PASSWORD"
    valid_password "$_pw"
    _are=$(re_esc "$_a"); _pare=$(re_esc "$_par"); _pwre=$(re_esc "$_pw")
    if grep -q "^instance $_i area $_are $_sc $_pare password $_pwre\$" "$CONF" 2>/dev/null || \
       grep -q "^instance $_i area $_are $_sc $_pare password $_pwre " "$CONF" 2>/dev/null; then
        echo "OSPF $_i area $_a $_sc $_par password sudah ada"
        return 0
    fi
    touch_conf
    printf 'instance %s area %s %s %s password %s\n' "$_i" "$_a" "$_sc" "$_par" "$_pw" >> "$CONF"
    echo "OSPF $_i area $_a $_sc $_par password ditambahkan"
}

cmd_password_del() {
    # password-del <inst> <area> <interface|vlink> <PARENT> <TEXT>:
    # hapus kunci + sub-opsinya.
    _i="$1"; _a="$2"; _sc="$3"; _par="$4"; _pw="$5"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_par" ] && [ -n "$_pw" ] || err "password-del butuh PARENT PASSWORD"
    _are=$(re_esc "$_a"); _pare=$(re_esc "$_par"); _pwre=$(re_esc "$_pw")
    dellines "^instance $_i area $_are $_sc $_pare password $_pwre\$"
    dellines "^instance $_i area $_are $_sc $_pare password $_pwre "
    echo "OSPF $_i area $_a $_sc $_par password dihapus"
}

cmd_password_set() {
    # password-set <inst> <area> <interface|vlink> <PARENT> <TEXT> <field> <value...>
    # field: id|generate-from|generate-to|accept-from|accept-to|from|to|algorithm
    _i="$1"; _a="$2"; _sc="$3"; _par="$4"; _pw="$5"; _f="$6"; shift 6
    _v="$*"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_par" ] && [ -n "$_pw" ] && [ -n "$_f" ] && [ -n "$_v" ] || \
        err "password-set butuh INSTANCE AREA SCOPE PARENT PASSWORD FIELD VALUE"
    valid_password "$_pw"
    _are=$(re_esc "$_a"); _pare=$(re_esc "$_par"); _pwre=$(re_esc "$_pw")
    grep -q "^instance $_i area $_are $_sc $_pare password $_pwre\$" "$CONF" 2>/dev/null || \
    grep -q "^instance $_i area $_are $_sc $_pare password $_pwre " "$CONF" 2>/dev/null || \
        err "password belum ada di $_sc $_par (tambah dulu: password \"$_pw\")"
    case "$_f" in
        id)
            valid_num "$_v" 0 4294967295 "password id"
            upsert "^instance $_i area $_are $_sc $_pare password $_pwre id " "instance $_i area $_a $_sc $_par password $_pw id $_v" ;;
        generate-from|generate-to|accept-from|accept-to|from|to)
            valid_date "$_v" "password $_f"
            upsert "^instance $_i area $_are $_sc $_pare password $_pwre $_f " "instance $_i area $_a $_sc $_par password $_pw $_f $_v" ;;
        algorithm)
            case "$_v" in
                keyed-md5|keyed-sha1|hmac-sha1|hmac-sha256|hmac-sha384|hmac-sha512|blake2s128|blake2s256|blake2b256|blake2b512)
                    upsert "^instance $_i area $_are $_sc $_pare password $_pwre algorithm " "instance $_i area $_a $_sc $_par password $_pw algorithm $_v" ;;
                *) err "algorithm harus keyed-md5|keyed-sha1|hmac-sha1|hmac-sha256|hmac-sha384|hmac-sha512|blake2s128|blake2s256|blake2b256|blake2b512: $_v" ;;
            esac ;;
        *) err "field password tidak dikenal: $_f (id|generate-from|generate-to|accept-from|accept-to|from|to|algorithm)" ;;
    esac
    echo "OSPF $_i area $_a $_sc $_par password $_f = $_v"
}

cmd_password_unset() {
    # password-unset <inst> <area> <interface|vlink> <PARENT> <TEXT> <field>
    _i="$1"; _a="$2"; _sc="$3"; _par="$4"; _pw="$5"; _f="$6"
    valid_inst "$_i"
    valid_area_id "$_a"
    [ -n "$_par" ] && [ -n "$_pw" ] && [ -n "$_f" ] || \
        err "password-unset butuh INSTANCE AREA SCOPE PARENT PASSWORD FIELD"
    _are=$(re_esc "$_a"); _pare=$(re_esc "$_par"); _pwre=$(re_esc "$_pw")
    case "$_f" in
        id|generate-from|generate-to|accept-from|accept-to|from|to|algorithm)
            dellines "^instance $_i area $_are $_sc $_pare password $_pwre $_f " ;;
        *) err "field password tidak dikenal: $_f" ;;
    esac
    echo "OSPF $_i area $_a $_sc $_par password $_f dihapus"
}

# --- getters (untuk generate) ---
get_inst_field() {
    # $1=inst $2=field -> nilai (kolom 4)
    grep "^instance $1 $2 " "$CONF" 2>/dev/null | head -1 | awk '{print $4}'
}

get_chan() {
    # $1=inst $2=import|export -> "all" | "none" | "filter NAME" | "where COND"
    # (juga dipakai untuk nilai multi-kata lain, mis. description).
    grep "^instance $1 $2 " "$CONF" 2>/dev/null | head -1 | awk '{$1=""; $2=""; $3=""; sub(/^ +/, ""); print}'
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

get_area_field() {
    # $1=inst $2=area $3=field -> nilai (kolom 6)
    _are=$(re_esc "$2")
    grep "^instance $1 area $_are $3 " "$CONF" 2>/dev/null | head -1 | awk '{print $6}'
}

area_flag() {
    # $1=inst $2=area $3=stub|nssa -> exit 0 bila flag ada.
    _are=$(re_esc "$2")
    grep -q "^instance $1 area $_are $3\$" "$CONF" 2>/dev/null
}

get_iface_field() {
    # $1=inst $2=area $3=pattern $4=field -> nilai (kolom 8)
    _are=$(re_esc "$2"); _pre=$(re_esc "$3")
    grep "^instance $1 area $_are interface $_pre $4 " "$CONF" 2>/dev/null | head -1 | awk '{print $8}'
}

get_vlink_field() {
    # $1=inst $2=area $3=router-id $4=field -> nilai (kolom 8)
    _are=$(re_esc "$2"); _re2=$(re_esc "$3")
    grep "^instance $1 area $_are vlink $_re2 $4 " "$CONF" 2>/dev/null | head -1 | awk '{print $8}'
}

get_pw_field() {
    # $1=inst $2=area $3=interface|vlink $4=parent $5=password $6=field
    # -> nilai (kolom 10..)
    _are=$(re_esc "$2"); _pare=$(re_esc "$4"); _pwre=$(re_esc "$5")
    grep "^instance $1 area $_are $3 $_pare password $_pwre $6 " "$CONF" 2>/dev/null | head -1 | awk '{$1=""; $2=""; $3=""; $4=""; $5=""; $6=""; $7=""; $8=""; $9=""; sub(/^ +/, ""); print}'
}

# emit_passwords <inst> <area> <interface|vlink> <parent>: cetak
# statement `password ...;` (indent 8 spasi) untuk semua kunci
# konteks itu, urut kemunculan.
emit_passwords() {
    _i="$1"; _a="$2"; _sc="$3"; _par="$4"
    _are=$(re_esc "$_a"); _pare=$(re_esc "$_par")
    set -f
    for _pw in $(grep "^instance $_i area $_are $_sc $_pare password " "$CONF" 2>/dev/null | awk '{print $8}' | awk '!s[$0]++'); do
        _id=$(get_pw_field "$_i" "$_a" "$_sc" "$_par" "$_pw" id)
        _gf=$(get_pw_field "$_i" "$_a" "$_sc" "$_par" "$_pw" generate-from)
        _gt=$(get_pw_field "$_i" "$_a" "$_sc" "$_par" "$_pw" generate-to)
        _af=$(get_pw_field "$_i" "$_a" "$_sc" "$_par" "$_pw" accept-from)
        _at=$(get_pw_field "$_i" "$_a" "$_sc" "$_par" "$_pw" accept-to)
        _fr=$(get_pw_field "$_i" "$_a" "$_sc" "$_par" "$_pw" from)
        _to=$(get_pw_field "$_i" "$_a" "$_sc" "$_par" "$_pw" to)
        _al=$(get_pw_field "$_i" "$_a" "$_sc" "$_par" "$_pw" algorithm)
        if [ -n "$_id" ] || [ -n "$_gf" ] || [ -n "$_gt" ] || [ -n "$_af" ] || [ -n "$_at" ] || [ -n "$_fr" ] || [ -n "$_to" ] || [ -n "$_al" ]; then
            _stmt="            password \"$_pw\" {"
            [ -n "$_id" ] && _stmt="$_stmt id $_id;"
            [ -n "$_gf" ] && _stmt="$_stmt generate from \"$(date_to_bird "$_gf")\";"
            [ -n "$_gt" ] && _stmt="$_stmt generate to \"$(date_to_bird "$_gt")\";"
            [ -n "$_af" ] && _stmt="$_stmt accept from \"$(date_to_bird "$_af")\";"
            [ -n "$_at" ] && _stmt="$_stmt accept to \"$(date_to_bird "$_at")\";"
            [ -n "$_fr" ] && _stmt="$_stmt from \"$(date_to_bird "$_fr")\";"
            [ -n "$_to" ] && _stmt="$_stmt to \"$(date_to_bird "$_to")\";"
            [ -n "$_al" ] && _stmt="$_stmt algorithm $(printf '%s' "$_al" | tr '-' ' ');"
            printf '%s };\n' "$_stmt"
        else
            printf '            password "%s";\n' "$_pw"
        fi
    done
    set +f
}

# emit_switch_iface <inst> <area> <pattern> <field> <bird-name>
emit_switch_iface() {
    _v=$(get_iface_field "$1" "$2" "$3" "$4")
    case "$_v" in
        on) printf '            %s yes;\n' "$5" ;;
        off) printf '            %s no;\n' "$5" ;;
    esac
}

# emit_iface <inst> <area> <pattern>: cetak blok interface BIRD.
emit_iface() {
    _i="$1"; _a="$2"; _pat="$3"
    _inst=$(get_iface_field "$_i" "$_a" "$_pat" instance)
    _cost=$(get_iface_field "$_i" "$_a" "$_pat" cost)
    _hello=$(get_iface_field "$_i" "$_a" "$_pat" hello)
    _poll=$(get_iface_field "$_i" "$_a" "$_pat" poll)
    _retrans=$(get_iface_field "$_i" "$_a" "$_pat" retransmit)
    _tdelay=$(get_iface_field "$_i" "$_a" "$_pat" transmit-delay)
    _prio=$(get_iface_field "$_i" "$_a" "$_pat" priority)
    _wait=$(get_iface_field "$_i" "$_a" "$_pat" wait)
    _dc=$(get_iface_field "$_i" "$_a" "$_pat" dead-count)
    _dead=$(get_iface_field "$_i" "$_a" "$_pat" dead)
    _rxb=$(get_iface_field "$_i" "$_a" "$_pat" rx-buffer)
    _txl=$(get_iface_field "$_i" "$_a" "$_pat" tx-length)
    _type=$(get_iface_field "$_i" "$_a" "$_pat" type)
    _ew=$(get_iface_field "$_i" "$_a" "$_pat" ecmp-weight)
    _ttl=$(get_iface_field "$_i" "$_a" "$_pat" ttl-security)
    _txc=$(get_iface_field "$_i" "$_a" "$_pat" tx-class)
    _txd=$(get_iface_field "$_i" "$_a" "$_pat" tx-dscp)
    _auth=$(get_iface_field "$_i" "$_a" "$_pat" authentication)
    if [ -n "$_inst" ]; then
        echo "        interface \"$_pat\" instance $_inst {"
    else
        echo "        interface \"$_pat\" {"
    fi
    [ -n "$_cost" ] && echo "            cost $_cost;"
    emit_switch_iface "$_i" "$_a" "$_pat" stub "stub"
    [ -n "$_hello" ] && echo "            hello $_hello;"
    [ -n "$_poll" ] && echo "            poll $_poll;"
    [ -n "$_retrans" ] && echo "            retransmit $_retrans;"
    [ -n "$_tdelay" ] && echo "            transmit delay $_tdelay;"
    [ -n "$_prio" ] && echo "            priority $_prio;"
    [ -n "$_wait" ] && echo "            wait $_wait;"
    [ -n "$_dc" ] && echo "            dead count $_dc;"
    [ -n "$_dead" ] && echo "            dead $_dead;"
    [ -n "$_rxb" ] && echo "            rx buffer $_rxb;"
    [ -n "$_txl" ] && echo "            tx length $_txl;"
    [ -n "$_type" ] && echo "            type $_type;"
    emit_switch_iface "$_i" "$_a" "$_pat" link-lsa-suppression "link lsa suppression"
    emit_switch_iface "$_i" "$_a" "$_pat" strict-nonbroadcast "strict nonbroadcast"
    emit_switch_iface "$_i" "$_a" "$_pat" real-broadcast "real broadcast"
    emit_switch_iface "$_i" "$_a" "$_pat" ptp-netmask "ptp netmask"
    emit_switch_iface "$_i" "$_a" "$_pat" ptp-address "ptp address"
    emit_switch_iface "$_i" "$_a" "$_pat" check-link "check link"
    emit_switch_iface "$_i" "$_a" "$_pat" bfd "bfd"
    [ -n "$_ew" ] && echo "            ecmp weight $_ew;"
    case "$_ttl" in
        on) echo "            ttl security yes;" ;;
        off) echo "            ttl security no;" ;;
        tx-only) echo "            ttl security tx only;" ;;
    esac
    [ -n "$_txc" ] && echo "            tx class $_txc;"
    [ -n "$_txd" ] && echo "            tx dscp $_txd;"
    [ -n "$_auth" ] && echo "            authentication $_auth;"
    emit_passwords "$_i" "$_a" interface "$_pat"
    # neighbors { ... } — satu blok, urut kemunculan.
    _are=$(re_esc "$_a"); _pre=$(re_esc "$_pat")
    set -f
    _nbs=$(grep "^instance $_i area $_are interface $_pre neighbor " "$CONF" 2>/dev/null | awk '{print $8}')
    if [ -n "$_nbs" ]; then
        echo "            neighbors {"
        for _nb in $_nbs; do
            _el=$(grep "^instance $_i area $_are interface $_pre neighbor $(re_esc "$_nb")\( \|$\)" "$CONF" 2>/dev/null | head -1 | awk '{print $9}')
            if [ "$_el" = "eligible" ]; then
                echo "                $_nb eligible;"
            else
                echo "                $_nb;"
            fi
        done
        echo "            };"
    fi
    set +f
    echo "        };"
}

# emit_vlink <inst> <area> <router-id>: cetak blok virtual link BIRD.
emit_vlink() {
    _i="$1"; _a="$2"; _r="$3"
    _inst=$(get_vlink_field "$_i" "$_a" "$_r" instance)
    _hello=$(get_vlink_field "$_i" "$_a" "$_r" hello)
    _retrans=$(get_vlink_field "$_i" "$_a" "$_r" retransmit)
    _wait=$(get_vlink_field "$_i" "$_a" "$_r" wait)
    _dc=$(get_vlink_field "$_i" "$_a" "$_r" dead-count)
    _dead=$(get_vlink_field "$_i" "$_a" "$_r" dead)
    _auth=$(get_vlink_field "$_i" "$_a" "$_r" authentication)
    if [ -n "$_inst" ]; then
        echo "        virtual link $_r instance $_inst {"
    else
        echo "        virtual link $_r {"
    fi
    [ -n "$_hello" ] && echo "            hello $_hello;"
    [ -n "$_retrans" ] && echo "            retransmit $_retrans;"
    [ -n "$_wait" ] && echo "            wait $_wait;"
    [ -n "$_dc" ] && echo "            dead count $_dc;"
    [ -n "$_dead" ] && echo "            dead $_dead;"
    [ -n "$_auth" ] && echo "            authentication $_auth;"
    emit_passwords "$_i" "$_a" vlink "$_r"
    echo "        };"
}

# emit_area <inst> <area>: cetak blok area BIRD.
emit_area() {
    _i="$1"; _a="$2"
    _are=$(re_esc "$_a")
    _summary=$(get_area_field "$_i" "$_a" summary)
    _dnssa=$(get_area_field "$_i" "$_a" default-nssa)
    _dcost=$(get_area_field "$_i" "$_a" default-cost)
    _dcost2=$(get_area_field "$_i" "$_a" default-cost2)
    _trans=$(get_area_field "$_i" "$_a" translator)
    _tstab=$(get_area_field "$_i" "$_a" translator-stability)
    echo "    area $_a {"
    area_flag "$_i" "$_a" stub && echo "        stub;"
    area_flag "$_i" "$_a" nssa && echo "        nssa;"
    case "$_summary" in on) echo "        summary yes;" ;; off) echo "        summary no;" ;; esac
    case "$_dnssa" in on) echo "        default nssa yes;" ;; off) echo "        default nssa no;" ;; esac
    [ -n "$_dcost" ] && echo "        default cost $_dcost;"
    [ -n "$_dcost2" ] && echo "        default cost2 $_dcost2;"
    case "$_trans" in on) echo "        translator yes;" ;; off) echo "        translator no;" ;; esac
    [ -n "$_tstab" ] && echo "        translator stability $_tstab;"
    # networks { ... }
    set -f
    _nets=$(grep "^instance $_i area $_are network " "$CONF" 2>/dev/null | awk '{print $6}' | awk '!s[$0]++')
    if [ -n "$_nets" ]; then
        echo "        networks {"
        for _n in $_nets; do
            if grep -q "^instance $_i area $_are network $(re_esc "$_n") hidden\$" "$CONF" 2>/dev/null; then echo "            $_n hidden;"
            else echo "            $_n;"; fi
        done
        echo "        };"
    fi
    # external { ... }
    _exts=$(grep "^instance $_i area $_are external " "$CONF" 2>/dev/null | awk '{print $6}' | awk '!s[$0]++')
    if [ -n "$_exts" ]; then
        echo "        external {"
        for _e in $_exts; do
            _line=$(grep "^instance $_i area $_are external $(re_esc "$_e")\( \|$\)" "$CONF" 2>/dev/null | head -1)
            _f7=$(printf '%s' "$_line" | awk '{print $7}')
            _f8=$(printf '%s' "$_line" | awk '{print $8}')
            _f9=$(printf '%s' "$_line" | awk '{print $9}')
            _stmt="            $_e"
            if [ "$_f7" = "hidden" ]; then
                _stmt="$_stmt hidden"
                [ "$_f8" = "tag" ] && _stmt="$_stmt tag $_f9"
            elif [ "$_f7" = "tag" ]; then
                _stmt="$_stmt tag $_f8"
            fi
            printf '%s;\n' "$_stmt"
        done
        echo "        };"
    fi
    # stubnet ...
    _sns=$(grep "^instance $_i area $_are stubnet " "$CONF" 2>/dev/null | awk '{print $6}' | awk '!s[$0]++')
    for _sn in $_sns; do
        _hid=$(get_stubnet_field "$_i" "$_a" "$_sn" hidden)
        _sum=$(get_stubnet_field "$_i" "$_a" "$_sn" summary)
        _cst=$(get_stubnet_field "$_i" "$_a" "$_sn" cost)
        if [ -n "$_hid" ] || [ -n "$_sum" ] || [ -n "$_cst" ]; then
            _stmt="        stubnet $_sn {"
            case "$_hid" in on) _stmt="$_stmt hidden yes;" ;; off) _stmt="$_stmt hidden no;" ;; esac
            case "$_sum" in on) _stmt="$_stmt summary yes;" ;; off) _stmt="$_stmt summary no;" ;; esac
            [ -n "$_cst" ] && _stmt="$_stmt cost $_cst;"
            printf '%s };\n' "$_stmt"
        else
            echo "        stubnet $_sn;"
        fi
    done
    # interface ...
    for _pat in $(grep "^instance $_i area $_are interface " "$CONF" 2>/dev/null | awk '{print $6}' | awk '!s[$0]++'); do
        emit_iface "$_i" "$_a" "$_pat"
    done
    # virtual link ...
    for _r in $(grep "^instance $_i area $_are vlink " "$CONF" 2>/dev/null | awk '{print $6}' | awk '!s[$0]++'); do
        emit_vlink "$_i" "$_a" "$_r"
    done
    set +f
    echo "    };"
}

get_stubnet_field() {
    # $1=inst $2=area $3=prefix $4=field -> nilai (kolom 8)
    _are=$(re_esc "$2"); _pre=$(re_esc "$3")
    grep "^instance $1 area $_are stubnet $_pre $4 " "$CONF" 2>/dev/null | head -1 | awk '{print $8}'
}

# emit_limit <INST> <KIND> — satu baris limit channel (B9, Bab 3.5-8/9/10).
# Dipanggil di dalam blok channel (indent 8 spasi). Action tanpa limit
# ditolak di generate (intent bisa diedit tangan).
emit_limit() {
    _li=$(get_inst_field "$1" "$2-limit")
    _la=$(get_inst_field "$1" "$2-limit-action")
    [ -n "$_li" ] || { [ -n "$_la" ] && err "instance $1: $2-limit-action tanpa $2-limit — set dulu $2-limit"; return 0; }
    case "$_li" in
        off) [ -n "$_la" ] && err "instance $1: $2-limit off tidak boleh pakai action — hapus $2-limit-action"
             echo "        $2 limit off;" ;;
        *) if [ -n "$_la" ]; then echo "        $2 limit $_li action $_la;"; else echo "        $2 limit $_li;"; fi ;;
    esac
}

# emit_instance <ospf|ospf6>: cetak blok `protocol ospf ... { ... }`.
emit_instance() {
    _i="$1"
    inst_has "$_i" || return 0
    _rfc1583=$(get_inst_field "$_i" rfc1583compat)
    _rfc5838=$(get_inst_field "$_i" rfc5838)
    _iid=$(get_inst_field "$_i" instance-id)
    _stubr=$(get_inst_field "$_i" stub-router)
    _tick=$(get_inst_field "$_i" tick)
    _ecmp=$(get_inst_field "$_i" ecmp)
    _eclimit=$(get_inst_field "$_i" ecmp-limit)
    _merge=$(get_inst_field "$_i" merge-external)
    _gr=$(get_inst_field "$_i" graceful-restart)
    _grt=$(get_inst_field "$_i" graceful-restart-time)
    _chan=$(get_inst_field "$_i" channel)
    _import=$(get_chan "$_i" import)
    _export=$(get_chan "$_i" export)
    _pref=$(get_inst_field "$_i" preference)
    _ikf=$(get_inst_field "$_i" import-keep-filtered)
    _dbg=$(get_inst_field "$_i" debug)
    _mrt=$(get_inst_field "$_i" mrtdump)
    _m1=$(get_inst_field "$_i" export-ospf-metric1)
    _m2=$(get_inst_field "$_i" export-ospf-metric2)
    _tag=$(get_inst_field "$_i" export-ospf-tag)
    _dis=$(get_inst_field "$_i" disabled)
    _rid=$(get_inst_field "$_i" router-id)
    _desc=$(get_chan "$_i" description)
    [ -n "$_import" ] || _import="all"
    [ -n "$_export" ] || _export="all"
    if [ -n "$_m1" ] || [ -n "$_m2" ] || [ -n "$_tag" ]; then
        case "$_export" in
            all) ;;
            *) err "export-ospf-metric1/metric2/tag hanya berlaku bila export all (instance $_i saat ini export $_export) — ubah export ke all dulu, atau hapus metric/tag" ;;
        esac
    fi
    # ecmp-limit tanpa ecmp on: `ecmp` barisnya akan menggantung;
    # tolak di generate agar konfigurasi tidak ambigu.
    if [ -z "$_ecmp" ] && [ -n "$_eclimit" ]; then
        err "ecmp-limit di instance $_i tanpa ecmp on — set dulu ecmp on (atau hapus ecmp-limit)"
    fi
    # Guard area: stub dan nssa tidak boleh bersamaan; opsi stub/NSSA
    # hanya bermakna di area stub/NSSA.
    set -f
    for _a in $(grep "^instance $_i area " "$CONF" 2>/dev/null | awk '{print $4}' | awk '!s[$0]++'); do
        if area_flag "$_i" "$_a" stub && area_flag "$_i" "$_a" nssa; then
            err "area $_a (instance $_i) tidak boleh stub DAN nssa sekaligus — pilih salah satu"
        fi
        # Virtual link menghubungkan area ke backbone LEWAT area
        # transit — tidak boleh didefinisikan di backbone (area 0).
        # Backbone juga tidak boleh stub/NSSA (BIRD: "Backbone area
        # cannot be stub/NSSA").
        if [ "$_a" = "0" ] || [ "$_a" = "0.0.0.0" ]; then
            _are=$(re_esc "$_a")
            grep -q "^instance $_i area $_are vlink " "$CONF" 2>/dev/null && \
                err "area $_a adalah backbone — virtual link tidak boleh di backbone, harus di area transit (bukan area 0)"
            if area_flag "$_i" "$_a" stub || area_flag "$_i" "$_a" nssa; then
                err "area $_a adalah backbone — tidak boleh stub/NSSA (BIRD: Backbone area cannot be stub/NSSA); pakai area transit (bukan 0)"
            fi
        fi
        _is_stub=0; _is_nssa=0
        area_flag "$_i" "$_a" stub && _is_stub=1
        area_flag "$_i" "$_a" nssa && _is_nssa=1
        if [ "$_is_nssa" = "0" ]; then
            for _f in default-nssa translator translator-stability; do
                [ -n "$(get_area_field "$_i" "$_a" "$_f")" ] && \
                    err "area $_a: $_f hanya berlaku di area NSSA — set dulu nssa di area itu, atau hapus $_f"
            done
            _are=$(re_esc "$_a")
            grep -q "^instance $_i area $_are external " "$CONF" 2>/dev/null && \
                err "area $_a: external hanya berlaku di area NSSA — set dulu nssa di area itu, atau hapus external"
        fi
        if [ "$_is_stub" = "0" ] && [ "$_is_nssa" = "0" ]; then
            for _f in summary default-cost default-cost2; do
                [ -n "$(get_area_field "$_i" "$_a" "$_f")" ] && \
                    err "area $_a: $_f hanya berlaku di area stub/NSSA — set dulu stub atau nssa di area itu, atau hapus $_f"
            done
        fi
    done
    set +f
    if [ "$_i" = "ospf" ]; then
        echo "protocol ospf ospf4 {"
        _chan="${_chan:-ipv4}"
        [ "$_chan" = "ipv4" ] || err "instance ospf (v2) hanya bisa channel ipv4"
    else
        echo "protocol ospf v3 ospf6 {"
        _chan="${_chan:-ipv6}"
    fi
    case "$_dis" in on) echo "    disabled;" ;; esac
    [ -n "$_rid" ] && echo "    router id $_rid;"
    [ -n "$_desc" ] && echo "    description \"$_desc\";"
    case "$_rfc1583" in on) echo "    rfc1583compat yes;" ;; off) echo "    rfc1583compat no;" ;; esac
    case "$_rfc5838" in on) echo "    rfc5838 yes;" ;; off) echo "    rfc5838 no;" ;; esac
    [ -n "$_iid" ] && echo "    instance id $_iid;"
    case "$_stubr" in on) echo "    stub router yes;" ;; off) echo "    stub router no;" ;; esac
    [ -n "$_tick" ] && echo "    tick $_tick;"
    case "$_ecmp" in
        on)
            if [ -n "$_eclimit" ]; then echo "    ecmp yes limit $_eclimit;"
            else echo "    ecmp yes;"; fi ;;
        off) echo "    ecmp no;" ;;
    esac
    case "$_merge" in on) echo "    merge external yes;" ;; off) echo "    merge external no;" ;; esac
    case "$_gr" in
        on) echo "    graceful restart yes;" ;;
        off) echo "    graceful restart no;" ;;
        aware) echo "    graceful restart aware;" ;;
    esac
    [ -n "$_grt" ] && echo "    graceful restart time $_grt;"
    if [ -n "$_dbg" ]; then
        case "$_dbg" in all|off) echo "    debug $_dbg;" ;; *) echo "    debug { $(echo "$_dbg" | sed 's/,/, /g') };" ;; esac
    fi
    if [ -n "$_mrt" ]; then
        case "$_mrt" in all|off) echo "    mrtdump $_mrt;" ;; *) echo "    mrtdump { $(echo "$_mrt" | sed 's/,/, /g') };" ;; esac
    fi
    echo "    $_chan {"
    [ -n "$_pref" ] && echo "        preference $_pref;"
    case "$_import" in
        where\ *) _wcond=${_import#where }; _wbird=$(cond_translate "$_wcond") || exit 33; echo "        import where $_wbird;" ;;
        *) echo "        import $_import;" ;;
    esac
    case "$_ikf" in on) echo "        import keep filtered on;" ;; off) echo "        import keep filtered off;" ;; esac
    emit_limit "$_i" import
    emit_limit "$_i" receive
    if [ -n "$_m1" ] || [ -n "$_m2" ] || [ -n "$_tag" ]; then
        echo "        export filter {"
        [ -n "$_m1" ] && echo "            ospf_metric1 = $_m1;"
        [ -n "$_m2" ] && echo "            ospf_metric2 = $_m2;"
        [ -n "$_tag" ] && echo "            ospf_tag = $_tag;"
        echo "            accept;"
        echo "        };"
    else
        case "$_export" in
            where\ *) _wcond=${_export#where }; _wbird=$(cond_translate "$_wcond") || exit 33; echo "        export where $_wbird;" ;;
            *) echo "        export $_export;" ;;
        esac
    fi
    emit_limit "$_i" export
    echo "    };"
    set -f
    for _a in $(grep "^instance $_i area " "$CONF" 2>/dev/null | awk '{print $4}' | awk '!s[$0]++'); do
        emit_area "$_i" "$_a"
    done
    set +f
    echo "}"
    echo ""
}

cmd_generate() {
    touch_conf
    set -f
    mkdir -p "$SECTION_DIR" 2>/dev/null || die "cannot mkdir $SECTION_DIR"
    _tmp="$SECTION.tmp.$$"
    # Guard: autentikasi tanpa password tidak bisa jalan — tolak
    # dengan pesan jelas (BIRD juga akan menolaknya saat parse).
    # `simple` di OSPFv3 sudah ditolak saat set; cek ulang di sini.
    for _i in ospf ospf6; do
        for _a in $(grep "^instance $_i area " "$CONF" 2>/dev/null | awk '{print $4}' | awk '!s[$0]++'); do
            _are=$(re_esc "$_a")
            for _pat in $(grep "^instance $_i area $_are interface " "$CONF" 2>/dev/null | awk '{print $6}' | awk '!s[$0]++'); do
                _auth=$(get_iface_field "$_i" "$_a" "$_pat" authentication)
                case "$_auth" in
                    simple)
                        [ "$_i" = "ospf6" ] && err "interface $_pat (area $_a, ospf6) authentication simple TIDAK tersedia di OSPFv3 — pakai cryptographic"
                        ;;
                esac
                case "$_auth" in
                    simple|cryptographic)
                        _pre=$(re_esc "$_pat")
                        grep -q "^instance $_i area $_are interface $_pre password " "$CONF" 2>/dev/null || \
                            err "interface $_pat (area $_a, $_i) authentication $_auth tanpa password — tambah dulu password (router bird -> ospf -> area $_a -> interface $_pat -> password ...)"
                        ;;
                esac
            done
            for _r in $(grep "^instance $_i area $_are vlink " "$CONF" 2>/dev/null | awk '{print $6}' | awk '!s[$0]++'); do
                _auth=$(get_vlink_field "$_i" "$_a" "$_r" authentication)
                case "$_auth" in
                    simple)
                        [ "$_i" = "ospf6" ] && err "virtual link $_r (area $_a, ospf6) authentication simple TIDAK tersedia di OSPFv3 — pakai cryptographic"
                        ;;
                    simple|cryptographic)
                        _re2=$(re_esc "$_r")
                        grep -q "^instance $_i area $_are vlink $_re2 password " "$CONF" 2>/dev/null || \
                            err "virtual link $_r (area $_a, $_i) authentication $_auth tanpa password — tambah dulu password (router bird -> ospf -> area $_a -> virtual-link $_r -> password ...)"
                        ;;
                esac
            done
        done
    done
    # Guard: OSPF tanpa area ditolak BIRD ("No configured areas in
    # OSPF") — tolak dengan pesan jelas, jangan emit protocol cacat.
    for _i in ospf ospf6; do
        if inst_has "$_i"; then
            grep -q "^instance $_i area " "$CONF" 2>/dev/null || \
                err "OSPF $_i tanpa area — BIRD menolak protocol tanpa area (No configured areas in OSPF); tambah dulu area (router bird -> ospf -> area 0 ...)"
        fi
    done
    if has_facts; then
        {
            echo "# ospf.conf - generated by titian-ospf.sh, do not edit by hand"
            emit_instance ospf
            emit_instance ospf6
        } > "$_tmp" || die "cannot write $_tmp"
    else
        {
            echo "# ospf.conf - generated by titian-ospf.sh, do not edit by hand"
            echo "# (tidak ada config OSPF — protocol ospf tidak dibuat)"
        } > "$_tmp" || die "cannot write $_tmp"
    fi
    mv "$_tmp" "$SECTION" || die "cannot write $SECTION"
    chmod 644 "$SECTION" 2>/dev/null || true
    set +f
    echo "OSPF section ditulis: $SECTION"
    _birdsh="$(dirname "$0")/titian-bird.sh"
    if [ -x "$_birdsh" ]; then
        "$_birdsh" generate ospf || exit 33
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
    echo "--- ospf.conf (intent) ---"
    cat "$CONF"
    echo "--- bird.d/ospf.conf (section, bila ada) ---"
    [ -f "$SECTION" ] && cat "$SECTION" || echo "(belum di-generate)"
    echo "--- birdc show protocol ospf4 / ospf6 ---"
    _birdc=$(birdc_bin)
    _done=0
    for _inst in ospf4 ospf6; do
        if grep -q "protocol ospf.*$_inst" "$SECTION" 2>/dev/null; then
            if _out=$("$_birdc" $(birdc_sock) show protocol "$_inst" 2>&1); then
                echo "$_out" | grep -v '^BIRD'
                _done=1
            fi
        fi
    done
    [ "$_done" = "0" ] && echo "(BIRD tidak jalan / belum ada instance OSPF — birdc show protocol gagal)"
    echo "--- birdc show ospf neighbors ---"
    if _out=$("$_birdc" $(birdc_sock) show ospf neighbors 2>&1); then
        echo "$_out" | grep -v '^BIRD'
    else
        echo "(BIRD tidak jalan / belum ada neighbor OSPF — birdc show ospf neighbors gagal)"
    fi
    echo "--- catatan: ospf_router_id adalah atribut read-only (hanya dibaca di filter); router-id OSPF = router-id BIRD global ---"
    return 0
}

cmd_show_neighbors() {
    _birdc=$(birdc_bin)
    if _out=$("$_birdc" $(birdc_sock) show ospf neighbors 2>&1); then
        echo "$_out" | grep -v '^BIRD'
    else
        echo "(BIRD tidak jalan / belum ada neighbor OSPF — birdc show ospf neighbors gagal)"
    fi
    return 0
}

# --- pemecah ctx single-var (refactor persistensi, pola route-map FRR) ---
# klish 2.2.5: var PERTAMA menelan sisa viewid bila multi-var, jadi
# konteks view di-encode SATU var ber-delimiter `:`. Bidang TERAKHIR
# selalu remainder (password boleh mengandung `:`). Helper menaruh
# hasil di global _CX_*; dispatch meneruskannya ke cmd_* yang
# signaturenya TIDAK berubah (bodi fungsi utuh, risiko minimal).
split_area_ctx() { # <INST:AREA> -> _CX_I _CX_A
    case "$1" in
        *:*)
            _CX_I="${1%%:*}"; _CX_A="${1#*:}" ;;
        *) err "ctx area OSPF harus <INST>:<AREA>: $1" ;;
    esac
    valid_inst "$_CX_I"
    valid_area_id "$_CX_A"
}
split_if_ctx() { # <INST:AREA:IFACE> -> _CX_I _CX_A _CX_PAT
    case "$1" in *:*:*) ;; *) err "ctx interface OSPF harus <INST>:<AREA>:<IFACE>: $1" ;; esac
    _CX_I="${1%%:*}"; _r="${1#*:}"
    _CX_A="${_r%%:*}"; _CX_PAT="${_r#*:}"
    valid_inst "$_CX_I"
    valid_area_id "$_CX_A"
    [ -n "$_CX_PAT" ] || err "ctx interface OSPF butuh IFACE: $1"
}
split_vl_ctx() { # <INST:AREA:VLINK> -> _CX_I _CX_A _CX_VL
    case "$1" in *:*:*) ;; *) err "ctx vlink OSPF harus <INST>:<AREA>:<ROUTER-ID>: $1" ;; esac
    _CX_I="${1%%:*}"; _r="${1#*:}"
    _CX_A="${_r%%:*}"; _CX_VL="${_r#*:}"
    valid_inst "$_CX_I"
    valid_area_id "$_CX_A"
    [ -n "$_CX_VL" ] || err "ctx vlink OSPF butuh ROUTER-ID: $1"
}
split_pw_ctx() { # <INST:AREA:PARENT:SCOPE:TEXT> -> _CX_I _CX_A _CX_SCOPE _CX_PARENT _CX_TEXT
    # Urutan ctx mengikuti hierarki view (parent dulu, scope sesudah);
    # backend memakai urutan (scope, parent) — helper membalik.
    case "$1" in *:*:*:*:*) ;; *) err "ctx password OSPF harus <INST>:<AREA>:<PARENT>:<SCOPE>:<TEXT>: $1" ;; esac
    _CX_I="${1%%:*}"; _r="${1#*:}"
    _CX_A="${_r%%:*}"; _r="${_r#*:}"
    _CX_PARENT="${_r%%:*}"; _r="${_r#*:}"
    _CX_SCOPE="${_r%%:*}"; _CX_TEXT="${_r#*:}"
    valid_inst "$_CX_I"
    valid_area_id "$_CX_A"
    [ -n "$_CX_PARENT" ] && [ -n "$_CX_SCOPE" ] && [ -n "$_CX_TEXT" ] || \
        err "ctx password OSPF tidak lengkap: $1"
}

case "$1" in
    ospf-touch) shift; cmd_ospf_touch "$@" ;;
    has-facts) has_facts ;;
    switch-set) shift; cmd_switch_set "$@" ;;
    switch-del) shift; cmd_switch_del "$@" ;;
    router-id-set) shift; cmd_router_id_set "$@" ;;
    router-id-del) shift; cmd_router_id_del "$@" ;;
    description-set) shift; cmd_description_set "$@" ;;
    description-del) shift; cmd_description_del "$@" ;;
    instance-id-set) shift; cmd_instance_id_set "$@" ;;
    instance-id-del) shift; cmd_instance_id_del "$@" ;;
    tick-set) shift; cmd_tick_set "$@" ;;
    tick-del) shift; cmd_tick_del "$@" ;;
    ecmp-set) shift; cmd_ecmp_set "$@" ;;
    ecmp-del) shift; cmd_ecmp_del "$@" ;;
    ecmp-limit-set) shift; cmd_ecmp_limit_set "$@" ;;
    ecmp-limit-del) shift; cmd_ecmp_limit_del "$@" ;;
    gr-set) shift; cmd_gr_set "$@" ;;
    gr-del) shift; cmd_gr_del "$@" ;;
    gr-time-set) shift; cmd_gr_time_set "$@" ;;
    gr-time-del) shift; cmd_gr_time_del "$@" ;;
    channel-set) shift; cmd_channel_set "$@" ;;
    channel-del) shift; cmd_channel_del "$@" ;;
    chan-set) shift; cmd_chan_set "$@" ;;
    preference-set) shift; cmd_preference_set "$@" ;;
    preference-del) shift; cmd_preference_del "$@" ;;
    limit-set) shift; cmd_limit_set "$@" ;;
    limit-action-set) shift; cmd_limit_action_set "$@" ;;
    limit-del) shift; cmd_limit_del "$@" ;;
    import-keep-filtered-set) shift; cmd_ikf_set "$@" ;;
    import-keep-filtered-del) shift; cmd_ikf_del "$@" ;;
    debug-set) shift; cmd_debug_set "$@" ;;
    debug-del) shift; cmd_debug_del "$@" ;;
    mrtdump-set) shift; cmd_mrtdump_set "$@" ;;
    mrtdump-del) shift; cmd_mrtdump_del "$@" ;;
    export-attr-set) shift; cmd_export_attr_set "$@" ;;
    export-attr-del) shift; cmd_export_attr_del "$@" ;;
    area-add) shift; cmd_area_add "$@" ;;
    area-del) shift; cmd_area_del "$@" ;;
    area-flag-set) shift; split_area_ctx "$1"; shift; cmd_area_flag_set "$_CX_I" "$_CX_A" "$@" ;;
    area-flag-del) shift; split_area_ctx "$1"; shift; cmd_area_flag_del "$_CX_I" "$_CX_A" "$@" ;;
    area-set) shift; split_area_ctx "$1"; shift; cmd_area_set "$_CX_I" "$_CX_A" "$@" ;;
    area-unset) shift; split_area_ctx "$1"; shift; cmd_area_unset "$_CX_I" "$_CX_A" "$@" ;;
    network-add) shift; split_area_ctx "$1"; shift; cmd_network_add "$_CX_I" "$_CX_A" "$@" ;;
    network-del) shift; split_area_ctx "$1"; shift; cmd_network_del "$_CX_I" "$_CX_A" "$@" ;;
    external-add) shift; split_area_ctx "$1"; shift; cmd_external_add "$_CX_I" "$_CX_A" "$@" ;;
    external-del) shift; split_area_ctx "$1"; shift; cmd_external_del "$_CX_I" "$_CX_A" "$@" ;;
    stubnet-add) shift; split_area_ctx "$1"; shift; cmd_stubnet_add "$_CX_I" "$_CX_A" "$@" ;;
    stubnet-del) shift; split_area_ctx "$1"; shift; cmd_stubnet_del "$_CX_I" "$_CX_A" "$@" ;;
    stubnet-set) shift; split_area_ctx "$1"; shift; cmd_stubnet_set "$_CX_I" "$_CX_A" "$@" ;;
    stubnet-unset) shift; split_area_ctx "$1"; shift; cmd_stubnet_unset "$_CX_I" "$_CX_A" "$@" ;;
    interface-add) shift; split_area_ctx "$1"; shift; cmd_interface_add "$_CX_I" "$_CX_A" "$@" ;;
    interface-del) shift; split_area_ctx "$1"; shift; cmd_interface_del "$_CX_I" "$_CX_A" "$@" ;;
    interface-set) shift; split_if_ctx "$1"; shift; cmd_interface_set "$_CX_I" "$_CX_A" "$_CX_PAT" "$@" ;;
    interface-unset) shift; split_if_ctx "$1"; shift; cmd_interface_unset "$_CX_I" "$_CX_A" "$_CX_PAT" "$@" ;;
    neighbor-add) shift; split_if_ctx "$1"; shift; cmd_neighbor_add "$_CX_I" "$_CX_A" "$_CX_PAT" "$@" ;;
    neighbor-del) shift; split_if_ctx "$1"; shift; cmd_neighbor_del "$_CX_I" "$_CX_A" "$_CX_PAT" "$@" ;;
    vlink-add) shift; split_area_ctx "$1"; shift; cmd_vlink_add "$_CX_I" "$_CX_A" "$@" ;;
    vlink-del) shift; split_area_ctx "$1"; shift; cmd_vlink_del "$_CX_I" "$_CX_A" "$@" ;;
    vlink-set) shift; split_vl_ctx "$1"; shift; cmd_vlink_set "$_CX_I" "$_CX_A" "$_CX_VL" "$@" ;;
    vlink-unset) shift; split_vl_ctx "$1"; shift; cmd_vlink_unset "$_CX_I" "$_CX_A" "$_CX_VL" "$@" ;;
    password-add) shift; split_pw_ctx "$1"; shift; cmd_password_add "$_CX_I" "$_CX_A" "$_CX_SCOPE" "$_CX_PARENT" "$_CX_TEXT" "$@" ;;
    password-del) shift; split_pw_ctx "$1"; shift; cmd_password_del "$_CX_I" "$_CX_A" "$_CX_SCOPE" "$_CX_PARENT" "$_CX_TEXT" "$@" ;;
    password-set) shift; split_pw_ctx "$1"; shift; cmd_password_set "$_CX_I" "$_CX_A" "$_CX_SCOPE" "$_CX_PARENT" "$_CX_TEXT" "$@" ;;
    password-unset) shift; split_pw_ctx "$1"; shift; cmd_password_unset "$_CX_I" "$_CX_A" "$_CX_SCOPE" "$_CX_PARENT" "$_CX_TEXT" "$@" ;;
    generate) cmd_generate ;;
    show) cmd_show ;;
    show-neighbors) cmd_show_neighbors ;;
    *) echo "Usage: $0 {ospf-touch INST|has-facts|switch-set INST FIELD on|off|switch-del INST FIELD|router-id-set INST IP|router-id-del INST|description-set INST TEKS|description-del INST|instance-id-set INST N|instance-id-del INST|tick-set INST N|tick-del INST|ecmp-set INST on|off|ecmp-del INST|ecmp-limit-set INST N|ecmp-limit-del INST|gr-set INST off|aware|on|gr-del INST|gr-time-set INST N|gr-time-del INST|channel-set INST ipv4|ipv6|channel-del INST|chan-set INST import|export all|none|filter NAME|where COND|preference-set INST N|preference-del INST|import-keep-filtered-set INST on|off|import-keep-filtered-del INST|limit-set INST import|receive|export N|off [ACTION]|limit-action-set INST import|receive|export warn|block|restart|disable|limit-del INST import|receive|export|debug-set INST SPEC|debug-del INST|mrtdump-set INST SPEC|mrtdump-del INST|export-attr-set INST metric1|metric2|tag N|export-attr-del INST metric1|metric2|tag|area-add INST AREA|area-del INST AREA|area-flag-set CTX-AREA stub|nssa|area-flag-del CTX-AREA stub|nssa|area-set CTX-AREA FIELD VALUE|area-unset CTX-AREA FIELD|network-add CTX-AREA PREFIX [hidden]|network-del CTX-AREA PREFIX|external-add CTX-AREA PREFIX [hidden] [tag N]|external-del CTX-AREA PREFIX|stubnet-add CTX-AREA PREFIX|stubnet-del CTX-AREA PREFIX|stubnet-set CTX-AREA PREFIX FIELD VALUE|stubnet-unset CTX-AREA PREFIX FIELD|interface-add CTX-AREA PATTERN|interface-del CTX-AREA PATTERN|interface-set CTX-IFACE FIELD VALUE|interface-unset CTX-IFACE FIELD|neighbor-add CTX-IFACE IP [eligible]|neighbor-del CTX-IFACE IP|vlink-add CTX-AREA ROUTER-ID|vlink-del CTX-AREA ROUTER-ID|vlink-set CTX-VLINK FIELD VALUE|vlink-unset CTX-VLINK FIELD|password-add CTX-PW|password-del CTX-PW|password-set CTX-PW FIELD VALUE|password-unset CTX-PW FIELD|generate|show|show-neighbors}" >&2; exit 2 ;;
esac
