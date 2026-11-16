#!/bin/sh
# titian-rip.sh — RIP / RIPng intent (BIRD `protocol rip` / `protocol rip ng`)
# untuk Titian/klish.
# Pola sama seperti titian-static.sh: intent di /etc/titian/rip.conf
# (tmpfs, dipersistenkan via titian-cfg.sh), generate menulis section
# BIRD /etc/titian/bird.d/rip.conf lalu memanggil titian-bird.sh
# generate rip (render + validasi + birdc). Section ditulis ulang
# UTUH tiap apply.
#
# Sintaks BIRD 2.16.1 yang dipakai (docs resmi bird.network,
# User's Guide 2.16.1, §6.15 RIP):
#   protocol rip rip4 {
#       infinity <number>;
#       ecmp <switch> [limit <number>];
#       debug all|off|{ states, routes, filters, interfaces, events, packets };
#       mrtdump all|off|{ states, messages };
#       ipv4 {
#           preference <number>;
#           import keep filtered <switch>;
#           import all|none|filter <name>;
#           export all|none|filter <name>;
#       };
#       interface "<pattern>" {
#           metric <number>;
#           mode multicast|broadcast;
#           passive <switch>;
#           address <ip>;
#           port <number>;
#           version 1|2;
#           split horizon <switch>;
#           poison reverse <switch>;
#           demand circuit <switch>;
#           check zero <switch>;
#           update time <number>;
#           timeout time <number>;
#           garbage time <number>;
#           ecmp weight <number>;
#           ttl security <switch>|tx only;
#           tx class|dscp <number>;
#           rx buffer <number>;
#           tx length <number>;
#           check link <switch>;
#           authentication none|plaintext|cryptographic;
#           password "<text>" { id <num>; generate from "<date>";
#               generate to "<date>"; accept from "<date>";
#               accept to "<date>"; from "<date>"; to "<date>";
#               algorithm (keyed md5|keyed sha1|hmac sha1|hmac sha256|
#               hmac sha384|hmac sha512); };
#       };
#   }
#   protocol rip ng ripng6 {
#       infinity <number>;
#       ecmp <switch> [limit <number>];
#       ipv6 { import ...; export ...; };
#       interface "<pattern>" { ... };   # tanpa `version`
#   }
# Satu instance = satu network type: RIP = IPv4 (v1/v2), RIPng = IPv6
# (`protocol rip ng`, tidak ada opsi `version`). Satu channel per
# instance; tanpa channel, channel default dibuat otomatis — klish
# selalu menulis channel eksplisit (default import all / export all,
# sama seperti contoh docs Bab 6.15).
# Default BIRD (docs 2.16.1): infinity 16; ecmp enabled bila Kernel
# mendukung, limit 16; metric 1 (range 1..255); mode multicast untuk
# RIPv2, broadcast untuk RIPv1, RIPng selalu multicast; passive no;
# address 224.0.0.9 (RIP) / ff02::9 (RIPng); port 520 (RIP) / 521
# (RIPng); version 2; split horizon yes; poison reverse yes; demand
# circuit no; check zero yes; update time 30; timeout time 180;
# garbage time 120; ecmp weight 1 (range 1..256); ttl security yes
# untuk RIPng, no untuk IPv4 RIP; rx buffer 532 (RIP) / MTU (RIPng);
# tx length 532 (RIP) / MTU (RIPng); check link yes; authentication
# none; algoritma default kunci RIP = keyed-MD5; rip_metric default 1
# dan rip_tag default 0 untuk route non-RIP yang diekspor ke RIP.
# Default yang TIDAK ditulis di section (BIRD yang memakai defaultnya)
# kecuali user mengaturnya eksplisit di klish.
#
# TIDAK diimplementasi di batch ini:
#   - `version only` (R12): dideskripsikan di teks Bab 6.15 tapi TIDAK
#     ADA di blok template sintaks — PERLU VERIFIKASI via `bird -p`
#     sebelum masuk klish (lihat BIRD-COVERAGE.md §2.4 R12).
#   - `tx priority` (R23): Linux-specific (lihat Bab 3.4-10); tidak ada
#     padanan FreeBSD.
#   - `rip_metric` / `rip_tag` sebagai filter umum: hanya didukung
#     sebagai atribut export channel (export-rip-metric / export-rip-tag
#     di bawah); penulisan bebas di filter Bab 5 menyusul batch filter.
#
# Format rip.conf (satu baris per fakta; <I> = rip|ripng):
#   instance <I> infinity <N>
#   instance <I> ecmp <on|off>
#   instance <I> ecmp-limit <N>
#   instance <I> import <all|none|filter NAME>
#   instance <I> export <all|none|filter NAME>
#   instance <I> export-rip-metric <N>      (0..255, default BIRD 1)
#   instance <I> export-rip-tag <N>         (0..65535, default BIRD 0)
#   instance <I> interface <PAT> <field> <value>
#     field: metric|mode|passive|address|port|version|split-horizon|
#       poison-reverse|demand-circuit|check-zero|update-time|
#       timeout-time|garbage-time|ecmp-weight|ttl-security|tx-class|
#       tx-dscp|rx-buffer|tx-length|check-link|authentication
#   instance <I> interface <PAT> password <TEXT>
#   instance <I> interface <PAT> password <TEXT> <field> <value>
#     field password: id|generate-from|generate-to|accept-from|
#       accept-to|from|to|algorithm
#     (TEXT tanpa spasi, tanpa `"` dan tanpa `\`; tanggal ditulis
#     `YYYY-MM-DD` atau `YYYY-MM-DDTHH:MM[:SS]` — `T` diubah jadi
#     spasi saat generate; algorithm ditulis `hmac-sha256` dst dan
#     diubah jadi `hmac sha256` saat generate.)
#
# Urutan apply (titian-commit.sh): apply_rip sesudah apply_static,
# sebelum apply_bgp. RIP tidak bergantung pada BFD.

STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CONF="$STATE_ROOT/rip.conf"
SECTION_DIR="$STATE_ROOT/bird.d"
SECTION="$SECTION_DIR/rip.conf"
PROG="titian-rip"
err() { echo "Error($PROG): $*" >&2; exit 33; }
die() { echo "$PROG: $*" >&2; exit 1; }

touch_conf() {
    if [ ! -f "$CONF" ]; then
        mkdir -p "$(dirname "$CONF")" 2>/dev/null
        printf '# rip.conf - generated by klish, do not edit by hand\n' > "$CONF" \
            || die "cannot create $CONF"
        chmod 600 "$CONF" 2>/dev/null || true
    fi
}

# re_esc <teks> — escape karakter regex (untuk pola interface yang
# boleh mengandung `*`, mis. "ge*") agar grep -v tidak salah hapus.
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
        rip|ripng) ;;
        *) err "instance harus rip|ripng: $1" ;;
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

valid_date() {
    # $1=tanggal $2=konteks: YYYY-MM-DD atau YYYY-MM-DDTHH:MM[:SS].
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]) ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
        *) err "$2 harus tanggal YYYY-MM-DD atau YYYY-MM-DDTHH:MM[:SS]: $1" ;;
    esac
}

# inst_has <rip|ripng>: exit 0 bila ada >=1 fakta instance itu.
inst_has() {
    grep -q "^instance $1 " "$CONF" 2>/dev/null
}

# iface_has <inst> <pattern>: exit 0 bila interface itu punya fakta.
iface_has() {
    _re=$(re_esc "$2")
    grep -q "^instance $1 interface $_re " "$CONF" 2>/dev/null
}

cmd_rip_touch() {
    # $1 = rip|ripng
    valid_inst "$1"
    touch_conf
    echo "RIP $1"
}

# --- opsi level instance ---
cmd_infinity_set() {
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "infinity butuh nilai"
    valid_num "$_v" 1 255 "infinity"
    upsert "^instance $_i infinity " "instance $_i infinity $_v"
    echo "RIP $_i infinity = $_v"
}

cmd_infinity_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i infinity "
    echo "RIP $_i infinity dihapus (default BIRD 16)"
}

cmd_ecmp_set() {
    _i="$1"; _v="$2"
    valid_inst "$_i"
    valid_onoff "$_v" "ecmp"
    upsert "^instance $_i ecmp " "instance $_i ecmp $_v"
    echo "RIP $_i ecmp = $_v"
}

cmd_ecmp_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i ecmp "
    dellines "^instance $_i ecmp-limit "
    echo "RIP $_i ecmp dihapus (default BIRD: enabled bila Kernel mendukung)"
}

cmd_ecmp_limit_set() {
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "ecmp-limit butuh nilai"
    valid_num "$_v" 1 256 "ecmp-limit"
    upsert "^instance $_i ecmp-limit " "instance $_i ecmp-limit $_v"
    echo "RIP $_i ecmp-limit = $_v"
}

cmd_ecmp_limit_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i ecmp-limit "
    echo "RIP $_i ecmp-limit dihapus (default BIRD 16)"
}

cmd_chan_set() {
    # chan-set <inst> <import|export> <all|none|filter NAME>
    _i="$1"; _d="$2"; _v="$3"; _n="$4"
    valid_inst "$_i"
    case "$_d" in import|export) ;; *) err "channel harus import|export: $_d" ;; esac
    case "$_v" in
        all|none) upsert "^instance $_i $_d " "instance $_i $_d $_v" ;;
        filter)
            [ -n "$_n" ] || err "$_d filter butuh NAMA filter"
            valid_name "$_n" "nama filter"
            upsert "^instance $_i $_d " "instance $_i $_d filter $_n" ;;
        *) err "$_d harus all|none|filter NAME: $_v" ;;
    esac
    echo "RIP $_i $_d = $_v${_n:+ $_n}"
}

