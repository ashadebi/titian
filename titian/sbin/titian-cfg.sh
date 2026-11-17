#!/bin/sh
# titian-cfg.sh — persistensi Titian ke partisi cfg BSDRP (/cfg).
#
# MASALAH (12 Nov 2026): /etc adalah tmpfs (hilang saat reboot) dan /
# read-only. `save` hanya menulis /etc/titian/startup-config (tmpfs),
# sehingga sesudah reboot config hilang (vxlan/bridge/SFP lenyap) dan
# `show startup-config` balik baca yang lama di /opt/titian.
# Partisi cfg (/dev/gpt/cfg, mount /cfg, rw) adalah tempat persisten
# BSDRP (rc.conf dll. di-restore dari sana saat boot).
#
# Usage: titian-cfg.sh save | save-now | save-wait <sig> | restore
#   save      — JADWALKAN persist ke /cfg/titian (proses latar).
#               Dipanggil ACTION `save` di enable-mode.xml.
#   save-now  — salin sinkron SEGERA (tanpa menunggu dump). HANYA
#               untuk pemakaian manual sesudah dump sudah mendarat
#               (mis. dari shell); JANGAN dipakai di ACTION `save`.
#   save-wait — pekerja latar save: tunggu dump mendarat lalu salin.
#   restore   — mount /cfg, bila /cfg/titian/startup-config ada, salin
#               balik ke /etc/titian/ (dipanggil titian-boot.sh sebelum
#               replay, agar replay menemukan config).
#
# KENAPA save DITUNDA (bug tes 16, pola konsisten 3x): klish menulis
# dump startup-config BARU sesudah ACTION `save` selesai — jadi
# salinan sinkron di dalam ACTION selalu menyalin file LAMA
# (/cfg tertinggal satu versi; baru sinkron sesudah `save` kedua).
# Solusinya: ACTION hanya melepas proses latar (setsid bila ada)
# yang menunggu sidik isi startup-config berubah (dump mendarat)
# baru menyalin ke /cfg. Bila dump tidak mendarat dalam 10 detik,
# salin apa adanya (best-effort) + catat peringatan.
#
# POSIX sh. Best-effort: gagal mount/salin = warning, bukan fatal
# (live session tetap jalan dari /etc/titian).
#
# BSDRP_klish, dibuat 2026-11-12 (fix persistensi cfg);
# diperbaiki 2026-11-15 (save tertinggal satu versi -> persist latar).

PROG="titian-cfg"
CFG_MNT="/cfg"
CFG_DIR="/cfg/titian"
STATE_DIR="/etc/titian"

mount_cfg() {
    if mount 2>/dev/null | grep -q "[[:space:]]/cfg[[:space:]]"; then
        return 0
    fi
    mount /cfg 2>/dev/null && return 0
    echo "Warning: $PROG: failed mount /cfg (config Not persisten reboot)" >&2
    return 1
}

ROOT=${TITIAN_ROOT:-/opt/titian}
SBIN_DIR=$(dirname "$0")

file_sig() {
    # $1 = file -> cetak sidik isi (hash) atau kosong bila file tak ada.
    # Portable: md5 FreeBSD (`md5 -q`), GNU (`md5sum`), fallback cksum.
    _f="$1"
    [ -f "$_f" ] || { echo ""; return 0; }
    if command -v md5 >/dev/null 2>&1; then
        md5 -q "$_f" 2>/dev/null && return 0
    fi
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$_f" 2>/dev/null | awk '{print $1}' && return 0
    fi
    cksum "$_f" 2>/dev/null | awk '{print $1"-"$2}' || echo ""
}

