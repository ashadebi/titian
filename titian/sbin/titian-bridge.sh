#!/bin/sh
# titian-bridge.sh — backend bridge L2 (FreeBSD if_bridge) untuk Titian.
# Memetakan layanan L2: bridge menggabungkan interface L2 (vxlan,
# vlan, ethernet, lagg) ke satu segmen broadcast. Pola utama: VXLAN
# overlay dijembatani ke VLAN / interface lokal.
#
# Usage: titian-bridge.sh create <bridge> | destroy <bridge>
#        titian-bridge.sh add-member <bridge> <iface>
#        titian-bridge.sh del-member <bridge> <iface>
#        titian-bridge.sh show [bridge]
#
# POSIX sh, no bashisms. FreeBSD 16 (if_bridge) + Linux (brctl/ip)
# — saat ini hanya FreeBSD yang diimplementasi penuh.
#
# BSDRP_klish, dibuat 2026-11-12 (fitur bridge atas perintah user).

PROG="titian-bridge"
OS=$(uname -s 2>/dev/null || echo FreeBSD)

err() { echo "Error: $*" >&2; exit 33; }
warn() { echo "Warning: $*" >&2; }

iface_exists() {
    ifconfig "$1" >/dev/null 2>&1
}

# --- create: buat bridge + tandai managed + persistenkan modul ---
cmd_create() {
    _br="$1"
    case "$_br" in
        bridge[0-9]*|bridge[0-9]) : ;;
        *) err "nama bridge harus bridge[N] (contoh bridge0)" ;;
    esac
    if [ "$OS" = "FreeBSD" ]; then
        kldload if_bridge 2>/dev/null || true
        if ! grep -qx 'if_bridge_load="YES"' /boot/loader.conf 2>/dev/null; then
            echo 'if_bridge_load="YES"' >> /boot/loader.conf 2>/dev/null || \
                warn "gagal tulis /boot/loader.conf (modul if_bridge tidak persisten reboot)"
        fi
        if ! iface_exists "$_br"; then
            ifconfig "$_br" create || err "gagal create $_br"
        fi
        ifconfig "$_br" up 2>/dev/null || true
    else
        err "bridge belum didukung di $OS (baru FreeBSD)"
    fi
    # Tandai managed agar ikut persist + startup-config.
    if [ -x "${RT_SBIN:-/opt/titian/sbin}/titian-persist.sh" ]; then
        "${RT_SBIN:-/opt/titian/sbin}/titian-persist.sh" mark-if "$_br" 2>/dev/null || true
    fi
    echo "bridge $_br dibuat"
    exit 0
}

# --- destroy: hapus bridge ---
cmd_destroy() {
    _br="$1"
    if iface_exists "$_br"; then
        ifconfig "$_br" destroy 2>/dev/null || err "gagal destroy $_br (masih ada anggota? lepas dulu)"
    else
        echo "$_br not found (already hilang)"
        exit 0
    fi
    if [ -x "${RT_SBIN:-/opt/titian/sbin}/titian-persist.sh" ]; then
        "${RT_SBIN:-/opt/titian/sbin}/titian-persist.sh" drop-if "$_br" 2>/dev/null || true
    fi
    echo "bridge $_br deleted"
    exit 0
}

# --- add-member: gabung interface ke bridge ---
cmd_add_member() {
    _br="$1"; _if="$2"
    iface_exists "$_br" || err "bridge $_br tidak ada (buat dulu: interface bridge $_br)"
    iface_exists "$_if" || err "interface $_if tidak ditemukan di sistem (lihat 'show interfaces')"
    if [ "$_br" = "$_if" ]; then
        err "bridge tidak bisa menjadi anggota dirinya sendiri"
    fi
    # Anggota harus UP agar bridge meneruskan trafik.
    ifconfig "$_if" up 2>/dev/null || true
    if ! ifconfig "$_br" addm "$_if" 2>/dev/null; then
        # Sudah anggota? cek.
        if ifconfig "$_br" 2>/dev/null | grep -q "member: $_if"; then
            echo "$_if already anggota $_br"
            exit 0
        fi
        err "gagal tambah $_if ke $_br"
    fi
    echo "$_if added to $_br"
    exit 0
}

# --- del-member: lepas interface dari bridge ---
cmd_del_member() {
    _br="$1"; _if="$2"
    if ! iface_exists "$_br"; then
        echo "bridge $_br no  (already hilang)"
        exit 0
    fi
    if ! ifconfig "$_br" deletem "$_if" 2>/dev/null; then
        if ! ifconfig "$_br" 2>/dev/null | grep -q "member: $_if"; then
            echo "$_if not anggota $_br"
            exit 0
        fi
        err "gagal lepas $_if dari $_br"
    fi
    echo "$_if dilepas from $_br"
    exit 0
}

# --- show: tampilkan bridge + anggota ---
cmd_show() {
    _br="$1"
    if [ -n "$_br" ]; then
        if ! iface_exists "$_br"; then
            echo "$_br not found"
            exit 0
        fi
        _list="$_br"
    else
        _list=$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^bridge[0-9]' || true)
        if [ -z "$_list" ]; then
            echo "(no bridges)"
            exit 0
        fi
    fi
    for _b in $_list; do
        echo "== $_b =="
        ifconfig "$_b" 2>/dev/null | grep -E "flags|ether|inet |member:" | sed 's/^/  /'
    done
    exit 0
}

# --- dispatch ---
RT_SBIN=$(dirname "$0" 2>/dev/null || echo /opt/titian/sbin)
case "$1" in
    create)     shift; cmd_create "$@" ;;
    destroy)    shift; cmd_destroy "$@" ;;
    add-member) shift; cmd_add_member "$@" ;;
    del-member) shift; cmd_del_member "$@" ;;
    show)       shift; cmd_show "$@" ;;
    *) echo "usage: $PROG <create|destroy|add-member|del-member|show> ..." >&2; exit 2 ;;
esac
