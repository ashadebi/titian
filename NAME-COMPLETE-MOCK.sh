#!/bin/sh
# NAME-COMPLETE-MOCK.sh — uji mock: nama checkpoint / filter / community /
# protocol / neighbor TERLIHAT + AUTO-COMPLETE di klish Titian/BSDRP.
# Self-contained: semua state di /tmp/namecomp-mock-state; tidak bergantung
# baseline eksternal. Konvensi sama seperti FILT-AUTOCOMPLETE-MOCK.sh
# (expect0/expect33/expect33msg/expect_file/expect_count/expect_md5).
#
# Pola yang dipakai (sama seperti filter-name, FILT-AUTOCOMPLETE-REPORT):
# VAR dinamis di tree/startup.xml (ACTION = helper script) + atribut
# `completion="${VAR}"` di PARAM. Nilai atribut di-expand klish lalu
# dipecah spasi/baris jadi kandidat TAB (dan daftar `?`).
# Nama tak dikenal ditolak LOUD rc=33 dengan menyebutkan yang tersedia.
#
# Cakupan batch ini:
#   checkpoint: rollback + checkpoint delete (BARU)
#   filter: completion SUDAH ADA (8 PARAM) — hanya verifikasi XML (tanpa duplikasi)
#   community list: community list delete (BARU)
#   community value: community export/import delete (BARU, reverse-map ke bentuk CLI)
#   protocol-name: protocol-name (BARU)
#   neighbor: neighbor + no neighbor (BARU)
#   interface: completion SUDAH ADA (Get_if_*) — tidak diuji ulang di sini
# Sengaja TIDAK dicakup (nama baru yang diciptakan user, bukan merujuk yang ada):
#   checkpoint save, community list add (nama), community export/import add
#   (nilai), filter (definisi baru). Alasan: completion untuk nama BARU
#   tidak bermakna — user mengetik nama yang belum ada.
#
# HASIL (diisi sesudah jalan): lihat ekor log.
S="$HOME/workspace/titian-bsdRP-xml/sbin"
ST=/tmp/namecomp-mock-state
CKPT="$S/titian-checkpoint.sh"
COMM="$S/titian-comm.sh"
XML="$HOME/workspace/titian-bsdRP-xml/tree"
mkdir -p "$ST" 2>/dev/null
fail=0; PASSN=0; FAILN=0
ok() { echo "PASS: $*"; PASSN=$((PASSN + 1)); }
bad() { echo "FAIL: $*"; fail=1; FAILN=$((FAILN + 1)); }
expect0() { # expect0 <label> <cmd...>
    _l="$1"; shift
    if "$@" >/tmp/namecomp-out 2>&1; then ok "$_l (rc=0)"
    else bad "$_l (rc=$?, harus 0)"; cat /tmp/namecomp-out; fi
}
expect33() { # expect33 <label> <cmd...>
    _l="$1"; shift
    if "$@" >/tmp/namecomp-out 2>&1; then bad "$_l (rc=0, harus 33)"; cat /tmp/namecomp-out
    else _rc=$?; if [ "$_rc" = 33 ]; then ok "$_l (rc=33: $(head -1 /tmp/namecomp-out))"
        else bad "$_l (rc=$_rc, harus 33)"; cat /tmp/namecomp-out; fi; fi
}
expect33msg() { # expect33msg <label> <substring> <cmd...>
    _l="$1"; _m="$2"; shift 2
    if "$@" >/tmp/namecomp-out 2>&1; then bad "$_l (rc=0, harus 33)"; cat /tmp/namecomp-out
    else _rc=$?; if [ "$_rc" = 33 ] && grep -qF -- "$_m" /tmp/namecomp-out; then ok "$_l (rc=33 + pesan: $_m)"
        else bad "$_l (rc=$_rc / pesan tidak memuat: $_m)"; cat /tmp/namecomp-out; fi; fi
}
expect_file() { # expect_file <label> <file> <pola-tetap>
    _l="$1"; _f="$2"; _p="$3"
    if grep -qF -- "$_p" "$_f" 2>/dev/null; then ok "$_l (memuat: $_p)"
    else bad "$_l (TIDAK memuat: $_p)"; fi
}
expect_not_file() { # expect_not_file <label> <file> <pola-tetap>
    _l="$1"; _f="$2"; _p="$3"
    if grep -qF -- "$_p" "$_f" 2>/dev/null; then bad "$_l (masih memuat: $_p)"
    else ok "$_l (tidak memuat: $_p)"; fi
}
expect_count() { # expect_count <label> <file> <pola> <jumlah>
    _l="$1"; _f="$2"; _p="$3"; _n="$4"
    _c=$(grep -cF -- "$_p" "$_f" 2>/dev/null || true)
    [ -z "$_c" ] && _c=0
    if [ "$_c" = "$_n" ]; then ok "$_l (jumlah=$_c)"
    else bad "$_l (jumlah=$_c, harus $_n)"; fi
}
expect_md5() { # expect_md5 <label> <file> <md5>
    _l="$1"; _f="$2"; _m="$3"
    _g=$(md5sum "$_f" 2>/dev/null | awk '{print $1}')
    if [ "$_g" = "$_m" ]; then ok "$_l (md5=$_g)"
    else bad "$_l (md5=$_g, harus $_m)"; fi
}
setup_state() { # setup_state — state contoh: 2 checkpoint (+ .last-save),
    # 3 community list, export+import community, 2 neighbor + 2 protoname
    rm -rf "$ST"; mkdir -p "$ST/checkpoints/2026-11-20" "$ST/checkpoints/2026-11-19" "$ST/checkpoints/.last-save" "$ST/bird.d"
    cat > "$ST/bird.d/filter.conf" <<'EOF'
define CUST_A = (64512, 300);
define CUST_B = (64512, 301);
define NOEXP = (65535, 65281);
filter bgp_export_attr {
    if source = RTS_STATIC then {
        bgp_community.add((64512, 300));
        bgp_community.add((65535, 65281));
        bgp_ext_community.add((rt, 64512, 400));
        bgp_large_community.add((64512, 1, 500));
        accept;
    }
}
filter bgp_import_comm {
    if (64512, 300) ~ bgp_community then reject;
    if (64512, 301) ~ bgp_community then bgp_local_pref = 200;
    if (rt, 64512, 400) ~ bgp_ext_community then reject;
}
EOF
    cat > "$ST/bgp.conf" <<'EOF'
neighbor 10.99.40.2 import all
neighbor 10.99.40.2 export all
neighbor 10.99.40.2 protocol-name bgp_AS1194
neighbor 10.99.40.3 import filter F-RB3011-IN
neighbor 10.99.40.3 protocol-name bgp_RB3011
filter F-RB3011-IN accept;
filter F-OTHER reject;
EOF
}

