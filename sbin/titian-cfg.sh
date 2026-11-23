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
# Jalur persisten/state overridable untuk uji (pola hermetik yang sama
# seperti TITIAN_STATE_ROOT di titian-bird.sh/titian-frr.sh).
# Produksi TIDAK PERNAH men-set variabel ini (unset = perilaku lama).
CFG_DIR=${TITIAN_CFG_DIR:-/cfg/titian}
CFG_MNT=${TITIAN_CFG_MNT:-$(dirname "$CFG_DIR")}
STATE_DIR=${TITIAN_STATE_ROOT:-/etc/titian}
OS=${TITIAN_OS:-$(uname -s)}
# rc.conf live + lokasi bird.conf live/persisten (FreeBSD) —
# overridable untuk uji. JANGAN override di mesin live.
RC_CONF=${TITIAN_RC_CONF:-/etc/rc.conf}
BIRD_LIVE=${TITIAN_BIRD_LIVE_CONF:-/usr/local/etc/bird.conf}
BIRD_PERSIST=${TITIAN_BIRD_PERSIST:-/cfg/local/bird.conf}

mount_cfg() {
    if mount 2>/dev/null | grep -q "[[:space:]]$CFG_MNT[[:space:]]"; then
        return 0
    fi
    mount "$CFG_MNT" 2>/dev/null && return 0
    echo "Warning: $PROG: failed mount $CFG_MNT (config Not persisten reboot)" >&2
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

# --- persistensi L2 ke rc.conf (Temuan 2a, 17 Nov 2026) ---
# MASALAH: `cloned_interfaces` TIDAK ADA di rc.conf (baik /etc
# maupun /cfg) dan /cfg/rc.conf basi (hanya ifconfig bridge0/ixl3/
# lagg0/xe3) — netif tidak membuat bridge/lo/vlan/lagg saat boot;
# keanggotaan bridge (member vlan/vxlan) TIDAK TERSIMPAN di mana
# pun. Replay startup-config adalah jalur utama pemulihan L2, tapi
# bila replay gagal/terpotong (Temuan 3), L2 hilang total.
# FUNGSI INI (sync-rc-l2): turunkan blok deklaratif `#-TITIAN-L2-#`
# dari startup-config (sumber kebenaran kanonis) dan tulis ke
# /etc/rc.conf (live) + /cfg/rc.conf (persisten — yang di-restore
# BSDRP saat boot). Blok ini milik titian-cfg.sh; baris di luar
# blok tidak pernah disentuh (pola yang sama dengan blok
# #-TITIAN-# milik titian-persist.sh dan #-TITIAN-RENAME-# milik
# titian-rename.sh).
# Isi blok:
#   cloned_interfaces="..." — semua interface clone titian dari
#     startup-config, urutan kemunculan pertama: bridge, loopback
#     (kecuali lo0 sistem), vlan, lagg. vxlan TIDAK masuk — sudah
#     dibangun ulang safety-net titian-vxlan.sh apply-all dari
#     netstate. ethernet TIDAK masuk — NIC fisik, milik
#     #-TITIAN-# (netstate).
#   ifconfig_<iface>="..." (+ _aliasN) — alamat dari startup-config
#     (urutan apa adanya; pertama = utama, sisanya alias), lalu:
#     bridge: `addm <member>` per member; vlan: `vlan <VID>
#     vlandev <parent>`; lagg: `laggproto lacp laggport <p>...`
#     (lacp SELALU — klish `interface lagg` mengeset laggproto lacp
#     tanpa syarat, tree/conf-if-lagg-fbsd.xml); semua diakhiri `up`.
# Dipanggil: tiap save (copy_all) + tiap restore (boot). Aman diulang
# (isi sama = file tidak berubah). FreeBSD saja; Linux = no-op.
# Best-effort: gagal = diam, bukan fatal (replay tetap jalur utama).
cmd_sync_rc_l2() {
    [ "$OS" = "FreeBSD" ] || return 0
    [ -f "$STATE_DIR/startup-config" ] || return 0
    _l2tmp=$(mktemp /tmp/titian-rc-l2.XXXXXX) || return 0
    _l2blk=$(mktemp /tmp/titian-rc-l2-blk.XXXXXX) || { rm -f "$_l2tmp"; return 0; }
    awk '
        function flush() {
            if (cur_type == "") return
            if (!(cur_name in seen)) {
                seen[cur_name] = 1
                cloned = cloned (cloned == "" ? "" : " ") cur_name
            }
            params = ""
            if (cur_type == "bridge") {
                for (i = 1; i <= nmem; i++) params = params " addm " mem[i]
            } else if (cur_type == "vlan") {
                params = " vlan " cur_vid " vlandev " cur_parent
            } else if (cur_type == "lagg") {
                params = " laggproto lacp"
                for (i = 1; i <= nport; i++) params = params " laggport " port[i]
            }
            if (naddr >= 1) {
                val = addr[1] params " up"
                sub(/^ /, "", val)
                out_lines[++nout] = "ifconfig_" cur_name "=\"" val "\""
                for (i = 2; i <= naddr; i++) {
                    out_lines[++nout] = "ifconfig_" cur_name "_alias" (i - 2) "=\"" addr[i] "\""
                }
            } else {
                val = params " up"
                sub(/^ /, "", val)
                out_lines[++nout] = "ifconfig_" cur_name "=\"" val "\""
            }
            cur_type = ""; cur_name = ""; cur_vid = ""; cur_parent = ""
            naddr = 0; nmem = 0; nport = 0
        }
        /^interface / {
            flush()
            if ($2 == "loopback") {
                if ($3 == "lo0") next
                cur_type = "loopback"; cur_name = $3
            } else if ($2 == "bridge") {
                cur_type = "bridge"; cur_name = $3
            } else if ($2 == "vlan") {
                cur_type = "vlan"; cur_name = "vlan" $3; cur_vid = $3; cur_parent = $4
            } else if ($2 == "lagg") {
                cur_type = "lagg"; cur_name = $3
            }
            next
        }
        !/^ / { flush(); next }
        {
            if (cur_type == "") next
            if ($1 == "ip" && $2 == "address") addr[++naddr] = "inet " $3
            else if ($1 == "ipv6" && $2 == "address") addr[++naddr] = "inet6 " $3
            else if ($1 == "member") mem[++nmem] = $2
            else if ($1 == "laggport") port[++nport] = $2
        }
        END {
            flush()
            printf "cloned_interfaces=\"%s\"\n", cloned
            for (i = 1; i <= nout; i++) print out_lines[i]
        }
    ' "$STATE_DIR/startup-config" > "$_l2blk" 2>/dev/null || { rm -f "$_l2tmp" "$_l2blk"; return 0; }
    {
        echo "#-TITIAN-L2-#"
        cat "$_l2blk"
        echo "#-ENDTITIAN-L2-#"
    } > "$_l2tmp" 2>/dev/null || { rm -f "$_l2tmp" "$_l2blk"; return 0; }
    rm -f "$_l2blk"
    for _l2rc in "$RC_CONF" "$(dirname "$CFG_DIR")/rc.conf"; do
        [ -f "$_l2rc" ] || continue
        _l2rtmp=$(mktemp /tmp/titian-rc-l2-rc.XXXXXX) || continue
        awk '/^#-TITIAN-L2-#/{skip=1; next} /^#-ENDTITIAN-L2-#/{skip=0; next} !skip {print}' "$_l2rc" > "$_l2rtmp" 2>/dev/null || { rm -f "$_l2rtmp"; continue; }
        cat "$_l2tmp" >> "$_l2rtmp" 2>/dev/null || { rm -f "$_l2rtmp"; continue; }
        if ! sh -n "$_l2rtmp" 2>/dev/null; then
            echo "Warning: $PROG: rc.conf hasil sync L2 gagal sh -n, tidak ditulis ($_l2rc)" >&2
            rm -f "$_l2rtmp"; continue
        fi
        if cmp -s "$_l2rtmp" "$_l2rc" 2>/dev/null; then rm -f "$_l2rtmp"; continue; fi
        cp -f "$_l2rc" "$_l2rc.titian-bak" 2>/dev/null || true
        cat "$_l2rtmp" > "$_l2rc" 2>/dev/null || { echo "Warning: $PROG: gagal tulis $_l2rc" >&2; rm -f "$_l2rtmp"; continue; }
        rm -f "$_l2rtmp"
    done
    rm -f "$_l2tmp"
    return 0
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
    # Cermin bird.conf live -> /cfg/local (Temuan 4): titian menulis
    # bird.conf hanya ke live; tanpa cermin, boot me-restore default
    # BSDRP dari /cfg/local. Best-effort (mirror sendiri yang
    # menjaga: FreeBSD saja + marker #-GLOBAL-#).
    if [ -x "$SBIN_DIR/titian-bird.sh" ]; then
        sh "$SBIN_DIR/titian-bird.sh" mirror-bird-conf 2>/dev/null || true
    fi
    # Sinkronisasi blok L2 rc.conf (Temuan 2a) — best-effort.
    cmd_sync_rc_l2 2>/dev/null || true
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
    # snapshot frr.conf /cfg -> lokasi live. PERHATIAN (Temuan 1):
    # FRR sudah naik LEBIH DULU (rcorder `frr` sebelum `titian`)
    # dengan config minimal — file yang dipasang baru dipakai
    # sesudah frr-boot-reconcile me-restart FRR. Best-effort;
    # snapshot format intent klish lama DITOLAK di sana (bukan config
    # FRR native). /etc/titian/frr.conf (intent lama) sengaja TIDAK
    # di-restore lagi.
    if [ -x "$SBIN_DIR/titian-frr.sh" ]; then
        sh "$SBIN_DIR/titian-frr.sh" frr-restore 2>/dev/null || true
    fi
    # Perbaikan bird.conf live dari salinan persisten (Temuan 4,
    # jaring pengaman): bila live bukan hasil generate titian
    # (tanpa marker #-GLOBAL-# — mis. default BSDRP pasca-reboot)
    # sementara /cfg/local/bird.conf berisi config titian, pulihkan
    # live dari salinan persisten. Best-effort; tidak pernah
    # menimpa live yang baik, tidak pernah menyalin default.
    if [ "$OS" = "FreeBSD" ] && [ -f "$BIRD_PERSIST" ] && [ -f "$BIRD_LIVE" ]; then
        if grep -qF '#-GLOBAL-#' "$BIRD_PERSIST" 2>/dev/null && ! grep -qF '#-GLOBAL-#' "$BIRD_LIVE" 2>/dev/null; then
            _btmp="$BIRD_LIVE.tmp.$$"
            if cp -f "$BIRD_PERSIST" "$_btmp" 2>/dev/null && mv "$_btmp" "$BIRD_LIVE" 2>/dev/null; then
                chmod 644 "$BIRD_LIVE" 2>/dev/null || true
                echo "titian config: bird.conf live dipulihkan dari $BIRD_PERSIST (default BSDRP pasca-reboot)"
            else
                rm -f "$_btmp" 2>/dev/null || true
            fi
        fi
    fi
    # Sinkronisasi blok L2 rc.conf (Temuan 2a): /cfg/rc.conf bisa
    # basi (tanpa blok L2 — boot pertama sesudah deploy fix ini);
    # turunkan ulang dari startup-config yang baru di-restore ke
    # /etc/rc.conf + /cfg/rc.conf. Best-effort.
    cmd_sync_rc_l2 2>/dev/null || true
    echo "titian config at-restore from $CFG_DIR"
    return 0
}

case "$1" in
    save)      cmd_save ;;
    save-now)  cmd_save_now ;;
    save-wait) cmd_save_wait "${2:-}" ;;
    restore)   cmd_restore ;;
    sync-rc-l2) cmd_sync_rc_l2 ;;
    *) echo "usage: $PROG <save|save-now|save-wait <sig>|restore|sync-rc-l2>" >&2; exit 2 ;;
esac
exit 0