_rip_valid_spec() { # <SPEC> <debug|mrtdump> — validasi daftar kelas koma
    _rp_spec="$1"; _rp_kind="$2"
    [ -n "$_rp_spec" ] || err "$_rp_kind butuh all|off|kelas,kelas,..."
    case "$_rp_spec" in all|off) return 0 ;; esac
    _rp_rest="$_rp_spec"
    while [ -n "$_rp_rest" ]; do
        case "$_rp_rest" in *,*) _rp_done=${_rp_rest%%,*}; _rp_rest=${_rp_rest#*,} ;; *) _rp_done="$_rp_rest"; _rp_rest="" ;; esac
        if [ "$_rp_kind" = "debug" ]; then
            case "$_rp_done" in states|routes|filters|interfaces|events|packets) ;; *) err "debug kelas tidak dikenal: $_rp_done (boleh: states|routes|filters|interfaces|events|packets)" ;; esac
        else
            case "$_rp_done" in states|messages) ;; *) err "mrtdump kelas tidak dikenal: $_rp_done (boleh: states|messages)" ;; esac
        fi
    done
}
cmd_preference_set() { # B8: preference-set INST N (0..65535, Bab 3.5-3)
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "preference butuh nilai"
    valid_num "$_v" 0 65535 "preference"
    upsert "^instance $_i preference " "instance $_i preference $_v"
    echo "RIP $_i preference = $_v"
}
cmd_preference_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i preference "
    echo "RIP $_i preference dihapus (default BIRD tergantung protokol)"
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
        echo "RIP $_i $_k-limit = $_v action $_a"
    else
        echo "RIP $_i $_k-limit = $_v"
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
    echo "RIP $_i $_k-limit-action = $_a"
}
cmd_limit_del() { # B9: limit-del INST KIND — hapus limit + action-nya
    _i="$1"; _k="$2"
    valid_inst "$_i"
    case "$_k" in import|receive|export) ;; *) err "$_k harus import|receive|export" ;; esac
    dellines "^instance $_i $_k-limit "
    dellines "^instance $_i $_k-limit-action "
    echo "RIP $_i $_k-limit dihapus (default BIRD tanpa limit)"
}
cmd_ikf_set() { # B8: import-keep-filtered-set INST on|off (Bab 3.5-6)
    _i="$1"; _v="$2"
    valid_inst "$_i"
    valid_onoff "$_v" "import-keep-filtered"
    upsert "^instance $_i import-keep-filtered " "instance $_i import-keep-filtered $_v"
    echo "RIP $_i import-keep-filtered = $_v"
}
cmd_ikf_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i import-keep-filtered "
    echo "RIP $_i import-keep-filtered dihapus (default BIRD off)"
}
cmd_debug_set() { # B8: debug-set INST SPEC (Bab 3.4-2)
    _i="$1"; _v="$2"
    valid_inst "$_i"
    _rip_valid_spec "$_v" debug
    upsert "^instance $_i debug " "instance $_i debug $_v"
    echo "RIP $_i debug = $_v"
}
cmd_debug_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i debug "
    echo "RIP $_i debug dihapus (default BIRD off)"
}
cmd_mrtdump_set() { # B8: mrtdump-set INST SPEC (Bab 3.4-3)
    _i="$1"; _v="$2"
    valid_inst "$_i"
    _rip_valid_spec "$_v" mrtdump
    upsert "^instance $_i mrtdump " "instance $_i mrtdump $_v"
    echo "RIP $_i mrtdump = $_v"
}
cmd_mrtdump_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i mrtdump "
    echo "RIP $_i mrtdump dihapus (default BIRD off)"
}
cmd_export_metric_set() {
    # export-rip-metric <inst> <N>: rip_metric route non-RIP yg diekspor.
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "export-rip-metric butuh nilai"
    valid_num "$_v" 0 255 "export-rip-metric"
    upsert "^instance $_i export-rip-metric " "instance $_i export-rip-metric $_v"
    echo "RIP $_i export-rip-metric = $_v"
}

cmd_export_metric_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i export-rip-metric "
    echo "RIP $_i export-rip-metric dihapus (default BIRD 1)"
}

cmd_export_tag_set() {
    _i="$1"; _v="$2"
    valid_inst "$_i"
    [ -n "$_v" ] || err "export-rip-tag butuh nilai"
    valid_num "$_v" 0 65535 "export-rip-tag"
    upsert "^instance $_i export-rip-tag " "instance $_i export-rip-tag $_v"
    echo "RIP $_i export-rip-tag = $_v"
}

cmd_export_tag_del() {
    _i="$1"
    valid_inst "$_i"
    dellines "^instance $_i export-rip-tag "
    echo "RIP $_i export-rip-tag dihapus (default BIRD 0)"
}

# --- interface ---
cmd_interface_add() {
    _i="$1"; _pat="$2"
    valid_inst "$_i"
    [ -n "$_pat" ] || err "interface-add butuh pola interface (mis. ge*)"
    valid_pattern "$_pat" "interface"
    touch_conf
    # Perbaikan persistensi (pola F3.2 OSPF / B.4 Babel): interface-add
    # HARUS menulis baris telanjang — sebelumnya no-op, interface tanpa
    # field tidak pernah ter-render. Emitter mengiterasi baris
    # `instance <I> interface ...` dan mencetak blok (kosong pun).
    _re=$(re_esc "$_pat")
    if ! grep -q "^instance $_i interface $_re " "$CONF" 2>/dev/null && \
       ! grep -q "^instance $_i interface $_re\$" "$CONF" 2>/dev/null; then
        printf 'instance %s interface %s\n' "$_i" "$_pat" >> "$CONF"
    fi
    echo "RIP $_i interface $_pat"
}

cmd_interface_del() {
    _i="$1"; _pat="$2"
    valid_inst "$_i"
    [ -n "$_pat" ] || err "interface-del butuh pola interface"
    # JANGAN pakai nama `_re`: dellines() menimpa `_re` global — panggilan
    # kedua akan memakai pola pertama (bug yang sama dengan B3 di
    # password-del; di sini baris telanjang `instance ... interface X`
    # tidak pernah terhapus — ketahuan mock B10).
    _patre=$(re_esc "$_pat")
    dellines "^instance $_i interface $_patre "
    dellines "^instance $_i interface $_patre\$"
    echo "RIP $_i interface $_pat dihapus"
}

