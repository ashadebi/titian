#!/bin/sh
# TITIAN BSDRP — FRR (net/frr10) via klish: VTYSH HANDOFF (17 Nov 2026).
#
# DESAIN BARU (keputusan user 17 Nov ~14:19): program coverage klish
# penuh untuk FRR DIBATALKAN. Tidak ada lagi perintah klish untuk
# BGP/OSPF/route-map/prefix-list/community-list/router-id/log — semua
# konfigurasi FRR dilakukan di CLI native FRR lewat handoff `vtysh`
# di view `router frr`. Yang tersisa di klish:
#   - enable/disable (`router frr enable`, pending commit) + `commit`
#     menaikkan/mematikan service (frr-apply, mutual exclusion vs BIRD),
#   - handoff interaktif `vtysh` (view configure-frr-view; CHILD, bukan
#     exec — `exit` di vtysh kembali ke klish; wajib TTY),
#   - show passthrough (`show frr*`, `show ip bgp*`, `show ip ospf*`),
#   - jembatan persistensi frr.conf live <-> /cfg (frr-sync/frr-restore
#     + frr-boot-reconcile; menutup 2 bug lama: frr.conf hilang
#     pasca-reboot, dan boot restore BIRD meski intent FRR).
# File intent lama /etc/titian/frr.conf TIDAK dipakai lagi (dan TIDAK
# boleh dipasang sebagai frr.conf live — formatnya bukan config FRR
# native; frr-restore menolak snapshot berformat intent).
#
# ANTI-HANG (diagnosis `router frr enable`+commit gantung >4 menit, 2x,
# 16 Nov 2026): semua pemanggilan backend satu-tembak yang dulu tanpa
# batas (`service frr start/stop`, `vtysh -c`) kini lewat run_bounded
# (watchdog POSIX sh; default vtysh 30 dtk, service start 60 dtk).
# Sesi interaktif `vtysh` TIDAK PERNAH dibungkus timeout — sesi user
# tidak boleh dibunuh watchdog.
# POSIX sh.
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
CFG_DIR=${TITIAN_CFG_DIR:-/cfg/titian}
SBIN_DIR=$(dirname "$0")
BIRD_SH="$SBIN_DIR/titian-bird.sh"
INTENT="$STATE_ROOT/netstate/routing.intent"
DIRTY=/var/run/routing.dirty
# Lokasi frr.conf live — overridable untuk uji (pola hermetik yang sama
# seperti TITIAN_STATE_ROOT di titian-bird.sh, B22). Default = lokasi
# live FreeBSD. JANGAN override di mesin live.
FRR_CONF=${TITIAN_FRR_CONF:-/usr/local/etc/frr/frr.conf}
# Direktori binary daemon FRR — overridable untuk uji (pola yang sama
# seperti TITIAN_FRR_CONF). Default = libdir FreeBSD. JANGAN override
# di mesin live.
FRR_LIBDIR=${TITIAN_FRR_LIBDIR:-/usr/local/lib/frr}
VTYSH_TIMEOUT=${TITIAN_FRR_VTYSH_TIMEOUT:-30}
SERVICE_TIMEOUT=${TITIAN_FRR_SERVICE_TIMEOUT:-60}
err() { echo "Error: $*" >&2; exit 33; }

have_vtysh() { command -v vtysh >/dev/null 2>&1; }

