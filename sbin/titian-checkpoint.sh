#!/bin/sh
# TITIAN — checkpoint + rollback.
# Checkpoint = TITIK SIMPAN BERNAMA dari konfigurasi. User membuat
# beberapa titik, melihat daftarnya, lalu memilih mau balik ke titik
# yang mana. Bukan "undo satu langkah".
#
# Isi satu checkpoint (di /etc/titian/checkpoints/<nama>/):
#   running-config  — dump running-config saat titik dibuat, TANPA
#                     baris stempel (! version / ! last commit).
#                     Alasan: stempel adalah metadata save, bukan
#                     konfigurasi — replay startup-config TIDAK
#                     mempertahankannya (terbukti: dump sesudah
#                     restart tidak mengandung stempel, sementara
#                     state yang baru di-save mengandungnya). Bila
#                     stempel ikut disimpan, verifikasi diff sesudah
#                     rollback akan selalu gagal palsu pada baris
#                     stempel. Dengan strip ini, diff rollback
#                     benar-benar byte-persis.
#   bird.conf       — bird.conf live saat titik dibuat
#   bird.d/         — fragmen sumber generate (*.conf saja; *.cli-bak
#                     dan *.pkgsave TIDAK ikut — itu artefak backup)
#   intent/         — file intent top-level (/etc/titian/*.conf:
#                     bgp.conf, bfd.conf, static.conf, ... — daftar
#                     yang sama dengan titian-cfg.sh; frr.conf
#                     TIDAK ikut, dikelola vtysh). LAPIS 2 (20 Nov
#                     2026): WAJIB — running-config hasil dump klish
#                     TIDAK memuat semua atribut (import filter /
#                     graceful-restart-time / validate off neighbor
#                     10.99.40.2 hilang), sehingga replay membangun
#                     ulang intent TANPA atribut itu (neighbor-add
#                     menulis default `import all`). Intent adalah
#                     sumber kebenaran generate; tanpa memulihkannya,
#                     bird.conf hasil regenerasi kehilangan setting
#                     (BGP 8/12, ping 100% loss). Checkpoint lama
#                     (pra-perbaikan) tidak punya intent/ — rollback
#                     ke titik lama fallback ke /cfg/titian
#                     (best-effort, warning lantang).
#   netstate/       — seluruh isi netstate (addr/managed/tuning/
#                     tuning.prev/bond/vxlan) saat titik dibuat
#   sysctl.titian (+ .prev) — sysctl global yang dikelola Titian
#   startup-header  — blok stempel startup-config (perbaikan 23 Nov
#                     2026, temuan Part 9): dump running-config TIDAK
#                     memuat 3 baris header (`! version ...`,
#                     ` ! last commit: ...`, `!` pemisah sesudahnya),
#                     sehingga rollback lama selalu kehilangan ketiganya
#                     (startup-config 409 -> 406 baris). File ini
#                     menyimpan KEEMPAT baris blok stempel (`!` pembuka
#                     + 3 baris itu) byte-persis, diambil dari
#                     startup-config live saat titik dibuat — BUKAN
#                     direkonstruksi (tanggal last commit tidak boleh
#                     ditebak). Bila startup-config tidak ada / tanpa
#                     stempel, file tidak ada (rollback fallback ke
#                     perilaku lama + peringatan). Titik LAMA (dibuat
#                     sebelum perbaikan ini) tidak punya file ini.
#   meta            — nama + waktu dibuat (WIB) + waktu rollback terakhir
#
# Semantik rollback (BACA SEBELUM PAKAI — ditulis juga di help text):
#   rollback MENGEMBALIKAN running-config + bird.conf + bird.d +
#   netstate + sysctl ke isi titik, MENULIS JUGA startup-config
#   (jadi rollback BERSIFAT PERSISTEN, bertahan melewati reboot —
#   bukan sekadar live), lalu restart service titian (konfd baru +
#   replay + apply-all tuning + apply-bond + apply-vxlan, mengikuti
#   jalur boot yang sudah terbukti) + birdc configure untuk bird.conf.
#   Alasan persistensi: "balik ke titik" harus berarti kembali
#   sungguhan, bukan kembali sampai reboot berikutnya.
#   (23 Nov 2026) startup-config dipulihkan BYTE-IDENTIK dari titik
#   baru (blok stempel di startup-header + dump running-config) di
#   KEDUA lokasi (/etc/titian + /cfg/titian); titik lama tanpa
#   startup-header tetap memakai perilaku lama (kehilangan 3 baris
#   header, /cfg tidak dipulihkan) + peringatan.
#   Sebelum restart, rollback membersihkan (prune) objek live yang
#   tidak ada di titik: interface buatan Titian yang mengendap,
#   alamat ekstra, kunci tuning ekstra, sysctl ekstra, dan route
#   statik ekstra — karena replay hanya MENAMBAH/MENGGANTI, tidak
#   menghapus. Prune bersifat best-effort per item (gagal satu item =
#   peringatan, rollback tetap jalan; kegagalan fatal hanya bila
#   service tidak kembali atau verifikasi diff gagal total).
#   PENGECUALIAN (20 Nov 2026): bila dump config saat ini TIDAK BISA
#   diambil sama sekali (batch clish gagal dari dalam sesi klish +
#   tidak ada startup-config — mesin ter-wipe pasca-confirm),
#   prune DILEWATI dengan peringatan lantang dan rollback TETAP
#   JALAN (restore file + restart). Rollback tidak boleh gagal hanya
#   karena tidak ada yang bisa di-prune.
#
# Rollback polos (tanpa nama) = kembali ke startup-config. Karena
# `save` tidak pernah memotret bird.d/netstate/sysctl, perintah
# `save` kini JUGA menulis titik tersembunyi `.last-save` (best-effort,
# tidak pernah menggagalkan save) yang memuat isi yang sama dengan
# checkpoint bernama — sehingga rollback polos memakai `.last-save`
# sebagai sumber dan mencapai fidelitas penuh, bukan sekadar replay.
# `.last-save` tidak tampil di `checkpoint list` dan tidak bisa
# dihapus/di-rollback lewat nama (nama titik tidak boleh diawali
# titik — lihat valid_name).
#
# Batasan yang dinyatakan apa adanya (bukan diam):
#   - `no speed` / speed-del: nilai live speed bertahan sampai reboot
#     (driver tidak punya operasi unset) — sama seperti semantik
#     `no speed` yang sudah didokumentasikan. Rollback TIDAK bisa
#     memaksa live speed kembali tanpa reboot.
#   - Route blackhole FreeBSD tidak di-prune (sintaks delete-nya
#     tidak diverifikasi di lab ini) — hapus lewat `no` form bila
#     perlu, atau akan hilang sendiri saat reboot berikutnya
#     (replay hanya menambah route dari titik).
#   - Bird yang tidak jalan (birdc gagal) = peringatan lantang,
#     bukan pembatalan rollback (file sudah dipulihkan; parse check
#     bird.conf sudah lolos sebelum file diganti).
# POSIX sh (jalan di dash Debian dan sh FreeBSD).
set -u
OS=${TITIAN_OS:-$(uname -s)}
ROOT=${TITIAN_ROOT:-/opt/titian}
# Pager global: output show >1 layar lewat less (titian-page.sh).
# Prologue dipanggil SESUDAH setup warna/TTY bila ada, SEBELUM output pertama.
SBIN_DIR=$(dirname "$0")
. "$SBIN_DIR/titian-page.sh"
# Hanya subcommand baca yang dipager: set/generate/commit TIDAK —
# output-nya harus tetap streaming/langsung, bukan tertahan sampai EXIT.
case "${1:-}" in list) titian_page_begin ;; esac

STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
BIN=$ROOT/bin
if [ ! -x "$BIN/clish" ] && [ -x /usr/local/bin/clish ]; then BIN=/usr/local/bin; fi
SBIN=${RT_SBIN:-$ROOT/sbin}
STATE_DIR=${TITIAN_STATE_DIR:-/etc/titian/netstate}
CKPT_DIR=$STATE_ROOT/checkpoints
SOCKFILE=/tmp/konfd.socket
CFG_DIR=${TITIAN_CFG_DIR:-/cfg/titian}
# Intent top-level yang dipersistenkan titian-cfg.sh (daftar yang sama
# dengan titian-cfg.sh + titian-factory-reset.sh INTENT_FILES — bila
# daftar di sana berubah, samakan di sini). frr.conf TIDAK ikut
# (dikelola vtysh; titian-cfg sengaja tidak me-restore-nya).
INTENT_FILES="terminal-length ipoe.conf bgp.conf bfd.conf static.conf rip.conf ospf.conf direct.conf pipe.conf kernel.conf device.conf rpki.conf radv.conf babel.conf bird-global.conf aggregator.conf bmp.conf l3vpn.conf mrt.conf"

err() { echo "Error: $*" >&2; exit 33; }
warn() {
    if [ -t 2 ]; then printf '\033[33mWarning(checkpoint):\033[0m %s\n' "$*" >&2
    else echo "Warning(checkpoint): $*" >&2; fi
}

