#!/bin/sh
# titian-bgp.sh — BGP intent (BIRD) untuk Titian/klish.
# Pola sama seperti titian-pppoe.sh / titian-dhcp.sh: intent di
# /etc/titian/bgp.conf (tmpfs, dipersistenkan via titian-cfg.sh),
# generate menulis section BIRD /etc/titian/bird.d/bgp.conf lalu
# memanggil titian-bird.sh generate bgp (render + validasi + birdc).
#
# Format bgp.conf (satu baris per fakta):
#   router-id <IP>
#   local-as <AS>
#   neighbor <IP> remote-as <AS>
#   neighbor <IP> description <teks>
#   neighbor <IP> import <all|none|filter-NAME>
#   neighbor <IP> export <all|none|filter-NAME>
#   neighbor <IP> local-pref <N>
#   neighbor <IP> med <N>
#   neighbor <IP> prepend <N>
#   neighbor <IP> community <AS:NN>        (tambah saat export)
#   neighbor <IP> bfd <on|graceful>        (ikat sesi BGP ke BFD;
#       butuh protocol bfd — section BFD di-generate DULU sebelum
#       section BGP, lihat cmd_generate + apply_bfd di titian-commit.sh)
#   --- B1 (BIRD 2.16.1 Bab 6.4): opsi protocol-level per neighbor ---
#   neighbor <IP> multihop [N]             (bare = multihop tanpa batas hop)
#   neighbor <IP> direct                   (bare; lawan multihop)
#   neighbor <IP> check-link|passive|strict-bind|free-bind|ttl-security|
#       setkey|confederation-member|allow-local-pref|allow-med|
#       allow-as-sets|enforce-first-as|enable-route-refresh|
#       require-route-refresh|enable-enhanced-rr|require-enhanced-rr|
#       require-graceful-restart|require-llgr|interpret-communities|
#       enable-as4|require-as4|enable-extended-messages|
#       require-extended-messages|capabilities|advertise-hostname|
#       require-hostname|disable-after-error|path-metric|med-metric|
#       deterministic-med|igp-metric|prefer-older|require-roles <on|off>
#   neighbor <IP> interface <nama>         (sesi direct IPv6 link-local)
#   neighbor <IP> port <N>                 (port remote; default 179)
#   neighbor <IP> mode <internal|external> (ganti `neighbor X as N`)
#   neighbor <IP> local-ip <IP>            (local <ip>; = source address)
#   neighbor <IP> local-port <N>           (local port)
#   neighbor <IP> source-address <IP>      (source address)
#   neighbor <IP> password <teks-tanpa-spasi>  (TCP MD5, RFC 2385)
#   neighbor <IP> confederation <N>
#   neighbor <IP> rr-client                (bare; jadi route reflector)
#   neighbor <IP> rr-cluster-id <IPv4>
#   neighbor <IP> rs-client                (bare; jadi route server)
#   neighbor <IP> allow-local-as [N]       (bare = cek AS lokal mati)
#   neighbor <IP> graceful-restart <off|aware|on>
#   neighbor <IP> graceful-restart-time <N>
#   neighbor <IP> llgr <off|aware|on>      (long lived graceful restart)
#   neighbor <IP> llgr-stale-time <N>
#   neighbor <IP> disable-after-cease <on|off>
#   neighbor <IP> disable-after-cease-flags <f1,f2,...> (nama flag
#       hyphenated, mis. administrative-shutdown,peer-deconfigured)
#   neighbor <IP> hold-time|min-hold-time|startup-hold-time|
#       keepalive-time|min-keepalive-time|send-hold-time|
#       connect-delay-time|connect-retry-time|error-forget-time <N>
#       (hold-time 0 = tanpa keepalive, VALID di BIRD)
#   neighbor <IP> error-wait-time <N,M>
#   neighbor <IP> default-med|default-local-pref <N>
#   neighbor <IP> local-role <provider|customer|peer|rs-server|rs-client>
#   neighbor <IP> disabled                 (bare; nonaktifkan instance)
#   --- B1: opsi channel ipv4 per neighbor ---
#   neighbor <IP> next-hop-self|next-hop-keep <on|off|ibgp|ebgp>
#   neighbor <IP> next-hop-address <IP>
#   neighbor <IP> gateway <direct|recursive>
#   neighbor <IP> igp-table <nama>         (tabel IGP v4)
#   neighbor <IP> igp-table6 <nama>        (tabel IGP v6, kedua di contoh resmi)
#   neighbor <IP> import-table|export-table|secondary|validate|
#       extended-next-hop|require-extended-next-hop|require-add-paths|
#       channel-graceful-restart|channel-llgr|mandatory <on|off>
#   neighbor <IP> base-table|channel-table <nama>
#   neighbor <IP> add-paths <on|off|rx|tx>
#   neighbor <IP> aigp <on|off|originate>
#   neighbor <IP> cost <N>
#   neighbor <IP> channel-llgr-stale-time <N>
#   neighbor <IP> import-limit|receive-limit|export-limit <N|off>
#   neighbor <IP> import-limit-action|receive-limit-action|
#       export-limit-action <warn|block|restart|disable>
#   --- B1: atribut export-inline tambahan (hanya bila export all) ---
#   neighbor <IP> origin <igp|egp|incomplete>
#   neighbor <IP> export-next-hop <IP>
#   neighbor <IP> community-del <AS:NN>
#   neighbor <IP> ext-community-del <rt|ro:AA:NN>
#   neighbor <IP> large-community-del <large:AA:X:NN>
#   --- B1: dynamic BGP + atribut top-level ---
#   neighbor-range <prefix>                (template protocol bgp_dyn)
#   dynamic-name <teks-tanpa-spasi>        (prefix nama instance dynamic)
#   dynamic-name-digits <N>
#   attribute-bgp <nomor 1..255> <nama>    (attribute bgp N bytestring NAME;
#       nomor yang sudah dikenal BIRD ditolak)
#   filter <NAME> accept-aspath|reject-aspath <AS[,AS...]>
#   filter <NAME> accept-origin|reject-origin <igp|egp|incomplete>
#   filter <NAME> accept-next-hop|reject-next-hop <IP>
#   filter <NAME> accept-originator-id|reject-originator-id <IP>
#   filter <NAME> accept-cluster-list|reject-cluster-list <IP>
#   filter <NAME> accept-otc|reject-otc <N>
#   --- B5 (BIRD 2.16.1 Bab 5: bahasa filter lengkap) ---
#   filter <NAME> accept|reject <prefix-pola>  (pola: IP/len[+|-|{low,high}])
#   filter <NAME> accept|reject prefix-len <OP> <N> | prefix-ip <IP> |
#       ip-v4 | ip-v6 | ip-mask <IP> <N> | path-mask <e,e,...> |
#       path-first|path-last <AS> | path-len <OP> <N> |
#       community-len <OP> <N> | community-min|max <AS:NN> |
#       local-pref|med <OP> <N> | defined|undefined <ATTR> |
#       roa <TABLE> <ROA_VALID|ROA_INVALID|ROA_UNKNOWN> |
#       aspa-down|aspa-up <TABLE> <ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN> |
#       roa3 <TABLE> <PREFIX|net> <ASN|bgp_path.last> <ROA_*> |  (B12/5-105)
#       aspa3 <TABLE> <bgp_path> <true|false|up|down> <ASPA_*> |  (B12/5-108)
#       match <COND>
#   filter <NAME> set <ATTR> <NILAI>          (assignment atribut)
#   filter <NAME> unset <ATTR>                (unset atribut opsional)
#   filter <NAME> var <TIPE> <NAMA>           (variabel lokal filter)
#   filter <NAME> if <COND> then <STMT> [else <STMT>]   (B9: boleh BANYAK
#       baris per filter — tiap filter-if APPEND, generate emit semuanya
#       berurutan; baris yang SAMA persis dideduplikasi)
#   filter <NAME> if-block <COND> | else-block | for-block <TIPE> <VAR> <SUMBER> |
#       case-block <EKSPRESI> | when <LABEL> <STMT> | otherwise <STMT> |
#       close-block                            (blok { } bersarang)
#   define-int <NAMA> <N>                     (define NAMA = N; top-level)
#   attribute-int <NAMA>                      (attribute int NAMA; top-level)
#   roa-table <NAMA> [v4|v6]                  (roa4/roa6 table NAMA;)
#   aspa-table <NAMA>                         (aspa table NAMA;)
#   Kondisi COND (satu token, tanpa spasi; atom digabung && atau || saja —
#   campuran keduanya DITOLAK karena docs Bab 5 tidak memberi tabel
#   presedensi, ambiguitas A3): defined:ATTR | !defined:ATTR |
#   ATTR=VAL | ATTR!=VAL | ATTR<VAL | ATTR<=VAL | ATTR>VAL | ATTR>=VAL |
#   net~POLA | path~MASK | ASN~path | community~AA:NN |
#   ext-community~rt:AA:NN | large-community~large:AA:X:NN |
#   net.ip.is_v4 | !net.ip.is_v4 | true | false |
#   roa:TABEL=ROA_* | roa:TABEL,PREFIX,ASN=ROA_* (B12/5-105) |
#   aspa-down:TABEL=ASPA_* | aspa-up:TABEL=ASPA_* |
#   aspa:TABEL,PATH,BOOL=ASPA_* (B12/5-108) |
#   net=LITERAL-SADR/ROA (B12/5-64/66: DST,from,SRC | PREFIX,max,MAXLEN,as,ASN —
#   literal net, TIDAK bisa masuk prefix-set; VPN 5-65: literal `rd` DITOLAK BIRD
#   2.20.0 — cocokkan via net.type=NET_VPN4|NET_VPN6 + net.rd=RD) |
#   ATTR-int = ekspresi aritmetika (+ - * / dan kurung, B12/5-90/91) |
#   call:NAMA | call:NAMA(ARG,...) | VAR<op>VAL (VAR lokal/loop)
#   STMT (satu token): accept | reject | accept "PESAN" | reject "PESAN"
#   (B12/5-159) | set:ATTR=NILAI | unset:ATTR
#   CATATAN B12: `ifname` hanya match (A12); `from`/`proto` hanya match
#   (A4/A12/B9 — RO, assignment tidak dikonfirmasi docs); `mpls_class` hanya
#   match (5-135, RO — tidak ada writer di BIRD). Var nested block (5-7):
#   `filter-var`/`function-var` di dalam if-block diterima; generator emit
#   deklarasi di posisi blok itu (indentasi mengikuti kedalaman blok).
#   CATATAN B5: `scope` TIDAK diimplementasi (dihapus di BIRD 3;
#   titian-bird.sh validate_config sudah menolaknya). `ifname` tidak bisa
#   di-set (A12: menghapus gateway). `source`/`from` tidak bisa di-set
#   (A4: tidak dikonfirmasi docs). `bgp_otc`/`bgp_originator_id`/
#   `bgp_cluster_list` hanya match (set-nya tugas RR/otomatis).
#   Tabel roa/aspa yang didefinisikan di sini KOSONG sampai ada protokol
#   RPKI yang mengisinya (B9/RPKI); roa_check atas tabel kosong = UNKNOWN.
#
# CATATAN B1: opsi baru HANYA di-emit bila diset di intent; tanpa opsi
# baru, output generate byte-identik dengan sebelum B1 (anchor regression).
# Yang TIDAK diimplementasi di B1 (lihat laporan batch): channel ipv6 +
# `next hop prefer global` (dependensi B6), `missing lladdr self`
# (BGP-109, PERLU VERIFIKASI), set community (tidak ada `.set()` di
# docs; hanya delete), bgp_atomic_aggr/bgp_aggregator/bgp_aigp (tidak
# bisa diakses dari filter per docs), channel multicast/mpls/vpn/flow
# (B6/P3), perintah birdc show/configure (di luar scope B1).
#   --- B6 (BIRD 2.16.1 Bab 3.5 + Bab 6.4 Tabel 2): channel non-ipv4 ---
#   neighbor <IP> <KEY>-<FIELD> <NILAI>    (KEY: ipv6|mc4|mc6|mpls4|
#       mpls6|vpn4|vpn6|vpn4mc|vpn6mc|flow4|flow6 — lihat chan_bird_name;
#       FIELD: import|export|table|preference|import-keep-filtered|
#       rpki-reload|import-limit|receive-limit|export-limit (+-action)|
#       mandatory|next-hop-self|next-hop-keep|next-hop-address|
#       next-hop-prefer-global (khusus keluarga IPv6)|gateway|
#       igp-table|igp-table6|import-table|export-table|secondary|
#       validate|base-table (khusus flow4/flow6)|extended-next-hop|
#       require-extended-next-hop|add-paths|require-add-paths|aigp|
#       cost|graceful-restart|llgr|llgr-stale-time|debug)
#       Default baru di channel ini (BIRD Bab 3.5): import all,
#       export none bila tak diset (beda dari ipv4 yang default
#       all/all dari neighbor-add). `missing lladdr self` (BGP-109)
#       TIDAK diimplementasi — tidak terdokumentasi di mana pun.
#   neighbor <IP> from <TEMPLATE>          (warisi template bgp;
#       template didefinisikan di bird-global.conf)
#   neighbor <IP> protocol-router-id <IPv4> (3.4-4, override global)
#   neighbor <IP> debug <all|off|states,routes,...>   (3.4-2)
#   neighbor <IP> mrtdump <all|off|states|messages>   (3.4-3)
#   neighbor <IP> tx-class|tx-dscp — DITOLAK di BGP BIRD 2.20 (hanya blok
#       interface OSPF/RIP/Babel; bird -p: "unexpected TX") (3.4-9, dikoreksi F3.2)
#   neighbor <IP> mpls-domain <NAMA>       (blok mpls { }; EKSPERIMENTAL)
#   neighbor <IP> mpls-label-range <NAMA>  (harus ada di bird-global.conf)
#   neighbor <IP> mpls-label-policy <static|prefix|aggregate|vrf>
#       (vrf hanya valid bila ada channel vpn4/vpn6 di neighbor ini)
#   CATATAN B6: description (3.4-5) + disabled (3.4-1) sudah ada (B1);
#   interface pola penuh (3.4-8) sudah ada di BFD/Direct; password
#   generik (3.4-11..19) milik batch OSPF/RIP/BFD — bukan di sini;
#   vrf + tx priority = Linux-specific, N/A FreeBSD (tidak dibuat).
#   network <prefix>                       (prefix yang diiklankan)
#   filter <NAME> accept <prefix>
#   filter <NAME> reject <prefix>
#   filter <NAME> accept-community <AS:NN>
#   filter <NAME> reject-community <AS:NN>
#
# Aturan BIRD: import/export filter merujuk nama filter yang didefinisikan
# via `filter`. Bila import/export = all/none, tidak perlu filter.
# `network` diiklankan lewat export filter yang hanya menerima prefix itu
# (bila export = all, network ikut teriklankan; bila export = filter,
# pastikan filter menerima prefix network).

STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CONF="$STATE_ROOT/bgp.conf"
SECTION_DIR="$STATE_ROOT/bird.d"
SECTION="$SECTION_DIR/bgp.conf"
PROG="titian-bgp"
err() { echo "Error($PROG): $*" >&2; exit 33; }
die() { echo "$PROG: $*" >&2; exit 1; }

touch_conf() {
    if [ ! -f "$CONF" ]; then
        mkdir -p "$(dirname "$CONF")" 2>/dev/null
        printf '# bgp.conf - generated by klish, do not edit by hand\n' > "$CONF" \
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

get_field() {
    # get_field <neighbor-IP> <field> -> nilai (atau kosong)
    _ip="$1"; _f="$2"
    grep "^neighbor $_ip $_f " "$CONF" 2>/dev/null | head -1 | awk '{print $4}'
}

get_field_rest() {
    # get_field_rest <neighbor-IP> <field> -> sisa baris sesudah field
    # (untuk nilai multi-kata, mis. `import where <COND>`).
    _ip="$1"; _f="$2"
    grep "^neighbor $_ip $_f " "$CONF" 2>/dev/null | head -1 | awk '{$1=""; $2=""; $3=""; sub(/^ +/, ""); print}'
}

# cmd_cond_to_bird <COND> — cetak terjemahan BIRD dari ekspresi kondisi
# bentuk ringkas (mis. net~10.0.0.0/8 -> net ~ [ 10.0.0.0/8+ ]).
# Dipakai backend lain (OSPF/RIP/static/direct/pipe/kernel) untuk bentuk
# `import/export where <COND>`; gagal rc=33 bila COND tidak valid.
# Tanpa daftar variabel lokal (where tidak punya var lokal).
cmd_cond_to_bird() {
    [ -n "$1" ] || err "cond-to-bird butuh ekspresi kondisi (bentuk ringkas, mis. net~10.0.0.0/8)"
    cond_to_bird "$*" ""
}

# cmd_stmt_to_bird <STMT> — cetak terjemahan BIRD dari satu statement filter
# bentuk ringkas (set:ATTR=NILAI | unset:ATTR | method:OBJ.METHOD(args) |
# accept | reject | accept "PESAN" | reject "PESAN" | print:ARGS | printn:ARGS).
# (static S30: statement di blok filter per-route) untuk validasi + generate;
# gagal rc=33 bila STMT tidak valid. Tanpa var lokal (blok route tidak punya).
cmd_stmt_to_bird() {
    [ -n "$1" ] || err "stmt-to-bird butuh statement (mis. set:ospf_metric1=20)"
    _s=$(klish_unescape "$1")
    stmt_to_bird "$_s" ""
}

# --- validator B1 (semua gagal -> rc 33 via err) ---
valid_uint() { # valid_uint <nilai> <label> — bilangan >= 0
    case "$1" in ''|*[!0-9]*) err "$2 harus bilangan >= 0: $1" ;; esac
}
valid_asn() { # valid_asn <nilai> <label> — AS 1..4294967295 (AS 0 invalid)
    valid_uint "$1" "$2"
    [ "$1" -ge 1 ] 2>/dev/null || err "$2 harus 1..4294967295 (AS 0 tidak valid): $1"
    [ "$1" -le 4294967295 ] 2>/dev/null || err "$2 harus 1..4294967295: $1"
}
valid_u32() { # valid_u32 <nilai> <label> — 0..4294967295
    valid_uint "$1" "$2"
    [ "$1" -le 4294967295 ] 2>/dev/null || err "$2 harus 0..4294967295: $1"
}
valid_port() { # valid_port <nilai> <label> — 1..65535 (port 0 invalid)
    valid_uint "$1" "$2"
    [ "$1" -ge 1 ] 2>/dev/null || err "$2 harus 1..65535 (port 0 tidak valid): $1"
    [ "$1" -le 65535 ] 2>/dev/null || err "$2 harus 1..65535: $1"
}
valid_ipv4() { # valid_ipv4 <nilai> <label> — 4 oktet 0..255
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
valid_onoff() { # valid_onoff <nilai> <label>
    case "$1" in on|off) ;; *) err "$2 harus on|off: $1" ;; esac
}
valid_name() { # valid_name <nilai> <label> — simbol BIRD [A-Za-z0-9_]
    case "$1" in ''|*[!A-Za-z0-9_]*) err "$2 harus nama BIRD [A-Za-z0-9_]: $1" ;; esac
}
valid_symbol() { # valid_symbol <nilai> <label> — simbol BIRD boleh '-' (filter/tabel/fungsi; bird_ident ubah '-' -> '_' saat generate)
    case "$1" in ''|*[!A-Za-z0-9_-]*) err "$2 harus nama BIRD [A-Za-z0-9_-]: $1" ;; esac
}
re_escape() { # re_escape <TEKS> — escape karakter spesial BRE agar pola upsert cocok persis (bukan regex)
    printf '%s' "$1" | sed 's/[][\\.^$*]/\\&/g'
}
valid_nospace() { # valid_nospace <nilai> <label> — satu token tanpa spasi
    case "$1" in ''|*[[:space:]]*) err "$2 tidak boleh kosong/mengandung spasi: $1" ;; esac
}
valid_prefix() { # valid_prefix <nilai> <label> — CIDR IPv4
    _v="$1"; _l="$2"
    case "$_v" in */*) ;; *) err "$_l harus prefix CIDR: $_v" ;; esac
    _ip=${_v%/*}; _len=${_v#*/}
    valid_ipv4 "$_ip" "$_l"
    case "$_len" in ''|*[!0-9]*) err "$_l panjang prefix harus bilangan: $_v" ;; esac
    [ "$_len" -le 32 ] 2>/dev/null || err "$_l panjang prefix harus 0..32: $_v"
}
valid_ipv6() { # valid_ipv6 <nilai> <label> — IPv6, '::' maks sekali, grup 1-4 hex
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
valid_prefix6() { # valid_prefix6 <nilai> <label> — CIDR IPv6
    _v="$1"; _l="$2"
    case "$_v" in */*) ;; *) err "$_l harus prefix CIDR IPv6: $_v" ;; esac
    _ip=${_v%/*}; _len=${_v#*/}
    valid_ipv6 "$_ip" "$_l"
    case "$_len" in ''|*[!0-9]*) err "$_l panjang prefix harus bilangan: $_v" ;; esac
    [ "$_len" -le 128 ] 2>/dev/null || err "$_l panjang prefix harus 0..128: $_v"
}
valid_community() { # valid_community <nilai> <label> — AA:NN, 0..65535
    _v="$1"; _l="$2"
    case "$_v" in *:*) ;; *) err "$_l harus AS:NN: $_v" ;; esac
    _a=${_v%%:*}; _n=${_v#*:}
    case "$_a" in ''|*[!0-9]*) err "$_l AS harus angka: $_v" ;; esac
    case "$_n" in ''|*[!0-9]*) err "$_l NN harus angka: $_v" ;; esac
    [ "$_a" -le 65535 ] 2>/dev/null || err "$_l AS harus 0..65535: $_v"
    [ "$_n" -le 65535 ] 2>/dev/null || err "$_l NN harus 0..65535: $_v"
}
valid_aspath_list() { # valid_aspath_list <nilai> <label> — AS[,AS...]
    _v="$1"; _l="$2"
    [ -n "$_v" ] || err "$_l butuh daftar AS (mis. 65000 atau 65000,65001)"
    _rest="$_v"
    while [ -n "$_rest" ]; do
        case "$_rest" in *,*) _one=${_rest%%,*}; _rest=${_rest#*,} ;; *) _one="$_rest"; _rest="" ;; esac
        valid_asn "$_one" "$_l"
    done
}
valid_ext_community() { # rt:AA:NN | ro:AA:NN
    _v="$1"; _l="$2"
    case "$_v" in rt:*|ro:*) ;; *) err "$_l harus rt:AA:NN atau ro:AA:NN: $_v" ;; esac
    _rest=${_v#*:}; _a=${_rest%%:*}; _n=${_rest#*:}
    case "$_a" in ''|*[!0-9]*) err "$_l AA harus angka: $_v" ;; esac
    case "$_n" in ''|*[!0-9]*) err "$_l NN harus angka: $_v" ;; esac
    [ "$_a" -le 4294967295 ] 2>/dev/null || err "$_l AA harus 0..4294967295: $_v"
    [ "$_n" -le 4294967295 ] 2>/dev/null || err "$_l NN harus 0..4294967295: $_v"
}
valid_large_community() { # large:AA:X:NN
    _v="$1"; _l="$2"
    case "$_v" in large:*) ;; *) err "$_l harus large:AA:X:NN: $_v" ;; esac
    _rest=${_v#large:}; _a=${_rest%%:*}; _rest2=${_rest#*:}
    _x=${_rest2%%:*}; _n=${_rest2#*:}
    for _p in "$_a" "$_x" "$_n"; do
        case "$_p" in ''|*[!0-9]*) err "$_l harus large:AA:X:NN angka semua: $_v" ;; esac
        [ "$_p" -le 4294967295 ] 2>/dev/null || err "$_l harus 0..4294967295: $_v"
    done
}

# --- B5: validator bahasa filter (Bab 5) ---
# Semua gagal -> rc 33 via err. Dipakai saat filter-add (fail fast) DAN
# saat generate (intent bisa diedit tangan; generate memvalidasi ulang).
valid_op() { # valid_op <op> <label> — operator perbandingan
    case "$1" in '='|'!='|'<'|'>'|'<='|'>=') ;; *) err "$2 harus =|!=|<|>|<=|>=: $1" ;; esac
}

valid_prefix_pattern() { # valid_prefix_pattern <nilai> <label>
    # IP/len, opsional suffix + (subnet) | - (supernet) | {low,high}
    _v="$1"; _l="$2"
    case "$_v" in
        *{*})
            _base=${_v%%\{*}; _rng=${_v#*\{}; _rng=${_rng%\}}
            case "$_rng" in *,*) ;; *) err "$_l pola {low,high} butuh koma: $_v" ;; esac
            _lo=${_rng%%,*}; _hi=${_rng#*,}
            case "$_lo" in ''|*[!0-9]*) err "$_l low harus bilangan: $_v" ;; esac
            case "$_hi" in ''|*[!0-9]*) err "$_l high harus bilangan: $_v" ;; esac
            [ "$_lo" -le 32 ] 2>/dev/null || err "$_l low harus 0..32: $_v"
            [ "$_hi" -le 32 ] 2>/dev/null || err "$_l high harus 0..32: $_v"
            [ "$_lo" -le "$_hi" ] 2>/dev/null || err "$_l low harus <= high (low>high tidak valid): $_v"
            valid_prefix "$_base" "$_l"
            ;;
        *+)
            valid_prefix "${_v%+}" "$_l" ;;
        *-)
            valid_prefix "${_v%-}" "$_l" ;;
        *) valid_prefix "$_v" "$_l" ;;
    esac
}

valid_bgpmask() { # valid_bgpmask <mask-koma> <label> — elemen: * ? ASN ASN+ A..B
    _v="$1"; _l="$2"
    [ -n "$_v" ] || err "$_l butuh mask (mis. *,65001,*)"
    _rest="$_v"
    while [ -n "$_rest" ]; do
        case "$_rest" in *,*) _one=${_rest%%,*}; _rest=${_rest#*,} ;; *) _one="$_rest"; _rest="" ;; esac
        case "$_one" in
            '*'|'?') ;;
            *+)
                valid_asn "${_one%+}" "$_l" ;;
            *..*)
                _a=${_one%%..*}; _b=${_one#*..}
                valid_asn "$_a" "$_l"; valid_asn "$_b" "$_l"
                [ "$_a" -le "$_b" ] 2>/dev/null || err "$_l range harus A<=B: $_one" ;;
            *) valid_asn "$_one" "$_l" ;;
        esac
    done
}

