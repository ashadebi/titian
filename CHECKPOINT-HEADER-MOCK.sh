#!/bin/sh
# CHECKPOINT-HEADER-MOCK.sh — bukti staging perbaikan header checkpoint
# (23 Nov 2026, temuan Part 9): rollback dari checkpoint lama kehilangan
# 3 baris header startup-config (`! version ...`, ` ! last commit: ...`,
# `!` pemisah — 409 -> 406 baris) + /cfg tidak dipulihkan.
# Perbaikan di titian/sbin/titian-checkpoint.sh: titik menyimpan blok
# stempel byte-persis di `startup-header`; rollback merekonstruksi
# startup-config byte-identik di /etc/titian DAN /cfg/titian.
#
# Membuktikan TANPA mesin test (semua hermetik di /tmp, stub clish):
#   (a) `save` membuat startup-header = 4 baris blok stempel persis;
#   (b) restore dari titik -> startup-config /etc + /cfg BYTE-IDENTIK
#       dengan file pra-uji (cmp kosong);
#   (c) titik LAMA (tanpa startup-header) -> perilaku lama: /etc =
#       dump polos (3 baris hilang) + /cfg TIDAK disentuh;
#   (d) startup-config tanpa stempel -> save tidak membuat startup-header;
#   (e) `snapshot-last-save` juga membuat startup-header.
# Restore diuji lewat fungsi restore_files asli (disalin + blok dispatch
# dibuang, prologue pager dinonaktifkan — transformasi harness saja,
# skrip repo tidak diubah).
# POSIX sh. Keluar 0 bila semua PASS.
STAGE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CKPT_SH="$STAGE/titian/sbin/titian-checkpoint.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

MOCKROOT=$(mktemp -d /tmp/ckpt-hdr-mock.XXXXXX) || { echo "FAIL: mktemp"; exit 1; }
trap 'if [ "$FAIL" -gt 0 ]; then echo "MOCKROOT (dipertahankan untuk inspeksi): $MOCKROOT"; else rm -rf "$MOCKROOT"; fi' EXIT

STATE_ROOT="$MOCKROOT/etc-titian"
CFG_DIR="$MOCKROOT/cfg-titian"
STATE_DIR="$MOCKROOT/netstate"
TITIAN_ROOT="$MOCKROOT/root"
mkdir -p "$STATE_ROOT" "$CFG_DIR" "$STATE_DIR" "$TITIAN_ROOT/bin" "$TITIAN_ROOT/sbin"
export TITIAN_STATE_ROOT="$STATE_ROOT" TITIAN_CFG_DIR="$CFG_DIR"
export TITIAN_STATE_DIR="$STATE_DIR" TITIAN_ROOT="$TITIAN_ROOT"
export TITIAN_BIRD_LIVE_CONF="$MOCKROOT/bird.conf"
export OS=FreeBSD

# bird.conf live (harus bermarker agar ikut dipotret)
printf '#-GLOBAL-#\nprotocol device {}\n' > "$MOCKROOT/bird.conf"

# --- startup-config pra-uji (bentuk anchor: 4 baris blok stempel) ---
ANCHOR="$MOCKROOT/startup-anchor"
cat > "$ANCHOR" <<'EOF'
!
! version core: 2.2.5
 ! last commit: Sat Nov 21 10:50:41 UTC 2026
!
system help-language english
!
service ssh
 allow-root
!
end
EOF
cp -f "$ANCHOR" "$STATE_ROOT/startup-config"
cp -f "$ANCHOR" "$CFG_DIR/startup-config"

# --- dump running-config seperti yang dicetak `show running-config`
# (tanpa 3 baris stempel; diawali `!`) ---
DUMP="$MOCKROOT/dump.txt"
cat > "$DUMP" <<'EOF'
# show running-config
!
system help-language english
!
service ssh
 allow-root
!
end
EOF
export MOCK_DUMP="$DUMP"

# --- stub clish: abaikan argumen, cetak dump kanonis ---
cat > "$TITIAN_ROOT/bin/clish" <<'EOF'
#!/bin/sh
cat "$MOCK_DUMP"
exit 0
EOF
chmod +x "$TITIAN_ROOT/bin/clish"

# --- (a) save membuat startup-header 4 baris persis ---
if sh "$CKPT_SH" save t1 >"$MOCKROOT/save.out" 2>&1; then ok "save t1 rc=0"; else bad "save t1 rc!=0"; cat "$MOCKROOT/save.out"; fi
POINT="$STATE_ROOT/checkpoints/t1"
[ -f "$POINT/running-config" ] && ok "running-config tersimpan" || bad "running-config tidak ada"
cat > "$MOCKROOT/exp-header" <<'EOF'
!
! version core: 2.2.5
 ! last commit: Sat Nov 21 10:50:41 UTC 2026
!
EOF
if [ -f "$POINT/startup-header" ] && cmp -s "$POINT/startup-header" "$MOCKROOT/exp-header"; then
    ok "startup-header = 4 baris blok stempel persis"
