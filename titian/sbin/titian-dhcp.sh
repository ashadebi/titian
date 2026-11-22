#!/bin/sh
# titian-dhcp.sh — IPoE via DHCP (dhclient client + isc-dhcpd server).
# mpd5 does NOT support IPoE (PPP only: PPPoE/PPTP/L2TP). IPoE is plain
# IP over Ethernet, i.e. DHCP. This script is the IPoE backend.
# Client: dhclient (base FreeBSD /sbin/dhclient).
# Server: isc-dhcpd (/usr/local/sbin/dhcpd, already in the image).
#
# RADIUS MAC-auth (19 Nov 2026): IPoE tidak punya username/password,
# jadi auth berbasis MAC (MAB — MAC Authentication Bypass). isc-dhcpd
# TIDAK punya dukungan RADIUS native, dan hook `on commit` + `execute()`
# TIDAK BISA mem-veto lease (lease sudah ter-commit saat hook jalan).
# Mekanisme yang dipakai (native isc-dhcpd):
#   - class "radius-allowed" { match hardware; } + subclass per MAC
#     yang lolos RADIUS + pool `allow members of "radius-allowed";`
#     + `deny unknown-clients;` di subnet. MAC yang tidak lolos RADIUS
#     TIDAK mendapat lease (deny).
#   - RADIUS adalah otoritas: saat generate, tiap MAC yang dideklarasikan
#     di klish diverifikasi ke RADIUS (titian-radius-check.py, PAP,
#     User-Name = MAC, User-Password = MAC). Hanya MAC yang RADIUS-accept
#     yang masuk allowlist. MAC yang RADIUS-reject / tidak terverifikasi
#     (RADIUS tidak terjangkau) DIKELUARKAN + warning (fail-closed).
#   - Bila mac-auth aktif tapi NOL MAC lolos verifikasi -> generate GAGAL
#     lantang (rc 33), config lama dipertahankan (jangan sampai DHCP
#     mati diam-diam untuk semua klien).
#   - Auth per-request real-time (cek RADIUS tiap DHCPDISCOVER) TIDAK
#     dimungkinkan isc-dhcpd; arsitektur yang benar untuk itu adalah
#     FreeRADIUS rlm_dhcp (FreeRADIUS sebagai DHCP server) — butuh paket
#     baru (tidak bisa di-install di mesin test, repo pkg 404) + keputusan
#     arsitektur. Lihat panduan §9a.3.
#
# KICK / DISCONNECT (19 Nov 2026): memutus layanan IPoE untuk satu MAC.
#   - `kick <mac>`: hapus lease aktif MAC itu (via OMAPI, tanpa restart
#     dhcpd) + blokir MAC (tambah ke blocked-mac) + regenerate dhcpd.conf
#     + restart dhcpd. Klien kehilangan IP-nya dan TIDAK BISA mendapat
#     lease baru (deny booting) sampai di-unblock.
#   - `unblock <mac>`: hapus MAC dari blocked-mac + regenerate + restart.
#   - Blokir = host declaration `deny booting` di dhcpd.conf (native
#     isc-dhcpd; berlaku baik saat radius-mac-auth aktif maupun tidak).
#     `deny booting` menang atas allowlist (server tidak merespons klien
#     itu sama sekali).
#   - Hapus lease = OMAPI (isc-dhcpd 4.4.3-P1, omshell). `remove` (destroy)
#     TIDAK diimplementasikan di versi ini ("can't destroy object: not
#     implemented") — cara benar: `set state = 1` (free) + `update`.
#     State OMAPI: 1 = free, 2 = active. Lease file isc-dhcpd bersifat
#     append-only — BLOK TERAKHIR untuk satu IP yang berlaku.
#   - OMAPI: dhcpd mendengarkan `*:7911` (semua interface; tidak ada opsi
#     bind-address di isc-dhcpd). Dilindungi key hmac-md5 acak (omapi-key,
#     digenerate sekali + disimpan di ipoe.conf mode 600). Jaringan lab
#     tepercaya; key WAJIB rahasia (sama seperti radius-secret).
#   - `kick` butuh dhcpd JALAN (untuk OMAPI). Bila dhcpd berhenti, kick
#     tetap memblokir MAC (deny booting) tapi lease tidak bisa dihapus
#     via OMAPI — lease akan bebas sendiri saat kedaluwarsa / saat
#     dhcpd restart (warning dicetak).
# State klish: $STATE_ROOT/ipoe.conf (mode 600 bila berisi radius-secret).
# Format state (satu baris per item):
#   enable
#   interface <if>
#   pool <net>/<mask> <start> <end> <gw> <dns> <lease>
#   radius-server <ip>
#   radius-secret <secret>            (tanpa spasi; TIDAK PERNAH di-echo)
#   radius-mac <aa:bb:cc:dd:ee:ff>    (MAC yang dideklarasikan)
#   radius-mac-auth                   (bare flag: enforcement aktif)
#   blocked-mac <aa:bb:cc:dd:ee:ff>   (MAC yang diblokir / di-kick)
#   omapi-key <base64>                (key OMAPI, digenerate otomatis;
#                                      TIDAK PERNAH di-echo)
# POSIX sh.
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CONF="$STATE_ROOT/ipoe.conf"
DHCPD_CONF="${TITIAN_DHCPD_CONF:-/usr/local/etc/dhcpd.conf}"
# Pager global: output show >1 layar lewat less (titian-page.sh).
# Prologue dipanggil SESUDAH setup warna/TTY bila ada, SEBELUM output pertama.
SBIN_DIR=$(dirname "$0")
. "$SBIN_DIR/titian-page.sh"
# Hanya subcommand baca yang dipager: set/generate/commit TIDAK —
# output-nya harus tetap streaming/langsung, bukan tertahan sampai EXIT.
case "${1:-}" in server-status|list-leases|list-blocked) titian_page_begin ;; esac

