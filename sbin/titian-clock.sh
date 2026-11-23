#!/bin/sh
# titian-clock.sh — tampilkan tanggal/waktu + zona waktu (show date).
# Dipanggil ACTION `show date` di en-show.xml.
#
# Zona waktu dibaca dari /etc/localtime (symlink ke
# /usr/share/zoneinfo/<zona>, diatur perintah `system time-zone`
# di configure view). Bila /etc/localtime bukan symlink (mis. salinan
# atau belum diatur), nama zona tidak dapat ditentukan — tampilkan
# petunjuk pengaturannya, bukan menebak.
#
# Usage: titian-clock.sh show
# POSIX sh. Dibuat 2026-11-19 (permintaan user: show date + set time-zone).

PROG="titian-clock"

case "${1:-}" in
    show)
        _tz=$(readlink /etc/localtime 2>/dev/null | sed 's|^/usr/share/zoneinfo/||')
        if [ -z "$_tz" ]; then
            if [ -f /etc/localtime ]; then
                _tz="(tidak dapat ditentukan dari /etc/localtime — atur dengan 'system time-zone <zona>')"
            else
                _tz="(belum diatur — atur dengan 'system time-zone <zona>')"
            fi
        fi
        echo "Waktu lokal: $(date)"
        echo "Zona waktu: $_tz"
        echo "UTC.......: $(TZ=UTC date)"
        ;;
    *) echo "usage: $PROG show" >&2; exit 2 ;;
esac
exit 0