cmd_interface_set() {
    # interface-set <inst> <PATTERN> <field> <value>
    _i="$1"; _pat="$2"; _f="$3"; _v="$4"
    valid_inst "$_i"
    [ -n "$_pat" ] && [ -n "$_f" ] && [ -n "$_v" ] || \
        err "interface-set butuh INSTANCE PATTERN FIELD VALUE"
    valid_pattern "$_pat" "interface"
    _re=$(re_esc "$_pat")
    case "$_f" in
        metric)
            valid_num "$_v" 1 255 "metric"
            upsert "^instance $_i interface $_re metric " "instance $_i interface $_pat metric $_v" ;;
        mode)
            case "$_v" in
                multicast) upsert "^instance $_i interface $_re mode " "instance $_i interface $_pat mode multicast" ;;
                broadcast)
                    [ "$_i" = "ripng" ] && err "mode broadcast tidak berlaku di RIPng (RIPng selalu multicast)"
                    upsert "^instance $_i interface $_re mode " "instance $_i interface $_pat mode broadcast" ;;
                *) err "mode harus multicast|broadcast: $_v" ;;
            esac ;;
        passive)
            valid_onoff "$_v" "passive"
            upsert "^instance $_i interface $_re passive " "instance $_i interface $_pat passive $_v" ;;
        address)
            valid_ip "$_v" "address"
            if [ "$_i" = "rip" ]; then
                [ "$(ip_family "$_v")" = "4" ] || err "address RIP (IPv4) harus alamat IPv4: $_v"
            else
                [ "$(ip_family "$_v")" = "6" ] || err "address RIPng (IPv6) harus alamat IPv6: $_v"
            fi
            upsert "^instance $_i interface $_re address " "instance $_i interface $_pat address $_v" ;;
        port)
            valid_num "$_v" 1 65535 "port"
            upsert "^instance $_i interface $_re port " "instance $_i interface $_pat port $_v" ;;
        version)
            [ "$_i" = "ripng" ] && err "version tidak didukung di RIPng (hanya RIP IPv4, version 1|2)"
            case "$_v" in
                1|2) upsert "^instance $_i interface $_re version " "instance $_i interface $_pat version $_v" ;;
                *) err "version harus 1|2: $_v" ;;
            esac ;;
        split-horizon|poison-reverse|demand-circuit|check-zero|check-link)
            valid_onoff "$_v" "$_f"
            upsert "^instance $_i interface $_re $_f " "instance $_i interface $_pat $_f $_v" ;;
        update-time|timeout-time|garbage-time)
            valid_num "$_v" 1 86400 "$_f"
            upsert "^instance $_i interface $_re $_f " "instance $_i interface $_pat $_f $_v" ;;
        ecmp-weight)
            valid_num "$_v" 1 256 "ecmp-weight"
            upsert "^instance $_i interface $_re ecmp-weight " "instance $_i interface $_pat ecmp-weight $_v" ;;
        ttl-security)
            case "$_v" in
                on|off|tx-only) upsert "^instance $_i interface $_re ttl-security " "instance $_i interface $_pat ttl-security $_v" ;;
                *) err "ttl-security harus on|off|tx-only: $_v" ;;
            esac ;;
        tx-class)
            valid_num "$_v" 0 255 "tx-class"
            upsert "^instance $_i interface $_re tx-class " "instance $_i interface $_pat tx-class $_v" ;;
        tx-dscp)
            valid_num "$_v" 0 63 "tx-dscp"
            upsert "^instance $_i interface $_re tx-dscp " "instance $_i interface $_pat tx-dscp $_v" ;;
        rx-buffer|tx-length)
            valid_num "$_v" 1 65535 "$_f"
            upsert "^instance $_i interface $_re $_f " "instance $_i interface $_pat $_f $_v" ;;
        authentication)
            case "$_v" in
                none|plaintext|cryptographic) upsert "^instance $_i interface $_re authentication " "instance $_i interface $_pat authentication $_v" ;;
                *) err "authentication harus none|plaintext|cryptographic: $_v" ;;
            esac ;;
        *) err "field interface RIP tidak dikenal: $_f (metric|mode|passive|address|port|version|split-horizon|poison-reverse|demand-circuit|check-zero|update-time|timeout-time|garbage-time|ecmp-weight|ttl-security|tx-class|tx-dscp|rx-buffer|tx-length|check-link|authentication)" ;;
    esac
    echo "RIP $_i interface $_pat $_f = $_v"
}

cmd_interface_unset() {
    # interface-unset <inst> <PATTERN> <field>: hapus satu opsi interface.
    _i="$1"; _pat="$2"; _f="$3"
    valid_inst "$_i"
    [ -n "$_pat" ] && [ -n "$_f" ] || err "interface-unset butuh INSTANCE PATTERN FIELD"
    _re=$(re_esc "$_pat")
    case "$_f" in
        metric|mode|passive|address|port|version|split-horizon|poison-reverse|demand-circuit|check-zero|update-time|timeout-time|garbage-time|ecmp-weight|ttl-security|tx-class|tx-dscp|rx-buffer|tx-length|check-link|authentication)
            dellines "^instance $_i interface $_re $_f " ;;
        password)
            err "password dihapus via password-del (hapus kunci + semua sub-opsinya sekaligus)" ;;
        *) err "field interface RIP tidak dikenal: $_f" ;;
    esac
    echo "RIP $_i interface $_pat $_f dihapus (kembali ke default BIRD)"
}

# --- password (per interface, bisa banyak — rotasi kunci) ---
cmd_password_add() {
    # password-add <inst> <PATTERN> <TEXT>
    _i="$1"; _pat="$2"; _pw="$3"
    valid_inst "$_i"
    [ -n "$_pat" ] && [ -n "$_pw" ] || err "password-add butuh INSTANCE PATTERN PASSWORD"
    valid_pattern "$_pat" "interface"
    valid_password "$_pw"
    _re=$(re_esc "$_pat"); _pwre=$(re_esc "$_pw")
    if grep -q "^instance $_i interface $_re password $_pwre\$" "$CONF" 2>/dev/null || \
       grep -q "^instance $_i interface $_re password $_pwre " "$CONF" 2>/dev/null; then
        echo "RIP $_i interface $_pat password sudah ada"
        return 0
    fi
    touch_conf
    printf 'instance %s interface %s password %s\n' "$_i" "$_pat" "$_pw" >> "$CONF"
    echo "RIP $_i interface $_pat password ditambahkan"
}

