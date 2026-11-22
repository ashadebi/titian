#!/bin/sh
# titian-factory-reset.sh — hapus SEMUA konfigurasi Titian, kembali ke
# default pabrik (kosong). Perintah `factory-reset` (enable view).
#
# MASALAH: tidak ada cara resmi memulai dari awal — konfigurasi hidup di
# /etc/titian (tmpfs, live) + /cfg/titian (persisten) + bird.conf
# (live /usr/local/etc + /etc/local + persisten /cfg/local) + frr.conf
# (live /usr/local/etc/frr + snapshot /cfg/titian) + blok Titian di
# rc.conf. Hapus manual rawan terlewat (mis. intent tertinggal lalu
# replay menghidupkan lagi) atau kelebihan (binary/XML ikut terhapus).
#
# SEMANTIK (dua langkah, mengikuti pola birdc `down`/`graceful-restart`
# yang ireversibel):
#   factory-reset          — ARM: hanya menampilkan ringkasan apa yang
#                            akan dihapus + perangkat tempat /cfg
#                            ter-mount + perintah konfirmasi. TIDAK
#                            menghapus apa pun. Aman diulang.
#   factory-reset confirm  — EKSEKUSI: backup otomatis dulu (tarball
#                            di /cfg — GAGAL backup = BATAL, rc 33),
#                            baru hapus, pulihkan default dari
#                            *.sample bila ada, buang blok Titian dari
#                            rc.conf, lalu (bila bukan mode hermetik)
#                            hentikan FRR + birdc configure + restart
#                            service titian (best-effort).
#   restore <backup.tgz>   — PULIHKAN konfigurasi dari tarball backup
#                            (dibuat confirm, atau backup pra-uji manual).
#                            Otomatis penuh: entri `usr/local/etc/*`
#                            TIDAK diekstrak langsung ke / (bsdtar
#                            MENOLAK lewat symlink /usr/local/etc ->
#                            /etc/local — Temuan 1, 19 Nov 2026), tapi
#                            diekstrak ke direktori sementara lalu
#                            disalin file-per-file dengan cp (cp
#                            mengikuti symlink tujuan); frr.conf live
#                            dipulihkan dengan mode 600 + owner frr:frr.
#                            Dipakai shell langsung (bukan perintah klish):
#                            sh /opt/titian/sbin/titian-factory-reset.sh
#                            restore /cfg/titian-factory-reset-bak-<WIB>.tgz
#                            lalu `service titian restart`.
#
# YANG DIHAPUS (bila ada): startup-config, intent *.conf, netstate/,
# bird.d/, bird-backup/, checkpoints/ (termasuk .last-save),
# sysctl.titian(.prev), frr.conf (intent lama + snapshot), bird.conf
# (live + /etc/local + /cfg/local — dipulihkan dari *.sample bila ada,
# bila tidak ada sample: dihapus), frr.conf live (idem), blok
# #-TITIAN-# / #-TITIAN-L2-# / #-TITIAN-RENAME-# di /etc/rc.conf +
# /cfg/rc.conf (isi lain rc.conf TIDAK disentuh).
#
# YANG TIDAK PERNAH DIHAPUS: binary + XML Titian (/opt/titian),
# struktur direktori /cfg + /etc, firewall.conf (/etc/local +
# /cfg/local — milik BSDRP, bukan konfigurasi hasil generate Titian),
# rc.local (+hook newsyslog), sshd_config, password root, disk/partisi
# lain. Perintah `write-memory` klish tetap dihapus (keputusan user
# 18 Nov 2026) — fitur ini TIDAK menghidupkannya lagi.
#
# PERINGATAN /cfg TABRAKAN LABEL (19 Nov 2026): bila /cfg ter-mount
# dari disk BERBEDA dengan root (dua disk punya partisi berlabel
# `cfg`), reset menghapus konfigurasi disk LAIN itu — arm menampilkan
# peringatan keras bila perangkat /cfg dan root beda disk.
#
# Hermetik (uji): TITIAN_STATE_ROOT / TITIAN_CFG_DIR / TITIAN_CFG_MNT /
# TITIAN_RC_CONF / TITIAN_CFG_RC_CONF / TITIAN_BIRD_LIVE_CONF /
# TITIAN_BIRD_ETC_CONF / TITIAN_BIRD_PERSIST / TITIAN_FRR_CONF /
# TITIAN_ROOT / TITIAN_OS. Bila TITIAN_STATE_ROOT di-set ke lokasi
# BUKAN default, langkah live (stop FRR, birdc configure, restart
# service) DILEWATI — pola yang sama seperti titian-bird.sh (B22).
# Produksi TIDAK PERNAH men-set variabel ini.
#
# POSIX sh. Dibuat 2026-11-19 (perintah user: reset konfigurasi
# Titian "mulai dari awal").

