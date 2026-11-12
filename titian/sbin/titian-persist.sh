#!/bin/sh
# TITIAN Fase 1 — cermin persistensi untuk interface yang DIBUAT titian.
#  - Debian: /etc/systemd/network/00-titian-<iface>.network (networkd
#    hanya me-match interface titian; NIC sistem tidak pernah ditulis).
#  - FreeBSD: blok marker #-TITIAN-# ... #-ENDTITIAN-# di /etc/rc.conf
#    (baris di luar blok tidak pernah disentuh; backup + sh -n tiap tulis).
# Sumber kebenaran = state file /etc/titian/netstate/<iface>.addr
# yang ditulis titian-if.sh (bukan parsing output tool).
# Persistensi utama tetap replay startup-config saat boot; cermin ini
# adalah artefak deklaratif kedua (keputusan default Fase 1).
# Helper ini best-effort: gagal tulis -> peringatan, exit 0 (perintah
# CLI tidak boleh gagal hanya karena cermin gagal).
# POSIX sh.
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
STATE_DIR="$STATE_ROOT/netstate"
warn() { echo "Warning(persist): $*" >&2; }

mark_if() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    touch "$STATE_DIR/$1.managed" 2>/dev/null || true
    touch "$STATE_DIR/$1.addr" 2>/dev/null || true
}

sync_debian() {
    # $1=iface: regenerasi .network dari state file
    local iface=$1 f net
    f="$STATE_DIR/$iface.addr"
    net="/etc/systemd/network/00-titian-$iface.network"
    # GUARD (insiden rollback 2 Nov 2026 — guest kehilangan mgmt):
    # JANGAN buat cermin untuk interface TANPA state titian
    # (.addr kosong + .tuning kosong). Cermin kosong (lexical
    # pertama, 00-titian-*) akan dibaca networkd SEBELUM konfigurasi
    # OS (mis. DHCP cloud-init untuk enp1s0) sehingga interface
    # sistem kehilangan alamatnya saat reload. Cermin yang sudah
    # ada untuk interface seperti itu DIHAPUS. Aturan ini sejalan
    # dengan guard sync_freebsd (lewati iface tanpa state).
    # Cermin hanya boleh ada bila titian punya state untuk iface
    # itu (alamat dan/atau tuning); tanpa state, tidak ada yang
    # perlu dideklarasikan.
    if [ ! -s "$f" ] && [ ! -s "$STATE_DIR/$iface.tuning" ]; then
        rm -f "$net" 2>/dev/null || true
        return 0
    fi
    mkdir -p /etc/systemd/network 2>/dev/null || { warn "tidak bisa mkdir /etc/systemd/network"; return 0; }
    {
        echo "[Match]"
        echo "Name=$iface"
        echo ""
        echo "[Network]"
        while IFS= read -r line; do
            case "$line" in
                'inet '*)
                    rest=${line#inet }
                    case "$rest" in
                        *' peer '*)
                            # PtP ditulis sebagai [Address] + Peer di bawah
                            ;;
                        *) echo "Address=$rest" ;;
                    esac
                    ;;
                'inet6 '*) echo "Address=${line#inet6 }" ;;
            esac
        done < "$f" 2>/dev/null
        # CATATAN: Bond= networkd TIDAK dipakai di sini — networkd hanya
        # menghormati Bond= bila bond-nya sendiri didefinisikan lewat
        # .netdev ("bond0 NetDev could not be found, ignoring
        # assignment"); bond titian dibuat via ip link, jadi Bond=
        # diabaikan. Keanggotaan ditegakkan ulang oleh attach-bond
        # (dipanggil sync tuning + apply-bond saat boot), bukan oleh
        # networkd.
        # [Link] dari .tuning (mtu/qlen saja; offload/coalesce TIDAK
        # punya padanan networkd — dibawa replay startup-config +
        # apply-all di titian-boot.sh)
        t="$STATE_DIR/$iface.tuning"
        if [ -f "$t" ]; then
            _mtu=$(grep '^mtu ' "$t" 2>/dev/null | tail -1 | awk '{print $2}')
            _qlen=$(grep '^qlen ' "$t" 2>/dev/null | tail -1 | awk '{print $2}')
            if [ -n "$_mtu" ] || [ -n "$_qlen" ]; then
                echo ""
                echo "[Link]"
                [ -n "$_mtu" ] && echo "MTUBytes=$_mtu"
                [ -n "$_qlen" ] && echo "TransmitQueueLength=$_qlen"
            fi
        fi
        while IFS= read -r line; do
            case "$line" in
                'inet '*peer' '*)
                    rest=${line#inet }
                    local=${rest%% peer *}
                    peer=${rest##* peer }
                    echo ""
                    echo "[Address]"
                    echo "Address=$local/32"
                    echo "Peer=$peer"
                    ;;
            esac
        done < "$f" 2>/dev/null
    } > "$net.tmp" 2>/dev/null && mv "$net.tmp" "$net" || { warn "gagal tulis $net"; return 0; }
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active -q systemd-networkd 2>/dev/null; then
        networkctl reload 2>/dev/null || true
    fi
}

