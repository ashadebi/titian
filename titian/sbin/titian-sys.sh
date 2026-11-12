#!/bin/sh
# TITIAN Fase 1 — perintah system/service/ssh/show-hw (cabang OS).
# POSIX sh.
OS=$(uname -s)
BIN=${TITIAN_BIN:-/opt/titian/bin}
err() { echo "Error: $*" >&2; exit 33; }

# Portable in-place sed: BSD sed -i wajib arg backup, GNU sed tidak.
sys_sed_i() {
    # $1=file $2=script
    if [ "$OS" = "FreeBSD" ]; then
        sed -i '' "$2" "$1"
    else
        sed -i "$2" "$1"
    fi
}
sys_sed_del_blank() {
    # $1=file
    if [ "$OS" = "FreeBSD" ]; then
        sed -i '' '/^$/d' "$1"
    else
        sed -i '/^$/d' "$1"
    fi
}
# Mode DNS stub: /etc/resolv.conf symlink + systemd-resolved aktif.
# Di mode ini symlink stub TIDAK BOLEH dirusak (sed -i mengganti symlink
# jadi file reguler); konfigurasi ditulis ke drop-in resolved.
dns_stub_mode() {
    [ -L /etc/resolv.conf ] && [ "$OS" != "FreeBSD" ] && \
        command -v systemctl >/dev/null 2>&1 && \
        systemctl is-active --quiet systemd-resolved 2>/dev/null
}
dns_dropin() { printf '%s' "/etc/systemd/resolved.conf.d/titian.conf"; }
dns_dropin_ensure() {
    mkdir -p /etc/systemd/resolved.conf.d
    if [ ! -f "$(dns_dropin)" ]; then
        printf '[Resolve]\n' > "$(dns_dropin)"
    elif ! grep -q '^\[Resolve\]' "$(dns_dropin)" 2>/dev/null; then
        { printf '[Resolve]\n'; cat "$(dns_dropin)"; } > "$(dns_dropin).tmp" && \
            mv "$(dns_dropin).tmp" "$(dns_dropin)"
    fi
}
dns_dropin_restart() {
    systemctl restart systemd-resolved 2>/dev/null || true
}