PROG="titian-factory-reset"
ROOT=${TITIAN_ROOT:-/opt/titian}
RESTORE_ROOT=${TITIAN_RESTORE_ROOT:-/}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
CFG_DIR=${TITIAN_CFG_DIR:-/cfg/titian}
CFG_MNT=${TITIAN_CFG_MNT:-$(dirname "$CFG_DIR")}
OS=${TITIAN_OS:-$(uname -s)}
RC_CONF=${TITIAN_RC_CONF:-/etc/rc.conf}
CFG_RC_CONF=${TITIAN_CFG_RC_CONF:-$(dirname "$CFG_DIR")/rc.conf}
BIRD_LIVE=${TITIAN_BIRD_LIVE_CONF:-/usr/local/etc/bird.conf}
BIRD_ETC=${TITIAN_BIRD_ETC_CONF:-/etc/local/bird.conf}
BIRD_PERSIST=${TITIAN_BIRD_PERSIST:-/cfg/local/bird.conf}
FRR_CONF=${TITIAN_FRR_CONF:-/usr/local/etc/frr/frr.conf}
SBIN_DIR=$(dirname "$0")
# Pager (mode `less`, seperti `show`): dipakai _with_pager untuk arm.
# TITIAN_PAGER = override hermetik (uji); bila tidak di-set, pakai helper
# titian-pager.sh di sbin yang sama, fallback ke $TITIAN_ROOT/sbin/.
PAGER=${TITIAN_PAGER:-$SBIN_DIR/titian-pager.sh}
[ -x "$PAGER" ] || PAGER="${TITIAN_ROOT:-/opt/titian}/sbin/titian-pager.sh"

# Intent yang dipersistenkan titian-cfg.sh copy_all()/cmd_restore()
# (daftar yang sama — bila daftar di sana berubah, samakan di sini).
INTENT_FILES="terminal-length ipoe.conf bgp.conf bfd.conf static.conf rip.conf ospf.conf direct.conf pipe.conf kernel.conf device.conf rpki.conf radv.conf babel.conf bird-global.conf aggregator.conf bmp.conf l3vpn.conf mrt.conf"

err() { echo "Error: $PROG: $*" >&2; exit 33; }

is_hermetic() {
    [ -n "${TITIAN_STATE_ROOT:-}" ] && [ "$TITIAN_STATE_ROOT" != "/etc/titian" ]
}

disk_of() {
    # $1 = perangkat partisi (nda0p5, da0p3, sda1, nvme0n1p2) -> nama disk.
    # Masukan selalu nama partisi (dari glabel/df); disk telanjang tidak
    # diharapkan.
    _d="$1"; _d=${_d##*/}
    case "$_d" in
        *p[0-9]) _d=${_d%p[0-9]*} ;;
        *[a-z][0-9]) _d=${_d%[0-9]*} ;;
    esac
    echo "$_d"
}