cmd_password_del() {
    # password-del <inst> <PATTERN> <TEXT>: hapus kunci + sub-opsinya.
    _i="$1"; _pat="$2"; _pw="$3"
    valid_inst "$_i"
    [ -n "$_pat" ] && [ -n "$_pw" ] || err "password-del butuh INSTANCE PATTERN PASSWORD"
    # JANGAN pakai nama `_re`: dellines()/upsert() menimpa `_re`
    # global — panggilan kedua akan memakai pola pertama (bug B3).
    _patre=$(re_esc "$_pat"); _pwre=$(re_esc "$_pw")
    # Dua pola (tanpa alternasi BRE): baris telanjang
    # `password <pw>` di ujung baris, dan baris sub-opsi
    # `password <pw> <field> ...`.
    dellines "^instance $_i interface $_patre password $_pwre\$"
    dellines "^instance $_i interface $_patre password $_pwre "
    echo "RIP $_i interface $_pat password dihapus"
}

cmd_password_set() {
    # password-set <inst> <PATTERN> <TEXT> <field> <value...>
    # field: id|generate-from|generate-to|accept-from|accept-to|from|to|algorithm
    _i="$1"; _pat="$2"; _pw="$3"; _f="$4"; shift 4
    _v="$*"
    valid_inst "$_i"
    [ -n "$_pat" ] && [ -n "$_pw" ] && [ -n "$_f" ] && [ -n "$_v" ] || \
        err "password-set butuh INSTANCE PATTERN PASSWORD FIELD VALUE"
    valid_pattern "$_pat" "interface"
    valid_password "$_pw"
    _re=$(re_esc "$_pat"); _pwre=$(re_esc "$_pw")
    grep -q "^instance $_i interface $_re password $_pwre\$" "$CONF" 2>/dev/null || \
    grep -q "^instance $_i interface $_re password $_pwre " "$CONF" 2>/dev/null || \
        err "password belum ada di interface $_pat (tambah dulu: password \"$_pw\")"
    case "$_f" in
        id)
            valid_num "$_v" 0 4294967295 "password id"
            upsert "^instance $_i interface $_re password $_pwre id " "instance $_i interface $_pat password $_pw id $_v" ;;
        generate-from|generate-to|accept-from|accept-to|from|to)
            valid_date "$_v" "password $_f"
            upsert "^instance $_i interface $_re password $_pwre $_f " "instance $_i interface $_pat password $_pw $_f $_v" ;;
        algorithm)
            case "$_v" in
                keyed-md5|keyed-sha1|hmac-sha1|hmac-sha256|hmac-sha384|hmac-sha512)
                    upsert "^instance $_i interface $_re password $_pwre algorithm " "instance $_i interface $_pat password $_pw algorithm $_v" ;;
                *) err "algorithm harus keyed-md5|keyed-sha1|hmac-sha1|hmac-sha256|hmac-sha384|hmac-sha512: $_v" ;;
            esac ;;
        *) err "field password tidak dikenal: $_f (id|generate-from|generate-to|accept-from|accept-to|from|to|algorithm)" ;;
    esac
    echo "RIP $_i interface $_pat password $_f = $_v"
}

cmd_password_unset() {
    # password-unset <inst> <PATTERN> <TEXT> <field>
    _i="$1"; _pat="$2"; _pw="$3"; _f="$4"
    valid_inst "$_i"
    [ -n "$_pat" ] && [ -n "$_pw" ] && [ -n "$_f" ] || \
        err "password-unset butuh INSTANCE PATTERN PASSWORD FIELD"
    _re=$(re_esc "$_pat"); _pwre=$(re_esc "$_pw")
    case "$_f" in
        id|generate-from|generate-to|accept-from|accept-to|from|to|algorithm)
            dellines "^instance $_i interface $_re password $_pwre $_f " ;;
        *) err "field password tidak dikenal: $_f" ;;
    esac
    echo "RIP $_i interface $_pat password $_f dihapus"
}

# --- getters (untuk generate) ---
get_inst_field() {
    # $1=inst $2=field -> nilai (kolom 4; untuk import/export filter
    # nama ada di kolom 4, lihat get_chan di bawah)
    grep "^instance $1 $2 " "$CONF" 2>/dev/null | head -1 | awk '{print $4}'
}

get_chan() {
    # $1=inst $2=import|export -> "all"|"none"|"filter NAME"
    grep "^instance $1 $2 " "$CONF" 2>/dev/null | head -1 | awk '{$1=""; $2=""; $3=""; sub(/^ +/, ""); print}'
}

get_iface_field() {
    # $1=inst $2=pattern $3=field -> nilai (kolom 6)
    _re=$(re_esc "$2")
    grep "^instance $1 interface $_re $3 " "$CONF" 2>/dev/null | head -1 | awk '{print $6}'
}

get_pw_field() {
    # $1=inst $2=pattern $3=password $4=field -> nilai (kolom 7..)
    _re=$(re_esc "$2"); _pwre=$(re_esc "$3")
    grep "^instance $1 interface $_re password $_pwre $4 " "$CONF" 2>/dev/null | head -1 | awk '{$1=""; $2=""; $3=""; $4=""; $5=""; $6=""; $7=""; sub(/^ +/, ""); print}'
}