# run_bounded <detik> <perintah...>: jalankan dengan batas waktu.
# rc 0 = perintah selesai (rc asli diteruskan); rc 124 = timeout
# (child di-TERM lalu di-KILL). Output perintah diteruskan ke
# stdout/stderr pemanggil. HANYA untuk pemanggilan backend
# satu-tembak (service/vtysh -c). JANGAN dipakai untuk sesi
# interaktif (vtysh handoff) — sesi user tidak pernah dibungkus
# timeout. Implementasi watchdog POSIX sh (tanpa `timeout(1)` —
# ketersediaannya di FreeBSD base tidak dijamin).
run_bounded() {
    _limit="$1"; shift
    _out=$(mktemp /tmp/titian-bounded.XXXXXX) 2>/dev/null || { "$@"; return $?; }
    "$@" >"$_out" 2>&1 &
    _pid=$!
    _n=0
    _lim2=$((_limit * 2))
    while kill -0 "$_pid" 2>/dev/null; do
        if [ "$_n" -ge "$_lim2" ]; then
            kill -TERM "$_pid" 2>/dev/null || true
            sleep 1 2>/dev/null || sleep 1
            kill -KILL "$_pid" 2>/dev/null || true
            wait "$_pid" 2>/dev/null
            cat "$_out" 2>/dev/null
            rm -f "$_out"
            echo "Error: perintah kehabisan waktu sesudah ${_limit} detik: $*" >&2
            return 124
        fi
        sleep 0.5 2>/dev/null || sleep 1
        _n=$((_n + 1))
    done
    wait "$_pid"; _rc=$?
    cat "$_out" 2>/dev/null
    rm -f "$_out"
    return "$_rc"
}

vtysh_c() {
    # vtysh -c satu-tembak dengan batas waktu (hang mgmtd = gagal
    # LOUD, bukan gantung). Dipakai semua show + pemanggilan vtysh
    # yang hasilnya wajib ada (bukan best-effort).
    have_vtysh || err "vtysh tidak ditemukan (FRR tidak terpasang di image ini?)"
    run_bounded "$VTYSH_TIMEOUT" vtysh -c "$1" || err "vtysh gagal/timeout: $1"
}

sysrc_val() {
    command -v sysrc >/dev/null 2>&1 || return 1
    sysrc -n "$1" 2>/dev/null
}

set_intent() {
    # $1 = yes|no (niat frr)
    mkdir -p "$(dirname "$INTENT")" 2>/dev/null
    touch "$INTENT" 2>/dev/null
    _tmp="$INTENT.tmp.$$"
    grep -v "^frr " "$INTENT" > "$_tmp" 2>/dev/null || true
    printf 'frr %s\n' "$1" >> "$_tmp"
    mv "$_tmp" "$INTENT" || err "gagal tulis $INTENT"
    touch "$DIRTY" 2>/dev/null || true
}

intent_val() {
    [ -f "$INTENT" ] || { echo "unset"; return 0; }
    _v=$(sed -n 's/^frr //p' "$INTENT" 2>/dev/null | head -1)
    printf '%s' "${_v:-unset}"
}

svc() {
    # svc <name> <action>: gagal-aman bila `service` tak ada (uji Linux).
    if command -v service >/dev/null 2>&1; then
        service "$1" "$2"
    else
        echo "(service no  at host ini — lewati: service $1 $2)"
    fi
}

