#!/bin/sh
# TITIAN — firewall + NAT terpadu (Linux nftables + FreeBSD pf).
# Model: SATU file netstate /opt/titian/etc/netstate/firewall.rules
# (satu rule per baris, urutan dibuat = prioritas) = sumber kebenaran.
# Setiap perubahan = tulis netstate + REBUILD backend penuh dari
# netstate (bukan tambah/hapus satu rule live) — jadi live selalu sama
# dengan netstate. Check-before-load (nft -c / pfctl -n) membuat gagal
# apply TIDAK mengubah live; netstate dipulihkan dari backup.
#
# Bentuk rule (kanonis, posisi tetap — PTYPE tree memaksa bentuk ini):
#   filter <forward|input|output> <permit|deny> <tcp|udp|icmp|all>
#          <src-cidr|any> <dst-cidr|any> <sport|any> <dport|any>
#          <in-iface|any> <out-iface|any>
#   snat <srcnet-cidr> <masquerade|addr> <out-iface|any>
#   dnat <tcp|udp> <in-iface> <dport> <to-addr> <to-port|same>
# Rule diidentifikasi ISI (bukan ID): `no` form = sintaks lengkap yang
# sama; duplikat ditolak sebagai "sudah ada" (exit 0, replay-safe).
#
# Semantik (didokumentasikan di help + panduan §20, JANGAN diubah diam):
#   - IPv4 SAJA v1. NAT first-match per chain (nft) / quick (pf).
#   - Forward default DENY: nft = policy drop + established/related
#     accept pertama; pf = trailing `block in quick on <iface> all`
#     per in-iface rule forward (pf stateful default, tanpa padanan
#     established). Input/output default ACCEPT (tidak pernah mengunci
#     manajemen yang sudah ada).
#   - Filter cocok pre-NAT untuk sumber (forward/output) dan post-NAT
#     untuk tujuan DNAT (prerouting/rdr jalan sebelum filter) — SAMA
#     kedua backend. Karena itu DNAT selalu butuh forward permit ke
#     tujuan TERJEMAHAN (bukan ke port publik).
#   - Perbedaan backend yang DITOLAK LANTANG (bukan diabaikan):
#     [F] filter out-iface (pf tidak bisa mencocokkan iface keluar
#         pada satu rule filter); [F] filter tanpa in/out iface
#         (pf tanpa `on` berlaku ke SEMUA interface termasuk mgmt);
#     [F] snat tanpa out; [F] masquerade tanpa out (alamat diambil
#         dari iface itu); [F] dnat proto selain tcp/udp.
#   - Guard mgmt/PtP: iface rute default (mgmt) selalu ditolak sebagai
#     in/out; file /opt/titian/etc/protected-ifaces (satu nama/baris,
#     kosong default) menambah daftar tolak (diisi uji lab dengan
#     nama mgmt + PtP; dihapus saat cleanup).
#   - Konflik NAT ditolak: snat (srcnet,out) sama target beda;
#     dnat (proto,in,dport) sama target beda. Filter overlap
#     DIIZINKAN (urutan memutuskan).
#   - pf: rule ber-iface-hilang DILEWATI dengan warning saat apply
#     (pfctl gagal load bila nama iface tidak ada); nft memuat semua
#     nama apa adanya.
# POSIX sh (jalan di dash Debian dan sh FreeBSD).
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_DIR=${TITIAN_STATE_DIR:-$ROOT/etc/netstate}
RULES="$STATE_DIR/firewall.rules"
PROT="$ROOT/etc/protected-ifaces"
PF_ANCHOR_FILE=/etc/pf.titian.conf

err() { echo "Error(firewall): $*" >&2; exit 33; }
warn() { echo "Warning(firewall): $*" >&2; }

