#!/bin/sh
# titian-update.sh — perintah `update` (19 Nov 2026): cek + install
# rilis Titian dari GitHub Releases (enable view, operasi — mengikuti
# pola save/checkpoint, BUKAN configure view).
#
#   update check           READ-ONLY: cek rilis terbaru GitHub, bandingkan
#                          dengan versi ter-install (pkg info titian).
#                          Laporan: UPDATE TERSEDIA / SUDAH TERBARU /
#                          TIDAK DAPAT DIHUBUNGI. rc 0 selalu (laporan).
#   update install         ARM: tampilkan versi baru + ringkasan + perintah
#                          konfirmasi. TIDAK download / install / restart.
#   update install confirm EKSEKUSI: download .pkg -> verifikasi sha256 ->
#                          pkg add -f -> restart service -> verifikasi
#                          config. Tanpa konfirmasi TIDAK ADA yang berubah.
#
# Sumber: GitHub API publik (tanpa auth):
#   https://api.github.com/repos/ashadebi/titian/releases/latest
# Tag rilis: titian-bsdrp-<versi> (contoh: titian-bsdrp-0.1.0). Versi
# rilis HARUS naik tiap rilis (PORTVERSION di-bump — syarat proses
# rilis, lihat UPDATE-LIVE-PLAN.md); bila tidak naik, `update check`
# melaporkan SUDAH TERBARU dan install menolak.
# Asset: titian-bsdrp-<versi>.pkg — URL diambil dari field
# browser_download_url di respons API, JANGAN konstruksi manual.
# Checksum sha256: dari body rilis (baris "SHA-256: <hex>  <file>.pkg")
# atau asset titian-bsdrp-<versi>.pkg.sha256. Bila TIDAK dipublikasikan
# atau TIDAK COCOK -> GAGAL LANTANG (rc 33), jangan install, versi lama
# tetap utuh.
#
# HTTP: curl dulu (bila ada), fallback fetch (base FreeBSD — bila curl
# tidak terpasang). Tanpa keduanya -> gagal lantang. GitHub API tanpa
# auth dibatasi 60 request/jam per IP — cek manual saja, jangan
# di-cron (TIDAK ADA cron auto-apply: cek + install hanya atas
# perintah; auto-update diam-diam TIDAK dibuat).
#
# Install: `pkg add -f <file>` — pkg add biasa menolak bila paket sudah
# ter-install (versi sama); -f memaksa penggantian. Alur ini hanya jalan
# bila rilis LEBIH BARU dari yang ter-install (install menolak bila
# sudah terbaru), jadi -f di sini adalah pengaman, bukan jalan pintas.
# Paket membawa hook @preexec mount-rw (remount / rw saat install).
#
# Restart: `service titian restart` (pola titian-checkpoint.sh) dengan
# guard save<->restore titian-cfg.sh yang menjaga running-config
# (fix 18 Nov 2026). Sesudah restart VERIFIKASI (aturan mengikat):
# startup-config vs /cfg (tanpa stempel), bird.conf md5 (harus SAMA
# dengan sebelum update — paket tidak memiliki config), jumlah BGP
# Established (harus kembali ke jumlah sebelum update; polling
# maksimal 60 detik). Gagal di langkah mana pun -> gagal lantang,
# laporkan, jangan tinggalkan setengah upgrade.
#
# YANG TIDAK PERNAH DISENTUH: konfigurasi di /cfg (paket tidak
# memilikinya — config harus selamat melewati update; skrip hanya
# MEMBACA startup-config/bird.conf untuk verifikasi), binary/tree di
# luar yang di-update paket, disk/partisi lain. Download ke direktori
# temp; cek ruang kosong dulu (df — ingat /var tmpfs 32M, .pkg
# ~2,6MB); hapus file temp sesudah selesai (berhasil maupun gagal).
#
# Hermetik (uji): TITIAN_STATE_ROOT / TITIAN_CFG_DIR /
# TITIAN_BIRD_LIVE_CONF / TITIAN_BIRD_ETC_CONF / TITIAN_BIRD_PERSIST /
# TITIAN_UPDATE_TMPDIR / TITIAN_UPDATE_HTTP (curl|fetch|auto).
# Dalam mode hermetik, pkg/service/birdc/curl/df diasumsikan STUB
# (disediakan harness mock) — produksi tidak pernah memakai mode ini.
# Produksi TIDAK PERNAH men-set variabel TITIAN_*.
#
# POSIX sh. Dibuat 2026-11-19 (perintah user: "bangun titian update").