# emit_passwords <inst> <pattern>: cetak statement `password ...;`
# (indent 8 spasi) untuk semua kunci interface itu, urut kemunculan.
emit_passwords() {
    _i="$1"; _pat="$2"
    _re=$(re_esc "$_pat")
    set -f
    for _pw in $(grep "^instance $_i interface $_re password " "$CONF" 2>/dev/null | awk '{print $6}' | awk '!s[$0]++'); do
        _id=$(get_pw_field "$_i" "$_pat" "$_pw" id)
        _gf=$(get_pw_field "$_i" "$_pat" "$_pw" generate-from)
        _gt=$(get_pw_field "$_i" "$_pat" "$_pw" generate-to)
        _af=$(get_pw_field "$_i" "$_pat" "$_pw" accept-from)
        _at=$(get_pw_field "$_i" "$_pat" "$_pw" accept-to)
        _fr=$(get_pw_field "$_i" "$_pat" "$_pw" from)
        _to=$(get_pw_field "$_i" "$_pat" "$_pw" to)
        _al=$(get_pw_field "$_i" "$_pat" "$_pw" algorithm)
        if [ -n "$_id" ] || [ -n "$_gf" ] || [ -n "$_gt" ] || [ -n "$_af" ] || [ -n "$_at" ] || [ -n "$_fr" ] || [ -n "$_to" ] || [ -n "$_al" ]; then
            _stmt="        password \"$_pw\" {"
            [ -n "$_id" ] && _stmt="$_stmt id $_id;"
            [ -n "$_gf" ] && _stmt="$_stmt generate from \"$(printf '%s' "$_gf" | tr 'T' ' ')\";"
            [ -n "$_gt" ] && _stmt="$_stmt generate to \"$(printf '%s' "$_gt" | tr 'T' ' ')\";"
            [ -n "$_af" ] && _stmt="$_stmt accept from \"$(printf '%s' "$_af" | tr 'T' ' ')\";"
            [ -n "$_at" ] && _stmt="$_stmt accept to \"$(printf '%s' "$_at" | tr 'T' ' ')\";"
            [ -n "$_fr" ] && _stmt="$_stmt from \"$(printf '%s' "$_fr" | tr 'T' ' ')\";"
            [ -n "$_to" ] && _stmt="$_stmt to \"$(printf '%s' "$_to" | tr 'T' ' ')\";"
            [ -n "$_al" ] && _stmt="$_stmt algorithm $(printf '%s' "$_al" | tr '-' ' ');"
            printf '%s };\n' "$_stmt"
        else
            printf '        password "%s";\n' "$_pw"
        fi
    done
    set +f
}

# emit_switch <inst> <pattern> <field> <bird-name>: cetak
# `    <bird-name> yes|no;` bila fakta ada.
emit_switch() {
    _v=$(get_iface_field "$1" "$2" "$3")
    case "$_v" in
        on) printf '        %s yes;\n' "$4" ;;
        off) printf '        %s no;\n' "$4" ;;
    esac
}

# emit_iface <inst> <pattern>: cetak blok interface BIRD.
emit_iface() {
    _i="$1"; _pat="$2"
    _metric=$(get_iface_field "$_i" "$_pat" metric)
    _mode=$(get_iface_field "$_i" "$_pat" mode)
    _passive=$(get_iface_field "$_i" "$_pat" passive)
    _addr=$(get_iface_field "$_i" "$_pat" address)
    _port=$(get_iface_field "$_i" "$_pat" port)
    _ver=$(get_iface_field "$_i" "$_pat" version)
    _ut=$(get_iface_field "$_i" "$_pat" update-time)
    _tt=$(get_iface_field "$_i" "$_pat" timeout-time)
    _gt=$(get_iface_field "$_i" "$_pat" garbage-time)
    _ew=$(get_iface_field "$_i" "$_pat" ecmp-weight)
    _ttl=$(get_iface_field "$_i" "$_pat" ttl-security)
    _txc=$(get_iface_field "$_i" "$_pat" tx-class)
    _txd=$(get_iface_field "$_i" "$_pat" tx-dscp)
    _rxb=$(get_iface_field "$_i" "$_pat" rx-buffer)
    _txl=$(get_iface_field "$_i" "$_pat" tx-length)
    _auth=$(get_iface_field "$_i" "$_pat" authentication)
    echo "    interface \"$_pat\" {"
    [ -n "$_metric" ] && echo "        metric $_metric;"
    [ -n "$_mode" ] && echo "        mode $_mode;"
    [ "$_passive" = "on" ] && echo "        passive yes;"
    [ "$_passive" = "off" ] && echo "        passive no;"
    [ -n "$_addr" ] && echo "        address $_addr;"
    [ -n "$_port" ] && echo "        port $_port;"
    [ -n "$_ver" ] && echo "        version $_ver;"
    emit_switch "$_i" "$_pat" split-horizon "split horizon"
    emit_switch "$_i" "$_pat" poison-reverse "poison reverse"
    emit_switch "$_i" "$_pat" demand-circuit "demand circuit"
    emit_switch "$_i" "$_pat" check-zero "check zero"
    [ -n "$_ut" ] && echo "        update time $_ut;"
    [ -n "$_tt" ] && echo "        timeout time $_tt;"
    [ -n "$_gt" ] && echo "        garbage time $_gt;"
    [ -n "$_ew" ] && echo "        ecmp weight $_ew;"
    case "$_ttl" in
        on) echo "        ttl security yes;" ;;
        off) echo "        ttl security no;" ;;
        tx-only) echo "        ttl security tx only;" ;;
    esac
    [ -n "$_txc" ] && echo "        tx class $_txc;"
    [ -n "$_txd" ] && echo "        tx dscp $_txd;"
    [ -n "$_rxb" ] && echo "        rx buffer $_rxb;"
    [ -n "$_txl" ] && echo "        tx length $_txl;"
    emit_switch "$_i" "$_pat" check-link "check link"
    [ -n "$_auth" ] && echo "        authentication $_auth;"
    emit_passwords "$_i" "$_pat"
    echo "    };"
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