dev_disk() {
    # $1 = perangkat (nda0p5, /dev/ada0p3, /dev/gpt/cfg) -> nama disk,
    # atau "" bila berupa label GPT (fisik tidak dapat ditentukan).
    case "$1" in
        /dev/gpt/*) echo "" ;;
        *) disk_of "$1" ;;
    esac
}

cfg_device() {
    # -> perangkat tempat /cfg ter-mount: "nda0p5" (via glabel) atau
    # "/dev/gpt/cfg" (via mount) atau "" (tidak ter-mount / tidak tahu).
    if command -v glabel >/dev/null 2>&1; then
        _d=$(glabel status 2>/dev/null | awk '$1=="gpt/cfg" {print $3; exit}')
        [ -n "$_d" ] && { echo "$_d"; return 0; }
    fi
    _m=$(mount 2>/dev/null | awk -v mnt="$CFG_MNT" '$3==mnt {print $1; exit}')
    [ -n "$_m" ] && { echo "$_m"; return 0; }
    echo ""
}

root_device() {
    # -> perangkat root: "da0p3" (via glabel) atau "/dev/gpt/BSDRP1"
    # (via df) atau "".
    _r=$(df -P / 2>/dev/null | tail -1 | awk '{print $1}')
    [ -n "$_r" ] || { echo ""; return 0; }
    case "$_r" in
        /dev/gpt/*)
            if command -v glabel >/dev/null 2>&1; then
                _lbl=${_r#/dev/}
                _d=$(glabel status 2>/dev/null | awk -v l="$_lbl" '$1==l {print $3; exit}')
                [ -n "$_d" ] && { echo "$_d"; return 0; }
            fi
            echo "$_r"; return 0 ;;
        *) echo "$_r" ;;
    esac
}

dir_nonempty() {
    # $1 = direktori -> true bila ada DAN berisi sesuatu. Direktori
    # kosong sudah bersih — JANGAN didaftar di wipe_list (kalau tidak,
    # confirm tidak pernah "sudah bersih": direktori yang dibuat ulang
    # kosong di akhir confirm akan dihapus lagi di confirm berikut).
    [ -d "$1" ] && [ -n "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]
}

# --- daftar hapus / pulih (satu path per baris, hanya yang ADA) ---
wipe_list() {
    # File + direktori Titian yang akan DIHAPUS (bila ada; direktori
    # hanya bila berisi sesuatu).
    for _f in startup-config frr.conf sysctl.titian sysctl.titian.prev; do
        [ -e "$STATE_ROOT/$_f" ] && echo "$STATE_ROOT/$_f"
        [ -e "$CFG_DIR/$_f" ] && echo "$CFG_DIR/$_f"
    done
    for _f in $INTENT_FILES; do
        [ -e "$STATE_ROOT/$_f" ] && echo "$STATE_ROOT/$_f"
        [ -e "$CFG_DIR/$_f" ] && echo "$CFG_DIR/$_f"
    done
    for _d in netstate bird.d bird-backup; do
        dir_nonempty "$STATE_ROOT/$_d" && echo "$STATE_ROOT/$_d"
        dir_nonempty "$CFG_DIR/$_d" && echo "$CFG_DIR/$_d"
    done
    # checkpoints: hapus semua titik KECUALI checkpoint pra-reset (yang
    # baru dibuat confirm ini — itu jalan kembali via `rollback <nama>`).
    # Tanpa checkpoint pra-reset, hapus seluruh dir (perilaku lama).
    # RESET_CKPT_NAME di-set make_reset_checkpoint (langkah 1b); saat
    # arm / backup tarball (sebelum 1b) variabel ini kosong sehingga
    # dir checkpoints terdaftar utuh (backup lengkap + preview benar).
    for _base in "$STATE_ROOT/checkpoints" "$CFG_DIR/checkpoints"; do
        [ -d "$_base" ] || continue
        if [ -n "${RESET_CKPT_NAME:-}" ] && [ -d "$_base/$RESET_CKPT_NAME" ]; then
            for _c in "$_base/"*/; do
                [ -d "$_c" ] || continue
                [ "$(basename "$_c")" = "$RESET_CKPT_NAME" ] && continue
                echo "$_c"
            done
        else
            dir_nonempty "$_base" && echo "$_base"
        fi
    done
    [ -e "$STATE_ROOT/bird.conf" ] && echo "$STATE_ROOT/bird.conf"
}

restore_list() {
    # File yang DIPULIHKAN ke default (punya *.sample dan isinya beda
    # dari sample) atau DIHAPUS (tidak punya sample): bird.conf x3 +
    # frr.conf live. File yang isinya SUDAH sama dengan sample tidak
    # didaftar (sudah default — confirm kedua jadi no-op "sudah bersih").
    for _f in "$BIRD_LIVE" "$BIRD_ETC" "$BIRD_PERSIST" "$FRR_CONF"; do
        [ -e "$_f" ] || continue
        if [ -f "$_f.sample" ] && cmp -s "$_f" "$_f.sample" 2>/dev/null; then
            continue
        fi
        echo "$_f"
    done
}

rc_block_lines() {
    # $1 = file rc.conf -> jumlah baris di dalam blok Titian (0 bila tak ada).
    _f="$1"; [ -f "$_f" ] || { echo 0; return 0; }
    awk '/^#-TITIAN-#/{s=1; next} /^#-ENDTITIAN-#/{s=0; next} /^#-TITIAN-L2-#/{s=1; next} /^#-ENDTITIAN-L2-#/{s=0; next} /^#-TITIAN-RENAME-#/{s=1; next} /^#-ENDTITIAN-RENAME-#/{s=0; next} s {n++} END {print n+0}' "$_f" 2>/dev/null
}

strip_rc_blocks() {
    # $1 = file rc.conf -> buang blok Titian (validasi sh -n dulu,
    # tulis atomik via tmp; salinan pra-reset di $1.titian-bak).
    # Return 0 bila tidak ada blok / berhasil; 1 bila gagal.
    _rc="$1"
    [ -f "$_rc" ] || return 0
    _n=$(rc_block_lines "$_rc")
    [ "$_n" = "0" ] && return 0
    _tmp=$(mktemp /tmp/titian-reset-rc.XXXXXX) || return 1
    awk '/^#-TITIAN-#/{skip=1; next} /^#-ENDTITIAN-#/{skip=0; next} /^#-TITIAN-L2-#/{skip=1; next} /^#-ENDTITIAN-L2-#/{skip=0; next} /^#-TITIAN-RENAME-#/{skip=1; next} /^#-ENDTITIAN-RENAME-#/{skip=0; next} !skip {print}' "$_rc" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    if cmp -s "$_tmp" "$_rc" 2>/dev/null; then rm -f "$_tmp"; return 0; fi
    if ! sh -n "$_tmp" 2>/dev/null; then
        echo "Warning: $PROG: hasil strip blok Titian gagal sh -n, $_rc TIDAK diubah" >&2
        rm -f "$_tmp"; return 1
    fi
    cp -f "$_rc" "$_rc.titian-bak" 2>/dev/null || true
    cat "$_tmp" > "$_rc" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    rm -f "$_tmp"
    echo "$_n"
    return 0
}

