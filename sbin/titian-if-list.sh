#!/bin/sh
# TITIAN Fase 1 — daftar interface untuk completion klish (VAR Get_if_*).
# Linux: /sys/class/net (fallback /proc/net/dev).
# FreeBSD: ifconfig -l.
# Aturan kategori `eth` (2 Nov 2026, PTYPE terpadu): EXCLUSION-based,
# bukan pola nama — supaya interface yang di-rename di level OS tetap
# muncul di completion. `eth` = semua interface sistem KECUALI loopback
# (lo/lo0/lo[1-9]) dan objek virtual Titian (bond*, lagg*, vlan*,
# vxlan*, dan subinterface bertitik di Linux). Deteksi fisik via
# symlink `device` di /sys/class/net DIEVALUASI dan DITOLAK: interface
# software (dummy/macvlan/veth) tidak punya symlink device, padahal
# sah di-rename dan dikelola lewat view ethernet — aturan device hanya
# akan menyembunyikan mereka. `vlan` Linux = semua nama bertitik
# (parent boleh nama hasil rename, mis. wan0.100). Kategori bond/lagg/
# vxlan/dummy adalah nama objek buatan Titian — tetap pola nama.
# POSIX sh.
OS=$(uname -s)
list_linux() {
    if [ -d /sys/class/net ]; then
        # Hanya DIREKTORI = interface nyata. /sys/class/net juga memuat
        # berkas non-interface (mis. bonding_masters saat modul bonding
        # termuat) yang BUKAN interface dan tidak boleh masuk completion.
        for _e in /sys/class/net/*; do
            [ -d "$_e" ] || continue
            basename "$_e"
        done
    else
        awk -F: '{gsub(/ /,"",$1); print $1}' /proc/net/dev 2>/dev/null | grep -v '^$'
    fi
}
list_fbsd() { ifconfig -l 2>/dev/null; }
case "$OS" in
    FreeBSD) ALL=$(list_fbsd) ;;
    *)       ALL=$(list_linux) ;;
esac
# Normalisasi ke satu nama per baris: ifconfig -l FreeBSD mengeluarkan
# SEMUA nama dalam satu baris dipisah spasi, sehingga pola grep yang
# berjangkar (^...$) tidak pernah cocok bila ALL dibiarkan satu baris
# (gejala: kategori eth FreeBSD == all, vlan/bond/lagg kosong).
# printf '%s\n' dengan $ALL tak dikutip memecah spasi jadi baris-baris.
if [ -n "$ALL" ]; then ALL=$(printf '%s\n' $ALL); fi
case "${1:-all}" in
    eth)
        # Exclusion-based: interface hasil rename tidak cocok pola nama
        # apa pun — justru karena itu ia harus lolos di sini.
        if [ "$OS" = "FreeBSD" ]; then
            echo "$ALL" | grep -v -E '^lo[0-9]+$|^lagg[0-9]+$|^vlan[0-9]+$|^vxlan[0-9]+$|^bond[0-9]+$|^bridge[0-9]+$' | sort
        else
            echo "$ALL" | grep -v -E '^lo[0-9]*$|^bond[0-9]+$|^vxlan[0-9]+$|^lagg[0-9]+$' | grep -v '\.' | sort
        fi
        ;;
    vlan)
        if [ "$OS" = "FreeBSD" ]; then
            echo "$ALL" | grep -E '^vlan[0-9]+$' | sort
        else
            # Semua nama bertitik = subinterface vlan; parent boleh
            # nama hasil rename (wan0.100).
            echo "$ALL" | grep '\.' | sort
        fi
        ;;
    bond)
        if [ "$OS" = "FreeBSD" ]; then
            exit 0
        else
            echo "$ALL" | grep -E '^bond[0-9]+$' | sort
        fi
        ;;
    lagg)
        if [ "$OS" = "FreeBSD" ]; then
            echo "$ALL" | grep -E '^lagg[0-9]+$' | sort
        else
            exit 0
        fi
        ;;
    vxlan)
        echo "$ALL" | grep -E '^vxlan[0-9]+$' | sort
        ;;
    bridge)
        echo "$ALL" | grep -E '^bridge[0-9]+$' | sort
        ;;
    dummy)
        echo "$ALL" | grep -E '^lo[1-9]$' | sort
        ;;
    all)
        echo "$ALL" | sort
        ;;
    *) echo "Usage: $0 {eth|vlan|bond|lagg|vxlan|bridge|dummy|all}" >&2; exit 2 ;;
esac
