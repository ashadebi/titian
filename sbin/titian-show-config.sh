#!/bin/sh
# titian-show-config.sh — tampilkan startup-config / running-config
# lewat pager (dipanggil ACTION `show startup-config` /
# `show running-config` di en-show.xml).
#
# MASALAH (Temuan 2, 19 Nov 2026): en-show.xml memanggil pager
# langsung pada ${RT_ROOT}/etc/startup-config
# (/opt/titian/etc/startup-config) — file yang TIDAK PERNAH ditulis
# skrip manapun. Startup-config yang sebenarnya hidup di
# $STATE_ROOT/startup-config (/etc/titian: ditulis dump klish saat
# `save`, dipersistenkan titian-cfg.sh ke /cfg/titian). Akibatnya
# `show startup-config` SELALU error "pager file not found" — bahkan
# dengan konfigurasi lengkap. Perintah ini memperbaikinya: baca lokasi
# yang sebenarnya; bila file belum ada, tampilkan pesan kosong (bukan
# error). Jalur save/checkpoint TIDAK diubah (nol risiko regresi di
# sana) — yang diperbaiki hanya jalur BACA show.
#
# Sama untuk running-config: dump klish ke /tmp/titian-show-run.conf
# TIDAK dibuat bila running-config kosong, jadi pager error juga —
# helper ini memastikan file dump ada (kosong = tampil kosong, rc 0).
#
# Usage: titian-show-config.sh {startup|running} [no-more]
# Hermetik (uji): TITIAN_STATE_ROOT / TITIAN_SHOW_RUN_FILE /
# TITIAN_ROOT. Produksi TIDAK PERNAH men-set variabel ini.
#
# POSIX sh. Dibuat 2026-11-19 (perbaikan Temuan 2 uji live factory-reset).

PROG="titian-show-config"
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
RUN_FILE=${TITIAN_SHOW_RUN_FILE:-/tmp/titian-show-run.conf}
SBIN_DIR=$(dirname "$0")
PAGER="$SBIN_DIR/titian-pager.sh"
[ -x "$PAGER" ] || PAGER="${TITIAN_ROOT:-/opt/titian}/sbin/titian-pager.sh"

case "${1:-}" in
    startup)
        _src="$STATE_ROOT/startup-config"
        if [ ! -f "$_src" ]; then
            echo "(startup-config kosong — belum ada konfigurasi tersimpan; jalankan 'save' sesudah 'commit')"
            exit 0
        fi
        sh "$PAGER" "$_src" "${2:-}"; exit $? ;;
    running)
        if [ ! -f "$RUN_FILE" ]; then
            : > "$RUN_FILE" 2>/dev/null || { echo "Error: $PROG: tidak bisa membuat $RUN_FILE" >&2; exit 33; }
        fi
        sh "$PAGER" "$RUN_FILE" "${2:-}"; exit $? ;;
    *) echo "usage: $PROG {startup|running} [no-more]" >&2; exit 2 ;;
esac
exit 0
