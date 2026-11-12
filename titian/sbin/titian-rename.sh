#!/bin/sh
# TITIAN — rename interface sistem + migrasi state Titian (Linux + FreeBSD).
# Dipanggil perintah exec `rename <lama> <baru>` (tree/en-rename.xml).
#
# PERSISTEN (seperti rollback, bukan sekadar live): startup-config
# ditulis ulang (section + referensi nama) + aturan boot ditulis
# (Linux: berkas .link berdasarkan MAC; FreeBSD: baris
# ifconfig_<asal>_name di blok #-TITIAN-RENAME-# rc.conf), lalu
# restart service titian (replay startup-config baru). Sesi CLI yang
# menjalankan rename ikut ter-restart (pola yang sama seperti
# rollback) — sambung lagi lalu verifikasi dengan `show interfaces`
# / `show running-config`. Baris pra-restart dicatat di
# /var/log/titian-rename.log.
#
# ATURAN AMAN (ditolak lantang, tanpa perubahan):
#  - nama lama tidak ada di sistem; nama baru sudah dipakai sistem;
#  - nama gagal charset IFACE_SYS (huruf/angka/_ di awal, lalu
#    huruf/angka/_/./-, maks 15 karakter — sama dengan PTYPE);
#  - nama lama == nama baru;
#  - objek buatan Titian (bond[N]/vxlan[N]/lagg[N]/vlan[N]) dan
#    loopback (lo/lo0/lo[N]): rename HANYA untuk interface SISTEM.
#    Objek Titian di-rename dengan menghapus + membuat ulang
#    (namanya kunci bookkeeping netstate/cermin/replay); loopback
#    clone dihapus + dibuat ulang. Nama bertitik (perangkat vlan
#    Linux) ditolak dengan alasan yang sama.
#  - startup-config tidak ada (jalankan `save` dulu — rename butuh
#    baseline persistensi untuk ditulis ulang).
#
# YANG DIIZINKAN (siklus down -> rename -> kembalikan state admin):
#  - interface UP membawa alamat: alamat + route melekat ke ifindex
#    (kernel), sehingga selamat dari rename; helper memverifikasi
#    sesudah restart. Interupsi sesaat (down/up) adalah konsekuensi
#    yang didokumentasikan — JANGAN rename interface yang sedang
#    membawa traffic mgmt/produksi. Perintah ini tidak tahu interface
#    mana yang mgmt; itu tanggung jawab operator.
#  - slave bond / member lagg / parent vlan: keanggotaan kernel
#    melekat ke ifindex (selamat); referensi nama di startup-config
#    (section + laggport + parent vlan FreeBSD + route dev + vxlan
#    group dev) ditulis ulang.
#
# ASIMETRI YANG DISENGAJA (didokumentasikan, bukan bug):
#  - Linux: nama perangkat vlan (<parent>.<tag>) TIDAK mengikuti
#    rename parent (perangkat vlan menyimpan link ke parent lewat
#    ifindex, bukan nama). Section vlan Linux tidak diubah.
#  - FreeBSD: section `interface vlan <id> <parent>` token parent-nya
#    ditulis ulang (parent eksplisit di konfigurasi).
#  - Objek runtime (dummy/epair/vlan/lo-clone) tidak bertahan
#    melewati reboot — rename-nya pun hilang bersama objeknya (nama
#    kembali ke penamaan sistem saat objek dibuat ulang). State
#    Titian yang mengendap untuk interface yang sudah hilang
#    DIABAIKAN apply-all (apply_iface melewati interface yang tidak
#    ada) — tidak merusak boot. Objek persisten (NIC nyata, MAC
#    stabil) + aturan boot di atas = rename bertahan melewati reboot.
#  - Checkpoint lama TIDAK ditulis ulang (titik beku): rollback ke
#    titik pra-rename mengembalikan nama lama — itu perilaku yang
#    benar untuk sebuah titik simpan.
#  - bird.conf TIDAK disentuh (pola interface di bird, bila ada,
#    adalah glob, bukan referensi nama — di luar cakupan rename).
# POSIX sh.
ROOT=${TITIAN_ROOT:-/opt/titian}
STATE_ROOT=${TITIAN_STATE_ROOT:-/etc/titian}
STATE_DIR=$STATE_ROOT/netstate
STARTUP=$STATE_ROOT/startup-config
SBIN=$ROOT/sbin
SOCKFILE=/tmp/konfd.socket
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:$PATH
OS=$(uname -s)