stop_frr_daemons() {
    # Matikan SEMUA daemon FRR. Daftar lama hanya mengenal 7 nama
    # (watchfrr/zebra/bgpd/ospfd/ripd/staticd/mgmtd) padahal
    # `frr_daemons` tak di-set → default rc script menaikkan SEMUA
    # 13 daemon + watchfrr, sehingga 7 daemon (ospf6d/ripngd/babeld/
    # bfdd/eigrpd/fabricd/isisd) tertinggal yatim sesudah disable
    # (Temuan 5, live test 17 Nov 2026). Daftar eksplisit lengkap di
    # bawah + sweep $FRR_LIBDIR (menangkap daemon tambahan seperti
    # pathd atau daemon FRR versi berikut — nama di sana selalu
    # daemon FRR; pkill -x pada nama yang tidak jalan = no-op).
    # `service frr stop` hanya mematikan watchfrr; zebra yatim bisa
    # berebut tabel route dengan BIRD. Beri waktu berhenti bersih,
    # paksa (-9) bila masih ada sesudah 5 detik.
    _daemons="watchfrr zebra bgpd ospfd ospf6d ripd ripngd staticd mgmtd babeld bfdd eigrpd fabricd isisd"
    if [ -d "$FRR_LIBDIR" ]; then
        for _f in "$FRR_LIBDIR"/*; do
            [ -e "$_f" ] || continue
            [ -x "$_f" ] || continue
            _daemons="$_daemons $(basename "$_f")"
        done
    fi
    _i=0
    while [ "$_i" -lt 10 ]; do
        _left=""
        for _d in $_daemons; do
            if command -v pgrep >/dev/null 2>&1; then
                pgrep -x "$_d" >/dev/null 2>&1 && _left="$_left $_d"
            fi
        done
        [ -z "$_left" ] && return 0
        if [ "$_i" = "0" ]; then
            for _d in $_daemons; do
                if command -v pkill >/dev/null 2>&1; then
                    pkill -x "$_d" 2>/dev/null || true
                fi
            done
        fi
        sleep 0.5 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    # Masih ada yang bandel — paksa.
    if command -v pkill >/dev/null 2>&1; then
        for _d in $_daemons; do pkill -9 -x "$_d" 2>/dev/null || true; done
        sleep 0.5 2>/dev/null || sleep 1
    fi
    return 0
}

# _mirror_rc_enable <bird YES|NO> <frr YES|NO>: tulis pasangan flag
# enable ke /cfg/rc.conf (bila file itu ada) agar rc boot berikutnya
# tidak menaikkan daemon yang salah. sysrc hanya menulis /etc/rc.conf
# (tmpfs di BSDRP — hilang saat reboot); tanpa cermin ini, /cfg/rc.conf
# yang basi (bird_enable=YES) membuat rc menaikkan BIRD saat boot
# meski intent FRR (bug b). Best-effort: gagal = diam, bukan fatal.
_mirror_rc_enable() {
    _cfg_parent=$(dirname "$CFG_DIR")
    [ -d "$_cfg_parent" ] || { mount /cfg 2>/dev/null || true; }
    [ -f "$_cfg_parent/rc.conf" ] || return 0
    _tmp="$_cfg_parent/rc.conf.titian.$$"
    grep -v '^bird_enable=' "$_cfg_parent/rc.conf" 2>/dev/null | grep -v '^frr_enable=' > "$_tmp" 2>/dev/null || true
    printf 'bird_enable="%s"\n' "$1" >> "$_tmp"
    printf 'frr_enable="%s"\n' "$2" >> "$_tmp"
    cp -f "$_tmp" "$_cfg_parent/rc.conf" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 0; }
    rm -f "$_tmp" 2>/dev/null || true
    return 0
}

do_check() {
    have_vtysh || err "FRR tidak terpasang (vtysh tidak ditemukan)"
    exit 0
}

do_enable() {
    have_vtysh || err "FRR tidak terpasang (vtysh tidak ditemukan)"
    # Mutual exclusion: tolak bila BIRD aktif (sysrc / service / proses / niat).
    sh "$BIRD_SH" check-exclusion frr || exit 33
    set_intent yes
    echo "router frr enable (pending commit — service frr naik saat commit)"
}

do_disable() {
    set_intent no
    echo "router frr disable (pending commit — service frr berhenti saat commit)"
}

do_apply() {
    # Dipanggil commit (dan boot). Terapkan niat: sysrc + service.
    local want
    want=$(intent_val)
    [ "$want" = "unset" ] && { echo "frr: tidak ada niat pending"; rm -f "$DIRTY"; return 0; }
    if [ "$want" = "yes" ]; then
        # Periksa ulang konflik SEBELUM menaikkan service.
        sh "$BIRD_SH" check-exclusion frr || exit 33
        if command -v sysrc >/dev/null 2>&1; then sysrc frr_enable="YES" >/dev/null || err "sysrc frr_enable gagal"; fi
        _mirror_rc_enable NO YES
        if [ -n "$(pgrep -x zebra 2>/dev/null | head -1)" ]; then
            echo "frr: zebra already jalan (not at-restart)"
        else
            run_bounded "$SERVICE_TIMEOUT" svc frr start \
                || err "service frr start gagal/timeout sesudah ${SERVICE_TIMEOUT} detik (daemon FRR tidak naik? cek 'show frr' + log daemon)"
        fi
        echo "frr: enabled + running"
    else
        # Berhenti DULU — pakai `onestop` (FreeBSD) agar tetap berhenti
        # walau frr_enable sudah NO (dari commit sebelumnya yang gagal).
        # `onestop` gagal di Linux -> fallback ke `stop`. Lalu matikan
        # SEMUA daemon (stop_frr_daemons) — `service frr stop` hanya
        # mematikan watchfrr (Temuan 5: 7 daemon yatim — ospf6d/
        # ripngd/babeld/bfdd/eigrpd/fabricd/isisd — tertinggal).
        run_bounded 30 svc frr onestop >/dev/null 2>&1 \
            || run_bounded 30 svc frr stop >/dev/null 2>&1 || true
        stop_frr_daemons
        if command -v sysrc >/dev/null 2>&1; then sysrc frr_enable="NO" >/dev/null || err "sysrc frr_enable gagal"; fi
        # Cermin: frr=NO; bird ikut niat BIRD (bukan YES paksa — disable
        # FRR saja tidak berarti enable BIRD).
        _bird_want=$(sed -n 's/^bird //p' "$INTENT" 2>/dev/null | head -1)
        if [ "$_bird_want" = "yes" ]; then _mirror_rc_enable YES NO; else _mirror_rc_enable NO NO; fi
        echo "frr: disabled + stopped"
    fi
    rm -f "$DIRTY"
    return 0
}

# --- handoff interaktif vtysh ---
do_vtysh() {
    # Masuk CLI native FRR sebagai CHILD (bukan exec) — `exit` di
    # vtysh kembali ke klish. stdio diwarisi dari proses klish:
    # saat sesi interaktif di TTY, child mendapat TTY; saat stdin
    # ter-pipe, tidak ada TTY -> gagal LOUD (bukan hang diam-diam).
    # Sesudah vtysh keluar, sinkronisasi persistensi best-effort.
    have_vtysh || err "vtysh tidak ditemukan (FRR tidak terpasang di image ini?)"
    _zpid=$(pgrep -x zebra 2>/dev/null | head -1)
    [ -n "$_zpid" ] || err "FRR belum jalan (zebra tidak ditemukan) — enable dulu: router frr enable + commit"
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        err "vtysh butuh sesi interaktif (TTY) — perintah ini tidak bisa dipakai dari pipe/skrip; jalankan dari sesi klish interaktif"
    fi
    echo "Masuk vtysh (CLI native FRR). Ketik 'exit' untuk kembali ke klish."
    vtysh
    _rc=$?
    _sync_persist
    echo "frr: keluar vtysh (rc=$_rc) — running-config disinkronkan ke $CFG_DIR/frr.conf (best-effort)"
    return "$_rc"
}

# --- jembatan persistensi frr.conf live <-> /cfg ---
_sync_persist() {
    # Best-effort, selalu exit 0: flush running-config FRR ke disk
    # (bila zebra jalan) lalu salin frr.conf live -> snapshot /cfg.
    # Dipanggil: sesudah keluar vtysh handoff + saat `save`
    # (titian-cfg.sh copy_all). Aman diulang: isi sama = hasil sama
    # (cmp: tidak ada penulisan bila identik).
    _zpid=$(pgrep -x zebra 2>/dev/null | head -1)
    if [ -n "$_zpid" ] && have_vtysh; then
        if ! run_bounded "$VTYSH_TIMEOUT" vtysh -c "write memory" >/dev/null 2>&1; then
            echo "Warning: frr-sync: vtysh 'write memory' gagal/timeout — snapshot /cfg mungkin tertinggal satu versi" >&2
        fi
    fi
    [ -f "$FRR_CONF" ] || return 0
    if [ ! -d "$CFG_DIR" ]; then
        mount /cfg 2>/dev/null || true
        mkdir -p "$CFG_DIR" 2>/dev/null || return 0
    fi
    [ -d "$CFG_DIR" ] || return 0
    if cmp -s "$FRR_CONF" "$CFG_DIR/frr.conf" 2>/dev/null; then return 0; fi
    _tmp="$CFG_DIR/frr.conf.tmp.$$"
    cp -f "$FRR_CONF" "$_tmp" 2>/dev/null && mv "$_tmp" "$CFG_DIR/frr.conf" 2>/dev/null \
        || { rm -f "$_tmp" 2>/dev/null; echo "Warning: frr-sync: gagal salin frr.conf ke $CFG_DIR" >&2; return 0; }
    return 0
}

do_sync() {
    _sync_persist
    echo "frr: running-config disinkronkan ke $CFG_DIR/frr.conf"
}

do_restore() {
    # Pasang snapshot /cfg -> frr.conf live (dipanggil titian-cfg.sh
    # restore saat boot). PERHATIAN (Temuan 1, 17 Nov 2026): FRR
    # sudah naik LEBIH DULU (rcorder `frr` sebelum `titian`) dengan
    # config minimal — memasang file saja TIDAK membuat daemon
    # memakai config itu; frr-boot-reconcile me-restart FRR sesudah
    # restore agar config yang dipulihkan benar-benar dipakai.
    # Bila snapshot BENAR-BENAR dipasang (file berubah), tandai
    # dengan flag $STATE_ROOT/.frr-restored untuk reconcile.
    # Best-effort, exit 0.
    # TOLAK snapshot format intent klish lama (baris `bgp ...` /
    # `ospf ...` / `route-map ...` / `prefix-list ...` /
    # `community-list ...`, atau header "intent klish") — itu BUKAN
    # frr.conf native; memasangnya akan membuat daemon gagal parse.
    # Snapshot begitu dibiarkan; `save` berikutnya menimpanya dengan
    # config native (via frr-sync).
    _snap="$CFG_DIR/frr.conf"
    [ -f "$_snap" ] || return 0
    # Keputusan segar tiap restore: hapus flag lama dulu; hanya
    # pemasangan snapshot baru yang boleh menyetelnya kembali.
    rm -f "$STATE_ROOT/.frr-restored" 2>/dev/null || true
    _first=$(grep -v '^#' "$_snap" 2>/dev/null | grep -v '^$' | head -1)
    case "$_first" in
        bgp\ *|ospf\ *|route-map\ *|prefix-list\ *|community-list\ *)
            echo "Warning: frr-restore: snapshot $_snap berformat intent klish lama — TIDAK dipasang sebagai frr.conf live (konfigurasi ulang via vtysh, lalu save)" >&2
            return 0 ;;
    esac
    if grep -q 'intent klish' "$_snap" 2>/dev/null; then
        echo "Warning: frr-restore: snapshot $_snap berformat intent klish lama — TIDAK dipasang sebagai frr.conf live (konfigurasi ulang via vtysh, lalu save)" >&2
        return 0
    fi
    if cmp -s "$_snap" "$FRR_CONF" 2>/dev/null; then return 0; fi
    mkdir -p "$(dirname "$FRR_CONF")" 2>/dev/null || return 0
    _tmp="$FRR_CONF.tmp.$$"
    cp -f "$_snap" "$_tmp" 2>/dev/null && mv "$_tmp" "$FRR_CONF" 2>/dev/null \
        || { rm -f "$_tmp" 2>/dev/null; echo "Warning: frr-restore: gagal pasang $_snap ke $FRR_CONF" >&2; return 0; }
    # `write memory` dari vtysh harus bisa menulis file ini: owner
    # frr:frr bila user itu ada (seperti yang dibuat rc script FRR).
    chown frr:frr "$FRR_CONF" 2>/dev/null || true
    # Tandai pemasangan untuk frr-boot-reconcile (Temuan 1).
    mkdir -p "$STATE_ROOT" 2>/dev/null || true
    touch "$STATE_ROOT/.frr-restored" 2>/dev/null || true
    echo "frr: frr.conf live dipulihkan dari $_snap"
    return 0
}

do_boot_reconcile() {
    # Dipanggil titian-boot.sh sesudah cfg restore, SEBELUM replay.
    # routing.intent = sumber kebenaran; rc.conf = turunan. Tanpa ini,
    # /etc/rc.conf yang dipulihkan dari /cfg (basi: bird_enable=YES)
    # membuat rc menaikkan BIRD saat boot, lalu check-exclusion commit
    # memblokir FRR — gejala "boot restore BIRD meski intent FRR".
    # Selaraskan rc.conf dari intent + hentikan daemon yang salah bila
    # sempat naik, agar replay + apply-all berjalan. Best-effort.
    # Flag restore dikonsumsi di sini (Temuan 1): dibaca + dihapus
    # di awal — apa pun cabang intent-nya — agar keputusan restart
    # selalu segar dari restore boot ini, bukan flag basi.
    _restored=0
    if [ -f "$STATE_ROOT/.frr-restored" ]; then _restored=1; fi
    rm -f "$STATE_ROOT/.frr-restored" 2>/dev/null || true
    _want=$(intent_val)
    [ "$_want" = "unset" ] && return 0
    _bird_want=$(sed -n 's/^bird //p' "$INTENT" 2>/dev/null | head -1)
    if [ "$_want" = "yes" ] && [ "$_bird_want" = "yes" ]; then
        echo "Warning: frr-boot: intent bentrok (bird yes + frr yes) — tidak direkonsiliasi, commit yang akan memblokir" >&2
        return 0
    fi
    if [ "$_want" = "yes" ]; then
        if command -v sysrc >/dev/null 2>&1; then
            sysrc bird_enable="NO" >/dev/null 2>&1
            sysrc frr_enable="YES" >/dev/null 2>&1
        fi
        _mirror_rc_enable NO YES
        if [ -n "$(pgrep -x bird 2>/dev/null | head -1)" ]; then
            echo "frr-boot: intent FRR — menghentikan BIRD yang sempat naik saat boot"
            run_bounded 30 svc bird onestop >/dev/null 2>&1 \
                || run_bounded 30 svc bird stop >/dev/null 2>&1 || true
        fi
        # RACE BOOT frr.conf (Temuan 1, 17 Nov 2026): rcorder
        # menempatkan `frr` SEBELUM `titian` — FRR sudah naik dengan
        # config minimal (RAM disk kosong) SEBELUM titian-cfg.sh
        # restore memasang snapshot /cfg; daemon tidak me-reload
        # file sendiri. Bila snapshot memang baru dipasang (flag
        # .frr-restored) DAN zebra jalan, restart FRR agar config
        # yang dipulihkan benar-benar dipakai (workaround yang
        # teruji live: `service frr restart` → BGP Established
        # kembali). Bila zebra belum jalan, restart tidak perlu —
        # apply-all nanti men-start FRR dengan file yang sudah
        # dipulihkan (tanpa race). Gagal restart = peringatan
        # lantang, boot tetap jalan.
        # (Jalan `BEFORE: frr` di rcorder tidak bisa ditempuh dari
        # staging ini: rc script titian tidak ada di repo ini —
        # hanya etc/rc.d/firewall + traffic-shape.)
        if [ "$_restored" = "1" ] && [ -n "$(pgrep -x zebra 2>/dev/null | head -1)" ]; then
            echo "frr-boot: intent FRR — restart FRR agar frr.conf yang dipulihkan dipakai (race boot, Temuan 1)"
            run_bounded "$SERVICE_TIMEOUT" svc frr restart >/dev/null 2>&1 \
                || run_bounded "$SERVICE_TIMEOUT" svc frr onerestart >/dev/null 2>&1 \
                || echo "Warning: frr-boot: restart FRR gagal — running-config mungkin masih minimal; jalankan 'service frr restart' manual" >&2
        fi
    elif [ "$_bird_want" = "yes" ]; then
        if command -v sysrc >/dev/null 2>&1; then
            sysrc bird_enable="YES" >/dev/null 2>&1
            sysrc frr_enable="NO" >/dev/null 2>&1
        fi
        _mirror_rc_enable YES NO
        if [ -n "$(pgrep -x zebra 2>/dev/null | head -1)" ]; then
            echo "frr-boot: intent BIRD — menghentikan daemon FRR yang sempat naik saat boot"
            run_bounded 30 svc frr onestop >/dev/null 2>&1 \
                || run_bounded 30 svc frr stop >/dev/null 2>&1 || true
            stop_frr_daemons
        fi
    else
        # Tidak ada niat routing (frr no/unset, bird no/unset): jangan
        # sentuh bird_enable; pastikan saja FRR mati + flag-nya NO.
        if command -v sysrc >/dev/null 2>&1; then
            sysrc frr_enable="NO" >/dev/null 2>&1
        fi
        _ben=$(sysrc_val bird_enable 2>/dev/null || echo NO)
        [ "$_ben" = "YES" ] || _ben=NO
        _mirror_rc_enable "$_ben" NO
        if [ -n "$(pgrep -x zebra 2>/dev/null | head -1)" ]; then
            echo "frr-boot: tidak ada niat routing — menghentikan daemon FRR yang sempat naik saat boot"
            run_bounded 30 svc frr onestop >/dev/null 2>&1 \
                || run_bounded 30 svc frr stop >/dev/null 2>&1 || true
            stop_frr_daemons
        fi
    fi
    return 0
}

frr_version() {
    local v=""
    if have_vtysh; then
        v=$(vtysh --version 2>/dev/null | head -1 | sed -n 's/.* \([0-9][0-9.]*\).*/\1/p')
    fi
    if [ -z "$v" ] && command -v pkg >/dev/null 2>&1; then
        v=$(pkg info -x '^frr[0-9]*$' 2>/dev/null | head -1 | sed -n 's/^frr[0-9]*-\([0-9][0-9.]*\).*/\1/p')
    fi
    printf '%s' "${v:-unknown}"
}