case "${1:-}" in
    hostname)
        # $2 = nama baru
        [ -n "${2:-}" ] || err "hostname kosong"
        hostname "$2" || err "gagal set hostname"
        if [ "$OS" = "FreeBSD" ]; then
            if command -v sysrc >/dev/null 2>&1; then
                sysrc hostname="$2" >/dev/null || true
            else
                grep -q '^hostname=' /etc/rc.conf 2>/dev/null && \
                    sed -i '' "s|^hostname=.*|hostname=\"$2\"|" /etc/rc.conf || \
                    echo "hostname=\"$2\"" >> /etc/rc.conf
            fi
        else
            echo "$2" > /etc/hostname 2>/dev/null || true
        fi
        sed -i "s|^127\.0\.0\.1.*$|127.0.0.1 localhost $2|" /etc/hosts 2>/dev/null || true
        ;;
    timezone)
        # $2 = Asia/Jakarta | Asia/Makassar | UTC (sesuai tree)
        [ -n "${2:-}" ] || err "timezone kosong"
        if [ ! -f "/usr/share/zoneinfo/$2" ]; then
            err "timezone tidak dikenal: $2"
        fi
        ln -sf "/usr/share/zoneinfo/$2" /etc/localtime || err "gagal set localtime"
        if [ "$OS" != "FreeBSD" ]; then
            echo "$2" > /etc/timezone 2>/dev/null || true
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart rsyslog 2>/dev/null || true
            fi
        fi
        ;;
    ssh-check)
        if [ ! -x /usr/sbin/sshd ]; then
            err "[openssh-server] tidak ditemukan"
        fi
        if [ -f /etc/ssh/sshd_config ] && [ ! -f /etc/ssh/sshd_config-save-titian ]; then
            cp -f /etc/ssh/sshd_config /etc/ssh/sshd_config-save-titian
        fi
        ;;
    ssh-restart)
        if [ "$OS" = "FreeBSD" ]; then
            service sshd restart || err "gagal restart sshd"
        else
            if command -v systemctl >/dev/null 2>&1; then
                # Reset rate-limit systemd (default StartLimitBurst=5/10s):
                # rentetan perubahan ssh via CLI tidak boleh membuat sshd
                # wedge dalam status start-limit-hit.
                systemctl reset-failed ssh sshd 2>/dev/null || true
                systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || err "gagal restart ssh"
            else
                service ssh restart 2>/dev/null || err "gagal restart ssh"
            fi
        fi
        ;;
    port-in-use)
        # $2 = port; gagal (33) bila dipakai proses selain sshd
        port=$2
        if [ "$OS" = "FreeBSD" ]; then
            if command -v sockstat >/dev/null 2>&1; then
                other=$(sockstat -l 2>/dev/null | awk -v p=":$port" '$6 ~ p"$" && $1 != "root" {print} $6 ~ p"$" && $0 !~ /sshd/ {print}')
                if [ -n "$other" ]; then
                    echo "Port: $port already in Use.." >&2; exit 33
                fi
            fi
        else
            if command -v ss >/dev/null 2>&1; then
                if ss -ltnp 2>/dev/null | grep -q ":$port "; then
                    if ! ss -ltnp 2>/dev/null | grep ":$port " | grep -q sshd; then
                        echo "Port: $port already in Use.." >&2; exit 33
                    fi
                fi
            elif command -v lsof >/dev/null 2>&1; then
                if lsof -i:"$port" 2>/dev/null | grep -qv '^sshd'; then
                    if lsof -i:"$port" 2>/dev/null | grep -q .; then
                        echo "Port: $port already in Use.." >&2; exit 33
                    fi
                fi
            fi
        fi
        ;;
    services)
        if [ "$OS" = "FreeBSD" ]; then
            service -e 2>/dev/null || service -l 2>/dev/null || err "tidak bisa daftar service"
        else
            if [ -x "$BIN/sigexec" ]; then
                "$BIN/sigexec" service --status-all 2>/dev/null || service --status-all
            else
                service --status-all
            fi
        fi
        ;;
    service-status)
        if [ "$OS" = "FreeBSD" ]; then
            service "$2" status
        else
            if [ -x "$BIN/sigexec" ]; then
                "$BIN/sigexec" service "$2" status 2>/dev/null || service "$2" status
            else
                service "$2" status
            fi
        fi
        ;;
    process)
        if [ "$OS" = "FreeBSD" ]; then
            ps aux | grep -v -E 'cli|klish|ps aux|agetty'
        else
            ps axf | grep -v -E 'cli|kli|klish|ps axf|agetty'
        fi
        ;;
    memory)
        if [ "$OS" = "FreeBSD" ]; then
            sysctl hw.physmem hw.usermem 2>/dev/null
            vmstat -s 2>/dev/null | head -8
        else
            free -h
        fi
        ;;
    cpu)
        if [ "$OS" = "FreeBSD" ]; then
            sysctl hw.model hw.ncpu hw.machine 2>/dev/null
        else
            if command -v lscpu >/dev/null 2>&1; then lscpu; else grep -m1 'model name' /proc/cpuinfo; fi
        fi
        ;;
    pci)
        if [ "$OS" = "FreeBSD" ]; then
            pciconf -lv 2>/dev/null || echo "pciconf tidak tersedia"
        else
            if command -v lspci >/dev/null 2>&1; then lspci; else echo "lspci tidak tersedia (paket pciutils)"; fi
        fi
        ;;
    dmi)
        if command -v dmidecode >/dev/null 2>&1; then
            dmidecode 2>/dev/null | head -60
        else
            echo "dmidecode not tersedia (Debian: apt install dmidecode; FreeBSD: pkg install dmidecode)"
        fi
        ;;
    connections)
        if [ "$OS" = "FreeBSD" ]; then
            netstat -an 2>/dev/null
        else
            if command -v ss >/dev/null 2>&1; then ss -tunap 2>/dev/null; elif command -v netstat >/dev/null 2>&1; then netstat -en; else echo "ss/netstat tidak tersedia"; fi
        fi
        ;;
    summary)
        # Ringkasan sistem lengkap untuk `show system` (OS, kernel, versi, hw ringkas).
        # Label 14 kolom + ": " supaya titik dua lurus.
        printf "\n"
        printf "Hostname......: %s\n" "$(hostname 2>/dev/null)"
        if [ "$OS" = "FreeBSD" ]; then
            printf "OS............: FreeBSD %s\n" "$(freebsd-version 2>/dev/null || echo "?")"
        else
            pretty=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')
            [ -n "$pretty" ] || pretty="Linux (os-release tidak ditemukan)"
            printf "OS............: %s\n" "$pretty"
        fi
        printf "Kernel........: %s\n" "$(uname -r 2>/dev/null)"
        printf "Kernel build..: %s\n" "$(uname -v 2>/dev/null)"
        printf "Arsitektur....: %s\n" "$(uname -m 2>/dev/null)"
        printf "Waktu system..: %s\n" "$(date 2>/dev/null)"
        printf "Waktu WIB.....: %s\n" "$(TZ=Asia/Jakarta date 2>/dev/null)"
        if [ "$OS" = "FreeBSD" ]; then
            printf "Uptime........: %s\n" "$(uptime 2>/dev/null | sed 's/^ *//')"
            printf "CPU...........: %s (%s CPU)\n" "$(sysctl -n hw.model 2>/dev/null)" "$(sysctl -n hw.ncpu 2>/dev/null)"
            phys=$(sysctl -n hw.physmem 2>/dev/null); user=$(sysctl -n hw.usermem 2>/dev/null)
            if [ -n "$phys" ] && [ -n "$user" ]; then
                printf "Memori........: %s MB terpakai / %s MB total\n" "$(( (phys - user) / 1024 / 1024 ))" "$(( phys / 1024 / 1024 ))"
            fi
            sysctl -n vm.loadavg 2>/dev/null | awk '{printf "Beban CPU.....: %s %s %s\n", $2, $3, $4}'
        else
            printf "Uptime........: %s\n" "$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
            model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //')
            printf "CPU...........: %s (%s CPU)\n" "$model" "$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
            free -m 2>/dev/null | awk 'NR==2{printf "Memori........: %s MB terpakai / %s MB total\n", $3, $2}'
            awk '{printf "Beban CPU.....: %s %s %s\n", $1, $2, $3}' /proc/loadavg 2>/dev/null
        fi
        df -h / 2>/dev/null | awk 'NR==2{printf "Disk (/)......: %s terpakai / %s total (%s)\n", $3, $2, $5}'
        printf "Titian CLI....: klish %s (tree /opt/titian/etc/clish-en)\n" "$("$BIN/clish" -v 2>/dev/null | head -1)"
        if command -v birdc >/dev/null 2>&1; then
            printf "BIRD..........: %s\n" "$(birdc show status 2>/dev/null | head -1 | sed 's/^BIRD //;s/ ready\.$//')"
        fi
        printf "\n"
        ;;
    sed-replace)
        # $2=file $3=script sed — portable sed -i (dipakai aksi XML).
        [ -n "${2:-}" ] && [ -n "${3:-}" ] || err "sed-replace butuh file + script"
        sys_sed_i "$2" "$3"
        ;;
    sed-del-blank)
        # $2=file — hapus baris kosong, portable.
        [ -n "${2:-}" ] || err "sed-del-blank butuh file"
        sys_sed_del_blank "$2"
        ;;
    dns-domain)
        # $2=domain
        [ -n "${2:-}" ] || err "domain kosong"
        if dns_stub_mode; then
            dns_dropin_ensure
            sys_sed_i "$(dns_dropin)" '/^Domains=/d'
            printf 'Domains=%s\n' "$2" >> "$(dns_dropin)"
            dns_dropin_restart
        elif [ -L /etc/resolv.conf ]; then
            err "resolv.conf symlink tanpa systemd-resolved aktif — tidak diubah (stub dilindungi)"
        else
            sys_sed_i /etc/resolv.conf 's|^domain.*||'
            sys_sed_i /etc/resolv.conf 's|^search.*||'
            sys_sed_del_blank /etc/resolv.conf
            echo "domain $2" >> /etc/resolv.conf
        fi
        ;;
    dns-domain-clear)
        if dns_stub_mode; then
            if [ -f "$(dns_dropin)" ]; then
                sys_sed_i "$(dns_dropin)" '/^Domains=/d'
                if ! grep -q -E '^(DNS|Domains)=' "$(dns_dropin)" 2>/dev/null; then
                    rm -f "$(dns_dropin)"
                fi
            fi
            dns_dropin_restart
        elif [ -L /etc/resolv.conf ]; then
            err "resolv.conf symlink tanpa systemd-resolved aktif — tidak diubah (stub dilindungi)"
        else
            sys_sed_i /etc/resolv.conf 's|^domain.*||'
            sys_sed_i /etc/resolv.conf 's|^search.*||'
            sys_sed_del_blank /etc/resolv.conf
        fi
        ;;
    dns-ns-add)
        # $2=ip nameserver
        [ -n "${2:-}" ] || err "nameserver kosong"
        if dns_stub_mode; then
            dns_dropin_ensure
            awk -v ip="$2" '/^DNS=/ { n=split(substr($0,5), a, " "); found=0; for (i=1;i<=n;i++) if (a[i]==ip) found=1; if (!found) $0=$0 " " ip } {print}' "$(dns_dropin)" > "$(dns_dropin).tmp" && mv "$(dns_dropin).tmp" "$(dns_dropin)"
            if ! grep -q '^DNS=' "$(dns_dropin)" 2>/dev/null; then
                printf 'DNS=%s\n' "$2" >> "$(dns_dropin)"
            fi
            dns_dropin_restart
        elif [ -L /etc/resolv.conf ]; then
            err "resolv.conf symlink tanpa systemd-resolved aktif — tidak diubah (stub dilindungi)"
        else
            sys_sed_i /etc/resolv.conf "s|nameserver $2\$||"
            sys_sed_del_blank /etc/resolv.conf
            echo "nameserver $2" >> /etc/resolv.conf
        fi
        ;;
    dns-ns-del)
        # $2=ip nameserver
        [ -n "${2:-}" ] || err "nameserver kosong"
        if dns_stub_mode; then
            if [ -f "$(dns_dropin)" ]; then
                awk -v ip="$2" '/^DNS=/ { n=split(substr($0,5), a, " "); out=""; for (i=1;i<=n;i++) if (a[i]!=ip) out=out (out==""?"":" ") a[i]; if (out!="") $0="DNS=" out; else next } {print}' "$(dns_dropin)" > "$(dns_dropin).tmp" && mv "$(dns_dropin).tmp" "$(dns_dropin)"
                if ! grep -q -E '^(DNS|Domains)=' "$(dns_dropin)" 2>/dev/null; then
                    rm -f "$(dns_dropin)"
                fi
            fi
            dns_dropin_restart
        elif [ -L /etc/resolv.conf ]; then
            err "resolv.conf symlink tanpa systemd-resolved aktif — tidak diubah (stub dilindungi)"
        else
            sys_sed_i /etc/resolv.conf "s|nameserver $2\$||"
            sys_sed_del_blank /etc/resolv.conf
        fi
        ;;
    *) echo "Usage: $0 {hostname|timezone|ssh-check|ssh-restart|port-in-use|services|service-status|process|memory|cpu|pci|dmi|connections|sed-replace|sed-del-blank|dns-domain|dns-domain-clear|dns-ns-add|dns-ns-del} ..." >&2; exit 2 ;;
esac