valid_v4() {
    local rest o i
    rest=$1
    for i in 1 2 3 4; do
        case "$rest" in
            *.*) o=${rest%%.*}; rest=${rest#*.} ;;
            *)   o=$rest; rest="" ;;
        esac
        case "$o" in ''|*[!0-9]*) return 1 ;; esac
        if [ "$o" -gt 255 ] 2>/dev/null; then return 1; fi
        if [ "$i" -eq 4 ] && [ -n "$rest" ]; then return 1; fi
    done
    case "$1" in *.*.*.*) return 0 ;; *) return 1 ;; esac
}

valid_cidr() {
    # $1 = A.B.C.D/N (N 0-32)
    local addr mask
    case "$1" in
        */*) addr=${1%%/*}; mask=${1##*/} ;;
        *) return 1 ;;
    esac
    valid_v4 "$addr" || return 1
    case "$mask" in ''|*[!0-9]*) return 1 ;; esac
    [ "$mask" -ge 0 ] 2>/dev/null && [ "$mask" -le 32 ] 2>/dev/null
}

valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

iface_exists() {
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$1" >/dev/null 2>&1
    else
        [ -d "/sys/class/net/$1" ]
    fi
}

default_iface() {
    # iface rute default = mgmt (kedua guest terbukti: enp1s0 / vtnet0)
    if [ "$OS" = "FreeBSD" ]; then
        netstat -rn 2>/dev/null | awk '$1=="default" {print $NF; exit}'
    else
        ip route show default 2>/dev/null | awk '{print $5; exit}'
    fi
}

check_iface() {
    # $1=iface $2=boleh-any(0/1) — tolak: tidak ada / mgmt / terproteksi
    local ifc=$1 d
    if [ "$ifc" = "any" ]; then
        [ "$2" = "1" ] && return 0
        err "iface 'any' tidak diizinkan di sini (lihat help: batas FreeBSD)"
    fi
    iface_exists "$ifc" || err "interface tidak ada: $ifc (lihat 'show interfaces')"
    d=$(default_iface)
    if [ -n "$d" ] && [ "$ifc" = "$d" ]; then
        err "interface $ifc adalah mgmt (rute default) — TIDAK BOLEH dipakai rule firewall/NAT"
    fi
    if [ -f "$PROT" ] && grep -qx "$ifc" "$PROT" 2>/dev/null; then
        err "interface $ifc terproteksi (daftar $PROT) — TIDAK BOLEH dipakai rule firewall/NAT"
    fi
}

rules_backup() { cp -f "$RULES" "$RULES.bak" 2>/dev/null || true; }
rules_restore() { if [ -f "$RULES.bak" ]; then mv -f "$RULES.bak" "$RULES"; else rm -f "$RULES"; fi; }

rule_add() {
    # $* = baris rule kanonis — tambah bila belum ada (dup = pesan, exit 0)
    local line="$*"
    mkdir -p "$STATE_DIR" 2>/dev/null
    touch "$RULES" 2>/dev/null
    if grep -qxF "$line" "$RULES" 2>/dev/null; then
        echo "firewall: rule sudah ada (tidak ditambah lagi): $line"
        return 0
    fi
    rules_backup
    echo "$line" >> "$RULES"
    if ! apply_live; then
        rules_restore
        err "apply backend GAGAL — netstate dipulihkan, live tidak berubah"
    fi
    echo "firewall: rule ditambah: $line"
}

rule_del() {
    # $* = baris rule kanonis — hapus bila ada (absen = pesan, exit 0)
    local line="$*" tmp
    if [ ! -f "$RULES" ] || ! grep -qxF "$line" "$RULES" 2>/dev/null; then
        echo "firewall: rule tidak ada (tidak ada yang dihapus): $line"
        return 0
    fi
    rules_backup
    tmp="$RULES.tmp"
    grep -vxF "$line" "$RULES" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$RULES"
    if ! apply_live; then
        rules_restore
        err "apply backend GAGAL — netstate dipulihkan, live tidak berubah"
    fi
    echo "firewall: rule dihapus: $line"
}

# ---------------- validasi + add/del per jenis ----------------