# --- B8: validator tambahan (Bab 5.2) ---
valid_ip_any() { # <nilai> <label> — IPv4 atau IPv6 (B9: IPv6 pakai valid_ipv6
    # yang ketat, sama seperti valid_prefix6 — sebelumnya hanya cek charset,
    # sehingga `2001:db8:` lolos)
    case "$1" in *:*)
        valid_ipv6 "$1" "$2" ;;
        *) valid_ipv4 "$1" "$2" ;;
    esac
}
valid_prefix_any() { # <nilai> <label> — CIDR IPv4 atau IPv6
    case "$1" in *:*)
        valid_prefix6 "$1" "$2" ;;
        *) valid_prefix "$1" "$2" ;;
    esac
}
valid_prefix_pattern_any() { # <nilai> <label> — pola prefix v4 ATAU v6 (+|-|{low,high})
    _b8v="$1"; _b8l="$2"
    case "$_b8v" in *:*)
        case "$_b8v" in
            *{*})
                _b8base=${_b8v%%\{*}; _b8rng=${_b8v#*\{}; _b8rng=${_b8rng%\}}
                case "$_b8rng" in *,*) ;; *) err "$_b8l pola {low,high} butuh koma: $_b8v" ;; esac
                _b8lo=${_b8rng%%,*}; _b8hi=${_b8rng#*,}
                case "$_b8lo" in ''|*[!0-9]*) err "$_b8l low harus bilangan: $_b8v" ;; esac
                case "$_b8hi" in ''|*[!0-9]*) err "$_b8l high harus bilangan: $_b8v" ;; esac
                [ "$_b8lo" -le 128 ] 2>/dev/null || err "$_b8l low harus 0..128: $_b8v"
                [ "$_b8hi" -le 128 ] 2>/dev/null || err "$_b8l high harus 0..128: $_b8v"
                [ "$_b8lo" -le "$_b8hi" ] 2>/dev/null || err "$_b8l low harus <= high: $_b8v"
                valid_prefix6 "$_b8base" "$_b8l" ;;
            *+) valid_prefix6 "${_b8v%+}" "$_b8l" ;;
            *-) valid_prefix6 "${_b8v%-}" "$_b8l" ;;
            *) valid_prefix6 "$_b8v" "$_b8l" ;;
        esac ;;
        *) valid_prefix_pattern "$_b8v" "$_b8l" ;;
    esac
}
valid_pair() { # <nilai> <label> — pair (AA,NN), tiap komponen 0..65535
    _b8pv="$1"; _b8pl="$2"
    case "$_b8pv" in '('*')') ;; *) err "$_b8pl harus pair (AA,NN): $_b8pv" ;; esac
    _b8pe=${_b8pv#(}; _b8pe=${_b8pe%)}
    case "$_b8pe" in *,*) ;; *) err "$_b8pl pair harus tepat 2 komponen: $_b8pv" ;; esac
    _b8pa=${_b8pe%%,*}; _b8pn=${_b8pe#*,}
    case "$_b8pn" in *,*) err "$_b8pl pair harus tepat 2 komponen: $_b8pv" ;; esac
    case "$_b8pa" in ''|*[!0-9]*) err "$_b8pl pair AS harus angka: $_b8pv" ;; esac
    case "$_b8pn" in ''|*[!0-9]*) err "$_b8pl pair NN harus angka: $_b8pv" ;; esac
    [ "$_b8pa" -le 65535 ] 2>/dev/null || err "$_b8pl pair AS harus 0..65535: $_b8pv"
    [ "$_b8pn" -le 65535 ] 2>/dev/null || err "$_b8pl pair NN harus 0..65535: $_b8pv"
}
valid_rd() { # <nilai> <label> — RD: ASN:u32 | ASN4:u16 | IP:u32
    _b8v="$1"; _b8l="$2"
    case "$_b8v" in *:*) ;; *) err "$_b8l harus RD (ASN:u32 | ASN4:u16 | IP:u32): $_b8v" ;; esac
    _b8r1=${_b8v%%:*}; _b8r2=${_b8v#*:}
    case "$_b8r2" in *:*|''|*[!0-9]*) err "$_b8l RD bagian kedua harus angka: $_b8v" ;; esac
    case "$_b8r1" in *.*)
        valid_ipv4 "$_b8r1" "$_b8l (RD IP)"
        [ "$_b8r2" -le 65535 ] 2>/dev/null || err "$_b8l RD bentuk IP:u32 butuh u32 0..65535: $_b8v" ;;
        *)
        case "$_b8r1" in ''|*[!0-9]*) err "$_b8l RD ASN harus angka: $_b8v" ;; esac
        [ "$_b8r1" -le 4294967295 ] 2>/dev/null || err "$_b8l RD ASN harus 0..4294967295: $_b8v"
        [ "$_b8r2" -le 4294967295 ] 2>/dev/null || err "$_b8l RD bagian kedua harus 0..4294967295: $_b8v"
        { [ "$_b8r1" -le 65535 ] 2>/dev/null || [ "$_b8r2" -le 65535 ] 2>/dev/null; } || err "$_b8l RD butuh bentuk ASN:u32 (ASN 0..65535) atau ASN4:u16 (u16 0..65535): $_b8v" ;;
    esac
}
valid_ec() { # <nilai> <label> — EC (rt|ro, A, B)
    _b8ev="$1"; _b8el="$2"
    case "$_b8ev" in '('*')') ;; *) err "$_b8el harus EC (rt|ro, A, B): $_b8ev" ;; esac
    _b8ee=${_b8ev#(}; _b8ee=${_b8ee%)}
    case "$_b8ee" in *,*,*) ;; *) err "$_b8el EC harus tepat 3 komponen: $_b8ev" ;; esac
    _b8ek=${_b8ee%%,*}; _b8erest=${_b8ee#*,}
    case "$_b8ek" in rt|ro) ;; *) err "$_b8el EC tipe harus rt|ro: $_b8ev" ;; esac
    _b8ea=${_b8erest%%,*}; _b8eb=${_b8erest#*,}
    case "$_b8eb" in *,*) err "$_b8el EC harus tepat 3 komponen: $_b8ev" ;; esac
    case "$_b8ea" in ''|*[!0-9]*) err "$_b8el EC A harus angka: $_b8ev" ;; esac
    case "$_b8eb" in ''|*[!0-9]*) err "$_b8el EC B harus angka: $_b8ev" ;; esac
    [ "$_b8ea" -le 4294967295 ] 2>/dev/null || err "$_b8el EC A harus 0..4294967295: $_b8ev"
    [ "$_b8eb" -le 4294967295 ] 2>/dev/null || err "$_b8el EC B harus 0..4294967295: $_b8ev"
    { [ "$_b8ea" -le 65535 ] 2>/dev/null || [ "$_b8eb" -le 65535 ] 2>/dev/null; } || err "$_b8el EC butuh bentuk (rt|ro, ASN16, u32) atau (rt|ro, ASN32, u16): $_b8ev"
}
valid_lc() { # <nilai> <label> — LC (A,B,C): A 0..4294967295, B/C 0..65535
    _b8lv="$1"; _b8ll="$2"
    case "$_b8lv" in '('*')') ;; *) err "$_b8ll harus LC (A,B,C): $_b8lv" ;; esac
    _b8le=${_b8lv#(}; _b8le=${_b8le%)}
    case "$_b8le" in *,*,*) ;; *) err "$_b8ll LC harus tepat 3 komponen: $_b8lv" ;; esac
    _b8la=${_b8le%%,*}; _b8lr=${_b8le#*,}; _b8lb=${_b8lr%%,*}; _b8lc=${_b8lr#*,}
    case "$_b8lc" in *,*) err "$_b8ll LC harus tepat 3 komponen: $_b8lv" ;; esac
    case "$_b8la" in ''|*[!0-9]*) err "$_b8ll LC A harus angka: $_b8lv" ;; esac
    case "$_b8lb" in ''|*[!0-9]*) err "$_b8ll LC B harus angka: $_b8lv" ;; esac
    case "$_b8lc" in ''|*[!0-9]*) err "$_b8ll LC C harus angka: $_b8lv" ;; esac
    [ "$_b8la" -le 4294967295 ] 2>/dev/null || err "$_b8ll LC A harus 0..4294967295: $_b8lv"
    [ "$_b8lb" -le 65535 ] 2>/dev/null || err "$_b8ll LC B harus 0..65535: $_b8lv"
    [ "$_b8lc" -le 65535 ] 2>/dev/null || err "$_b8ll LC C harus 0..65535: $_b8lv"
}
valid_bytestring() { # <nilai> <label> — bytestring (Bab 5.2 No 20)
    _b8v="$1"; _b8l="$2"
    case "$_b8v" in
        from_hex\(\"*\"\))
            _b8h=$(printf '%s' "$_b8v" | sed 's/^from_hex("//; s/")$//')
            case "$_b8h" in ''|*[!0-9a-fA-F.:-]*) err "$_b8l from_hex: isi harus digit hex + pemisah . : - : $_b8v" ;; esac
            case "$_b8h" in *[0-9a-fA-F]*) ;; *) err "$_b8l from_hex: butuh minimal 1 digit hex: $_b8v" ;; esac ;;
        'hex:'*)
            _b8h=${_b8v#hex:}
            case "$_b8h" in ''|*[!0-9a-fA-F:]*) err "$_b8l bytestring hex: harus byte hex dipisah ':' (mis. hex:0e:10:20): $_b8v" ;; esac ;;
        *)
            case "$_b8v" in *[!0-9a-fA-F]*) err "$_b8l bytestring tanpa prefix hex: wajib string hex (tanpa spasi): $_b8v" ;; esac
            _b8n=${#_b8v}
            [ $(( _b8n % 2 )) -eq 0 ] || err "$_b8l bytestring tanpa prefix hex: jumlah digit harus genap: $_b8v"
            [ "$_b8n" -ge 32 ] || err "$_b8l bytestring tanpa prefix hex: wajib >= 16 byte (32 digit hex); yang pendek wajib prefix hex: : $_b8v" ;;
    esac
}

# --- B12: literal net SADR/VPN/ROA (Bab 5.2 No 64-66) ---
# Bentuk ringkas satu token (COND tidak boleh mengandung spasi):
#   SADR: DST,from,SRC            (mis. 2001:db8::/32,from,2001:db8:1::/48)
#   ROA:  PREFIX,max,MAXLEN,as,ASN (mis. 10.0.0.0/8,max,24,as,65000)
# Bentuk BIRD (conf/confbase.Y net_: net_ip6_sadr_/net_roa_):
#   DST from SRC | PREFIX max MAXLEN as ASN.
# CATATAN: literal ini adalah konstanta net_ (T_NET) untuk posisi TERM
# (mis. net = <literal>). TIDAK bisa masuk prefix-set [ ... ] (fprefix di
# filter/config.Y hanya menerima net_ip_ — bird -p: unexpected FROM/MAX) —
# jadi TIDAK ada bentuk net~; pakai net=<literal>, atau net.type +
# net.src/net.dst (5-64/66).
# VPN (5-65): literal `rd RD PREFIX` DITOLAK BIRD 2.20.0 di filter (bird -p:
# "unexpected RD" — di term, di set, di define, berkurung pun). Bentuk ringkas
# rd,RD,PREFIX sengaja DITOLAK backend dengan pesan ini. Cocokkan VPN via
# net.type=NET_VPN4|NET_VPN6 + net.rd=RD (keduanya bird -p rc=0).
valid_net_literal() { # valid_net_literal <RINGKAS> <label>
    _nl="$1"; _nll="$2"
    case "$_nl" in
        rd,*)  # B12/5-65 KOREKSI: BIRD 2.20.0 MENOLAK literal `rd ...` di filter
            # (bird -p: "syntax error, unexpected RD" — di term, di set, di define,
            # berkurung pun; `rd` hanya valid di definisi channel/protocol VPN).
            # Cocokkan VPN via net.type=NET_VPN4|NET_VPN6 + net.rd=RD (keduanya rc=0).
            err "$_nll literal VPN rd,RD,PREFIX DITOLAK BIRD 2.20.0 (bird -p: unexpected RD) — cocokkan VPN via net.type=NET_VPN4|NET_VPN6 + net.rd=RD: $_nl" ;;
        *',from,'*)
            _nld=${_nl%%,from,*}; _nls=${_nl#*,from,}
            case "$_nls" in *,*) err "$_nll literal SADR harus DST,from,SRC (tepat 3 bagian): $_nl" ;; esac
            [ -n "$_nld" ] && [ -n "$_nls" ] || err "$_nll literal SADR harus DST,from,SRC: $_nl"
            valid_prefix6 "$_nld" "$_nll"; valid_prefix6 "$_nls" "$_nll" ;;
        *',max,'*',as,'*)
            _nlp=${_nl%%,max,*}; _nlr=${_nl#*,max,}; _nlm=${_nlr%%,as,*}; _nla=${_nlr#*,as,}
            case "$_nla" in *,*) err "$_nll literal ROA harus PREFIX,max,MAXLEN,as,ASN (tepat 5 bagian): $_nl" ;; esac
            [ -n "$_nlp" ] && [ -n "$_nlm" ] && [ -n "$_nla" ] || err "$_nll literal ROA harus PREFIX,max,MAXLEN,as,ASN: $_nl"
            valid_prefix_any "$_nlp" "$_nll"
            case "$_nlm" in ''|*[!0-9]*) err "$_nll literal ROA maxlen harus bilangan: $_nl" ;; esac
            _nlplen=${_nlp#*/}
            [ "$_nlm" -ge "$_nlplen" ] 2>/dev/null || err "$_nll literal ROA maxlen harus >= panjang prefix ($_nlplen): $_nl"
            case "$_nlp" in *:*)
                [ "$_nlm" -le 128 ] 2>/dev/null || err "$_nll literal ROA maxlen harus 0..128: $_nl" ;;
                *) [ "$_nlm" -le 32 ] 2>/dev/null || err "$_nll literal ROA maxlen harus 0..32: $_nl" ;; esac
            valid_asn "$_nla" "$_nll" ;;
        *) err "$_nll bukan literal net SADR/VPN/ROA (bentuk: DST,from,SRC | rd,RD,PREFIX | PREFIX,max,MAXLEN,as,ASN): $_nl" ;;
    esac
}
net_literal_to_bird() { # net_literal_to_bird <RINGKAS> -> bentuk BIRD (sudah divalidasi)
    _nl="$1"
    case "$_nl" in
        *',from,'*) printf '%s from %s' "${_nl%%,from,*}" "${_nl#*,from,}"; return 0 ;;
        *',max,'*',as,'*) _nlp=${_nl%%,max,*}; _nlr=${_nl#*,max,}; printf '%s max %s as %s' "$_nlp" "${_nlr%%,as,*}" "${_nlr#*,as,}"; return 0 ;;
    esac
    printf '%s' "$_nl"
}
is_net_literal() { # is_net_literal <NILAI> -> 0 bila bentuk ringkas literal net
    case "$1" in rd,*|*',from,'*|*',max,'*',as,'*) return 0 ;; *) return 1 ;; esac
}
prefix_value_to_bird() { # prefix_value_to_bird <ATTR> <NILAI> <label> -> bentuk BIRD
    # ATTR net + literal ringkas -> terjemahkan; selain itu validasi prefix biasa.
    if [ "$1" = "net" ] && is_net_literal "$2"; then
        valid_net_literal "$2" "$3" || exit 33
        net_literal_to_bird "$2"; return 0
    fi
    valid_prefix_any "$2" "$3" || exit 33
    printf '%s' "$2"
}
# define_exists <NAMA> — 0 bila nama didefinisikan (define global di
# bird-global.conf atau define-int di bgp.conf ini).
define_exists() {
    { [ -f "$STATE_ROOT/bird-global.conf" ] && grep -q "^define $1 " "$STATE_ROOT/bird-global.conf" 2>/dev/null; } ||     grep -q "^define-int $1 " "$CONF" 2>/dev/null
}
# valid_int_component <KOMP> <label> — satu komponen int di elemen set:
# literal u32/hex | `*` | range A..B | nama define | ekspresi int
# (digit/nama/+-*/() — mis. myas+2, 0..16*16*16-1, (1+2)).
valid_int_component() {
    _b8c="$1"; _b8l="$2"
    case "$_b8c" in
        '*') return 0 ;;
        *..*)
            _b8a=${_b8c%%..*}; _b8b=${_b8c#*..}
            valid_int_component "$_b8a" "$_b8l"; valid_int_component "$_b8b" "$_b8l"
            return 0 ;;
    esac
    case "$_b8c" in
        0x*) case "$_b8c" in 0x*[!0-9a-fA-F]*) err "$_b8l komponen int hex tidak valid: $_b8c" ;; esac; return 0 ;;
        ''|*[!0-9]*) ;;
        *) valid_u32 "$_b8c" "$_b8l"; return 0 ;;
    esac
    # Karakter yang diizinkan: digit/nama/+-*/.- (kurung dicek seimbang di bawah).
    _b8noparens=$(printf '%s' "$_b8c" | tr -d '()')
    case "$_b8noparens" in
        *[!0-9A-Za-z_+*/.-]*) err "$_b8l komponen int mengandung karakter tidak valid: $_b8c" ;;
    esac
    # Kurung harus seimbang.
    _b8o=$(printf '%s' "$_b8c" | tr -cd '(' | wc -c); _b8cl=$(printf '%s' "$_b8c" | tr -cd ')' | wc -c)
    [ "$_b8o" = "$_b8cl" ] || err "$_b8l komponen int kurung tidak seimbang: $_b8c"
    case "$_b8c" in
        *[-+*/]*) return 0 ;;  # ekspresi (mengandung operator)
        *'('*) return 0 ;;     # ekspresi berkurung
        *')'*) return 0 ;;
    esac
    # Kata tunggal = nama define (wajib terdaftar).
    define_exists "$_b8c" || err "$_b8l komponen int '$_b8c' bukan angka/ekspresi/define terdaftar (define di global -> define-add, atau define-int di BGP)"
}
# split_set_elements <ISI-DALAM-[...]> — cetak tiap elemen per baris,
# pisah koma di kedalaman kurung 0.
split_set_elements() {
    _b8s="$1"; _b8depth=0; _b8cur=""
    while [ -n "$_b8s" ]; do
        _b8c=${_b8s%"${_b8s#?}"}
        _b8s=${_b8s#?}
        case "$_b8c" in
            '(') _b8depth=$((_b8depth+1)); _b8cur="$_b8cur$_b8c" ;;
            ')') _b8depth=$((_b8depth-1)); _b8cur="$_b8cur$_b8c" ;;
            ',')
                if [ "$_b8depth" -eq 0 ]; then printf '%s\n' "$_b8cur"; _b8cur=""; else _b8cur="$_b8cur$_b8c"; fi ;;
            *) _b8cur="$_b8cur$_b8c" ;;
        esac
    done
    [ -n "$_b8cur" ] && printf '%s\n' "$_b8cur"
}
# valid_set_elem_norange <TYPESET> <ELEM> <label> — satu elemen set
# (tanpa range atas `..` di level elemen).
valid_set_elem_norange() {
    _b8t="$1"; _b8e="$2"; _b8l="$3"
    case "$_b8e" in
        '*') return 0 ;;
        '['*']') err "$_b8l elemen set tidak boleh set bersarang: $_b8e" ;;
    esac
    case "$_b8t" in
        int-set) valid_int_component "$_b8e" "$_b8l"; return 0 ;;
        pair-set)
            case "$_b8e" in '('*')') ;; *) _b8e2="$_b8e"; case "$_b8e2" in *[!0-9A-Za-z_]* ) err "$_b8l elemen pair-set harus (AA,NN) atau nama define: $_b8e" ;; esac; define_exists "$_b8e" || err "$_b8l elemen pair-set '$_b8e' bukan (AA,NN)/define terdaftar"; return 0 ;; esac
            _b8p=${_b8e#(}; _b8p=${_b8p%)}
            case "$_b8p" in *,*) ;; *) err "$_b8l elemen pair-set harus (AA,NN): $_b8e" ;; esac
            valid_int_component "${_b8p%%,*}" "$_b8l"; valid_int_component "${_b8p#*,}" "$_b8l"; return 0 ;;
        quad-set) valid_ipv4 "$_b8e" "$_b8l"; return 0 ;;
        ip-set) valid_ip_any "$_b8e" "$_b8l"; return 0 ;;
        prefix-set) valid_prefix_any "$_b8e" "$_b8l"; return 0 ;;
        ec-set)
            case "$_b8e" in '('*')') ;; *) case "$_b8e" in *[!0-9A-Za-z_]* ) err "$_b8l elemen ec-set harus (rt|ro, A, B) atau nama define: $_b8e" ;; esac; define_exists "$_b8e" || err "$_b8l elemen ec-set '$_b8e' bukan (rt|ro, A, B)/define terdaftar"; return 0 ;; esac
            _b8p=${_b8e#(}; _b8p=${_b8p%)}
            case "$_b8p" in *,*,*) ;; *) err "$_b8l elemen ec-set harus (rt|ro, A, B): $_b8e" ;; esac
            _b8k=${_b8p%%,*}; _b8r=${_b8p#*,}; _b8a=${_b8r%%,*}; _b8b=${_b8r#*,}
            case "$_b8k" in rt|ro) ;; *) err "$_b8l elemen ec-set tipe harus rt|ro: $_b8e" ;; esac
            # A10: (rt, *, 3) DILARANG — wildcard ASN butuh wildcard juga di B.
            case "$_b8a" in '*') case "$_b8b" in '*') ;; *) err "$_b8l elemen ec-set (rt, *, X) dilarang docs A10 — pakai (rt, *, *): $_b8e" ;; esac ;; esac
            valid_int_component "$_b8a" "$_b8l"; valid_int_component "$_b8b" "$_b8l"; return 0 ;;
        lc-set)
            case "$_b8e" in '('*')') ;; *) case "$_b8e" in *[!0-9A-Za-z_]* ) err "$_b8l elemen lc-set harus (A,B,C) atau nama define: $_b8e" ;; esac; define_exists "$_b8e" || err "$_b8l elemen lc-set '$_b8e' bukan (A,B,C)/define terdaftar"; return 0 ;; esac
            _b8p=${_b8e#(}; _b8p=${_b8p%)}
            case "$_b8p" in *,*,*) ;; *) err "$_b8l elemen lc-set harus (A,B,C): $_b8e" ;; esac
            _b8a=${_b8p%%,*}; _b8r=${_b8p#*,}; _b8b=${_b8r%%,*}; _b8c=${_b8r#*,}
            # A10: field spesifik sesudah wildcard dilarang.
            case "$_b8a" in '*') case "$_b8b$_b8c" in '**') ;; *) err "$_b8l elemen lc-set wildcard di A butuh wildcard juga di B,C: $_b8e" ;; esac ;; esac
            case "$_b8b" in '*') case "$_b8c" in '*') ;; *) err "$_b8l elemen lc-set wildcard di B butuh wildcard juga di C: $_b8e" ;; esac ;; esac
            valid_int_component "$_b8a" "$_b8l"; valid_int_component "$_b8b" "$_b8l"; valid_int_component "$_b8c" "$_b8l"; return 0 ;;
        enum-set)
            case "$_b8e" in [A-Za-z_][A-Za-z0-9_]*) ;; *) err "$_b8l elemen enum-set harus nama enum/define [A-Za-z_][A-Za-z0-9_]*: $_b8e" ;; esac
            return 0 ;;
        rd-set)
            case "$_b8e" in *[!0-9A-Za-z_:.]* ) err "$_b8l elemen rd-set harus RD (ASN:u32|ASN4:u16|IP:u32) atau nama define: $_b8e" ;; esac
            case "$_b8e" in *:* ) valid_rd "$_b8e" "$_b8l"; return 0 ;; esac
            define_exists "$_b8e" || err "$_b8l elemen rd-set '$_b8e' bukan RD/define terdaftar"; return 0 ;;
    esac
    err "$_b8l tipe set tidak dikenal: $_b8t"
}
# valid_set_elem <TYPESET> <ELEM> <label> — elemen set, termasuk range
# bentuk X..Y (mis. 3..5, (3,4)..(4,8)).
valid_set_elem() {
    _b8t="$1"; _b8e="$2"; _b8l="$3"
    case "$_b8e" in
        *..*)
            case "$_b8e" in *')..('*)
                # Range antar elemen utuh, mis. (3,4)..(4,8): pecah dua sisi.
                case "$_b8t" in int-set|pair-set)
                    _b8x=${_b8e%%..*}; _b8y=${_b8e#*..}
                    valid_set_elem_norange "$_b8t" "$_b8x" "$_b8l"
                    valid_set_elem_norange "$_b8t" "$_b8y" "$_b8l"
                    return 0 ;;
                    *) err "$_b8l range .. antar elemen hanya didukung untuk int-set/pair-set: $_b8e" ;;
                esac ;;
            esac
            # B9: `..` di DALAM komponen, mis. (65000,100..109) atau
            # (rt,10,32..40) — JANGAN dipecah; valid_int_component di
            # norange sudah menangani range per-komponen.
            ;;
    esac
    valid_set_elem_norange "$_b8t" "$_b8e" "$_b8l"
}
valid_set_typeset() { # <TYPESET> <label>
    case "$1" in
        enum-set) err "$2: enum-set TIDAK ada di BIRD 2.20 (tidak ada sintaks 'enum set' / variabel enum — nilai enum dipakai inline, mis. bgp_origin ~ [ORIGIN_IGP,ORIGIN_EGP])" ;;
        int-set|pair-set|quad-set|ip-set|prefix-set|ec-set|lc-set|rd-set) ;;
        *) err "$2 tipe set harus int-set|pair-set|quad-set|ip-set|prefix-set|ec-set|lc-set|rd-set: $1" ;;
    esac
}
valid_set_literal() { # <TYPESET> <LITERAL> <label>
    _b8t="$1"; _b8lit="$2"; _b8l="$3"
    valid_set_typeset "$_b8t" "$_b8l"
    case "$_b8lit" in '['*']') ;; *) err "$_b8l literal set harus [elemen,...] satu token tanpa spasi: $_b8lit" ;; esac
    _b8inner=${_b8lit#\[}; _b8inner=${_b8inner%\]}
    [ -n "$_b8inner" ] || err "$_b8l literal set kosong [] tidak didukung — hapus deklarasi var-set bila tidak butuh"
    split_set_elements "$_b8inner" | while IFS= read -r _b8el; do
        [ -n "$_b8el" ] || err "$_b8l literal set mengandung elemen kosong: $_b8lit"
        valid_set_elem "$_b8t" "$_b8el" "$_b8l"
    done || exit 33
}
# method_elem_bird <OBJ> <ARG> <VARLIST> -> cetak argumen BIRD untuk
# .add/.delete (elemen literal ternormalisasi, set literal, atau nama var).
method_elem_bird() {
    _b8o="$1"; _b8a="$2"; _b8vl="$3"
    case "$_b8a" in '['*']')
        _b8ts=$(case "$_b8o" in bgp_community) echo pair-set ;; bgp_ext_community) echo ec-set ;; bgp_large_community) echo lc-set ;; bgp_cluster_list) echo quad-set ;; esac)
        valid_set_literal "$_b8ts" "$_b8a" "method $_b8o"
        printf '%s' "$_b8a"; return 0 ;;
    esac
    _b8vt=$(var_type "$_b8vl" "$_b8a") && {
        case "$_b8o:$_b8vt" in
            bgp_community:pair|bgp_community:pair-set|bgp_community:clist|bgp_cluster_list:quad|bgp_cluster_list:quad-set|bgp_cluster_list:clist|bgp_ext_community:ec|bgp_ext_community:ec-set|bgp_ext_community:eclist|bgp_large_community:lc|bgp_large_community:lc-set|bgp_large_community:lclist)
                printf '%s' "$_b8a"; return 0 ;;
            *) err "method: variabel $_b8a (tipe $_b8vt) bukan elemen/set $_b8o" ;;
        esac
    }
    case "$_b8o" in
        bgp_community)
            case "$_b8a" in
                '('*')') valid_pair "$_b8a" "method bgp_community"; printf '( %s )' "$(printf '%s' "${_b8a#(}" | sed 's/)$//; s/,/, /')" ; return 0 ;;
                *:*)
                    valid_community "$_b8a" "method bgp_community"
                    printf '( %s, %s )' "${_b8a%%:*}" "${_b8a#*:}"; return 0 ;;
                *) err "method: bgp_community.add/.delete butuh pair (AA,NN) atau AA:NN: $_b8a" ;;
            esac ;;
        bgp_cluster_list) valid_ipv4 "$_b8a" "method bgp_cluster_list"; printf '%s' "$_b8a"; return 0 ;;
        bgp_ext_community) valid_ec "$_b8a" "method bgp_ext_community"; printf '( %s )' "$(printf '%s' "${_b8a#(}" | sed 's/)$//; s/,/, /g')"; return 0 ;;
        bgp_large_community) valid_lc "$_b8a" "method bgp_large_community"; printf '( %s )' "$(printf '%s' "${_b8a#(}" | sed 's/)$//; s/,/, /g')"; return 0 ;;
    esac
}
# method_to_bird <CALL> <VARLIST> -> cetak statement BIRD tanpa ';'.
# CALL: OBJ.METHOD(args) | OBJ.empty — OBJ bgp_community |
# bgp_ext_community | bgp_large_community | bgp_cluster_list | bgp_path.
# METHOD: add (clist saja; bgp_path pakai prepend), delete, filter,
# prepend (bgp_path saja), empty (tanpa argumen; bentuk docs `C.empty;`).
method_to_bird() {
    _b8mc="$1"; _b8vl="$2"
    case "$_b8mc" in *.*'('*')') ;; *'.empty') ;; *'.empty()') ;; *) err "method: bentuk harus OBJ.METHOD(args) atau OBJ.empty: $_b8mc" ;; esac
    _b8obj=${_b8mc%%.*}; _b8rest=${_b8mc#*.}
    case "$_b8obj" in bgp_community|bgp_ext_community|bgp_large_community|bgp_cluster_list|bgp_path) ;; *) err "method: objek harus bgp_community|bgp_ext_community|bgp_large_community|bgp_cluster_list|bgp_path: $_b8mc" ;; esac
    case "$_b8rest" in *'('*) _b8m=${_b8rest%%'('*}; _b8args=${_b8rest#*'('}; _b8args=${_b8args%')'} ;; *) _b8m="$_b8rest"; _b8args="" ;; esac
    case "$_b8m" in add|delete|filter|prepend|empty) ;; *) err "method: METHOD harus add|delete|filter|prepend|empty: $_b8mc" ;; esac
    case "$_b8m" in
        empty)
            [ -z "$_b8args" ] || err "method: .empty tidak pakai argumen: $_b8mc"
            printf '%s.empty' "$_b8obj"; return 0 ;;
        prepend)
            [ "$_b8obj" = "bgp_path" ] || err "method: .prepend hanya untuk bgp_path: $_b8mc"
            [ -n "$_b8args" ] || err "method: .prepend butuh ASN: $_b8mc"
            case "$_b8args" in *,*) err "method: .prepend hanya 1 ASN: $_b8mc" ;; esac
            _b8vt=$(var_type "$_b8vl" "$_b8args") && { [ "$_b8vt" = "int" ] || err "method: .prepend argumen variabel harus int: $_b8mc"; printf '%s.prepend(%s)' "$_b8obj" "$_b8args"; return 0; }
            valid_asn "$_b8args" "method prepend"
            printf '%s.prepend(%s)' "$_b8obj" "$_b8args"; return 0 ;;
        add)
            [ "$_b8obj" != "bgp_path" ] || err "method: bgp_path tidak punya .add — pakai .prepend(ASN): $_b8mc"
            [ -n "$_b8args" ] || err "method: .add butuh 1 elemen: $_b8mc"
            _b8marg=$(method_elem_bird "$_b8obj" "$_b8args" "$_b8vl") || exit 33
            printf '%s.add(%s)' "$_b8obj" "$_b8marg"; return 0 ;;
        delete)
            [ -n "$_b8args" ] || err "method: .delete butuh argumen: $_b8mc"
            if [ "$_b8obj" = "bgp_path" ]; then
                _b8vt=$(var_type "$_b8vl" "$_b8args") && { [ "$_b8vt" = "int" ] || err "method: bgp_path.delete argumen variabel harus int: $_b8mc"; printf '%s.delete(%s)' "$_b8obj" "$_b8args"; return 0; }
                valid_asn "$_b8args" "method bgp_path.delete"
                printf '%s.delete(%s)' "$_b8obj" "$_b8args"; return 0
            fi
            _b8marg=$(method_elem_bird "$_b8obj" "$_b8args" "$_b8vl") || exit 33
            printf '%s.delete(%s)' "$_b8obj" "$_b8marg"; return 0 ;;
        filter)
            [ -n "$_b8args" ] || err "method: .filter butuh argumen: $_b8mc"
            if [ "$_b8obj" = "bgp_path" ]; then
                valid_bgpmask "$_b8args" "method bgp_path.filter"
                printf '%s.filter(%s)' "$_b8obj" "$(bgpmask_to_bird "$_b8args")"; return 0
            fi
            case "$_b8args" in '['*']')
                _b8ts=$(case "$_b8obj" in bgp_community) echo pair-set ;; bgp_ext_community) echo ec-set ;; bgp_large_community) echo lc-set ;; bgp_cluster_list) echo quad-set ;; esac)
                valid_set_literal "$_b8ts" "$_b8args" "method $_b8obj.filter"
                printf '%s.filter(%s)' "$_b8obj" "$_b8args"; return 0 ;;
                *)
                _b8vt=$(var_type "$_b8vl" "$_b8args") || err "method: .filter argumen harus set literal [...] atau variabel set: $_b8mc"
                case "$_b8vt" in *-set) ;; *) err "method: .filter argumen $_b8args harus variabel set (tipe $_b8vt): $_b8mc" ;; esac
                printf '%s.filter(%s)' "$_b8obj" "$_b8args"; return 0 ;;
            esac ;;
    esac
}

