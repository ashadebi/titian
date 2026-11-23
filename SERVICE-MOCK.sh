#!/bin/sh
# SERVICE-MOCK.sh — bukti staging sintaks service Item 12 (23 Nov 2026).
# Dua celah kecil yang ditemukan di inventarisasi (tree sudah lengkap
# vs panduan + backend — 0 perintah terdokumentasi yang hilang):
#   (a) view `service ssh`: `port` tidak punya bentuk `no` (tidak ada
#       cara CLI kembali ke port default 22) -> op baru
#       `titian-sys.sh ssh-port-del` + perintah `no port`;
#   (b) `show service status <nama>` memakai STRING bebas tanpa
#       completion -> helper baru `titian-service-names.sh` (VAR
#       Get_services di startup.xml) + completion pada PARAM.
# Membuktikan TANPA mesin test (semua di-stub):
#   (a) ssh-port-del menghapus baris Port + restart sshd;
#   (b) ssh-port-del tanpa baris Port: tidak ada perubahan, tidak restart;
#   (c) ssh-port-del dengan Port yang dikomentari saja: tidak berubah;
#   (d) service-names dari `service -l` gaya FreeBSD -> basename terurut;
#   (e) service-names fallback statis bila `service` gagal;
#   (f) ssh-restart tetap jalan sesudah refactor ke do_ssh_restart.
# POSIX sh. Keluar 0 bila semua PASS.
STAGE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SYS_SH="$STAGE/titian/sbin/titian-sys.sh"
NAMES_SH="$STAGE/titian/sbin/titian-service-names.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

MOCKROOT=$(mktemp -d /tmp/svc-mock.XXXXXX) || { echo "FAIL: mktemp"; exit 1; }
trap 'if [ "$FAIL" -gt 0 ]; then echo "MOCKROOT (dipertahankan untuk inspeksi): $MOCKROOT"; else rm -rf "$MOCKROOT"; fi' EXIT

FAKEBIN="$MOCKROOT/bin"
mkdir -p "$FAKEBIN"
export SVC_MOCK_LOG="$MOCKROOT/calls.log"
: > "$SVC_MOCK_LOG"
cat > "$FAKEBIN/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$SVC_MOCK_LOG"
exit 0
EOF
cat > "$FAKEBIN/service" <<'EOF'
#!/bin/sh
echo "service $*" >> "$SVC_MOCK_LOG"
# gaya FreeBSD `service -l`: satu path rc script per baris
if [ "$1" = "-l" ]; then
    printf '%s\n' /etc/rc.d/sshd /etc/rc.d/cron /usr/local/etc/rc.d/bird /usr/local/etc/rc.d/titian /usr/local/etc/rc.d/mpd5
    exit 0
fi
exit 0
EOF
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:/usr/bin:/bin"

# --- (a) ssh-port-del menghapus Port + restart ---
SSHD="$MOCKROOT/sshd_config"
cat > "$SSHD" <<'EOF'
#Port 22
Port 9393
PermitRootLogin yes
UseDNS no
EOF
export TITIAN_SSHD_CONFIG="$SSHD"
: > "$SVC_MOCK_LOG"
if sh "$SYS_SH" ssh-port-del >"$MOCKROOT/a.out" 2>&1; then ok "ssh-port-del rc=0"; else bad "ssh-port-del rc!=0"; cat "$MOCKROOT/a.out"; fi
if grep -q '^Port' "$SSHD"; then bad "baris Port masih ada sesudah ssh-port-del"; else ok "baris Port terhapus"; fi
grep -q '^PermitRootLogin yes' "$SSHD" && ok "baris lain utuh" || bad "baris lain ikut berubah"
grep -q "systemctl restart ssh" "$SVC_MOCK_LOG" && ok "sshd di-restart" || { bad "sshd tidak di-restart"; cat "$SVC_MOCK_LOG"; }
grep -q "reset to default (22)" "$MOCKROOT/a.out" && ok "pesan reset tampil" || bad "pesan reset hilang"

# --- (b) tanpa baris Port: no-op, tidak restart ---
cat > "$SSHD" <<'EOF'
PermitRootLogin yes
UseDNS no
EOF
: > "$SVC_MOCK_LOG"
if sh "$SYS_SH" ssh-port-del >"$MOCKROOT/b.out" 2>&1; then ok "ssh-port-del (tanpa Port) rc=0"; else bad "ssh-port-del (tanpa Port) rc!=0"; fi
if grep -q "restart" "$SVC_MOCK_LOG"; then bad "restart dipanggil padahal sudah default"; else ok "tidak ada restart (sudah default)"; fi
grep -q "already default" "$MOCKROOT/b.out" && ok "pesan already-default tampil" || bad "pesan already-default hilang"

# --- (c) Port yang dikomentari saja: tidak berubah, tidak restart ---
cat > "$SSHD" <<'EOF'
#Port 22
PermitRootLogin yes
EOF
: > "$SVC_MOCK_LOG"
if sh "$SYS_SH" ssh-port-del >"$MOCKROOT/c.out" 2>&1; then ok "ssh-port-del (Port komentar) rc=0"; else bad "ssh-port-del (Port komentar) rc!=0"; fi
grep -q '^#Port 22' "$SSHD" && ok "baris komentar #Port dibiarkan" || bad "baris komentar ikut berubah"
if grep -q "restart" "$SVC_MOCK_LOG"; then bad "restart dipanggil untuk Port komentar"; else ok "tidak ada restart (Port komentar)"; fi

# --- (d) service-names dari `service -l` ---
NAMES=$(sh "$NAMES_SH")
if [ "$NAMES" = "bird
cron
mpd5
sshd
titian" ]; then ok "service-names: basename terurut dari service -l"; else bad "service-names salah: [$NAMES]"; fi

# --- (e) fallback statis bila `service` gagal ---
mkdir -p "$MOCKROOT/bin2"
cat > "$MOCKROOT/bin2/service" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$MOCKROOT/bin2/service"
NAMES2=$(PATH="$MOCKROOT/bin2:/usr/bin:/bin" sh "$NAMES_SH")
echo "$NAMES2" | grep -qx "bird" && echo "$NAMES2" | grep -qx "sshd" && echo "$NAMES2" | grep -qx "titian" \
    && ok "service-names fallback statis (bird/sshd/titian)" || bad "fallback statis salah: [$NAMES2]"

# --- (f) ssh-restart tetap jalan sesudah refactor ---
: > "$SVC_MOCK_LOG"
if sh "$SYS_SH" ssh-restart >"$MOCKROOT/f.out" 2>&1; then ok "ssh-restart rc=0 (refactor aman)"; else bad "ssh-restart rc!=0 sesudah refactor"; cat "$MOCKROOT/f.out"; fi
grep -q "systemctl restart ssh" "$SVC_MOCK_LOG" && ok "ssh-restart memanggil systemctl restart" || bad "ssh-restart tidak memanggil restart"

echo "HASIL: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