DHCPD_LEASES="${TITIAN_DHCPD_LEASES:-/var/db/dhcpd.leases}"
DHCPD_BIN="${TITIAN_DHCPD_BIN:-/usr/local/sbin/dhcpd}"
ROOT="${TITIAN_ROOT:-/opt/titian}"
RADIUS_CHECK="${TITIAN_RADIUS_CHECK:-$ROOT/sbin/titian-radius-check.py}"
RADIUS_PORT="${TITIAN_RADIUS_PORT:-1812}"
OMSHELL="${TITIAN_OMSHELL:-/usr/local/bin/omshell}"
OMAPI_PORT="${TITIAN_OMAPI_PORT:-7911}"
PROG="titian-dhcp"
err() { echo "Error($PROG): $*" >&2; exit 33; }
die() { echo "$PROG: $*" >&2; exit 1; }
warn() { echo "$PROG: warning: $*" >&2; }

touch_conf() {
    if [ ! -f "$CONF" ]; then
        mkdir -p "$(dirname "$CONF")" 2>/dev/null
        printf '# ipoe.conf - generated by klish, do not edit by hand\n' > "$CONF" \
            || die "cannot create $CONF"
        chmod 600 "$CONF" 2>/dev/null || true
    fi
}

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
    _re="$1"; _what="$2"
    touch_conf
    grep -q "$_re" "$CONF" 2>/dev/null || die "$_what not found"
    _tmp="$CONF.tmp.$$"
    grep -v "$_re" "$CONF" > "$_tmp" || true
    mv "$_tmp" "$CONF" || die "cannot write $CONF"
    chmod 600 "$CONF" 2>/dev/null || true
}

valid_v4() {
    _a="$1"
    case "$_a" in *.*.*.*) ;; *) return 1 ;; esac
    _o1=${_a%%.*}; _r=${_a#*.}; _o2=${_r%%.*}; _r=${_r#*.}; _o3=${_r%%.*}; _o4=${_r#*.}
    case "$_o4" in *.*) return 1 ;; esac
    for _o in "$_o1" "$_o2" "$_o3" "$_o4"; do
        case "$_o" in ''|*[!0-9]*) return 1 ;; esac
        [ "$_o" -ge 0 ] 2>/dev/null && [ "$_o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

valid_mac() {
    _m="$1"
    case "$_m" in
        ??:??:??:??:??:??) ;;
        *) return 1 ;;
    esac
    _old_ifs="$IFS"; IFS=':'
    set -- $_m
    IFS="$_old_ifs"
    [ "$#" -eq 6 ] || return 1
    for _o in "$1" "$2" "$3" "$4" "$5" "$6"; do
        case "$_o" in
            [0-9A-Fa-f][0-9A-Fa-f]) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# norm_mac <mac> -> MAC lowercase format colon (02:00:00:00:00:01).
norm_mac() {
    printf '%s' "$1" | tr 'A-F' 'a-f'
}