add_filter() {
    # $1..$9 = chain action proto src dst sport dport in out
    local chain=$1 action=$2 proto=$3 src=$4 dst=$5 sport=$6 dport=$7 in=$8 out=$9
    case "$chain" in forward|input|output) ;; *) err "chain tidak dikenal: $chain" ;; esac
    case "$action" in permit|deny) ;; *) err "aksi tidak dikenal: $action" ;; esac
    case "$proto" in tcp|udp|icmp|all) ;; *) err "proto tidak dikenal: $proto" ;; esac
    if [ "$src" != "any" ]; then valid_cidr "$src" || err "src harus CIDR atau any: $src"; fi
    if [ "$dst" != "any" ]; then valid_cidr "$dst" || err "dst harus CIDR atau any: $dst"; fi
    case "$proto" in
        tcp|udp)
            [ "$sport" != "any" ] && { valid_port "$sport" || err "sport di luar 1-65535: $sport"; }
            [ "$dport" != "any" ] && { valid_port "$dport" || err "dport di luar 1-65535: $dport"; }
            ;;
        *)
            [ "$sport" != "any" ] || [ "$dport" != "any" ] && err "proto $proto tidak memakai port (pakai any)"
            ;;
    esac
    if [ "$OS" = "FreeBSD" ]; then
        [ "$out" != "any" ] && err "FreeBSD: filter tidak bisa mencocokkan out-iface (pf tidak punya padanannya) — pakai in saja"
        case "$chain" in
            forward|input) check_iface "$in" 0 ;;
            output) check_iface "$out" 0 ;;
        esac
    else
        [ "$in" != "any" ] && check_iface "$in" 1
        [ "$out" != "any" ] && check_iface "$out" 1
    fi
    rule_add "filter $chain $action $proto $src $dst $sport $dport $in $out"
}

del_filter() {
    rule_del "filter $1 $2 $3 $4 $5 $6 $7 $8 $9"
}

add_snat() {
    # $1=srcnet $2=target(masquerade|addr) $3=out
    local src=$1 tgt=$2 out=$3 line f s o
    valid_cidr "$src" || err "srcnet harus CIDR: $src"
    if [ "$tgt" != "masquerade" ]; then valid_v4 "$tgt" || err "target snat harus alamat IPv4 atau masquerade: $tgt"; fi
    if [ "$OS" = "FreeBSD" ]; then
        [ "$out" = "any" ] && err "FreeBSD: snat butuh out-iface eksplisit"
        check_iface "$out" 0
        [ "$tgt" = "masquerade" ] || true
    else
        [ "$out" != "any" ] && check_iface "$out" 1
    fi
    # konflik: (srcnet,out) sama tapi target beda
    if [ -f "$RULES" ]; then
        while IFS= read -r line; do
            set -- $line
            if [ "${1:-}" = "snat" ] && [ "${2:-}" = "$src" ] && [ "${4:-}" = "$out" ] && [ "${3:-}" != "$tgt" ]; then
                err "konflik snat: ($src, out $out) sudah dipetakan ke ${3} — hapus dulu bila mau ganti target"
            fi
        done < "$RULES"
    fi
    rule_add "snat $src $tgt $out"
}

del_snat() { rule_del "snat $1 $2 $3"; }

add_dnat() {
    # $1=proto $2=in $3=dport $4=to $5=toport
    local proto=$1 in=$2 dport=$3 to=$4 toport=$5 line
    case "$proto" in tcp|udp) ;; *) err "dnat hanya tcp/udp (bukan $proto)" ;; esac
    check_iface "$in" 0
    valid_port "$dport" || err "dport di luar 1-65535: $dport"
    valid_v4 "$to" || err "tujuan dnat harus IPv4: $to"
    if [ "$toport" != "same" ]; then valid_port "$toport" || err "port tujuan di luar 1-65535: $toport"; fi
    if [ -f "$RULES" ]; then
        while IFS= read -r line; do
            set -- $line
            if [ "${1:-}" = "dnat" ] && [ "${2:-}" = "$proto" ] && [ "${3:-}" = "$in" ] && [ "${4:-}" = "$dport" ] && ( [ "${5:-}" != "$to" ] || [ "${6:-}" != "$toport" ] ); then
                err "konflik dnat: ($proto, in $in, dport $dport) sudah dipetakan ke ${5}:${6} — hapus dulu bila mau ganti target"
            fi
        done < "$RULES"
    fi
    rule_add "dnat $proto $in $dport $to $toport"
}