valid_name() {
    # $1=nama -> 0 bila valid: [A-Za-z0-9][A-Za-z0-9_-]*, maks 64
    case "$1" in
        ''|.*) return 1 ;;
    esac
    [ "${#1}" -le 64 ] || return 1
    case "$1" in
        *[!A-Za-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

avail_names() {
    # Cetak nama checkpoint yang tersedia (satu baris, dipisah spasi),
    # atau "(tidak ada checkpoint)" bila belum ada. Dipakai pesan error
    # LOUD saat rollback/delete menyebut nama yang tidak dikenal —
    # pola yang sama dengan filter-name (sebutkan yang tersedia).
    local out="" d name
    if [ -d "$CKPT_DIR" ]; then
        for d in "$CKPT_DIR/"*/; do
            [ -d "$d" ] || continue
            name=${d%/}; name=${name##*/}
            case "$name" in .*) continue ;; esac
            out="$out $name"
        done
    fi
    if [ -n "$out" ]; then printf '%s' "${out# }"
    else printf '(tidak ada checkpoint)'; fi
}

now_wib() { TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S WIB'; }

bird_bin() {
    command -v bird 2>/dev/null || { [ -x /usr/sbin/bird ] && echo /usr/sbin/bird; } || \
        { [ -x /usr/local/sbin/bird ] && echo /usr/local/sbin/bird; } || echo bird
}
birdc_bin() {
    command -v birdc 2>/dev/null || { [ -x /usr/sbin/birdc ] && echo /usr/sbin/birdc; } || \
        { [ -x /usr/local/sbin/birdc ] && echo /usr/local/sbin/birdc; } || echo birdc
}
# birdc_sock — salinan titian-birdc.sh (BC8, B13): cetak "-s <path>" bila
# socket utama dikonfigurasi via klish ($STATE_ROOT/birdc.conf), kosong bila
# default. Dipakai semua pemanggilan birdc di file ini.
birdc_sock() {
    _s=$(grep '^socket ' "$STATE_ROOT/birdc.conf" 2>/dev/null | head -1 | cut -d' ' -f2-)
    [ -n "$_s" ] && printf '%s' "-s $_s"
}

bird_conf_path() {
    # Hook uji (pola TITIAN_FRR_CONF): override lokasi live untuk
    # mock. JANGAN override di mesin live.
    if [ -n "${TITIAN_BIRD_LIVE_CONF:-}" ]; then echo "$TITIAN_BIRD_LIVE_CONF"; return 0; fi
    if [ "$OS" = "FreeBSD" ]; then echo "/usr/local/etc/bird.conf"; else echo "/etc/bird/bird.conf"; fi
}

# --- normalisasi terminator dump (fix012b, 24 Nov 2026) ---
ensure_end_terminator() {
    # $1=file dump (sudah dipangkas baris kosong akhir). Tambahkan baris
    # `end` bila belum ada; JANGAN gagal hanya karena `end` tidak ada.
    #
    # ALASAN (terbukti, bukan tebakan): klish 2.2.5 TIDAK PERNAH menulis
    # baris `end` sendiri — konf/tree/tree.c hanya mencetak baris yang
    # ada di tree konfd. `end` masuk tree HANYA bila diketik di
    # configure-mode: configure-mode.xml memberi perintah `end` sebuah
    # <CONFIG priority="0x9999"/> tanpa operation, dan default op di
    # klish (shell_xml.c) adalah SET bila operation tak disebut — jadi
    # tiap `end` yang diketik tersimpan di tree (prioritas tertinggi =
    # tercetak terakhir). Config yang dibangun skrip (pakai `exit`,
    # bukan `end` — semua alur uji guest) sah tapi tanpa `end`, sehingga
    # guard lama `grep -q '^end$'` menolak dump yang sah dan
    # `checkpoint save` selalu gagal (rc=33) — padahal batch clish-nya
    # BERHASIL (rc=0, dump 26 baris). Bukti guest 014: sesudah `end`
    # diketik sekali, `checkpoint save` langsung berhasil dan `save`
    # berikutnya menulis startup-config yang diakhiri `end`.
    #
    # Menambahkan `end` aman untuk replay: `end` keluar dari
    # configure-mode lalu tersimpan lagi (self-healing), dan cocok
    # dengan format anchor mesin asli (409 baris, diakhiri `end`).
    # Dump KOSONG tetap gagal (diperiksa pemanggil / di sini).
    [ -s "$1" ] || return 1
    grep -q '^end$' "$1" && return 0
    printf '%s\n' "end" >> "$1" || return 1
    return 0
}

# --- bandingkan dua dump sebagai KONFIGURASI (abaikan pemisah `!`) ---
dump_norm() {
    # $1=file -> cetak bentuk kanonis ke stdout (tanpa baris `!`
    # semata dan baris kosong).
    grep -v -e '^!$' -e '^$' "$1" 2>/dev/null
}
dump_same() {
    # $1 $2 = dua file dump -> 0 bila isi konfigurasinya sama.
    # Baris `!` semata adalah pemisah cetakan klish
    # (konf_tree_fprintf) — posisinya TIDAK stabil melewati
    # save -> restore -> replay (bukti uji 017: diff verifikasi
    # rollback hanya `!` di baris 2 dan 12, isi konfigurasi sama
    # persis; `*` di `show checkpoints` pun hilang karenanya).
    # Bandingkan tanpa `!`/kosong; `end` sudah dinormalisasi
    # ensure_end_terminator di kedua sisi, stempel sudah dibuang
    # saat dump. Baris `!` tidak membawa info konfigurasi.
    _a=$(mktemp /tmp/titian-ckpt-cmpa.XXXXXX) || return 1
    _b=$(mktemp /tmp/titian-ckpt-cmpb.XXXXXX) || { rm -f "$_a"; return 1; }
    dump_norm "$1" > "$_a"; dump_norm "$2" > "$_b"
    cmp -s "$_a" "$_b"; _rc=$?
    rm -f "$_a" "$_b"
    return $_rc
}
dump_diff() {
    # $1 $2 = dua file dump -> cetak diff bentuk kanonis (tanpa `!`).
    _a=$(mktemp /tmp/titian-ckpt-difa.XXXXXX) || return 1
    _b=$(mktemp /tmp/titian-ckpt-difb.XXXXXX) || { rm -f "$_a"; return 1; }
    dump_norm "$1" > "$_a"; dump_norm "$2" > "$_b"
    diff "$_a" "$_b" 2>/dev/null | head -40
    rm -f "$_a" "$_b"
}

# --- dump running-config lewat konf (jalur live, dari DALAM sesi klish) ---
dump_via_konf() {
    # $1=file-tujuan (ditulis penuh, bukan append)
    #
    # Mekanisme yang SAMA dengan `show running-config` (CONFIG dump di
    # plugins/clish/hook_config.c): kirim query `-d -f <file>` ke
    # konfd lewat klien `konf`. Beda dengan batch clish: `konf` hanya
    # membuka SATU koneksi query ke socket yang sama dengan sesi luar
    # — cara yang dipakai ACTION `save` untuk SET (enable-mode.xml),
    # jadi BISA jalan dari DALAM sesi klish dan mengembalikan tree
    # LIVE (termasuk perubahan yang di-commit tapi BELUM di-save).
    # Itu persis yang dibutuhkan prune saat rollback: dump lama
    # (batch clish gagal dari dalam sesi + fallback startup-config)
    # HANYA berisi yang sudah di-save, sehingga objek live yang
    # belum di-save (mis. vlan101/102 di uji 016) lolos dari prune
    # dan rollback "berhasil" palsu. Bukti sumber (klish 2.2.5):
    # konfd melayani BANYAK klien sekaligus (select loop,
    # bin/konfd.c) — bukan eksklusif satu koneksi; parser query
    # menerima `-d` + `-f` (konf/query/query.c).
    local tmp
    [ -x "$BIN/konf" ] || return 1
    [ -S "$SOCKFILE" ] || return 1
    tmp=$(mktemp /tmp/titian-ckpt-konf.XXXXXX) || return 1
    if ! "$BIN/konf" -s "$SOCKFILE" -- -d -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; return 1
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    # Buang baris stempel (metadata save, bukan konfigurasi) +
    # baris kosong akhir agar diff byte-persis stabil (sama
    # dengan jalur batch clish di bawah).
    grep -v -e '^! version' -e '^ ! last commit' -e '^! last commit' "$tmp" | \
        awk '{lines[NR]=$0} END {last=NR; while (last>0 && lines[last]=="") last--; for (i=1;i<=last;i++) print lines[i]}' > "$1"
    rm -f "$tmp"
    [ -s "$1" ] || return 1
    ensure_end_terminator "$1" || return 1
    return 0
}

# --- dump running-config (tiga tingkat, dari yang paling live) ---
dump_running() {
    # $1=file-tujuan (ditulis penuh, bukan append)
    # DUMP_FALLBACK (global): 1 bila dump berasal dari startup-config
    # (tingkat 3, bukan tree live) — dipakai cmd_rollback untuk
    # memperingatkan bahwa prune buta terhadap perubahan belum di-save.
    DUMP_FALLBACK=0
    local tmp cmd
    # Tingkat 1 — konf (tree LIVE, dari dalam sesi klish pun bisa).
    if dump_via_konf "$1"; then return 0; fi
    # Tingkat 2 — batch clish (tree live, hanya dari shell).
    tmp=$(mktemp /tmp/titian-ckpt-dump.XXXXXX) || return 1
    cmd=$(mktemp /tmp/titian-ckpt-cmd.XXXXXX) || { rm -f "$tmp"; return 1; }
    printf 'show running-config\n' > "$cmd"
    if "$BIN/clish" -x "$ROOT/etc/clish-en" -w enable-view "$cmd" > "$tmp" 2>&1; then
        rm -f "$cmd"
        # buang banner sesi + baris prompt-echo; sisakan dump mulai
        # baris setelah `# show running-config`. Buang baris kosong
        # di akhir agar diff byte-persis stabil. Buang juga baris
        # stempel (metadata save, bukan konfigurasi — lihat header).
        awk '/# show running-config$/ {dump=1; next} dump {print}' "$tmp" | \
            grep -v -e '^! version' -e '^ ! last commit' -e '^! last commit' | \
            awk '{lines[NR]=$0} END {last=NR; while (last>0 && lines[last]=="") last--; for (i=1;i<=last;i++) print lines[i]}' > "$1"
        rm -f "$tmp"
        if [ -s "$1" ]; then
            ensure_end_terminator "$1" || return 1
            return 0
        fi
        # Dump kosong dari batch clish JANGAN langsung gagal (uji
        # 016: batch bisa "berhasil" dengan dump kosong bila konfd
        # sibuk sesaat sesudah save) — jatuh ke fallback
        # startup-config di bawah, bukan return 1.
    else
        rm -f "$tmp" "$cmd"
    fi
    # Tingkat 3 — FALLBACK startup-config (config terakhir yang
    # di-save). Peringatan lantang agar transparan: perubahan yang
    # di-commit tapi BELUM di-save tidak ikut — karena itu tingkat
    # ini TIDAK BOLEH dipakai untuk prune (prune memakai dump
    # tingkat 1/2; bila keduanya gagal, prune dilewati — lihat
    # cmd_rollback).
    DUMP_FALLBACK=1
    warn "dump live gagal (konf + batch clish) — fallback ke startup-config (config terakhir yang di-save)"
    if [ -s "$STATE_ROOT/startup-config" ]; then
        grep -v -e '^! version' -e '^ ! last commit' -e '^! last commit' "$STATE_ROOT/startup-config" | \
            awk '{lines[NR]=$0} END {last=NR; while (last>0 && lines[last]=="") last--; for (i=1;i<=last;i++) print lines[i]}' > "$1"
        [ -s "$1" ] || return 1
        ensure_end_terminator "$1" || return 1
        return 0
    fi
    return 1
}

# --- snapshot file-file state ke direktori titik (sudah ada) ---
snapshot_files() {
    # $1=dir-titik $2=sumber-running-config (file; untuk .last-save
    #      ini startup-config yang baru ditulis save)
    local d=$1 src=$2 conf
    conf=$(bird_conf_path)
    # simpan running-config TANPA baris stempel (alasan: header).
    # Untuk .last-save, sumbernya startup-config yang baru ditulis
    # save (berstempel) — strip di sini membuatnya kanonis.
    grep -v -e '^! version' -e '^ ! last commit' -e '^! last commit' "$src" > "$d/running-config.tmp" 2>/dev/null && \
        mv "$d/running-config.tmp" "$d/running-config" || return 1
    # Normalisasi terminator (fix012b): sumber .last-save adalah
    # startup-config, yang juga bisa tanpa `end` (lihat
    # ensure_end_terminator) — samakan dengan dump_running agar
    # verifikasi rollback (cmp vs dump sesudah rollback) konsisten.
    ensure_end_terminator "$d/running-config" || return 1
    # Header stempel startup-config (perbaikan 23 Nov 2026 — rollback
    # byte-identik, temuan Part 9): blok = baris-baris awal
    # startup-config yang cocok pola stempel (`!`, `! version ...`,
    # ` ! last commit: ...`), berhenti di baris pertama yang bukan
    # stempel. Guard: file HANYA valid bila memuat baris `! version`
    # dan paling banyak 5 baris (blok stempel = 4 baris; lebih dari itu
    # berarti pola salah tangkap isi config) — bila guard gagal, file
    # dibuang (rollback fallback ke perilaku lama).
    if [ -f "$STATE_ROOT/startup-config" ]; then
        awk '/^!$/ || /^! version/ || /^ ?! last commit/ {print; next} {exit}' \
            "$STATE_ROOT/startup-config" > "$d/startup-header" 2>/dev/null || true
        if grep -q '^! version' "$d/startup-header" 2>/dev/null && \
           [ "$(wc -l < "$d/startup-header" 2>/dev/null | tr -d ' ')" -le 5 ]; then
            chmod 600 "$d/startup-header" 2>/dev/null || true
        else
            rm -f "$d/startup-header"
        fi
    fi
    # GUARD (Temuan 4, 17 Nov 2026): JANGAN memotret bird.conf yang
    # bukan hasil generate titian (tanpa marker #-GLOBAL-# — mis.
    # file default BSDRP yang kembali sesudah reboot karena
    # /cfg/local basi). Memotret default meracuni checkpoint
    # (.last-save berisi default 13 Nov) dan rollback berikutnya
    # akan memulihkan file default itu. Bila live bukan titian:
    # lewati (snapshot bird.conf lama di titik dipertahankan) +
    # peringatan lantang. Rollback memakai bird.conf titik hanya
    # bila file itu ada (restore_files sudah menjaga).
    if [ -f "$conf" ]; then
        if grep -qF '#-GLOBAL-#' "$conf" 2>/dev/null; then
            cp -f "$conf" "$d/bird.conf"
        else
            warn "bird.conf live bukan hasil generate titian (tanpa marker #-GLOBAL-# — kemungkinan file default BSDRP pasca-reboot) — TIDAK dimasukkan ke checkpoint (snapshot lama dipertahankan)"
        fi
    fi
    mkdir -p "$d/bird.d" "$d/netstate" || return 1
    for f in "$STATE_ROOT/bird.d/"*.conf; do
        [ -e "$f" ] || continue
        case "$f" in *.cli-bak|*.pkgsave) continue ;; esac
        cp -f "$f" "$d/bird.d/" 2>/dev/null || true
    done
    if [ -d "$STATE_DIR" ]; then
        for f in "$STATE_DIR/"*; do
            [ -e "$f" ] || continue
            cp -f "$f" "$d/netstate/" 2>/dev/null || true
        done
    fi
    [ -f "$STATE_ROOT/sysctl.titian" ] && cp -f "$STATE_ROOT/sysctl.titian" "$d/sysctl.titian"
    [ -f "$STATE_ROOT/sysctl.titian.prev" ] && cp -f "$STATE_ROOT/sysctl.titian.prev" "$d/sysctl.titian.prev"
    # Intent top-level (lapis 2, 20 Nov 2026): simpan SEMUA file intent
    # (bukan hanya yang ada di bird.d) — running-config hasil dump
    # klish tidak memuat semua atribut, jadi intent adalah satu-satunya
    # sumber lengkap untuk regenerasi bird.conf. Hanya file yang ada
    # yang disalin; file yang tidak ada dilewati (restore juga
    # melewatinya). Mode 600 seperti file intent live.
    mkdir -p "$d/intent" || return 1
    for _if in $INTENT_FILES; do
        if [ -f "$STATE_ROOT/$_if" ]; then
            cp -f "$STATE_ROOT/$_if" "$d/intent/" 2>/dev/null || true
            chmod 600 "$d/intent/$_if" 2>/dev/null || true
        fi
    done
    chmod 700 "$d" "$d/bird.d" "$d/netstate" "$d/intent" 2>/dev/null || true
    chmod 600 "$d/running-config" "$d/bird.conf" "$d/meta" 2>/dev/null || true
    return 0
}

write_meta() {
    # $1=dir-titik $2=nama $3=sumber (running|save)
    {
        echo "name=$2"
        echo "created_wib=$(now_wib)"
        echo "source=$3"
    } > "$1/meta" || return 1
}

cmd_save() {
    # $1=nama
    local name=$1 d tmp
    valid_name "$name" || err "nama checkpoint tidak valid: '$name' (harus [A-Za-z0-9][A-Za-z0-9_-]*, maks 64 karakter)"
    d="$CKPT_DIR/$name"
    [ -e "$d" ] && err "checkpoint sudah ada: $name — hapus dulu ('checkpoint delete $name') atau pakai nama lain (tidak ditimpa diam-diam)"
    mkdir -p "$CKPT_DIR" 2>/dev/null || err "gagal mkdir $CKPT_DIR"
    mkdir -p "$d" || err "gagal mkdir $d"
    tmp=$(mktemp /tmp/titian-ckpt-save.XXXXXX) || { rmdir "$d" 2>/dev/null; err "gagal mktemp"; }
    if ! dump_running "$tmp"; then
        rm -rf "$d" "$tmp"
        err "gagal membuang running-config (dump kosong / konfd tidak terjangkau?) — checkpoint TIDAK dibuat, tidak ada perubahan"
    fi
    if ! snapshot_files "$d" "$tmp"; then
        rm -rf "$d" "$tmp"
        err "gagal memotret file state — checkpoint TIDAK dibuat, tidak ada perubahan"
    fi
    rm -f "$tmp"
    write_meta "$d" "$name" "running" || warn "gagal tulis meta (checkpoint tetap tersimpan)"
    echo "checkpoint $name dibuat: $(grep '^created_wib=' "$d/meta" 2>/dev/null | cut -d= -f2-)"
    echo "  isi: running-config + startup-header + bird.conf + bird.d + intent + netstate + sysctl (beku; 'save' biasa not mengubah point ini)"
}

cmd_snapshot_last_save() {
    # Dipanggil perintah `save` (best-effort; TIDAK PERNAH gagal fatal).
    # Sumber running-config = startup-config yang baru ditulis save.
    local d="$CKPT_DIR/.last-save"
    mkdir -p "$CKPT_DIR" 2>/dev/null || { warn "gagal mkdir $CKPT_DIR"; return 0; }
    mkdir -p "$d" 2>/dev/null || { warn "gagal mkdir $d"; return 0; }
    if ! snapshot_files "$d" "$STATE_ROOT/startup-config"; then
        warn "gagal memotret .last-save (save tetap berhasil)"
        return 0
    fi
    write_meta "$d" ".last-save" "save" 2>/dev/null || true
    return 0
}

cmd_list() {
    local d name created dump tmp line found=0
    # tidak ada titik non-tersembunyi sama sekali -> pesan ramah
    if [ -d "$CKPT_DIR" ]; then
        for d in "$CKPT_DIR/"*/; do
            [ -d "$d" ] || continue
            case "$(basename "$d")" in .*) continue ;; *) found=1; break ;; esac
        done
    fi
    if [ "$found" -eq 0 ]; then
        echo "(none yet checkpoint — pakai 'checkpoint save <name>')"
        return 0
    fi
    tmp=$(mktemp /tmp/titian-ckpt-list.XXXXXX) || tmp=""
    if [ -n "$tmp" ] && ! dump_running "$tmp"; then rm -f "$tmp"; tmp=""; fi
    printf '%-24s %-22s %s\n' "Name" "DIBUAT (WIB)" "SAAT INI"
    # kumpulkan "created|name", urutkan kronologis, lalu cetak
    for d in "$CKPT_DIR/"*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        case "$name" in .* ) continue ;; esac
        created=$(grep '^created_wib=' "$d/meta" 2>/dev/null | cut -d= -f2-)
        [ -n "$created" ] || created="(tanpa meta)"
        echo "$created|$name"
    done | LC_ALL=C sort | while IFS='|' read -r created name; do
        line=""
        if [ -n "$tmp" ] && [ -f "$CKPT_DIR/$name/running-config" ] && dump_same "$CKPT_DIR/$name/running-config" "$tmp"; then
            line="*"
        fi
        printf '%-24s %-22s %s\n' "$name" "$created" "$line"
    done
    [ -n "$tmp" ] && rm -f "$tmp"
    echo "  * = isi point sama persis with running-config current"
}