usage() {
    echo "Usage: $0 client-start <iface> | client-stop <iface> | server-generate | server-start | server-stop | server-status | server-restart | set-radius-server <ip> | del-radius-server | set-radius-secret <secret> | del-radius-secret | add-radius-mac <mac> | del-radius-mac <mac> | set-radius-mac-auth | del-radius-mac-auth | set-nas-ip <ip> | del-nas-ip | add-blocked-mac <mac> | del-blocked-mac <mac> | kick-lease <mac> | kick <mac> | unblock <mac> | list-leases | list-blocked" >&2
    exit 2
}

# --- IPoE client (DHCP) ---
client_start() {
    _if="$1"
    [ -n "$_if" ] || { echo "Error: interface required" >&2; exit 1; }
    # kill any stale dhclient for this iface, then start fresh
    pkill -f "dhclient.*[[:space:]]$_if" 2>/dev/null || true
    sleep 1
    if dhclient "$_if" 2>&1; then
        echo "IPoE (DHCP) started on $_if"
        # record intent so replay/boot can restore it
        mkdir -p "$STATE_ROOT/netstate" 2>/dev/null || true
        echo "dhcp" > "$STATE_ROOT/netstate/$_if.dhcp" 2>/dev/null || true
    else
        echo "Error: dhclient failed on $_if" >&2
        exit 1
    fi
}

client_stop() {
    _if="$1"
    [ -n "$_if" ] || { echo "Error: interface required" >&2; exit 1; }
    pkill -f "dhclient.*[[:space:]]$_if" 2>/dev/null || true
    # remove the address dhclient assigned (best effort)
    _ip="$(ifconfig "$_if" 2>/dev/null | awk '/inet /{print $2; exit}')"
    [ -n "$_ip" ] && ifconfig "$_if" -alias "$_ip" 2>/dev/null || true
    rm -f "$STATE_ROOT/netstate/$_if.dhcp" 2>/dev/null || true
    echo "IPoE (DHCP) stopped on $_if"
}

# --- RADIUS intent (klish) ---
cmd_set_radius_server() {
    valid_v4 "$1" || err "radius-server harus IPv4: $1"
    upsert '^radius-server ' "radius-server $1"
    echo "ipoe radius-server $1 (pending commit)"
    exit 0
}

cmd_del_radius_server() {
    dellines '^radius-server ' "radius-server"
    echo "radius-server dihapus (auth lokal)"
    exit 0
}

cmd_set_radius_secret() {
    _sec="$1"
    case "$_sec" in ''|*' '*) die "radius-secret tidak boleh kosong/berspasi" ;; esac
    upsert '^radius-secret ' "radius-secret $_sec"
    # JANGAN echo secret (pernah terekspos di PPPoE via klish).
    echo "ipoe radius-secret diubah (pending commit)"
    exit 0
}

cmd_del_radius_secret() {
    dellines '^radius-secret ' "radius-secret"
    echo "radius-secret dihapus"
    exit 0
}

cmd_add_radius_mac() {
    valid_mac "$1" || err "radius-mac harus MAC (aa:bb:cc:dd:ee:ff): $1"
    _mac=$(norm_mac "$1")
    touch_conf
    if grep -q "^radius-mac $_mac\$" "$CONF" 2>/dev/null; then
        echo "ipoe radius-mac $_mac sudah ada"
        exit 0
    fi
    printf '%s\n' "radius-mac $_mac" >> "$CONF"
    chmod 600 "$CONF" 2>/dev/null || true
    echo "ipoe radius-mac $_mac ditambahkan (pending commit)"
    exit 0
}

cmd_del_radius_mac() {
    valid_mac "$1" || err "radius-mac harus MAC (aa:bb:cc:dd:ee:ff): $1"
    _mac=$(norm_mac "$1")
    dellines "^radius-mac $_mac\$" "radius-mac $_mac"
    echo "radius-mac $_mac dihapus"
    exit 0
}

cmd_set_radius_mac_auth() {
    upsert '^radius-mac-auth$' "radius-mac-auth"
    echo "ipoe radius-mac-auth diaktifkan (pending commit)"
    exit 0
}

cmd_del_radius_mac_auth() {
    dellines '^radius-mac-auth$' "radius-mac-auth"
    echo "radius-mac-auth dimatikan (DHCP terbuka, tanpa RADIUS)"
    exit 0
}