# emit_instance <rip|ripng>: cetak blok `protocol rip ... { ... }`.
emit_instance() {
    _i="$1"
    inst_has "$_i" || return 0
    _inf=$(get_inst_field "$_i" infinity)
    _ecmp=$(get_inst_field "$_i" ecmp)
    _eclimit=$(get_inst_field "$_i" ecmp-limit)
    _import=$(get_chan "$_i" import)
    _export=$(get_chan "$_i" export)
    _rmetric=$(get_inst_field "$_i" export-rip-metric)
    _rtag=$(get_inst_field "$_i" export-rip-tag)
    _pref=$(get_inst_field "$_i" preference)
    _ikf=$(get_inst_field "$_i" import-keep-filtered)
    _dbg=$(get_inst_field "$_i" debug)
    _mrt=$(get_inst_field "$_i" mrtdump)
    [ -n "$_import" ] || _import="all"
    [ -n "$_export" ] || _export="all"
    if [ -n "$_rmetric" ] || [ -n "$_rtag" ]; then
        case "$_export" in
            all) ;;
            *) err "export-rip-metric/export-rip-tag hanya berlaku bila export all (instance $_i saat ini export $_export) — ubah export ke all dulu, atau hapus rip-metric/rip-tag" ;;
        esac
    fi
    # ecmp-limit tanpa ecmp on: `ecmp` barisnya akan menggantung;
    # tolak di generate agar konfigurasi tidak ambigu.
    if [ -z "$_ecmp" ] && [ -n "$_eclimit" ]; then
        err "ecmp-limit di instance $_i tanpa ecmp on — set dulu ecmp on (atau hapus ecmp-limit)"
    fi
    if [ "$_i" = "rip" ]; then
        echo "protocol rip rip4 {"
        _chan="ipv4"
    else
        echo "protocol rip ng ripng6 {"
        _chan="ipv6"
    fi
    [ -n "$_inf" ] && echo "    infinity $_inf;"
    case "$_ecmp" in
        on)
            if [ -n "$_eclimit" ]; then echo "    ecmp yes limit $_eclimit;"
            else echo "    ecmp yes;"; fi ;;
        off) echo "    ecmp no;" ;;
    esac
    if [ -n "$_dbg" ]; then
        case "$_dbg" in all|off) echo "    debug $_dbg;" ;; *) echo "    debug { $(echo "$_dbg" | sed 's/,/, /g') };" ;; esac
    fi
    if [ -n "$_mrt" ]; then
        case "$_mrt" in all|off) echo "    mrtdump $_mrt;" ;; *) echo "    mrtdump { $(echo "$_mrt" | sed 's/,/, /g') };" ;; esac
    fi
    echo "    $_chan {"
    [ -n "$_pref" ] && echo "        preference $_pref;"
    echo "        import $_import;"
    case "$_ikf" in on) echo "        import keep filtered on;" ;; off) echo "        import keep filtered off;" ;; esac
    emit_limit "$_i" import
    emit_limit "$_i" receive
    if [ -n "$_rmetric" ] || [ -n "$_rtag" ]; then
        echo "        export filter {"
        [ -n "$_rmetric" ] && echo "            rip_metric = $_rmetric;"
        [ -n "$_rtag" ] && echo "            rip_tag = $_rtag;"
        echo "            accept;"
        echo "        };"
    else
        echo "        export $_export;"
    fi
    emit_limit "$_i" export
    echo "    };"
    set -f
    for _pat in $(grep "^instance $_i interface " "$CONF" 2>/dev/null | awk '{print $4}' | awk '!s[$0]++'); do
        emit_iface "$_i" "$_pat"
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
    for _i in rip ripng; do
        for _pat in $(grep "^instance $_i interface " "$CONF" 2>/dev/null | awk '{print $4}' | awk '!s[$0]++'); do
            _auth=$(get_iface_field "$_i" "$_pat" authentication)
            case "$_auth" in
                plaintext|cryptographic)
                    _re=$(re_esc "$_pat")
                    grep -q "^instance $_i interface $_re password " "$CONF" 2>/dev/null || \
                        err "interface $_pat ($_i) authentication $_auth tanpa password — tambah dulu password (router bird -> $_i -> interface $_pat -> password ...)"
                    ;;
            esac
        done
    done
    if has_facts; then
        {
            echo "# rip.conf - generated by titian-rip.sh, do not edit by hand"
            emit_instance rip
            emit_instance ripng
        } > "$_tmp" || die "cannot write $_tmp"
    else
        {
            echo "# rip.conf - generated by titian-rip.sh, do not edit by hand"
            echo "# (tidak ada config RIP — protocol rip/ripng tidak dibuat)"
        } > "$_tmp" || die "cannot write $_tmp"
    fi
    mv "$_tmp" "$SECTION" || die "cannot write $SECTION"
    chmod 644 "$SECTION" 2>/dev/null || true
    set +f
    echo "RIP section ditulis: $SECTION"
    _birdsh="$(dirname "$0")/titian-bird.sh"
    if [ -x "$_birdsh" ]; then
        "$_birdsh" generate rip || exit 33
    else
        echo "Warning: $_birdsh tidak ditemukan; section hanya ditulis, belum di-apply" >&2
    fi
}

birdc_bin() {
    command -v birdc 2>/dev/null || { [ -x /usr/sbin/birdc ] && echo /usr/sbin/birdc; } || \
        { [ -x /usr/local/sbin/birdc ] && echo /usr/local/sbin/birdc; } || echo birdc
}