cmd_delete() {
    local name=$1 d
    valid_name "$name" || err "nama checkpoint tidak valid: '$name'"
    d="$CKPT_DIR/$name"
    [ -d "$d" ] || err "checkpoint tidak ada: $name — tidak ada yang dihapus (yang tersedia: $(avail_names))"
    rm -rf "$d" || err "gagal hapus checkpoint $name"
    echo "checkpoint $name deleted"
}

# --- prune: hapus objek live yang tidak ada di titik ---
# Semua prune membaca state SAAT INI (sebelum restore file) dan
# membandingkannya dengan isi titik. Gagal satu item = peringatan,
# bukan pembatalan (dilaporkan di akhir).
PRUNE_WARN=0
prune_note() { warn "$*"; PRUNE_WARN=1; }

prune_iface() {
    # $1=iface $2=tipe (vlan|vxlan|bonding|lagg|loopback)
    local iface=$1 type=$2 bond
    # lepas dari bond bila masih menempel (Linux; FreeBSD best-effort)
    if [ -f "$STATE_DIR/$iface.bond" ]; then
        bond=$(head -n 1 "$STATE_DIR/$iface.bond" 2>/dev/null)
        if [ -n "$bond" ]; then
            if [ "$OS" = "FreeBSD" ]; then
                ifconfig "$bond" -laggport "$iface" 2>/dev/null || prune_note "gagal lepas $iface dari $bond (best-effort)"
            else
                if [ -w "/sys/class/net/$bond/bonding/slaves" ]; then
                    echo "-$iface" > "/sys/class/net/$bond/bonding/slaves" 2>/dev/null || prune_note "gagal lepas $iface dari $bond"
                fi
            fi
        fi
    fi
    if [ "$OS" = "FreeBSD" ]; then
        ifconfig "$iface" >/dev/null 2>&1 || return 0
        ifconfig "$iface" destroy 2>/dev/null || prune_note "gagal hapus interface $iface (best-effort)"
    else
        [ -d "/sys/class/net/$iface" ] || return 0
        ip link delete dev "$iface" 2>/dev/null || prune_note "gagal hapus interface $iface (best-effort)"
    fi
}

