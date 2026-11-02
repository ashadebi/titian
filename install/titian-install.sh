#!/bin/sh
# TITIAN Fase 1 — installer tree + service di VM lab (Debian/FreeBSD).
# Dijalankan sebagai root dari direktori sumber titian-cli/ yang sudah
# disalin ke VM (mis. /tmp/titian-cli). TIDAK menginstal klish/BIRD
# (itu langkah terpisah); skrip ini merakit tree, helper, wrapper,
# seed bird.conf, dan service boot.
# Penggunaan: ./titian-install.sh [--bindir /opt/titian/bin] [--asn <N>]
# POSIX sh.
set -u
SRC=$(cd "$(dirname "$0")/.." && pwd)
OS=$(uname -s)
ROOT=/opt/titian
BIN=$ROOT/bin
ASN=64512
while [ $# -gt 0 ]; do
    case "$1" in
        --bindir) BIN=$2; shift 2 ;;
        --asn) ASN=$2; shift 2 ;;
        *) echo "Usage: $0 [--bindir DIR] [--asn N]" >&2; exit 2 ;;
    esac
done
case "$ASN" in ''|*[!0-9]*) echo "Error: --asn harus angka" >&2; exit 2 ;; esac
if [ ! -x "$BIN/clish" ]; then
    echo "Error: clish tidak ditemukan di $BIN (build/install klish dulu)" >&2
    exit 33
fi
echo "== TITIAN install: OS=$OS SRC=$SRC BIN=$BIN =="
if [ "$OS" = "FreeBSD" ]; then
    TREE_OS="freebsd"
else
    TREE_OS="linux"
fi

# --- backup instalasi lama (bila ada) ---
# HANYA etc/ + sbin/ milik titian yang dipindah; bin/ lib/ include/
# (hasil make install klish) TIDAK BOLEH ikut pindah, kalau tidak
# clish/konfd hilang dan service gagal start (bug 28 Okt 2026).
if [ -d "$ROOT/etc" ] || [ -d "$ROOT/sbin" ]; then
    ts=$(date +%Y%m%d-%H%M%S)
    echo "-- backup etc/sbin lama -> ${ROOT}.bak-$ts"
    mkdir -p "${ROOT}.bak-$ts" || exit 33
    [ -d "$ROOT/etc" ] && mv "$ROOT/etc" "${ROOT}.bak-$ts/etc"
    [ -d "$ROOT/sbin" ] && mv "$ROOT/sbin" "${ROOT}.bak-$ts/sbin"
fi
mkdir -p "$ROOT/etc/clish-en" "$ROOT/etc/clish" "$ROOT/sbin" \
         "$ROOT/etc/db" "$ROOT/etc/bird.d" "$ROOT/etc/bird-backup" \
         "$ROOT/etc/netstate" "$ROOT/etc/checkpoints" || exit 33

# --- rakit tree root (common + per-OS; file per-OS menimpa nama sama) ---
COMMON="bird.xml common.xml conf-fw.xml conf-route6.xml conf-serv-ssh.xml conf-sys-dns.xml \
conf-sys.xml configure-mode.xml en-checkpoint.xml en-rename.xml en-show.xml en-show-hw.xml enable-mode.xml \
ping.xml startup.xml types.xml types-dev.xml types-ip6.xml"
LINUX_ONLY="conf-if-bond.xml conf-if-eth.xml conf-if-eth-opt.xml conf-if-lo.xml \
conf-if-vlan.xml conf-if-vxlan.xml conf-route.xml en-show-if-vlan.xml en-show-if-bond.xml en-show-if-vxlan.xml"
FBSD_ONLY="conf-if-eth-fbsd.xml conf-if-vlan-fbsd.xml conf-if-lagg-fbsd.xml conf-if-vxlan-fbsd.xml \
conf-if-lo-fbsd.xml conf-if-opt-fbsd.xml conf-route-fbsd.xml en-show-if-vlan-fbsd.xml en-show-if-lagg.xml en-show-if-vxlan-fbsd.xml"
for f in $COMMON; do
    cp "$SRC/tree/$f" "$ROOT/etc/clish-en/$f" || { echo "Error: copy $f" >&2; exit 33; }