service_restart() {
    # Pola yang sama seperti titian-checkpoint.sh service_restart():
    # FreeBSD `service titian restart`, Linux `systemctl restart titian`.
    if command -v service >/dev/null 2>&1; then
        service titian restart 2>&1 || return 1
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl restart titian 2>&1 || return 1
    else
        return 1
    fi
    return 0
}

# Jalankan subcommand dengan stdout ditangkap ke file sementara lalu
# ditampilkan lewat pager (mode `less`, seperti `show` — permintaan
# user 19 Nov 2026). stderr TIDAK ditangkap (error fatal tetap langsung
# terlihat di terminal). Bila pager tidak ada/tidak bisa dieksekusi,
# tampilkan langsung (cat) — jangan gagal hanya karena pager hilang.
# Bila subcommand memanggil err (exit), skrip keluar seketika dengan
# kode itu; file sementara dibersihkan trap EXIT. Dipakai HANYA untuk
# arm (ringkasan yang dibaca sebelum memutuskan confirm); confirm
# sengaja TIDAK dipager supaya progresnya (backup, hapus, restart)
# terlihat live, dan restore outputnya pendek.
_with_pager() {
    _fn="$1"; shift
    _tmp=$(mktemp /tmp/titian-reset-out.XXXXXX) || { echo "Error: $PROG: gagal mktemp" >&2; return 33; }
    trap 'rm -f "$_tmp" 2>/dev/null' EXIT
    "$_fn" "$@" > "$_tmp"
    _rc=$?
    if [ -x "$PAGER" ]; then
        sh "$PAGER" "$_tmp"
    else
        cat "$_tmp"
    fi
    rm -f "$_tmp" 2>/dev/null || true
    trap - EXIT
    return $_rc
}

cmd_arm() {
    _cfgdev=$(cfg_device)
    _rootdev=$(root_device)
    _nw=$(wipe_list | wc -l | tr -d ' ')
    _nr=$(restore_list | wc -l | tr -d ' ')
    _brc=$(rc_block_lines "$RC_CONF")
    _bcfg=$(rc_block_lines "$CFG_RC_CONF")
    echo "PERINGATAN: 'factory-reset' menghapus SEMUA konfigurasi Titian (ireversibel)."
    if [ -n "$_cfgdev" ]; then
        echo "/cfg ter-mount di: $_cfgdev"
    else
        echo "/cfg ter-mount di: (tidak ter-mount / tidak dapat ditentukan)"
    fi
    [ -n "$_rootdev" ] && echo "root ter-mount di: $_rootdev"
    # Peringatan tabrakan label hanya bila KEDUA perangkat terurai ke
    # disk fisik (bukan label GPT) — bila salah satu tak terurai, jangan
    # menebak (hindari alarm palsu); operator tetap melihat kedua
    # perangkat di atas.
    _cd=$(dev_disk "$_cfgdev"); _rd=$(dev_disk "$_rootdev")
    if [ -n "$_cd" ] && [ -n "$_rd" ] && [ "$_cd" != "$_rd" ]; then
        echo "PERINGATAN KERAS: /cfg berada di disk BERBEDA dari root ($_cd vs $_rd) — reset akan menghapus konfigurasi disk $_cd, BUKAN disk boot!"
    fi
    if [ "$_nw" = "0" ] && [ "$_nr" = "0" ] && [ "$_brc" = "0" ] && [ "$_bcfg" = "0" ]; then
        echo "Sistem sudah bersih: tidak ada konfigurasi Titian (startup-config, intent, bird.conf, frr.conf, blok rc.conf semua tidak ada)."
        echo "Untuk eksekusi, jalankan: factory-reset confirm"
        return 0
    fi
    echo "Yang akan dihapus ($_nw item):"
    wipe_list | sed 's/^/  /'
    echo "Yang dipulihkan ke default pabrik ($_nr file):"
    restore_list | while read -r _rf; do
        if [ -f "$_rf.sample" ]; then
            echo "  $_rf <- $_rf.sample"
        else
            echo "  $_rf (tidak ada sample — file dihapus)"
        fi
    done
    echo "Blok rc.conf Titian yang akan dibuang: $RC_CONF ($_brc baris), $CFG_RC_CONF ($_bcfg baris)"
    echo "Backup otomatis: $CFG_MNT/titian-factory-reset-bak-<WIB>.tgz (dibuat saat confirm; gagal backup = batal)"
    echo "Checkpoint pra-reset: dibuat saat confirm (nama = tanggal WIB) dan DIPERTAHANKAN — muat kembali: 'rollback <tanggal>' (titik checkpoint lain dihapus)"
    echo "TIDAK dihapus: binary/XML Titian, firewall.conf, rc.local (+hook newsyslog), sshd_config, password root, disk/partisi lain."
    echo "Untuk eksekusi, jalankan: factory-reset confirm"
    return 0
}