prune_addrs() {
    # $1=iface $2=file-.addr-saat-ini $3=file-.addr-titik (boleh absen)
    local iface=$1 cur=$2 tgt=$3 line a b c
    [ -f "$cur" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ -f "$tgt" ] && grep -qxF "$line" "$tgt" 2>/dev/null; then continue; fi
        # bentuk: "inet <cidr>" | "inet <local> peer <peer>"
        # (sama untuk inet6) — set -- memecah jadi $1..$4
        set -- $line; a=${1:-}; b=${2:-}; c=${3:-}; d=${4:-}
        case "$a" in
            inet)
                if [ "$c" = "peer" ]; then
                    "$SBIN/titian-if.sh" addr-del "$iface" "$b" "$d" 2>/dev/null || prune_note "gagal hapus alamat $line di $iface"
                else
                    "$SBIN/titian-if.sh" addr-del "$iface" "$b" 2>/dev/null || prune_note "gagal hapus alamat $line di $iface"
                fi
                ;;
            inet6)
                if [ "$c" = "peer" ]; then
                    "$SBIN/titian-if.sh" addr6-del "$iface" "$b" "$d" 2>/dev/null || prune_note "gagal hapus alamat $line di $iface"
                else
                    "$SBIN/titian-if.sh" addr6-del "$iface" "$b" 2>/dev/null || prune_note "gagal hapus alamat $line di $iface"
                fi
                ;;
        esac
    done < "$cur"
}

tuning_key() {
    # $1=baris .tuning -> kunci ("mtu"|"qlen"|"offload tso"|"coalesce rx-usecs"|"speed")
    case "$1" in
        'offload '*) echo "offload ${1#offload }" | awk '{print $1" "$2}' ;;
        'coalesce '*) echo "coalesce ${1#coalesce }" | awk '{print $1" "$2}' ;;
        *) echo "$1" | awk '{print $1}' ;;
    esac
}
prune_tuning() {
    # $1=iface $2=file-.tuning-saat-ini $3=file-.tuning-titik (boleh absen)
    local iface=$1 cur=$2 tgt=$3 line key feat kind
    [ -f "$cur" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key=$(tuning_key "$line")
        if [ -f "$tgt" ] && grep -q "^$key " "$tgt" 2>/dev/null; then continue; fi
        case "$key" in
            mtu) "$SBIN/titian-tune.sh" mtu-del "$iface" 2>/dev/null || prune_note "gagal hapus tuning mtu di $iface" ;;
            qlen) "$SBIN/titian-tune.sh" qlen-del "$iface" 2>/dev/null || prune_note "gagal hapus tuning qlen di $iface" ;;
            'offload '*) feat=${key#offload }; "$SBIN/titian-tune.sh" offload-del "$iface" "$feat" 2>/dev/null || prune_note "gagal hapus tuning offload $feat di $iface" ;;
            'coalesce '*) kind=${key#coalesce }; "$SBIN/titian-tune.sh" coalesce-del "$iface" "$kind" 2>/dev/null || prune_note "gagal hapus tuning coalesce $kind di $iface" ;;
            speed) "$SBIN/titian-tune.sh" speed-del "$iface" 2>/dev/null || prune_note "gagal hapus tuning speed di $iface (live bertahan sampai reboot — batas driver)" ;;
        esac
    done < "$cur"
}

prune_sysctls() {
    # $1=file-sysctl-saat-ini $2=file-sysctl-titik (boleh absen)
    local cur=$1 tgt=$2 line k
    [ -f "$cur" ] || return 0
    while IFS='=' read -r k _v; do
        [ -n "$k" ] || continue
        if [ -f "$tgt" ] && grep -q "^$k=" "$tgt" 2>/dev/null; then continue; fi
        "$SBIN/titian-sysctl.sh" del "$k" 2>/dev/null || prune_note "gagal hapus sysctl $k"
    done < "$cur"
}