err() { printf 'Error: %s\n' "$*" >&2; exit 33; }
warn() { printf 'peringatan: %s\n' "$*" >&2; }

iface_exists() {
    if [ "$OS" = "FreeBSD" ]; then ifconfig "$1" >/dev/null 2>&1;
    else [ -d "/sys/class/net/$1" ]; fi
}

admin_up() {
    _f=$( (if [ "$OS" = "FreeBSD" ]; then ifconfig "$1"; else ip link show dev "$1"; fi) 2>/dev/null | head -1 | sed -n 's/.*<\([^>]*\)>.*/\1/p')
    case ",$_f," in *,UP,*) return 0 ;; *) return 1 ;; esac
}

iface_down() {
    if [ "$OS" = "FreeBSD" ]; then ifconfig "$1" down 2>/dev/null || true;
    else ip link set dev "$1" down 2>/dev/null || true; fi
}

iface_up() {
    if [ "$OS" = "FreeBSD" ]; then ifconfig "$1" up 2>/dev/null || true;
    else ip link set dev "$1" up 2>/dev/null || true; fi
}

# charset IFACE_SYS (tree/types-dev.xml): awal huruf/angka/underscore,
# lalu huruf/angka/underscore/titik/strip, total maks 15 karakter.
valid_name() {
    expr "$1" : '^[A-Za-z0-9_][A-Za-z0-9_.-]\{0,14\}$' >/dev/null 2>&1
}

# Objek buatan Titian + loopback + nama bertitik: bukan sasaran rename.
is_object_or_loopback() {
    case "$1" in *.*) return 0 ;; esac
    expr "$1" : '^bond[0-9][0-9]*$' >/dev/null 2>&1 && return 0
    expr "$1" : '^vxlan[0-9][0-9]*$' >/dev/null 2>&1 && return 0
    expr "$1" : '^lagg[0-9][0-9]*$' >/dev/null 2>&1 && return 0
    expr "$1" : '^vlan[0-9][0-9]*$' >/dev/null 2>&1 && return 0
    expr "$1" : '^lo[0-9]*$' >/dev/null 2>&1 && return 0
    return 1
}

# --- tulis ulang startup-config (awk; field-exact, baris lain verbatim) ---
# Aturan: section ethernet; section vlan FreeBSD (NF==4, token parent);
# laggport; route dev (ip/ipv6); vxlan group dev. Section vlan Linux
# (NF==3, nama perangkat) SENGAJA tidak diubah (lihat header).
rewrite_startup() {
    # $1=in $2=out $3=old $4=new
    awk -v old="$3" -v new="$4" '
    {
        line=$0
        match($0, /^ */)
        lead=substr($0, 1, RLENGTH)
        if ($1=="interface" && $2=="ethernet" && $3==old) { $3=new; print lead $0; next }
        if ($1=="interface" && $2=="vlan" && NF==4 && $4==old) { $4=new; print lead $0; next }
        if ($1=="laggport" && $2==old) { $2=new; print lead $0; next }
        if (($1=="ip" || $1=="ipv6") && $2=="route" && $(NF-1)=="dev" && $NF==old) { $NF=new; print lead $0; next }
        if ($1=="group" && $(NF-1)=="dev" && $NF==old) { $NF=new; print lead $0; next }
        print line
    }' "$1" > "$2" || return 1
    return 0
}

count_matches() {
    # $1=file $2=old: hitung baris yang akan ditulis ulang (self-check)
    awk -v old="$2" '
    ($1=="interface" && $2=="ethernet" && $3==old) { c++ }
    ($1=="interface" && $2=="vlan" && NF==4 && $4==old) { c++ }
    ($1=="laggport" && $2==old) { c++ }
    (($1=="ip" || $1=="ipv6") && $2=="route" && $(NF-1)=="dev" && $NF==old) { c++ }
    ($1=="group" && $(NF-1)=="dev" && $NF==old) { c++ }
    END { print c+0 }' "$1"
}