else
    bad "startup-header tidak sama dengan blok stempel anchor"; cat "$POINT/startup-header" 2>/dev/null
fi
# running-config titik = dump tanpa stempel
tail -n +2 "$DUMP" > "$MOCKROOT/exp-running"
if cmp -s "$POINT/running-config" "$MOCKROOT/exp-running"; then ok "running-config titik = dump tanpa stempel"; else bad "running-config titik != dump"; diff "$MOCKROOT/exp-running" "$POINT/running-config" | head; fi

# --- (b) restore byte-identik di /etc + /cfg ---
# Rusak dulu kedua salinan (simulasi "ubah" sesudah checkpoint)
echo "GARBAGE-BARU" > "$STATE_ROOT/startup-config"
echo "GARBAGE-CFG" > "$CFG_DIR/startup-config"
FUNCS="$MOCKROOT/ckpt-funcs.sh"
sed -e '/^case "${1:-}" in$/,$d' -e 's|^\. "\$SBIN_DIR/titian-page\.sh"|. /dev/null # mock: pager dinonaktifkan|' "$CKPT_SH" > "$FUNCS"
titian_page_begin() { :; }
. "$FUNCS"
if restore_files "$POINT" 2>"$MOCKROOT/restore.err"; then ok "restore_files rc=0"; else bad "restore_files rc!=0"; cat "$MOCKROOT/restore.err"; fi
if cmp -s "$STATE_ROOT/startup-config" "$ANCHOR"; then ok "/etc startup-config BYTE-IDENTIK dengan pra-uji (diff kosong)"; else bad "/etc startup-config != pra-uji"; diff "$ANCHOR" "$STATE_ROOT/startup-config" | head; fi
if cmp -s "$CFG_DIR/startup-config" "$ANCHOR"; then ok "/cfg startup-config BYTE-IDENTIK dengan pra-uji"; else bad "/cfg startup-config != pra-uji"; diff "$ANCHOR" "$CFG_DIR/startup-config" | head; fi

# --- (c) titik LAMA (tanpa startup-header): perilaku lama ---
rm -f "$POINT/startup-header"
echo "GARBAGE-BARU" > "$STATE_ROOT/startup-config"
echo "GARBAGE-CFG-TETAP" > "$CFG_DIR/startup-config"
CFG_MD5_BEFORE=$(md5sum "$CFG_DIR/startup-config" 2>/dev/null | awk '{print $1}')
if restore_files "$POINT" 2>/dev/null; then ok "restore_files titik lama rc=0"; else bad "restore_files titik lama rc!=0"; fi
tail -n +2 "$DUMP" > "$MOCKROOT/exp-running"
if cmp -s "$STATE_ROOT/startup-config" "$MOCKROOT/exp-running"; then ok "titik lama: /etc = dump polos (3 baris hilang, perilaku lama)"; else bad "titik lama: /etc bukan dump polos"; fi
CFG_MD5_AFTER=$(md5sum "$CFG_DIR/startup-config" 2>/dev/null | awk '{print $1}')
if [ "$CFG_MD5_BEFORE" = "$CFG_MD5_AFTER" ]; then ok "titik lama: /cfg TIDAK disentuh"; else bad "titik lama: /cfg ikut berubah"; fi

# --- (d) startup-config tanpa stempel: tidak ada startup-header ---
cat > "$STATE_ROOT/startup-config" <<'EOF'
system help-language english
!
service ssh
 allow-root
!
end
EOF
cat > "$MOCKROOT/dump-nostamp.txt" <<'EOF'
# show running-config
system help-language english
!
service ssh
 allow-root
!
end
EOF
export MOCK_DUMP="$MOCKROOT/dump-nostamp.txt"
if sh "$CKPT_SH" save t2 >"$MOCKROOT/save2.out" 2>&1; then ok "save t2 (tanpa stempel) rc=0"; else bad "save t2 rc!=0"; cat "$MOCKROOT/save2.out"; fi
if [ ! -e "$STATE_ROOT/checkpoints/t2/startup-header" ]; then ok "tanpa stempel: tidak ada startup-header (fallback)"; else bad "tanpa stempel: startup-header malah ada"; fi

# --- (e) snapshot-last-save juga membuat startup-header ---
cp -f "$ANCHOR" "$STATE_ROOT/startup-config"
export MOCK_DUMP="$DUMP"
if sh "$CKPT_SH" snapshot-last-save >"$MOCKROOT/snap.out" 2>&1; then ok "snapshot-last-save rc=0"; else bad "snapshot-last-save rc!=0"; cat "$MOCKROOT/snap.out"; fi
if [ -f "$STATE_ROOT/checkpoints/.last-save/startup-header" ] && cmp -s "$STATE_ROOT/checkpoints/.last-save/startup-header" "$MOCKROOT/exp-header"; then
    ok ".last-save/startup-header = blok stempel persis"
else
    bad ".last-save/startup-header tidak ada / tidak sama"
fi

echo "HASIL: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