bgpmask_to_bird() { # <mask-koma> -> "[= e1 e2 ... =]"
    printf '[= %s =]' "$(printf '%s' "$1" | sed 's/,/ /g')"
}

# attr_kind <ATTR> -> int | pair | ip | bool | string | prefix | bgppath |
#   clist | eclist | lclist | rd | ec | lc | enum:ORIGIN | enum:SOURCE |
#   enum:DEST | enum:NETTYPE | enum:RAPREF | unknown
# B8: net.type (enum NET_*), net.rd, net.maxlen/net.asn (ROA), net.src/
# net.dst (flowspec), pair/lc .min/.max + .asn/.data(.1/.2), ra_preference
# (enum RA_PREF_*), ra_lifetime (int).
attr_kind() {
    case "$1" in
        net.len|bgp_path.len|bgp_community.len|bgp_ext_community.len|bgp_large_community.len|bgp_cluster_list.len|bgp_local_pref|bgp_med|bgp_otc|preference|igp_metric|weight|rip_metric|bgp_path.first|bgp_path.last|bgp_path.last_nonaggregated|net.maxlen|net.asn|bgp_community.min.asn|bgp_community.min.data|bgp_community.max.asn|bgp_community.max.data|bgp_large_community.min.asn|bgp_large_community.min.data1|bgp_large_community.min.data2|bgp_large_community.max.asn|bgp_large_community.max.data1|bgp_large_community.max.data2|ra_lifetime|babel_metric|gw_mpls|mpls_label|mpls_class|ospf_metric1|ospf_metric2|ospf_tag) echo int ;;
        bgp_community.min|bgp_community.max) echo pair ;;
        bgp_large_community.min|bgp_large_community.max) echo lc ;;
        bgp_ext_community.min|bgp_ext_community.max) echo ec ;;
        bgp_origin) echo enum:ORIGIN ;;
        mpls_policy) echo enum:MPLSPOLICY ;;
        source) echo enum:SOURCE ;;
        dest) echo enum:DEST ;;
        net.type) echo enum:NETTYPE ;;
        ra_preference) echo enum:RAPREF ;;
        net.rd) echo rd ;;
        bgp_next_hop|gw|from|net.ip) echo ip ;;
        onlink) echo bool ;;
        proto|ifname) echo string ;;
        net|net.src|net.dst) echo prefix ;;
        bgp_path) echo bgppath ;;
        bgp_community|bgp_cluster_list) echo clist ;;
        bgp_ext_community) echo eclist ;;
        bgp_large_community) echo lclist ;;
        *) bgp_attr_exists "$1" && echo bytestring || echo unknown ;;
    esac
}

valid_int_atom() { # valid_int_atom <OPERAND> <VARLIST> <label> — satu operand ekspresi int (B12/5-90/91)
    _ia="$1"; _ivl="$2"; _il="$3"
    case "$_ia" in ''|*[!0-9]*) ;; *) valid_u32 "$_ia" "$_il"; return 0 ;; esac
    case "$_ia" in 0x*) case "$_ia" in 0x*[!0-9a-fA-F]*) err "$_il operand hex tidak valid: $_ia" ;; esac; return 0 ;; esac
    _ivt=$(var_type "$_ivl" "$_ia") && [ "$_ivt" = "int" ] && return 0
    define_exists "$_ia" && return 0
    [ "$(attr_kind "$_ia")" = "int" ] && return 0
    accessor_bird "$_ia" "$_ivl" >/dev/null 2>&1 && return 0  # B16/5-46..50: p.asn / c.data1 (int)
    err "$_il operand int tidak dikenal (harus bilangan/hex/variabel-int/define/atribut-int/accessor .asn/.data): $_ia"
}
valid_int_expr() { # valid_int_expr <NILAI> <VARLIST> <label> — literal/var/define/atribut-int/ekspresi aritmetika (+ - * / dan kurung, B12/5-90/91); otoritas akhir bird -p; pembagian nol BIRD = runtime error (bukan parse error)
    # B12: unescape klish (lihat cond_to_bird) — nilai int via klish bisa
    # membawa "\(" / "\>" dari substitusi ACTION.
    set -- "$(klish_unescape "$1")" "$2" "$3"
    _ie="$1"; _ivl="$2"; _il="$3"
    [ -n "$_ie" ] || err "$_il ekspresi int tidak boleh kosong"
    _iebad=$(printf '%s' "$_ie" | tr -d '0-9A-Za-z_+*/().-')
    [ -z "$_iebad" ] || err "$_il ekspresi int mengandung karakter tidak valid: $_ie"
    _ieo=$(printf '%s' "$_ie" | tr -cd '(' | wc -c); _iec=$(printf '%s' "$_ie" | tr -cd ')' | wc -c)
    [ "$_ieo" = "$_iec" ] || err "$_il ekspresi int kurung tidak seimbang: $_ie"
    _iecur=""; _ierest="$_ie"; _ieprev="start"
    while [ -n "$_ierest" ]; do
        _iech=${_ierest%"${_ierest#?}"}; _ierest=${_ierest#?}
        case "$_iech" in
            '+'|'-'|'*'|'/')
                case "$_ieprev" in operand|close) ;; *) err "$_il ekspresi int: operator '$_iech' di posisi salah: $_ie" ;; esac
                [ -n "$_iecur" ] && { valid_int_atom "$_iecur" "$_ivl" "$_il" || exit 33; _iecur=""; }
                _ieprev="op" ;;
            '(')
                case "$_ieprev" in start|op|open) ;; *) err "$_il ekspresi int: '(' di posisi salah: $_ie" ;; esac
                _ieprev="open" ;;
            ')')
                case "$_ieprev" in operand|close) ;; *) err "$_il ekspresi int: ')' di posisi salah (kurung kosong?): $_ie" ;; esac
                [ -n "$_iecur" ] && { valid_int_atom "$_iecur" "$_ivl" "$_il" || exit 33; _iecur=""; }
                _ieprev="close" ;;
            *)
                case "$_ieprev" in start|op|open|operand) ;; *) err "$_il ekspresi int: karakter '$_iech' di posisi salah: $_ie" ;; esac
                _iecur="$_iecur$_iech"; _ieprev="operand" ;;
        esac
    done
    case "$_ieprev" in operand|close) ;; *) err "$_il ekspresi int diakhiri operator/kurung buka: $_ie" ;; esac
    [ -n "$_iecur" ] && { valid_int_atom "$_iecur" "$_ivl" "$_il" || exit 33; }
    return 0
}

valid_attr_value() { # valid_attr_value <ATTR> <NILAI> <label> [VARLIST] — B12: int kini ekspresi aritmetika; tambah bytestring (attribute-bgp, 5-45)
    _k=$(attr_kind "$1")
    case "$_k" in
        int) valid_int_expr "$2" "${4:-}" "$3" ;;
        bytestring) valid_bytestring "$2" "$3" ;;
        pair)
            case "$2" in '('*','*')') ;; *) err "$3 harus pair (AA,NN): $2" ;; esac
            _vv_pa=${2#(}; _vv_pa=${_vv_pa%)}; _vv_a=${_vv_pa%%,*}; _vv_n=${_vv_pa#*,}
            case "$_vv_a" in ''|*[!0-9]*) err "$3 pair AS harus angka: $2" ;; esac
            case "$_vv_n" in ''|*[!0-9]*) err "$3 pair NN harus angka: $2" ;; esac
            [ "$_vv_a" -le 65535 ] 2>/dev/null || err "$3 pair AS harus 0..65535: $2"
            [ "$_vv_n" -le 65535 ] 2>/dev/null || err "$3 pair NN harus 0..65535: $2" ;;
        enum:ORIGIN) case "$2" in ORIGIN_IGP|ORIGIN_EGP|ORIGIN_INCOMPLETE) ;; *) err "$3 harus ORIGIN_IGP|ORIGIN_EGP|ORIGIN_INCOMPLETE: $2" ;; esac ;;
        enum:SOURCE) case "$2" in RTS_STATIC|RTS_STATIC_DEVICE|RTS_INHERIT|RTS_DEVICE|RTS_REDIRECT|RTS_RIP|RTS_OSPF|RTS_OSPF_IA|RTS_OSPF_EXT1|RTS_OSPF_EXT2|RTS_BGP|RTS_PIPE|RTS_BABEL|RTS_RPKI) ;; *) err "$3 harus nilai RTS_*: $2" ;; esac ;;
        enum:DEST) case "$2" in RTD_ROUTER|RTD_DEVICE|RTD_MULTIPATH|RTD_BLACKHOLE|RTD_UNREACHABLE|RTD_PROHIBIT) ;; *) err "$3 harus nilai RTD_*: $2" ;; esac ;;
        ip) valid_ip_any "$2" "$3" ;;
        bool) case "$2" in true|false) ;; *) err "$3 harus true|false: $2" ;; esac ;;
        string) valid_nospace "$2" "$3" ;;
        prefix) valid_prefix_any "$2" "$3" ;;
        rd) valid_rd "$2" "$3" ;;
        ec) valid_ec "$2" "$3" ;;
        lc) valid_lc "$2" "$3" ;;
        enum:NETTYPE) case "$2" in NET_IP4|NET_IP6|NET_IP6_SADR|NET_VPN4|NET_VPN6|NET_ROA4|NET_ROA6|NET_FLOW4|NET_FLOW6|NET_MPLS|NET_ASPA|NET_EVPN) ;; *) err "$3 harus NET_IP4|NET_IP6|NET_IP6_SADR|NET_VPN4|NET_VPN6|NET_ROA4|NET_ROA6|NET_FLOW4|NET_FLOW6|NET_MPLS|NET_ASPA|NET_EVPN: $2" ;; esac ;;
        enum:RAPREF) case "$2" in RA_PREF_LOW|RA_PREF_MEDIUM|RA_PREF_HIGH) ;; *) err "$3 harus RA_PREF_LOW|RA_PREF_MEDIUM|RA_PREF_HIGH: $2" ;; esac ;;
        enum:MPLSPOLICY) case "$2" in MPLS_POLICY_NONE|MPLS_POLICY_STATIC|MPLS_POLICY_PREFIX|MPLS_POLICY_AGGREGATE|MPLS_POLICY_VRF) ;; *) err "$3 harus MPLS_POLICY_NONE|STATIC|PREFIX|AGGREGATE|VRF: $2" ;; esac ;;
        *) err "$3 atribut tidak dikenal / nilainya tidak bisa divalidasi: $1" ;;
    esac
}

# Registry intent (dibaca dari $CONF; dipakai validasi lintas-baris).
custom_attr_exists() { grep -q "^attribute-int $1\$" "$CONF" 2>/dev/null; }
bgp_attr_exists() { grep -q "^attribute-bgp [0-9]* $1\$" "$CONF" 2>/dev/null; } # B12/5-45: atribut BGP tak dikenal (attribute-bgp N NAME, bytestring)
# B12/5-105: tabel ROA bisa didefinisikan di 3 tempat — bgp.conf (roa-table),
# bird-global.conf (table roa4|roa6 NAMA), atau rpki.conf (instance ... roa4-table|
# roa6-table NAMA). Ketiganya materialisasi jadi tabel BIRD yang sama di bird.conf.
roa_table_exists() {
    grep -q "^roa-table $1\( \|$\)" "$CONF" 2>/dev/null && return 0
    grep -q "^table roa[46] $1\$" "${STATE_ROOT}/bird-global.conf" 2>/dev/null && return 0
    grep -q " roa[46]-table $1\$" "${STATE_ROOT}/rpki.conf" 2>/dev/null && return 0
    return 1
}
# B12/5-108: tabel ASPA — bgp.conf (aspa-table), bird-global.conf (table aspa
# NAMA), atau rpki.conf (instance ... aspa-table NAMA).
aspa_table_exists() {
    grep -q "^aspa-table $1\$" "$CONF" 2>/dev/null && return 0
    grep -q "^table aspa $1\$" "${STATE_ROOT}/bird-global.conf" 2>/dev/null && return 0
    grep -q " aspa-table $1\$" "${STATE_ROOT}/rpki.conf" 2>/dev/null && return 0
    return 1
}
# function_exists <NAMA> — net_is_private bawaan + intent function.intent
function_exists() {
    [ "$1" = "net_is_private" ] && return 0
    [ -f "${STATE_ROOT}/function.intent" ] && grep -q "^function $1 " "${STATE_ROOT}/function.intent" 2>/dev/null
}
# function_params <NAMA> -> "TIPE:NAMA TIPE:NAMA ..." (kosong = 0 param)
function_params() {
    [ "$1" = "net_is_private" ] && return 0
    grep "^function $1 param " "${STATE_ROOT}/function.intent" 2>/dev/null | awk '{printf "%s:%s ", $4, $5}'
}

# filter_vars <FILTER> -> "nama:tipe nama:tipe ..." (var lokal + var for)
filter_vars() {
    grep "^filter $1 " "$CONF" 2>/dev/null | awk '$3 == "var" {printf "%s:%s ", $5, $4} $3 == "var-set" {printf "%s:%s ", $5, $4} $3 == "for-block" {printf "%s:%s ", $5, $4}'
}
# var_type <VARLIST> <NAMA> -> tipe atau kosong
var_type() {
    _vl="$1"; _vn="$2"
    for _vt in $_vl; do
        case "$_vt" in "$_vn":*) printf '%s' "${_vt#*:}"; return 0 ;; esac
    done
    return 1
}

# settable_attr <ATTR> -> 0 bila boleh di-set di filter (B5).
# DITOLAK: net/proto/ifindex (RO, A4), scope (dihapus BIRD 3), bgp_path/
# bgp_community/eclist/lclist (hanya method .add/.delete/.filter/.prepend),
# bgp_otc/bgp_originator_id/bgp_cluster_list (set-nya RR/otomatis),
# source/from (A4: assignment tidak dikonfirmasi docs), ifname (A12:
# menghapus gateway). B9: gw_mpls/mpls_label/mpls_policy RW (ch5 5-131/133/134);
# babel_metric/mpls_class RO (ch5 5-132/135) — hanya match, tidak di-set.
# B13 (O60-O62): ospf_metric1/2/tag RW di filter (docs Bab 6.11; terverifikasi
# bird -p 2.20.0: assignment di filter + di blok route static).
settable_attr() {
    case "$1" in
        preference|gw|bgp_local_pref|bgp_med|bgp_origin|bgp_next_hop|igp_metric|weight|onlink|rip_metric|dest|ra_lifetime|ra_preference|gw_mpls|mpls_label|mpls_policy|ospf_metric1|ospf_metric2|ospf_tag) return 0 ;;
        *) custom_attr_exists "$1" && return 0; bgp_attr_exists "$1" && return 0; return 1 ;;
    esac
}
valid_set_stmt() { # valid_set_stmt <ATTR> <NILAI> [label] [VARLIST]
    _l="${3:-set}"; _vl="$4"
    if [ -n "$_vl" ]; then
        _vt=$(var_type "$_vl" "$1") && { valid_var_value "$_vt" "$2" "$_l" "$_vl"; return 0; }
    fi
    settable_attr "$1" || err "$_l atribut tidak bisa di-set di filter: $1 (RO / hanya method / hanya match — lihat header B5)"
    if [ "$1" = "dest" ]; then
        case "$2" in RTD_BLACKHOLE|RTD_UNREACHABLE|RTD_PROHIBIT) ;; *) err "$_l dest hanya boleh RTD_BLACKHOLE|RTD_UNREACHABLE|RTD_PROHIBIT (A19): $2" ;; esac
        return 0
    fi
    if custom_attr_exists "$1"; then
        valid_u32 "$2" "$_l (atribut int $1)"
        return 0
    fi
    valid_attr_value "$1" "$2" "$_l" "$_vl"
    case "$2" in ''|*[!0-9]*) ;; *)  # ekspresi (bukan bilangan polos): rentang dicek bird -p (B12/5-90/91)
    case "$1" in
        preference) [ "$2" -le 65535 ] 2>/dev/null || err "$_l preference harus 0..65535: $2" ;;
        net.len|bgp_path.len|bgp_community.len) ;; # u32 sudah cukup
        weight) { [ "$2" -ge 1 ] 2>/dev/null && [ "$2" -le 256 ] 2>/dev/null; } || err "$_l weight harus 1..256: $2" ;;
        mpls_label|gw_mpls) [ "$2" -le 1048575 ] 2>/dev/null || err "$_l $1 harus label 20-bit 0..1048575: $2" ;;
        ospf_metric1) { [ "$2" -ge 1 ] 2>/dev/null && [ "$2" -le 65535 ] 2>/dev/null; } || err "$_l ospf_metric1 harus 1..65535 (docs Bab 6.11, infinity 65535): $2" ;;
    esac
    ;; esac
}
# unsettable_attr <ATTR> -> 0 bila boleh di-unset.
unsettable_attr() {
    case "$1" in
        bgp_community|bgp_ext_community|bgp_large_community|bgp_med|bgp_local_pref|bgp_origin|bgp_next_hop|bgp_originator_id|bgp_cluster_list|bgp_otc|bgp_path|rip_metric|ospf_metric1|ospf_metric2|ospf_tag) return 0 ;;
        *) custom_attr_exists "$1" && return 0; bgp_attr_exists "$1" && return 0; return 1 ;;
    esac
}
valid_unset_attr() { # valid_unset_attr <ATTR> [label]
    unsettable_attr "$1" || err "${2:-unset} atribut tidak bisa di-unset: $1 (wajib/RO — net/proto/ifindex tidak bisa di-unset)"
}
valid_var_type() { # valid_var_type <TIPE> <label>
    case "$1" in int|bool|pair|ip|prefix|string|quad|bytestring|rd|ec|lc) ;; *) err "$2 tipe variabel harus int|bool|pair|ip|prefix|string|quad|bytestring|rd|ec|lc: $1" ;; esac
}
valid_var_value() { # valid_var_value <TIPE> <NILAI> <label> [VARLIST] — B12: int kini ekspresi aritmetika
    case "$1" in
        int) valid_int_expr "$2" "${4:-}" "$3" ;;
        bool) case "$2" in true|false) ;; *) err "$3 harus true|false: $2" ;; esac ;;
        pair)
            case "$2" in '('*','*')') ;; *) err "$3 harus pair (AA,NN): $2" ;; esac
            _vv_pa=${2#(}; _vv_pa=${_vv_pa%)}; _vv_a=${_vv_pa%%,*}; _vv_n=${_vv_pa#*,}
            [ "$_vv_a" -le 65535 ] 2>/dev/null || err "$3 pair AS harus 0..65535: $2"
            [ "$_vv_n" -le 65535 ] 2>/dev/null || err "$3 pair NN harus 0..65535: $2" ;;
        ip) valid_ip_any "$2" "$3" ;;
        prefix) valid_prefix "$2" "$3" ;;
        string) valid_nospace "$2" "$3" ;;
        quad) valid_ipv4 "$2" "$3" ;;
        bytestring) valid_bytestring "$2" "$3" ;;
        rd) valid_rd "$2" "$3" ;;
        ec) valid_ec "$2" "$3" ;;
        lc) valid_lc "$2" "$3" ;;
    esac
}

# filter_minmax_bird <ATOM> <label> — filter(OBJ,[set]).min|.max (Bab 5,
# 5-85/86, B9). OBJ bgp_community|bgp_ext_community|bgp_large_community;
# set literal divalidasi penuh via valid_set_literal. Cetak ekspresi BIRD.
filter_minmax_bird() {
    _fmatom="$1"; _fml="$2"
    case "$_fmatom" in filter"("*")".min|filter"("*")".max) ;; *) err "$_fml harus filter(OBJ,[set]).min|.max: $_fmatom" ;; esac
    _fmobj=${_fmatom#filter(}; _fmobj=${_fmobj%%,*}
    _fmset=${_fmatom#*,}; _fmset=${_fmset%)*}
    _fmsuf=${_fmatom##*)}; _fmsuf=${_fmsuf#.}
    case "$_fmobj" in
        bgp_community) valid_set_literal pair-set "$_fmset" "$_fml" ;;
        bgp_ext_community) valid_set_literal ec-set "$_fmset" "$_fml" ;;
        bgp_large_community) valid_set_literal lc-set "$_fmset" "$_fml" ;;
        *) err "$_fml objek filter() harus bgp_community|bgp_ext_community|bgp_large_community: $_fmobj" ;;
    esac
    printf 'filter(%s, %s).%s' "$_fmobj" "$_fmset" "$_fmsuf"
}