# --- aturan persistensi FreeBSD: blok #-TITIAN-RENAME-# di rc.conf ---
# Baris: ifconfig_<asal>_name="<kini>". Aturan yang nilai kini-nya ==
# nama lama diperbarui (atau dihapus bila nama baru == asal); bila
# tidak ada aturan untuk nama lama, aturan baru ditambahkan.
write_persist_freebsd() {
    # $1=old $2=new
    _rc=/etc/rc.conf
    [ -f "$_rc" ] || return 1
    _tmp=$(mktemp /tmp/titian-rename-rc.XXXXXX) || return 1
    awk -v old="$1" -v new="$2" '
    /^#-TITIAN-RENAME-#/ { inb=1; seen=1; print; next }
    /^#-ENDTITIAN-RENAME-#/ {
        if (!found) printf "ifconfig_%s_name=\"%s\"\n", old, new
        inb=0; print; next
    }
    inb && /^ifconfig_.*_name=".*"$/ {
        cur=$0; sub(/^.*_name="/, "", cur); sub(/"$/, "", cur)
        orig=$0; sub(/^ifconfig_/, "", orig)
        suffix="_name=\"" cur "\""
        orig=substr(orig, 1, length(orig)-length(suffix))
        if (cur==old) {
            found=1
            if (new!=orig) printf "ifconfig_%s_name=\"%s\"\n", orig, new
            next
        }
        print; next
    }
    { print }
    END {
        if (!seen) {
            print "#-TITIAN-RENAME-#"
            printf "ifconfig_%s_name=\"%s\"\n", old, new
            print "#-ENDTITIAN-RENAME-#"
        }
    }' "$_rc" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    _mode=$(stat -f %Lp "$_rc" 2>/dev/null || echo 644)
    chmod "$_mode" "$_tmp" 2>/dev/null || true
    cp "$_tmp" "$_rc" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    chmod "$_mode" "$_rc" 2>/dev/null || true
    rm -f "$_tmp"
    return 0
}

write_persist_linux() {
    # $1=old $2=new
    _mac=$(cat "/sys/class/net/$2/address" 2>/dev/null)
    [ -n "$_mac" ] || return 1
    mkdir -p /etc/systemd/network 2>/dev/null || return 1
    rm -f "/etc/systemd/network/10-titian-rename-$1.link" 2>/dev/null
    {
        echo "[Match]"
        echo "MACAddress=$_mac"
        echo ""
        echo "[Link]"
        echo "Name=$2"
    } > "/etc/systemd/network/10-titian-rename-$2.link" || return 1
    chmod 644 "/etc/systemd/network/10-titian-rename-$2.link" 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    return 0
}