# ================= A. kunci file berubah =================
echo "===== A. kunci-file ====="
expect_md5 "A-checkpoint-names.sh" "$S/titian-checkpoint-names.sh" "b500fa320bb9b70f013c6704540f01d5"
expect_md5 "A-comm-lists.sh" "$S/titian-comm-lists.sh" "788e3ff816d6853c088745606748e1cd"
expect_md5 "A-comm-values.sh" "$S/titian-comm-values.sh" "fa70d4c1e62cfed369051b6574085f16"
expect_md5 "A-bgp-protocols.sh" "$S/titian-bgp-protocols.sh" "1075fd2415be32510ac380993fd95af6"
expect_md5 "A-bgp-neighbors.sh" "$S/titian-bgp-neighbors.sh" "6f5803e0a10c3fd046c46957801a2a32"
expect_md5 "A-titian-checkpoint.sh" "$S/titian-checkpoint.sh" "65b9c424c53d5f90ce0a1162d9cbe6fd"
expect_md5 "A-titian-comm.sh" "$S/titian-comm.sh" "d34e16c69e3b3d1ab4cdafdc9810daf5"
expect_md5 "A-startup.xml" "$XML/startup.xml" "116fd821fcda63ce4263ea36e5bf36d8"
expect_md5 "A-en-checkpoint.xml" "$XML/en-checkpoint.xml" "00ccba8855daf40d267b0fada9f5f408"
expect_md5 "A-bird.xml" "$XML/bird.xml" "e91a66c5b4760533f70c43d61ff7183c"
expect_md5 "A-conf-bgp.xml" "$XML/conf-bgp.xml" "6148000beb2c8fe2272659ab9614ff56"