# Interface manajemen (yang TIDAK BOLEH disentuh teardown): dari default
# route kernel; bila tidak ada, fallback ge0 (interface mgmt lab).
mgmt_iface() {
    _gw_if=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
    if [ -n "$_gw_if" ]; then echo "$_gw_if"; return 0; fi
    echo "ge0"
}

# Hancurkan interface live buatan Titian (Temuan 3, 19 Nov 2026):
# factory-reset confirm sebelumnya hanya menghapus lapisan FILE —
# interface live (vlan/vxlan/bridge/lagg, cloned loopback, IP di
# interface fisik) TETAP HIDUP di kernel sampai reboot. Fungsi ini
# menutup celah itu. Yang DIPERTAHANKAN: interface mgmt (dari
# mgmt_iface) + lo0 + default route, supaya SSH tidak putus.
# Best-effort: gagal destroy satu interface = warning, lanjut (bukan
# batal). Route BIRD sudah dicabut sebelum fungsi ini dipanggil
# (birdc configure dengan bird.conf default), jadi interface bebas
# dihancurkan. TIDAK disentuh di sini (tindak lanjut terpisah):
# rule pf live (inert sesudah interface hilang), nilai sysctl live,
# daemon mpd5, dan route kernel yang ditambah manual di luar BIRD.
teardown_live() {
    _mgmt=$(mgmt_iface)
    echo "factory-reset: teardown interface live (pertahankan mgmt: $_mgmt + lo0 + default route)..."
    # 1) Hancurkan cloned interface — bridge dulu (member lepas),
    #    lalu vxlan, vlan, lagg.
    for _t in bridge vxlan vlan lagg; do
        for _i in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep "^$_t" 2>/dev/null); do
            ifconfig "$_i" destroy 2>/dev/null || echo "Warning: $PROG: gagal destroy $_i" >&2
        done
    done
    # 2) Hancurkan cloned loopback lo1.. (bukan lo0).
    for _i in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^lo[1-9]' 2>/dev/null); do
        ifconfig "$_i" destroy 2>/dev/null || echo "Warning: $PROG: gagal destroy $_i" >&2
    done
    # 3) Cabut semua IP dari interface fisik (ge/xe) kecuali mgmt.
    for _i in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^(ge|xe)' 2>/dev/null); do
        [ "$_i" = "$_mgmt" ] && continue
        for _a in $(ifconfig "$_i" 2>/dev/null | awk '/inet /{print $2}'); do
            ifconfig "$_i" inet "$_a" -alias 2>/dev/null || true
        done
        for _a in $(ifconfig "$_i" 2>/dev/null | awk '/inet6 /{print $2}'); do
            ifconfig "$_i" inet6 "$_a" -alias 2>/dev/null || true
        done
    done
    echo "factory-reset: teardown interface live selesai."
    return 0
}