# --- NAS-IP (untuk RADIUS accounting IPoE) ---
# NAS-IP-Address yang dikirim titian-ipoe-acct.py ke FreeRADIUS.
# Harus sama dengan nasname NAS di myRadDASH (mis. 103.50.128.18).
# Bila tidak diset, accounting memakai IP sumber UDP lokal + warning.
cmd_set_nas_ip() {
    valid_v4 "$1" || err "nas-ip harus IPv4: $1"
    upsert '^nas-ip ' "nas-ip $1"
    echo "ipoe nas-ip $1 (pending commit)"
    exit 0
}

cmd_del_nas_ip() {
    dellines '^nas-ip ' "nas-ip"
    echo "nas-ip dihapus (accounting pakai IP sumber lokal)"
    exit 0
}

# --- Blocked MAC (kick) ---
cmd_add_blocked_mac() {
    valid_mac "$1" || err "blocked-mac harus MAC (aa:bb:cc:dd:ee:ff): $1"
    _mac=$(norm_mac "$1")
    touch_conf
    if grep -q "^blocked-mac $_mac\$" "$CONF" 2>/dev/null; then
        echo "ipoe blocked-mac $_mac sudah ada"
        exit 0
    fi
    printf '%s\n' "blocked-mac $_mac" >> "$CONF"
    chmod 600 "$CONF" 2>/dev/null || true
    echo "ipoe blocked-mac $_mac ditambahkan (pending commit)"
    exit 0
}

cmd_del_blocked_mac() {
    valid_mac "$1" || err "blocked-mac harus MAC (aa:bb:cc:dd:ee:ff): $1"
    _mac=$(norm_mac "$1")
    dellines "^blocked-mac $_mac\$" "blocked-mac $_mac"
    echo "blocked-mac $_mac dihapus"
    exit 0
}

# --- OMAPI (hapus lease tanpa restart dhcpd) ---
# Ambil / generate omapi-key (disimpan di ipoe.conf, mode 600).
# Digenerate SEKALI (bila belum ada); sesudahnya dipakai ulang.
get_omapi_key() {
    _k=$(sed -n 's/^omapi-key //p' "$CONF" 2>/dev/null | head -1)
    if [ -z "$_k" ]; then
        _k=$(openssl rand -base64 24 2>/dev/null) \
            || _k=$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | base64 2>/dev/null) \
            || die "tidak bisa generate omapi-key (openssl/base64 tidak ada)"
        upsert '^omapi-key ' "omapi-key $_k"
    fi
    printf '%s' "$_k"
}

# Cari IP lease AKTIF untuk satu MAC (dari lease file; BLOK TERAKHIR
# per IP yang berlaku — file lease isc-dhcpd append-only).
# Output: IP, atau kosong bila tidak ada lease aktif untuk MAC itu.
find_lease_ip_for_mac() {
    _mac=$(norm_mac "$1")
    [ -f "$DHCPD_LEASES" ] || return 0
    awk -v mac="$_mac" '
        /^lease / { ip=$2; state=""; hw=""; }
        # Pola DIJANGKAR ke awal baris (setelah spasi) -- JANGAN /binding
        # state / tanpa jangkar: baris "next binding state free;" ikut
        # cocok dan menimpa state="active" menjadi state="state"
        # (bug live 19 Nov: lease aktif tidak tampil).
        /^[[:space:]]*binding state / { state=$3; sub(/;$/, "", state); }
        /^[[:space:]]*hardware ethernet / { hw=$3; sub(/;$/, "", hw); }
        /^}/ {
            if (hw == mac) { last_ip[ip]=ip; last_state[ip]=state; }
            ip=""; state=""; hw="";
        }
        END {
            for (i in last_ip) if (last_state[i] == "active") print last_ip[i];
        }
    ' "$DHCPD_LEASES" 2>/dev/null | head -1
}

# Bebaskan SATU lease via OMAPI: set state=1 (free) + update.
# Arg: IP lease. Return 0 bila berhasil, 1 bila gagal (pesan ke stderr).
omapi_free_lease() {
    _ip="$1"
    _key=$(get_omapi_key) || return 1
    [ -x "$OMSHELL" ] || { echo "omshell tidak ditemukan: $OMSHELL" >&2; return 1; }
    _out=$("$OMSHELL" <<EOF 2>&1
server 127.0.0.1
port $OMAPI_PORT
key omapi-key "$_key"
connect
new "lease"
set ip-address = $_ip
open
set state = 1
update
EOF
)
    _rc=$?
    # Verifikasi: buka lagi, state harus 1 (free).
    _st=$("$OMSHELL" <<EOF 2>/dev/null | awk '/^state =/{print $3; exit}'
server 127.0.0.1
port $OMAPI_PORT
key omapi-key "$_key"
connect
new "lease"
set ip-address = $_ip
open
EOF
)
    if [ "$_st" = "1" ] || [ "$_st" = "00:00:00:01" ]; then
        return 0
    fi
    echo "OMAPI: gagal membebaskan lease $_ip (state sesudah: ${_st:-?})" >&2
    echo "$_out" | grep -i "error\|can't\|fail" | head -3 >&2
    return 1
}