# --- B5: bahasa kondisi (COND) ---
# atom_to_bird <ATOM> <VARLIST> -> cetak ekspresi BIRD; gagal -> err.
atom_to_bird() {
    _at="$1"; _vl="$2"
    case "$_at" in
        true|false) printf '%s' "$_at"; return 0 ;;
        'defined:'*) _a=${_at#defined:}
            [ "$(attr_kind "$_a")" != "unknown" ] || custom_attr_exists "$_a" || err "defined() atribut tidak dikenal: $_a"
            printf 'defined(%s)' "$_a"; return 0 ;;
        '!defined:'*) _a=${_at#!defined:}
            [ "$(attr_kind "$_a")" != "unknown" ] || custom_attr_exists "$_a" || err "defined() atribut tidak dikenal: $_a"
            printf '! defined(%s)' "$_a"; return 0 ;;
        'net~'*) _p=${_at#net~}
            valid_prefix_pattern_any "$_p" "kondisi net~"
            case "$_p" in *+|*-|*{*}) printf 'net ~ [ %s ]' "$_p" ;; *) printf 'net ~ [ %s+ ]' "$_p" ;; esac
            return 0 ;;
        'net!~'*) _p=${_at#net!~}  # B16/5-95
            valid_prefix_pattern_any "$_p" "kondisi net!~"
            case "$_p" in *+|*-|*{*}) printf 'net !~ [ %s ]' "$_p" ;; *) printf 'net !~ [ %s+ ]' "$_p" ;; esac
            return 0 ;;
        'path~'*) _m=${_at#path~}
            valid_bgpmask "$_m" "kondisi path~"
            printf 'bgp_path ~ %s' "$(bgpmask_to_bird "$_m")"; return 0 ;;
        'path!~'*) _m=${_at#path!~}  # B16/5-95
            valid_bgpmask "$_m" "kondisi path!~"
            printf 'bgp_path !~ %s' "$(bgpmask_to_bird "$_m")"; return 0 ;;
        'community~'*) _c=${_at#community~}
            valid_community "$_c" "kondisi community~"
            printf 'bgp_community ~ [ (%s, %s) ]' "${_c%%:*}" "${_c#*:}"; return 0 ;;
        'community!~'*) _c=${_at#community!~}  # B16/5-95
            valid_community "$_c" "kondisi community!~"
            printf 'bgp_community !~ [ (%s, %s) ]' "${_c%%:*}" "${_c#*:}"; return 0 ;;
        'ext-community~'*) _c=${_at#ext-community~}
            valid_ext_community "$_c" "kondisi ext-community~"
            printf 'bgp_ext_community ~ [ (%s, %s, %s) ]' "${_c%%:*}" "$(echo "$_c" | cut -d: -f2)" "$(echo "$_c" | cut -d: -f3)"; return 0 ;;
        'ext-community!~'*) _c=${_at#ext-community!~}  # B16/5-95
            valid_ext_community "$_c" "kondisi ext-community!~"
            printf 'bgp_ext_community !~ [ (%s, %s, %s) ]' "${_c%%:*}" "$(echo "$_c" | cut -d: -f2)" "$(echo "$_c" | cut -d: -f3)"; return 0 ;;
        'large-community~'*) _c=${_at#large-community~}
            valid_large_community "$_c" "kondisi large-community~"
            printf 'bgp_large_community ~ [ (%s, %s, %s) ]' "$(echo "$_c" | cut -d: -f2)" "$(echo "$_c" | cut -d: -f3)" "$(echo "$_c" | cut -d: -f4)"; return 0 ;;
        'large-community!~'*) _c=${_at#large-community!~}  # B16/5-95
            valid_large_community "$_c" "kondisi large-community!~"
            printf 'bgp_large_community !~ [ (%s, %s, %s) ]' "$(echo "$_c" | cut -d: -f2)" "$(echo "$_c" | cut -d: -f3)" "$(echo "$_c" | cut -d: -f4)"; return 0 ;;
        'src~'*) _p=${_at#src~}
            valid_prefix_pattern_any "$_p" "kondisi src~"
            case "$_p" in *+|*-|*{*}) printf 'net.src ~ [ %s ]' "$_p" ;; *) printf 'net.src ~ [ %s+ ]' "$_p" ;; esac
            return 0 ;;
        'src!~'*) _p=${_at#src!~}  # B16/5-95
            valid_prefix_pattern_any "$_p" "kondisi src!~"
            case "$_p" in *+|*-|*{*}) printf 'net.src !~ [ %s ]' "$_p" ;; *) printf 'net.src !~ [ %s+ ]' "$_p" ;; esac
            return 0 ;;
        'dst~'*) _p=${_at#dst~}
            valid_prefix_pattern_any "$_p" "kondisi dst~"
            case "$_p" in *+|*-|*{*}) printf 'net.dst ~ [ %s ]' "$_p" ;; *) printf 'net.dst ~ [ %s+ ]' "$_p" ;; esac
            return 0 ;;
        'dst!~'*) _p=${_at#dst!~}  # B16/5-95
            valid_prefix_pattern_any "$_p" "kondisi dst!~"
            case "$_p" in *+|*-|*{*}) printf 'net.dst !~ [ %s ]' "$_p" ;; *) printf 'net.dst !~ [ %s+ ]' "$_p" ;; esac
            return 0 ;;
        'net.ip.is_v4') printf 'net.ip.is_v4'; return 0 ;;
        '!net.ip.is_v4') printf '! net.ip.is_v4'; return 0 ;;
        'from.is_v4'|'gw.is_v4'|'bgp_next_hop.is_v4') printf '%s' "$_at"; return 0 ;;
        '!from.is_v4'|'!gw.is_v4'|'!bgp_next_hop.is_v4') printf '! %s' "${_at#!}"; return 0 ;;
        *'!~set:'*)  # B16/5-95 (WAJIB sebelum ~set: — "X!~set:V" juga cocok pola *~set:*)
            _lhs=${_at%%'!~set:'*}; _var=${_at##*'!~set:'}
            [ -n "$_lhs" ] && [ -n "$_var" ] || err "kondisi !~set: butuh ATTR!~set:VAR: $_at"
            _k=$(attr_kind "$_lhs")
            [ "$_k" != "unknown" ] || err "kondisi !~set: atribut tidak dikenal: $_lhs"
            _vt=$(var_type "$_vl" "$_var") || err "kondisi !~set: variabel $_var tidak dideklarasikan (var-set di filter ini)"
            case "$_vt" in *-set) ;; *) err "kondisi !~set: $_var harus variabel set (tipe $_vt): $_at" ;; esac
            _elem=${_vt%-set}
            case "$_k:$_elem" in
                int:int|pair:pair|ip:ip|prefix:prefix|rd:rd|ec:ec|lc:lc|bgppath:int) ;;
                clist:pair|clist:quad|eclist:ec|lclist:lc) ;;
                *) err "kondisi !~set: tipe elemen set $_var ($_vt) tidak cocok dengan $_lhs ($_k)" ;;
            esac
            printf '%s !~ %s' "$_lhs" "$_var"; return 0 ;;
        *'~set:'*)
            _lhs=${_at%%'~set:'*}; _var=${_at##*'~set:'}
            [ -n "$_lhs" ] && [ -n "$_var" ] || err "kondisi ~set: butuh ATTR~set:VAR: $_at"
            _k=$(attr_kind "$_lhs")
            [ "$_k" != "unknown" ] || err "kondisi ~set: atribut tidak dikenal: $_lhs"
            _vt=$(var_type "$_vl" "$_var") || err "kondisi ~set: variabel $_var tidak dideklarasikan (var-set di filter ini)"
            case "$_vt" in *-set) ;; *) err "kondisi ~set: $_var harus variabel set (tipe $_vt): $_at" ;; esac
            _elem=${_vt%-set}
            case "$_k:$_elem" in
                int:int|pair:pair|ip:ip|prefix:prefix|rd:rd|ec:ec|lc:lc|bgppath:int) ;;
                clist:pair|clist:quad|eclist:ec|lclist:lc) ;;
                *) err "kondisi ~set: tipe elemen set $_var ($_vt) tidak cocok dengan $_lhs ($_k)" ;;
            esac
            printf '%s ~ %s' "$_lhs" "$_var"; return 0 ;;
        'roa:'*'='*)
            _t=${_at#roa:}; _t=${_t%%=*}; _r=${_at#*=}
            case "$_r" in ROA_VALID|ROA_INVALID|ROA_UNKNOWN) ;; *) err "kondisi roa: hasil harus ROA_VALID|ROA_INVALID|ROA_UNKNOWN: $_r" ;; esac
            case "$_t" in *,*,*)  # B12/5-105: bentuk 3-argumen roa_check(TABEL,PREFIX,ASN)
                _rt=${_t%%,*}; _rr=${_t#*,}; _rp=${_rr%%,*}; _ra=${_rr#*,}
                case "$_ra" in *,*) err "kondisi roa: harus roa:TABEL,PREFIX,ASN=ROA_* (tepat 3 bagian): $_at" ;; esac
                [ -n "$_rt" ] && [ -n "$_rp" ] && [ -n "$_ra" ] || err "kondisi roa: harus roa:TABEL,PREFIX,ASN=ROA_*: $_at"
                roa_table_exists "$_rt" || err "kondisi roa: tabel roa $_rt belum didefinisikan (roa-table $_rt)"
                case "$_rp" in net) ;; *) valid_prefix_any "$_rp" "kondisi roa prefix" ;; esac
                case "$_ra" in bgp_path.last) ;; *) valid_asn "$_ra" "kondisi roa ASN" ;; esac
                printf 'roa_check(%s, %s, %s) = %s' "$_rt" "$_rp" "$_ra" "$_r"; return 0 ;;
                *)
                roa_table_exists "$_t" || err "kondisi roa: tabel roa $_t belum didefinisikan (roa-table $_t)"
                printf 'roa_check(%s) = %s' "$_t" "$_r"; return 0 ;;
            esac ;;
        'aspa:'*'='*)  # B12/5-108: aspa_check 3-argumen (TABEL,PATH,BOOL)
            _t=${_at#aspa:}; _t=${_t%%=*}; _r=${_at#*=}
            case "$_t" in *,*,*)
                _st=${_t%%,*}; _sr=${_t#*,}; _sp=${_sr%%,*}; _sb=${_sr#*,}
                case "$_sb" in *,*) err "kondisi aspa: harus aspa:TABEL,PATH,BOOL=ASPA_* (tepat 3 bagian): $_at" ;; esac
                [ -n "$_st" ] && [ -n "$_sp" ] && [ -n "$_sb" ] || err "kondisi aspa: harus aspa:TABEL,PATH,BOOL=ASPA_*: $_at"
                aspa_table_exists "$_st" || err "kondisi aspa: tabel aspa $_st belum didefinisikan (aspa-table $_st)"
                case "$_sp" in bgp_path) ;; *) err "kondisi aspa: PATH harus bgp_path (satu-satunya bgppath): $_sp" ;; esac
                case "$_sb" in true|up) _sb=true ;; false|down) _sb=false ;; *) err "kondisi aspa: BOOL harus true|up (upstream) atau false|down (downstream): $_sb" ;; esac
                case "$_r" in ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN) ;; *) err "kondisi aspa: hasil harus ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN: $_r" ;; esac
                printf 'aspa_check(%s, %s, %s) = %s' "$_st" "$_sp" "$_sb" "$_r"; return 0 ;;
                *)
                err "kondisi aspa: harus aspa:TABEL,PATH,BOOL=ASPA_* (bentuk 1-argumen pakai aspa-down:/aspa-up:): $_at" ;;
            esac ;;
        'aspa-down:'*'='*)
            _t=${_at#aspa-down:}; _t=${_t%%=*}; _r=${_at#*=}
            aspa_table_exists "$_t" || err "kondisi aspa-down: tabel aspa $_t belum didefinisikan (aspa-table $_t)"
            case "$_r" in ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN) ;; *) err "kondisi aspa: hasil harus ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN: $_r" ;; esac
            printf 'aspa_check_downstream(%s) = %s' "$_t" "$_r"; return 0 ;;
        'aspa-up:'*'='*)
            _t=${_at#aspa-up:}; _t=${_t%%=*}; _r=${_at#*=}
            aspa_table_exists "$_t" || err "kondisi aspa-up: tabel aspa $_t belum didefinisikan (aspa-table $_t)"
            case "$_r" in ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN) ;; *) err "kondisi aspa: hasil harus ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN: $_r" ;; esac
            printf 'aspa_check_upstream(%s) = %s' "$_t" "$_r"; return 0 ;;
        'call:'*)
            _c=${_at#call:}
            case "$_c" in *'('*) _fn=${_c%%'('*}; _args=${_c#*'('}; _args=${_args%')'} ;;
                *) _fn="$_c"; _args="" ;;
            esac
            function_exists "$_fn" || err "kondisi call: fungsi $_fn tidak didefinisikan (function $_fn)"
            _want=$(function_params "$_fn")
            _nwant=0; [ -n "$_want" ] && _nwant=$(printf '%s' "$_want" | wc -w)
            _narg=0; [ -n "$_args" ] && _narg=$(printf '%s' "$_args" | awk -F, '{print NF}')
            if [ "$_narg" -ne "$_nwant" ]; then err "kondisi call: $_fn butuh $_nwant argumen, diberi $_narg"; fi
            printf '%s(%s)' "$_fn" "$_args"; return 0 ;;
        *'!~path')  # B16/5-95 (WAJIB sebelum ~path — "ASN!~path" juga cocok pola *~path)
            _a=${_at%'!~path'}
            valid_asn "$_a" "kondisi ASN!~path"
            printf '%s !~ bgp_path' "$_a"; return 0 ;;
        *'~path')
            _a=${_at%'~path'}
            valid_asn "$_a" "kondisi ASN~path"
            printf '%s ~ bgp_path' "$_a"; return 0 ;;
        *'!~'*|*'~'*)  # B16/5-95/96/97: bentuk umum ~ / !~ (yang spesifik sudah ditangani di atas)
            case "$_at" in
                *'!~'*) _gl=${_at%%'!~'*}; _gr=${_at##*'!~'}; _go='!~' ;;
                *) _gl=${_at%%'~'*}; _gr=${_at##*'~'}; _go='~' ;;
            esac
            _gb=$(generic_match_bird "$_gl" "$_gr" "$_go" "$_vl") || exit 33
            printf '%s' "$_gb"; return 0 ;;
    esac
    # Perbandingan ATTR<op>VAL — coba operator terpanjang dulu.
    for _op in '!=' '<=' '>=' '=' '<' '>'; do
        case "$_at" in *"$_op"*)
            _lhs=${_at%%"$_op"*}; _rhs=${_at#*"$_op"}
            [ -n "$_lhs" ] && [ -n "$_rhs" ] || continue
            case "$_lhs" in *.mask\([0-9]*\))
                _mbase=${_lhs%%.mask\(*}; _mnum=${_lhs##*.mask\(}; _mnum=${_mnum%\)}
                case "$_mbase" in net.ip|bgp_next_hop|gw|from) ;;
                    *) err "kondisi mask: .mask() hanya untuk net.ip|bgp_next_hop|gw|from: $_at" ;;
                esac
                case "$_mnum" in ''|*[!0-9]*) err "kondisi mask: N harus bilangan 0..128: $_at" ;; esac
                [ "$_mnum" -le 128 ] 2>/dev/null || err "kondisi mask: N harus 0..128: $_at"
                valid_ip_any "$_rhs" "kondisi $_lhs"
                printf '%s.mask(%s) %s %s' "$_mbase" "$_mnum" "$_op" "$_rhs"; return 0 ;;
            esac
            case "$_lhs" in filter"("*")".min|filter"("*")".max)
                _fm=$(filter_minmax_bird "$_lhs" "kondisi $_lhs") || exit 33
                _fobj=${_lhs#filter(}; _fobj=${_fobj%%,*}
                case "$_fobj" in
                    bgp_community) valid_attr_value bgp_community.min "$_rhs" "kondisi $_lhs" ;;
                    bgp_ext_community) valid_attr_value bgp_ext_community.min "$_rhs" "kondisi $_lhs" ;;
                    bgp_large_community) valid_attr_value bgp_large_community.min "$_rhs" "kondisi $_lhs" ;;
                esac
                printf '%s %s %s' "$_fm" "$_op" "$_rhs"; return 0 ;;
            esac
            _k=$(attr_kind "$_lhs")
            if [ "$_k" != "unknown" ]; then
                case "$_k" in
                    int) valid_int_expr "$_rhs" "$_vl" "kondisi $_lhs" ;;
                    prefix) _rhs=$(prefix_value_to_bird "$_lhs" "$_rhs" "kondisi $_lhs") || exit 33 ;;
                    *) valid_attr_value "$_lhs" "$_rhs" "kondisi $_lhs" "$_vl" ;;
                esac
                case "$_k" in pair) _rhs="( $(echo "$_rhs" | sed 's/^(\(.*\))$/\1/; s/,/, /') )" ;; string) _rhs="\"$_rhs\"" ;; esac
                printf '%s %s %s' "$_lhs" "$_op" "$_rhs"; return 0
            fi
            # B16/5-46..50: accessor .asn/.data/.data1/.data2 (hasil int)
            case "$_lhs" in *.asn|*.data|*.data1|*.data2)
                _acc=$(accessor_bird "$_lhs" "$_vl") || err "kondisi: accessor tidak dikenal: $_lhs (harus variabel pair/lc, literal pair/lc, atau bgp_community/bgp_large_community .min/.max)"
                valid_int_expr "$_rhs" "$_vl" "kondisi $_lhs"
                printf '%s %s %s' "$_acc" "$_op" "$_rhs"; return 0 ;;
            esac
            _vt=$(var_type "$_vl" "$_lhs") || {
                # B12/5-90/91: LHS ekspresi aritmetika (mis. bgp_path.len+1>2);
                # validasi di subshell agar err() tidak mematikan proses.
                if (valid_int_expr "$_lhs" "$_vl" "kondisi $_lhs" 2>/dev/null) && (valid_int_expr "$_rhs" "$_vl" "kondisi $_rhs" 2>/dev/null); then
                    printf '%s %s %s' "$_lhs" "$_op" "$_rhs"; return 0
                fi
                continue
            }
            case "$_vt" in
                int) valid_int_expr "$_rhs" "$_vl" "kondisi variabel $_lhs" ;;
                bool) case "$_rhs" in true|false) ;; *) err "kondisi variabel bool $_lhs harus true|false: $_rhs" ;; esac ;;
                string) valid_nospace "$_rhs" "kondisi variabel string $_lhs"; _rvt=$(var_type "$_vl" "$_rhs" 2>/dev/null || true); [ "$_rvt" = "string" ] || _rhs="\"$_rhs\"" ;;
                *) err "kondisi: variabel $_lhs (tipe $_vt) tidak bisa dibandingkan langsung — hanya int/bool/string" ;;
            esac
            printf '%s %s %s' "$_lhs" "$_op" "$_rhs"; return 0
            ;;
        esac
    done
    err "kondisi tidak dikenal: $_at (lihat format COND di header B5)"
}

# --- B16: accessor .asn/.data/.data1/.data2 (Bab 5.2, 5-46..50) ---
# accessor_bird <EKSPRESI> <VARLIST> -> cetak ekspresi BIRD (int) atau
# return 1 TANPA err — pemanggil yang memutuskan pesannya, agar bisa dipakai
# di valid_int_atom tanpa mematikan proses.
accessor_bird() {
    _ae="$1"; _avl="$2"
    case "$_ae" in
        *.asn) _abase=${_ae%.asn}; _apart=asn ;;
        *.data1) _abase=${_ae%.data1}; _apart=data1 ;;
        *.data2) _abase=${_ae%.data2}; _apart=data2 ;;
        *.data) _abase=${_ae%.data}; _apart=data ;;
        *) return 1 ;;
    esac
    # basis: variabel pair/lc yang dideklarasikan
    _abt=$(var_type "$_avl" "$_abase" 2>/dev/null || true)
    case "$_abt:$_apart" in
        pair:asn|pair:data|lc:asn|lc:data1|lc:data2) printf '%s' "$_ae"; return 0 ;;
        pair:data1|pair:data2|lc:data) return 1 ;;
    esac
    # basis: atribut min/max clist/lclist (bentuk tetap; sudah ada di attr_kind
    # untuk bgp_community/bgp_large_community — ditangani di sana dulu; ini
    # penangkap bila attr_kind dilewati)
    case "$_abase:$_apart" in
        bgp_community.min:asn|bgp_community.min:data|bgp_community.max:asn|bgp_community.max:data|bgp_large_community.min:asn|bgp_large_community.min:data1|bgp_large_community.min:data2|bgp_large_community.max:asn|bgp_large_community.max:data1|bgp_large_community.max:data2)
            printf '%s' "$_ae"; return 0 ;;
    esac
    # basis: literal pair/lc — (65000,100).asn, (65000,100,200).data1
    case "$_abase" in '('*')')
        case "$_apart" in
            asn|data)
                (valid_pair "$_abase" "accessor $_ae" 2>/dev/null) || return 1
                printf '%s.%s' "$_abase" "$_apart"; return 0 ;;
            data1|data2)
                (valid_lc "$_abase" "accessor $_ae" 2>/dev/null) || return 1
                printf '%s.%s' "$_abase" "$_apart"; return 0 ;;
        esac ;;
    esac
    return 1
}

# valid_shell_pattern <POLA> <label> — pola shell Bab 5.3 (5-96): tanpa
# spasi / ';' / kutip ganda (klish: COND satu token; spasi memecah token).
valid_shell_pattern() {
    case "$1" in
        ''|*' '*|*';'*|*'"'*) err "$2 pola shell tidak boleh kosong/mengandung spasi, ';', atau kutip ganda: $1" ;;
    esac
}

# generic_match_bird <LHS> <RHS> <OP ~|!~> <VARLIST> -> ekspresi BIRD.
# B16/5-96/97: LHS bertipe string (proto/ifname/variabel-string/literal
# string berkutip) vs pola shell, atau bertipe ip (from/gw/bgp_next_hop/
# net.ip/variabel-ip/literal IP) vs prefix. Bentuk spesifik (net~/path~/
# community~/ext-community~/large-community~/src~/dst~/~set:/~path)
# ditangani SEBELUM pemanggilan ini — yang sampai sini hanya bentuk umum.
generic_match_bird() {
    _gl="$1"; _gr="$2"; _go="$3"; _gvl="$4"
    [ -n "$_gl" ] && [ -n "$_gr" ] || err "kondisi $_go butuh LHS$_go RHS: $_gl$_go$_gr"
    # LHS atribut ip -> RHS harus prefix (5-97)
    case "$_gl" in
        from|gw|bgp_next_hop|net.ip)
            valid_prefix_any "$_gr" "kondisi $_gl$_go prefix"
            printf '%s %s %s' "$_gl" "$_go" "$_gr"; return 0 ;;
        proto|ifname)
            _grt=$(var_type "$_gvl" "$_gr" 2>/dev/null || true)
            if [ "$_grt" = "string" ]; then printf '%s %s %s' "$_gl" "$_go" "$_gr"; return 0; fi
            case "$_gr" in '"'*'"') _gr=${_gr#\"}; _gr=${_gr%\"} ;; esac
            valid_shell_pattern "$_gr" "kondisi $_gl$_go pola"
            printf '%s %s "%s"' "$_gl" "$_go" "$_gr"; return 0 ;;
    esac
    # LHS variabel -> ikut tipenya
    _gt=$(var_type "$_gvl" "$_gl" 2>/dev/null || true)
    case "$_gt" in
        ip)
            valid_prefix_any "$_gr" "kondisi $_gl$_go prefix"
            printf '%s %s %s' "$_gl" "$_go" "$_gr"; return 0 ;;
        string)
            _grt=$(var_type "$_gvl" "$_gr" 2>/dev/null || true)
            if [ "$_grt" = "string" ]; then printf '%s %s %s' "$_gl" "$_go" "$_gr"; return 0; fi
            case "$_gr" in '"'*'"') _gr=${_gr#\"}; _gr=${_gr%\"} ;; esac
            valid_shell_pattern "$_gr" "kondisi $_gl$_go pola"
            printf '%s %s "%s"' "$_gl" "$_go" "$_gr"; return 0 ;;
    esac
    # LHS literal IP (5-97: 127.0.0.5 ~ 127.0.0.0/8)
    if (valid_ip_any "$_gl" "kondisi" 2>/dev/null); then
        valid_prefix_any "$_gr" "kondisi $_gl$_go prefix"
        printf '%s %s %s' "$_gl" "$_go" "$_gr"; return 0
    fi
    # LHS literal string berkutip (5-96: "eth0" ~ "eth*") — backend langsung;
    # via klish kutip dimakan tokenizer, pakai atribut/variabel string saja.
    case "$_gl" in '"'*'"')
        _gs=${_gl#\"}; _gs=${_gs%\"}
        case "$_gs" in ''|*'"'*) err "kondisi string: literal tidak boleh kosong/mengandung kutip ganda: $_gl" ;; esac
        _grt=$(var_type "$_gvl" "$_gr" 2>/dev/null || true)
        if [ "$_grt" = "string" ]; then printf '%s %s %s' "$_gl" "$_go" "$_gr"; return 0; fi
        case "$_gr" in '"'*'"') _gr=${_gr#\"}; _gr=${_gr%\"} ;; esac
        valid_shell_pattern "$_gr" "kondisi $_gl$_go pola"
        printf '%s %s "%s"' "$_gl" "$_go" "$_gr"; return 0 ;;
    esac
    err "kondisi $_go tidak dikenal: LHS $_gl harus atribut ip/string (from|gw|bgp_next_hop|net.ip|proto|ifname), variabel ip/string, literal IP, atau string berkutip: $_gl$_go$_gr"
}

# --- B16: print/printn (Bab 5.6, 5-157/158) ---
# print_arg_to_bird <ARG> <VARLIST> -> satu ekspresi BIRD.
# Bentuk ARG (satu token, tanpa spasi):
#   s:TEKS      string literal (bentuk klish; TEKS tanpa spasi/;/koma/kutip)
#   "TEKS"      string literal (backend langsung; via klish kutip dimakan)
#   true|false  bool · bilangan/hex · atribut route · variabel terdeklarasi
#   X.asn|X.data|X.data1|X.data2   accessor pair/lc (5-46..50)
#   (A,B)|(A,B,C)   literal pair/lc
print_arg_to_bird() {
    _pe="$1"; _pvl="$2"
    case "$_pe" in
        's:'*)
            _st=${_pe#s:}
            case "$_st" in ''|*'"'*|*';'*|*','*|*' '*) err "print: string s:TEKS tidak boleh kosong/mengandung kutip, ';', koma, atau spasi: $_pe" ;; esac
            printf '"%s"' "$_st"; return 0 ;;
        '"'*'"')
            _st=${_pe#\"}; _st=${_st%\"}
            case "$_st" in ''|*'"'*) err "print: string tidak boleh kosong/mengandung kutip ganda: $_pe" ;; esac
            printf '"%s"' "$_st"; return 0 ;;
        true|false) printf '%s' "$_pe"; return 0 ;;
        '('*')')
            (valid_pair "$_pe" "print" 2>/dev/null) && { printf '%s' "$_pe"; return 0; }
            (valid_lc "$_pe" "print" 2>/dev/null) && { printf '%s' "$_pe"; return 0; }
            err "print: literal pair/lc tidak valid: $_pe" ;;
    esac
    case "$_pe" in *.asn|*.data|*.data1|*.data2)
        _ab=$(accessor_bird "$_pe" "$_pvl") || err "print: accessor tidak dikenal: $_pe"
        printf '%s' "$_ab"; return 0 ;;
    esac
    case "$_pe" in ''|*[!0-9]*) ;; *) (valid_u32 "$_pe" "print" 2>/dev/null) && { printf '%s' "$_pe"; return 0; } ;; esac
    case "$_pe" in 0x*) case "$_pe" in 0x*[!0-9a-fA-F]*) ;; *) printf '%s' "$_pe"; return 0 ;; esac ;; esac
    _pt=$(var_type "$_pvl" "$_pe" 2>/dev/null || true)
    [ -n "$_pt" ] && { printf '%s' "$_pe"; return 0; }
    [ "$(attr_kind "$_pe")" != "unknown" ] && { printf '%s' "$_pe"; return 0; }
    err "print: argumen tidak dikenal (harus s:TEKS, \"TEKS\", atribut, variabel, bilangan, accessor .asn/.data, atau literal pair/lc): $_pe"
}

# print_args_to_bird <ARGS-koma> <VARLIST> -> "ekspr, ekspr, ..." (BIRD).
# Pisah koma yang peka-kurung (literal pair/lc mengandung koma).
print_args_to_bird() {
    _pa="$1"; _pvl="$2"
    [ -n "$_pa" ] || err "print butuh minimal satu argumen"
    case "$_pa" in *';'*) err "print: argumen tidak boleh mengandung ';': $_pa" ;; esac
    _pout=""; _cur=""; _depth=0; _rest="$_pa"
    while [ -n "$_rest" ]; do
        _ch=${_rest%"${_rest#?}"}
        _rest=${_rest#?}
        case "$_ch" in
            '(') _depth=$((_depth + 1)); _cur="$_cur$_ch" ;;
            ')') _depth=$((_depth - 1)); [ "$_depth" -ge 0 ] || err "print: kurung tutup tanpa buka: $_pa"; _cur="$_cur$_ch" ;;
            ',')
                if [ "$_depth" -eq 0 ]; then
                    [ -n "$_cur" ] || err "print: argumen kosong (koma ganda/akhir): $_pa"
                    _pb=$(print_arg_to_bird "$_cur" "$_pvl") || exit 33
                    if [ -z "$_pout" ]; then _pout="$_pb"; else _pout="$_pout, $_pb"; fi
                    _cur=""
                else
                    _cur="$_cur$_ch"
                fi ;;
            *) _cur="$_cur$_ch" ;;
        esac
    done
    [ "$_depth" -eq 0 ] || err "print: kurung tidak seimbang: $_pa"
    [ -n "$_cur" ] || err "print: argumen kosong (koma di akhir): $_pa"
    _pb=$(print_arg_to_bird "$_cur" "$_pvl") || exit 33
    if [ -z "$_pout" ]; then _pout="$_pb"; else _pout="$_pout, $_pb"; fi
    printf '%s' "$_pout"
}

# cond_to_bird <COND> <VARLIST> -> cetak ekspresi BIRD (atom diparentesis).
# B12: klish meng-escape karakter shell-special di PARAM saat substitusi ACTION
# (">" -> "\>", "&&" -> "\&\&", "(" -> "\(", ";" -> "\;"). Backend menerima
# bentuk ber-escape itu; unescape "\X" -> "X" untuk X shell-special.
# Backslash ganda ("\\") adalah backslash literal -> jadi satu backslash.
# Urutan: escape satu-karakter dulu, "\\" -> "\" terakhir.
klish_unescape() {
    printf '%s' "$1" | sed -e 's/\\!/!/g' -e 's/\\>/>/g' -e 's/\\</</g' -e 's/\\(/(/g' -e 's/\\)/)/g' -e 's/\\&/\&/g' -e 's/\\|/|/g' -e 's/\\;/;/g' -e 's/\\\\/\\/g'
}
cond_to_bird() {
    _c="$1"; _vl="$2"
    # B12: klish meng-escape karakter shell-special di PARAM saat substitusi
    # ACTION (">" -> "\>", "&&" -> "\&\&", "(" -> "\("). B16: klish juga
    # meng-escape "!" ("!" -> "\!") — tanpa ini COND `!~` gagal di klish
    # (backend terima `net\!~...`, LHS jadi `net\`). COND tidak pernah
    # mengandung backslash yang sah — buang semua backslash di awal.
    _c=$(klish_unescape "$_c")
    case "$_c" in
        *'&&'*'|'*|*'|'*'&&'*) err "kondisi campuran && dan || tidak didukung (presedensi tidak ada di docs Bab 5, A3): $_c" ;;
    esac
    _sep=""; _rest="$_c"; _out=""
    case "$_c" in *'&&'*) _sep='&&' ;; *'||'*) _sep='||' ;; esac
    if [ -n "$_sep" ]; then
        while [ -n "$_rest" ]; do
            case "$_rest" in
                *"$_sep"*) _atom=${_rest%%"$_sep"*}; _rest=${_rest#*"$_sep"} ;;
                *) _atom="$_rest"; _rest="" ;;
            esac
            _b=$(atom_to_bird "$_atom" "$_vl") || exit 33
            if [ -z "$_out" ]; then _out="($_b)"; else _out="$_out $_sep ($_b)"; fi
        done
    else
        _b=$(atom_to_bird "$_c" "$_vl") || exit 33
        _out="$_b"
    fi
    printf '%s' "$_out"
}

# stmt_to_bird <STMT> <VARLIST> -> cetak satu statement BIRD (tanpa indent).
stmt_to_bird() {
    case "$1" in
        accept|reject) printf '%s' "$1"; return 0 ;;
        'accept "'*'"'|'reject "'*'"')  # B12/5-159: accept/reject berpesan (5.6 contoh not_too_far); pesan satu token shell, spasi di dalam kutip
            _smact=${1%% *}
            _smmsg=${1#*\"}; _smmsg=${_smmsg%\"}
            case "$_smmsg" in ''|*'"'*) err "statement pesan tidak boleh kosong/mengandung kutip ganda: $1" ;; esac
            case "$_smmsg" in *' else '*) err "statement pesan tidak boleh mengandung ' else ' (pemecah baris if): $1" ;; esac
            printf '%s "%s"' "$_smact" "$_smmsg"; return 0 ;;
        'set:'*) _s=${1#set:}; _a=${_s%%=*}; _v=${_s#*=}
            [ -n "$_a" ] && [ -n "$_v" ] || err "statement set: butuh set:ATTR=NILAI: $1"
            valid_set_stmt "$_a" "$_v" "statement set" "$2"
            _sat=$(var_type "$2" "$_a" 2>/dev/null || true)
            if [ "$_sat" = "string" ]; then _svt=$(var_type "$2" "$_v" 2>/dev/null || true); [ "$_svt" = "string" ] || _v="\"$_v\""; fi
            printf '%s = %s' "$_a" "$_v"; return 0 ;;
        'unset:'*) _a=${1#unset:}
            valid_unset_attr "$_a" "statement unset"
            printf 'unset(%s)' "$_a"; return 0 ;;
        'method:'*) _m=${1#method:}
            _mb=$(method_to_bird "$_m" "$2") || exit 33
            printf '%s' "$_mb"; return 0 ;;
        'print:'*|'printn:'*)  # B16/5-157/158
            _pk=${1%%:*}; _pa=${1#*:}
            _pb=$(print_args_to_bird "$_pa" "$2") || exit 33
            printf '%s %s' "$_pk" "$_pb"; return 0 ;;
        *) err "statement tidak dikenal: $1 (accept|reject|accept \"PESAN\"|reject \"PESAN\"|set:ATTR=NILAI|unset:ATTR|method:OBJ.METHOD(args)|print:ARGS|printn:ARGS)" ;;
    esac
}

# valid_for <TIPE> <VAR> <SUMBER> <VARLIST> — pasangan tipe/sumber Bab 5.4.
valid_for() {
    _t="$1"; _v="$2"; _s="$3"
    valid_name "$_v" "variabel for"
    case "$_t:$_s" in
        int:bgp_path|pair:bgp_community|ec:bgp_ext_community|lc:bgp_large_community|quad:bgp_cluster_list) ;;
        *) err "for atas tipe salah: for $_t $_v in $_s (pasangan valid: int:bgp_path | pair:bgp_community | ec:bgp_ext_community | lc:bgp_large_community | quad:bgp_cluster_list)" ;;
    esac
}
# valid_case_expr <EKSPRESI> <VARLIST> -> cetak "<jenis>:<ekspresi-BIRD>".
# jenis: int | ORIGIN | ROA | ASPA. `net` (prefix) DITOLAK (A8/118).
valid_case_expr() {
    _e="$1"; _vl="$2"
    case "$_e" in
        net) err "case tidak bisa untuk prefix net (batasan docs Bab 5.4, A8) — pakai if berantai / case net.len" ;;
        net.len|bgp_path.len|bgp_community.len|bgp_local_pref|bgp_med)
            printf 'int:%s' "$_e"; return 0 ;;
        bgp_origin) printf 'ORIGIN:bgp_origin'; return 0 ;;
        'roa-check:'*) _t=${_e#roa-check:}
            roa_table_exists "$_t" || err "case roa-check: tabel roa $_t belum didefinisikan (roa-table $_t)"
            printf 'ROA:roa_check(%s)' "$_t"; return 0 ;;
        'aspa-up:'*) _t=${_e#aspa-up:}
            aspa_table_exists "$_t" || err "case aspa-up: tabel aspa $_t belum didefinisikan (aspa-table $_t)"
            printf 'ASPA:aspa_check_upstream(%s)' "$_t"; return 0 ;;
        'aspa-down:'*) _t=${_e#aspa-down:}
            aspa_table_exists "$_t" || err "case aspa-down: tabel aspa $_t belum didefinisikan (aspa-table $_t)"
            printf 'ASPA:aspa_check_downstream(%s)' "$_t"; return 0 ;;
        *)
            _vt=$(var_type "$_vl" "$_e") || err "case: ekspresi tidak dikenal: $_e (net.len|bgp_path.len|bgp_community.len|bgp_local_pref|bgp_med|bgp_origin|roa-check:TABEL|aspa-up:TABEL|aspa-down:TABEL|variabel-int)"
            [ "$_vt" = "int" ] || err "case: variabel $_e harus int (tipe $_vt)"
            printf 'int:%s' "$_e"; return 0 ;;
    esac
}
valid_case_label() { # valid_case_label <JENIS> <LABEL>
    case "$1" in
        int)
            case "$2" in *..*)
                _a=${2%%..*}; _b=${2#*..}
                valid_u32 "$_a" "label case"; valid_u32 "$_b" "label case"
                [ "$_a" -le "$_b" ] 2>/dev/null || err "label case range harus A<=B: $2" ;;
                *) valid_u32 "$2" "label case" ;;
            esac ;;
        ORIGIN) case "$2" in ORIGIN_IGP|ORIGIN_EGP|ORIGIN_INCOMPLETE) ;; *) err "label case bgp_origin harus ORIGIN_IGP|ORIGIN_EGP|ORIGIN_INCOMPLETE: $2" ;; esac ;;
        ROA) case "$2" in ROA_VALID|ROA_INVALID|ROA_UNKNOWN) ;; *) err "label case roa harus ROA_VALID|ROA_INVALID|ROA_UNKNOWN: $2" ;; esac ;;
        ASPA) case "$2" in ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN) ;; *) err "label case aspa harus ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN: $2" ;; esac ;;
    esac
}

