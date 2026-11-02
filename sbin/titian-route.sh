#!/bin/sh
# TITIAN Fase 1 — route IPv6 (conf-route6.xml). v4 tetap inline di
# conf-route.xml (Linux) / conf-route-fbsd.xml (FreeBSD).
# POSIX sh.
OS=$(uname -s)
err() { echo "Error: $*" >&2; exit 33; }

fbsd_change_or_add() {
    # $1.. = argumen route (tanpa subcommand change/add)
    route change "$@" 2>/dev/null || route add "$@" || err "route gagal: $*"
}

case "${1:-}" in
    gw6)
        if [ "$OS" = "FreeBSD" ]; then
            route -n get -inet6 default >/dev/null 2>&1 && route change -inet6 default "$2" || route add -inet6 default "$2" || err "gagal set default-gateway v6 $2"
        else
            ip -6 route replace default via "$2" || err "gagal set default-gateway v6 $2"
        fi
        ;;
    gw6-del)
        if [ "$OS" = "FreeBSD" ]; then
            route delete -inet6 default || err "gagal hapus default-gateway v6"
        else
            ip -6 route del default || err "gagal hapus default-gateway v6"
        fi
        ;;
    route6-dev)
        if [ "$OS" = "FreeBSD" ]; then
            fbsd_change_or_add -inet6 "$2" -interface "$3"
        else
            ip -6 route replace "$2" dev "$3" || err "gagal route v6 $2 dev $3"
        fi
        ;;
    route6-via)
        if [ "$OS" = "FreeBSD" ]; then
            fbsd_change_or_add -inet6 "$2" "$3"
        else
            ip -6 route replace "$2" via "$3" || err "gagal route v6 $2 via $3"
        fi
        ;;
    route6-del)
        if [ "$OS" = "FreeBSD" ]; then
            route delete -inet6 "$2" || err "gagal hapus route v6 $2"
        else
            ip -6 route del "$2" || err "gagal hapus route v6 $2"
        fi
        ;;
    route6-blackhole)
        if [ "$OS" = "FreeBSD" ]; then
            route add -inet6 "$2" ::1 -blackhole || err "gagal blackhole v6 $2"
        else
            ip -6 route replace blackhole "$2" || err "gagal blackhole v6 $2"
        fi
        ;;
    route6-blackhole-del)
        if [ "$OS" = "FreeBSD" ]; then
            route delete -inet6 "$2" || err "gagal hapus blackhole v6 $2"
        else
            ip -6 route del blackhole "$2" || err "gagal hapus blackhole v6 $2"
        fi
        ;;
    *) echo "Usage: $0 {gw6|gw6-del|route6-dev|route6-via|route6-del|route6-blackhole|route6-blackhole-del} ..." >&2; exit 2 ;;
esac
