#!/bin/sh
# titian-remote-kick.sh -- wrapper SSH terbatas untuk kick/disconnect
# dari myRadDASH (19 Nov 2026).
# Keputusan user 19:30: pemutusan layanan/kick via SSH (BUKAN CoA --
# mpd5 tidak mendengarkan CoA port 3799, dan membangun listener CoA
# menambah komponen; SSH lebih sederhana + robust). Keputusan user
# 19:31: SSH pakai key DEDIKASI (bukan password, bukan key utama user).
# Cara pakai: public key dedikasi dipasang di authorized_keys Titian
# dengan forced command:
#   command="/opt/titian/sbin/titian-remote-kick.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty <public-key>
# Saat myRadDASH SSH dengan key itu, sshd menjalankan skrip ini (bukan
# perintah klien). Perintah asli klien ada di SSH_ORIGINAL_COMMAND.
# Skrip ini HANYA mengizinkan perintah kick/disconnect/status berikut
# (allowlist); yang lain DITOLAK. TIDAK PERNAH eval input klien --
# perintah di-parse (word split) + tiap argumen divalidasi ketat
# (MAC / IPv4 / username) sebelum diteruskan ke backend. Jadi walau
# private key bocor, penyerang TIDAK bisa mendapat shell bebas --
# hanya bisa kick/unblock/disconnect/status.
# Perintah yang diizinkan (yang dikirim myRadDASH sebagai
# `ssh ... "<perintah>"`):
#   kick <mac>                  Putus IPoE: hapus lease (OMAPI) + blokir MAC
#   unblock <mac>               Buka blokir MAC IPoE
#   disconnect-pppoe <user> <framed-ip>
#                               Putus sesi PPPoE via console mpd5
#                               (verifikasi sesi + close LCP)
#   status                      Status IPoE server + lease + blocked (read-only)
#   leases                      Daftar lease DHCP aktif (read-only)
#   blocked                     Daftar MAC diblokir (read-only)
#   pppoe-sessions              Sesi PPPoE aktif (read-only)
# Private key ada di host myRadDASH (/root/.ssh/myraddash-titian-kick,
# mode 600). Public key di Titian (/root/.ssh/authorized_keys).
# Password TIDAK dipakai (root password image BSDRP kosong + password
# auth tidak bisa diotomasi dengan aman).
# POSIX sh. Exit = rc backend (0 sukses, 1 gagal, 2 usage).
ROOT="${TITIAN_ROOT:-/opt/titian}"
SBIN="${TITIAN_SBIN:-$ROOT/sbin}"
PROG="titian-remote-kick"

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

valid_user() {
    case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; *) return 0 ;; esac
}

reject() {
    echo "$PROG: perintah tidak diizinkan: ${SSH_ORIGINAL_COMMAND:-<kosong>}" >&2
    echo "$PROG: yang diizinkan: kick <mac> | unblock <mac> | disconnect-pppoe <user> <framed-ip> | status | leases | blocked | pppoe-sessions" >&2
    exit 1
}

# Tanpa perintah (mis. SSH interaktif tanpa command) -> tolak. Ini yang
# mencegah shell bebas walau key dipakai langsung.
[ -n "${SSH_ORIGINAL_COMMAND:-}" ] || reject

# Parse (word split saja -- TIDAK eval). Kelebihan argumen ditolak.
# shellcheck disable=SC2086
set -- $SSH_ORIGINAL_COMMAND
_cmd="$1"

case "$_cmd" in
    kick)
        [ "$#" -eq 2 ] || reject
        _mac=$(printf '%s' "$2" | tr 'A-F' 'a-f')
        valid_mac "$_mac" || reject
        exec "$SBIN/titian-dhcp.sh" kick "$_mac"
        ;;
    unblock)
        [ "$#" -eq 2 ] || reject
        _mac=$(printf '%s' "$2" | tr 'A-F' 'a-f')
        valid_mac "$_mac" || reject
        exec "$SBIN/titian-dhcp.sh" unblock "$_mac"
        ;;
    disconnect-pppoe)
        [ "$#" -eq 3 ] || reject
        valid_user "$2" || reject
        valid_v4 "$3" || reject
        exec "$SBIN/titian-pppoe.sh" disconnect "$2" "$3"
        ;;
    status)
        [ "$#" -eq 1 ] || reject
        "$SBIN/titian-dhcp.sh" server-status
        echo "--- leases ---"
        "$SBIN/titian-dhcp.sh" list-leases
        echo "--- blocked ---"
        "$SBIN/titian-dhcp.sh" list-blocked
        exit 0
        ;;
    leases)
        [ "$#" -eq 1 ] || reject
        exec "$SBIN/titian-dhcp.sh" list-leases
        ;;
    blocked)
        [ "$#" -eq 1 ] || reject
        exec "$SBIN/titian-dhcp.sh" list-blocked
        ;;
    pppoe-sessions)
        [ "$#" -eq 1 ] || reject
        exec "$SBIN/titian-pppoe.sh" show-sessions
        ;;
    *)
        reject
        ;;
esac