# upsert_nbr <ip> <field> <baris-baru> — seperti upsert, tapi cocok juga
# baris bare (tanpa nilai, mis. `neighbor IP direct`) via pola `( |$)`.
# Dipakai field B1 yang bare / opsional nilainya.
upsert_nbr() {
    _nip="$1"; _fld="$2"; _line="$3"
    touch_conf
    _tmp="$CONF.tmp.$$"
    grep -v "^neighbor $_nip $_fld\( \|$\)" "$CONF" > "$_tmp" 2>/dev/null || true
    printf '%s\n' "$_line" >> "$_tmp"
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    chmod 600 "$CONF" 2>/dev/null || true
}

# has_nbr <ip> <field> — 0 bila baris field ada (bare atau bernilai)
has_nbr() {
    grep -q "^neighbor $1 $2\( \|$\)" "$CONF" 2>/dev/null
}

# --- B6: channel BGP non-ipv4 (Bab 6.4 Tabel 2) ---
# KEY klish (satu token) -> nama channel BIRD:
#   ipv6=ipv6 · mc4=ipv4 multicast · mc6=ipv6 multicast ·
#   mpls4=ipv4 mpls · mpls6=ipv6 mpls · vpn4=vpn4 mpls · vpn6=vpn6 mpls ·
#   vpn4mc=vpn4 multicast · vpn6mc=vpn6 multicast · flow4/flow6
chan_bird_name() { # <KEY> -> nama channel BIRD
    case "$1" in
        ipv6) echo "ipv6" ;;
        mc4) echo "ipv4 multicast" ;;
        mc6) echo "ipv6 multicast" ;;
        mpls4) echo "ipv4 mpls" ;;
        mpls6) echo "ipv6 mpls" ;;
        vpn4) echo "vpn4 mpls" ;;
        vpn6) echo "vpn6 mpls" ;;
        vpn4mc) echo "vpn4 multicast" ;;
        vpn6mc) echo "vpn6 multicast" ;;
        flow4) echo "flow4" ;;
        flow6) echo "flow6" ;;
        *) err "channel KEY tidak dikenal: $1" ;;
    esac
}
chan_family() { # <KEY> -> v4|v6 (keluarga alamat channel)
    case "$1" in ipv6|mc6|mpls6|vpn6|vpn6mc|flow6) echo v6 ;; *) echo v4 ;; esac
}
chan_has() { # <IP> <KEY> -> true bila ada field channel itu di intent
    grep -q "^neighbor $1 $2-" "$CONF" 2>/dev/null
}
_chan_set() { # _chan_set <IP> <KEY> <FIELD> [VALUE...] — validasi + upsert field channel B6
    _cip="$1"; _ck="$2"; _cf="$3"; shift 3
    case "$_cf" in
        import|export)
            [ -n "$1" ] || err "$_ck-$_cf butuh all|none|filter <nama>|where <ekspresi>"
            case "$1" in
                all|none) upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
                filter) [ -n "$2" ] || err "$_ck-$_cf filter butuh nama filter"
                    valid_symbol "$2" "$_ck-$_cf filter"
                    upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf filter $2" ;;
                where)
                    shift
                    [ -n "$*" ] || err "$_ck-$_cf where butuh ekspresi filter bentuk ringkas (mis. where net~10.0.0.0/8)"
                    cond_to_bird "$*" "" >/dev/null || exit 33
                    upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf where $*" ;;
                *) err "$_ck-$_cf harus all|none|filter <nama>|where <ekspresi>: $1" ;;
            esac ;;
        table|igp-table|igp-table6)
            [ -n "$1" ] || err "$_ck-$_cf butuh nama tabel"
            valid_symbol "$1" "$_ck-$_cf"
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        base-table)
            case "$_ck" in flow4|flow6) ;; *) err "$_ck-base-table hanya untuk channel flowspec (flow4/flow6)" ;; esac
            [ -n "$1" ] || err "$_ck-base-table butuh nama tabel"
            valid_symbol "$1" "$_ck-base-table"
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        preference)
            [ -n "$1" ] || err "$_ck-preference butuh angka 0..65535"
            valid_u32 "$1" "$_ck-preference"
            [ "$1" -le 65535 ] 2>/dev/null || err "$_ck-preference harus 0..65535: $1"
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        import-keep-filtered|rpki-reload|mandatory|secondary|import-table|export-table|extended-next-hop|require-extended-next-hop|require-add-paths)
            [ -n "$1" ] || err "$_ck-$_cf butuh on|off"
            valid_onoff "$1" "$_ck-$_cf"
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        validate)
            case "$_ck" in flow4|flow6) ;; *) err "$_ck-validate hanya untuk channel flowspec (flow4/flow6)" ;; esac
            [ -n "$1" ] || err "$_ck-validate butuh on|off"
            valid_onoff "$1" "$_ck-validate"
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        import-limit|receive-limit|export-limit)
            [ -n "$1" ] || err "$_ck-$_cf butuh angka atau off"
            case "$1" in off) ;; *) valid_uint "$1" "$_ck-$_cf" ;; esac
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        import-limit-action|receive-limit-action|export-limit-action)
            [ -n "$1" ] || err "$_ck-$_cf butuh warn|block|restart|disable"
            case "$1" in warn|block|restart|disable) ;; *) err "$_ck-$_cf harus warn|block|restart|disable: $1" ;; esac
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        next-hop-self|next-hop-keep)
            [ -n "$1" ] || err "$_ck-$_cf butuh on|off|ibgp|ebgp"
            case "$1" in on|off|ibgp|ebgp) ;; *) err "$_ck-$_cf harus on|off|ibgp|ebgp: $1" ;; esac
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        next-hop-address)
            [ -n "$1" ] || err "$_ck-next-hop-address butuh alamat IP"
            if [ "$(chan_family "$_ck")" = "v6" ]; then valid_ipv6 "$1" "$_ck-next-hop-address"; else valid_ipv4 "$1" "$_ck-next-hop-address"; fi
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        next-hop-prefer-global)
            case "$_ck" in ipv6|mc6|mpls6|vpn6|vpn6mc) ;; *) err "$_ck-next-hop-prefer-global hanya untuk channel keluarga IPv6 (ipv6|mc6|mpls6|vpn6|vpn6mc)" ;; esac
            [ -n "$1" ] || err "$_ck-next-hop-prefer-global butuh on|off"
            valid_onoff "$1" "$_ck-next-hop-prefer-global"
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        gateway)
            [ -n "$1" ] || err "$_ck-gateway butuh direct|recursive"
            case "$1" in direct|recursive) ;; *) err "$_ck-gateway harus direct|recursive: $1" ;; esac
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        add-paths)
            [ -n "$1" ] || err "$_ck-add-paths butuh on|off|rx|tx"
            case "$1" in on|off|rx|tx) ;; *) err "$_ck-add-paths harus on|off|rx|tx: $1" ;; esac
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        aigp)
            [ -n "$1" ] || err "$_ck-aigp butuh on|off|originate"
            case "$1" in on|off|originate) ;; *) err "$_ck-aigp harus on|off|originate: $1" ;; esac
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        graceful-restart|llgr)
            [ -n "$1" ] || err "$_ck-$_cf butuh off|aware|on"
            case "$1" in off|aware|on) ;; *) err "$_ck-$_cf harus off|aware|on: $1" ;; esac
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        cost|llgr-stale-time)
            [ -n "$1" ] || err "$_ck-$_cf butuh angka"
            valid_uint "$1" "$_ck-$_cf"
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        debug)
            [ -n "$1" ] || err "$_ck-debug butuh all|off|states,routes,filters"
            case "$1" in all|off) ;; *)
                _drest="$1"
                while [ -n "$_drest" ]; do
                    case "$_drest" in *,*) _done=${_drest%%,*}; _drest=${_drest#*,} ;; *) _done="$_drest"; _drest="" ;; esac
                    case "$_done" in states|routes|filters) ;; *) err "$_ck-debug kelas tidak dikenal: $_done (boleh: states|routes|filters)" ;; esac
                done ;;
            esac
            upsert "^neighbor $_cip $_ck-$_cf " "neighbor $_cip $_ck-$_cf $1" ;;
        *) err "field channel $_ck tidak dikenal: $_cf" ;;
    esac
}

cmd_set_router_id() {
    [ -n "$1" ] || err "router-id butuh alamat IP"
    upsert '^router-id ' "router-id $1"
    echo "BIRD router-id set to $1"
}

cmd_set_local_as() {
    [ -n "$1" ] || err "local-as butuh nomor AS"
    valid_asn "$1" "local-as"
    upsert '^local-as ' "local-as $1"
    echo "BIRD local-as set to $1"
}

cmd_neighbor_add() {
    # neighbor-add <IP> <remote-as>
    _ip="$1"; _as="$2"
    [ -n "$_ip" ] && [ -n "$_as" ] || err "neighbor butuh IP + remote-as"
    valid_ip_any "$_ip" "neighbor"
    valid_asn "$_as" "remote-as"
    upsert "^neighbor $_ip remote-as " "neighbor $_ip remote-as $_as"
    # default: import/export all bila belum ada
    grep -q "^neighbor $_ip import " "$CONF" 2>/dev/null || \
        printf 'neighbor %s import all\n' "$_ip" >> "$CONF"
    grep -q "^neighbor $_ip export " "$CONF" 2>/dev/null || \
        printf 'neighbor %s export all\n' "$_ip" >> "$CONF"
    echo "BGP neighbor $_ip remote-as $_as (import/export all)"
}

cmd_neighbor_touch() {
    # neighbor-touch <IP>: pastikan intent file ada; neighbor baru
    # dicatat saat `remote-as` diset. Tidak mengubah bgp.conf bila
    # neighbor belum punya remote-as.
    _ip="$1"
    [ -n "$_ip" ] || err "neighbor-touch butuh IP"
    touch_conf
    echo "BGP neighbor $_ip"
}

cmd_neighbor_del() {
    _ip="$1"
    [ -n "$_ip" ] || err "neighbor-del butuh IP"
    dellines "^neighbor $_ip "
    echo "BGP neighbor $_ip dihapus"
}

# --- neighbor-chan-set/unset (refactor persistensi, pola route-map FRR) ---
# Konteks channel view di-encode SATU var `bgp_ch_ctx` =
# `<NEIGHBOR>:<CHANNEL>`. Split pada `:` TERAKHIR — neighbor IPv6 boleh
# mengandung `:` (nama channel tidak). Delegasi ke cmd_neighbor_set /
# cmd_neighbor_unset dengan field `<CHANNEL>-<ATTR>` (logika B6 utuh).
split_chan_ctx() { # <NEIGHBOR:CHANNEL> -> _CX_NIP _CX_CH
    case "$1" in
        *:*)
            _CX_NIP="${1%:*}"   # hapus dari `:` TERAKHIR ke kanan
            _CX_CH="${1##*:}" ;; # ambil sesudah `:` TERAKHIR
        *) err "ctx channel BGP harus <NEIGHBOR>:<CHANNEL>: $1" ;;
    esac
    [ -n "$_CX_NIP" ] && [ -n "$_CX_CH" ] || err "ctx channel BGP tidak lengkap: $1"
}
cmd_neighbor_chan_set() { # neighbor-chan-set <NEIGHBOR:CHANNEL> <ATTR> <VALUE...>
    split_chan_ctx "$1"; _attr="$2"; shift 2
    [ -n "$_attr" ] || err "neighbor-chan-set butuh ATTR"
    cmd_neighbor_set "$_CX_NIP" "$_CX_CH-$_attr" "$@"
}
cmd_neighbor_chan_unset() { # neighbor-chan-unset <NEIGHBOR:CHANNEL> <ATTR>
    split_chan_ctx "$1"; _attr="$2"
    [ -n "$_attr" ] || err "neighbor-chan-unset butuh ATTR"
    cmd_neighbor_unset "$_CX_NIP" "$_CX_CH-$_attr"
}

cmd_neighbor_set() {
    # neighbor-set <IP> <field> [value...]
    # field lama: description|import|export|local-pref|med|prepend|community|bfd
    # field B1: lihat header file. Switch = on|off; bare = tanpa value;
    # multihop / allow-local-as = bare atau + angka.
    _ip="$1"; _f="$2"; shift 2
    [ -n "$_ip" ] && [ -n "$_f" ] || err "neighbor-set butuh IP field [value]"
    # --- B6: channel non-ipv4 (<KEY>-<FIELD>) — delegasi ke _chan_set ---
    case "$_f" in
        ipv6-*|mc4-*|mc6-*|mpls4-*|mpls6-*|vpn4-*|vpn6-*|vpn4mc-*|vpn6mc-*|flow4-*|flow6-*)
            _ck=${_f%%-*}; _cf=${_f#*-}
            _chan_set "$_ip" "$_ck" "$_cf" "$@"
            echo "BGP neighbor $_ip $_f = $*"
            return 0 ;;
    esac
    case "$_f" in
        description) [ -n "$1" ] || err "description butuh teks"
            upsert "^neighbor $_ip description " "neighbor $_ip description $*" ;;
        import|export)
            [ -n "$1" ] || err "import/export butuh all|none|filter <nama>|where <ekspresi>"
            case "$1" in
                all|none) upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
                filter) [ -n "$2" ] || err "import/export filter butuh nama filter"
                    upsert "^neighbor $_ip $_f " "neighbor $_ip $_f filter $2" ;;
                where)
                    shift
                    [ -n "$*" ] || err "import/export where butuh ekspresi filter bentuk ringkas (mis. where net~10.0.0.0/8)"
                    cond_to_bird "$*" "" >/dev/null || exit 33
                    upsert "^neighbor $_ip $_f " "neighbor $_ip $_f where $*" ;;
                *) err "import/export harus all|none|filter <nama>|where <ekspresi>: $1" ;;
            esac
            ;;
        local-pref|med|prepend)
            [ -n "$1" ] || err "$_f butuh angka"
            valid_u32 "$1" "$_f"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        community)
            [ -n "$1" ] || err "community butuh AS:NN"
            valid_community "$1" "community"
            upsert "^neighbor $_ip community " "neighbor $_ip community $1" ;;
        bfd)
            [ -n "$1" ] || err "bfd butuh on|graceful|off"
            case "$1" in
                on) upsert "^neighbor $_ip bfd " "neighbor $_ip bfd on" ;;
                graceful) upsert "^neighbor $_ip bfd " "neighbor $_ip bfd graceful" ;;
                off) dellines "^neighbor $_ip bfd " ;;
                *) err "bfd harus on|graceful|off: $1" ;;
            esac ;;
        # --- B1: bare (tanpa value) ---
        direct|rr-client|rs-client|disabled)
            upsert_nbr "$_ip" "$_f" "neighbor $_ip $_f" ;;
        # --- B1: switch on|off ---
        check-link|passive|strict-bind|free-bind|ttl-security|setkey|confederation-member|allow-local-pref|allow-med|allow-as-sets|enforce-first-as|enable-route-refresh|require-route-refresh|enable-enhanced-rr|require-enhanced-rr|require-graceful-restart|require-llgr|interpret-communities|enable-as4|require-as4|enable-extended-messages|require-extended-messages|capabilities|advertise-hostname|require-hostname|disable-after-error|path-metric|med-metric|deterministic-med|igp-metric|prefer-older|require-roles|import-table|export-table|secondary|validate|extended-next-hop|require-extended-next-hop|require-add-paths|channel-graceful-restart|channel-llgr|mandatory|import-keep-filtered)
            [ -n "$1" ] || err "$_f butuh on|off"
            valid_onoff "$1" "$_f"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        # --- B5: preference channel (Bab 3.5-3; beda dari bgp_local_pref) ---
        channel-preference)
            [ -n "$1" ] || err "channel-preference butuh angka 0..65535"
            valid_u32 "$1" "channel-preference"
            [ "$1" -le 65535 ] 2>/dev/null || err "channel-preference harus 0..65535: $1"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        # --- B1: multihop / allow-local-as (bare atau + angka) ---
        multihop)
            if [ -n "$1" ]; then
                valid_uint "$1" "multihop"
                [ "$1" -ge 1 ] 2>/dev/null || err "multihop harus 1..255 (0 tidak valid): $1"
                [ "$1" -le 255 ] 2>/dev/null || err "multihop harus 1..255: $1"
                upsert_nbr "$_ip" "$_f" "neighbor $_ip multihop $1"
            else
                upsert_nbr "$_ip" "$_f" "neighbor $_ip multihop"
            fi ;;
        allow-local-as)
            if [ -n "$1" ]; then
                valid_uint "$1" "allow-local-as"
                upsert_nbr "$_ip" "$_f" "neighbor $_ip allow-local-as $1"
            else
                upsert_nbr "$_ip" "$_f" "neighbor $_ip allow-local-as"
            fi ;;
        # --- B1: nilai IPv4 ---
        local-ip|source-address|next-hop-address|export-next-hop|rr-cluster-id)
            [ -n "$1" ] || err "$_f butuh alamat IP"
            valid_ipv4 "$1" "$_f"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        # --- B1: nilai angka ---
        port|local-port)
            [ -n "$1" ] || err "$_f butuh nomor port"
            valid_port "$1" "$_f"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        confederation)
            [ -n "$1" ] || err "confederation butuh nomor"
            valid_asn "$1" "confederation"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        hold-time|min-hold-time|startup-hold-time|keepalive-time|min-keepalive-time|send-hold-time|connect-delay-time|connect-retry-time|error-forget-time|graceful-restart-time|llgr-stale-time|channel-llgr-stale-time|cost)
            [ -n "$1" ] || err "$_f butuh angka (>= 0; hold-time 0 = tanpa keepalive, VALID)"
            valid_uint "$1" "$_f"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        default-med|default-local-pref)
            [ -n "$1" ] || err "$_f butuh angka"
            valid_u32 "$1" "$_f"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        error-wait-time)
            [ -n "$1" ] || err "error-wait-time butuh N,M (mis. 60,300)"
            case "$1" in *,*) ;; *) err "error-wait-time harus N,M: $1" ;; esac
            _ew1=${1%%,*}; _ew2=${1#*,}
            valid_uint "$_ew1" "error-wait-time (min)"
            valid_uint "$_ew2" "error-wait-time (max)"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        # --- B1: enum ---
        mode)
            [ -n "$1" ] || err "mode butuh internal|external"
            case "$1" in internal|external) ;; *) err "mode harus internal|external: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        next-hop-self|next-hop-keep)
            [ -n "$1" ] || err "$_f butuh on|off|ibgp|ebgp"
            case "$1" in on|off|ibgp|ebgp) ;; *) err "$_f harus on|off|ibgp|ebgp: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        gateway)
            [ -n "$1" ] || err "gateway butuh direct|recursive"
            case "$1" in direct|recursive) ;; *) err "gateway harus direct|recursive: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        add-paths)
            [ -n "$1" ] || err "add-paths butuh on|off|rx|tx"
            case "$1" in on|off|rx|tx) ;; *) err "add-paths harus on|off|rx|tx: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        aigp)
            [ -n "$1" ] || err "aigp butuh on|off|originate"
            case "$1" in on|off|originate) ;; *) err "aigp harus on|off|originate: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        graceful-restart|llgr)
            [ -n "$1" ] || err "$_f butuh off|aware|on"
            case "$1" in off|aware|on) ;; *) err "$_f harus off|aware|on: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        local-role)
            [ -n "$1" ] || err "local-role butuh provider|customer|peer|rs-server|rs-client"
            case "$1" in provider|customer|peer|rs-server|rs-client) ;; *) err "local-role harus provider|customer|peer|rs-server|rs-client: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        origin)
            [ -n "$1" ] || err "origin butuh igp|egp|incomplete"
            case "$1" in igp|egp|incomplete) ;; *) err "origin harus igp|egp|incomplete: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        # --- B1: nama / teks satu token ---
        interface|igp-table|igp-table6|base-table|channel-table)
            [ -n "$1" ] || err "$_f butuh nama"
            valid_name "$1" "$_f"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        password)
            [ -n "$1" ] || err "password butuh teks (tanpa spasi)"
            valid_nospace "$1" "password"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        # --- B1: limit channel (N|off) + aksi ---
        import-limit|receive-limit|export-limit)
            [ -n "$1" ] || err "$_f butuh angka atau off"
            case "$1" in off) ;; *) valid_uint "$1" "$_f" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        import-limit-action|receive-limit-action|export-limit-action)
            [ -n "$1" ] || err "$_f butuh warn|block|restart|disable"
            case "$1" in warn|block|restart|disable) ;; *) err "$_f harus warn|block|restart|disable: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        # --- B1: disable-after-cease (switch) + flags ---
        disable-after-cease)
            [ -n "$1" ] || err "disable-after-cease butuh on|off"
            valid_onoff "$1" "$_f"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        disable-after-cease-flags)
            [ -n "$1" ] || err "disable-after-cease-flags butuh daftar flag dipisah koma (mis. administrative-shutdown,peer-deconfigured)"
            _rest="$1"
            while [ -n "$_rest" ]; do
                case "$_rest" in *,*) _one=${_rest%%,*}; _rest=${_rest#*,} ;; *) _one="$_rest"; _rest="" ;; esac
                case "$_one" in cease|prefix-limit-hit|administrative-shutdown|peer-deconfigured|administrative-reset|connection-rejected|configuration-change|connection-collision|out-of-resources) ;; *) err "disable-after-cease flag tidak dikenal: $_one (cease|prefix-limit-hit|administrative-shutdown|peer-deconfigured|administrative-reset|connection-rejected|configuration-change|connection-collision|out-of-resources)" ;; esac
            done
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        # --- B1: community delete (export-inline) ---
        community-del)
            [ -n "$1" ] || err "community-del butuh AS:NN"
            valid_community "$1" "community-del"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        ext-community-del)
            [ -n "$1" ] || err "ext-community-del butuh rt:AA:NN atau ro:AA:NN"
            valid_ext_community "$1" "ext-community-del"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        large-community-del)
            [ -n "$1" ] || err "large-community-del butuh large:AA:X:NN"
            valid_large_community "$1" "large-community-del"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        # --- B6: opsi protocol-level (Bab 3.4) + from + mpls ---
        from)
            [ -n "$1" ] || err "from butuh nama template bgp"
            valid_symbol "$1" "from"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        protocol-router-id)
            [ -n "$1" ] || err "protocol-router-id butuh alamat IPv4"
            valid_ipv4 "$1" "protocol-router-id"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        debug)
            [ -n "$1" ] || err "debug butuh all|off|states,routes,filters,interfaces,events,packets"
            case "$1" in all|off) ;; *)
                _drest="$1"
                while [ -n "$_drest" ]; do
                    case "$_drest" in *,*) _done=${_drest%%,*}; _drest=${_drest#*,} ;; *) _done="$_drest"; _drest="" ;; esac
                    case "$_done" in states|routes|filters|interfaces|events|packets) ;; *) err "debug kelas tidak dikenal: $_done (boleh: states|routes|filters|interfaces|events|packets)" ;; esac
                done ;;
            esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        mrtdump)
            [ -n "$1" ] || err "mrtdump butuh all|off|states|messages"
            case "$1" in all|off) ;; *)
                _drest="$1"
                while [ -n "$_drest" ]; do
                    case "$_drest" in *,*) _done=${_drest%%,*}; _drest=${_drest#*,} ;; *) _done="$_drest"; _drest="" ;; esac
                    case "$_done" in states|messages) ;; *) err "mrtdump kelas tidak dikenal: $_done (boleh: states|messages)" ;; esac
                done ;;
            esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        tx-class|tx-dscp)
            # BIRD 2.20: tx class/dscp HANYA di blok interface (OSPF/RIP/Babel) —
            # bukan opsi protokol BGP (bird -p: "unexpected TX"). Ditolak tegas
            # agar intent tidak menyimpan nilai yang tidak pernah ter-emit.
            err "$_f tidak didukung di BGP BIRD 2.20 (tx class/dscp hanya di blok interface OSPF/RIP/Babel)" ;;
        mpls-domain|mpls-label-range)
            [ -n "$1" ] || err "$_f butuh nama"
            valid_symbol "$1" "$_f"
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        mpls-label-policy)
            [ -n "$1" ] || err "mpls-label-policy butuh static|prefix|aggregate|vrf"
            case "$1" in static|prefix|aggregate|vrf) ;; *) err "mpls-label-policy harus static|prefix|aggregate|vrf: $1" ;; esac
            upsert "^neighbor $_ip $_f " "neighbor $_ip $_f $1" ;;
        *) err "field neighbor tidak dikenal: $_f" ;;
    esac
    echo "BGP neighbor $_ip $_f = $*"
}

cmd_neighbor_unset() {
    # neighbor-unset <IP> <FIELD> — hapus baris intent (kembali ke
    # default BIRD). Untuk limit, hapus juga baris *-action-nya;
    # untuk disable-after-cease, hapus juga baris flags-nya.
    _ip="$1"; _f="$2"
    [ -n "$_ip" ] && [ -n "$_f" ] || err "neighbor-unset butuh IP FIELD"
    # --- B6: field channel (<KEY>-<FIELD>) ---
    case "$_f" in
        ipv6-*|mc4-*|mc6-*|mpls4-*|mpls6-*|vpn4-*|vpn6-*|vpn4mc-*|vpn6mc-*|flow4-*|flow6-*)
            _ck=${_f%%-*}; _cf=${_f#*-}
            case "$_cf" in
                import-limit|receive-limit|export-limit)
                    dellines "^neighbor $_ip $_f\( \|$\)"
                    dellines "^neighbor $_ip $_ck-$_cf-action " ;;
                *) dellines "^neighbor $_ip $_f\( \|$\)" ;;
            esac
            echo "BGP neighbor $_ip $_f dihapus (default BIRD)"
            return 0 ;;
    esac
    case "$_f" in
        import-limit) dellines "^neighbor $_ip import-limit\( \|$\)"; dellines "^neighbor $_ip import-limit-action " ;;
        receive-limit) dellines "^neighbor $_ip receive-limit\( \|$\)"; dellines "^neighbor $_ip receive-limit-action " ;;
        export-limit) dellines "^neighbor $_ip export-limit\( \|$\)"; dellines "^neighbor $_ip export-limit-action " ;;
        disable-after-cease) dellines "^neighbor $_ip disable-after-cease\( \|$\)"; dellines "^neighbor $_ip disable-after-cease-flags " ;;
        *) dellines "^neighbor $_ip $_f\( \|$\)" ;;
    esac
    echo "BGP neighbor $_ip $_f dihapus (default BIRD)"
}

cmd_channel_del() { # channel-del <IP> <KEY> — hapus SEMUA field channel itu
    _ip="$1"; _k="$2"
    [ -n "$_ip" ] && [ -n "$_k" ] || err "channel-del butuh IP + KEY (ipv6|mc4|mc6|mpls4|mpls6|vpn4|vpn6|vpn4mc|vpn6mc|flow4|flow6)"
    case "$_k" in ipv6|mc4|mc6|mpls4|mpls6|vpn4|vpn6|vpn4mc|vpn6mc|flow4|flow6) ;;
        *) err "channel KEY harus ipv6|mc4|mc6|mpls4|mpls6|vpn4|vpn6|vpn4mc|vpn6mc|flow4|flow6: $_k" ;;
    esac
    dellines "^neighbor $_ip $_k-"
    echo "BGP neighbor $_ip channel $_k dihapus"
}

cmd_neighbor_range_add() {
    # neighbor-range-add <PREFIX> — dynamic BGP template (bgp_dyn)
    _p="$1"
    [ -n "$_p" ] || err "neighbor-range butuh prefix (mis. 10.99.0.0/16)"
    valid_prefix "$_p" "neighbor-range"
    upsert "^neighbor-range $_p\$" "neighbor-range $_p"
    echo "BGP dynamic neighbor-range $_p ditambahkan (template bgp_dyn)"
}

cmd_neighbor_range_del() {
    _p="$1"
    [ -n "$_p" ] || err "neighbor-range-del butuh prefix"
    dellines "^neighbor-range $_p\$"
    echo "BGP dynamic neighbor-range $_p dihapus"
}

cmd_dynamic_name_set() {
    [ -n "$1" ] || err "dynamic-name butuh teks (tanpa spasi)"
    valid_nospace "$1" "dynamic-name"
    upsert '^dynamic-name ' "dynamic-name $1"
    echo "BGP dynamic-name set to $1"
}

cmd_dynamic_name_digits_set() {
    [ -n "$1" ] || err "dynamic-name-digits butuh angka"
    valid_uint "$1" "dynamic-name-digits"
    upsert '^dynamic-name-digits ' "dynamic-name-digits $1"
    echo "BGP dynamic-name-digits set to $1"
}

cmd_dynamic_name_del() {
    dellines '^dynamic-name '
    echo "BGP dynamic-name dihapus"
}

cmd_dynamic_name_digits_del() {
    dellines '^dynamic-name-digits '
    echo "BGP dynamic-name-digits dihapus"
}