PROG="titian-update"
API_URL="https://api.github.com/repos/ashadebi/titian/releases/latest"
REPO="ashadebi/titian"
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
CFG_DIR=${TITIAN_CFG_DIR:-/cfg/titian}
OS=${TITIAN_OS:-$(uname -s)}
BIRD_LIVE=${TITIAN_BIRD_LIVE_CONF:-/usr/local/etc/bird.conf}
BIRD_ETC=${TITIAN_BIRD_ETC_CONF:-/etc/local/bird.conf}
BIRD_PERSIST=${TITIAN_BIRD_PERSIST:-/cfg/local/bird.conf}
STARTUP_LIVE="$STATE_ROOT/startup-config"
STARTUP_CFG="$CFG_DIR/startup-config"
TMP_BASE=${TITIAN_UPDATE_TMPDIR:-${TMPDIR:-/tmp}}
BGP_POLL_MAX=60

err() { echo "Error: $PROG: $*" >&2; exit 33; }

is_hermetic() {
    [ -n "${TITIAN_STATE_ROOT:-}" ] && [ "$TITIAN_STATE_ROOT" != "/etc/titian" ]
}

file_sig() {
    # $1 = file -> cetak sidik isi (md5) atau kosong bila file tak ada.
    # Portable: md5 FreeBSD (`md5 -q`), GNU (`md5sum`), fallback cksum.
    # (Pola yang sama seperti titian-cfg.sh file_sig().)
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

stream_md5() {
    # stdin -> md5 hex (atau kosong). Rantai tool yang sama seperti file_sig.
    if command -v md5 >/dev/null 2>&1; then
        md5 -q 2>/dev/null && return 0
    fi
    if command -v md5sum >/dev/null 2>&1; then
        md5sum 2>/dev/null | awk '{print $1}' && return 0
    fi
    cksum 2>/dev/null | awk '{print $1"-"$2}' || echo ""
}

stream_sha256() {
    # stdin -> sha256 hex (atau kosong). Portable: sha256 FreeBSD
    # (`sha256 -q`), GNU (`sha256sum`), fallback `shasum -a 256`.
    if command -v sha256 >/dev/null 2>&1; then
        sha256 -q 2>/dev/null && return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum 2>/dev/null | awk '{print $1}' && return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 2>/dev/null | awk '{print $1}' && return 0
    fi
    echo ""
}

file_sha256() {
    _f="$1"
    [ -f "$_f" ] || { echo ""; return 0; }
    stream_sha256 < "$_f"
}

startup_md5() {
    # $1 = file startup-config -> md5 isi TANPA stempel 'last commit:'
    # (pola yang sama seperti verifikasi anchor: grep -v TANPA anchor ^).
    _f="$1"
    [ -f "$_f" ] || { echo ""; return 0; }
    grep -v 'last commit:' "$_f" 2>/dev/null | stream_md5
}

ver_cmp() {
    # $1 $2 = versi (0.1.0, 0.10.0) -> echo -1 / 0 / 1 (perbandingan
    # NUMERIK per komponen — 0.10.0 > 0.9.0, bukan leksikal).
    _a="$1"; _b="$2"; _i=1
    while :; do
        _fa=$(printf '%s' "$_a" | cut -d. -f"$_i" 2>/dev/null)
        _fb=$(printf '%s' "$_b" | cut -d. -f"$_i" 2>/dev/null)
        [ -z "$_fa" ] && [ -z "$_fb" ] && { echo 0; return; }
        _fa=${_fa:-0}; _fb=${_fb:-0}
        _fa=$(printf '%s' "$_fa" | sed 's/^0*//'); [ -z "$_fa" ] && _fa=0
        _fb=$(printf '%s' "$_fb" | sed 's/^0*//'); [ -z "$_fb" ] && _fb=0
        [ "$_fa" -lt "$_fb" ] && { echo -1; return; }
        [ "$_fa" -gt "$_fb" ] && { echo 1; return; }
        _i=$((_i+1))
    done
}

tag_version() {
    # $1 = tag (titian-bsdrp-0.2.0) -> versi (0.2.0) atau kosong bila
    # pola tag tidak dikenal / versi bukan angka-titik.
    case "$1" in
        titian-bsdrp-[0-9]*)
            _v=${1#titian-bsdrp-}
            case "$_v" in
                *[!0-9.]*) echo "" ;;
                *) echo "$_v" ;;
            esac
            ;;
        *) echo "" ;;
    esac
}