del_dnat() { rule_del "dnat $1 $2 $3 $4 $5"; }

# ---------------- generate + load: Linux nftables ----------------

nft_filter_terms() {
    # $1..$8 = proto src dst sport dport in out (tanpa chain/action)
    # -> istilah match nft (stdout, satu baris, tanpa aksi)
    local proto=$1 src=$2 dst=$3 sport=$4 dport=$5 in=$6 out=$7 t=""
    [ "$in" != "any" ] && t="$t iif \"$in\""
    [ "$out" != "any" ] && t="$t oif \"$out\""
    [ "$src" != "any" ] && t="$t ip saddr $src"
    [ "$dst" != "any" ] && t="$t ip daddr $dst"
    case "$proto" in
        tcp) t="$t ip protocol tcp"
            [ "$sport" != "any" ] && t="$t tcp sport $sport"
            [ "$dport" != "any" ] && t="$t tcp dport $dport" ;;
        udp) t="$t ip protocol udp"
            [ "$sport" != "any" ] && t="$t udp sport $sport"
            [ "$dport" != "any" ] && t="$t udp dport $dport" ;;
        icmp) t="$t ip protocol icmp" ;;
        all) : ;;
    esac
    printf '%s' "$t"
}

nft_apply() {
    local tmpfull tmpadd exists=0
    if nft list table inet titian >/dev/null 2>&1; then exists=1; fi
    if [ ! -s "$RULES" ]; then
        if [ "$exists" = "1" ]; then nft delete table inet titian 2>/dev/null || warn "gagal hapus tabel inet titian"; fi
        return 0
    fi
    tmpfull=$(mktemp /tmp/titian-fw-nft.XXXXXX) || return 1
    tmpadd=$(mktemp /tmp/titian-fw-add.XXXXXX) || { rm -f "$tmpfull"; return 1; }
    # JALUR EXISTING (insiden bar1 2 Nov 2026): `nft flush table`
    # menghapus SEMUA rule termasuk established/related di forward —
    # jadi daftar add-rule HARUS membukanya lagi PALING ATAS, kalau
    # tidak trafik balik putus (policy drop) meski request lolos.
    # (Di chain forward, add-rule menempel urut per chain, jadi baris
    # ini tetap pertama di forward apa pun urutan rule user.)
    if [ "$exists" = "1" ]; then
        echo "add rule inet titian forward ct state established,related accept" > "$tmpadd"
    fi
    {
        echo "table inet titian {"
        echo "  chain input { type filter hook input priority 0; policy accept;"
        echo "  }"
        echo "  chain forward { type filter hook forward priority 0; policy drop;"
        echo "    ct state established,related accept"
        echo "  }"
        echo "  chain output { type filter hook output priority 0; policy accept;"
        echo "  }"
        echo "  chain prerouting { type nat hook prerouting priority -100; policy accept;"
        echo "  }"
        echo "  chain postrouting { type nat hook postrouting priority 100; policy accept;"
        echo "  }"
        echo "}"
    } > "$tmpfull"
    # aturan-aturan sebagai add rule (dipakai sesudah flush bila tabel ada)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        case "$1" in
            filter)
                _act=accept; [ "$3" = "deny" ] && _act=drop
                echo "add rule inet titian $2$(nft_filter_terms "$4" "$5" "$6" "$7" "$8" "$9" "${10}") $_act" >> "$tmpadd"
                ;;
            snat)
                _t=""
                [ "$2" != "any" ] && _t=" ip saddr $2"
                if [ "$4" != "any" ]; then _t="$_t oif \"$4\""; fi
                if [ "$3" = "masquerade" ]; then
                    echo "add rule inet titian postrouting$_t masquerade" >> "$tmpadd"
                else
                    echo "add rule inet titian postrouting$_t snat to $3" >> "$tmpadd"
                fi
                ;;
            dnat)
                _t="iif \"$3\" $2 dport $4 dnat ip to $5"
                [ "$6" != "same" ] && _t="$_t:$6"
                echo "add rule inet titian prerouting $_t" >> "$tmpadd"
                ;;
        esac
    done < "$RULES"
    if [ "$exists" = "1" ]; then
        # fail-closed selama refill: flush mempertahanankan chain +
        # policy (forward drop), lalu tambah aturan.
        nft flush table inet titian 2>/dev/null || { rm -f "$tmpfull" "$tmpadd"; return 1; }
        if ! nft -c -f "$tmpadd" 2>/dev/null; then
            warn "nft check gagal untuk aturan baru (live = tabel kosong ter-flush; jalankan apply-all lagi sesudah perbaiki netstate)"
            rm -f "$tmpfull" "$tmpadd"; return 1
        fi
        nft -f "$tmpadd" 2>/dev/null || { rm -f "$tmpfull" "$tmpadd"; return 1; }
    else
        # tabel belum ada: gabung definisi + aturan jadi satu -f
        {
            echo "table inet titian {"
            echo "  chain input { type filter hook input priority 0; policy accept;"
            while IFS= read -r line; do
                set -- $line
                [ "${1:-}" = "filter" ] && [ "${2:-}" = "input" ] || continue
                _act=accept; [ "$3" = "deny" ] && _act=drop
                echo "    $(nft_filter_terms "$4" "$5" "$6" "$7" "$8" "$9" "${10}" | sed 's/^ //') $_act"
            done < "$RULES"
            echo "  }"
            echo "  chain forward { type filter hook forward priority 0; policy drop;"
            echo "    ct state established,related accept"
            while IFS= read -r line; do
                set -- $line
                [ "${1:-}" = "filter" ] && [ "${2:-}" = "forward" ] || continue
                _act=accept; [ "$3" = "deny" ] && _act=drop
                echo "    $(nft_filter_terms "$4" "$5" "$6" "$7" "$8" "$9" "${10}" | sed 's/^ //') $_act"
            done < "$RULES"
            echo "  }"
            echo "  chain output { type filter hook output priority 0; policy accept;"
            while IFS= read -r line; do
                set -- $line
                [ "${1:-}" = "filter" ] && [ "${2:-}" = "output" ] || continue
                _act=accept; [ "$3" = "deny" ] && _act=drop
                echo "    $(nft_filter_terms "$4" "$5" "$6" "$7" "$8" "$9" "${10}" | sed 's/^ //') $_act"
            done < "$RULES"
            echo "  }"
            echo "  chain prerouting { type nat hook prerouting priority -100; policy accept;"
            while IFS= read -r line; do
                set -- $line
                [ "${1:-}" = "dnat" ] || continue
                _t="iif \"$3\" $2 dport $4 dnat ip to $5"
                [ "$6" != "same" ] && _t="$_t:$6"
                echo "    $_t"
            done < "$RULES"
            echo "  }"
            echo "  chain postrouting { type nat hook postrouting priority 100; policy accept;"
            while IFS= read -r line; do
                set -- $line
                [ "${1:-}" = "snat" ] || continue
                _t=""
                [ "$2" != "any" ] && _t=" ip saddr $2"
                if [ "$4" != "any" ]; then _t="$_t oif \"$4\""; fi
                if [ "$3" = "masquerade" ]; then
                    echo "    $_t masquerade" | sed 's/^ *//'
                else
                    echo "    $_t snat to $3" | sed 's/^ *//'
                fi
            done < "$RULES"
            echo "  }"
            echo "}"
        } > "$tmpfull"
        if ! nft -c -f "$tmpfull" 2>/dev/null; then
            rm -f "$tmpfull" "$tmpadd"; return 1
        fi
        nft -f "$tmpfull" 2>/dev/null || { rm -f "$tmpfull" "$tmpadd"; return 1; }
    fi
    rm -f "$tmpfull" "$tmpadd"
    return 0
}