do_show() {
    local want fver fen frn zpid
    want=$(intent_val); fver=$(frr_version)
    fen=no; frn="not running"
    [ "$(sysrc_val frr_enable 2>/dev/null)" = "YES" ] && fen="enabled"
    zpid=$(pgrep -x zebra 2>/dev/null | head -1)
    [ -n "$zpid" ] && frn="running, pid $zpid"
    echo "FRR: $fver (intent: $want, rc: $fen, $frn)"
    if command -v service >/dev/null 2>&1; then
        service frr status 2>&1 | sed 's/^/  /'
    fi
    if have_vtysh && [ -n "$zpid" ]; then
        echo "-- daemons (vtysh show version):"
        run_bounded "$VTYSH_TIMEOUT" vtysh -c "show version" 2>/dev/null | head -5 | sed 's/^/  /'
    fi
}

do_show_version() {
    local fver zpid
    fver=$(frr_version)
    zpid=$(pgrep -x zebra 2>/dev/null | head -1)
    if [ -n "$zpid" ]; then
        echo "FRR $fver (running, pid $zpid)"
    else
        echo "FRR $fver (not running)"
    fi
    if have_vtysh; then
        run_bounded "$VTYSH_TIMEOUT" vtysh -c "show version" 2>/dev/null | sed -n '1,8p'
    fi
}