# ================= B. helper scripts =================
echo "===== B. helper ====="
setup_state
_out=$(TITIAN_STATE_ROOT="$ST" sh "$S/titian-checkpoint-names.sh" 2>/dev/null)
if [ "$_out" = "2026-11-19
2026-11-20" ]; then ok "B-ckpt-dua-nama (urut, .last-save disembunyikan)"
else bad "B-ckpt-dua-nama (keluar: [$_out])"; fi
_out=$(TITIAN_STATE_ROOT="$ST" sh "$S/titian-comm-lists.sh" 2>/dev/null)
if [ "$_out" = "CUST_A
CUST_B
NOEXP" ]; then ok "B-comm-lists-tiga-nama (urut)"
else bad "B-comm-lists-tiga-nama (keluar: [$_out])"; fi
_out=$(TITIAN_STATE_ROOT="$ST" sh "$S/titian-comm-values.sh" 2>/dev/null)
if [ "$_out" = "64512:300
64512:301
large:64512:1:500
no-export
rt:64512:400" ]; then ok "B-comm-values-lima (reverse-map std+wellknown+rt+large, dedup)"
else bad "B-comm-values-lima (keluar: [$_out])"; fi
_out=$(TITIAN_STATE_ROOT="$ST" sh "$S/titian-bgp-protocols.sh" 2>/dev/null)
if [ "$_out" = "bgp_AS1194
bgp_RB3011" ]; then ok "B-protonames-dua (urut)"
else bad "B-protonames-dua (keluar: [$_out])"; fi
_out=$(TITIAN_STATE_ROOT="$ST" sh "$S/titian-bgp-neighbors.sh" 2>/dev/null)
if [ "$_out" = "10.99.40.2
10.99.40.3" ]; then ok "B-neighbors-dua-ip (urut)"
else bad "B-neighbors-dua-ip (keluar: [$_out])"; fi
rm -rf "$ST"; mkdir -p "$ST"
for _h in titian-checkpoint-names.sh titian-comm-lists.sh titian-comm-values.sh titian-bgp-protocols.sh titian-bgp-neighbors.sh; do
    _out=$(TITIAN_STATE_ROOT="$ST" sh "$S/$_h" 2>/dev/null; echo "rc=$?")
    if [ "$_out" = "rc=0" ]; then ok "B-helper-kosong-$_h (state kosong, rc=0)"
    else bad "B-helper-kosong-$_h (keluar: [$_out])"; fi
done
rm -rf "$ST"
for _h in titian-checkpoint-names.sh titian-comm-lists.sh titian-comm-values.sh titian-bgp-protocols.sh titian-bgp-neighbors.sh; do
    _out=$(TITIAN_STATE_ROOT="$ST" sh "$S/$_h" 2>/dev/null; echo "rc=$?")
    if [ "$_out" = "rc=0" ]; then ok "B-helper-hilang-$_h (state tidak ada, rc=0)"
    else bad "B-helper-hilang-$_h (keluar: [$_out])"; fi
done

# ================= C. checkpoint LOUD rejection =================
echo "===== C. checkpoint-loud ====="
setup_state
expect33msg "C-rollback-tidak-ada" "checkpoint tidak ada: CKPT-TIDAK-ADA" env TITIAN_STATE_ROOT="$ST" sh "$CKPT" rollback CKPT-TIDAK-ADA
expect33msg "C-rollback-sebut-tersedia" "yang tersedia: 2026-11-19 2026-11-20" env TITIAN_STATE_ROOT="$ST" sh "$CKPT" rollback CKPT-TIDAK-ADA
expect33msg "C-delete-tidak-ada" "checkpoint tidak ada: CKPT-TIDAK-ADA" env TITIAN_STATE_ROOT="$ST" sh "$CKPT" delete CKPT-TIDAK-ADA
expect33msg "C-delete-sebut-tersedia" "yang tersedia: 2026-11-19 2026-11-20" env TITIAN_STATE_ROOT="$ST" sh "$CKPT" delete CKPT-TIDAK-ADA
expect0 "C-delete-ada" env TITIAN_STATE_ROOT="$ST" sh "$CKPT" delete 2026-11-19
if [ ! -d "$ST/checkpoints/2026-11-19" ] && [ -d "$ST/checkpoints/2026-11-20" ]; then ok "C-delete-ada-hapus-dir (2026-11-19 hilang, 2026-11-20 utuh)"
else bad "C-delete-ada-hapus-dir (dir 2026-11-19 masih ada / 2026-11-20 hilang)"; fi
# rollback ke nama yang ada DIUJI di seksi G (mesin ter-wipe, tanpa konfd).
echo "INFO: rollback <nama-ada> diuji di seksi G (bukan di sini)"

# ================= D. community LOUD rejection =================
echo "===== D. comm-loud ====="
setup_state
expect33msg "D-listdel-tidak-ada" "community list tidak ada: LIST_TIDAK_ADA" env TITIAN_STATE_ROOT="$ST" sh "$COMM" list-del LIST_TIDAK_ADA
expect33msg "D-listdel-sebut-tersedia" "yang tersedia: CUST_A CUST_B NOEXP" env TITIAN_STATE_ROOT="$ST" sh "$COMM" list-del LIST_TIDAK_ADA
expect33msg "D-exportdel-tidak-ada" "community tidak ada di export: 64512:999" env TITIAN_STATE_ROOT="$ST" sh "$COMM" export-del 64512:999
expect33msg "D-exportdel-sebut-tersedia" "yang tersedia:" env TITIAN_STATE_ROOT="$ST" sh "$COMM" export-del 64512:999
expect33msg "D-importdel-tidak-ada" "tidak ada match import untuk 64512:999" env TITIAN_STATE_ROOT="$ST" sh "$COMM" import-del 64512:999
expect33msg "D-importdel-sebut-tersedia" "yang tersedia:" env TITIAN_STATE_ROOT="$ST" sh "$COMM" import-del 64512:999
# delete yang ADA tidak diuji di mock (memanggil apply -> bird check/generate, butuh bird live)
echo "INFO: list-del/export-del/import-del <nama-ada> tidak diuji di mock (apply butuh bird live)"

# ================= E. XML completion + verify.py =================
echo "===== E. xml-verify ====="
expect_count "E-completion-ckpt" "$XML/en-checkpoint.xml" 'completion="${Get_checkpoints}"' 2
expect_count "E-completion-commlists" "$XML/bird.xml" 'completion="${Get_comm_lists}"' 1
expect_count "E-completion-commvalues" "$XML/bird.xml" 'completion="${Get_comm_values}"' 2
expect_count "E-completion-protonames" "$XML/conf-bgp.xml" 'completion="${Get_bgp_protonames}"' 1
expect_count "E-completion-neighbors" "$XML/conf-bgp.xml" 'completion="${Get_bgp_neighbors}"' 2
expect_count "E-completion-filter-tetap" "$XML/conf-bgp.xml" 'completion="${Get_bgp_filters}"' 6
expect_file "E-var-ckpt" "$XML/startup.xml" 'name="Get_checkpoints"'
expect_file "E-var-commlists" "$XML/startup.xml" 'name="Get_comm_lists"'
expect_file "E-var-commvalues" "$XML/startup.xml" 'name="Get_comm_values"'
expect_file "E-var-protonames" "$XML/startup.xml" 'name="Get_bgp_protonames"'
expect_file "E-var-neighbors" "$XML/startup.xml" 'name="Get_bgp_neighbors"'
expect_file "E-var-act-ckpt" "$XML/startup.xml" 'titian-checkpoint-names.sh'
expect_file "E-var-act-commlists" "$XML/startup.xml" 'titian-comm-lists.sh'
expect_file "E-var-act-commvalues" "$XML/startup.xml" 'titian-comm-values.sh'
expect_file "E-var-act-protonames" "$XML/startup.xml" 'titian-bgp-protocols.sh'
expect_file "E-var-act-neighbors" "$XML/startup.xml" 'titian-bgp-neighbors.sh'
# negatif: nama BARU yang diciptakan user TIDAK diberi completion
if grep -A3 'COMMAND name="checkpoint save"' "$XML/en-checkpoint.xml" | grep -q 'completion='; then bad "E-negatif-ckpt-save (checkpoint save TIDAK boleh completion)"
else ok "E-negatif-ckpt-save (checkpoint save tanpa completion — nama baru)"; fi
if grep -A3 'COMMAND name="community list add"' "$XML/bird.xml" | grep -q 'completion='; then bad "E-negatif-list-add (community list add TIDAK boleh completion)"
else ok "E-negatif-list-add (community list add tanpa completion — nama baru)"; fi
_vout=$(cd "$HOME/workspace/titian-bsdRP-xml" && python3 verify.py 2>&1)
echo "$_vout" | grep -q "VERIFIKASI OK: NOL error" && ok "E-verify-nol-error" || bad "E-verify-nol-error: $_vout"
echo "$_vout" | grep -q "COMMAND unik (view+nama): 2156" && ok "E-command-2156-tetap" || bad "E-command-2156-tetap: $(echo "$_vout" | grep COMMAND)"

# ================= F. regresi mock batch lama =================
echo "===== F. regresi ====="
for _m in FILT-AUTOCOMPLETE-MOCK.sh FACTORY-RESET-MOCK.sh; do
    _o=$(cd "$HOME/workspace/titian-bsdRP-xml" && timeout 600 sh "$_m" 2>&1 | tail -1)
    case "$_o" in *"FAIL=0"*|*"0 FAIL"*) ok "F-regresi-$_m ($_o)" ;; *) bad "F-regresi-$_m ($_o)" ;; esac
done

# ================= G. rollback tanpa dump (mesin ter-wipe, 20 Nov 2026) =================
# Akar error "konfd tidak terjangkau" saat rollback: cmd_rollback memanggil
# dump_running DULU (untuk prune_all). Dari DALAM sesi klish, batch clish
# tidak bisa terhubung ke konfd (dipegang sesi luar) DAN tidak ada
# startup-config untuk fallback (mesin ter-wipe pasca-confirm) -> dump
# gagal -> rollback abort SEBELUM memulihkan apa pun. Fix: bila dump
# gagal, prune DILEWATI (warning lantang) dan rollback TETAP JALAN
# (restore file + restart). Uji JALUR NYATA (helper asli): TITIAN_ROOT
# palsu tanpa clish (batch clish gagal) + TANPA startup-config (ter-wipe)
# + stub service/bird/birdc.
echo "===== G. rollback-tanpa-dump ====="
_GROOT=/tmp/namecomp-rb-root; _GBIN=/tmp/namecomp-rb-bin
rm -rf "$_GROOT" "$_GBIN"; mkdir -p "$_GROOT/bin" "$_GROOT/sbin" "$_GBIN"
cat > "$_GBIN/service" <<'EOF'
#!/bin/sh
# stub service titian restart: sukses + buat socket konfd (nyata, AF_UNIX)
rm -f /tmp/konfd.socket
python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('/tmp/konfd.socket')" 2>/dev/null || true
exit 0
EOF
cat > "$_GBIN/bird" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$_GBIN/birdc" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$_GBIN/service" "$_GBIN/bird" "$_GBIN/birdc"
# state ter-wipe: checkpoint 2026-11-20 utuh, TANPA startup-config
setup_state
rm -f "$ST/startup-config"
printf 'interface bridge bridge0\n  member ge1\nrouter bird\n  bgp bgp_RB3011\nend\n' > "$ST/checkpoints/2026-11-20/running-config"
printf 'name=2026-11-20\ncreated_wib=2026-11-20 17:39:37 WIB\nsource=running\n' > "$ST/checkpoints/2026-11-20/meta"
printf '#-GLOBAL-#\nrouter id 10.99.40.1;\n' > "$ST/checkpoints/2026-11-20/bird.conf"
_BIRDLIVE=/tmp/namecomp-rb-bird.conf; rm -f "$_BIRDLIVE"
rm -f /tmp/konfd.socket
PATH="$_GBIN:$PATH" TITIAN_ROOT="$_GROOT" TITIAN_OS="FreeBSD" TITIAN_STATE_ROOT="$ST" TITIAN_BIRD_LIVE_CONF="$_BIRDLIVE" sh "$CKPT" rollback 2026-11-20 > /tmp/namecomp-rb.out 2>&1; _rc=$?
[ "$_rc" = "0" ] && ok "G-rollback-wiped-rc0 (rc=0, bukan 33 konfd)" || { bad "G-rollback-wiped-rc0 (rc=$_rc, harus 0)"; cat /tmp/namecomp-rb.out; }
grep -q "prune objek live DILEWATI" /tmp/namecomp-rb.out && ok "G-rollback-warning-prune (warning lantang tampil)" || bad "G-rollback-warning-prune (warning TIDAK tampil)"
[ -f "$ST/startup-config" ] && cmp -s "$ST/startup-config" "$ST/checkpoints/2026-11-20/running-config" && ok "G-rollback-startup-dipulihkan (startup-config == running-config titik)" || bad "G-rollback-startup-dipulihkan (startup-config TIDAK sama dengan titik)"
[ -f "$_BIRDLIVE" ] && grep -q "#-GLOBAL-#" "$_BIRDLIVE" && ok "G-rollback-bird-dipulihkan (bird.conf live == titik)" || bad "G-rollback-bird-dipulihkan (bird.conf live TIDAK dipulihkan)"
grep -q "^last_rollback_wib=" "$ST/checkpoints/2026-11-20/meta" && ok "G-rollback-meta-dicatat (last_rollback_wib di meta titik)" || bad "G-rollback-meta-dicatat (last_rollback_wib TIDAK ada di meta)"
# kontrol negatif: checkpoint tanpa running-config TETAP ditolak rc 33
mkdir -p "$ST/checkpoints/rusak-1"
PATH="$_GBIN:$PATH" TITIAN_ROOT="$_GROOT" TITIAN_OS="FreeBSD" TITIAN_STATE_ROOT="$ST" TITIAN_BIRD_LIVE_CONF="$_BIRDLIVE" sh "$CKPT" rollback rusak-1 > /tmp/namecomp-rb2.out 2>&1; _rc=$?
[ "$_rc" = "33" ] && grep -q "checkpoint rusak" /tmp/namecomp-rb2.out && ok "G-rollback-rusak-tetap-33 (guard checkpoint rusak utuh)" || bad "G-rollback-rusak-tetap-33 (rc=$_rc, harus 33 + pesan checkpoint rusak)"
rm -f /tmp/konfd.socket "$_BIRDLIVE"; rm -rf "$_GROOT" "$_GBIN"

# ================= H. rollback memulihkan intent + bird.conf lengkap (lapis 2, 20 Nov 2026) =================
# Akar lapis 2: running-config hasil dump klish TIDAK memuat
# `import filter` / `graceful-restart-time` / `validate off` neighbor
# 10.99.40.2 — replay membangun ulang intent TANPA atribut itu
# (neighbor-add menulis default `import all`) lalu generate menulis
# bird.conf yang kehilangan setting (BGP 8/12, ping 100% loss).
# Fix: checkpoint menyimpan file intent top-level (intent/);
# rollback memulihkannya SEBELUM restart, sehingga replay (per-key,
# additive) mempertahankannya dan generate menulis bird.conf lengkap.
# Uji JALUR NYATA (helper + generate ASLI): TITIAN_ROOT palsu tanpa
# clish + state ter-wipe + stub service/bird/birdc; stub service
# mensimulasikan boot (replay remote-as ASLI + generate BGP ASLI +
# render bird.conf ASLI), lalu buat socket konfd.
echo "===== H. rollback-intent-lengkap ====="
_HROOT=/tmp/namecomp-h-root; _HBIN=/tmp/namecomp-h-bin; _HCFG=/tmp/namecomp-h-cfg; _HCFG2=/tmp/namecomp-h-cfg2
rm -rf "$_HROOT" "$_HBIN" "$_HCFG" "$_HCFG2"; mkdir -p "$_HROOT/bin" "$_HROOT/sbin" "$_HBIN" "$_HCFG" "$_HCFG2"
cat > "$_HBIN/service" <<'EOF'
#!/bin/sh
# stub service titian restart (mock H): simulasi boot — replay +
# generate memakai skrip ASLI (bukan tiruan logika).
# Env dari mock: H_STATE_ROOT, H_SBIN, H_BIRDLIVE.
ST="${H_STATE_ROOT:-/tmp/namecomp-mock-state}"
SB="$H_SBIN"
BL="$H_BIRDLIVE"
# 1. replay `remote-as` neighbor 10.99.40.2 (neighbor-add ASLI):
#    menulis default `import all` HANYA bila kunci import belum ada.
TITIAN_STATE_ROOT="$ST" sh "$SB/titian-bgp.sh" neighbor-add 10.99.40.2 65001 >/dev/null 2>&1
# 2. generate BGP ASLI (intent -> bird.d/bgp.conf -> bird.conf).
TITIAN_STATE_ROOT="$ST" TITIAN_BIRD_LIVE_CONF="$BL" sh "$SB/titian-bgp.sh" generate >/dev/null 2>&1
# 3. socket konfd (nyata, AF_UNIX) agar service_restart lolos.
rm -f /tmp/konfd.socket
python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('/tmp/konfd.socket')" 2>/dev/null || true
exit 0
EOF
cat > "$_HBIN/bird" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$_HBIN/birdc" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$_HBIN/service" "$_HBIN/bird" "$_HBIN/birdc"
# state ter-wipe + checkpoint 2026-11-20 DENGAN intent/ (format baru)
setup_state
rm -f "$ST/startup-config" "$ST/bgp.conf" "$ST/bird-global.conf"
rm -rf "$ST/bird.d"; mkdir -p "$ST/bird.d"
# running-config LOSSY (tanpa import filter / graceful-restart-time /
# validate off utk 40.2 — cermin dump klish; hanya 3 baris stempel
# yang hilang vs anchor = kosmetik, bukan diuji di sini)
printf 'interface bridge bridge0\n  member ge1\nrouter bird\n  bgp bgp_RB3011\nend\n' > "$ST/checkpoints/2026-11-20/running-config"
printf 'name=2026-11-20\ncreated_wib=2026-11-20 17:39:37 WIB\nsource=running\n' > "$ST/checkpoints/2026-11-20/meta"
printf '#-GLOBAL-#\nrouter id 10.99.40.1;\n#-BGP-#\n#-ENDBGP-#\n' > "$ST/checkpoints/2026-11-20/bird.conf"
mkdir -p "$ST/checkpoints/2026-11-20/intent" "$ST/checkpoints/2026-11-20/bird.d"
cat > "$ST/checkpoints/2026-11-20/intent/bgp.conf" <<'EOF'
# bgp.conf - generated by klish, do not edit by hand
neighbor 10.99.40.2 community 65000:100
neighbor 10.99.40.2 description RB3011-TEST
neighbor 10.99.40.2 export all
neighbor 10.99.40.2 flow4-export all
neighbor 10.99.40.2 flow4-import all
neighbor 10.99.40.2 flow4-table f4tab
neighbor 10.99.40.2 flow4-validate off
neighbor 10.99.40.2 flow6-export all
neighbor 10.99.40.2 flow6-import all
neighbor 10.99.40.2 flow6-table f6tab
neighbor 10.99.40.2 flow6-validate off
neighbor 10.99.40.2 graceful-restart on
neighbor 10.99.40.2 graceful-restart-time 120
neighbor 10.99.40.2 hold-time 30
neighbor 10.99.40.2 import filter F-RB3011-IN
neighbor 10.99.40.2 keepalive-time 10
neighbor 10.99.40.2 local-pref 100
neighbor 10.99.40.2 med 50
neighbor 10.99.40.2 prepend 2
neighbor 10.99.40.2 protocol-name bgp_RB3011
neighbor 10.99.40.2 remote-as 65001
neighbor 10.99.45.1 description MT-P01
neighbor 10.99.45.1 export all
neighbor 10.99.45.1 import filter F-RB3011-IN
neighbor 10.99.45.1 multihop
neighbor 10.99.45.1 protocol-name bgp_MT_P01
neighbor 10.99.45.1 remote-as 65001
neighbor 10.99.45.1 source-address 10.99.42.1
filter F-RB3011-IN accept 10.0.0.0/8
filter F-RB3011-IN reject 192.168.0.0/16
local-as 65000
router-id 10.99.40.1
EOF
cat > "$ST/checkpoints/2026-11-20/intent/bird-global.conf" <<'EOF'
# bird-global.conf - generated by klish, do not edit by hand
table roa4 r4
table roa6 r6
table flow4 f4tab
table flow6 f6tab
table mpls mtab
mpls domain d1
EOF
# bird.conf live: TITIAN_BIRD_LIVE_CONF = $ST/bird.conf agar restore
# + render konsisten (sama seperti mesin: conf_path == live_conf_path).
_HBIRDLIVE="$ST/bird.conf"; rm -f "$_HBIRDLIVE"
printf '#-GLOBAL-#\nrouter id 10.99.40.1;\n#-BGP-#\n#-ENDBGP-#\n' > "$_HBIRDLIVE"
rm -f /tmp/konfd.socket
H_STATE_ROOT="$ST" H_SBIN="$S" H_BIRDLIVE="$_HBIRDLIVE" PATH="$_HBIN:$PATH" TITIAN_ROOT="$_HROOT" TITIAN_OS="FreeBSD" TITIAN_STATE_ROOT="$ST" TITIAN_CFG_DIR="$_HCFG" TITIAN_BIRD_LIVE_CONF="$_HBIRDLIVE" sh "$CKPT" rollback 2026-11-20 > /tmp/namecomp-h.out 2>&1; _rc=$?
[ "$_rc" = "0" ] && ok "H-rollback-intent-rc0 (rc=0)" || { bad "H-rollback-intent-rc0 (rc=$_rc, harus 0)"; cat /tmp/namecomp-h.out; }
# intent dipulihkan lengkap (bukan import all)
expect_file "H-intent-import-filter" "$ST/bgp.conf" "neighbor 10.99.40.2 import filter F-RB3011-IN"
expect_not_file "H-intent-tanpa-import-all" "$ST/bgp.conf" "neighbor 10.99.40.2 import all"
expect_file "H-intent-graceful-time" "$ST/bgp.conf" "neighbor 10.99.40.2 graceful-restart-time 120"
expect_file "H-intent-validate-off" "$ST/bgp.conf" "neighbor 10.99.40.2 flow4-validate off"
expect_file "H-intent-validate-off6" "$ST/bgp.conf" "neighbor 10.99.40.2 flow6-validate off"
# bird.conf hasil regenerasi memuat ketiga setting
# (flow4/flow6 LEGIT `import all;` — hanya ipv4 yang diuji via filter)
expect_count "H-bird-import-filter-2x" "$_HBIRDLIVE" "import filter F_RB3011_IN;" 2
expect_file "H-bird-graceful-time" "$_HBIRDLIVE" "graceful restart time 120;"
expect_count "H-bird-validate-off-2x" "$_HBIRDLIVE" "validate off;" 2
# intent juga dipersistenkan ke /cfg (agar bertahan reboot)
expect_file "H-cfg-intent-dipulihkan" "$_HCFG/bgp.conf" "neighbor 10.99.40.2 import filter F-RB3011-IN"
# kontrol negatif: checkpoint LAMA tanpa intent/ tetap rollback rc=0
# (mundur-kompatibel) + warning fallback tampil. Pakai cfg KOSONG
# (cfg2) agar fallback tidak menemukan intent persisten.
mkdir -p "$ST/checkpoints/lama-1"
printf 'interface bridge bridge0\n  member ge1\nend\n' > "$ST/checkpoints/lama-1/running-config"
printf 'name=lama-1\ncreated_wib=2026-11-19 10:00:00 WIB\nsource=running\n' > "$ST/checkpoints/lama-1/meta"
printf '#-GLOBAL-#\nrouter id 10.99.40.1;\n#-BGP-#\n#-ENDBGP-#\n' > "$ST/checkpoints/lama-1/bird.conf"
rm -f "$ST/bgp.conf" "$ST/startup-config"
rm -f /tmp/konfd.socket
H_STATE_ROOT="$ST" H_SBIN="$S" H_BIRDLIVE="$_HBIRDLIVE" PATH="$_HBIN:$PATH" TITIAN_ROOT="$_HROOT" TITIAN_OS="FreeBSD" TITIAN_STATE_ROOT="$ST" TITIAN_CFG_DIR="$_HCFG2" TITIAN_BIRD_LIVE_CONF="$_HBIRDLIVE" sh "$CKPT" rollback lama-1 > /tmp/namecomp-h2.out 2>&1; _rc=$?
[ "$_rc" = "0" ] && ok "H-rollback-lama-rc0 (checkpoint lama tetap rollback, rc=0)" || { bad "H-rollback-lama-rc0 (rc=$_rc, harus 0)"; cat /tmp/namecomp-h2.out; }
grep -q "tidak menyimpan intent" /tmp/namecomp-h2.out && ok "H-rollback-lama-warning (warning fallback intent tampil)" || bad "H-rollback-lama-warning (warning fallback TIDAK tampil)"
rm -f /tmp/konfd.socket "$_HBIRDLIVE"; rm -rf "$_HROOT" "$_HBIN" "$_HCFG" "$_HCFG2"

# ================= RINGKASAN =================
echo "----------------------------------------"
echo "NAME-COMPLETE-MOCK: PASS=$PASSN FAIL=$FAILN"
[ "$fail" -eq 0 ] && echo "HASIL: SEMUA LOLOS" || echo "HASIL: ADA YANG GAGAL"
exit $fail