cmd_attribute_bgp_add() {
    # attribute-bgp-add <NOMOR 1..255> <NAMA> — nomor yang sudah dikenal
    # BIRD ditolak (ORIGIN 1, AS_PATH 2, NEXT_HOP 3, MED 4, LOCAL_PREF 5,
    # ATOMIC_AGGR 6, AGGREGATOR 7, COMMUNITY 8, ORIGINATOR_ID 9,
    # CLUSTER_LIST 10, MP_REACH 14, MP_UNREACH 15, EXT_COMM 16,
    # AS4_PATH 17, AS4_AGGREGATOR 18, LARGE_COMMUNITY 22).
    _n="$1"; _name="$2"
    [ -n "$_n" ] && [ -n "$_name" ] || err "attribute-bgp butuh NOMOR + NAMA"
    valid_uint "$_n" "attribute-bgp nomor"
    [ "$_n" -ge 1 ] 2>/dev/null || err "attribute-bgp nomor harus 1..255: $_n"
    [ "$_n" -le 255 ] 2>/dev/null || err "attribute-bgp nomor harus 1..255: $_n"
    case "$_n" in 1|2|3|4|5|6|7|8|9|10|14|15|16|17|18|22) err "attribute-bgp nomor $_n sudah dikenal BIRD (tidak boleh didefinisikan ulang)" ;; esac
    valid_name "$_name" "attribute-bgp nama"
    upsert "^attribute-bgp $_n " "attribute-bgp $_n $_name"
    echo "BGP attribute bgp $_n bytestring $_name ditambahkan"
}

cmd_attribute_bgp_del() {
    _n="$1"
    [ -n "$_n" ] || err "attribute-bgp-del butuh NOMOR"
    dellines "^attribute-bgp $_n "
    echo "BGP attribute-bgp $_n dihapus"
}