# Buat checkpoint pra-reset (Temuan 4, 19 Nov 2026): agar config sebelum
# reset bisa dimuat kembali lewat `rollback <nama>` (terlihat di
# `checkpoint list`). Nama = tanggal WIB (YYYY-MM-DD); bila sudah ada,
# tambah jam (-HHMM), lalu detik (-HHMMSS). Best-effort: gagal membuat
# checkpoint = peringatan lantang, confirm tetap jalan (backup tarball
# adalah jaring pengaman utama dan sudah dibuat di langkah 1).
make_reset_checkpoint() {
    _ckpt_sh=${TITIAN_CHECKPOINT_SH:-$SBIN_DIR/titian-checkpoint.sh}
    _ckptdir="$STATE_ROOT/checkpoints"
    _d=$(TZ=Asia/Jakarta date '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
    _name="$_d"
    _n=0
    while [ -d "$_ckptdir/$_name" ] && [ "$_n" -lt 3 ]; do
        _n=$((_n + 1))
        if [ "$_n" = "1" ]; then _name="$_d-$(TZ=Asia/Jakarta date '+%H%M' 2>/dev/null || date '+%H%M')"
        else _name="$_d-$(TZ=Asia/Jakarta date '+%H%M%S' 2>/dev/null || date '+%H%M%S')"; fi
    done
    if [ -x "$_ckpt_sh" ]; then
        if sh "$_ckpt_sh" save "$_name" > /tmp/titian-reset-ckpt.out 2>&1; then
            RESET_CKPT_NAME="$_name"
            echo "factory-reset: checkpoint pra-reset dibuat: $_name (muat kembali: 'rollback $_name')"
            if grep -q "fallback ke startup-config" /tmp/titian-reset-ckpt.out 2>/dev/null; then
                echo "  (catatan: fallback ke startup-config — checkpoint dibuat dari config terakhir yang di-save; perubahan yang di-commit tapi BELUM di-save tidak ikut)" >&2
            fi
        else
            RESET_CKPT_NAME=""
            echo "Warning: $PROG: gagal membuat checkpoint pra-reset '$_name' (backup tarball tetap ada — reset tetap jalan)" >&2
            sed 's/^/  /' /tmp/titian-reset-ckpt.out 2>/dev/null >&2 || true
        fi
        rm -f /tmp/titian-reset-ckpt.out 2>/dev/null || true
    else
        RESET_CKPT_NAME=""
        echo "Warning: $PROG: titian-checkpoint.sh tidak ditemukan — checkpoint pra-reset dilewati (backup tarball tetap ada)" >&2
    fi
    return 0
}

cmd_confirm() {
    _nw=$(wipe_list | wc -l | tr -d ' ')
    _rlist=$(restore_list)
    _nr=$(printf '%s' "$_rlist" | grep -c '^')
    _brc=$(rc_block_lines "$RC_CONF")
    _bcfg=$(rc_block_lines "$CFG_RC_CONF")
    if [ "$_nw" = "0" ] && [ "$_nr" = "0" ] && [ "$_brc" = "0" ] && [ "$_bcfg" = "0" ]; then
        echo "factory-reset: sudah bersih, tidak ada yang dihapus."
        return 0
    fi
    # 1) Backup otomatis DULU — gagal = batal (tidak ada yang dihapus).
    _stamp=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo "unknown")
    _backup="$CFG_MNT/titian-factory-reset-bak-$_stamp.tgz"
    mkdir -p "$CFG_MNT" 2>/dev/null || err "gagal mkdir $CFG_MNT (backup tidak bisa dibuat — batal)"
    _blist=$( { wipe_list; restore_list; [ -f "$RC_CONF" ] && echo "$RC_CONF"; [ -f "$CFG_RC_CONF" ] && echo "$CFG_RC_CONF"; } | sort -u )
    # tar memakai path absolut (bsdtar/GNU tar sama-sama membuang '/' depan).
    # shellcheck disable=SC2086
    if ! tar -czf "$_backup" $_blist 2>/dev/null; then
        err "gagal membuat backup $_backup — batal, tidak ada yang dihapus"
    fi
    [ -s "$_backup" ] || err "backup $_backup kosong/rusak — batal, tidak ada yang dihapus"
    echo "factory-reset: backup tersimpan di $_backup"
    # 1b) Checkpoint pra-reset (Temuan 4) — best-effort, gagal = warning, lanjut.
    make_reset_checkpoint
    # 2) Hapus daftar wipe.
    _del=0
    wipe_list | while read -r _p; do
        if [ -d "$_p" ]; then rm -rf "$_p" 2>/dev/null || echo "Warning: $PROG: gagal hapus direktori $_p" >&2
        else rm -f "$_p" 2>/dev/null || echo "Warning: $PROG: gagal hapus $_p" >&2; fi
    done
    _del=$_nw
    # Direktori state tetap berdiri (kosong) agar boot/skrip lain tidak gagal.
    mkdir -p "$STATE_ROOT/netstate" "$STATE_ROOT/bird.d" "$STATE_ROOT/checkpoints" "$CFG_DIR" "$CFG_DIR/netstate" 2>/dev/null || true
    # 3) Pulihkan default: dari *.sample bila ada, bila tidak ada: hapus file.
    # Hanya file yang didaftar restore_list (perlu tindakan) — file yang
    # sudah sama dengan sample tidak disentuh (supaya hitungan jujur dan
    # confirm kedua benar-benar no-op).
    _restored=0; _removed=0
    # shellcheck disable=SC2086
    for _rf in $_rlist; do
        [ -e "$_rf" ] || continue
        if [ -f "$_rf.sample" ]; then
            if cp -f "$_rf.sample" "$_rf" 2>/dev/null; then
                chmod 644 "$_rf" 2>/dev/null || true
                _restored=$((_restored + 1))
            else
                echo "Warning: $PROG: gagal pulihkan $_rf dari sample" >&2
            fi
        else
            rm -f "$_rf" 2>/dev/null && _removed=$((_removed + 1))
        fi
    done
    # 4) Buang blok Titian dari rc.conf (isi lain tidak disentuh).
    _s1=$(strip_rc_blocks "$RC_CONF" 2>/dev/null) || echo "Warning: $PROG: strip blok Titian gagal di $RC_CONF" >&2
    _s2=$(strip_rc_blocks "$CFG_RC_CONF" 2>/dev/null) || echo "Warning: $PROG: strip blok Titian gagal di $CFG_RC_CONF" >&2
    _s1=${_s1:-0}; _s2=${_s2:-0}
    echo "factory-reset: $_del item dihapus, $_restored file dipulihkan dari sample, $_removed file dihapus (tanpa sample), blok rc.conf dibuang (${_s1:-0}+${_s2:-0} baris)."
    # 5) Langkah live — DILEWATI di mode hermetik (uji).
    if is_hermetic; then
        echo "factory-reset: mode hermetik — stop FRR / birdc configure / restart service dilewati."
        echo "factory-reset: selesai (mode uji). Verifikasi live: 'show startup-config' (harus kosong) + bird.conf == sample."
        return 0
    fi
    # Hentikan FRR (best-effort): konfigurasi FRR sudah dihapus, daemon
    # tidak boleh jalan dengan config lama.
    if command -v service >/dev/null 2>&1; then
        service frr onestop 2>/dev/null || service frr stop 2>/dev/null || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl stop frr 2>/dev/null || true
    fi
    # Muat ulang bird.conf default (best-effort).
    if command -v birdc >/dev/null 2>&1 && [ -f "$BIRD_LIVE" ]; then
        birdc configure 2>&1 | head -3 || echo "Warning: $PROG: birdc configure gagal (BIRD mungkin belum jalan — cek 'show bird')" >&2
    fi
    # Hancurkan interface live buatan Titian (Temuan 3): sesudah birdc
    # configure (route BIRD sudah dicabut) dan sebelum restart service
    # (replay config kosong tidak membuat interface apa pun) — supaya
    # mesin benar-benar kembali ke default pabrik di lapisan runtime,
    # bukan cuma di file.
    teardown_live
    # Restart service titian: replay startup-config (kini kosong) -> running-config bersih.
    echo "factory-reset: restart service titian..."
    if service_restart; then
        echo "factory-reset: service titian kembali."
    else
        echo "Warning: $PROG: service titian TIDAK KEMBALI setelah restart — file sudah dihapus, periksa log service (atau reboot mesin)" >&2
    fi
    echo "factory-reset: selesai. Verifikasi: 'show startup-config' (harus kosong) + 'show bird' + bird.conf == sample."
    return 0
}

