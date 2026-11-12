#!/bin/sh
# apply.sh — pasang Titian/klish ke checkout BSDRP resmi.
#
# Cara pakai (dari branch ini):
#   git clone https://github.com/ocochard/BSDRP.git
#   git clone -b bsdrp https://github.com/ashadebi/titian.git bsdrp-titian
#   ./bsdrp-titian/apply.sh /path/ke/BSDRP
#
# Yang dilakukan:
#   1. Terapkan patches/bsdrp-titian.patch ke checkout BSDRP (git apply,
#      fallback: patch -p1). Patch ini hasil diff terhadap BSDRP resmi
#      HEAD c3d134a (23 Okt 2026) — 12 file yang diubah.
#   2. Salin isi files/ ke checkout BSDRP (9 file baru: port net/titian,
#      pf.conf, nfacctd, clear-logs, pkglist bird2/bird3, dsb).
#
# Idempotent: dijalankan 2x aman — patch yang sudah terpasang di-skip
# (dideteksi dari marker net/titian di pkglist.common), file disalin ulang
# dengan isi yang sama. Keluar 1 bila ada langkah yang gagal.
#
# TIDAK menyentuh: repo BSDRP resmi (hanya checkout lokal yang ditunjuk),
# tidak build, tidak dd, tidak mengubah branch titian mana pun.

set -u

die() { echo "apply.sh: ERROR: $*" >&2; exit 1; }
info() { echo "apply.sh: $*"; }

[ $# -eq 1 ] || die "pakai: $0 /path/ke/checkout-BSDRP"
BSDRP=$1

# --- resolve direktori skrip ini (root branch bsdrp-titian) ---
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || die "tidak bisa resolve direktori skrip"
PATCH="$SCRIPT_DIR/patches/bsdrp-titian.patch"
FILES_DIR="$SCRIPT_DIR/files"
[ -f "$PATCH" ] || die "patch tidak ditemukan: $PATCH"
[ -d "$FILES_DIR" ] || die "direktori files/ tidak ditemukan: $FILES_DIR"

# --- validasi checkout BSDRP ---
[ -d "$BSDRP" ] || die "checkout BSDRP tidak ada: $BSDRP"
[ -f "$BSDRP/Makefile" ] || die "$BSDRP bukan checkout BSDRP (Makefile tidak ada)"
[ -d "$BSDRP/BSDRP" ] || die "$BSDRP bukan checkout BSDRP (dir BSDRP/ tidak ada)"
[ -d "$BSDRP/poudriere.etc" ] || die "$BSDRP bukan checkout BSDRP (dir poudriere.etc/ tidak ada)"
[ -d "$BSDRP/.git" ] || die "$BSDRP bukan repo git (butuh .git untuk git apply)"
BSDRP=$(CDPATH= cd -- "$BSDRP" && pwd) || die "tidak bisa resolve path BSDRP"
info "checkout BSDRP: $BSDRP"
info "sumber patch: $SCRIPT_DIR"

# --- langkah 1: terapkan patch ---
MARKER_FILE="$BSDRP/poudriere.etc/poudriere.d/BSDRP-pkglist.common"
if grep -q "net/titian" "$MARKER_FILE" 2>/dev/null; then
    info "patch sudah terpasang (net/titian ada di BSDRP-pkglist.common) — skip langkah 1"
else
    info "menerapkan patch (12 file) ..."
    cd "$BSDRP" || die "tidak bisa cd ke $BSDRP"
    if git apply --check "$PATCH" 2>/tmp/apply-git-check.err; then
        git apply "$PATCH" || die "git apply gagal (lihat error di atas)"
        info "patch terpasang via git apply"
    else
        info "git apply --check gagal, coba fallback patch -p1 ..."
        if command -v patch >/dev/null 2>&1 && patch -p1 --dry-run < "$PATCH" >/dev/null 2>&1; then
            patch -p1 < "$PATCH" || die "patch -p1 gagal"
            info "patch terpasang via patch -p1"
        else
            cat /tmp/apply-git-check.err >&2
            die "patch tidak bisa diterapkan (bukan checkout BSDRP HEAD c3d134a? atau sudah dimodifikasi?). Periksa error di atas."
        fi
    fi
    grep -q "net/titian" "$MARKER_FILE" || die "verifikasi gagal: net/titian tidak ada di BSDRP-pkglist.common setelah patch"
    info "verifikasi patch OK (net/titian ada di pkglist.common)"
fi

# --- langkah 2: salin file baru (files/) ---
info "menyalin file baru (9 file) dari files/ ..."
cp -R "$FILES_DIR/"* "$BSDRP"/ || die "gagal menyalin files/ ke $BSDRP"
for f in \
    "BSDRP/patches/ports.titian.shar" \
    "BSDRP/Files/etc/pf.conf" \
    "BSDRP/Files/usr/local/etc/nfacctd.conf" \
    "BSDRP/Files/usr/local/etc/rc.d/nfacctd" \
    "BSDRP/Files/usr/local/etc/newsyslog.conf.d/nfacctd" \
    "BSDRP/Files/usr/local/sbin/clear-logs" \
    "BSDRP/Files/usr/local/share/info/.keep" \
    "poudriere.etc/poudriere.d/BSDRP-pkglist.bird2" \
    "poudriere.etc/poudriere.d/BSDRP-pkglist.bird3"
do
    [ -f "$BSDRP/$f" ] || die "verifikasi gagal: $f tidak ada setelah penyalinan"
done
info "verifikasi file baru OK (9/9 ada)"

# --- ringkasan ---
info "SELESAI. Status checkout BSDRP:"
cd "$BSDRP" && git status --short | sed 's/^/  /'
info "Lanjut: build image seperti biasa (lihat docs/INSTALL.md)."