cmd_network_add() {
    _p="$1"
    [ -n "$_p" ] || err "network butuh prefix (mis. 10.99.40.0/24)"
    case "$_p" in */*) ;; *) err "network harus prefix CIDR: $_p" ;; esac
    upsert "^network $_p\$" "network $_p"
    echo "BGP network $_p ditambahkan (diiklankan)"
}

cmd_network_del() {
    _p="$1"
    [ -n "$_p" ] || err "network-del butuh prefix"
    dellines "^network $_p\$"
    echo "BGP network $_p dihapus"
}

cmd_filter_add() {
    # filter-add <NAME> <accept|reject> <prefix|community AS:NN|SUB VALUE>
    # SUB (B1): as-path <AS[,AS...]> | origin <igp|egp|incomplete> |
    #   next-hop <IP> | originator-id <IP> | cluster-list <IP> | otc <N>
    # SUB (B5): prefix-len <OP> <N> | prefix-ip <IP> | ip-v4 | ip-v6 |
    #   ip-mask <IP> <N> | path-mask <e,e,...> | path-first|path-last <AS> |
    #   path-len <OP> <N> | community-len <OP> <N> |
    #   community-min|max <AS:NN> | local-pref|med <OP> <N> |
    #   defined|undefined <ATTR> | roa <TABEL> <ROA_*> |
    #   aspa-down|aspa-up <TABEL> <ASPA_*> | match <COND>
    # SUB (B12): roa3 <TABEL> <PREFIX|net> <ASN|bgp_path.last> <ROA_*> |
    #   aspa3 <TABEL> <bgp_path> <true|false|up|down> <ASPA_*>
    #   (prefix biasa boleh pola +|-|{low,high}, mis. 10.0.0.0/8{16,24})
    _n="$1"; _a="$2"; _v="$3"; _x="$4"; _y="$5"; _z="$6"; _w="$7"
    _b5_n="$_n"; _b5_a="$_a"; _b5_v="$_v"; _b5_x="$_x"; _b5_y="$_y"
    [ -n "$_n" ] && [ -n "$_a" ] && [ -n "$_v" ] || err "filter butuh NAMA accept|reject NILAI"
    valid_symbol "$_n" "filter"
    case "$_a" in
        accept|reject) ;;
        *) err "filter aksi harus accept|reject: $_a" ;;
    esac
    _vl=$(filter_vars "$_n")
    _b5_vl="$_vl"
    case "$_b5_v" in
        community)
            _c="$_b5_x"
            [ -n "$_c" ] || err "filter community butuh nilai AS:NN"
            valid_community "$_c" "community"
            upsert "^filter $_b5_n $_b5_a-community $_c\$" "filter $_b5_n $_b5_a-community $_c"
            ;;
        as-path)
            [ -n "$_b5_x" ] || err "filter as-path butuh daftar AS (mis. 65000 atau 65000,65001)"
            valid_aspath_list "$_b5_x" "as-path"
            upsert "^filter $_b5_n $_b5_a-aspath " "filter $_b5_n $_b5_a-aspath $_b5_x"
            ;;
        origin)
            [ -n "$_b5_x" ] || err "filter origin butuh igp|egp|incomplete"
            case "$_b5_x" in igp|egp|incomplete) ;; *) err "filter origin harus igp|egp|incomplete: $_b5_x" ;; esac
            upsert "^filter $_b5_n $_b5_a-origin " "filter $_b5_n $_b5_a-origin $_b5_x"
            ;;
        next-hop)
            [ -n "$_b5_x" ] || err "filter next-hop butuh alamat IP"
            valid_ipv4 "$_b5_x" "next-hop"
            upsert "^filter $_b5_n $_b5_a-next-hop " "filter $_b5_n $_b5_a-next-hop $_b5_x"
            ;;
        originator-id)
            [ -n "$_b5_x" ] || err "filter originator-id butuh alamat IP"
            valid_ipv4 "$_b5_x" "originator-id"
            upsert "^filter $_b5_n $_b5_a-originator-id " "filter $_b5_n $_b5_a-originator-id $_b5_x"
            ;;
        cluster-list)
            [ -n "$_b5_x" ] || err "filter cluster-list butuh alamat IP"
            valid_ipv4 "$_b5_x" "cluster-list"
            upsert "^filter $_b5_n $_b5_a-cluster-list " "filter $_b5_n $_b5_a-cluster-list $_b5_x"
            ;;
        otc)
            [ -n "$_b5_x" ] || err "filter otc butuh angka"
            valid_u32 "$_b5_x" "otc"
            upsert "^filter $_b5_n $_b5_a-otc " "filter $_b5_n $_b5_a-otc $_b5_x"
            ;;
        # --- B5 ---
        prefix-len)
            [ -n "$_b5_x" ] && [ -n "$_b5_y" ] || err "filter prefix-len butuh OP + N (mis. prefix-len <= 24)"
            valid_op "$_b5_x" "prefix-len"
            valid_u32 "$_b5_y" "prefix-len"; [ "$_b5_y" -le 128 ] 2>/dev/null || err "prefix-len harus 0..128: $_b5_y"
            upsert "^filter $_b5_n $_b5_a-prefix-len $_b5_x $_b5_y\$" "filter $_b5_n $_b5_a-prefix-len $_b5_x $_b5_y"
            ;;
        prefix-ip)
            [ -n "$_b5_x" ] || err "filter prefix-ip butuh alamat IP"
            valid_ipv4 "$_b5_x" "prefix-ip"
            upsert "^filter $_b5_n $_b5_a-prefix-ip $(re_escape "$_b5_x")\$" "filter $_b5_n $_b5_a-prefix-ip $_b5_x"
            ;;
        ip-v4|ip-v6)
            upsert "^filter $_b5_n $_b5_a-$_b5_v\$" "filter $_b5_n $_b5_a-$_b5_v"
            ;;
        ip-mask)
            [ -n "$_b5_x" ] && [ -n "$_b5_y" ] || err "filter ip-mask butuh IP + N (mis. ip-mask 10.0.0.0 8)"
            valid_ipv4 "$_b5_x" "ip-mask"
            valid_u32 "$_b5_y" "ip-mask"; [ "$_b5_y" -le 32 ] 2>/dev/null || err "ip-mask N harus 0..32: $_b5_y"
            upsert "^filter $_b5_n $_b5_a-ip-mask $(re_escape "$_b5_x") $_b5_y\$" "filter $_b5_n $_b5_a-ip-mask $_b5_x $_b5_y"
            ;;
        path-mask)
            [ -n "$_b5_x" ] || err "filter path-mask butuh mask koma (mis. *,65001,*)"
            valid_bgpmask "$_b5_x" "path-mask"
            upsert "^filter $_b5_n $_b5_a-path-mask $(re_escape "$_b5_x")\$" "filter $_b5_n $_b5_a-path-mask $_b5_x"
            ;;
        path-first|path-last)
            [ -n "$_b5_x" ] || err "filter $_b5_v butuh nomor AS"
            valid_asn "$_b5_x" "$_b5_v"
            upsert "^filter $_b5_n $_b5_a-$_b5_v $_b5_x\$" "filter $_b5_n $_b5_a-$_b5_v $_b5_x"
            ;;
        path-len|community-len)
            [ -n "$_b5_x" ] && [ -n "$_b5_y" ] || err "filter $_b5_v butuh OP + N (mis. $_b5_v <= 3)"
            valid_op "$_b5_x" "$_b5_v"
            valid_u32 "$_b5_y" "$_b5_v"
            upsert "^filter $_b5_n $_b5_a-$_b5_v $_b5_x $_b5_y\$" "filter $_b5_n $_b5_a-$_b5_v $_b5_x $_b5_y"
            ;;
        community-min|community-max)
            [ -n "$_b5_x" ] || err "filter $_b5_v butuh nilai AS:NN"
            valid_community "$_b5_x" "$_b5_v"
            upsert "^filter $_b5_n $_b5_a-$_b5_v $_b5_x\$" "filter $_b5_n $_b5_a-$_b5_v $_b5_x"
            ;;
        local-pref|med)
            [ -n "$_b5_x" ] && [ -n "$_b5_y" ] || err "filter $_b5_v butuh OP + N (mis. $_b5_v = 100)"
            valid_op "$_b5_x" "$_b5_v"
            valid_u32 "$_b5_y" "$_b5_v"
            upsert "^filter $_b5_n $_b5_a-$_b5_v $_b5_x $_b5_y\$" "filter $_b5_n $_b5_a-$_b5_v $_b5_x $_b5_y"
            ;;
        defined|undefined)
            [ -n "$_b5_x" ] || err "filter $_b5_v butuh nama atribut (mis. defined bgp_med)"
            [ "$(attr_kind "$_b5_x")" != "unknown" ] || custom_attr_exists "$_b5_x" || err "filter $_b5_v atribut tidak dikenal: $_b5_x"
            upsert "^filter $_b5_n $_b5_a-$_b5_v $_b5_x\$" "filter $_b5_n $_b5_a-$_b5_v $_b5_x"
            ;;
        roa)
            [ -n "$_b5_x" ] && [ -n "$_b5_y" ] || err "filter roa butuh TABEL + HASIL (mis. roa R4 ROA_VALID)"
            roa_table_exists "$_b5_x" || err "filter roa: tabel roa $_b5_x belum didefinisikan (define dulu: roa-table $_b5_x)"
            case "$_b5_y" in ROA_VALID|ROA_INVALID|ROA_UNKNOWN) ;; *) err "filter roa hasil harus ROA_VALID|ROA_INVALID|ROA_UNKNOWN: $_b5_y" ;; esac
            upsert "^filter $_b5_n $_b5_a-roa $_b5_x $_b5_y\$" "filter $_b5_n $_b5_a-roa $_b5_x $_b5_y"
            ;;
        aspa-down|aspa-up)
            [ -n "$_b5_x" ] && [ -n "$_b5_y" ] || err "filter $_b5_v butuh TABEL + HASIL (mis. $_b5_v AT ASPA_VALID)"
            aspa_table_exists "$_b5_x" || err "filter $_b5_v: tabel aspa $_b5_x belum didefinisikan (define dulu: aspa-table $_b5_x)"
            case "$_b5_y" in ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN) ;; *) err "filter $_b5_v hasil harus ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN: $_b5_y" ;; esac
            upsert "^filter $_b5_n $_b5_a-$_b5_v $_b5_x $_b5_y\$" "filter $_b5_n $_b5_a-$_b5_v $_b5_x $_b5_y"
            ;;
        roa3)  # B12/5-105: roa_check 3-argumen (TABEL PREFIX ASN HASIL)
            [ -n "$_b5_x" ] && [ -n "$_b5_y" ] && [ -n "$_z" ] && [ -n "$_w" ] || err "filter roa3 butuh TABEL + PREFIX + ASN + HASIL (mis. roa3 R4 net bgp_path.last ROA_VALID)"
            roa_table_exists "$_b5_x" || err "filter roa3: tabel roa $_b5_x belum didefinisikan (define dulu: roa-table $_b5_x)"
            case "$_b5_y" in net) ;; *) valid_prefix_any "$_b5_y" "roa3 prefix" ;; esac
            case "$_z" in bgp_path.last) ;; *) valid_asn "$_z" "roa3 ASN" ;; esac
            case "$_w" in ROA_VALID|ROA_INVALID|ROA_UNKNOWN) ;; *) err "filter roa3 hasil harus ROA_VALID|ROA_INVALID|ROA_UNKNOWN: $_w" ;; esac
            upsert "^filter $_b5_n $_b5_a-roa3 $_b5_x $_b5_y $_z $_w\$" "filter $_b5_n $_b5_a-roa3 $_b5_x $_b5_y $_z $_w"
            ;;
        aspa3)  # B12/5-108: aspa_check 3-argumen (TABEL PATH BOOL HASIL)
            [ -n "$_b5_x" ] && [ -n "$_b5_y" ] && [ -n "$_z" ] && [ -n "$_w" ] || err "filter aspa3 butuh TABEL + PATH + BOOL + HASIL (mis. aspa3 AT bgp_path true ASPA_VALID)"
            aspa_table_exists "$_b5_x" || err "filter aspa3: tabel aspa $_b5_x belum didefinisikan (define dulu: aspa-table $_b5_x)"
            case "$_b5_y" in bgp_path) ;; *) err "filter aspa3 PATH harus bgp_path: $_b5_y" ;; esac
            case "$_z" in true|up) _z=true ;; false|down) _z=false ;; *) err "filter aspa3 BOOL harus true|up (upstream) atau false|down (downstream): $_z" ;; esac
            case "$_w" in ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN) ;; *) err "filter aspa3 hasil harus ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN: $_w" ;; esac
            upsert "^filter $_b5_n $_b5_a-aspa3 $_b5_x $_b5_y $_z $_w\$" "filter $_b5_n $_b5_a-aspa3 $_b5_x $_b5_y $_z $_w"
            ;;
        match)
            _b5_x=$(klish_unescape "$_b5_x")
            [ -n "$_b5_x" ] || err "filter match butuh COND (mis. match defined:bgp_med)"
            cond_to_bird "$_b5_x" "$_b5_vl" >/dev/null || exit 33
            upsert "^filter $_b5_n $_b5_a-match $(re_escape "$_b5_x")\$" "filter $_b5_n $_b5_a-match $_b5_x"
            ;;
        *)
            valid_prefix_pattern "$_b5_v" "filter prefix"
            upsert "^filter $_b5_n $_b5_a $_b5_v\$" "filter $_b5_n $_b5_a $_b5_v"
            ;;
    esac
    echo "BGP filter $_b5_n $_b5_a $_b5_v${4:+ $4}${5:+ $5}${6:+ $6}${7:+ $7}"
}

# --- B5: statement / blok / definisi top-level filter ---
cmd_filter_set() { # filter-set <NAME> <ATTR> <NILAI>
    _n="$1"; _a="$2"; _v="$3"
    [ -n "$_n" ] && [ -n "$_a" ] && [ -n "$_v" ] || err "filter-set butuh NAMA ATTR NILAI"
    _b5_n="$_n"; _b5_a="$_a"; _b5_v=$(klish_unescape "$_v")
    valid_symbol "$_n" "filter"
    valid_set_stmt "$_a" "$_b5_v" "filter-set" "$(filter_vars "$_n")"
    upsert "^filter $_b5_n set $_b5_a $(re_escape "$_b5_v")\$" "filter $_b5_n set $_b5_a $_b5_v"
    echo "BGP filter $_b5_n set $_b5_a = $_b5_v"
}
cmd_filter_unset() { # filter-unset <NAME> <ATTR>
    _n="$1"; _a="$2"
    [ -n "$_n" ] && [ -n "$_a" ] || err "filter-unset butuh NAMA ATTR"
    valid_symbol "$_n" "filter"
    valid_unset_attr "$_a" "filter-unset"
    upsert "^filter $_n unset $_a\$" "filter $_n unset $_a"
    echo "BGP filter $_n unset $_a"
}
cmd_filter_var() { # filter-var <NAME> <TIPE> <VAR>
    _n="$1"; _t="$2"; _v="$3"
    [ -n "$_n" ] && [ -n "$_t" ] && [ -n "$_v" ] || err "filter-var butuh NAMA TIPE VAR"
    valid_symbol "$_n" "filter"
    valid_var_type "$_t" "filter-var"
    valid_name "$_v" "filter-var"
    _old=$(filter_vars "$_n")
    case " $_old " in *" $_v:"*) err "filter-var: variabel $_v sudah dideklarasikan di filter $_n" ;; esac
    touch_conf
    printf 'filter %s var %s %s\n' "$_n" "$_t" "$_v" >> "$CONF"
    echo "BGP filter $_n var $_t $_v"
}
cmd_filter_var_set() { # filter-var-set <NAME> <TYPESET> <VAR> <LITERAL>
    _n="$1"; _t="$2"; _v="$3"; _lit=$(klish_unescape "$4") # B23: klish escape \( \) di PARAM — tanpa ini var-set gagal live (uji live 17 Nov 01:40 UTC)
    [ -n "$_n" ] && [ -n "$_t" ] && [ -n "$_v" ] && [ -n "$_lit" ] || err "filter-var-set butuh NAMA TYPESET VAR LITERAL"
    valid_symbol "$_n" "filter"
    valid_set_typeset "$_t" "filter-var-set"
    valid_name "$_v" "filter-var-set"
    valid_set_literal "$_t" "$_lit" "filter-var-set"
    _old=$(filter_vars "$_n")
    case " $_old " in *" $_v:"*) err "filter-var-set: variabel $_v sudah dideklarasikan di filter $_n" ;; esac
    touch_conf
    printf 'filter %s var-set %s %s %s\n' "$_n" "$_t" "$_v" "$_lit" >> "$CONF"
    echo "BGP filter $_n var-set $_t $_v = $_lit"
}
cmd_filter_method() { # filter-method <NAME> <CALL>
    _n="$1"; _c=$(klish_unescape "$2") # B23: klish escape \( \) di PARAM — tanpa ini method gagal live (uji live 17 Nov 01:40 UTC)
    [ -n "$_n" ] && [ -n "$_c" ] || err "filter-method butuh NAMA CALL"
    valid_symbol "$_n" "filter"
    method_to_bird "$_c" "$(filter_vars "$_n")" >/dev/null || exit 33
    touch_conf
    printf 'filter %s method %s\n' "$_n" "$_c" >> "$CONF"
    echo "BGP filter $_n method $_c"
}
cmd_filter_if() { # filter-if <NAME> <COND> <THEN> [ELSE]
    _n="$1"; _c="$2"; _t="$3"; _e="$4"
    _c=$(klish_unescape "$_c"); _t=$(klish_unescape "$_t"); _e=$(klish_unescape "$_e")
    [ -n "$_n" ] && [ -n "$_c" ] && [ -n "$_t" ] || err "filter-if butuh NAMA COND THEN [ELSE]"
    _b5_n="$_n"; _b5_c="$_c"; _b5_t="$_t"; _b5_e="$_e"
    valid_symbol "$_n" "filter"
    _vl=$(filter_vars "$_n")
    cond_to_bird "$_c" "$_vl" >/dev/null || exit 33
    stmt_to_bird "$_t" "$_vl" >/dev/null || exit 33
    # B9: APPEND (bukan upsert) — satu filter boleh punya banyak baris if;
    # baris yang sama persis dideduplikasi agar idempotent.
    _b5_line="filter $_b5_n if $_b5_c then $_b5_t"
    [ -n "$_e" ] && _b5_line="$_b5_line else $_b5_e"
    touch_conf; _tmp="$CONF.tmp.$$"
    awk -v line="$_b5_line" '$0 != line' "$CONF" > "$_tmp" 2>/dev/null || true
    printf '%s\n' "$_b5_line" >> "$_tmp"
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    chmod 600 "$CONF" 2>/dev/null || true
    echo "BGP filter $_b5_line"
}
cmd_filter_print() { # B16/5-157/158: filter-print <NAME> print|printn <ARGS>
    _n="$1"; _k="$2"; _a="$3"
    [ -n "$_n" ] && [ -n "$_k" ] && [ -n "$_a" ] || err "filter-print butuh NAMA print|printn ARGS"
    case "$_k" in print|printn) ;; *) err "filter-print: jenis harus print|printn: $_k" ;; esac
    valid_symbol "$_n" "filter"
    _vl=$(filter_vars "$_n")
    print_args_to_bird "$_a" "$_vl" >/dev/null || exit 33
    # APPEND (bukan upsert) + dedup baris sama persis, seperti filter-if (B9).
    _line="filter $_n $_k $_a"
    touch_conf; _tmp="$CONF.tmp.$$"
    awk -v line="$_line" '$0 != line' "$CONF" > "$_tmp" 2>/dev/null || true
    printf '%s\n' "$_line" >> "$_tmp"
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    chmod 600 "$CONF" 2>/dev/null || true
    echo "BGP filter $_line"
}
cmd_filter_block() { # filter-block <NAME> <if|else|for|case|when|otherwise|close> [ARGS...]
    _n="$1"; _k="$2"; shift 2
    [ -n "$_n" ] && [ -n "$_k" ] || err "filter-block butuh NAMA JENIS [ARGS]"
    valid_symbol "$_n" "filter"
    _vl=$(filter_vars "$_n")
    case "$_k" in
        if)
            [ -n "$1" ] || err "filter-block if butuh COND"
            cond_to_bird "$1" "$_vl" >/dev/null || exit 33
            touch_conf; printf 'filter %s if-block %s\n' "$_n" "$1" >> "$CONF"
            echo "BGP filter $_n if-block $1" ;;
        else)
            touch_conf; printf 'filter %s else-block\n' "$_n" >> "$CONF"
            echo "BGP filter $_n else-block" ;;
        for)
            [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || err "filter-block for butuh TIPE VAR SUMBER (mis. for int asn bgp_path)"
            valid_for "$1" "$2" "$3" "$_vl"
            touch_conf; printf 'filter %s for-block %s %s %s\n' "$_n" "$1" "$2" "$3" >> "$CONF"
            echo "BGP filter $_n for-block $1 $2 $3" ;;
        case)
            [ -n "$1" ] || err "filter-block case butuh EKSPRESI (mis. case roa-check:R4)"
            valid_case_expr "$1" "$_vl" >/dev/null || exit 33
            touch_conf; printf 'filter %s case-block %s\n' "$_n" "$1" >> "$CONF"
            echo "BGP filter $_n case-block $1" ;;
        when)
            [ -n "$1" ] && [ -n "$2" ] || err "filter-block when butuh LABEL STMT (mis. when 2 accept)"
            stmt_to_bird "$2" "$_vl" >/dev/null || exit 33
            touch_conf; printf 'filter %s when %s %s\n' "$_n" "$1" "$2" >> "$CONF"
            echo "BGP filter $_n when $1 $2" ;;
        otherwise)
            [ -n "$1" ] || err "filter-block otherwise butuh STMT (mis. otherwise reject)"
            stmt_to_bird "$1" "$_vl" >/dev/null || exit 33
            touch_conf; printf 'filter %s otherwise %s\n' "$_n" "$1" >> "$CONF"
            echo "BGP filter $_n otherwise $1" ;;
        close)
            touch_conf; printf 'filter %s close-block\n' "$_n" >> "$CONF"
            echo "BGP filter $_n close-block" ;;
        *) err "filter-block jenis tidak dikenal: $_k (if|else|for|case|when|otherwise|close)" ;;
    esac
}
cmd_define_int_add() { # define-int-add <NAMA> <N>
    [ -n "$1" ] && [ -n "$2" ] || err "define-int butuh NAMA + N"
    valid_name "$1" "define-int"
    valid_u32 "$2" "define-int"
    upsert "^define-int $1 " "define-int $1 $2"
    echo "define $1 = $2"
}
cmd_define_int_del() {
    [ -n "$1" ] || err "define-int-del butuh NAMA"
    dellines "^define-int $1 "
    echo "define-int $1 dihapus"
}
cmd_attribute_int_add() { # attribute-int-add <NAMA>
    [ -n "$1" ] || err "attribute-int butuh NAMA"
    valid_name "$1" "attribute-int"
    upsert "^attribute-int $1\$" "attribute-int $1"
    echo "attribute int $1 ditambahkan"
}
cmd_attribute_int_del() {
    [ -n "$1" ] || err "attribute-int-del butuh NAMA"
    dellines "^attribute-int $1\$"
    echo "attribute-int $1 dihapus"
}
cmd_roa_table_add() { # roa-table-add <NAMA> [v4|v6]
    [ -n "$1" ] || err "roa-table butuh NAMA"
    valid_symbol "$1" "roa-table"
    _ver="${2:-v4}"
    case "$_ver" in v4|v6) ;; *) err "roa-table versi harus v4|v6: $_ver" ;; esac
    upsert "^roa-table $1 " "roa-table $1 $_ver"
    echo "roa-table $1 ($_ver) ditambahkan (tabel kosong sampai protokol RPKI mengisinya — B9)"
}
cmd_roa_table_del() {
    [ -n "$1" ] || err "roa-table-del butuh NAMA"
    dellines "^roa-table $1 "
    echo "roa-table $1 dihapus"
}
cmd_aspa_table_add() { # aspa-table-add <NAMA>
    [ -n "$1" ] || err "aspa-table butuh NAMA"
    valid_symbol "$1" "aspa-table"
    upsert "^aspa-table $1\$" "aspa-table $1"
    echo "aspa-table $1 ditambahkan (tabel kosong sampai protokol RPKI mengisinya — B9)"
}
cmd_aspa_table_del() {
    [ -n "$1" ] || err "aspa-table-del butuh NAMA"
    dellines "^aspa-table $1\$"
    echo "aspa-table $1 dihapus"
}

cmd_filter_del() {
    _n="$1"
    [ -n "$_n" ] || err "filter-del butuh NAMA"
    dellines "^filter $_n "
    echo "BGP filter $_n dihapus"
}

cmd_show() {
    touch_conf
    cat "$CONF"
}

# bird_ident <nama> — ubah nama menjadi identifier BIRD yang valid
# (huruf/angka/underscore saja; '-' dan karakter lain jadi '_').
# BIRD menolak '-' di nama filter/protocol ("unexpected '-'").
bird_ident() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
}

# emit_sw <opsi-BIRD> <nilai> — tulis "    <opsi> <nilai>;" bila nilai non-kosong.
# Dipakai opsi B1 (switch/enum/angka) di cmd_generate.
emit_sw() { [ -n "$2" ] && echo "    $1 $2;"; }

# _emit_bgp_channel <IP> <KEY> — tulis SATU blok channel BIRD (B6).
# Dipanggil hanya bila neighbor punya field channel itu (chan_has).
# Default import/export bila tak diset = BIRD Bab 3.5 (import all,
# export none). Urutan opsi = docs Bab 6.4 Tabel 2 / Bab 3.5.
_emit_bgp_channel() {
    _eip="$1"; _ek="$2"
    _ecn=$(chan_bird_name "$_ek")
    _cg() { get_field "$_eip" "$_ek-$1"; }
    _cesw() { # <opsi-BIRD> <FIELD>
        _cev=$(_cg "$2")
        [ -n "$_cev" ] && echo "        $1 $_cev;"
    }
    _celim() { # <opsi-BIRD> <FIELD-limit> <FIELD-action>
        _clv=$(_cg "$2")
        [ -z "$_clv" ] && return 0
        _cav=$(_cg "$3")
        if [ -n "$_cav" ]; then echo "        $1 $_clv action $_cav;"; else echo "        $1 $_clv;"; fi
    }
    # Guard: aksi limit tanpa limit-nya tidak bermakna (cermin ipv4).
    _cv=$(_cg import-limit-action); _cl=$(_cg import-limit)
    [ -n "$_cv" ] && [ -z "$_cl" ] && err "neighbor $_eip: $_ek-import-limit-action tanpa $_ek-import-limit"
    _cv=$(_cg receive-limit-action); _cl=$(_cg receive-limit)
    [ -n "$_cv" ] && [ -z "$_cl" ] && err "neighbor $_eip: $_ek-receive-limit-action tanpa $_ek-receive-limit"
    _cv=$(_cg export-limit-action); _cl=$(_cg export-limit)
    [ -n "$_cv" ] && [ -z "$_cl" ] && err "neighbor $_eip: $_ek-export-limit-action tanpa $_ek-export-limit"
    # Guard: gateway recursive + igp-table harus se-famili dgn channel
    # (BIRD 2.20: "Mismatched IGP table type" — resolusi gateway rekursif
    # memakai igp-table; tabel v4 di channel v6 (atau sebaliknya) ditolak).
    # igp-table6 tidak dicek di sini (itu tabel v6; bila gateway recursive
    # dan igp-table6 v4, BIRD juga menolak — pola sama, tambahkan bila perlu).
    _gw=$(_cg gateway); _it=$(_cg igp-table)
    if [ "$_gw" = "recursive" ] && [ -n "$_it" ]; then
        _gc="$STATE_ROOT/bird-global.conf"
        if [ -f "$_gc" ]; then
            _int=$(grep "^table [^ ]* $_it\$" "$_gc" 2>/dev/null | awk '{print $2}' | head -1)
            if [ -n "$_int" ]; then
                case "$(chan_family "$_ek")" in
                    v4) case "$_int" in ipv4) ;; *) err "neighbor $_eip: channel $_ek gateway recursive + igp-table $_it ($_int) — tabel IGP harus ipv4 untuk channel v4" ;; esac ;;
                    v6) case "$_int" in ipv6|ipv6-sadr) ;; *) err "neighbor $_eip: channel $_ek gateway recursive + igp-table $_it ($_int) — tabel IGP harus ipv6 untuk channel v6" ;; esac ;;
                esac
            fi
        fi
    fi
    # Guard: channel vpn4/vpn6 WAJIB punya tabel (BIRD 2.20: "Routing table
    # not specified" bila tanpa `table`).
    case "$_ek" in
        vpn4|vpn6)
            _ct=$(_cg table)
            [ -n "$_ct" ] || err "neighbor $_eip: channel $_ek wajib punya tabel (neighbor-set $_eip $_ek-table <NAMA>)"
            ;;
    esac
    # Guard kombinasi next hop self vs keep (cermin ipv4, docs Bab 6.4).
    _nhs=$(_cg next-hop-self); _nhk=$(_cg next-hop-keep)
    case "$_nhs" in on|ibgp|ebgp)
        case "$_nhk" in on|ibgp|ebgp) err "neighbor $_eip: $_ek next hop self dan next hop keep tidak bisa dipakai bersamaan" ;; esac ;;
    esac
    echo "    $_ecn {"
    _cimp=$(_cg import); _cexp=$(_cg export)
    case "$_cimp" in
        all|"") echo "        import all;" ;;
        none) echo "        import none;" ;;
        filter)
            _cfn=$(grep "^neighbor $_eip $_ek-import " "$CONF" | awk '{print $5}')
            echo "        import filter $(bird_ident "$_cfn");" ;;
        where)
            _wexpr=$(grep "^neighbor $_eip $_ek-import " "$CONF" | awk '{print $5}')
            _wbird=$(cond_to_bird "$_wexpr" "") || exit 33
            echo "        import where $_wbird;" ;;
    esac
    case "$_cexp" in
        none|"") echo "        export none;" ;;
        all) echo "        export all;" ;;
        filter)
            _cfn=$(grep "^neighbor $_eip $_ek-export " "$CONF" | awk '{print $5}')
            echo "        export filter $(bird_ident "$_cfn");" ;;
        where)
            _wexpr=$(grep "^neighbor $_eip $_ek-export " "$CONF" | awk '{print $5}')
            _wbird=$(cond_to_bird "$_wexpr" "") || exit 33
            echo "        export where $_wbird;" ;;
    esac
    _cesw "import keep filtered" import-keep-filtered
    _cesw "rpki reload" rpki-reload
    _cesw "preference" preference
    _cesw "mandatory" mandatory
    _cesw "next hop keep" next-hop-keep
    _cesw "next hop self" next-hop-self
    _cv=$(_cg next-hop-address); [ -n "$_cv" ] && echo "        next hop address $_cv;"
    # next hop prefer global = FLAG polos (BIRD 2.20: tanpa nilai on/off;
    # "unexpected ON" bila pakai nilai). Emit hanya bila on.
    _cv=$(_cg next-hop-prefer-global); [ "$_cv" = "on" ] && echo "        next hop prefer global;"
    _cesw "gateway" gateway
    _cv=$(_cg igp-table); [ -n "$_cv" ] && echo "        igp table $(bird_ident "$_cv");"
    _cv=$(_cg igp-table6); [ -n "$_cv" ] && echo "        igp table $(bird_ident "$_cv");"
    _cesw "import table" import-table
    _cesw "export table" export-table
    _cesw "secondary" secondary
    _cesw "validate" validate
    _cv=$(_cg base-table); [ -n "$_cv" ] && echo "        base table $(bird_ident "$_cv");"
    _cesw "extended next hop" extended-next-hop
    _cesw "require extended next hop" require-extended-next-hop
    _cesw "add paths" add-paths
    _cesw "require add paths" require-add-paths
    _cesw "aigp" aigp
    _cesw "cost" cost
    _cesw "graceful restart" graceful-restart
    _cesw "long lived graceful restart" llgr
    _cesw "long lived stale time" llgr-stale-time
    _cv=$(_cg table); [ -n "$_cv" ] && echo "        table $(bird_ident "$_cv");"
    _cv=$(_cg debug)
    if [ -n "$_cv" ]; then
        case "$_cv" in all|off) echo "        debug $_cv;" ;; *) echo "        debug { $(echo "$_cv" | sed 's/,/, /g') };" ;; esac
    fi
    _celim "import limit" import-limit import-limit-action
    _celim "receive limit" receive-limit receive-limit-action
    _celim "export limit" export-limit export-limit-action
    # FlowSpec: tabel dasar (base table) WAJIB trie on (BIRD 2.20 menolak
    # config bila base table trie off — "Flowspec validation requires base
    # table ... with trie" / "Routing table not specified"). Guard gagal
    # rc=33 bila base table diketahui trie off di bird-global.conf; bila
    # tidak diketahui (master4/6 atau tabel luar intent), emit NOTE saja.
    _bt=$(_cg base-table)
    if [ -n "$_bt" ]; then
        _trie="tidak-diketahui"
        _gc="$STATE_ROOT/bird-global.conf"
        if [ -f "$_gc" ] && grep -q "^table [^ ]* $_bt\$" "$_gc" 2>/dev/null; then
            if grep -q "^table-opt $_bt trie on" "$_gc" 2>/dev/null; then _trie="on"; else _trie="off"; fi
        fi
        case "$_trie" in
            on) ;;
            off) err "neighbor $_eip: channel $_ek base table $_bt trie off — BIRD 2.20 menolak validasi flowspec tanpa trie (table-set $_bt trie on dulu)" ;;
            *) case "$_bt" in
                   master4|master6)
                       # B.6: master built-in tanpa baris `table` di intent =
                       # trie BELUM on (BIRD menolak validate on tanpa trie —
                       # teruji bird -p: "Flowspec validation requires base
                       # table (master4) with trie"); jangan lolos sebagai NOTE.
                       if [ "$(_cg validate)" = "on" ]; then
                           err "neighbor $_eip: channel $_ek base table $_bt tanpa trie on — BIRD 2.20 menolak validasi flowspec (table-set $_bt trie on dulu)"
                       fi ;;
                   *) [ "$(_cg validate)" = "on" ] && echo "        # NOTE: validate on — pastikan tabel dasar $_bt trie on (validasi flowspec wajib trie, Bab 3.3-3)" ;;
               esac ;;
        esac
    fi
    echo "    };"
}

# --- generate: intent -> bird.d/bgp.conf (sintaks BIRD) ---
cmd_generate() {
    touch_conf
    _rid=$(grep '^router-id ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
    _las=$(grep '^local-as ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
    [ -n "$_las" ] || err "local-as belum diset (router bird local-as <AS>)"
    # B6: `from` wajib merujuk template bgp yang ada di bird-global.conf
    # (template hanya didefinisikan di sana; bila belum ada, gagal jelas).
    for _fn in $(grep '^neighbor ' "$CONF" 2>/dev/null | awk '{print $2}' | sort -u); do
        _ff=$(get_field "$_fn" from)
        [ -z "$_ff" ] && continue
        _gf="$STATE_ROOT/bird-global.conf"
        [ -f "$_gf" ] && grep -q "^template bgp $_ff\( \|$\)" "$_gf" 2>/dev/null || \
            err "neighbor $_fn: from template bgp $_ff tidak ada di bird-global.conf (template-add bgp $_ff dulu)"
    done
    # BFD: bila ada neighbor dengan bfd on/graceful, section BFD harus
    # sudah ter-generate SEBELUM section BGP di-render — birdc
    # configure gagal bila `bfd on;` ada tanpa `protocol bfd`.
    # (Di jalur commit, apply_bfd sudah jalan dulu; ini pertahanan
    # untuk pemanggilan generate langsung.)
    if grep -q '^neighbor .* bfd ' "$CONF" 2>/dev/null; then
        _bfds="$(dirname "$0")/titian-bfd.sh"
        if [ -x "$_bfds" ]; then
            "$_bfds" has-facts || err "BFD diaktifkan di neighbor BGP tapi protocol bfd belum dikonfigurasi (router bird -> bfd -> interface ...)"
            "$_bfds" generate || exit 33
        else
            err "BFD diaktifkan di neighbor BGP tapi $_bfds tidak ditemukan"
        fi
    fi
    mkdir -p "$SECTION_DIR" 2>/dev/null || die "cannot mkdir $SECTION_DIR"
    _tmp="$SECTION.tmp.$$"
    {
        echo "# bgp.conf - generated by titian-bgp.sh, do not edit by hand"
        # --- B1: atribut BGP kustom (top-level; hanya bila ada) ---
        _ab_lines=$(grep '^attribute-bgp ' "$CONF" 2>/dev/null | sed 's/^attribute-bgp \([0-9]*\) \([A-Za-z0-9_]*\)/attribute bgp \1 bytestring \2;/')
        if [ -n "$_ab_lines" ]; then
            printf '%s\n' "$_ab_lines"
            echo ""
        fi
        # --- B5: definisi top-level (define / attribute int / tabel roa+aspa).
        # Urutan: define -> attribute -> tabel, sebelum filter yang memakainya.
        _d_lines=$(grep '^define-int ' "$CONF" 2>/dev/null | sed 's/^define-int \([A-Za-z0-9_]*\) \([0-9]*\)/define \1 = \2;/')
        [ -n "$_d_lines" ] && printf '%s\n' "$_d_lines"
        _ai_lines=$(grep '^attribute-int ' "$CONF" 2>/dev/null | sed 's/^attribute-int \([A-Za-z0-9_]*\)/attribute int \1;/')
        [ -n "$_ai_lines" ] && printf '%s\n' "$_ai_lines"
        _roa_lines=$(grep '^roa-table ' "$CONF" 2>/dev/null | sed 's/^roa-table \([A-Za-z0-9_]*\) v6/roa6 table \1;/; s/^roa-table \([A-Za-z0-9_]*\) v4/roa4 table \1;/; s/^roa-table \([A-Za-z0-9_]*\)$/roa4 table \1;/')
        [ -n "$_roa_lines" ] && printf '%s\n' "$_roa_lines"
        _aspa_lines=$(grep '^aspa-table ' "$CONF" 2>/dev/null | sed 's/^aspa-table \([A-Za-z0-9_]*\)/aspa table \1;/')
        [ -n "$_aspa_lines" ] && printf '%s\n' "$_aspa_lines"
        if [ -n "$_d_lines" ] || [ -n "$_ai_lines" ] || [ -n "$_roa_lines" ] || [ -n "$_aspa_lines" ]; then
            echo ""
        fi
        # --- filter definitions (B5: aturan + statement + blok) ---
        # Loop memakai redirect file (bukan pipeline) supaya err (exit 33)
        # di dalam loop langsung menggagalkan generate, bukan hanya subshell.
        for _Lfn in $(grep '^filter ' "$CONF" 2>/dev/null | awk '{print $2}' | sort -u); do
            _Lbfn=$(bird_ident "$_Lfn")
            echo "filter $_Lbfn {"
            _Lftmp=$(mktemp /tmp/titian-bgp-filter.XXXXXX) || die "cannot mktemp"
            grep "^filter $_Lfn " "$CONF" > "$_Lftmp" 2>/dev/null || true
            _Ldepth=0; _Lpad="    "; _Lstack=""; _Lvars=$(filter_vars "$_Lfn")
            while read -r _ _Lf _La _Lv; do
                case "$_La" in
                    accept*) _Lact="accept" ;;
                    reject*) _Lact="reject" ;;
                    set|unset|var|var-set|method|print|printn|if|if-block|else-block|for-block|case-block|when|otherwise|close-block) _Lact="" ;;
                    *) err "filter $_Lfn: baris intent tidak dikenal: $_La" ;;
                esac
                case "$_La" in
                    accept|reject)
                        valid_prefix_pattern "$_Lv" "filter $_Lfn prefix"
                        case "$_Lv" in *+|*-|*{*}) _Lpat="$_Lv" ;; *) _Lpat="$_Lv+" ;; esac
                        printf '%sif net ~ [ %s ] then %s;\n' "$_Lpad" "$_Lpat" "$_Lact"
                        ;;
                    accept-community|reject-community)
                        # _Lv di sini adalah nilai community (kolom ke-4)
                        printf '%sif bgp_community ~ [ (%s) ] then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    accept-aspath|reject-aspath)
                        # _Lv = AS[,AS...] -> bgp_path ~ [ 65000, 65001 ]
                        _Lapl=$(echo "$_Lv" | sed 's/,/, /g')
                        printf '%sif bgp_path ~ [ %s ] then %s;\n' "$_Lpad" "$_Lapl" "$_Lact"
                        ;;
                    accept-origin|reject-origin)
                        case "$_Lv" in
                            igp) _Lov="ORIGIN_IGP" ;;
                            egp) _Lov="ORIGIN_EGP" ;;
                            incomplete) _Lov="ORIGIN_INCOMPLETE" ;;
                            *) err "filter $_Lfn: origin harus igp|egp|incomplete: $_Lv" ;;
                        esac
                        printf '%sif bgp_origin = %s then %s;\n' "$_Lpad" "$_Lov" "$_Lact"
                        ;;
                    accept-next-hop|reject-next-hop)
                        valid_ipv4 "$_Lv" "filter $_Lfn next-hop"
                        printf '%sif bgp_next_hop = %s then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    accept-originator-id|reject-originator-id)
                        valid_ipv4 "$_Lv" "filter $_Lfn originator-id"
                        printf '%sif bgp_originator_id = %s then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    accept-cluster-list|reject-cluster-list)
                        valid_ipv4 "$_Lv" "filter $_Lfn cluster-list"
                        printf '%sif bgp_cluster_list ~ [ %s ] then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    accept-otc|reject-otc)
                        valid_u32 "$_Lv" "filter $_Lfn otc"
                        printf '%sif bgp_otc = %s then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    # --- B5: match baru ---
                    accept-prefix-len|reject-prefix-len)
                        _Lop=${_Lv%% *}; _Lnum=${_Lv#* }
                        valid_op "$_Lop" "filter $_Lfn prefix-len"
                        valid_u32 "$_Lnum" "filter $_Lfn prefix-len"
                        [ "$_Lnum" -le 128 ] 2>/dev/null || err "filter $_Lfn prefix-len harus 0..128: $_Lnum"
                        printf '%sif net.len %s %s then %s;\n' "$_Lpad" "$_Lop" "$_Lnum" "$_Lact"
                        ;;
                    accept-prefix-ip|reject-prefix-ip)
                        valid_ipv4 "$_Lv" "filter $_Lfn prefix-ip"
                        printf '%sif net.ip = %s then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    accept-ip-v4|reject-ip-v4)
                        printf '%sif net.ip.is_v4 then %s;\n' "$_Lpad" "$_Lact"
                        ;;
                    accept-ip-v6|reject-ip-v6)
                        printf '%sif ! net.ip.is_v4 then %s;\n' "$_Lpad" "$_Lact"
                        ;;
                    accept-ip-mask|reject-ip-mask)
                        _Lip=${_Lv%% *}; _Lnum=${_Lv#* }
                        valid_ipv4 "$_Lip" "filter $_Lfn ip-mask"
                        valid_u32 "$_Lnum" "filter $_Lfn ip-mask"
                        [ "$_Lnum" -le 32 ] 2>/dev/null || err "filter $_Lfn ip-mask N harus 0..32: $_Lnum"
                        printf '%sif net.ip.mask(%s) = %s then %s;\n' "$_Lpad" "$_Lnum" "$_Lip" "$_Lact"
                        ;;
                    accept-path-mask|reject-path-mask)
                        valid_bgpmask "$_Lv" "filter $_Lfn path-mask"
                        printf '%sif bgp_path ~ %s then %s;\n' "$_Lpad" "$(bgpmask_to_bird "$_Lv")" "$_Lact"
                        ;;
                    accept-path-first|reject-path-first)
                        valid_asn "$_Lv" "filter $_Lfn path-first"
                        printf '%sif bgp_path.first = %s then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    accept-path-last|reject-path-last)
                        valid_asn "$_Lv" "filter $_Lfn path-last"
                        printf '%sif bgp_path.last = %s then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    accept-path-len|reject-path-len)
                        _Lop=${_Lv%% *}; _Lnum=${_Lv#* }
                        valid_op "$_Lop" "filter $_Lfn path-len"
                        valid_u32 "$_Lnum" "filter $_Lfn path-len"
                        printf '%sif bgp_path.len %s %s then %s;\n' "$_Lpad" "$_Lop" "$_Lnum" "$_Lact"
                        ;;
                    accept-community-len|reject-community-len)
                        _Lop=${_Lv%% *}; _Lnum=${_Lv#* }
                        valid_op "$_Lop" "filter $_Lfn community-len"
                        valid_u32 "$_Lnum" "filter $_Lfn community-len"
                        printf '%sif bgp_community.len %s %s then %s;\n' "$_Lpad" "$_Lop" "$_Lnum" "$_Lact"
                        ;;
                    accept-community-min|reject-community-min)
                        valid_community "$_Lv" "filter $_Lfn community-min"
                        printf '%sif bgp_community.min = (%s, %s) then %s;\n' "$_Lpad" "${_Lv%%:*}" "${_Lv#*:}" "$_Lact"
                        ;;
                    accept-community-max|reject-community-max)
                        valid_community "$_Lv" "filter $_Lfn community-max"
                        printf '%sif bgp_community.max = (%s, %s) then %s;\n' "$_Lpad" "${_Lv%%:*}" "${_Lv#*:}" "$_Lact"
                        ;;
                    accept-local-pref|reject-local-pref)
                        _Lop=${_Lv%% *}; _Lnum=${_Lv#* }
                        valid_op "$_Lop" "filter $_Lfn local-pref"
                        valid_u32 "$_Lnum" "filter $_Lfn local-pref"
                        printf '%sif bgp_local_pref %s %s then %s;\n' "$_Lpad" "$_Lop" "$_Lnum" "$_Lact"
                        ;;
                    accept-med|reject-med)
                        _Lop=${_Lv%% *}; _Lnum=${_Lv#* }
                        valid_op "$_Lop" "filter $_Lfn med"
                        valid_u32 "$_Lnum" "filter $_Lfn med"
                        printf '%sif bgp_med %s %s then %s;\n' "$_Lpad" "$_Lop" "$_Lnum" "$_Lact"
                        ;;
                    accept-defined|reject-defined)
                        [ "$(attr_kind "$_Lv")" != "unknown" ] || custom_attr_exists "$_Lv" || err "filter $_Lfn defined: atribut tidak dikenal: $_Lv"
                        printf '%sif defined(%s) then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    accept-undefined|reject-undefined)
                        [ "$(attr_kind "$_Lv")" != "unknown" ] || custom_attr_exists "$_Lv" || err "filter $_Lfn undefined: atribut tidak dikenal: $_Lv"
                        printf '%sif ! defined(%s) then %s;\n' "$_Lpad" "$_Lv" "$_Lact"
                        ;;
                    accept-roa|reject-roa)
                        _Ltb=${_Lv%% *}; _Lrs=${_Lv#* }
                        roa_table_exists "$_Ltb" || err "filter $_Lfn roa: tabel roa $_Ltb belum didefinisikan (roa-table $_Ltb)"
                        case "$_Lrs" in ROA_VALID|ROA_INVALID|ROA_UNKNOWN) ;; *) err "filter $_Lfn roa: hasil harus ROA_VALID|ROA_INVALID|ROA_UNKNOWN: $_Lrs" ;; esac
                        printf '%sif roa_check(%s) = %s then %s;\n' "$_Lpad" "$_Ltb" "$_Lrs" "$_Lact"
                        ;;
                    accept-aspa-down|reject-aspa-down)
                        _Ltb=${_Lv%% *}; _Lrs=${_Lv#* }
                        aspa_table_exists "$_Ltb" || err "filter $_Lfn aspa-down: tabel aspa $_Ltb belum didefinisikan (aspa-table $_Ltb)"
                        case "$_Lrs" in ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN) ;; *) err "filter $_Lfn aspa-down: hasil harus ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN: $_Lrs" ;; esac
                        printf '%sif aspa_check_downstream(%s) = %s then %s;\n' "$_Lpad" "$_Ltb" "$_Lrs" "$_Lact"
                        ;;
                    accept-aspa-up|reject-aspa-up)
                        _Ltb=${_Lv%% *}; _Lrs=${_Lv#* }
                        aspa_table_exists "$_Ltb" || err "filter $_Lfn aspa-up: tabel aspa $_Ltb belum didefinisikan (aspa-table $_Ltb)"
                        case "$_Lrs" in ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN) ;; *) err "filter $_Lfn aspa-up: hasil harus ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN: $_Lrs" ;; esac
                        printf '%sif aspa_check_upstream(%s) = %s then %s;\n' "$_Lpad" "$_Ltb" "$_Lrs" "$_Lact"
                        ;;
                    accept-roa3|reject-roa3)  # B12/5-105
                        _Ltb=${_Lv%% *}; _Lrest=${_Lv#* }; _Lpf=${_Lrest%% *}; _Lrest2=${_Lrest#* }; _Las=${_Lrest2%% *}; _Lrs=${_Lrest2#* }
                        roa_table_exists "$_Ltb" || err "filter $_Lfn roa3: tabel roa $_Ltb belum didefinisikan (roa-table $_Ltb)"
                        case "$_Lpf" in net) ;; *) valid_prefix_any "$_Lpf" "filter $_Lfn roa3 prefix" ;; esac
                        case "$_Las" in bgp_path.last) ;; *) valid_asn "$_Las" "filter $_Lfn roa3 ASN" ;; esac
                        case "$_Lrs" in ROA_VALID|ROA_INVALID|ROA_UNKNOWN) ;; *) err "filter $_Lfn roa3: hasil harus ROA_VALID|ROA_INVALID|ROA_UNKNOWN: $_Lrs" ;; esac
                        printf '%sif roa_check(%s, %s, %s) = %s then %s;\n' "$_Lpad" "$_Ltb" "$_Lpf" "$_Las" "$_Lrs" "$_Lact"
                        ;;
                    accept-aspa3|reject-aspa3)  # B12/5-108
                        _Ltb=${_Lv%% *}; _Lrest=${_Lv#* }; _Lp=${_Lrest%% *}; _Lrest2=${_Lrest#* }; _Lb=${_Lrest2%% *}; _Lrs=${_Lrest2#* }
                        aspa_table_exists "$_Ltb" || err "filter $_Lfn aspa3: tabel aspa $_Ltb belum didefinisikan (aspa-table $_Ltb)"
                        case "$_Lp" in bgp_path) ;; *) err "filter $_Lfn aspa3: PATH harus bgp_path: $_Lp" ;; esac
                        case "$_Lb" in true|false) ;; *) err "filter $_Lfn aspa3: BOOL harus true|false: $_Lb" ;; esac
                        case "$_Lrs" in ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN) ;; *) err "filter $_Lfn aspa3: hasil harus ASPA_VALID|ASPA_INVALID|ASPA_UNKNOWN: $_Lrs" ;; esac
                        printf '%sif aspa_check(%s, %s, %s) = %s then %s;\n' "$_Lpad" "$_Ltb" "$_Lp" "$_Lb" "$_Lrs" "$_Lact"
                        ;;
                    accept-match|reject-match)
                        _Lbc=$(cond_to_bird "$_Lv" "$_Lvars") || exit 33
                        printf '%sif %s then %s;\n' "$_Lpad" "$_Lbc" "$_Lact"
                        ;;
                    # --- B5: statement ---
                    set)
                        _Lsa=${_Lv%% *}; _Lsv=${_Lv#* }
                        valid_set_stmt "$_Lsa" "$_Lsv" "filter $_Lfn set" "$_Lvars"
                        _Lsat=$(var_type "$_Lvars" "$_Lsa" 2>/dev/null || true)
                        if [ "$_Lsat" = "string" ]; then _Lsvt=$(var_type "$_Lvars" "$_Lsv" 2>/dev/null || true); [ "$_Lsvt" = "string" ] || _Lsv="\"$_Lsv\""; fi
                        printf '%s%s = %s;\n' "$_Lpad" "$_Lsa" "$_Lsv"
                        ;;
                    unset)
                        valid_unset_attr "$_Lv" "filter $_Lfn unset"
                        printf '%sunset(%s);\n' "$_Lpad" "$_Lv"
                        ;;
                    var)
                        _Lvt=${_Lv%% *}; _Lvn=${_Lv#* }
                        valid_var_type "$_Lvt" "filter $_Lfn var"
                        valid_name "$_Lvn" "filter $_Lfn var"
                        printf '%s%s %s;\n' "$_Lpad" "$_Lvt" "$_Lvn"
                        ;;
                    var-set)
                        _Lts=${_Lv%% *}; _Lrest=${_Lv#* }; _Lvn=${_Lrest%% *}; _Llit=${_Lrest#* }
                        valid_set_typeset "$_Lts" "filter $_Lfn var-set"
                        valid_name "$_Lvn" "filter $_Lfn var-set"
                        valid_set_literal "$_Lts" "$_Llit" "filter $_Lfn var-set"
                        printf '%s%s set %s = %s;\n' "$_Lpad" "${_Lts%-set}" "$_Lvn" "$_Llit"
                        ;;
                    method)
                        _Lmb=$(method_to_bird "$_Lv" "$_Lvars") || exit 33
                        printf '%s%s;\n' "$_Lpad" "$_Lmb"
                        ;;
                    print|printn)  # B16/5-157/158
                        _Lpa=$(print_args_to_bird "$_Lv" "$_Lvars") || exit 33
                        printf '%s%s %s;\n' "$_Lpad" "$_La" "$_Lpa"
                        ;;
                    if)
                        _Lc=${_Lv%% *}; _Lrest=${_Lv#* }
                        case "$_Lrest" in 'then '*) _Lrest=${_Lrest#then } ;; *) err "filter $_Lfn if: butuh 'then' sesudah kondisi: $_Lv" ;; esac
                        _Lbc=$(cond_to_bird "$_Lc" "$_Lvars") || exit 33
                        case "$_Lrest" in *' else '*)
                            _Lt=${_Lrest%%' else '*}; _Le=${_Lrest#*' else '}
                            _Lbs=$(stmt_to_bird "$_Lt" "$_Lvars") || exit 33
                            _Lbe=$(stmt_to_bird "$_Le" "$_Lvars") || exit 33
                            printf '%sif %s then %s; else %s;\n' "$_Lpad" "$_Lbc" "$_Lbs" "$_Lbe" ;;
                        *)
                            _Lbs=$(stmt_to_bird "$_Lrest" "$_Lvars") || exit 33
                            printf '%sif %s then %s;\n' "$_Lpad" "$_Lbc" "$_Lbs" ;;
                        esac
                        ;;
                    if-block)
                        _Lbc=$(cond_to_bird "$_Lv" "$_Lvars") || exit 33
                        printf '%sif %s then {\n' "$_Lpad" "$_Lbc"
                        _Lstack="${_Lstack:+$_Lstack }if"; _Lpad="$_Lpad    "; _Ldepth=$((_Ldepth + 1))
                        ;;
                    else-block)
                        _Ltop=${_Lstack##* }
                        [ "$_Ltop" = "if" ] || err "filter $_Lfn else-block tanpa if-block yang terbuka (atas stack: ${_Lstack:-kosong})"
                        case "$_Lstack" in *' '*) _Lstack=${_Lstack% *} ;; *) _Lstack="" ;; esac
                        _Lpad=${_Lpad%    }
                        printf '%s} else {\n' "$_Lpad"
                        _Lstack="${_Lstack:+$_Lstack }ifelse"; _Lpad="$_Lpad    "
                        ;;
                    for-block)
                        _Lft=${_Lv%% *}; _Lfr=${_Lv#* }; _Lfv=${_Lfr%% *}; _Lfs=${_Lfr#* }
                        valid_for "$_Lft" "$_Lfv" "$_Lfs" "$_Lvars"
                        printf '%sfor %s %s in %s do {\n' "$_Lpad" "$_Lft" "$_Lfv" "$_Lfs"
                        _Lstack="${_Lstack:+$_Lstack }for"; _Lpad="$_Lpad    "; _Ldepth=$((_Ldepth + 1))
                        ;;
                    case-block)
                        _Lck=$(valid_case_expr "$_Lv" "$_Lvars") || exit 33
                        _Lckind=${_Lck%%:*}; _Lcexpr=${_Lck#*:}
                        printf '%scase %s {\n' "$_Lpad" "$_Lcexpr"
                        _Lstack="${_Lstack:+$_Lstack }case:$_Lckind:0"; _Lpad="$_Lpad    "; _Ldepth=$((_Ldepth + 1))
                        ;;
                    when)
                        _Ltop=${_Lstack##* }
                        case "$_Ltop" in 'case:'*':0'|'case:'*':1') _Lkind=${_Ltop#case:}; _Lkind=${_Lkind%:*} ;; *) err "filter $_Lfn when tanpa case-block yang terbuka (atas stack: ${_Lstack:-kosong})" ;; esac
                        _Llb=${_Lv%% *}; _Lst=${_Lv#* }
                        valid_case_label "$_Lkind" "$_Llb"
                        _Lbs=$(stmt_to_bird "$_Lst" "$_Lvars") || exit 33
                        case "$_Lstack" in *' '*) _Ls=${_Lstack% *} ;; *) _Ls="" ;; esac
                        _Lstack="${_Ls:+$_Ls }case:$_Lkind:1"
                        printf '%s%s: %s;\n' "$_Lpad" "$_Llb" "$_Lbs"
                        ;;
                    otherwise)
                        _Ltop=${_Lstack##* }
                        case "$_Ltop" in 'case:'*':0'|'case:'*':1') _Lkind=${_Ltop#case:}; _Lkind=${_Lkind%:*} ;; *) err "filter $_Lfn otherwise tanpa case-block yang terbuka (atas stack: ${_Lstack:-kosong})" ;; esac
                        _Lbs=$(stmt_to_bird "$_Lv" "$_Lvars") || exit 33
                        case "$_Lstack" in *' '*) _Ls=${_Lstack% *} ;; *) _Ls="" ;; esac
                        _Lstack="${_Ls:+$_Ls }case:$_Lkind:1"
                        printf '%selse: %s;\n' "$_Lpad" "$_Lbs"
                        ;;
                    close-block)
                        [ -n "$_Lstack" ] || err "filter $_Lfn close-block tanpa blok yang terbuka"
                        _Ltop=${_Lstack##* }
                        case "$_Ltop" in 'case:'*':0') err "filter $_Lfn case tanpa cabang (butuh minimal satu when/otherwise)" ;; esac
                        case "$_Lstack" in *' '*) _Lstack=${_Lstack% *} ;; *) _Lstack="" ;; esac
                        _Lpad=${_Lpad%    }; _Ldepth=$((_Ldepth - 1))
                        printf '%s}\n' "$_Lpad"
                        ;;
                esac
            done < "$_Lftmp"
            rm -f "$_Lftmp"
            [ -z "$_Lstack" ] || err "filter $_Lfn: blok tidak ditutup: $_Lstack"
            echo "    reject;"
            echo "}"
            echo ""
        done
        # --- neighbors ---
        for _nip in $(grep '^neighbor ' "$CONF" 2>/dev/null | awk '{print $2}' | sort -u); do
            _ras=$(get_field "$_nip" remote-as)
            [ -n "$_ras" ] || { echo "Warning: neighbor $_nip tanpa remote-as, dilewati" >&2; continue; }
            _desc=$(grep "^neighbor $_nip description " "$CONF" 2>/dev/null | head -1 | sed 's/^neighbor [^ ]* description //')
            _imp=$(get_field "$_nip" import)
            _exp=$(get_field "$_nip" export)
            _lp=$(get_field "$_nip" local-pref)
            _med=$(get_field "$_nip" med)
            _pre=$(get_field "$_nip" prepend)
            _comm=$(get_field "$_nip" community)
            _bfd=$(get_field "$_nip" bfd)
            _mode=$(get_field "$_nip" mode)
            _org=$(get_field "$_nip" origin)
            _enh=$(get_field "$_nip" export-next-hop)
            _cdel=$(get_field "$_nip" community-del)
            _edel=$(get_field "$_nip" ext-community-del)
            _ldel=$(get_field "$_nip" large-community-del)
            # nama protocol harus valid BIRD (huruf/angka/_), dari IP
            # (bird_ident: '.' IPv4 dan ':' IPv6 jadi '_')
            _pname=$(bird_ident "bgp_$_nip")
            _from=$(get_field "$_nip" from)
            if [ -n "$_from" ]; then
                echo "protocol bgp $_pname from $(bird_ident "$_from") {"
            else
                echo "protocol bgp $_pname {"
            fi
            [ -n "$_desc" ] && echo "    description \"$_desc\";"
            echo "    local as $_las;"
            # B1: mode internal|external menggantikan `neighbor X as N`
            case "$_mode" in
                internal) echo "    neighbor $_nip internal;" ;;
                external) echo "    neighbor $_nip external;" ;;
                *) echo "    neighbor $_nip as $_ras;" ;;
            esac
            # BFD: ikat sesi BGP ke protocol bfd (butuh section BFD —
            # sudah di-generate di atas bila ada neighbor dengan bfd).
            case "$_bfd" in
                on) echo "    bfd on;" ;;
                graceful) echo "    bfd graceful;" ;;
            esac
            # --- B1: opsi protocol-level (HANYA yang diset; urutan = docs
            # Bab 6.4). Tanpa opsi baru, blok ini kosong -> output
            # byte-identik dengan sebelum B1 (anchor regression). ---
            # Guard kombinasi yang ditolak / dilarang docs:
            _mnh=0; has_nbr "$_nip" multihop && _mnh=1
            _chk=$(get_field "$_nip" check-link)
            [ "$_mnh" = "1" ] && [ "$_chk" = "on" ] && err "neighbor $_nip: check link tidak bisa dipakai dengan multihop (docs Bab 6.4)"
            has_nbr "$_nip" interface && [ "$_mnh" = "1" ] && err "neighbor $_nip: interface hanya untuk sesi direct, bukan multihop (docs Bab 6.4)"
            _rrcid=$(get_field "$_nip" rr-cluster-id)
            if [ -n "$_rrcid" ]; then
                has_nbr "$_nip" rr-client || err "neighbor $_nip: rr cluster id butuh rr-client (instance ini bukan route reflector)"
            fi
            _nhs=$(get_field "$_nip" next-hop-self)
            _nhk=$(get_field "$_nip" next-hop-keep)
            case "$_nhs" in on|ibgp|ebgp)
                case "$_nhk" in on|ibgp|ebgp) err "neighbor $_nip: next hop self dan next hop keep tidak bisa dipakai bersamaan" ;; esac ;;
            esac
            _tts=$(get_field "$_nip" ttl-security)
            if [ "$_tts" = "on" ] && [ "$_mnh" = "1" ]; then
                _mhv=$(get_field "$_nip" multihop)
                [ -z "$_mhv" ] && echo "Warning: neighbor $_nip ttl-security on + multihop tanpa jumlah hop — hitung TTL harapan bisa salah (docs Bab 6.4)" >&2
            fi
            _v=$(get_field "$_nip" local-ip); [ -n "$_v" ] && echo "    local $_v;"
            _v=$(get_field "$_nip" local-port); [ -n "$_v" ] && echo "    local port $_v;"
            _v=$(get_field "$_nip" source-address); [ -n "$_v" ] && echo "    source address $_v;"
            _v=$(get_field "$_nip" port); [ -n "$_v" ] && echo "    neighbor $_nip port $_v;"
            _v=$(get_field "$_nip" interface); [ -n "$_v" ] && echo "    interface \"$_v\";"
            has_nbr "$_nip" direct && echo "    direct;"
            if [ "$_mnh" = "1" ]; then
                _v=$(get_field "$_nip" multihop)
                if [ -n "$_v" ]; then echo "    multihop $_v;"; else echo "    multihop;"; fi
            fi
            emit_sw "strict bind" "$(get_field "$_nip" strict-bind)"
            emit_sw "free bind" "$(get_field "$_nip" free-bind)"
            emit_sw "check link" "$(get_field "$_nip" check-link)"
            emit_sw "ttl security" "$(get_field "$_nip" ttl-security)"
            _v=$(get_field "$_nip" password); [ -n "$_v" ] && echo "    password \"$_v\";"
            emit_sw "setkey" "$(get_field "$_nip" setkey)"
            emit_sw "passive" "$(get_field "$_nip" passive)"
            _v=$(get_field "$_nip" confederation); [ -n "$_v" ] && echo "    confederation $_v;"
            emit_sw "confederation member" "$(get_field "$_nip" confederation-member)"
            has_nbr "$_nip" rr-client && echo "    rr client;"
            _v=$(get_field "$_nip" rr-cluster-id); [ -n "$_v" ] && echo "    rr cluster id $_v;"
            has_nbr "$_nip" rs-client && echo "    rs client;"
            emit_sw "allow bgp_local_pref" "$(get_field "$_nip" allow-local-pref)"
            emit_sw "allow bgp_med" "$(get_field "$_nip" allow-med)"
            if has_nbr "$_nip" allow-local-as; then
                _v=$(get_field "$_nip" allow-local-as)
                if [ -n "$_v" ]; then echo "    allow local as $_v;"; else echo "    allow local as;"; fi
            fi
            emit_sw "allow as sets" "$(get_field "$_nip" allow-as-sets)"
            emit_sw "enforce first as" "$(get_field "$_nip" enforce-first-as)"
            emit_sw "enable route refresh" "$(get_field "$_nip" enable-route-refresh)"
            emit_sw "require route refresh" "$(get_field "$_nip" require-route-refresh)"
            emit_sw "enable enhanced route refresh" "$(get_field "$_nip" enable-enhanced-rr)"
            emit_sw "require enhanced route refresh" "$(get_field "$_nip" require-enhanced-rr)"
            emit_sw "graceful restart" "$(get_field "$_nip" graceful-restart)"
            emit_sw "graceful restart time" "$(get_field "$_nip" graceful-restart-time)"
            emit_sw "require graceful restart" "$(get_field "$_nip" require-graceful-restart)"
            emit_sw "long lived graceful restart" "$(get_field "$_nip" llgr)"
            emit_sw "long lived stale time" "$(get_field "$_nip" llgr-stale-time)"
            emit_sw "require long lived graceful restart" "$(get_field "$_nip" require-llgr)"
            emit_sw "interpret communities" "$(get_field "$_nip" interpret-communities)"
            emit_sw "enable as4" "$(get_field "$_nip" enable-as4)"
            emit_sw "require as4" "$(get_field "$_nip" require-as4)"
            emit_sw "enable extended messages" "$(get_field "$_nip" enable-extended-messages)"
            emit_sw "require extended messages" "$(get_field "$_nip" require-extended-messages)"
            emit_sw "capabilities" "$(get_field "$_nip" capabilities)"
            emit_sw "advertise hostname" "$(get_field "$_nip" advertise-hostname)"
            emit_sw "require hostname" "$(get_field "$_nip" require-hostname)"
            emit_sw "disable after error" "$(get_field "$_nip" disable-after-error)"
            _v=$(get_field "$_nip" disable-after-cease-flags)
            if [ -n "$_v" ]; then
                _fl=$(echo "$_v" | sed 's/-/ /g; s/,/, /g')
                echo "    disable after cease { $_fl };"
            else
                emit_sw "disable after cease" "$(get_field "$_nip" disable-after-cease)"
            fi
            emit_sw "hold time" "$(get_field "$_nip" hold-time)"
            emit_sw "min hold time" "$(get_field "$_nip" min-hold-time)"
            emit_sw "startup hold time" "$(get_field "$_nip" startup-hold-time)"
            emit_sw "keepalive time" "$(get_field "$_nip" keepalive-time)"
            emit_sw "min keepalive time" "$(get_field "$_nip" min-keepalive-time)"
            emit_sw "send hold time" "$(get_field "$_nip" send-hold-time)"
            emit_sw "connect delay time" "$(get_field "$_nip" connect-delay-time)"
            emit_sw "connect retry time" "$(get_field "$_nip" connect-retry-time)"
            _v=$(get_field "$_nip" error-wait-time)
            if [ -n "$_v" ]; then
                _ew=$(echo "$_v" | sed 's/,/, /')
                echo "    error wait time $_ew;"
            fi
            emit_sw "error forget time" "$(get_field "$_nip" error-forget-time)"
            emit_sw "path metric" "$(get_field "$_nip" path-metric)"
            emit_sw "med metric" "$(get_field "$_nip" med-metric)"
            emit_sw "deterministic med" "$(get_field "$_nip" deterministic-med)"
            emit_sw "igp metric" "$(get_field "$_nip" igp-metric)"
            emit_sw "prefer older" "$(get_field "$_nip" prefer-older)"
            emit_sw "default bgp_med" "$(get_field "$_nip" default-med)"
            emit_sw "default bgp_local_pref" "$(get_field "$_nip" default-local-pref)"
            _v=$(get_field "$_nip" local-role); [ -n "$_v" ] && echo "    local role $_v;"
            emit_sw "require roles" "$(get_field "$_nip" require-roles)"
            has_nbr "$_nip" disabled && echo "    disabled;"
            # --- B6: opsi protocol-level (Bab 3.4-2/3/4/9) ---
            _v=$(get_field "$_nip" protocol-router-id); [ -n "$_v" ] && echo "    router id $_v;"
            _v=$(get_field "$_nip" debug)
            if [ -n "$_v" ]; then
                case "$_v" in all|off) echo "    debug $_v;" ;; *) echo "    debug { $(echo "$_v" | sed 's/,/, /g') };" ;; esac
            fi
            _v=$(get_field "$_nip" mrtdump)
            if [ -n "$_v" ]; then
                case "$_v" in all|off) echo "    mrtdump $_v;" ;; *) echo "    mrtdump { $(echo "$_v" | sed 's/,/, /g') };" ;; esac
            fi
            # tx class/dscp TIDAK di-emit di BGP (BIRD 2.20: hanya blok interface
            # OSPF/RIP/Babel; setter menolak tx-class/tx-dscp — lihat cmd_neighbor_set).
            # source address: pakai alamat lokal yang se-subnet dgn neighbor bila ada
            # (sederhana: tidak dipaksa; BIRD pilih otomatis dari routing table)
            # import/export WAJIB di dalam channel ipv4 { } di BIRD 2
            # (import/export langsung di protocol block ditolak parser:
            # "unexpected IMPORT"). Atribut export (local-pref/MED/
            # prepend/community) diterapkan lewat inline export filter.
            echo "    ipv4 {"
            # import
            case "$_imp" in
                all|"") echo "        import all;" ;;
                none) echo "        import none;" ;;
                filter)
                    _fname=$(grep "^neighbor $_nip import " "$CONF" | awk '{print $5}')
                    echo "        import filter $(bird_ident "$_fname");" ;;
                where)
                    _wexpr=$(grep "^neighbor $_nip import " "$CONF" | awk '{print $5}')
                    _wbird=$(cond_to_bird "$_wexpr" "") || exit 33
                    echo "        import where $_wbird;" ;;
            esac
            # export
            _has_attr=""
            [ -n "$_lp" ] || [ -n "$_med" ] || [ -n "$_pre" ] || [ -n "$_comm" ] || [ -n "$_org" ] || [ -n "$_enh" ] || [ -n "$_cdel" ] || [ -n "$_edel" ] || [ -n "$_ldel" ] && _has_attr=1
            case "$_exp" in
                none) echo "        export none;" ;;
                filter)
                    _fname=$(grep "^neighbor $_nip export " "$CONF" | awk '{print $5}')
                    echo "        export filter $(bird_ident "$_fname");"
                    [ -n "$_has_attr" ] && echo "        # NOTE: atribut local-pref/MED/prepend/community diabaikan (export memakai filter $_fname)" ;;
                where)
                    _wexpr=$(grep "^neighbor $_nip export " "$CONF" | awk '{print $5}')
                    _wbird=$(cond_to_bird "$_wexpr" "") || exit 33
                    echo "        export where $_wbird;"
                    [ -n "$_has_attr" ] && echo "        # NOTE: atribut local-pref/MED/prepend/community diabaikan (export memakai where)" ;;
                all|"" )
                    if [ -n "$_has_attr" ]; then
                        echo "        export filter {"
                        [ -n "$_lp" ] && echo "            bgp_local_pref = $_lp;"
                        [ -n "$_med" ] && echo "            bgp_med = $_med;"
                        case "$_org" in
                            igp) echo "            bgp_origin = ORIGIN_IGP;" ;;
                            egp) echo "            bgp_origin = ORIGIN_EGP;" ;;
                            incomplete) echo "            bgp_origin = ORIGIN_INCOMPLETE;" ;;
                        esac
                        if [ -n "$_pre" ]; then
                            # prepend() hanya terima 1 argumen (AS); untuk
                            # prepend N kali, panggil N kali.
                            _i=0
                            while [ "$_i" -lt "$_pre" ]; do
                                echo "            bgp_path.prepend($_las);"
                                _i=$((_i + 1))
                            done
                        fi
                        if [ -n "$_comm" ]; then
                            _c1=$(echo "$_comm" | cut -d: -f1)
                            _c2=$(echo "$_comm" | cut -d: -f2)
                            echo "            bgp_community.add(($_c1, $_c2));"
                        fi
                        if [ -n "$_cdel" ]; then
                            _c1=$(echo "$_cdel" | cut -d: -f1)
                            _c2=$(echo "$_cdel" | cut -d: -f2)
                            echo "            bgp_community.delete(($_c1, $_c2));"
                        fi
                        if [ -n "$_edel" ]; then
                            _ek=$(echo "$_edel" | cut -d: -f1)
                            _ea=$(echo "$_edel" | cut -d: -f2)
                            _en=$(echo "$_edel" | cut -d: -f3)
                            echo "            bgp_ext_community.delete(($_ek, $_ea, $_en));"
                        fi
                        if [ -n "$_ldel" ]; then
                            _la=$(echo "$_ldel" | cut -d: -f2)
                            _lx=$(echo "$_ldel" | cut -d: -f3)
                            _ln=$(echo "$_ldel" | cut -d: -f4)
                            echo "            bgp_large_community.delete(($_la, $_lx, $_ln));"
                        fi
                        [ -n "$_enh" ] && echo "            bgp_next_hop = $_enh;"
                        echo "            accept;"
                        echo "        };"
                    else
                        echo "        export all;"
                    fi
                    ;;
            esac
            # --- B1: opsi channel ipv4 (HANYA yang diset; urutan = docs) ---
            # Guard: aksi limit tanpa limit-nya tidak bermakna.
            _v=$(get_field "$_nip" import-limit-action); _l=$(get_field "$_nip" import-limit)
            [ -n "$_v" ] && [ -z "$_l" ] && err "neighbor $_nip: import-limit-action tanpa import-limit"
            _v=$(get_field "$_nip" receive-limit-action); _l=$(get_field "$_nip" receive-limit)
            [ -n "$_v" ] && [ -z "$_l" ] && err "neighbor $_nip: receive-limit-action tanpa receive-limit"
            _v=$(get_field "$_nip" export-limit-action); _l=$(get_field "$_nip" export-limit)
            [ -n "$_v" ] && [ -z "$_l" ] && err "neighbor $_nip: export-limit-action tanpa export-limit"
            # --- B5: opsi channel ipv4 (Bab 3.5-3 preference, 3.5-6 keep filtered) ---
            _v=$(get_field "$_nip" import-keep-filtered); [ -n "$_v" ] && echo "        import keep filtered $_v;"
            _v=$(get_field "$_nip" channel-preference); [ -n "$_v" ] && echo "        preference $_v;"
            _emit_chan_sw() { # _emit_chan_sw <opsi-BIRD> <field> — 8 spasi indent
                _cv=$(get_field "$_nip" "$2")
                [ -n "$_cv" ] && echo "        $1 $_cv;"
            }
            _emit_chan_sw "mandatory" mandatory
            _emit_chan_sw "next hop keep" next-hop-keep
            _emit_chan_sw "next hop self" next-hop-self
            _v=$(get_field "$_nip" next-hop-address); [ -n "$_v" ] && echo "        next hop address $_v;"
            _emit_chan_sw "gateway" gateway
            _v=$(get_field "$_nip" igp-table); [ -n "$_v" ] && echo "        igp table $_v;"
            _v=$(get_field "$_nip" igp-table6); [ -n "$_v" ] && echo "        igp table $_v;"
            _emit_chan_sw "import table" import-table
            _emit_chan_sw "export table" export-table
            _emit_chan_sw "secondary" secondary
            _emit_chan_sw "validate" validate
            _v=$(get_field "$_nip" base-table); [ -n "$_v" ] && echo "        base table $_v;"
            _emit_chan_sw "extended next hop" extended-next-hop
            _emit_chan_sw "require extended next hop" require-extended-next-hop
            _emit_chan_sw "add paths" add-paths
            _emit_chan_sw "require add paths" require-add-paths
            _emit_chan_sw "aigp" aigp
            _emit_chan_sw "cost" cost
            _emit_chan_sw "graceful restart" channel-graceful-restart
            _emit_chan_sw "long lived graceful restart" channel-llgr
            _emit_chan_sw "long lived stale time" channel-llgr-stale-time
            _v=$(get_field "$_nip" channel-table); [ -n "$_v" ] && echo "        table $_v;"
            _emit_limit() { # _emit_limit <opsi-BIRD> <field-limit> <field-action>
                _lv=$(get_field "$_nip" "$2")
                [ -z "$_lv" ] && return 0
                _av=$(get_field "$_nip" "$3")
                if [ -n "$_av" ]; then echo "        $1 $_lv action $_av;"; else echo "        $1 $_lv;"; fi
            }
            _emit_limit "import limit" import-limit import-limit-action
            _emit_limit "receive limit" receive-limit receive-limit-action
            _emit_limit "export limit" export-limit export-limit-action
            echo "    };"
            # --- B6: channel tambahan (ipv6/multicast/mpls/vpn/flow) ---
            # Hanya channel yang punya field di intent yang di-emit;
            # anchor (ipv4 saja) tetap byte-identik.
            for _ck in ipv6 mc4 mc6 mpls4 mpls6 vpn4 vpn6 vpn4mc vpn6mc flow4 flow6; do
                chan_has "$_nip" "$_ck" && _emit_bgp_channel "$_nip" "$_ck"
            done
            # --- B6: blok mpls { } (channel MPLS-aware, EKSPERIMENTAL) ---
            _md=$(get_field "$_nip" mpls-domain); _mlr=$(get_field "$_nip" mpls-label-range); _mlp=$(get_field "$_nip" mpls-label-policy)
            if [ -n "$_md" ] || [ -n "$_mlr" ] || [ -n "$_mlp" ]; then
                if [ "$_mlp" = "vrf" ]; then
                    { chan_has "$_nip" vpn4 || chan_has "$_nip" vpn6; } || err "neighbor $_nip: label policy vrf hanya valid di protokol L3VPN (butuh channel vpn4/vpn6)"
                fi
                # Guard: blok mpls butuh tabel mpls (BIRD: "Routing table
                # not specified" bila tidak ada tabel mpls global maupun
                # di channel). Tabel mpls didefinisikan di global.
                _gconf="$STATE_ROOT/bird-global.conf"
                if [ -f "$_gconf" ]; then
                    grep -q "^table mpls " "$_gconf" 2>/dev/null || err "neighbor $_nip: blok mpls butuh tabel mpls — buat dulu (global -> table-add mpls <nama>)"
                else
                    err "neighbor $_nip: blok mpls butuh tabel mpls — buat dulu (global -> table-add mpls <nama>)"
                fi
                if [ -n "$_mlr" ]; then
                    _gconf="$STATE_ROOT/bird-global.conf"
                    if [ -f "$_gconf" ]; then
                        if [ -n "$_md" ]; then
                            grep -q "^mpls label-range $_md $_mlr " "$_gconf" 2>/dev/null || err "neighbor $_nip: mpls label range $_mlr tidak ada di domain $_md (bird-global.conf)"
                        else
                            grep -q "^mpls label-range [^ ]* $_mlr " "$_gconf" 2>/dev/null || err "neighbor $_nip: mpls label range $_mlr tidak didefinisikan di bird-global.conf"
                        fi
                    fi
                fi
                echo "    mpls {"
                [ -n "$_md" ] && echo "        domain $(bird_ident "$_md");"
                [ -n "$_mlr" ] && echo "        label range $(bird_ident "$_mlr");"
                [ -n "$_mlp" ] && echo "        label policy $_mlp;"
                echo "    };"
            fi
            echo "}"
            echo ""
        done
        # --- B1: dynamic BGP template (satu protocol bgp_dyn menampung
        # SEMUA neighbor-range; import/export all; dynamic name/digits
        # hanya bermakna di dalam template ini) ---
        if grep -q '^neighbor-range ' "$CONF" 2>/dev/null; then
            _dyn=$(grep '^dynamic-name ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
            _dyd=$(grep '^dynamic-name-digits ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
            echo "protocol bgp bgp_dyn {"
            echo "    local as $_las;"
            grep '^neighbor-range ' "$CONF" | awk '{print $2}' | while read -r _r; do
                echo "    neighbor range $_r;"
            done
            [ -n "$_dyn" ] && echo "    dynamic name \"$_dyn\";"
            [ -n "$_dyd" ] && echo "    dynamic name digits $_dyd;"
            echo "    ipv4 {"
            echo "        import all;"
            echo "        export all;"
            echo "    };"
            echo "}"
            echo ""
        fi
        # --- networks: bila ada `network`, pastikan ada export filter yang
        # menerimanya. Bila neighbor export=all, network sudah teriklankan
        # (dari kernel/direct). Bila export=filter, user wajib filter-nya
        # menerima prefix ini. Di sini kita hanya mencatat sebagai komentar.
        for _net in $(grep '^network ' "$CONF" 2>/dev/null | awk '{print $2}'); do
            echo "# network $_net (diiklankan bila ada di tabel routing + lolos export filter)"
        done
    } > "$_tmp" || die "cannot write $_tmp"
    mv "$_tmp" "$SECTION" || die "cannot write $SECTION"
    chmod 644 "$SECTION" 2>/dev/null || true
    echo "BGP section ditulis: $SECTION"
    # router-id adalah setting GLOBAL BIRD (bukan per-protocol).
    # Terapkan ke bird.conf di luar section BGP (sed, idempotent).
    if [ -n "$_rid" ]; then
        _conf="/usr/local/etc/bird.conf"
        [ -f "$_conf" ] || _conf="/etc/bird/bird.conf"
        if [ -f "$_conf" ]; then
            if grep -q "^router id " "$_conf" 2>/dev/null; then
                sed -i '' "s/^router id .*/router id $_rid;/" "$_conf" 2>/dev/null || \
                    sed -i "s/^router id .*/router id $_rid;/" "$_conf" 2>/dev/null || true
            elif grep -q "^# router id " "$_conf" 2>/dev/null; then
                sed -i '' "s/^# router id .*/router id $_rid;/" "$_conf" 2>/dev/null || \
                    sed -i "s/^# router id .*/router id $_rid;/" "$_conf" 2>/dev/null || true
            else
                printf 'router id %s;\n' "$_rid" >> "$_conf"
            fi
            echo "BIRD router-id global set to $_rid"
        fi
    fi
    # render ke bird.conf + birdc configure (pakai mekanisme titian-bird.sh)
    _birdsh="$(dirname "$0")/titian-bird.sh"
    if [ -x "$_birdsh" ]; then
        "$_birdsh" generate bgp || exit 33
    else
        echo "Warning: $_birdsh tidak ditemukan; section hanya ditulis, belum di-apply" >&2
    fi
}