prune_routes() {
    # $1=dump-saat-ini $2=running-config-titik
    # (baca dari file temp, bukan pipa — supaya prune_note tidak
    # tenggelam di subshell)
    local cur=$1 tgt=$2 line prefix tmpf
    tmpf=$(mktemp /tmp/titian-ckpt-rt.XXXXXX) || return 0
    grep -E '^(ip|ipv6) route ' "$cur" 2>/dev/null > "$tmpf" || true
    while IFS= read -r line; do
        grep -qxF "$line" "$tgt" 2>/dev/null && continue
        case "$line" in
            'ip route blackhole '*) prefix=${line#ip route blackhole }; prefix=${prefix%% *}
                if [ "$OS" = "FreeBSD" ]; then prune_note "route blackhole $prefix tidak di-prune di FreeBSD (hapus lewat 'no' form bila perlu)"; continue; fi
                ip route del blackhole "$prefix" 2>/dev/null || prune_note "gagal hapus route blackhole $prefix" ;;
            'ip route '*) prefix=${line#ip route }; prefix=${prefix%% *}
                if [ "$OS" = "FreeBSD" ]; then route delete -inet "$prefix" 2>/dev/null || prune_note "gagal hapus route $prefix";
                else ip route del to "$prefix" 2>/dev/null || prune_note "gagal hapus route $prefix"; fi ;;
            'ipv6 route blackhole '*) prefix=${line#ipv6 route blackhole }; prefix=${prefix%% *}
                if [ "$OS" = "FreeBSD" ]; then prune_note "route blackhole v6 $prefix tidak di-prune di FreeBSD (hapus lewat 'no' form bila perlu)"; continue; fi
                ip -6 route del blackhole "$prefix" 2>/dev/null || prune_note "gagal hapus route blackhole v6 $prefix" ;;
            'ipv6 route '*) prefix=${line#ipv6 route }; prefix=${prefix%% *}
                if [ "$OS" = "FreeBSD" ]; then route delete -inet6 "$prefix" 2>/dev/null || prune_note "gagal hapus route v6 $prefix";
                else ip -6 route del to "$prefix" 2>/dev/null || prune_note "gagal hapus route v6 $prefix"; fi ;;
        esac
    done < "$tmpf"
    rm -f "$tmpf"
}

prune_all() {
    # $1=dump-saat-ini $2=dir-titik
    # (baca dari file temp, bukan pipa — supaya prune_note tidak
    # tenggelam di subshell)
    # URUTAN WAJIB (pelajaran FreeBSD 2 Nov 2026): route, alamat,
    # tuning, dan sysctl DIHAPUS DULU selagi interface masih ada,
    # interface buatan dihancurkan TERAKHIR. Dua ketergantungan
    # yang terbukti: (1) menghancurkan interface ikut menghapus
    # alamat + route-nya; (2) di FreeBSD, menghapus alamat
    # interface ikut menghapus route statik via interface itu
    # (terbukti: addr-del lo1 menghilangkan 198.51.99.0/24 dari
    # tabel). Karena itu route DIHAPUS SEBELUM alamat — kalau
    # dibalik, prune route gagal palsu ("not in table") dan
    # memunculkan Warning yang menyesatkan padahal keadaan akhir
    # sudah benar.
    local cur=$1 d=$2 line type name tmpf
    # (a) route statik ekstra — PERTAMA (lihat komentar urutan)
    prune_routes "$cur" "$d/running-config"
    # (b) alamat ekstra per interface
    if [ -d "$STATE_DIR" ]; then
        for f in "$STATE_DIR/"*.addr; do
            [ -e "$f" ] || continue
            name=$(basename "$f" .addr)
            prune_addrs "$name" "$f" "$d/netstate/$name.addr"
        done
    fi
    # (c) kunci tuning ekstra per interface
    if [ -d "$STATE_DIR" ]; then
        for f in "$STATE_DIR/"*.tuning; do
            [ -e "$f" ] || continue
            case "$f" in *.prev) continue ;; esac
            name=$(basename "$f" .tuning)
            prune_tuning "$name" "$f" "$d/netstate/$name.tuning"
        done
    fi
    # (d) sysctl global ekstra
    prune_sysctls "$STATE_ROOT/sysctl.titian" "$d/sysctl.titian"
    # (e) interface buatan Titian yang mengendap — TERAKHIR:
    #     header seksi `interface <tipe> <nama>` di dump saat ini
    #     tapi tidak di titik
    tmpf=$(mktemp /tmp/titian-ckpt-if.XXXXXX) || return 0
    grep -E '^interface (vlan|vxlan|bonding|lagg|loopback) ' "$cur" 2>/dev/null > "$tmpf" || true
    while IFS= read -r line; do
        grep -qxF "$line" "$d/running-config" 2>/dev/null && continue
        type=$(echo "$line" | awk '{print $2}'); name=$(echo "$line" | awk '{print $3}')
        # Nama interface OS: untuk vlan/vxlan, $3 adalah ID numerik
        # (baris dump `interface vlan 101 vtnet0`) dan nama OS-nya
        # adalah tipe+ID (`vlan101`, `vxlan101` — FreeBSD menamai
        # begitu; bukti: `unit=${iface#vxlan}` di titian-vxlan.sh).
        # Mengirim "101" mentah ke prune_iface berarti `ifconfig
        # 101 destroy` — interface tidak ada, prune diam-diam
        # tidak melakukan apa-apa (bukti uji 016/017: vlan101/102
        # bertahan hidup sesudah rollback). lagg/loopback/bonding
        # memakai $3 sebagai nama penuh (lagg0/lo1/bond0).
        case "$type" in
            vlan|vxlan) iface="${type}${name}" ;;
            *) iface="$name" ;;
        esac
        prune_iface "$iface" "$type"
    done < "$tmpf"
    rm -f "$tmpf"
}

service_restart() {
    if [ "$OS" = "FreeBSD" ]; then
        service titian restart 2>&1 || return 1
    else
        systemctl restart titian 2>&1 || return 1
    fi
    # tunggu socket konfd kembali (maks ~30 detik)
    i=0
    while [ ! -S "$SOCKFILE" ] && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
    [ -S "$SOCKFILE" ] || return 1
    return 0
}

