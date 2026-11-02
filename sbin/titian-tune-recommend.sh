#!/bin/sh
# TITIAN — rekomendasi tuning (READ-ONLY, tidak mengubah apa-apa).
# Hanya membaca: /sys, ethtool -i/-k/-c (query), ip link, ifconfig,
# sysctl -n. TIDAK PERNAH menjalankan ethtool -K/-C, ip link set,
# ifconfig set, atau sysctl -w.
#
# Profil default = ROUTER (box forwarding BIRD). Bila box ini endpoint
# (bukan router), abaikan rekomendasi ip_forward (seharusnya 0).
# Setiap rekomendasi mencetak perintah CLI Titian persis yang bisa
# dijalankan operator untuk menerapkannya — tool ini sendiri tidak
# menerapkannya.
#
# Graceful degradation: ethtool tidak ada -> bagian offload/coalesce
# dilewati dengan catatan; fitur [fixed] driver -> tidak direkomendasikan
# diubah; interface tanpa dukungan suatu fitur -> dilewati diam-diam
# untuk fitur itu.
# POSIX sh (jalan di dash Debian dan sh FreeBSD).
set -u
OS=$(uname -s)

say() { echo "$*"; }
rec() {
    # $1=perintah titian $2=alasan
    echo "  REKOMENDASI: $1"
    echo "    alasan: $2"
}
ok() { echo "  OK: $*"; }
note() { echo "  CATATAN: $*"; }

# ---------- sysctl (kedua OS) ----------
sysctl_section_linux() {
    say "== Sysctl (Linux, profil router) =="
    _v=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    if [ "$_v" = "1" ]; then ok "net.ipv4.ip_forward=1 (forwarding aktif)"; else rec "system sysctl net.ipv4.ip_forward 1" "router wajib meneruskan paket antar interface (saat ini: $_v). Bila box ini endpoint, justru harus 0."; fi
    _v=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "?")
    if [ "$_v" = "1" ]; then ok "net.ipv6.conf.all.forwarding=1"; else rec "system sysctl net.ipv6.conf.all.forwarding 1" "forwarding IPv6 untuk router dual-stack (saat ini: $_v)."; fi
    for k in net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter; do
        _v=$(sysctl -n "$k" 2>/dev/null || echo "?")
        case "$_v" in
            2) ok "$k=2 (loose)" ;;
            *) rec "system sysctl $k 2" "strict (1) menolak paket dari jalur tak terduga dan merusak routing asimetris; loose (2) tetap memfilter spoof kasar tanpa memutus rute asimetris (saat ini: $_v)." ;;
        esac
    done
    _v=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "?")
    case "$_v" in
        ''|'[?]') ;;
        *) if [ "$_v" -ge 5000 ] 2>/dev/null; then ok "net.core.netdev_max_backlog=$_v"; else rec "system sysctl net.core.netdev_max_backlog 5000" "antrean paket masuk sebelum diproses; nilai kecil menyebabkan drop RX saat burst (saat ini: $_v)."; fi ;;
    esac
    _v=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "?")
    case "$_v" in
        ''|'[?]') ;;
        *) if [ "$_v" -ge 16777216 ] 2>/dev/null; then ok "net.core.rmem_max=$_v"; else rec "system sysctl net.core.rmem_max 16777216" "buffer socket maksimum; menaikkan ini saja belum berefek tanpa tcp_rmem (saat ini: $_v)."; fi ;;
    esac
    _v=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "?")
    case "$_v" in
        ''|'[?]') ;;
        *) if [ "$_v" -ge 16777216 ] 2>/dev/null; then ok "net.core.wmem_max=$_v"; else rec "system sysctl net.core.wmem_max 16777216" "seperti rmem_max, untuk arah kirim (saat ini: $_v)."; fi ;;
    esac
    _v=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "?")
    case "$_v" in
        ''|'[?]') ;;
        *) _max=$(echo "$_v" | awk '{print $3}')
            if [ "${_max:-0}" -ge 16777216 ] 2>/dev/null; then ok "net.ipv4.tcp_rmem=$_v"; else rec "system sysctl net.ipv4.tcp_rmem \"4096 87380 16777216\"" "buffer TCP (min/default/maks); maks kecil membatasi throughput sesi jarak jauh/latensi tinggi seperti BGP antar POP (saat ini: $_v)."; fi ;;
    esac
    _v=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "?")
    case "$_v" in
        ''|'[?]') ;;
        *) _max=$(echo "$_v" | awk '{print $3}')
            if [ "${_max:-0}" -ge 16777216 ] 2>/dev/null; then ok "net.ipv4.tcp_wmem=$_v"; else rec "system sysctl net.ipv4.tcp_wmem \"4096 65536 16777216\"" "seperti tcp_rmem, untuk arah kirim (saat ini: $_v)."; fi ;;
    esac
}
sysctl_section_freebsd() {
    say "== Sysctl (FreeBSD, profil router) =="
    _v=$(sysctl -n net.inet.ip.forwarding 2>/dev/null || echo "?")
    if [ "$_v" = "1" ]; then ok "net.inet.ip.forwarding=1 (forwarding aktif)"; else rec "system sysctl net.inet.ip.forwarding 1" "router wajib meneruskan paket antar interface (saat ini: $_v). Bila box ini endpoint, justru harus 0."; fi
    _v=$(sysctl -n net.inet6.ip6.forwarding 2>/dev/null || echo "?")
    if [ "$_v" = "1" ]; then ok "net.inet6.ip6.forwarding=1"; else rec "system sysctl net.inet6.ip6.forwarding 1" "forwarding IPv6 untuk router dual-stack (saat ini: $_v)."; fi
    _v=$(sysctl -n net.inet.tcp.sendbuf_max 2>/dev/null || echo "?")
    case "$_v" in
        ''|'[?]') ;;
        *) if [ "$_v" -ge 16777216 ] 2>/dev/null; then ok "net.inet.tcp.sendbuf_max=$_v"; else rec "system sysctl net.inet.tcp.sendbuf_max 16777216" "buffer kirim TCP maksimum; kecil membatasi throughput sesi jarak jauh (saat ini: $_v)."; fi ;;
    esac
    _v=$(sysctl -n net.inet.tcp.recvbuf_max 2>/dev/null || echo "?")
    case "$_v" in
        ''|'[?]') ;;
        *) if [ "$_v" -ge 16777216 ] 2>/dev/null; then ok "net.inet.tcp.recvbuf_max=$_v"; else rec "system sysctl net.inet.tcp.recvbuf_max 16777216" "seperti sendbuf_max, untuk arah terima (saat ini: $_v)."; fi ;;
    esac
    note "FreeBSD tidak punya rp_filter seperti Linux (tidak ada rekomendasi padanan)."
}