# Hapus lease aktif untuk satu MAC via OMAPI (tanpa restart dhcpd).
# Exit 0 bila lease dibebaskan / tidak ada lease aktif (nothing to do).
# Exit 1 bila ada lease aktif tapi OMAPI gagal membebaskannya.
cmd_kick_lease() {
    valid_mac "$1" || err "kick-lease harus MAC (aa:bb:cc:dd:ee:ff): $1"
    _mac=$(norm_mac "$1")
    _ip=$(find_lease_ip_for_mac "$_mac")
    if [ -z "$_ip" ]; then
        echo "ipoe: tidak ada lease aktif untuk $_mac (nothing to do)"
        exit 0
    fi
    if pgrep -x dhcpd >/dev/null 2>&1; then
        if omapi_free_lease "$_ip"; then
            echo "ipoe: lease $_mac ($_ip) dibebaskan via OMAPI"
            exit 0
        else
            echo "Error: OMAPI gagal membebaskan lease $_mac ($_ip)" >&2
            exit 1
        fi
    else
        echo "Error: dhcpd tidak jalan — lease $_mac ($_ip) tidak bisa dihapus via OMAPI" >&2
        exit 1
    fi
}

# Daftar lease AKTIF (IP, MAC, ends) — dari lease file, blok terakhir
# per IP. Dipakai `show ipoe leases`.
cmd_list_leases() {
    [ -f "$DHCPD_LEASES" ] || { echo "tidak ada lease file: $DHCPD_LEASES"; exit 0; }
    awk '
        /^lease / { ip=$2; state=""; hw=""; ends=""; }
        # Pola DIJANGKAR ke awal baris -- lihat find_lease_ip_for_mac
        # (bug live 19 Nov: "next binding state free;" menimpa state).
        /^[[:space:]]*binding state / { state=$3; sub(/;$/, "", state); }
        /^[[:space:]]*hardware ethernet / { hw=$3; sub(/;$/, "", hw); }
        /^[[:space:]]*ends / { ends=$3 " " $4; sub(/;$/, "", ends); }
        /^}/ {
            if (ip != "") { last_state[ip]=state; last_hw[ip]=hw; last_ends[ip]=ends; }
            ip=""; state=""; hw=""; ends="";
        }
        END {
            n=0
            for (i in last_state) {
                if (last_state[i] == "active") {
                    printf "%-15s %-17s %s\n", i, last_hw[i], last_ends[i];
                    n++;
                }
            }
            if (n == 0) print "(tidak ada lease aktif)";
        }
    ' "$DHCPD_LEASES" 2>/dev/null | sort
    exit 0
}

# Daftar MAC yang diblokir. Dipakai `show ipoe blocked`.
# CATATAN: JANGAN pakai `grep -c ... || echo 0` -- grep -c mencetak 0
# DAN exit 1 saat tidak ada yang cocok, sehingga hasilnya "0\n0".
cmd_list_blocked() {
    if ! grep -q '^blocked-mac ' "$CONF" 2>/dev/null; then
        echo "(tidak ada MAC diblokir)"
        exit 0
    fi
    grep '^blocked-mac ' "$CONF" 2>/dev/null | sed 's/^blocked-mac //' | sort -u
    exit 0
}

