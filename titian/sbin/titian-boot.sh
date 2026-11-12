#!/bin/sh
# TITIAN Fase 1 — boot service: jalankan konfd (bila belum jalan)
# lalu replay startup-config gaya titian init-titian.
# Dipanggil systemd unit (Debian) / rc script (FreeBSD).
# POSIX sh.
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
BIN=$ROOT/bin

# Restore config persisten dari partisi cfg (/cfg/titian) ke /etc/titian
# (tmpfs) SEBELUM replay — tanpa ini replay tidak menemukan config
# sesudah reboot. Best-effort: bila /cfg kosong, lanjut (boot bersih).
if [ -x "$ROOT/sbin/titian-cfg.sh" ]; then
    "$ROOT/sbin/titian-cfg.sh" restore 2>/dev/null || true
fi
if [ ! -x "$BIN/konfd" ] && [ -x /usr/local/bin/konfd ]; then
    BIN=/usr/local/bin
fi
export LD_LIBRARY_PATH=$ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:$BIN
PIDFILE=/var/run/titian-konfd.pid
SOCKFILE=/tmp/konfd.socket
LOG=/var/log/titian-konfd.log

# bersihkan pid/socket basi (boot tidak bersih sebelumnya)
if [ -f "$PIDFILE" ]; then
    oldpid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        echo "konfd already jalan (pid $oldpid)"
    else
        rm -f "$PIDFILE" "$SOCKFILE"
    fi
fi
if [ ! -f "$PIDFILE" ]; then
    [ -S "$SOCKFILE" ] && rm -f "$SOCKFILE"
    # konfd klish 2.x: daemon socket default /tmp/konfd.socket
    "$BIN/konfd" >>"$LOG" 2>&1 &
    # tunggu socket maksimal ~10 detik
    i=0
    while [ ! -S "$SOCKFILE" ] && [ "$i" -lt 20 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    # konfd menulis pidfile-nya sendiri (/var/run/konfd.pid klish);
    # salin ke pidfile titian bila ada
    if [ -f /var/run/konfd.pid ]; then
        cp -f /var/run/konfd.pid "$PIDFILE" 2>/dev/null || true
    fi
    if [ ! -S "$SOCKFILE" ]; then
        echo "Warning: socket konfd not muncul; show $LOG" >&2
    fi
fi

# FreeBSD: pastikan modul vxlan termuat SEBELUM replay, agar replay
# baris `interface vxlan` tidak gagal karena if_vxlan belum ada.
# (loader.conf if_vxlan_load="YES" ditulis saat create; kldload di sini
# menutup celah bila loader.conf belum sempat ditulis / modul tidak
# ter-load.) Best-effort: replay tetap jalan bila modul gagal.
if [ "$(uname -s)" = "FreeBSD" ]; then
    kldload if_vxlan 2>/dev/null || true
fi

# replay startup-config (bila ada) — idempotent (replace semantics)
# Perbaikan replay (12 Nov 2026, reboot ke-2/ke-4):
#  `!` pemisah seksi keluar dari sub-mode KECUALI bridge — sub-mode
#  bridge TIDAK keluar pada `!`, sehingga `interface` sesudah bridge
#  gagal "Unknown command" (vlan99 hilang, bridge0 hanya 1 member).
#  Preprocess: sisipkan `exit` HANYA sebelum `interface` yang
#  mengikuti seksi bridge (lacak last_iface). JANGAN sisipkan `exit`
#  sebelum semua interface/router — itu merusak replay ke-3/ke-4
#  (exit ganda keluar dari configure-view, semua baris "Unknown
#  command", running-config kosong). Replay DUA pass: pass 1 membuat
#  semua interface, pass 2 menempelkan member/atribut yang gagal di
#  pass 1 (dependensi sudah ada).
if [ -f "$STATE_ROOT/startup-config" ]; then
    _replay_tmp="/tmp/titian-replay-prep.conf"
    awk '
        /^interface / {
            if (last_iface == "bridge") print "exit"
            if (/^interface bridge/) { last_iface = "bridge" } else { last_iface = "other" }
        }
        { print }
    ' "$STATE_ROOT/startup-config" > "$_replay_tmp" 2>/dev/null
    _replay_src="$STATE_ROOT/startup-config"
    [ -s "$_replay_tmp" ] && _replay_src="$_replay_tmp"
    "$BIN/clish" -x "$ROOT/etc/clish-en" -w configure-view "$_replay_src" 2>&1 | tee /var/log/titian-replay.log
    "$BIN/clish" -x "$ROOT/etc/clish-en" -w configure-view "$_replay_src" 2>&1 | tee -a /var/log/titian-replay.log
    rm -f "$_replay_tmp" 2>/dev/null || true
fi

# jaring pengaman tuning: terapkan ulang nilai .tuning yang tercatat
# (best-effort, idempotent, tidak pernah menggagalkan boot). Ini
# menutup celah bila replay baris view `options` (nested) gagal, dan
# menerapkan tuning yang tercatat di cermin meski belum sempat `save`.
if [ -x "$ROOT/sbin/titian-tune.sh" ]; then
    "$ROOT/sbin/titian-tune.sh" apply-all 2>/dev/null || true
fi

# jaring pengaman bond: pasang ulang slave bond yang tercatat.
# Replay menempelkan slave, tapi sync tuning sesudahnya memicu
# reconfigure networkd yang melepas slave (bond titian bukan NetDev
# networkd, jadi networkd tidak mempertahankan master-nya). Langkah
# ini jalan PALING AKHIR, sesudah semua reload, sehingga tidak ada
# lagi reconfigure yang bisa melepasnya.
if [ -x "$ROOT/sbin/titian-persist.sh" ]; then
    "$ROOT/sbin/titian-persist.sh" apply-bond 2>/dev/null || true
fi

# jaring pengaman vxlan: bangun ulang vxlan yang tercatat di netstate
# tapi interfacenya hilang (replay gagal untuk seksi itu). No-op bila
# replay berhasil. Jalan sesudah apply-bond; vxlan bukan slave bond,
# jadi urutan terhadap reload networkd aman.
if [ -x "$ROOT/sbin/titian-vxlan.sh" ]; then
    "$ROOT/sbin/titian-vxlan.sh" apply-all 2>/dev/null || true
fi

# jaring pengaman firewall: rebuild backend penuh dari netstate
# (flush + generate). Ini JUGA yang membuat rollback checkpoint benar
# untuk firewall: restore netstate titik + restart -> apply ini
# membuang rule live yang tidak ada di titik. No-op (tabel/anchor
# dibersihkan) bila netstate kosong. Jalan PALING AKHIR.
if [ -x "$ROOT/sbin/titian-fw.sh" ]; then
    "$ROOT/sbin/titian-fw.sh" apply-all 2>/dev/null || true
fi

# BSDRP port: terapkan semua niat pending (routing/firewall/
# traffic-shape/pppoe/wireguard/monitoring) sesudah replay — replay
# klish menandai dirty lagi, jadi commit apply-all di sini yang
# menaikkan service sesuai niat startup-config. No-op bila tidak ada
# niat pending. Mutual exclusion bird/FRR tetap diperiksa.
if [ -x "$ROOT/sbin/titian-commit.sh" ]; then
    "$ROOT/sbin/titian-commit.sh" apply-all 2>/dev/null || true
fi
exit 0