# ---------- interface: Linux ----------
iface_linux() {
    local iface=$1 drv speed mtu qlen
    say "== Interface $iface (Linux) =="
    drv=$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}')
    [ -n "$drv" ] && say "  driver: $drv" || say "  driver: (tidak terbaca — ethtool tidak tersedia?)"
    mtu=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo "?")
    qlen=$(cat "/sys/class/net/$iface/tx_queue_len" 2>/dev/null || echo "?")
    say "  mtu saat ini: $mtu | txqueuelen saat ini: $qlen"
    case "$mtu" in
        1500) note "mtu 1500 = default aman. Jumbo 9000 hanya bila SELURUH path mendukung; bila ya: interface ethernet $iface -> mtu 9000." ;;
        9000) ok "mtu 9000 (jumbo) — pastikan seluruh path mendukung, kalau tidak paket besar di-drop." ;;
        *) note "mtu $mtu bukan 1500/9000 — pastikan disengaja (pastikan path + peer sepakat)." ;;
    esac
    if command -v ethtool >/dev/null 2>&1; then
        speed=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/^[[:space:]]*Speed:/{print $2; exit}')
        [ -n "$speed" ] && say "  kecepatan link: $speed"
        case "$speed" in
            10000Mb/s)
                if [ "$qlen" = "10000" ]; then ok "txqueuelen 10000 cocok untuk 10G"; else rec "interface ethernet $iface -> qlen 10Gbit" "antrean kirim 10000 untuk 10G (saat ini: $qlen)."; fi ;;
            1000Mb/s)
                if [ "$qlen" = "1000" ]; then ok "txqueuelen 1000 cocok untuk 1G"; else rec "interface ethernet $iface -> qlen 1Gbit" "antrean kirim 1000 untuk 1G (saat ini: $qlen)."; fi ;;
            *) note "kecepatan link tidak terbaca ($speed) — rekomendasi qlen dilewati." ;;
        esac
        # offload: hanya fitur yang dikenal + tidak [fixed]
        ethtool -k "$iface" 2>/dev/null | while read -r line; do
            case "$line" in
                'tcp-segmentation-offload: '*) _f=tso ;;
                'generic-segmentation-offload: '*) _f=gso ;;
                'generic-receive-offload: '*) _f=gro ;;
                'large-receive-offload: '*) _f=lro ;;
                'rx-checksumming: '*) _f=rx ;;
                'tx-checksumming: '*) _f=tx ;;
                'scatter-gather: '*) _f=sg ;;
                *) continue ;;
            esac
            _val=${line#*: }; _state=${_val%% *}; _fixed=""
            case "$_val" in *'[fixed]'*) _fixed=1 ;; esac
            if [ -n "$_fixed" ]; then
                note "$_f: $_state [fixed driver] — tidak bisa diubah, dilewati."
                continue
            fi
            case "$_f:$_state" in
                'lro:on') rec "interface ethernet $iface -> options -> no lro" "LRO hardware HARUS off di router/bridge karena bisa merusak semantik forwarding; pakai GRO (software) sebagai gantinya." ;;
                'lro:off') ok "lro off (benar untuk router)" ;;
                'tso:off') rec "interface ethernet $iface -> options -> tso on" "TSO off membebani CPU untuk trafik lokal (sesi BGP/manajemen yang berasal dari box ini)." ;;
                'gso:off') rec "interface ethernet $iface -> options -> gso on" "GSO off membebani CPU untuk trafik lokal." ;;
                'gro:off') rec "interface ethernet $iface -> options -> gro on" "GRO off membebani CPU receive; GRO aman untuk router (berbeda dengan LRO hardware)." ;;
                'rx:off') rec "interface ethernet $iface -> options -> rx on" "checksum receive oleh NIC menghemat CPU; hampir selalu on." ;;
                'tx:off') rec "interface ethernet $iface -> options -> tx on" "checksum transmit oleh NIC menghemat CPU; hampir selalu on." ;;
                'sg:off') rec "interface ethernet $iface -> options -> sg on" "scatter-gather adalah prasyarat TSO/GSO; off membatasi offload lain." ;;
                *) ok "$_f $_state" ;;
            esac
        done
        _c=$(ethtool -c "$iface" 2>/dev/null)
        _rxu=$(echo "$_c" | awk '/^RX-usecs:/{print $2}')
        _arx=$(echo "$_c" | awk '/^Adaptive RX:/{print $3}')
        if [ -n "$_rxu" ]; then
            case "$_rxu" in
                0) note "rx-usecs 0 = interupsi segera (latensi terendah, CPU tertinggi). Untuk throughput tinggi pertimbangkan: interface ethernet $iface -> options -> rx-usecs 125." ;;
                *) if [ "$_rxu" -gt 500 ] 2>/dev/null; then note "rx-usecs $_rxu tinggi: hemat CPU tapi latensi naik; untuk latensi rendah pertimbangkan 125 atau 0."; else ok "rx-usecs $_rxu (dalam rentang wajar)."; fi ;;
            esac
        fi
        if [ -n "$_arx" ]; then
            case "$_arx" in
                off) note "adaptive-rx off. Untuk beban campuran (kadang sepi, kadang burst) pertimbangkan: interface ethernet $iface -> options -> adaptive-rx on." ;;
                *) ok "adaptive-rx $_arx" ;;
            esac
        fi
    else
        note "ethtool tidak ditemukan — bagian offload/coalesce/kecepatan dilewati (pasang ethtool untuk rekomendasi lengkap)."
    fi
}

