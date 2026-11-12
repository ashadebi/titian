#!/bin/sh
# TITIAN — checkpoint + rollback.
# Checkpoint = TITIK SIMPAN BERNAMA dari konfigurasi. User membuat
# beberapa titik, melihat daftarnya, lalu memilih mau balik ke titik
# yang mana. Bukan "undo satu langkah".
#
# Isi satu checkpoint (di /opt/titian/etc/checkpoints/<nama>/):
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
#   netstate/       — seluruh isi netstate (addr/managed/tuning/
#                     tuning.prev/bond/vxlan) saat titik dibuat
#   sysctl.titian (+ .prev) — sysctl global yang dikelola Titian
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
#   Sebelum restart, rollback membersihkan (prune) objek live yang
#   tidak ada di titik: interface buatan Titian yang mengendap,
#   alamat ekstra, kunci tuning ekstra, sysctl ekstra, dan route
#   statik ekstra — karena replay hanya MENAMBAH/MENGGANTI, tidak
#   menghapus. Prune bersifat best-effort per item (gagal satu item =
#   peringatan, rollback tetap jalan; kegagalan fatal hanya bila
#   service tidak kembali atau verifikasi diff gagal total).
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
OS=$(uname -s)
ROOT=${TITIAN_ROOT:-/opt/titian}
BIN=$ROOT/bin
if [ ! -x "$BIN/clish" ] && [ -x /usr/local/bin/clish ]; then BIN=/usr/local/bin; fi
SBIN=${RT_SBIN:-$ROOT/sbin}
STATE_DIR=${TITIAN_STATE_DIR:-$ROOT/etc/netstate}
CKPT_DIR=$ROOT/etc/checkpoints
SOCKFILE=/tmp/konfd.socket

err() { echo "Error: $*" >&2; exit 33; }
warn() { echo "Warning(checkpoint): $*" >&2; }

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