done
if [ "$TREE_OS" = "freebsd" ]; then
    for f in $FBSD_ONLY; do
        cp "$SRC/tree/$f" "$ROOT/etc/clish-en/$f" || { echo "Error: copy $f" >&2; exit 33; }
    done
else
    for f in $LINUX_ONLY; do
        cp "$SRC/tree/$f" "$ROOT/etc/clish-en/$f" || { echo "Error: copy $f" >&2; exit 33; }
    done
fi
# tree non-root (subset rtcli, path sudah disesuaikan)
for f in "$SRC"/tree-nonroot/*.xml; do
    cp "$f" "$ROOT/etc/clish/" || { echo "Error: copy $f" >&2; exit 33; }
done
# sesuaikan RT_BIN literal di installed startup.xml/info-mode bila klish dari port
if [ "$BIN" != "$ROOT/bin" ]; then
    sed -i '' "s#$ROOT/bin#$BIN#g" "$ROOT/etc/clish-en/startup.xml" 2>/dev/null || \
        sed -i "s#$ROOT/bin#$BIN#g" "$ROOT/etc/clish-en/startup.xml"
    sed -i '' "s#$ROOT/bin#$BIN#g" "$ROOT/etc/clish/info-mode.xml" 2>/dev/null || \
        sed -i "s#$ROOT/bin#$BIN#g" "$ROOT/etc/clish/info-mode.xml"
fi

# --- helper sbin ---
for f in "$SRC"/sbin/titian-*.sh; do
    cp "$f" "$ROOT/sbin/" || { echo "Error: copy $f" >&2; exit 33; }
done
chmod +x "$ROOT"/sbin/*.sh
if [ "$TREE_OS" = "linux" ]; then
    for f in ether_tools.sh drivers.sh set_irq_affinity.sh udev_generator.sh; do
        [ -f "$SRC/sbin/$f" ] && cp "$SRC/sbin/$f" "$ROOT/sbin/" && chmod +x "$ROOT/sbin/$f"
    done
fi

# --- wrapper ---
cat > /usr/local/bin/titian <<EOF
#!/bin/sh
# TITIAN CLI wrapper (root -> tree clish-en, non-root -> tree clish).
ROOT=$ROOT
BIN=$BIN
if [ ! -x "\$BIN/clish" ]; then BIN=/usr/local/bin; fi
export LD_LIBRARY_PATH=\$ROOT/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:\$BIN
if [ "\$(id -u)" = "0" ]; then
    exec "\$BIN/clish" -l -x "\$ROOT/etc/clish-en" "\$@"
else
    cd /tmp 2>/dev/null || true
    exec "\$BIN/clish" -l -x "\$ROOT/etc/clish" "\$@"
fi
EOF
chmod +x /usr/local/bin/titian
ln -sf /usr/local/bin/titian /usr/local/bin/cli
# wrapper tool rekomendasi tuning (read-only; skrip di sbin)
cat > /usr/local/bin/titian-tune-recommend <<EOF
#!/bin/sh
# TITIAN tuning recommendations (read-only) — wrapper gaya titian.
exec $ROOT/sbin/titian-tune-recommend.sh "\$@"
EOF
chmod +x /usr/local/bin/titian-tune-recommend

# --- bird.d templates ---
for f in "$SRC"/bird.d/*.conf; do
    cp "$f" "$ROOT/etc/bird.d/" || { echo "Error: copy $f" >&2; exit 33; }
done

# --- seed bird.conf (backup dulu bila ada tanpa marker titian) ---
if [ "$OS" = "FreeBSD" ]; then
    BIRDCONF=/usr/local/etc/bird.conf
else
    BIRDCONF=/etc/bird/bird.conf
fi
mkdir -p "$(dirname "$BIRDCONF")"
PRIMARY=""
if [ "$OS" = "FreeBSD" ]; then
    PRIMARY=$(ifconfig 2>/dev/null | awk '/^[[:space:]]*inet / && $2 != "127.0.0.1" {print $2; exit}')
else
    PRIMARY=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
[ -n "$PRIMARY" ] || PRIMARY="192.0.2.1"
if [ -f "$BIRDCONF" ] && grep -q '#-BGP-#' "$BIRDCONF" 2>/dev/null; then
    echo "-- bird.conf sudah bermarker titian, dipertahankan: $BIRDCONF"
else
    if [ -f "$BIRDCONF" ]; then
        cp -f "$BIRDCONF" "$ROOT/etc/bird-backup/bird.conf.pre-titian"
        echo "-- backup bird.conf lama -> $ROOT/etc/bird-backup/bird.conf.pre-titian"
    fi
    cat > "$BIRDCONF" <<EOF
# TITIAN seed bird.conf — section antar marker dikelola generator
# (bird view: generate <section>); jangan edit manual antar marker.
# ASN global router ini: protocol bgp memakai "local as TITIAN_ASN;"
# (ubah angka di sini, atau install ulang dengan --asn <N>).
# Log BIRD: /var/log/bird/bird.log (rotasi: logrotate/newsyslog, simpan 3).
router id $PRIMARY;
define TITIAN_ASN = $ASN;
log "/var/log/bird/bird.log" all;
#-FUNCTION-#
#-ENDFUNCTION-#
#-FILTER-#
#-ENDFILTER-#
#-PROTOCOL-#
protocol device {
    scan time 10;
}
protocol kernel {
    ipv4 { import none; export none; };
}
protocol kernel {
    ipv6 { import none; export none; };
}
#-ENDPROTOCOL-#
#-PROTOCOL-STATIC-#
#-ENDPROTOCOL-STATIC-#
#-BGP-#
#-ENDBGP-#
#-OSPF-#
#-ENDOSPF-#
#-DIRECT-#
#-ENDDIRECT-#
#-BFD-#
#-ENDBFD-#
#-PIPE-#
#-ENDPIPE-#
EOF
    echo "-- seed bird.conf ditulis (router id $PRIMARY)"
fi

# --- upgrade header lama: tambah define TITIAN_ASN + log bila belum ada ---
# (instalasi lama sudah bermarker sehingga seed di atas dilewati.)
if ! grep -q '^define TITIAN_ASN' "$BIRDCONF" 2>/dev/null; then
    cp -f "$BIRDCONF" "$ROOT/etc/bird-backup/bird.conf.pre-asn-log" || exit 33
    awk -v asn="$ASN" '/^router id / { print; print "define TITIAN_ASN = " asn ";"; print "log \"/var/log/bird/bird.log\" all;"; next } { print }' \
        "$BIRDCONF" > "$BIRDCONF.tmp" || exit 33
    mv "$BIRDCONF.tmp" "$BIRDCONF" || exit 33
    echo "-- header bird.conf ditambah define TITIAN_ASN + log (backup: bird.conf.pre-asn-log)"
elif ! grep -q '^log "/var/log/bird/bird.log"' "$BIRDCONF" 2>/dev/null; then
    cp -f "$BIRDCONF" "$ROOT/etc/bird-backup/bird.conf.pre-asn-log" || exit 33
    awk '/^define TITIAN_ASN/ { print; print "log \"/var/log/bird/bird.log\" all;"; next } { print }' \
        "$BIRDCONF" > "$BIRDCONF.tmp" || exit 33
    mv "$BIRDCONF.tmp" "$BIRDCONF" || exit 33
    echo "-- header bird.conf ditambah log (backup: bird.conf.pre-asn-log)"
fi

# --- direktori log + rotasi (default: harian, simpan 3 arsip gzip) ---
mkdir -p /var/log/bird || exit 33
if [ "$TREE_OS" = "freebsd" ]; then
    chown root:wheel /var/log/bird 2>/dev/null || true
    chmod 0755 /var/log/bird
    mkdir -p /usr/local/etc/newsyslog.conf.d
    cp "$SRC/install/newsyslog/titian-bird.conf" /usr/local/etc/newsyslog.conf.d/titian-bird.conf \
        || echo "-- PERINGATAN: gagal pasang newsyslog titian-bird" >&2
    cp "$SRC/install/newsyslog/titian-bird-reopen" /usr/local/sbin/titian-bird-reopen \
        || echo "-- PERINGATAN: gagal pasang titian-bird-reopen" >&2
    chmod +x /usr/local/sbin/titian-bird-reopen 2>/dev/null || true
else
    if id bird >/dev/null 2>&1; then chown bird:bird /var/log/bird; fi
    chmod 0755 /var/log/bird
    if command -v logrotate >/dev/null 2>&1; then
        cp "$SRC/install/logrotate/titian-bird" /etc/logrotate.d/titian-bird \
            || echo "-- PERINGATAN: gagal pasang logrotate titian-bird" >&2
    else
        echo "-- PERINGATAN: logrotate tidak terpasang; pasang dulu (apt-get install logrotate) lalu salin install/logrotate/titian-bird ke /etc/logrotate.d/" >&2
    fi
fi

# --- parse-check seed ---
BIRDBIN=$(command -v bird || echo "")
[ -n "$BIRDBIN" ] || { [ -x /usr/sbin/bird ] && BIRDBIN=/usr/sbin/bird; } || \
    { [ -x /usr/local/sbin/bird ] && BIRDBIN=/usr/local/sbin/bird; }
if [ -n "$BIRDBIN" ] && [ -x "$BIRDBIN" ]; then
    "$BIRDBIN" -p -c "$BIRDCONF" || { echo "Error: seed bird.conf gagal parse" >&2; exit 33; }
    echo "-- seed bird.conf lolos parse"
else
    echo "-- PERINGATAN: biner bird tidak ditemukan, parse-check dilewati"
fi

# --- service boot ---
if [ "$TREE_OS" = "freebsd" ]; then
    cat > /usr/local/etc/rc.d/titian <<'EOS'
#!/bin/sh
# PROVIDE: titian
# REQUIRE: DAEMON
# KEYWORD: shutdown
. /etc/rc.subr
name="titian"
rcvar="titian_enable"
pidfile="/var/run/titian-konfd.pid"
procname="/opt/titian/bin/konfd"
command="/opt/titian/sbin/titian-boot.sh"
start_cmd="titian_start"
stop_cmd="titian_stop"
titian_start() {
    /opt/titian/sbin/titian-boot.sh
}
titian_stop() {
    if [ -f /var/run/titian-konfd.pid ]; then
        kill "$(cat /var/run/titian-konfd.pid)" 2>/dev/null || true
        rm -f /var/run/titian-konfd.pid /tmp/konfd.socket
    else
        pkill -f '/opt/titian/bin/konfd|/usr/local/bin/konfd' 2>/dev/null || true
        rm -f /tmp/konfd.socket
    fi
}
load_rc_config $name
run_rc_command "$1"
EOS
    chmod +x /usr/local/etc/rc.d/titian
    if command -v sysrc >/dev/null 2>&1; then
        sysrc titian_enable=YES
    # BIRD daemon: titian bird-view butuh birdc configure -> daemon harus jalan
    grep -q '^bird_enable=' /etc/rc.conf 2>/dev/null || echo 'bird_enable="YES"' >> /etc/rc.conf >/dev/null
    else
        grep -q '^titian_enable=' /etc/rc.conf 2>/dev/null || echo 'titian_enable="YES"' >> /etc/rc.conf
    fi
    echo "-- rc script titian terpasang + enabled"
else
    cat > /etc/systemd/system/titian.service <<'EOS'
[Unit]
Description=Titian CLI (klish konfd + startup-config replay)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/titian/sbin/titian-boot.sh
ExecStop=/bin/sh -c 'if [ -f /var/run/titian-konfd.pid ]; then kill $(cat /var/run/titian-konfd.pid) 2>/dev/null || true; rm -f /var/run/titian-konfd.pid /tmp/konfd.socket; fi'
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOS
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl enable titian.service >/dev/null 2>&1 || true
        echo "-- systemd unit titian terpasang + enabled"
    fi
fi

# --- mulai service + verifikasi parse tree ---
if [ "$TREE_OS" = "freebsd" ]; then
    service titian start 2>&1 || /opt/titian/sbin/titian-boot.sh 2>&1
else
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start titian.service 2>&1 || /opt/titian/sbin/titian-boot.sh 2>&1
    else
        /opt/titian/sbin/titian-boot.sh 2>&1
    fi
fi
sleep 1
if [ -S /tmp/konfd.socket ]; then
    echo "-- konfd socket OK: /tmp/konfd.socket"
else
    echo "-- PERINGATAN: socket konfd tidak ditemukan (cek /var/log/titian-konfd.log)"
fi
printf 'help\n' > /tmp/titian-parse-test.cmd
if "$BIN/clish" -x "$ROOT/etc/clish-en" -w enable-view /tmp/titian-parse-test.cmd 2>&1 | head -20; then
    echo "-- tree parse check selesai (lihat output help di atas)"
fi
echo "== TITIAN install selesai =="