# ---------------- generate + load: FreeBSD pf ----------------

pf_filter_terms() {
    # $1..$7 = proto src dst sport dport dir(if-in/out) — tidak, dir
    # ditangani pemanggil; fungsi ini hanya from/to/proto/port.
    # Dipakai inline di pf_apply (bukan fungsi terpisah) agar urutan
    # kata pf tepat; fungsi ini TIDAK dipakai (lihat pf_apply).
    :
}

pf_ensure_main() {
    # pastikan blok marker anchor di /etc/pf.conf + pf_enable di rc.conf
    local tmp
    if [ ! -f /etc/pf.conf ] || ! grep -q '#-TITIAN-FW-#' /etc/pf.conf 2>/dev/null; then
        [ -f /etc/pf.conf ] && cp -f /etc/pf.conf /etc/pf.conf.titian-fw-bak 2>/dev/null || true
        {
            [ -f /etc/pf.conf ] && cat /etc/pf.conf
            echo ""
            echo '#-TITIAN-FW-#'
            echo 'nat-anchor "titian"'
            echo 'rdr-anchor "titian"'
            echo 'anchor "titian"'
            echo '#-ENDTITIAN-FW-#'
        } > /etc/pf.conf.tmp 2>/dev/null && mv -f /etc/pf.conf.tmp /etc/pf.conf
        pfctl -n -f /etc/pf.conf 2>/dev/null || warn "pf.conf hasil edit GAGAL parse-check (anchor mungkin tidak dievaluasi — periksa manual)"
    fi
    if ! grep -q '#-TITIAN-FW-#' /etc/rc.conf 2>/dev/null; then
        cp -f /etc/rc.conf /etc/rc.conf.titian-fw-bak 2>/dev/null || true
        {
            cat /etc/rc.conf 2>/dev/null
            echo ""
            echo '#-TITIAN-FW-#'
            echo 'pf_enable="YES"'
            echo '#-ENDTITIAN-FW-#'
        } > /etc/rc.conf.tmp 2>/dev/null
        if sh -n /etc/rc.conf.tmp 2>/dev/null; then
            mv -f /etc/rc.conf.tmp /etc/rc.conf
        else
            warn "rc.conf hasil edit GAGAL sh -n — tidak ditulis"
            rm -f /etc/rc.conf.tmp
        fi
    fi
}