copy_all() {
    # Salin startup-config + netstate + aux dari /etc ke /cfg.
    # Dipakai save-now (sinkron) dan save-wait (sesudah dump mendarat).
    [ -f "$STATE_DIR/startup-config" ] || {
        echo "Warning: $PROG: $STATE_DIR/startup-config tidak ada (belum save?)" >&2
        return 1
    }
    cp -f "$STATE_DIR/startup-config" "$CFG_DIR/startup-config" 2>/dev/null || {
        echo "Warning: $PROG: gagal salin startup-config ke $CFG_DIR" >&2; return 1
    }
    # netstate ikut dipersistenkan (alamat/intent/managed) agar commit
    # sesudah reboot konsisten dengan startup-config.
    if [ -d "$STATE_DIR/netstate" ]; then
        mkdir -p "$CFG_DIR/netstate" 2>/dev/null
        cp -f "$STATE_DIR/netstate/"* "$CFG_DIR/netstate/" 2>/dev/null || true
    fi
    # Intent-intent di /etc (tmpfs) ikut dipersistenkan — semuanya hilang
    # saat reboot bila tidak disalin. Daftar: terminal-length (pager),
    # ipoe/bgp/bfd/static/rip/ospf/direct/pipe/kernel/device +
    # rpki/radv/babel/bird-global/aggregator/bmp/l3vpn/mrt (Batch 9 —
    # sebelumnya rpki/radv/babel/global hilang saat reboot meski ada
    # di /etc/titian).
    # CATATAN (handoff vtysh, 17 Nov 2026): frr.conf TIDAK ada di daftar
    # ini lagi. /etc/titian/frr.conf adalah file intent klish LAMA
    # (format `bgp ...`/`route-map ...`, bukan config FRR native) dan
    # tidak dipakai lagi. Yang dipersistenkan adalah frr.conf LIVE
    # (/usr/local/etc/frr/frr.conf) via titian-frr.sh frr-sync di bawah
    # (write memory dulu bila zebra jalan, lalu salin ke /cfg).
    for _f in terminal-length ipoe.conf bgp.conf bfd.conf static.conf rip.conf ospf.conf direct.conf pipe.conf kernel.conf device.conf rpki.conf radv.conf babel.conf bird-global.conf aggregator.conf bmp.conf l3vpn.conf mrt.conf; do
        [ -f "$STATE_DIR/$_f" ] && cp -f "$STATE_DIR/$_f" "$CFG_DIR/$_f" 2>/dev/null || true
    done
    # Jembatan persistensi FRR (best-effort, tidak pernah menggagalkan save).
    if [ -x "$SBIN_DIR/titian-frr.sh" ]; then
        sh "$SBIN_DIR/titian-frr.sh" frr-sync 2>/dev/null || true
    fi
    return 0
}

cmd_save() {
    mount_cfg || return 0
    mkdir -p "$CFG_DIR" 2>/dev/null || {
        echo "Warning: $PROG: gagal mkdir $CFG_DIR" >&2; return 0
    }
    # JANGAN salin sinkron di sini (lihat header: dump mendarat
    # sesudah ACTION selesai). Lepas proses latar yang menunggu dump
    # baru menyalin. setsid = lepas dari grup proses konfd agar
    # selamat saat ACTION selesai; fallback: background biasa.
    _sig=$(file_sig "$STATE_DIR/startup-config")
    _self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$_self" save-wait "$_sig" >/dev/null 2>&1 </dev/null &
    else
        ( sh "$_self" save-wait "$_sig" >/dev/null 2>&1 </dev/null & )
    fi
    echo "titian config persist dijadwalkan (menunggu dump startup-config selesai, lalu salin ke $CFG_DIR)"
    return 0
}

cmd_save_now() {
    # Salin sinkron SEGERA — hanya untuk pemakaian manual sesudah dump
    # sudah mendarat (bukan dari ACTION `save`).
    mount_cfg || return 0
    mkdir -p "$CFG_DIR" 2>/dev/null || {
        echo "Warning: $PROG: gagal mkdir $CFG_DIR" >&2; return 0
    }
    if copy_all; then
        echo "titian config dipersistenkan ke $CFG_DIR (survive reboot)"
    fi
    return 0
}