cmd_status() {
    touch_conf
    echo "--- bgp.conf (intent) ---"
    cat "$CONF"
    echo "--- bird.d/bgp.conf (section, bila ada) ---"
    [ -f "$SECTION" ] && cat "$SECTION" || echo "(belum di-generate)"
}

case "$1" in
    set-router-id) shift; cmd_set_router_id "$@" ;;
    set-local-as) shift; cmd_set_local_as "$@" ;;
    neighbor-add) shift; cmd_neighbor_add "$@" ;;
    neighbor-touch) shift; cmd_neighbor_touch "$@" ;;
    neighbor-del) shift; cmd_neighbor_del "$@" ;;
    neighbor-set) shift; cmd_neighbor_set "$@" ;;
    neighbor-unset) shift; cmd_neighbor_unset "$@" ;;
    neighbor-chan-set) shift; cmd_neighbor_chan_set "$@" ;;
    neighbor-chan-unset) shift; cmd_neighbor_chan_unset "$@" ;;
    channel-del) shift; cmd_channel_del "$@" ;;
    neighbor-range-add) shift; cmd_neighbor_range_add "$@" ;;
    neighbor-range-del) shift; cmd_neighbor_range_del "$@" ;;
    dynamic-name-set) shift; cmd_dynamic_name_set "$@" ;;
    dynamic-name-digits-set) shift; cmd_dynamic_name_digits_set "$@" ;;
    dynamic-name-del) cmd_dynamic_name_del ;;
    dynamic-name-digits-del) cmd_dynamic_name_digits_del ;;
    attribute-bgp-add) shift; cmd_attribute_bgp_add "$@" ;;
    attribute-bgp-del) shift; cmd_attribute_bgp_del "$@" ;;
    network-add) shift; cmd_network_add "$@" ;;
    network-del) shift; cmd_network_del "$@" ;;
    filter-add) shift; cmd_filter_add "$@" ;;
    filter-del) shift; cmd_filter_del "$@" ;;
    filter-set) shift; cmd_filter_set "$@" ;;
    filter-unset) shift; cmd_filter_unset "$@" ;;
    filter-var) shift; cmd_filter_var "$@" ;;
    filter-var-set) shift; cmd_filter_var_set "$@" ;;
    filter-method) shift; cmd_filter_method "$@" ;;
    filter-if) shift; cmd_filter_if "$@" ;;
    filter-block) shift; cmd_filter_block "$@" ;;
    filter-print) shift; cmd_filter_print "$@" ;;
    define-int-add) shift; cmd_define_int_add "$@" ;;
    define-int-del) shift; cmd_define_int_del "$@" ;;
    attribute-int-add) shift; cmd_attribute_int_add "$@" ;;
    attribute-int-del) shift; cmd_attribute_int_del "$@" ;;
    roa-table-add) shift; cmd_roa_table_add "$@" ;;
    roa-table-del) shift; cmd_roa_table_del "$@" ;;
    aspa-table-add) shift; cmd_aspa_table_add "$@" ;;
    aspa-table-del) shift; cmd_aspa_table_del "$@" ;;
    cond-to-bird) shift; cmd_cond_to_bird "$@" ;;
    stmt-to-bird) shift; cmd_stmt_to_bird "$@" ;;
    generate) cmd_generate ;;
    show|status) cmd_status ;;
    *) echo "Usage: $0 {set-router-id IP|set-local-as AS|neighbor-add IP AS|neighbor-del IP|neighbor-set IP FIELD [VALUE]|neighbor-unset IP FIELD|channel-del IP KEY|neighbor-range-add PREFIX|neighbor-range-del PREFIX|dynamic-name-set TEXT|dynamic-name-digits-set N|attribute-bgp-add NUM NAME|attribute-bgp-del NUM|network-add PREFIX|network-del PREFIX|filter-add NAME accept|reject VALUE|filter-del NAME|filter-set NAME ATTR VALUE|filter-unset NAME ATTR|filter-var NAME TYPE VAR|filter-var-set NAME TYPESET VAR LITERAL|filter-method NAME CALL|filter-if NAME COND THEN [ELSE]|filter-block NAME if|else|for|case|when|otherwise|close [ARGS]|filter-print NAME print|printn ARGS|define-int-add NAME N|define-int-del NAME|attribute-int-add NAME|attribute-int-del NAME|roa-table-add NAME [v4|v6]|roa-table-del NAME|aspa-table-add NAME|aspa-table-del NAME|cond-to-bird COND|stmt-to-bird STMT|generate|show}" >&2; exit 2 ;;
esac