sync_freebsd() {
    # regenerasi SELURUH blok marker dari semua state file
    local rc=/etc/rc.conf tmp
    tmp=$(mktemp /tmp/titian-rcconf.XXXXXX) || { warn "gagal mktemp"; return 0; }
    {
        # salin rc.conf tanpa blok titian lama (bila ada)
        if [ -f "$rc" ]; then
            awk '/^#-TITIAN-#/{skip=1; next} /^#-ENDTITIAN-#/{skip=0; next} !skip {print}' "$rc"
        fi
        echo "#-TITIAN-#"
        # static_routes lama di luar blok titian dipertahankan (merge, bukan timpa);
        # nama route titian lama (titian_p*) dibuang agar re-sync tidak menumpuk.
        _old_routes=$(awk '/^#-TITIAN-#/{skip=1} /^#-ENDTITIAN-#/{skip=0} !skip && /^static_routes=/{print}' "$rc" 2>/dev/null | tail -1 | sed 's/^static_routes=//; s/"//g')
        _kept=""
        for _r in $_old_routes; do
            case "$_r" in titian_p*) ;; *) _kept="$_kept $_r" ;; esac
        done
        _proutes=""; _pcount=0
        for m in "$STATE_DIR"/*.managed; do
            [ -e "$m" ] || continue
            iface=$(basename "$m" .managed)
            f="$STATE_DIR/$iface.addr"
            tf="$STATE_DIR/$iface.tuning"
            [ -s "$f" ] || [ -s "$tf" ] || continue
            # suffix tuning untuk baris ifconfig pertama: mtu + flag
            # offload (gro/gso/sg/coalesce/qlen tidak punya padanan
            # ifconfig sehingga tidak pernah tercatat di FreeBSD)
            _tsuffix=""
            if [ -f "$tf" ]; then
                _m=$(grep '^mtu ' "$tf" 2>/dev/null | tail -1 | awk '{print $2}')
                [ -n "$_m" ] && _tsuffix="$_tsuffix mtu $_m"
                while IFS= read -r _tl; do
                    case "$_tl" in
                        'offload tso on') _tsuffix="$_tsuffix tso" ;;
                        'offload tso off') _tsuffix="$_tsuffix -tso" ;;
                        'offload lro on') _tsuffix="$_tsuffix lro" ;;
                        'offload lro off') _tsuffix="$_tsuffix -lro" ;;
                        'offload rx on') _tsuffix="$_tsuffix rxcsum" ;;
                        'offload rx off') _tsuffix="$_tsuffix -rxcsum" ;;
                        'offload tx on') _tsuffix="$_tsuffix txcsum" ;;
                        'offload tx off') _tsuffix="$_tsuffix -txcsum" ;;
                    esac
                done < "$tf"
            fi
            n=0
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                case "$line" in
                    'inet '*)
                        rest=${line#inet }
                        case "$rest" in
                            *' peer '*)
                                local=${rest%% peer *}
                                peer=${rest##* peer }
                                frag="inet $local netmask 255.255.255.255"
                                _proutes="$_proutes titian_p$_pcount"
                                printf 'route_titian_p%s="-host %s -iface %s"\n' "$_pcount" "$peer" "$iface"
                                _pcount=$((_pcount + 1))
                                ;;
                            *) frag="inet $rest" ;;
                        esac
                        ;;
                    'inet6 '*) frag="inet6 ${line#inet6 }" ;;
                    *) continue ;;
                esac
                if [ "$n" -eq 0 ]; then
                    printf 'ifconfig_%s="%s"\n' "$iface" "$frag$_tsuffix"
                else
                    printf 'ifconfig_%s_alias%s="%s"\n' "$iface" "$((n - 1))" "$frag"
                fi
                n=$((n + 1))
            done < "$f"
            # tuning saja tanpa alamat: tetap tulis satu baris ifconfig
            # (mis. ifconfig_vtnet1="mtu 9000") agar cermin tidak hilang
            if [ "$n" -eq 0 ] && [ -n "$_tsuffix" ]; then
                printf 'ifconfig_%s="%s"\n' "$iface" "${_tsuffix# }"
            fi
        done
        _all_routes="$_kept$_proutes"
        _all_routes=$(printf '%s' "$_all_routes" | sed 's/^ //')
        if [ -n "$_all_routes" ]; then
            printf 'static_routes="%s"\n' "$_all_routes"
        fi
        echo "#-ENDTITIAN-#"
    } > "$tmp" 2>/dev/null
    if ! sh -n "$tmp" 2>/dev/null; then
        warn "rc.conf hasil regenerasi gagal sh -n, tidak ditulis"
        rm -f "$tmp"
        return 0
    fi
    if [ -f "$rc" ]; then
        cp -f "$rc" /etc/rc.conf.titian-bak 2>/dev/null || true
    fi
    cat "$tmp" > "$rc" 2>/dev/null || { warn "gagal tulis $rc"; rm -f "$tmp"; return 0; }
    rm -f "$tmp"
}

drop_if() {
    # $1=iface: hapus marker+state, bersihkan cermin
    rm -f "$STATE_DIR/$1.managed" "$STATE_DIR/$1.addr" "$STATE_DIR/$1.tuning" "$STATE_DIR/$1.tuning.prev" "$STATE_DIR/$1.bond" "$STATE_DIR/$1.vxlan" 2>/dev/null
    if [ "$OS" = "FreeBSD" ]; then
        sync_freebsd
    else
        rm -f "/etc/systemd/network/00-titian-$1.network" 2>/dev/null
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active -q systemd-networkd 2>/dev/null; then
            networkctl reload 2>/dev/null || true
        fi
    fi
}

attach_bond() {
    # $1=slave: pasang ulang ke bond tercatat bila terlepas.
    # Latar: networkd me-reset master sebuah interface setiap kali
    # me-reconfigure-nya (regen cermin + reload, atau flap dengan
    # config berubah) — karena bond titian bukan NetDev networkd,
    # reconfigure itu melepas slave dari bond. Fungsi ini
    # menegakkan ulang keanggotaan dari file .bond. No-op bila
    # bukan slave bond / bond tidak ada / sudah terpasang.
    # Selalu exit 0 (jaring pengaman, bukan perintah yang boleh gagal).
    local b f
    f="$STATE_DIR/$1.bond"
    [ -f "$f" ] || return 0
    b=$(head -n 1 "$f" 2>/dev/null)
    [ -n "$b" ] || return 0
    [ -d "/sys/class/net/$b" ] || return 0
    [ -d "/sys/class/net/$b/lower_$1" ] && return 0
    echo "+$1" > "/sys/class/net/$b/bonding/slaves" 2>/dev/null || return 0
    ip link set "$1" up 2>/dev/null || true
    ip link set "$b" up 2>/dev/null || true
    # Bila reconfigure networkd masih tertunda saat pasang pertama,
    # verifikasi gagal → tunggu sebentar lalu pasang sekali lagi.
    if [ ! -d "/sys/class/net/$b/lower_$1" ]; then
        sleep 2
        echo "+$1" > "/sys/class/net/$b/bonding/slaves" 2>/dev/null || return 0
        ip link set "$1" up 2>/dev/null || true
        ip link set "$b" up 2>/dev/null || true
    fi
    return 0
}
apply_bond() {
    # Pasang ulang semua slave bond yang tercatat (jaring pengaman boot:
    # dipanggil titian-boot.sh sesudah replay + apply-all).
    local m iface
    for m in "$STATE_DIR"/*.bond; do
        [ -e "$m" ] || continue
        iface=$(basename "$m" .bond)
        attach_bond "$iface"
    done
}
bond_if() {
    # $1=slave $2=bond: catat keanggotaan + regenerasi cermin slave,
    # lalu pasang ulang (sync di atas memicu reconfigure networkd
    # yang melepas slave — attach menutup celah itu seketika).
    echo "$2" > "$STATE_DIR/$1.bond" 2>/dev/null
    if [ -f "$STATE_DIR/$1.managed" ]; then
        if [ "$OS" = "FreeBSD" ]; then sync_freebsd; else sync_debian "$1"; fi
    fi
    attach_bond "$1"
}
unbond_if() {
    # $1=slave: hapus catatan keanggotaan + regenerasi cermin slave.
    rm -f "$STATE_DIR/$1.bond" 2>/dev/null
    if [ -f "$STATE_DIR/$1.managed" ]; then
        if [ "$OS" = "FreeBSD" ]; then sync_freebsd; else sync_debian "$1"; fi
    fi
}

case "${1:-}" in
    mark-if) mark_if "$2" ;;
    drop-if) drop_if "$2" ;;
    bond-if) bond_if "$2" "$3" ;;
    unbond-if) unbond_if "$2" ;;
    attach-bond) attach_bond "$2" ;;
    apply-bond) apply_bond ;;
    sync-if)
        # no-op untuk interface sistem (tanpa marker)
        if [ -f "$STATE_DIR/$2.managed" ]; then
            if [ "$OS" = "FreeBSD" ]; then sync_freebsd; else sync_debian "$2"; fi
        fi
        ;;
    *) echo "Usage: $0 {mark-if|drop-if|sync-if|bond-if|unbond-if|attach-bond|apply-bond} <iface> [bond]" >&2; exit 2 ;;
esac
exit 0