pf_apply() {
    local tmp fwd_ifaces f line
    if [ ! -s "$RULES" ]; then
        pfctl -a titian -F rules 2>/dev/null || true
        pfctl -a titian -F nat 2>/dev/null || true
        return 0
    fi
    tmp=$(mktemp /tmp/titian-fw-pf.XXXXXX) || return 1
    {
        echo "# generated by titian-fw.sh — jangan edit manual (sumber: netstate/firewall.rules)"
        # --- translation dulu (grup order pf: nat/rdr sebelum filter) ---
        while IFS= read -r line; do
            set -- $line
            case "${1:-}" in
                snat)
                    if [ "$3" = "masquerade" ]; then
                        echo "nat on $4 from $2 to any -> ($4)"
                    else
                        echo "nat on $4 from $2 to any -> $3"
                    fi
                    ;;
                dnat)
                    if [ "$6" = "same" ]; then
                        echo "rdr on $3 proto $2 from any to any port $4 -> $5"
                    else
                        echo "rdr on $3 proto $2 from any to any port $4 -> $5 port $6"
                    fi
                    ;;
            esac
        done < "$RULES"
        # --- filter (semua quick = menang-pertama, sama dengan nft) ---
        while IFS= read -r line; do
            set -- $line
            [ "${1:-}" = "filter" ] || continue
            _act=pass; [ "$3" = "deny" ] && _act=block
            _dir=in; _if=$9
            if [ "$2" = "output" ]; then _dir=out; _if=${10}; fi
            # iface hilang -> lewati (pfctl gagal load bila nama tak ada)
            if ! iface_exists "$_if"; then
                echo "# LEWATI (iface $_if hilang): $line" >&2
                continue
            fi
            _t="$_act $_dir quick on $_if inet"
            case "$4" in tcp|udp|icmp) _t="$_t proto $4" ;; esac
            _t="$_t from $5"
            if [ "$4" = "tcp" ] || [ "$4" = "udp" ]; then
                [ "$7" != "any" ] && _t="$_t port $7"
            fi
            _t="$_t to $6"
            if [ "$4" = "tcp" ] || [ "$4" = "udp" ]; then
                [ "$8" != "any" ] && _t="$_t port $8"
            fi
            echo "$_t"
        done < "$RULES"
        # --- trailing block per in-iface (default deny) ---
        # In-iface dikumpulkan dari filter-forward DAN dnat: dnat saja (tanpa
        # forward rule) sebelumnya tidak menutup iface -> koneksi DNAT lolos
        # tanpa permit (bar2 FreeBSD FAIL 2 Nov). Filter-input TIDAK ikut:
        # input-only harus berperilaku sama dengan nft (policy accept).
        # Snat-only (tanpa in-iface) juga tidak menutup iface di pf —
        # didokumentasikan sebagai batas per-OS (nft menutup via policy drop).
        fwd_ifaces=""
        while IFS= read -r line; do
            set -- $line
            if [ "${1:-}" = "filter" ] && [ "${2:-}" = "forward" ]; then _f=$9
            elif [ "${1:-}" = "dnat" ]; then _f=$3
            else continue; fi
            case " $fwd_ifaces " in *" $_f "*) ;; *) fwd_ifaces="$fwd_ifaces $_f" ;; esac
        done < "$RULES"
        for f in $fwd_ifaces; do
            iface_exists "$f" || continue
            echo "block in quick on $f all"
        done
    } > "$tmp" 2>/tmp/titian-fw-pf.warn
    if [ -s /tmp/titian-fw-pf.warn ]; then
        # warning iface-hilang (stderr dari subshell di atas) diteruskan
        cat /tmp/titian-fw-pf.warn >&2
    fi
    cp -f "$tmp" "$PF_ANCHOR_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    pf_ensure_main
    # modul pf + main ruleset + anchor, lalu enable
    if ! kldstat -q -m pf 2>/dev/null; then kldload pf 2>/dev/null || true; fi
    pfctl -f /etc/pf.conf 2>/dev/null || warn "pfctl -f /etc/pf.conf gagal (anchor mungkin tidak dievaluasi)"
    if ! pfctl -a titian -n -f "$tmp" 2>/dev/null; then
        warn "pf anchor GAGAL parse-check — live tidak diubah"
        rm -f "$tmp"; return 1
    fi
    pfctl -a titian -f "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    if ! pfctl -s Running >/dev/null 2>&1; then pfctl -e 2>/dev/null || true; fi
    rm -f "$tmp"
    return 0
}