cmd_save_wait() {
    # $1 = sidik isi startup-config saat `save` dipanggil. Tunggu dump
    # klish mendarat (sidik berubah, atau file muncul bila belum ada),
    # lalu salin ke /cfg. Timeout 10 detik; bila tidak ada perubahan,
    # salin apa adanya (best-effort — isi sama, tidak merusak) + catat.
    _before="${1:-}"
    mount_cfg || return 0
    mkdir -p "$CFG_DIR" 2>/dev/null || return 0
    _i=0
    while [ "$_i" -lt 50 ]; do
        _now=$(file_sig "$STATE_DIR/startup-config")
        if [ -n "$_now" ] && [ "$_now" != "$_before" ]; then
            break
        fi
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    if [ "$_i" -ge 50 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $PROG: dump startup-config tidak teramati dalam 10 detik, salin apa adanya" >> /var/log/titian-cfg.log 2>/dev/null || true
    fi
    if copy_all; then
        echo "titian config dipersistenkan ke $CFG_DIR (survive reboot)"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') $PROG: persist gagal" >> /var/log/titian-cfg.log 2>/dev/null || true
    fi
    # Segarkan snapshot .last-save agar rollback memakai isi save ini,
    # bukan versi sebelumnya (snapshot di ACTION punya race yang sama:
    # dump belum mendarat saat snapshot diambil).
    if [ -x "$ROOT/sbin/titian-checkpoint.sh" ]; then
        "$ROOT/sbin/titian-checkpoint.sh" snapshot-last-save 2>/dev/null || true
    elif [ -x "$SBIN_DIR/titian-checkpoint.sh" ]; then
        "$SBIN_DIR/titian-checkpoint.sh" snapshot-last-save 2>/dev/null || true
    fi
    return 0
}

cmd_restore() {
    mount_cfg || return 0
    if [ ! -f "$CFG_DIR/startup-config" ]; then
        return 0
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null
    cp -f "$CFG_DIR/startup-config" "$STATE_DIR/startup-config" 2>/dev/null || {
        echo "Warning: $PROG: failed restore startup-config from $CFG_DIR" >&2; return 0
    }
    if [ -d "$CFG_DIR/netstate" ]; then
        mkdir -p "$STATE_DIR/netstate" 2>/dev/null
        cp -f "$CFG_DIR/netstate/"* "$STATE_DIR/netstate/" 2>/dev/null || true
    fi
    for _f in terminal-length ipoe.conf bgp.conf bfd.conf static.conf rip.conf ospf.conf direct.conf pipe.conf kernel.conf device.conf rpki.conf radv.conf babel.conf bird-global.conf aggregator.conf bmp.conf l3vpn.conf mrt.conf; do
        [ -f "$CFG_DIR/$_f" ] && cp -f "$CFG_DIR/$_f" "$STATE_DIR/$_f" 2>/dev/null || true
    done
    # Jembatan persistensi FRR (handoff vtysh, 17 Nov 2026): pasang
    # snapshot frr.conf /cfg -> lokasi live SEBELUM FRR naik. Best-effort;
    # snapshot format intent klish lama DITOLAK di sana (bukan config
    # FRR native). /etc/titian/frr.conf (intent lama) sengaja TIDAK
    # di-restore lagi.
    if [ -x "$SBIN_DIR/titian-frr.sh" ]; then
        sh "$SBIN_DIR/titian-frr.sh" frr-restore 2>/dev/null || true
    fi
    echo "titian config at-restore from $CFG_DIR"
    return 0
}

case "$1" in
    save)      cmd_save ;;
    save-now)  cmd_save_now ;;
    save-wait) cmd_save_wait "${2:-}" ;;
    restore)   cmd_restore ;;
    *) echo "usage: $PROG <save|save-now|save-wait <sig>|restore>" >&2; exit 2 ;;
esac
exit 0