now_wib() { TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S WIB'; }

bird_bin() {
    command -v bird 2>/dev/null || { [ -x /usr/sbin/bird ] && echo /usr/sbin/bird; } || \
        { [ -x /usr/local/sbin/bird ] && echo /usr/local/sbin/bird; } || echo bird
}
birdc_bin() {
    command -v birdc 2>/dev/null || { [ -x /usr/sbin/birdc ] && echo /usr/sbin/birdc; } || \
        { [ -x /usr/local/sbin/birdc ] && echo /usr/local/sbin/birdc; } || echo birdc
}
bird_conf_path() {
    if [ "$OS" = "FreeBSD" ]; then echo "/usr/local/etc/bird.conf"; else echo "/etc/bird/bird.conf"; fi
}

# --- dump running-config lewat batch clish (read-only) ---
dump_running() {
    # $1=file-tujuan (ditulis penuh, bukan append)
    local tmp cmd
    tmp=$(mktemp /tmp/titian-ckpt-dump.XXXXXX) || return 1
    cmd=$(mktemp /tmp/titian-ckpt-cmd.XXXXXX) || { rm -f "$tmp"; return 1; }
    printf 'show running-config\n' > "$cmd"
    if ! "$BIN/clish" -x "$ROOT/etc/clish-en" -w enable-view "$cmd" > "$tmp" 2>&1; then
        warn "batch clish dump gagal"
        rm -f "$tmp" "$cmd"; return 1
    fi
    rm -f "$cmd"
    # buang banner sesi + baris prompt-echo; sisakan dump mulai
    # baris setelah `# show running-config`. Buang baris kosong
    # di akhir agar diff byte-persis stabil. Buang juga baris
    # stempel (metadata save, bukan konfigurasi — lihat header).
    awk '/# show running-config$/ {dump=1; next} dump {print}' "$tmp" | \
        grep -v -e '^! version' -e '^ ! last commit' -e '^! last commit' | \
        awk '{lines[NR]=$0} END {last=NR; while (last>0 && lines[last]=="") last--; for (i=1;i<=last;i++) print lines[i]}' > "$1"
    rm -f "$tmp"
    [ -s "$1" ] || return 1
    grep -q '^end$' "$1" || return 1
    return 0
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
    [ -f "$conf" ] && cp -f "$conf" "$d/bird.conf"
    mkdir -p "$d/bird.d" "$d/netstate" || return 1
    for f in "$ROOT/etc/bird.d/"*.conf; do
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
    [ -f "$ROOT/etc/sysctl.titian" ] && cp -f "$ROOT/etc/sysctl.titian" "$d/sysctl.titian"
    [ -f "$ROOT/etc/sysctl.titian.prev" ] && cp -f "$ROOT/etc/sysctl.titian.prev" "$d/sysctl.titian.prev"
    chmod 700 "$d" "$d/bird.d" "$d/netstate" 2>/dev/null || true
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
        err "gagal membuang running-config (konfd tidak terjangkau?) — checkpoint TIDAK dibuat, tidak ada perubahan"
    fi
    if ! snapshot_files "$d" "$tmp"; then
        rm -rf "$d" "$tmp"
        err "gagal memotret file state — checkpoint TIDAK dibuat, tidak ada perubahan"
    fi
    rm -f "$tmp"
    write_meta "$d" "$name" "running" || warn "gagal tulis meta (checkpoint tetap tersimpan)"
    echo "checkpoint $name dibuat: $(grep '^created_wib=' "$d/meta" 2>/dev/null | cut -d= -f2-)"
    echo "  isi: running-config + bird.conf + bird.d + netstate + sysctl (beku; 'save' biasa tidak mengubah titik ini)"
}

cmd_snapshot_last_save() {
    # Dipanggil perintah `save` (best-effort; TIDAK PERNAH gagal fatal).
    # Sumber running-config = startup-config yang baru ditulis save.
    local d="$CKPT_DIR/.last-save"
    mkdir -p "$CKPT_DIR" 2>/dev/null || { warn "gagal mkdir $CKPT_DIR"; return 0; }
    mkdir -p "$d" 2>/dev/null || { warn "gagal mkdir $d"; return 0; }
    if ! snapshot_files "$d" "$ROOT/etc/startup-config"; then
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
        echo "(belum ada checkpoint — pakai 'checkpoint save <nama>')"
        return 0
    fi
    tmp=$(mktemp /tmp/titian-ckpt-list.XXXXXX) || tmp=""
    if [ -n "$tmp" ] && ! dump_running "$tmp"; then rm -f "$tmp"; tmp=""; fi
    printf '%-24s %-22s %s\n' "NAMA" "DIBUAT (WIB)" "SAAT INI"
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
        if [ -n "$tmp" ] && [ -f "$CKPT_DIR/$name/running-config" ] && cmp -s "$CKPT_DIR/$name/running-config" "$tmp"; then
            line="*"
        fi
        printf '%-24s %-22s %s\n' "$name" "$created" "$line"
    done
    [ -n "$tmp" ] && rm -f "$tmp"
    echo "  * = isi titik sama persis dengan running-config saat ini"
}

cmd_delete() {
    local name=$1 d
    valid_name "$name" || err "nama checkpoint tidak valid: '$name'"
    d="$CKPT_DIR/$name"
    [ -d "$d" ] || err "checkpoint tidak ada: $name — tidak ada yang dihapus"
    rm -rf "$d" || err "gagal hapus checkpoint $name"
    echo "checkpoint $name dihapus"
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
    prune_sysctls "$ROOT/etc/sysctl.titian" "$d/sysctl.titian"
    # (e) interface buatan Titian yang mengendap — TERAKHIR:
    #     header seksi `interface <tipe> <nama>` di dump saat ini
    #     tapi tidak di titik
    tmpf=$(mktemp /tmp/titian-ckpt-if.XXXXXX) || return 0
    grep -E '^interface (vlan|vxlan|bonding|lagg|loopback) ' "$cur" 2>/dev/null > "$tmpf" || true
    while IFS= read -r line; do
        grep -qxF "$line" "$d/running-config" 2>/dev/null && continue
        type=$(echo "$line" | awk '{print $2}'); name=$(echo "$line" | awk '{print $3}')
        prune_iface "$name" "$type"
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
    cp -f "$d/running-config" "$ROOT/etc/startup-config" || return 1
    # MODE FILE LIVE (perbaikan 2 Nov 2026): cp FreeBSD MENULAR mode
    # sumber ke tujuan yang sudah ada (terbukti di lab: cp -f src600
    # dst644 -> dst 600), sementara file snapshot sengaja 600
    # (snapshot_files). Tanpa chmod eksplisit ini, restore membuat
    # file live 600 sehingga tidak terbaca tanpa sudo — persis yang
    # terjadi pada bird.conf + startup-config FreeBSD sesudah fitur
    # checkpoint (1 Nov 22:29). GNU cp Linux mempertahankan mode
    # tujuan, jadi chmod ini no-op di sana; tapi tetap ditulis
    # eksplisit agar restore tidak bergantung pada perilaku cp.
    # Mode live yang benar: 644 (semua saudara file di /opt/titian/etc
    # dan /usr/local/etc FreeBSD 644; startup-config Debian 644).
    # bird.conf Debian DIKECUALIKAN: normanya 640 bird:bird di dir
    # 750 (hanya via sudo) — jangan dilebarkan.
    chmod 644 "$ROOT/etc/startup-config" 2>/dev/null || true
    if [ -f "$d/bird.conf" ]; then
        cp -f "$d/bird.conf" "$conf" || return 1
        if [ "$OS" = "FreeBSD" ]; then chmod 644 "$conf" 2>/dev/null || true; fi
    fi
    if [ -d "$d/bird.d" ]; then
        for f in "$ROOT/etc/bird.d/"*.conf; do
            [ -e "$f" ] || continue
            case "$f" in *.cli-bak|*.pkgsave) continue ;; esac
            rm -f "$f"
        done
        for f in "$d/bird.d/"*.conf; do
            [ -e "$f" ] || continue
            cp -f "$f" "$ROOT/etc/bird.d/" 2>/dev/null || true
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
    if [ -f "$d/sysctl.titian" ]; then cp -f "$d/sysctl.titian" "$ROOT/etc/sysctl.titian";
    else rm -f "$ROOT/etc/sysctl.titian"; fi
    if [ -f "$d/sysctl.titian.prev" ]; then cp -f "$d/sysctl.titian.prev" "$ROOT/etc/sysctl.titian.prev";
    else rm -f "$ROOT/etc/sysctl.titian.prev"; fi
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
        [ -d "$d" ] || err "checkpoint tidak ada: $name — TIDAK ADA PERUBAHAN (buat dulu dengan 'checkpoint save $name')"
    else
        d="$CKPT_DIR/.last-save"
        [ -d "$d" ] || err "belum pernah save (tidak ada titik .last-save) — TIDAK ADA PERUBAHAN (jalankan 'save' dulu atau buat checkpoint)"
        name="(startup-config)"
    fi
    [ -f "$d/running-config" ] || err "checkpoint rusak: $d/running-config tidak ada — TIDAK ADA PERUBAHAN"
    # parse check bird.conf titik SEBELUM mengganti apa pun
    if [ -f "$d/bird.conf" ]; then
        bird=$(bird_bin)
        if ! "$bird" -p -c "$d/bird.conf" >/dev/null 2>&1; then
            err "bird.conf titik $name GAGAL parse — TIDAK ADA PERUBAHAN (titik rusak, jangan dipakai)"
        fi
    fi
    cur=$(mktemp /tmp/titian-ckpt-rb.XXXXXX) || err "gagal mktemp"
    if ! dump_running "$cur"; then
        rm -f "$cur"
        err "gagal membuang running-config saat ini (konfd tidak terjangkau?) — TIDAK ADA PERUBAHAN"
    fi
    echo "rollback ke $name — prune objek live yang tidak ada di titik..."
    prune_all "$cur" "$d"
    echo "rollback ke $name — pulihkan file (startup-config + bird + netstate + sysctl)..."
    if ! restore_files "$d"; then
        rm -f "$cur"
        err "gagal memulihkan file dari titik $name — KEADAAN MUNGKIN SETENGAH (periksa manual; titik tidak diubah)"
    fi
    regen_mirrors
    echo "rollback ke $name — restart service titian..."
    if ! service_restart; then
        rm -f "$cur"
        err "service titian TIDAK KEMBALI setelah restart — file sudah dipulihkan dari titik, tapi konfd tidak jalan (periksa log service)"
    fi
    # sysctl live dari state yang dipulihkan (boot OS tidak me-apply
    # ulang cermin titian saat restart service — apply eksplisit)
    "$SBIN/titian-sysctl.sh" apply 2>/dev/null || true
    if [ -f "$d/bird.conf" ]; then
        out=$("$(birdc_bin)" configure 2>&1); rc=$?
        echo "$out" | grep -v '^BIRD' || true
        [ "$rc" -ne 0 ] && warn "birdc configure gagal (bird.conf sudah dipulihkan + parse lolos; periksa birdc)"
    fi
    tmp=$(mktemp /tmp/titian-ckpt-rb2.XXXXXX) || tmp=""
    if [ -n "$tmp" ] && dump_running "$tmp"; then
        if cmp -s "$tmp" "$d/running-config"; then
            echo "rollback OK: running-config sama persis dengan titik $name"
        else
            echo "PERINGATAN: running-config sesudah rollback BERBEDA dari titik $name (diff di bawah):" >&2
            diff "$d/running-config" "$tmp" 2>/dev/null | head -40 >&2
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
    echo "rollback ke $name SELESAI (persistensi: startup-config sudah ditulis dari titik — bertahan melewati reboot)."
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