restore_files() {
    # $1=dir-titik — tulis startup-config + bird.conf + bird.d +
    # netstate + sysctl dari titik (menimpa penuh)
    local d=$1 conf f
    conf=$(bird_conf_path)
    # Startup-config: pulihkan BYTE-IDENTIK (perbaikan 23 Nov 2026,
    # temuan Part 9). Titik BARU menyimpan blok stempel di
    # startup-header; gabungkan dengan dump running-config: dump
    # diawali baris `!` (pemisah klish = baris pertama
    # startup-config), jadi baris pertama dump DIGANTI blok header
    # utuh — bukan ditempel di depan (itu akan menduplikasi `!`).
    # Bila dump tidak diawali `!` (config kosong / bentuk lain),
    # header ditempel di depan. Titik LAMA (tanpa startup-header):
    # perilaku lama (dump polos) — 3 baris header tetap hilang di
    # titik lama (peringatan di cmd_rollback).
    if [ -s "$d/startup-header" ]; then
        if [ "$(head -n 1 "$d/running-config" 2>/dev/null)" = "!" ]; then
            { cat "$d/startup-header"; tail -n +2 "$d/running-config"; } > "$STATE_ROOT/startup-config.tmp.$$" || return 1
        else
            { cat "$d/startup-header"; cat "$d/running-config"; } > "$STATE_ROOT/startup-config.tmp.$$" || return 1
        fi
        mv "$STATE_ROOT/startup-config.tmp.$$" "$STATE_ROOT/startup-config" || return 1
    else
        cp -f "$d/running-config" "$STATE_ROOT/startup-config" || return 1
    fi
    # Cerminkan ke /cfg agar rollback bertahan melewati reboot
    # (temuan Part 9: /cfg dulu TIDAK dipulihkan sama sekali).
    # HANYA bila restore byte-identik (ada startup-header): untuk
    # titik lama, /cfg dibiarkan apa adanya — menimpa salinan /cfg
    # yang bagus dengan file 3-baris-pendek justru merusak.
    if [ -s "$d/startup-header" ] && [ -d "$CFG_DIR" ]; then
        cp -f "$STATE_ROOT/startup-config" "$CFG_DIR/startup-config" 2>/dev/null || \
            warn "gagal mencerminkan startup-config ke $CFG_DIR/startup-config (rollback tetap berlaku di sesi ini, tapi TIDAK bertahan melewati reboot — jalankan 'save' sesudah rollback)"
    fi
    # MODE FILE LIVE (perbaikan 2 Nov 2026): cp FreeBSD MENULAR mode
    # sumber ke tujuan yang sudah ada (terbukti di lab: cp -f src600
    # dst644 -> dst 600), sementara file snapshot sengaja 600
    # (snapshot_files). Tanpa chmod eksplisit ini, restore membuat
    # file live 600 sehingga tidak terbaca tanpa sudo — persis yang
    # terjadi pada bird.conf + startup-config FreeBSD sesudah fitur
    # checkpoint (1 Nov 22:29). GNU cp Linux mempertahankan mode
    # tujuan, jadi chmod ini no-op di sana; tapi tetap ditulis
    # eksplisit agar restore tidak bergantung pada perilaku cp.
    # Mode live yang benar: 644 (semua saudara file di /etc/titian
    # dan /usr/local/etc FreeBSD 644; startup-config Debian 644).
    # bird.conf Debian DIKECUALIKAN: normanya 640 bird:bird di dir
    # 750 (hanya via sudo) — jangan dilebarkan.
    chmod 644 "$STATE_ROOT/startup-config" 2>/dev/null || true
    if [ -f "$d/bird.conf" ]; then
        cp -f "$d/bird.conf" "$conf" || return 1
        if [ "$OS" = "FreeBSD" ]; then chmod 644 "$conf" 2>/dev/null || true; fi
        # Cerminkan ke /cfg/local (Temuan 4) agar rollback bertahan
        # melewati reboot berikutnya — best-effort.
        sh "$SBIN/titian-bird.sh" mirror-bird-conf "$conf" 2>/dev/null || true
    fi
    if [ -d "$d/bird.d" ]; then
        for f in "$STATE_ROOT/bird.d/"*.conf; do
            [ -e "$f" ] || continue
            case "$f" in *.cli-bak|*.pkgsave) continue ;; esac
            rm -f "$f"
        done
        for f in "$d/bird.d/"*.conf; do
            [ -e "$f" ] || continue
            cp -f "$f" "$STATE_ROOT/bird.d/" 2>/dev/null || true
        done
    fi
    rm -rf "$STATE_DIR" 2>/dev/null || true
    mkdir -p "$STATE_DIR" || return 1
    if [ -d "$d/netstate" ]; then
        for f in "$d/netstate/"*; do
            [ -e "$f" ] || continue
            cp -f "$f" "$STATE_DIR/" 2>/dev/null || true
        done
    fi
    if [ -f "$d/sysctl.titian" ]; then cp -f "$d/sysctl.titian" "$STATE_ROOT/sysctl.titian";
    else rm -f "$STATE_ROOT/sysctl.titian"; fi
    if [ -f "$d/sysctl.titian.prev" ]; then cp -f "$d/sysctl.titian.prev" "$STATE_ROOT/sysctl.titian.prev";
    else rm -f "$STATE_ROOT/sysctl.titian.prev"; fi
    # Intent top-level (lapis 2, 20 Nov 2026): pulihkan intent dari
    # titik — ini yang membuat rollback memulihkan bird.conf lengkap.
    # Replay startup-config HANYA meng-upsert kunci yang ada di
    # startup-config (per-key, additive) + neighbor-add hanya menulis
    # default `import all` bila kunci import BELUM ADA — jadi intent
    # yang dipulihkan di sini BERTAHAN melewati replay, dan commit
    # apply-all meregenerasi bird.conf dari intent lengkap.
    # Persistensikan juga ke /cfg agar titian-cfg restore saat boot
    # tidak menimpa dengan versi basi + agar rollback bertahan
    # melewati reboot (best-effort; gagal = lewati diam, bukan fatal).
    if [ -d "$d/intent" ]; then
        for _if in "$d/intent/"*; do
            [ -e "$_if" ] || continue
            _base=$(basename "$_if")
            cp -f "$_if" "$STATE_ROOT/" 2>/dev/null || true
            chmod 600 "$STATE_ROOT/$_base" 2>/dev/null || true
            [ -d "$CFG_DIR" ] && cp -f "$_if" "$CFG_DIR/" 2>/dev/null || true
        done
    else
        # Checkpoint lama (pra-perbaikan, tanpa intent/): fallback ke
        # intent persisten /cfg/titian (best-effort). PERINGATAN:
        # /cfg adalah state TERAKHIR yang di-save (bisa lebih baru
        # dari titik) — untuk titik lama ini yang terbaik yang bisa
        # dilakukan tanpa mengubah titik; checkpoint BARU (dibuat
        # sesudah perbaikan ini) mandiri (intent tertanam di titik).
        warn "titik $(basename "$d") tidak menyimpan intent (checkpoint lama, pra-20 Nov 2026) — fallback ke intent persisten /cfg/titian (bila ada); bila /cfg juga kosong, bird.conf hasil regenerasi bisa kehilangan setting (import filter / graceful-restart-time / validate)"
        if [ -d "$CFG_DIR" ]; then
            for _if in $INTENT_FILES; do
                [ -f "$CFG_DIR/$_if" ] && cp -f "$CFG_DIR/$_if" "$STATE_ROOT/" 2>/dev/null || true
            done
        fi
    fi
    return 0
}