# KICK penuh: hapus lease aktif (OMAPI) + blokir MAC + regenerate +
# restart dhcpd (bila jalan). Lease yang tidak bisa dihapus (dhcpd
# berhenti / OMAPI gagal) TIDAK menggagalkan kick — blokir tetap jalan
# (klien tidak bisa renew / dapat lease baru), warning dicetak.
cmd_kick() {
    valid_mac "$1" || err "kick harus MAC (aa:bb:cc:dd:ee:ff): $1"
    _mac=$(norm_mac "$1")
    _was_running=0
    pgrep -x dhcpd >/dev/null 2>&1 && _was_running=1
    # 1) Hapus lease aktif (best-effort bila dhcpd jalan).
    _ip=$(find_lease_ip_for_mac "$_mac")
    if [ -n "$_ip" ]; then
        if [ "$_was_running" -eq 1 ]; then
            if omapi_free_lease "$_ip"; then
                echo "ipoe kick: lease $_mac ($_ip) dibebaskan via OMAPI"
            else
                warn "kick: OMAPI gagal membebaskan lease $_mac ($_ip) — blokir tetap jalan (lease bebas saat kedaluwarsa)"
            fi
        else
            warn "kick: dhcpd tidak jalan — lease $_mac ($_ip) tidak dihapus via OMAPI (bebas saat kedaluwarsa); blokir tetap jalan"
        fi
    else
        echo "ipoe kick: tidak ada lease aktif untuk $_mac"
    fi
    # 2) Blokir MAC (idempotent) + regenerate + restart bila dhcpd jalan.
    touch_conf
    if ! grep -q "^blocked-mac $_mac\$" "$CONF" 2>/dev/null; then
        printf '%s\n' "blocked-mac $_mac" >> "$CONF"
        chmod 600 "$CONF" 2>/dev/null || true
    fi
    server_generate || exit 1
    if [ "$_was_running" -eq 1 ]; then
        server_stop >/dev/null 2>&1
        sleep 1
        server_start || err "kick: dhcpd gagal restart sesudah blokir (config sudah regenerate)"
    fi
    echo "ipoe kick: $_mac DIBLOKIR (deny booting) — tidak bisa dapat lease lagi (unblock: ipoe unblock $_mac)"
    exit 0
}

# UNBLOCK: hapus MAC dari blocked-mac + regenerate + restart bila jalan.
cmd_unblock() {
    valid_mac "$1" || err "unblock harus MAC (aa:bb:cc:dd:ee:ff): $1"
    _mac=$(norm_mac "$1")
    _was_running=0
    pgrep -x dhcpd >/dev/null 2>&1 && _was_running=1
    if ! grep -q "^blocked-mac $_mac\$" "$CONF" 2>/dev/null; then
        echo "ipoe unblock: $_mac tidak ada di daftar blokir"
        exit 0
    fi
    dellines "^blocked-mac $_mac\$" "blocked-mac $_mac" || exit 1
    server_generate || exit 1
    if [ "$_was_running" -eq 1 ]; then
        server_stop >/dev/null 2>&1
        sleep 1
        server_start || err "unblock: dhcpd gagal restart (config sudah regenerate)"
    fi
    echo "ipoe unblock: $_mac dibuka lagi (bisa dapat lease)"
    exit 0
}

