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
# Usage: titian-cfg.sh save | restore
#   save    — mount /cfg, salin /etc/titian/startup-config + netstate
#             ke /cfg/titian/ (persisten).
#   restore — mount /cfg, bila /cfg/titian/startup-config ada, salin
#             balik ke /etc/titian/ (dipanggil titian-boot.sh sebelum
#             replay, agar replay menemukan config).
#
# POSIX sh. Best-effort: gagal mount/salin = warning, bukan fatal
# (live session tetap jalan dari /etc/titian).
#
# BSDRP_klish, dibuat 2026-11-12 (fix persistensi cfg).

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

cmd_save() {
    mount_cfg || return 0
    mkdir -p "$CFG_DIR" 2>/dev/null || {
        echo "Warning: $PROG: failed mkdir $CFG_DIR" >&2; return 0
    }
    # Tunggu startup-config ditulis oleh CONFIG dump (save memanggil
    # script ini dari ACTION yang bisa jalan SEBELUM dump selesai).
    _i=0
    while [ ! -f "$STATE_DIR/startup-config" ] && [ "$_i" -lt 10 ]; do
        sleep 0.5
        _i=$((_i + 1))
    done
    if [ -f "$STATE_DIR/startup-config" ]; then
        cp -f "$STATE_DIR/startup-config" "$CFG_DIR/startup-config" 2>/dev/null || {
            echo "Warning: $PROG: failed salin startup-config to $CFG_DIR" >&2; return 0
        }
    else
        echo "Warning: $PROG: $STATE_DIR/startup-config no  (not yet save?)" >&2
        return 0
    fi
    # netstate ikut dipersistenkan (alamat/intent/managed) agar commit
    # sesudah reboot konsisten dengan startup-config.
    if [ -d "$STATE_DIR/netstate" ]; then
        mkdir -p "$CFG_DIR/netstate" 2>/dev/null
        cp -f "$STATE_DIR/netstate/"* "$CFG_DIR/netstate/" 2>/dev/null || true
    fi
    # terminal-length (pager) + ipoe.conf (IPoE server intent) ikut
    # dipersistenkan — keduanya di /etc (tmpfs) dan hilang saat reboot.
    for _f in terminal-length ipoe.conf; do
        [ -f "$STATE_DIR/$_f" ] && cp -f "$STATE_DIR/$_f" "$CFG_DIR/$_f" 2>/dev/null || true
    done
    echo "titian config dipersistenkan to $CFG_DIR (survive reboot)"
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
    for _f in terminal-length ipoe.conf; do
        [ -f "$CFG_DIR/$_f" ] && cp -f "$CFG_DIR/$_f" "$STATE_DIR/$_f" 2>/dev/null || true
    done
    echo "titian config at-restore from $CFG_DIR"
    return 0
}

case "$1" in
    save)    cmd_save ;;
    restore) cmd_restore ;;
    *) echo "usage: $PROG <save|restore>" >&2; exit 2 ;;
esac
exit 0