regen_mirrors() {
    # Cermin deklaratif dari netstate yang baru dipulihkan.
    # ATURAN YANG SAMA DENGAN GUARD sync_debian (insiden rollback
    # 2 Nov 2026): interface yang dikelola TAPI tanpa state
    # (.addr kosong + .tuning kosong — mis. enp1s0 mgmt yang hanya
    # tercatat sebagai managed) TIDAK BOLEH punya cermin; cermin
    # yang ada untuknya DIHAPUS (bukan di-sync). Cermin kosong
    # akan membajak interface sistem dari konfigurasi OS-nya.
    local m name net
    if [ -d "$STATE_DIR" ]; then
        for m in "$STATE_DIR/"*.managed; do
            [ -e "$m" ] || continue
            name=$(basename "$m" .managed)
            if [ ! -s "$STATE_DIR/$name.addr" ] && [ ! -s "$STATE_DIR/$name.tuning" ]; then
                if [ "$OS" != "FreeBSD" ]; then
                    rm -f "/etc/systemd/network/00-titian-$name.network" 2>/dev/null || true
                fi
                continue
            fi
            "$SBIN/titian-persist.sh" sync-if "$name" 2>/dev/null || true
        done
    fi
    # hapus cermin networkd interface yang tidak lagi dikelola
    if [ "$OS" != "FreeBSD" ]; then
        for net in /etc/systemd/network/00-titian-*.network; do
            [ -e "$net" ] || continue
            name=$(basename "$net" .network); name=${name#00-titian-}
            [ -f "$STATE_DIR/$name.managed" ] || rm -f "$net" 2>/dev/null || true
        done
    fi
    "$SBIN/titian-sysctl.sh" mirror 2>/dev/null || true
}

cmd_rollback() {
    # $1=nama (boleh kosong = startup-config via .last-save)
    local name=${1:-} d cur tmp bird
    if [ -n "$name" ]; then
        valid_name "$name" || err "nama checkpoint tidak valid: '$name'"
        d="$CKPT_DIR/$name"
        [ -d "$d" ] || err "checkpoint tidak ada: $name — TIDAK ADA PERUBAHAN (yang tersedia: $(avail_names); buat dulu dengan 'checkpoint save $name')"
    else
        d="$CKPT_DIR/.last-save"
        [ -d "$d" ] || err "belum pernah save (tidak ada titik .last-save) — TIDAK ADA PERUBAHAN (jalankan 'save' dulu atau buat checkpoint)"
        name="(startup-config)"
    fi
    [ -f "$d/running-config" ] || err "checkpoint rusak: $d/running-config tidak ada — TIDAK ADA PERUBAHAN"
    # Titik lama (pra-23 Nov 2026, tanpa startup-header): rollback
    # tetap jalan dengan perilaku lama — startup-config hasil rollback
    # kehilangan 3 baris header stempel + /cfg TIDAK dipulihkan
    # (jalankan 'save' sesudah rollback untuk menyinkronkan /cfg).
    if [ ! -s "$d/startup-header" ]; then
        warn "titik $name dibuat sebelum perbaikan header 23 Nov 2026 (tanpa startup-header) — startup-config hasil rollback kehilangan 3 baris header stempel + /cfg TIDAK dipulihkan; jalankan 'save' sesudah rollback untuk menyinkronkan /cfg"
    fi
    # parse check bird.conf titik SEBELUM mengganti apa pun
    if [ -f "$d/bird.conf" ]; then
        bird=$(bird_bin)
        if ! "$bird" -p -c "$d/bird.conf" >/dev/null 2>&1; then
            err "bird.conf titik $name GAGAL parse — TIDAK ADA PERUBAHAN (titik rusak, jangan dipakai)"
        fi
    fi
    cur=$(mktemp /tmp/titian-ckpt-rb.XXXXXX) || err "gagal mktemp"
    if ! dump_running "$cur"; then
        # Rollback TIDAK BOLEH gagal hanya karena dump config saat ini
        # tidak bisa diambil (akar error "konfd tidak terjangkau" saat
        # rollback, 20 Nov 2026): dump live (konf + batch clish)
        # gagal DAN tidak ada startup-config untuk fallback (mesin
        # ter-wipe pasca factory-reset confirm). Dump saat ini HANYA
        # dipakai prune_all (bersihkan objek live yang tidak ada di
        # titik). Bila tidak bisa diambil, tidak ada yang bisa
        # di-prune — perlakukan sebagai config kosong dan LANJUTKAN
        # ke restore_files + restart (itu inti rollback). Peringatan
        # lantang agar transparan; bukan silent success. Catatan:
        # dump hanya bisa gagal total bila startup-config pun tidak
        # ada (mesin ter-wipe) — dalam keadaan itu tidak ada objek
        # live Titian untuk di-prune.
        warn "tidak bisa membuang running-config saat ini (konfd tidak terjangkau + tidak ada startup-config) — prune objek live DILEWATI, lanjut memulihkan file dari titik $name"
        : > "$cur"
    fi
    if [ "${DUMP_FALLBACK:-0}" = "1" ]; then
        # Dump prune dari startup-config (bukan tree live): prune
        # buta terhadap perubahan yang di-commit tapi BELUM di-save
        # (uji 016: vlan101/102 lolos). File tetap dipulihkan dari
        # titik + restart jalan; verifikasi cmp di akhir akan
        # menangkap selisihnya (diff tidak kosong) — bukan silent.
        warn "dump prune dari startup-config (bukan tree live) — perubahan yang di-commit tapi BELUM di-save TIDAK TERLIHAT prune dan bisa bertahan hidup sesudah rollback; verifikasi di akhir akan menangkapnya"
    fi
    echo "rollback to $name — prune objek live that no  at point..."
    prune_all "$cur" "$d"
    echo "rollback to $name — pulihkan file (startup-config + bird + netstate + sysctl)..."
    if ! restore_files "$d"; then
        rm -f "$cur"
        err "gagal memulihkan file dari titik $name — KEADAAN MUNGKIN SETENGAH (periksa manual; titik tidak diubah)"
    fi
    regen_mirrors
    echo "rollback to $name — restart service titian..."
    if ! service_restart; then
        rm -f "$cur"
        err "service titian TIDAK KEMBALI setelah restart — file sudah dipulihkan dari titik, tapi konfd tidak jalan (periksa log service)"
    fi
    # sysctl live dari state yang dipulihkan (boot OS tidak me-apply
    # ulang cermin titian saat restart service — apply eksplisit)
    "$SBIN/titian-sysctl.sh" apply 2>/dev/null || true
    if [ -f "$d/bird.conf" ]; then
        out=$("$(birdc_bin)" $(birdc_sock) configure 2>&1); rc=$?
        echo "$out" | grep -v '^BIRD' || true
        [ "$rc" -ne 0 ] && warn "birdc configure gagal (bird.conf sudah dipulihkan + parse lolos; periksa birdc)"
    fi
    tmp=$(mktemp /tmp/titian-ckpt-rb2.XXXXXX) || tmp=""
    if [ -n "$tmp" ] && dump_running "$tmp"; then
        if dump_same "$tmp" "$d/running-config"; then
            echo "rollback OK: running-config sama persis with point $name"
        else
            echo "Warning: running-config after rollback Differs from point $name (diff at below, tanpa pemisah '!'):" >&2
            dump_diff "$d/running-config" "$tmp" >&2
            warn "verifikasi diff tidak kosong — periksa manual"
        fi
        rm -f "$tmp"
    else
        warn "verifikasi dump sesudah rollback gagal (konfd tidak menjawab) — periksa manual dengan 'show running-config'"
        [ -n "$tmp" ] && rm -f "$tmp"
    fi
    rm -f "$cur"
    # catat waktu rollback di meta titik (bukan mengubah isi titik)
    if [ -f "$d/meta" ]; then
        grep -v '^last_rollback_wib=' "$d/meta" > "$d/meta.tmp" 2>/dev/null && mv "$d/meta.tmp" "$d/meta" 2>/dev/null || true
        echo "last_rollback_wib=$(now_wib)" >> "$d/meta" 2>/dev/null || true
    fi
    echo "rollback to $name Done (persistensi: startup-config already ditulis from point — bertahan melewati reboot)."
    [ "$PRUNE_WARN" -eq 1 ] && warn "ada peringatan prune di atas — periksa baris Warning sebelum menganggap rollback bersih"
    return 0
}

case "${1:-}" in
    save) cmd_save "${2:-}" ;;
    snapshot-last-save) cmd_snapshot_last_save ;;
    list) cmd_list ;;
    delete) cmd_delete "${2:-}" ;;
    rollback) cmd_rollback "${2:-}" ;;
    dump-running) dump_running "${2:-/dev/stdout}" ;;
    *) echo "Usage: $0 {save <nama>|snapshot-last-save|list|delete <nama>|rollback [nama]|dump-running <file>}" >&2; exit 2 ;;
esac