# --- IPoE server (isc-dhcpd) ---
# Config source: $STATE_ROOT/ipoe.conf (generated by commit from klish intent).
# Format (one per line): interface <iface> | pool <net>/<mask> <start> <end> <gw> <dns> <lease>
#   | radius-server <ip> | radius-secret <secret> | radius-mac <mac> | radius-mac-auth
server_generate() {
    _intent="$STATE_ROOT/ipoe.conf"
    [ -f "$_intent" ] || { echo "Error: no IPoE server intent ($STATE_ROOT/ipoe.conf)" >&2; exit 1; }
    _rs=$(sed -n 's/^radius-server //p' "$_intent" | head -1)
    _rsec=$(sed -n 's/^radius-secret //p' "$_intent" | head -1)
    _rma=0
    grep -q '^radius-mac-auth$' "$_intent" 2>/dev/null && _rma=1
    _allowed=""
    _n_ok=0; _n_bad=0
    if [ "$_rma" -eq 1 ]; then
        [ -n "$_rs" ] || err "radius-mac-auth aktif tapi radius-server belum diset"
        [ -n "$_rsec" ] || err "radius-mac-auth aktif tapi radius-secret belum diset"
        valid_v4 "$_rs" || err "radius-server harus IPv4: $_rs"
        [ -x "$RADIUS_CHECK" ] || [ -f "$RADIUS_CHECK" ] || err "helper RADIUS tidak ditemukan: $RADIUS_CHECK"
        # Verifikasi tiap MAC ke RADIUS (PAP, User-Name = MAC).
        # Hanya yang Accept yang masuk allowlist (fail-closed).
        for _m in $(sed -n 's/^radius-mac //p' "$_intent" 2>/dev/null); do
            if python3 "$RADIUS_CHECK" --server "$_rs" --secret "$_rsec" --user "$_m" --password "$_m" --port "$RADIUS_PORT" >/dev/null 2>&1; then
                _allowed="$_allowed $_m"
                _n_ok=$((_n_ok + 1))
            else
                warn "radius-mac $_m DITOLAK / tidak terverifikasi RADIUS ($_rs) — dikeluarkan dari allowlist"
                _n_bad=$((_n_bad + 1))
            fi
        done
        if [ "$_n_ok" -eq 0 ]; then
            err "radius-mac-auth aktif tapi NOL MAC lolos verifikasi RADIUS (declared: $((_n_ok + _n_bad)), ditolak/tak-terjangkau: $_n_bad) — generate dibatalkan, config lama dipertahankan"
        fi
        echo "ipoe: RADIUS MAC-auth aktif ($_rs): $_n_ok MAC lolos, $_n_bad ditolak/tak-terjangkau"
    fi
    _tmp="$DHCPD_CONF.titian-tmp"
    # OMAPI key (digenerate sekali bila belum ada; dipakai omshell
    # untuk hapus lease saat kick). Key TIDAK PERNAH di-echo.
    _omapi_key=$(get_omapi_key) || err "gagal siapkan omapi-key"
    {
        echo "# dhcpd.conf generated by Titian (IPoE server) — do not edit by hand"
        echo "authoritative;"
        echo "default-lease-time 86400;"
        echo "max-lease-time 86400;"
        echo "log-facility local7;"
        echo "# OMAPI (kick: hapus lease tanpa restart dhcpd). Port 7911"
        echo "# mendengarkan *:7911 — dilindungi key hmac-md5 (omapi-key)."
        echo "key omapi-key {"
        echo "  algorithm hmac-md5;"
        echo "  secret \"$_omapi_key\";"
        echo "}"
        echo "omapi-port 7911;"
        echo "omapi-key omapi-key;"
        if [ "$_rma" -eq 1 ]; then
            echo "# RADIUS MAC-auth aktif (server $_rs): hanya MAC di bawah ini yang dapat lease."
            echo "# Allowlist diverifikasi ke RADIUS saat generate (bukan per-request)."
            echo "class \"radius-allowed\" {"
            echo "  match hardware;"
            echo "}"
            for _m in $_allowed; do
                echo "subclass \"radius-allowed\" 1:$_m;"
            done
        fi
        awk -v rma="$_rma" '
            function cidr2mask(p,    m, i) {
                # Convert CIDR prefix (e.g. 24) to dotted-quad netmask (255.255.255.0)
                m = ""
                for (i = 0; i < 4; i++) {
                    if (p >= 8) { m = m "255"; p -= 8 }
                    else if (p > 0) { m = m (256 - 2^(8-p)); p = 0 }
                    else { m = m "0" }
                    if (i < 3) m = m "."
                }
                return m
            }
            $1 == "interface" { print "# listen on " $2 }
            $1 == "pool" {
                # pool <net>/<mask> <start> <end> <gw> <dns> <lease>
                split($2, a, "/")
                print "subnet " a[1] " netmask " cidr2mask(a[2]+0) " {"
                if (rma == 1) {
                    print "  pool {"
                    print "    allow members of \"radius-allowed\";"
                    print "    range " $3 " " $4 ";"
                    print "    option routers " $5 ";"
                    print "    option domain-name-servers " $6 ";"
                    if ($7 != "") print "    default-lease-time " $7 ";"
                    print "  }"
                    print "  deny unknown-clients;"
                } else {
                    print "  range " $3 " " $4 ";"
                    print "  option routers " $5 ";"
                    print "  option domain-name-servers " $6 ";"
                    if ($7 != "") print "  default-lease-time " $7 ";"
                }
                print "}"
            }
        ' "$_intent"
        # MAC yang diblokir (kick): host declaration deny booting.
        # Berlaku baik saat radius-mac-auth aktif maupun tidak; menang
        # atas allowlist (server tidak merespons klien itu sama sekali).
        _nblk=$(grep -c '^blocked-mac ' "$_intent" 2>/dev/null || echo 0)
        if [ "$_nblk" != "0" ] && [ -n "$_nblk" ]; then
            echo "# MAC yang diblokir (kick) — tidak mendapat lease (deny booting)."
            for _bm in $(sed -n 's/^blocked-mac //p' "$_intent" 2>/dev/null); do
                _bname=$(printf '%s' "$_bm" | tr -d ':')
                echo "host blocked-$_bname {"
                echo "  hardware ethernet $_bm;"
                echo "  deny booting;"
                echo "}"
            done
        fi
    } > "$_tmp" || die "cannot write $DHCPD_CONF"
    # Validasi sintaks sebelum pakai (gagal lantang, config lama aman).
    if [ -x "$DHCPD_BIN" ]; then
        "$DHCPD_BIN" -t -cf "$_tmp" >/dev/null 2>&1 || { rm -f "$_tmp"; err "dhcpd.conf hasil generate TIDAK VALID (dhcpd -t gagal) — config lama dipertahankan"; }
    fi
    mv "$_tmp" "$DHCPD_CONF" || die "cannot write $DHCPD_CONF"
    touch "$DHCPD_LEASES" 2>/dev/null || true
    echo "dhcpd.conf generated: $DHCPD_CONF"
}