cmd_restore() {
    # $1 = tarball backup (wajib). Pulihkan SEMUA konfigurasi dari
    # backup — otomatis penuh, tanpa langkah manual.
    #
    # TEMUAN 1 (19 Nov 2026): `tar -xzf -C /` polos GAGAL memulihkan
    # entri `usr/local/etc/*` di BSDRP — bsdtar menolak mengekstrak
    # lewat symlink `/usr/local/etc -> /etc/local` ("Cannot extract
    # through symlink / Too many levels of symbolic links"); frr.conf
    # live hilang dan harus disalin manual. Jalur ini memperbaikinya:
    #   1) ekstrak semua entri KECUALI usr/local/etc/* langsung ke
    #      $RESTORE_ROOT (aman — tidak ada symlink di jalurnya);
    #   2) ekstrak SELURUH backup ke direktori sementara (di sana
    #      tidak ada symlink; hard-link antar-entri — mis. bird.conf
    #      live <-> /etc/local/bird.conf satu inode — ikut terurai
    #      dengan benar), lalu salin entri usr/local/etc/* file-per-file
    #      dengan cp — cp mengikuti symlink direktori tujuan, jadi
    #      frr.conf mendarat di /etc/local/frr/frr.conf (inode yang
    #      sama dengan /usr/local/etc/frr/frr.conf) dengan mode 600 +
    #      owner frr:frr, dan bird.conf dengan mode 644.
    # Verifikasi akhir: SETIAP entri file di backup harus ada di
    # tujuan sesudah restore (bila tidak, restore rc 33 + daftar yang
    # hilang — jangan diam). Kegagalan tar fase 1 saja (mis. peringatan
    # hard-link) TIDAK menggagalkan restore bila verifikasi lolos.
    _bak="${1:-}"
    [ -n "$_bak" ] || { echo "usage: $PROG restore <backup.tgz>" >&2; exit 2; }
    [ -f "$_bak" ] || err "backup tidak ada: $_bak"
    [ -s "$_bak" ] || err "backup kosong: $_bak"
    tar tzf "$_bak" >/dev/null 2>&1 || err "backup tidak bisa dibaca (bukan tarball gzip valid): $_bak"
    _tmp=$(mktemp -d /tmp/titian-reset-restore.XXXXXX) || err "gagal mktemp (restore batal)"
    _nfail=0
    # 1) Semua entri kecuali usr/local/etc/*.
    #    Pola '*usr/local/etc*' (bukan '^usr/local/etc') supaya cocok
    #    juga bila entri berawalan lain; pola tanpa '*' tetap disertakan
    #    untuk backup format live (entri tepat 'usr/local/etc/...').
    if ! tar -xzf "$_bak" -C "$RESTORE_ROOT" --exclude 'usr/local/etc' --exclude 'usr/local/etc/' --exclude 'usr/local/etc/*' --exclude '*usr/local/etc' --exclude '*usr/local/etc/*' 2>/dev/null; then
        echo "Warning: $PROG: tar fase 1 (ekstrak ke $RESTORE_ROOT) memberi peringatan — lanjut, verifikasi akhir yang menentukan" >&2
    fi
    # 2) Entri usr/local/etc/* via direktori sementara + cp.
    _ulist=$(tar tzf "$_bak" 2>/dev/null | grep 'usr/local/etc/' | grep -v '/$' || true)
    _nok=0
    if [ -n "$_ulist" ]; then
        if ! tar -xzf "$_bak" -C "$_tmp" 2>/dev/null; then
            rm -rf "$_tmp" 2>/dev/null || true
            err "gagal ekstrak backup $_bak ke direktori sementara (restore batal — tidak ada yang dipulihkan)"
        fi
        # shellcheck disable=SC2086 — daftar entri tar, satu path per baris.
        for _e in $_ulist; do
            if [ -f "$_tmp/$_e" ]; then
                _dest="$RESTORE_ROOT/$_e"
                mkdir -p "$(dirname "$_dest")" 2>/dev/null || true
                if cp -p "$_tmp/$_e" "$_dest" 2>/dev/null; then
                    case "$_e" in
                        */frr/frr.conf)
                            chmod 600 "$_dest" 2>/dev/null || true
                            if id frr >/dev/null 2>&1; then chown frr:frr "$_dest" 2>/dev/null || true; fi ;;
                        */bird.conf)
                            chmod 644 "$_dest" 2>/dev/null || true ;;
                    esac
                    _nok=$((_nok + 1))
                else
                    echo "Warning: $PROG: gagal salin $_e -> $_dest" >&2
                    _nfail=$((_nfail + 1))
                fi
            else
                echo "Warning: $PROG: $_e tidak ditemukan sesudah ekstrak sementara" >&2
                _nfail=$((_nfail + 1))
            fi
        done
    fi
    rm -rf "$_tmp" 2>/dev/null || true
    # 3) Verifikasi akhir: setiap entri file di backup harus ada di tujuan.
    # Uji `-f || -L`: symlink yang targetnya menggantung (mis.
    # etc/local/ssl/cert.pem.sample -> ../../share/certs/ca-root-nss.crt,
    # target tidak ada di image) tetap terhitung pulih bila symlink-nya
    # kembali — yang diuji adalah entrinya, bukan targetnya.
    _missing=$(tar tzf "$_bak" 2>/dev/null | grep -v '/$' | while read -r _me; do
        [ -f "$RESTORE_ROOT/$_me" ] || [ -L "$RESTORE_ROOT/$_me" ] || echo "$_me"
    done || true)
    if [ -n "$_missing" ]; then
        echo "factory-reset: restore GAGAL — entri berikut tidak pulih:" >&2
        printf '%s\n' "$_missing" | head -10 | sed 's/^/  /' >&2
        echo "factory-reset: ulangi restore dari $_bak (backup TIDAK diubah)" >&2
        return 33
    fi
    if tar tzf "$_bak" 2>/dev/null | grep -q 'etc/titian/startup-config$'; then
        if [ ! -f "$STATE_ROOT/startup-config" ]; then
            echo "factory-reset: restore GAGAL — startup-config ada di backup tapi tidak kembali ke $STATE_ROOT/startup-config" >&2
            return 33
        fi
    fi
    if [ "$_nfail" -gt 0 ]; then
        echo "factory-reset: restore GAGAL ($_nfail file usr/local/etc tidak pulih) — ulangi restore dari $_bak" >&2
        return 33
    fi
    echo "factory-reset: restore selesai dari $_bak ($_nok file usr/local/etc dipulihkan via jalur symlink, 0 gagal)."
    echo "factory-reset: jalankan 'service titian restart' untuk memuat konfigurasi yang dipulihkan, lalu verifikasi anchor (startup-config, bird.conf, BGP)."
    return 0
}

case "$1" in
    arm)     _with_pager cmd_arm ;;
    confirm) cmd_confirm ;;
    restore) cmd_restore "${2:-}" ;;
    teardown-live)
        # Subcommand HANYA untuk uji mock (FASE L): memanggil teardown_live
        # langsung. Ditolak di produksi (tanpa TITIAN_STATE_ROOT) supaya
        # tidak ada yang menjalankannya manual di mesin live — teardown
        # hanya boleh jalan lewat `confirm`.
        is_hermetic || { echo "Error: $PROG: teardown-live hanya untuk uji (set TITIAN_STATE_ROOT)" >&2; exit 2; }
        teardown_live ;;
    *) echo "usage: $PROG <arm|confirm|restore <backup.tgz>>" >&2; exit 2 ;;
esac
# Tanpa `exit 0` di sini: kode keluar skrip = kode subcommand (return 33
# dari verifikasi restore harus terlihat pemanggil, bukan tertutup 0).