cmd_show() {
    touch_conf
    echo "--- rip.conf (intent) ---"
    cat "$CONF"
    echo "--- bird.d/rip.conf (section, bila ada) ---"
    [ -f "$SECTION" ] && cat "$SECTION" || echo "(belum di-generate)"
    echo "--- birdc show protocol rip ---"
    _birdc=$(birdc_bin)
    _done=0
    for _inst in rip4 ripng6; do
        if grep -q "protocol rip.*$_inst" "$SECTION" 2>/dev/null; then
            if _out=$("$_birdc" show protocol "$_inst" 2>&1); then
                echo "$_out" | grep -v '^BIRD'
                _done=1
            fi
        fi
    done
    [ "$_done" = "0" ] && echo "(BIRD tidak jalan / belum ada instance RIP — birdc show protocol gagal)"
    return 0
}

# --- pemecah ctx single-var (refactor persistensi, pola route-map FRR) ---
# klish 2.2.5: var PERTAMA menelan sisa viewid bila multi-var, jadi
# konteks view di-encode SATU var ber-delimiter `:`. Bidang TERAKHIR
# selalu remainder (password boleh mengandung `:`).
split_if_ctx() { # <INST:IFACE> -> _CX_I _CX_PAT
    case "$1" in
        *:*)
            _CX_I="${1%%:*}"; _CX_PAT="${1#*:}" ;;
        *) err "ctx interface RIP harus <INST>:<IFACE>: $1" ;;
    esac
    valid_inst "$_CX_I"
    [ -n "$_CX_PAT" ] || err "ctx interface RIP butuh IFACE: $1"
}
split_pw_ctx() { # <INST:IFACE:TEXT> -> _CX_I _CX_PAT _CX_TEXT
    case "$1" in *:*:*) ;; *) err "ctx password RIP harus <INST>:<IFACE>:<TEXT>: $1" ;; esac
    _CX_I="${1%%:*}"; _r="${1#*:}"
    _CX_PAT="${_r%%:*}"; _CX_TEXT="${_r#*:}"
    valid_inst "$_CX_I"
    [ -n "$_CX_PAT" ] && [ -n "$_CX_TEXT" ] || err "ctx password RIP tidak lengkap: $1"
}

case "$1" in
    rip-touch) shift; cmd_rip_touch "$@" ;;
    has-facts) has_facts ;;
    infinity-set) shift; cmd_infinity_set "$@" ;;
    infinity-del) shift; cmd_infinity_del "$@" ;;
    ecmp-set) shift; cmd_ecmp_set "$@" ;;
    ecmp-del) shift; cmd_ecmp_del "$@" ;;
    ecmp-limit-set) shift; cmd_ecmp_limit_set "$@" ;;
    ecmp-limit-del) shift; cmd_ecmp_limit_del "$@" ;;
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
    export-rip-metric-set) shift; cmd_export_metric_set "$@" ;;
    export-rip-metric-del) shift; cmd_export_metric_del "$@" ;;
    export-rip-tag-set) shift; cmd_export_tag_set "$@" ;;
    export-rip-tag-del) shift; cmd_export_tag_del "$@" ;;
    interface-add) shift; split_if_ctx "$1"; shift; cmd_interface_add "$_CX_I" "$_CX_PAT" ;;
    interface-del) shift; split_if_ctx "$1"; shift; cmd_interface_del "$_CX_I" "$_CX_PAT" ;;
    interface-set) shift; split_if_ctx "$1"; shift; cmd_interface_set "$_CX_I" "$_CX_PAT" "$@" ;;
    interface-unset) shift; split_if_ctx "$1"; shift; cmd_interface_unset "$_CX_I" "$_CX_PAT" "$@" ;;
    password-add) shift; split_pw_ctx "$1"; shift; cmd_password_add "$_CX_I" "$_CX_PAT" "$_CX_TEXT" ;;
    password-del) shift; split_pw_ctx "$1"; shift; cmd_password_del "$_CX_I" "$_CX_PAT" "$_CX_TEXT" ;;
    password-set) shift; split_pw_ctx "$1"; shift; cmd_password_set "$_CX_I" "$_CX_PAT" "$_CX_TEXT" "$@" ;;
    password-unset) shift; split_pw_ctx "$1"; shift; cmd_password_unset "$_CX_I" "$_CX_PAT" "$_CX_TEXT" "$@" ;;
    generate) cmd_generate ;;
    show) cmd_show ;;
    *) echo "Usage: $0 {rip-touch INST|has-facts|infinity-set INST N|infinity-del INST|ecmp-set INST on|off|ecmp-del INST|ecmp-limit-set INST N|ecmp-limit-del INST|chan-set INST import|export all|none|filter NAME|preference-set INST N|preference-del INST|import-keep-filtered-set INST on|off|import-keep-filtered-del INST|limit-set INST import|receive|export N|off [ACTION]|limit-action-set INST import|receive|export warn|block|restart|disable|limit-del INST import|receive|export|debug-set INST SPEC|debug-del INST|mrtdump-set INST SPEC|mrtdump-del INST|export-rip-metric-set INST N|export-rip-metric-del INST|export-rip-tag-set INST N|export-rip-tag-del INST|interface-add CTX-IFACE|interface-del CTX-IFACE|interface-set CTX-IFACE FIELD VALUE|interface-unset CTX-IFACE FIELD|password-add CTX-PW|password-del CTX-PW|password-set CTX-PW FIELD VALUE|password-unset CTX-PW FIELD|generate|show}" >&2; exit 2 ;;
esac