server_start() {
    server_generate || exit 1
    if [ -x "$DHCPD_BIN" ]; then
        # dhcpd needs at least one listen interface with an IP; use intent interfaces
        _ifs="$(awk '$1=="interface"{print $2}' "$STATE_ROOT/ipoe.conf" 2>/dev/null | tr '\n' ' ')"
        if "$DHCPD_BIN" -q $_ifs 2>&1; then
            echo "IPoE server (dhcpd) started on: $_ifs"
        else
            echo "Error: dhcpd failed to start" >&2
            exit 1
        fi
    else
        echo "Error: $DHCPD_BIN not found" >&2
        exit 1
    fi
}

server_stop() {
    pkill -x dhcpd 2>/dev/null || true
    echo "IPoE server (dhcpd) stopped"
}

server_restart() {
    server_stop >/dev/null 2>&1
    sleep 1
    server_start
}

server_status() {
    if pgrep -x dhcpd >/dev/null 2>&1; then
        echo "IPoE server (dhcpd): running (pid $(pgrep -x dhcpd | head -1))"
    else
        echo "IPoE server (dhcpd): not running"
    fi
    [ -f "$DHCPD_CONF" ] && echo "config: $DHCPD_CONF" || echo "config: (none)"
    _rs=$(sed -n 's/^radius-server //p' "$CONF" 2>/dev/null | head -1)
    # grep -c mencetak 0 DAN exit 1 saat tidak ada yang cocok -- pakai
    # grep -q + wc -l agar hitungan bersih (bukan "0\n0").
    _nmac=$(grep '^radius-mac ' "$CONF" 2>/dev/null | wc -l | tr -d ' ')
    _nblk=$(grep '^blocked-mac ' "$CONF" 2>/dev/null | wc -l | tr -d ' ')
    if grep -q '^radius-mac-auth$' "$CONF" 2>/dev/null; then
        echo "radius-mac-auth: aktif (server ${_rs:-unset}, $_nmac MAC dideklarasikan)"
    else
        echo "radius-mac-auth: nonaktif (DHCP terbuka)"
    fi
    echo "blocked-mac: ${_nblk:-0} MAC diblokir (kick)"
}

case "$1" in
    client-start)   client_start "$2" ;;
    client-stop)    client_stop "$2" ;;
    server-generate) server_generate ;;
    server-start)   server_start ;;
    server-stop)    server_stop ;;
    server-status)  server_status ;;
    server-restart) server_restart ;;
    set-radius-server) cmd_set_radius_server "${2:-}" ;;
    del-radius-server) cmd_del_radius_server ;;
    set-radius-secret) cmd_set_radius_secret "${2:-}" ;;
    del-radius-secret) cmd_del_radius_secret ;;
    add-radius-mac) cmd_add_radius_mac "${2:-}" ;;
    del-radius-mac) cmd_del_radius_mac "${2:-}" ;;
    set-radius-mac-auth) cmd_set_radius_mac_auth ;;
    del-radius-mac-auth) cmd_del_radius_mac_auth ;;
    set-nas-ip) cmd_set_nas_ip "${2:-}" ;;
    del-nas-ip) cmd_del_nas_ip ;;
    add-blocked-mac) cmd_add_blocked_mac "${2:-}" ;;
    del-blocked-mac) cmd_del_blocked_mac "${2:-}" ;;
    kick-lease) cmd_kick_lease "${2:-}" ;;
    kick) cmd_kick "${2:-}" ;;
    unblock) cmd_unblock "${2:-}" ;;
    list-leases) cmd_list_leases ;;
    list-blocked) cmd_list_blocked ;;
    *) usage ;;
esac