apply_live() {
    if [ "$OS" = "FreeBSD" ]; then pf_apply; else nft_apply; fi
}

# ---------------- show / flush / teardown ----------------

do_show() {
    local n=0 line
    echo "== firewall Titian (backend: $([ "$OS" = "FreeBSD" ] && echo "pf anchor titian" || echo "nftables inet titian")) =="
    if [ "$OS" = "FreeBSD" ]; then
        echo "-- forwarding: net.inet.ip.forwarding=$(sysctl -n net.inet.ip.forwarding 2>/dev/null) net.inet6.ip6.forwarding=$(sysctl -n net.inet6.ip6.forwarding 2>/dev/null) (pf TIDAK me-forward sendiri — butuh 1 untuk transit)"
        echo "-- pf: $(pfctl -s Running 2>&1 | head -1)"
    else
        echo "-- forwarding: net.ipv4.ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) (butuh 1 untuk transit)"
        if nft list table inet titian >/dev/null 2>&1; then echo "-- tabel inet titian: ADA"; else echo "-- tabel inet titian: TIDAK ADA (tanpa rule)"; fi
    fi
    echo "-- rules (urutan = prioritas; hapus dengan sintaks lengkap, bukan nomor):"
    if [ ! -s "$RULES" ]; then
        echo "   (belum ada rule)"
    else
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            n=$((n + 1))
            printf '   %d. %s\n' "$n" "$line"
        done < "$RULES"
    fi
    if [ "$OS" = "FreeBSD" ]; then
        echo "-- live anchor titian (filter):"
        pfctl -a titian -sr 2>&1 | sed 's/^/   /'
        echo "-- live anchor titian (nat/rdr):"
        pfctl -a titian -sn 2>&1 | sed 's/^/   /'
    else
        echo "-- live nftables:"
        nft list table inet titian 2>&1 | sed 's/^/   /'
    fi
    [ -f "$PROT" ] && { echo "-- iface terproteksi:"; sed 's/^/   /' "$PROT"; }
}