# --- show (vtysh passthrough, berbatas waktu) ---
do_show_ip() {
    # $1 = perintah vtysh lengkap, mis. "show ip bgp"
    _zpid=$(pgrep -x zebra 2>/dev/null | head -1)
    [ -n "$_zpid" ] || err "FRR belum jalan (enable dulu: router frr enable + commit)"
    vtysh_c "$1"
}


case "${1:-}" in
    check) do_check ;;
    frr-enable) do_enable ;;
    frr-disable) do_disable ;;
    frr-apply) do_apply ;;
    vtysh) do_vtysh ;;
    frr-sync) do_sync ;;
    frr-restore) do_restore ;;
    frr-boot-reconcile) do_boot_reconcile ;;
    show) do_show ;;
    show-version) do_show_version ;;
    show-ip-bgp) do_show_ip "show ip bgp" ;;
    show-ip-bgp-summary) do_show_ip "show ip bgp summary" ;;
    show-ip-ospf) do_show_ip "show ip ospf" ;;
    show-ip-ospf-neighbor) do_show_ip "show ip ospf neighbor" ;;
    show-ip-route) do_show_ip "show ip route" ;;
    *) echo "Usage: $0 {check|frr-enable|frr-disable|frr-apply|vtysh|frr-sync|frr-restore|frr-boot-reconcile|show|show-version|show-ip-bgp|show-ip-bgp-summary|show-ip-ospf|show-ip-ospf-neighbor|show-ip-route}" >&2; exit 2 ;;
esac