# --- rollback pra-restart: kembalikan OS + netstate + startup + rc ---
# Dipanggil HANYA untuk kegagalan sesudah rename OS (sebelum restart).
# Variabel global: old, new, was_up, bak, rcbak, linkbak, persist_done.
fail_rollback() {
    echo "Failed: $1 — mengembalikan keadaan (tanpa perubahan Titian)..." >&2
    if iface_exists "$new"; then
        if [ "$OS" = "FreeBSD" ]; then ifconfig "$new" name "$old" 2>/dev/null || true;
        else ip link set dev "$new" name "$old" 2>/dev/null || true; fi
    fi
    if [ "$was_up" = "1" ] && iface_exists "$old"; then iface_up "$old"; fi
    for _f in "$STATE_DIR/$new".*; do
        [ -e "$_f" ] || continue
        _b=${_f##*/}; _r=${_b#$new.}
        mv "$_f" "$STATE_DIR/$old.$_r" 2>/dev/null || true
    done
    if [ -n "$bak" ] && [ -f "$bak" ]; then
        cp "$bak" "$STARTUP" 2>/dev/null || true
        chmod 644 "$STARTUP" 2>/dev/null || true
    fi
    if [ "$OS" = "FreeBSD" ]; then
        [ -n "$rcbak" ] && [ -f "$rcbak" ] && cp "$rcbak" /etc/rc.conf 2>/dev/null || true
    else
        rm -f "/etc/systemd/network/10-titian-rename-$new.link" 2>/dev/null
        [ -n "$linkbak" ] && [ -f "$linkbak" ] && cp "$linkbak" "/etc/systemd/network/10-titian-rename-$old.link" 2>/dev/null || true
    fi
    exit 33
}

# ================= main =================
[ $# -eq 2 ] || err "pakai: rename <lama> <baru>"
old=$1; new=$2
[ "$old" != "$new" ] || err "nama lama dan nama baru sama ($old) — tidak ada yang diubah"
valid_name "$old" || err "nama lama '$old' bukan nama interface yang sah (charset IFACE_SYS)"
valid_name "$new" || err "nama baru '$new' bukan nama interface yang sah (charset IFACE_SYS: huruf/angka/_ di awal, lalu huruf/angka/_/./-, maks 15 karakter)"
is_object_or_loopback "$old" && err "rename menolak '$old' (objek Titian bond/vxlan/lagg/vlan, loopback, atau nama bertitik) — hapus + buat ulang, bukan rename"
is_object_or_loopback "$new" && err "nama baru '$new' bertabrakan dengan namespace objek Titian/loopback (bond/vxlan/lagg/vlan/lo) atau mengandung titik — pilih nama lain"
iface_exists "$old" || err "interface $old tidak ditemukan di sistem (lihat 'show interfaces' untuk daftar)"
iface_exists "$new" && err "nama baru '$new' sudah dipakai sistem — pilih nama lain"
[ -f "$STARTUP" ] || err "startup-config tidak ada — jalankan 'save' dulu (rename butuh baseline persistensi)"

# Cegah kehilangan state live yang belum di-save pada interface yang
# di-rename: restart sesudah rename me-replay startup-config, jadi
# state live-only (netstate non-kosong tapi tidak ada section /
# referensi di startup-config) akan hilang + meninggalkan netstate /
# cermin yatim. Tolak lantang dengan perintah 'save' dulu.
# (State live interface LAIN juga hilang saat restart — itu semantik
# restart Titian secara umum, didokumentasikan di help; tidak ditolak
# di sini karena deteksinya butuh dump running-config dari dalam
# ACTION, yang berisiko deadlock kunci konfd.)
if [ -s "$STATE_DIR/$old.addr" ] || [ -s "$STATE_DIR/$old.tuning" ]; then
    if [ "$(count_matches "$STARTUP" "$old")" = "0" ]; then
        err "interface $old punya state Titian (.addr/.tuning non-kosong) tapi tidak ada section/referensi di startup-config — kemungkinan konfigurasi live yang belum di-save (restart sesudah rename akan menghilangkannya). Jalankan 'save' dulu bila state masih live (bila state yatim, terapkan ulang di view lalu 'save'), baru 'rename'."
    fi
fi

# Backup (untuk fail_rollback) + hitung + tulis ulang startup ke temp
# SEBELUM mutasi apa pun (rewrite gagal = tanpa perubahan).
bak=$(mktemp /tmp/titian-rename-startup.XXXXXX) || err "gagal mktemp"
cp "$STARTUP" "$bak" 2>/dev/null || err "gagal membackup startup-config"
rcbak=""; linkbak=""
if [ "$OS" = "FreeBSD" ]; then
    rcbak=$(mktemp /tmp/titian-rename-rcbak.XXXXXX) 2>/dev/null || true
    [ -n "$rcbak" ] && cp /etc/rc.conf "$rcbak" 2>/dev/null || true
else
    if [ -f "/etc/systemd/network/10-titian-rename-$old.link" ]; then
        linkbak=$(mktemp /tmp/titian-rename-linkbak.XXXXXX) 2>/dev/null || true
        [ -n "$linkbak" ] && cp "/etc/systemd/network/10-titian-rename-$old.link" "$linkbak" 2>/dev/null || true
    fi
fi
tmpnew=$(mktemp /tmp/titian-rename-new.XXXXXX) || err "gagal mktemp"
rewrite_startup "$STARTUP" "$tmpnew" "$old" "$new" || err "gagal menulis ulang startup-config (tanpa perubahan)"
[ -s "$tmpnew" ] || err "hasil tulis ulang startup-config kosong (tanpa perubahan)"
matches=$(count_matches "$STARTUP" "$old")
if [ "$matches" = "0" ]; then
    cmp -s "$tmpnew" "$STARTUP" || err "self-check rewrite gagal (tanpa perubahan)"
    echo "note: $old not punya section/referensi at startup-config (tanpa state Titian) — rename OS + aturan boot saja"
else
    echo "tulis ulang startup-config: $matches baris section/referensi $old -> $new"
fi

# Siklus down -> rename -> kembalikan state admin (uniform kedua OS).
if admin_up "$old"; then was_up=1; else was_up=0; fi
[ "$was_up" = "1" ] && iface_down "$old"
if [ "$OS" = "FreeBSD" ]; then
    ifconfig "$old" name "$new" 2>/dev/null || {
        [ "$was_up" = "1" ] && iface_up "$old"
        err "gagal rename OS $old -> $new (tanpa perubahan Titian)"
    }
else
    ip link set dev "$old" name "$new" 2>/dev/null || {
        [ "$was_up" = "1" ] && iface_up "$old"
        err "gagal rename OS $old -> $new (tanpa perubahan Titian)"
    }
fi
[ "$was_up" = "1" ] && iface_up "$new"
iface_exists "$new" || fail_rollback "rename OS dilaporkan sukses tapi $new tidak ditemukan"
echo "rename OS: $old -> $new (state admin dikembalikan: $([ "$was_up" = "1" ] && echo up || echo down))"

# Pindah netstate keyed by name (semua <old>.* -> <new>.*).
for _f in "$STATE_DIR/$old".*; do
    [ -e "$_f" ] || continue
    _b=${_f##*/}; _r=${_b#$old.}
    mv "$_f" "$STATE_DIR/$new.$_r" 2>/dev/null || fail_rollback "gagal memindah netstate $_f"
done

# Pasang startup-config baru (mode eksplisit — pelajaran mode FreeBSD:
# cp menularkan mode sumber; sumber di-chmod 644 dulu + chmod sesudah).
chmod 644 "$tmpnew" 2>/dev/null || true
cp "$tmpnew" "$STARTUP" 2>/dev/null || fail_rollback "gagal memasang startup-config baru"
chmod 644 "$STARTUP" 2>/dev/null || true
echo "startup-config ditulis ulang ($old -> $new)"

# Aturan persistensi boot.
if [ "$OS" = "FreeBSD" ]; then
    write_persist_freebsd "$old" "$new" || fail_rollback "gagal menulis aturan rename di rc.conf"
    echo "aturan boot FreeBSD: ifconfig_<asal>_name=\"$new\" (blok #-TITIAN-RENAME-# rc.conf)"
else
    write_persist_linux "$old" "$new" || fail_rollback "gagal menulis berkas .link persistensi"
    echo "aturan boot Linux: /etc/systemd/network/10-titian-rename-$new.link (match MAC)"
fi

# Cermin: regenerasi untuk nama baru, hapus untuk nama lama
# (best-effort — replay sesudah restart meregenerasi cermin baru).
"$SBIN/titian-persist.sh" sync-if "$new" 2>/dev/null || warn "sync-if $new gagal (replay sesudah restart meregenerasi cermin)"
"$SBIN/titian-persist.sh" drop-if "$old" 2>/dev/null || warn "drop-if $old gagal (cermin lama mungkin mengendap)"

# Restart service (pola rollback) — sesi CLI terputus sesaat.
echo "rename $old -> $new — restart service titian (sesi CLI terputus sesaat; sambung lagi lalu check 'show interfaces')..."
echo "$(date '+%Y-%m-%d %H:%M:%S %Z') rename $old -> $new (restart issued)" >> /var/log/titian-rename.log 2>/dev/null || true
if [ "$OS" = "FreeBSD" ]; then
    service titian restart 2>&1 || err "restart service GAGAL — state sudah PERSISTEN-baru (startup-config + netstate + aturan boot untuk $new); perbaiki service (start akan me-replay config baru), lalu verifikasi dengan 'show interfaces'"
else
    systemctl restart titian 2>&1 || err "restart service GAGAL — state sudah PERSISTEN-baru (startup-config + netstate + aturan boot untuk $new); perbaiki service (start akan me-replay config baru), lalu verifikasi dengan 'show interfaces'"
fi
i=0
while [ ! -S "$SOCKFILE" ] && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
rm -f "$bak" "$rcbak" "$linkbak" "$tmpnew" 2>/dev/null || true
if iface_exists "$new" && ! iface_exists "$old"; then
    echo "rename OK: $old -> $new (system + startup-config + netstate + aturan boot; verifikasi lengkap: 'show interfaces' + 'show running-config')"
else
    warn "verifikasi pasca-restart tidak keduanya benar ($new ada / $old hilang) — periksa 'show interfaces' + 'show running-config'"
fi
exit 0