do_flush() {
    # hapus SEMUA rule (netstate kosong + rebuild) — dipakai `no firewall`
    rm -f "$RULES" "$RULES.bak"
    apply_live || err "flush backend gagal"
    echo "firewall: semua rule dihapus"
}

do_teardown() {
    # teardown TOTAL (hanya untuk cleanup uji — TIDAK diekspos di CLI):
    # kembalikan pf/nft ke keadaan sebelum fitur dipakai.
    rm -f "$RULES" "$RULES.bak"
    if [ "$OS" = "FreeBSD" ]; then
        pfctl -a titian -F rules 2>/dev/null || true
        pfctl -a titian -F nat 2>/dev/null || true
        if [ -f /etc/pf.conf ]; then
            awk '/^#-TITIAN-FW-#/{skip=1; next} /^#-ENDTITIAN-FW-#/{skip=0; next} !skip {print}' /etc/pf.conf > /etc/pf.conf.tmp 2>/dev/null && mv -f /etc/pf.conf.tmp /etc/pf.conf
            if ! grep -q '[^[:space:]#]' /etc/pf.conf 2>/dev/null; then rm -f /etc/pf.conf; fi
        fi
        if [ -f /etc/rc.conf ]; then
            awk '/^#-TITIAN-FW-#/{skip=1; next} /^#-ENDTITIAN-FW-#/{skip=0; next} !skip {print}' /etc/rc.conf > /etc/rc.conf.tmp 2>/dev/null && mv -f /etc/rc.conf.tmp /etc/rc.conf
        fi
        rm -f "$PF_ANCHOR_FILE" /etc/pf.conf.titian-fw-bak /etc/rc.conf.titian-fw-bak
        pfctl -d 2>/dev/null || true
        kldunload pf 2>/dev/null || true
    else
        nft delete table inet titian 2>/dev/null || true
    fi
    rm -f "$PROT"
    echo "firewall: teardown selesai"
}

case "${1:-}" in
    add-filter) shift; add_filter "$@" ;;
    del-filter) shift; del_filter "$@" ;;
    add-snat) shift; add_snat "$@" ;;
    del-snat) shift; del_snat "$@" ;;
    add-dnat) shift; add_dnat "$@" ;;
    del-dnat) shift; del_dnat "$@" ;;
    apply-all) apply_live || err "apply-all gagal" ;;
    show) do_show ;;
    flush) do_flush ;;
    teardown) do_teardown ;;
    *) echo "Usage: $0 {add-filter|del-filter|add-snat|del-snat|add-dnat|del-dnat|apply-all|show|flush|teardown} ..." >&2; exit 2 ;;
esac
exit 0