http_get() {
    # $1 = URL, $2 = file output -> 0 bila sukses, 1 bila gagal.
    # curl dulu; bila curl tidak ada ATAU gagal, coba fetch (base
    # FreeBSD). TITIAN_UPDATE_HTTP memaksa salah satu (uji).
    _client="${TITIAN_UPDATE_HTTP:-auto}"
    if [ "$_client" = "auto" ] || [ "$_client" = "curl" ]; then
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --max-time 30 -o "$2" "$1" 2>/dev/null; then return 0; fi
            [ "$_client" = "curl" ] && return 1
        fi
    fi
    if [ "$_client" = "auto" ] || [ "$_client" = "fetch" ]; then
        if command -v fetch >/dev/null 2>&1; then
            if fetch -o "$2" "$1" 2>/dev/null; then return 0; fi
        fi
    fi
    return 1
}

json_tag() {
    # $1 = file JSON -> tag_name (atau kosong).
    sed -n 's/^[[:space:]]*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

json_body_sha() {
    # $1 = file JSON -> sha256 hex dari body rilis (baris
    # "SHA-256: <64 hex>  <file>.pkg") atau kosong. Body ada dalam satu
    # baris JSON (dengan escape \n), jadi grep pada baris "body" cukup.
    grep '"body"' "$1" 2>/dev/null | sed -n 's/.*SHA-256:[[:space:]]*\([0-9a-fA-F]\{64\}\).*/\1/p' | head -1
}

json_asset_field() {
    # $1 = file JSON, $2 = nama asset, $3 = field
    # (browser_download_url|size) -> nilai (atau kosong).
    # Parser awk atas respons API pretty-printed (format standar
    # api.github.com): objek asset dimulai baris "    {", field "name"
    # muncul sebelum field lain di objek yang sama.
    awk -v name="$2" -v field="$3" '
        /^[ \t]*{$/ { cur = "" }
        /"name"[ \t]*:/ {
            line = $0
            sub(/^.*"name"[ \t]*:[ \t]*"/, "", line)
            sub(/".*$/, "", line)
            cur = line
        }
        cur == name && $0 ~ ("\"" field "\"[ \t]*:") {
            line = $0
            if (field == "browser_download_url") {
                sub(/^.*"browser_download_url"[ \t]*:[ \t]*"/, "", line)
                sub(/".*$/, "", line)
                print line; exit
            } else if (field == "size") {
                sub(/^.*"size"[ \t]*:[ \t]*/, "", line)
                sub(/[^0-9].*$/, "", line)
                print line; exit
            }
        }
    ' "$1" 2>/dev/null
}

installed_version() {
    # -> versi titian ter-install via pkg (0.1.0) atau kosong bila
    # pkg tidak ada / titian belum ter-install.
    command -v pkg >/dev/null 2>&1 || return 0
    _out=$(pkg info titian 2>/dev/null) || return 0
    printf '%s\n' "$_out" | awk '/^Version[ \t]*:/ {print $3; exit}'
}

bgp_count() {
    # -> jumlah BGP Established (birdc) atau "none" bila birdc tidak ada.
    command -v birdc >/dev/null 2>&1 || { echo "none"; return 0; }
    _n=$(birdc show protocols 2>/dev/null | grep -c 'Established')
    echo "${_n:-0}"
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

fetch_release() {
    # $1 = direktori kerja temp. Mengisi REL_TAG/REL_VER/REL_PKG/
    # REL_PKG_URL/REL_PKG_SIZE/REL_SHA/REL_SHA_URL (global).
    # rc 0 = OK; rc 1 = API tidak dapat dihubungi; rc 2 = respons tidak
    # dapat diparse / tag tidak dikenal / asset .pkg tidak ada.
    _api="$1/api.json"
    http_get "$API_URL" "$_api" || return 1
    [ -s "$_api" ] || return 1
    REL_TAG=$(json_tag "$_api")
    [ -n "$REL_TAG" ] || return 2
    REL_VER=$(tag_version "$REL_TAG")
    [ -n "$REL_VER" ] || return 2
    REL_PKG="titian-bsdrp-$REL_VER.pkg"
    REL_PKG_URL=$(json_asset_field "$_api" "$REL_PKG" browser_download_url)
    [ -n "$REL_PKG_URL" ] || return 2
    REL_PKG_SIZE=$(json_asset_field "$_api" "$REL_PKG" size)
    case "$REL_PKG_SIZE" in *[!0-9]*) REL_PKG_SIZE="" ;; esac
    REL_SHA=$(json_body_sha "$_api")
    REL_SHA_URL=$(json_asset_field "$_api" "$REL_PKG.sha256" browser_download_url)
    return 0
}

resolve_checksum() {
    # $1 = direktori kerja temp -> sha256 hex (lowercase) atau kosong.
    # Sumber: body rilis dulu, bila tidak ada: asset .pkg.sha256
    # (diunduh, diambil token hex pertama).
    _sha=$(printf '%s' "$REL_SHA" | tr 'A-F' 'a-f')
    [ -n "$_sha" ] && { echo "$_sha"; return 0; }
    [ -n "$REL_SHA_URL" ] || { echo ""; return 0; }
    _sf="$1/pkg.sha256"
    http_get "$REL_SHA_URL" "$_sf" || { echo ""; return 0; }
    grep -o '[0-9a-fA-F]\{64\}' "$_sf" 2>/dev/null | head -1 | tr 'A-F' 'a-f'
}

verify_post_update() {
    # $1 = startup md5 pra-update, $2 = bird.conf md5 pra-update,
    # $3 = jumlah BGP Established pra-update (atau "none" bila birdc
    # tidak ada). rc 0 = semua cocok; rc 1 = ada yang tidak cocok
    # (pesan dicetak).
    _bad=0
    _s1=$(startup_md5 "$STARTUP_LIVE"); _s2=$(startup_md5 "$STARTUP_CFG")
    if [ "$_s1" != "$_s2" ]; then
        echo "VERIFIKASI GAGAL: startup-config live ($_s1) != /cfg ($_s2)" >&2; _bad=1
    elif [ -n "$1" ] && [ "$_s1" != "$1" ]; then
        echo "VERIFIKASI GAGAL: startup-config berubah melewati update (sebelum $1, sesudah $_s1)" >&2; _bad=1
    fi
    _b1=$(file_sig "$BIRD_LIVE"); _b2=$(file_sig "$BIRD_ETC"); _b3=$(file_sig "$BIRD_PERSIST")
    if [ "$_b1" != "$_b2" ] || [ "$_b1" != "$_b3" ]; then
        echo "VERIFIKASI GAGAL: bird.conf tidak konsisten (live $_b1, /etc/local $_b2, /cfg/local $_b3)" >&2; _bad=1
    elif [ -n "$2" ] && [ "$_b1" != "$2" ]; then
        echo "VERIFIKASI GAGAL: bird.conf berubah melewati update (sebelum $2, sesudah $_b1)" >&2; _bad=1
    fi
    if [ "$3" = "none" ]; then
        echo "VERIFIKASI: birdc tidak ada — cek BGP dilewati (BIRD tidak jalan di mesin ini)."
    else
        _n=0; _i=0
        while [ "$_i" -lt 12 ]; do
            _n=$(bgp_count)
            [ "$_n" = "$3" ] && break
            sleep 5; _i=$((_i+1))
        done
        if [ "$_n" != "$3" ]; then
            echo "VERIFIKASI GAGAL: BGP Established sesudah restart ($_n) != sebelum update ($3) — belum kembali sesudah ${BGP_POLL_MAX} dtk" >&2; _bad=1
        fi
    fi
    [ "$_bad" = "0" ]
}

cmd_check() {
    _tmp=$(mktemp -d "$TMP_BASE/update-check.XXXXXX") || err "gagal membuat direktori temp"
    trap 'rm -rf "$_tmp"' EXIT
    _inst=$(installed_version)
    fetch_release "$_tmp"; _rc=$?
    if [ "$_rc" = "1" ]; then
        echo "update check: rilis GitHub TIDAK DAPAT DIHUBUNGI ($API_URL)"
        echo "versi ter-install: ${_inst:-belum ter-install via pkg}"
        return 0
    fi
    if [ "$_rc" = "2" ]; then
        echo "update check: respons GitHub tidak dapat diparse / tag rilis tidak dikenal (tag: ${REL_TAG:-?})"
        echo "versi ter-install: ${_inst:-belum ter-install via pkg}"
        return 0
    fi
    if [ -z "$_inst" ]; then
        echo "update check: titian BELUM ter-install via pkg"
        echo "rilis terbaru: $REL_TAG (versi $REL_VER)"
        echo "asset: $REL_PKG (${REL_PKG_SIZE:-?} byte)"
        return 0
    fi
    _cmp=$(ver_cmp "$_inst" "$REL_VER")
    case "$_cmp" in
        -1) echo "update check: UPDATE TERSEDIA — ter-install $_inst, terbaru $REL_VER (tag $REL_TAG)"
            echo "asset: $REL_PKG (${REL_PKG_SIZE:-?} byte)"
            echo "jalankan: update install" ;;
        0)  echo "update check: SUDAH TERBARU — versi $_inst == rilis $REL_VER" ;;
        1)  echo "update check: ter-install $_inst LEBIH BARU dari rilis $REL_VER" ;;
    esac
    return 0
}

cmd_install() {
    _tmp=$(mktemp -d "$TMP_BASE/update-install.XXXXXX") || err "gagal membuat direktori temp"
    trap 'rm -rf "$_tmp"' EXIT
    _inst=$(installed_version)
    [ -n "$_inst" ] || err "titian belum ter-install via pkg — update tidak bisa jalan (install manual dari .pkg dulu)"
    fetch_release "$_tmp"; _rc=$?
    [ "$_rc" = "1" ] && err "rilis GitHub tidak dapat dihubungi — coba lagi nanti ('update check' untuk status)"
    [ "$_rc" = "2" ] && err "respons GitHub tidak dapat diparse / tag rilis tidak dikenal (tag: ${REL_TAG:-?})"
    _cmp=$(ver_cmp "$_inst" "$REL_VER")
    [ "$_cmp" = "-1" ] || err "sudah terbaru (ter-install $_inst, rilis $REL_VER) — tidak ada yang di-update"
    echo "update install: versi baru $REL_VER (tag $REL_TAG), ter-install $_inst"
    echo "asset: $REL_PKG (${REL_PKG_SIZE:-?} byte)"
    if [ -n "$REL_SHA" ]; then
        echo "checksum sha256: dipublikasikan di body rilis"
    elif [ -n "$REL_SHA_URL" ]; then
        echo "checksum sha256: asset $REL_PKG.sha256"
    else
        echo "checksum sha256: TIDAK DIPUBLIKASIKAN — 'update install confirm' akan MENOLAK (rilis wajib mempublikasikan sha256; lihat UPDATE-LIVE-PLAN.md)"
    fi
    echo "Alur eksekusi: download $REL_PKG -> verifikasi sha256 -> pkg add -f -> restart service titian -> verifikasi config (startup-config vs /cfg, bird.conf md5, BGP Established)."
    echo "Konfigurasi di /cfg TIDAK disentuh. TIDAK ada cron auto-apply."
    echo "Untuk eksekusi, jalankan: update install confirm"
    return 0
}

cmd_install_confirm() {
    _tmp=$(mktemp -d "$TMP_BASE/update-install.XXXXXX") || err "gagal membuat direktori temp"
    trap 'rm -rf "$_tmp"' EXIT
    is_hermetic && echo "update install: mode uji (hermetik) — pkg/service/birdc/curl/df adalah stub."
    _inst=$(installed_version)
    [ -n "$_inst" ] || err "titian belum ter-install via pkg — update tidak bisa jalan (install manual dari .pkg dulu)"
    fetch_release "$_tmp"; _rc=$?
    [ "$_rc" = "1" ] && err "rilis GitHub tidak dapat dihubungi — batal, versi lama tetap utuh ($_inst)"
    [ "$_rc" = "2" ] && err "respons GitHub tidak dapat diparse / tag rilis tidak dikenal — batal, versi lama tetap utuh ($_inst)"
    _cmp=$(ver_cmp "$_inst" "$REL_VER")
    [ "$_cmp" = "-1" ] || err "sudah terbaru (ter-install $_inst, rilis $REL_VER) — batal, tidak ada yang di-update"
    _sha=$(resolve_checksum "$_tmp")
    [ -n "$_sha" ] || err "checksum sha256 TIDAK dipublikasikan untuk rilis $REL_TAG — batal, versi lama tetap utuh ($_inst)"
    # Ruang kosong: ukuran asset + margin 1MB (bila ukuran tidak
    # diketahui: 10MB). /var tmpfs 32M — .pkg ~2,6MB.
    _need=$(( ${REL_PKG_SIZE:-0} + 1048576 ))
    [ "${REL_PKG_SIZE:-0}" = "0" ] && _need=10485760
    _avail_kb=$(df -k "$_tmp" 2>/dev/null | tail -1 | awk '{print $4}')
    _avail_kb=${_avail_kb:-0}
    case "$_avail_kb" in *[!0-9]*) _avail_kb=0 ;; esac
    if [ $(( _avail_kb * 1024 )) -lt "$_need" ]; then
        err "ruang kosong di $_tmp tidak cukup (butuh $_need byte, tersedia $(( _avail_kb * 1024 )) byte) — batal, versi lama tetap utuh"
    fi
    # Baseline pra-update (untuk verifikasi pasca-restart).
    _pre_startup=$(startup_md5 "$STARTUP_LIVE")
    _pre_bird=$(file_sig "$BIRD_LIVE")
    _pre_bgp=$(bgp_count)
    echo "update install: $_inst -> $REL_VER (asset $REL_PKG, ${REL_PKG_SIZE:-?} byte)"
    # Download.
    _pkgfile="$_tmp/$REL_PKG"
    http_get "$REL_PKG_URL" "$_pkgfile" || err "download $REL_PKG gagal — batal, versi lama tetap utuh ($_inst)"
    [ -s "$_pkgfile" ] || err "file $REL_PKG kosong sesudah download — batal, versi lama tetap utuh ($_inst)"
    # Verifikasi sha256.
    _got=$(file_sha256 "$_pkgfile" | tr 'A-F' 'a-f')
    [ -n "$_got" ] || err "tidak dapat menghitung sha256 file yang diunduh — batal, versi lama tetap utuh"
    [ "$_got" = "$_sha" ] || err "sha256 TIDAK COCOK (diharapkan $_sha, didapat $_got) — batal, JANGAN install, versi lama tetap utuh ($_inst)"
    echo "update install: sha256 cocok."
    # Install (upgrade lokal — pkg add -f: pkg add biasa menolak bila
    # paket sudah ter-install).
    pkg add -f "$_pkgfile" || err "pkg add -f gagal — batal, versi lama tetap utuh ($_inst)"
    _new=$(installed_version)
    [ -n "$_new" ] || err "pkg info gagal sesudah install — keadaan tidak pasti, LAPORKAN (file baru mungkin sudah ter-install)"
    [ "$_new" = "$REL_VER" ] || err "versi sesudah install ($_new) != rilis ($REL_VER) — setengah upgrade, LAPORKAN"
    echo "update install: paket ter-install ($_new)."
    # Restart + verifikasi.
    echo "update install: restart service titian..."
    service_restart || err "service titian restart GAGAL sesudah install — file baru sudah ter-install ($_new), service masih jalan dengan konfd lama; jalankan 'service titian restart' manual, lalu verifikasi config"
    if verify_post_update "$_pre_startup" "$_pre_bird" "$_pre_bgp"; then
        echo "update install: SELESAI — $_inst -> $_new (config utuh: startup-config vs /cfg cocok, bird.conf md5 sama, BGP ${_pre_bgp} Established)."
    else
        err "verifikasi pasca-restart GAGAL — paket baru sudah ter-install ($_new) tapi config/BGP tidak kembali seperti sebelum update; LAPORKAN, jangan lanjutkan pekerjaan lain"
    fi
    return 0
}

case "$1" in
    check)           cmd_check ;;
    install)         cmd_install ;;
    install-confirm) cmd_install_confirm ;;
    *) echo "usage: $PROG <check|install|install-confirm>" >&2; exit 2 ;;
esac
exit 0