# ---------- interface: FreeBSD ----------
iface_freebsd() {
    local iface=$1 out opts
    say "== Interface $iface (FreeBSD) =="
    out=$(ifconfig "$iface" 2>/dev/null) || { note "tidak bisa dibaca, dilewati."; return 0; }
    say "  mtu saat ini: $(echo "$out" | awk '{for(i=1;i<=NF;i++) if ($i == "mtu") {print $(i+1); exit}}')"
    # token options=<> dipisah koma, cocok PERSIS (bukan substring:
    # VLAN_HWTSO bukan TSO, RXCSUM_IPV6 bukan RXCSUM)
    _toks=$(echo "$out" | awk '/^[[:space:]]options=/{print; exit}' | sed 's/.*<//; s/>.*//')
    say "  options=<$_toks>"
    _has() { case ",$_toks," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
    if _has TSO4 || _has TSO6; then ok "tso aktif (TSO4/TSO6)"; else rec "interface ethernet $iface -> options -> tso on" "TSO off membebani CPU untuk trafik lokal (bila driver mendukung)."; fi
    if _has LRO; then rec "interface ethernet $iface -> options -> no lro" "LRO HARUS off di router/bridge karena bisa merusak semantik forwarding."; else ok "lro off (benar untuk router)"; fi
    if _has RXCSUM; then ok "rxcsum aktif"; else rec "interface ethernet $iface -> options -> rx on" "checksum receive oleh NIC menghemat CPU (bila driver mendukung)."; fi
    if _has TXCSUM; then ok "txcsum aktif"; else rec "interface ethernet $iface -> options -> tx on" "checksum transmit oleh NIC menghemat CPU (bila driver mendukung)."; fi
    note "gro/gso/sg tidak punya padanan ifconfig di FreeBSD — tidak dinilai."
    note "coalesce tidak punya padanan generik di FreeBSD — tidak dinilai."
    note "qlen (txqueuelen) tidak punya padanan di FreeBSD — tidak dinilai."
}

say "TITIAN tuning recommendations ($OS) — READ-ONLY, tidak ada yang diubah"
say "Profil: ROUTER (forwarding BIRD). Bila box ini endpoint, abaikan rekomendasi ip_forward."
say ""
if [ "$OS" = "FreeBSD" ]; then
    for i in $(ifconfig -l 2>/dev/null); do
        case "$i" in lo*|pflog*|pfsync*) continue ;; esac
        iface_freebsd "$i"
        say ""
    done
    sysctl_section_freebsd
else
    for d in /sys/class/net/*; do
        [ -d "$d" ] || continue
        i=$(basename "$d")
        case "$i" in lo) continue ;; esac
        iface_linux "$i"
        say ""
    done
    sysctl_section_linux
fi
say ""
say "Selesai. Jalankan perintah REKOMENDASI di atas lewat CLI Titian bila setuju — tool ini tidak mengubah apa-apa."
