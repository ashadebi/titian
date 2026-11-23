#!/usr/local/bin/python3
# titian-ipoe-acct.py -- RADIUS Accounting untuk sesi IPoE (DHCP) Titian.
# isc-dhcpd TIDAK mengirim RADIUS accounting, jadi Titian yang mendorong
# event sesi ke FreeRADIUS (myRadDASH) agar sesi IPoE tampil di
# `GET /v0/sessions` myRadDASH (dari tabel radacct).
# Mekanisme: baca lease DHCP aktif (/var/db/dhcpd.leases), kirim
# Accounting-Request (Code 4) ke FreeRADIUS port 1813 sebagai NAS
# `titian-test` (secret = radius-secret di ipoe.conf).
#   - Start (Acct-Status-Type 1): saat lease aktif BARU terlihat.
#   - Stop  (Acct-Status-Type 2): saat lease hilang / kedaluwarsa.
#   - Interim-Update (3): tidak dipakai (Start+Stop cukup untuk sesi).
# State sesi yang sudah dilaporkan disimpan di file JSON (state file)
# agar Start dikirim SEKALI per lease dan Stop dikirim saat lease hilang.
# File lease isc-dhcpd bersifat append-only -- BLOK TERAKHIR per IP
# yang berlaku (sama seperti titian-dhcp.sh find_lease_ip_for_mac).
# Acct-Session-Id: ipoe-<mac-tanpa-titikdua>-<starts-epoch> (unik per
# lease; lease baru = starts baru = session-id baru).
# User-Name = MAC (pola MAB, sama seperti RADIUS MAC-auth).
# NAS-IP-Address: dari `nas-ip` di ipoe.conf (harus = nasname NAS di
# myRadDASH, mis. 103.50.128.18); bila tidak diset, pakai IP sumber UDP
# lokal + warning.
# Secret + JWT TIDAK PERNAH dicetak. Pure Python stdlib (tanpa dependensi).
# Usage:
#   titian-ipoe-acct.py push [--server <ip>] [--port 1813]
#       [--secret <secret>] [--nas-ip <ip>] [--nas-id titian-test]
#       [--leases <path>] [--state <path>] [--conf <path>]
#   titian-ipoe-acct.py status [--leases <path>] [--state <path>]
#   titian-ipoe-acct.py test <mac> <ip> [--server ...] [...]
#       (kirim Start lalu Stop untuk MAC/IP uji; tidak ubah state)
# Exit: 0 = sukses (semua paket di-ACK / tidak ada yang perlu dikirim),
#       1 = ada paket yang gagal (timeout / NAK / response-auth salah).
# Variabel env (untuk mock): TITIAN_STATE_ROOT, TITIAN_DHCPD_LEASES,
# TITIAN_IPOE_CONF. Default: /etc/titian, /var/db/dhcpd.leases.
import argparse
import calendar
import hashlib
import json
import os
import re
import socket
import struct
import sys
import time

DEFAULT_STATE_ROOT = os.environ.get("TITIAN_STATE_ROOT", "/etc/titian")
DEFAULT_LEASES = os.environ.get("TITIAN_DHCPD_LEASES", "/var/db/dhcpd.leases")
DEFAULT_CONF = os.environ.get(
    "TITIAN_IPOE_CONF", os.path.join(DEFAULT_STATE_ROOT, "ipoe.conf"))
DEFAULT_STATE = os.path.join(DEFAULT_STATE_ROOT, "ipoe-acct-state.json")
DEFAULT_NAS_ID = "titian-test"
ACCT_PORT = 1812 + 1  # 1813


def md5(b):
    return hashlib.md5(b).digest()


def attr(t, v):
    if isinstance(v, str):
        v = v.encode()
    return bytes([t, len(v) + 2]) + v


def attr_int(t, v):
    return bytes([t, 6]) + struct.pack("!I", v)


def attr_ip(t, ip):
    parts = [int(x) for x in ip.split(".")]
    return bytes([t, 6]) + bytes(parts)


def parse_lease_datetime(s):
    # Format isc-dhcpd: "4 2026/11/19 12:00:00" (dow yyyy/mm/dd hh:mm:ss, UTC)
    m = re.match(r"\d+\s+(\d+)/(\d+)/(\d+)\s+(\d+):(\d+):(\d+)", s.strip())
    if not m:
        return None
    y, mo, d, h, mi, sec = (int(x) for x in m.groups())
    try:
        return calendar.timegm((y, mo, d, h, mi, sec, 0, 0, 0))
    except Exception:
        return None


def read_active_leases(path):
    # Kembalikan dict ip -> {mac, starts_epoch, ends_epoch}.
    # Hanya blok TERAKHIR per IP yang dipakai (file append-only).
    if not os.path.isfile(path):
        return {}
    cur = None
    blocks = {}  # ip -> dict blok terakhir
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            m = re.match(r"lease\s+(\S+)\s*\{", line)
            if m:
                cur = {"ip": m.group(1), "state": None, "mac": None,
                       "starts": None, "ends": None}
                continue
            if cur is None:
                continue
            if line == "}":
                blocks[cur["ip"]] = cur
                cur = None
                continue
            m = re.match(r"binding state\s+(\w+);", line)
            if m:
                cur["state"] = m.group(1)
                continue
            m = re.match(r"hardware ethernet\s+([0-9A-Fa-f:]+);", line)
            if m:
                cur["mac"] = m.group(1).lower()
                continue
            m = re.match(r"starts\s+(.+);", line)
            if m:
                cur["starts"] = parse_lease_datetime(m.group(1))
                continue
            m = re.match(r"ends\s+(.+);", line)
            if m:
                cur["ends"] = parse_lease_datetime(m.group(1))
                continue
    out = {}
    for ip, b in blocks.items():
        if b.get("state") == "active" and b.get("mac"):
            out[ip] = {"mac": b["mac"], "starts_epoch": b.get("starts"),
                       "ends_epoch": b.get("ends")}
    return out


def read_conf(path):
    conf = {}
    if not os.path.isfile(path):
        return conf
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) == 2:
                conf[parts[0]] = parts[1].strip()
            elif len(parts) == 1:
                conf[parts[0]] = True
    return conf


def session_id(mac, starts_epoch):
    mac_nocolon = mac.replace(":", "")
    if starts_epoch:
        return "ipoe-%s-%d" % (mac_nocolon, starts_epoch)
    return "ipoe-%s-%d" % (mac_nocolon, int(time.time()))


def send_acct(server, port, secret, attrs, timeout=3):
    # Accounting-Request (Code 4). Request Authenticator =
    # MD5(Code+ID+Length+16 zero bytes+Attributes+Secret).
    # Response Authenticator diverifikasi: MD5(Code+ID+Length+
    # RequestAuth+Attributes+Secret). Return (ok, msg).
    secret_b = secret.encode()
    ident = 1
    length = 20 + len(attrs)
    zero16 = b"\x00" * 16
    req_auth = md5(struct.pack("!BBH", 4, ident, length) + zero16 + attrs + secret_b)
    pkt = struct.pack("!BBH", 4, ident, length) + req_auth + attrs
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(pkt, (server, port))
        data, _ = s.recvfrom(4096)
    except socket.timeout:
        return False, "timeout (tidak ada jawaban dari %s:%d)" % (server, port)
    except OSError as e:
        return False, "jaringan: %s" % e
    finally:
        s.close()
    if len(data) < 20:
        return False, "jawaban terlalu pendek (%d byte)" % len(data)
    code = data[0]
    expect = md5(data[:4] + req_auth + data[20:] + secret_b)
    if expect != data[4:20]:
        return False, "response-authenticator SALAH (secret tidak cocok?)"
    if code == 5:
        return True, "Accounting-Response (ACK)"
    return False, "code jawaban tak dikenal: %d (bukan Accounting-Response)" % code


def build_attrs(mac, ip, nas_ip, nas_id, status_type, sess_id, terminate=None):
    # Atribut Accounting-Request (RFC 2866).
    # 1 User-Name, 4 NAS-IP-Address, 6 Service-Type, 8 Framed-IP-Address,
    # 30 Called-Station-Id, 31 Calling-Station-Id, 32 NAS-Identifier,
    # 40 Acct-Status-Type, 42 Acct-Input-Octets, 43 Acct-Output-Octets,
    # 44 Acct-Session-Id, 45 Acct-Authentic, 49 Acct-Terminate-Cause,
    # 55 Event-Timestamp, 61 NAS-Port-Type.
    a = b""
    a += attr(1, mac)
    a += attr_ip(4, nas_ip)
    a += attr_int(6, 2)          # Service-Type: Framed-User
    a += attr_ip(8, ip)
    a += attr(30, nas_id)        # Called-Station-Id
    a += attr(31, mac)           # Calling-Station-Id
    a += attr(32, nas_id)        # NAS-Identifier
    a += attr_int(40, status_type)
    a += attr_int(42, 0)         # Acct-Input-Octets
    a += attr_int(43, 0)         # Acct-Output-Octets
    a += attr(44, sess_id)
    a += attr_int(45, 1)         # Acct-Authentic: RADIUS
    if terminate is not None:
        a += attr_int(49, terminate)  # Acct-Terminate-Cause
    a += attr_int(55, int(time.time()))  # Event-Timestamp
    a += attr_int(61, 15)        # NAS-Port-Type: Ethernet
    return a


def local_source_ip(server, port):
    # IP sumber UDP lokal saat kirim ke server (fallback nas-ip).
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((server, port))
        return s.getsockname()[0]
    except OSError:
        return "0.0.0.0"
    finally:
        s.close()


def load_state(path):
    if os.path.isfile(path):
        try:
            with open(path, "r") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def cmd_push(args):
    conf = read_conf(args.conf)
    server = args.server or conf.get("radius-server")
    secret = args.secret or conf.get("radius-secret")
    if not server:
        print("ERROR: radius-server belum diset (ipoe.conf / --server)", file=sys.stderr)
        return 2
    if not secret:
        print("ERROR: radius-secret belum diset (ipoe.conf / --secret)", file=sys.stderr)
        return 2
    nas_id = args.nas_id or DEFAULT_NAS_ID
    nas_ip = args.nas_ip or conf.get("nas-ip")
    if not nas_ip:
        nas_ip = local_source_ip(server, args.port)
        print("warning: nas-ip belum diset di ipoe.conf — pakai IP sumber lokal %s "
              "(set 'nas-ip <ip>' agar sama dengan nasname di myRadDASH)" % nas_ip,
              file=sys.stderr)
    leases = read_active_leases(args.leases)
    state = load_state(args.state)
    now = int(time.time())
    n_start = 0
    n_stop = 0
    failed = 0
    # Start untuk lease aktif yang belum dilaporkan.
    for ip, info in sorted(leases.items()):
        mac = info["mac"]
        sid = session_id(mac, info.get("starts_epoch"))
        if sid in state:
            continue
        attrs = build_attrs(mac, ip, nas_ip, nas_id, 1, sid)
        ok, msg = send_acct(server, args.port, secret, attrs, args.timeout)
        if ok:
            state[sid] = {"mac": mac, "ip": ip,
                          "starts_epoch": info.get("starts_epoch"),
                          "reported_at": now}
            n_start += 1
            print("Start: %s (%s) -> %s" % (mac, ip, msg))
        else:
            failed += 1
            print("Start GAGAL: %s (%s): %s" % (mac, ip, msg), file=sys.stderr)
    # Stop untuk sesi di state yang lease-nya sudah hilang / kedaluwarsa.
    current_sids = set()
    for ip, info in leases.items():
        current_sids.add(session_id(info["mac"], info.get("starts_epoch")))
    for sid in sorted(list(state.keys())):
        if sid in current_sids:
            continue
        info = state[sid]
        mac = info.get("mac", "")
        ip = info.get("ip", "")
        attrs = build_attrs(mac, ip, nas_ip, nas_id, 2, sid, terminate=1)
        ok, msg = send_acct(server, args.port, secret, attrs, args.timeout)
        if ok:
            n_stop += 1
            print("Stop: %s (%s) -> %s" % (mac, ip, msg))
        else:
            failed += 1
            print("Stop GAGAL: %s (%s): %s" % (mac, ip, msg), file=sys.stderr)
        del state[sid]
    save_state(args.state, state)
    print("push selesai: %d Start, %d Stop, %d gagal, %d sesi aktif dilaporkan"
          % (n_start, n_stop, failed, len(state)))
    return 1 if failed else 0


def cmd_status(args):
    leases = read_active_leases(args.leases)
    state = load_state(args.state)
    print("Lease DHCP aktif: %d" % len(leases))
    for ip, info in sorted(leases.items()):
        sid = session_id(info["mac"], info.get("starts_epoch"))
        mark = "dilaporkan" if sid in state else "BELUM dilaporkan"
        print("  %-15s %-17s session %s (%s)" % (ip, info["mac"], sid, mark))
    print("Sesi dilaporkan ke myRadDASH: %d" % len(state))
    for sid, info in sorted(state.items()):
        print("  %s  %s (%s)" % (sid, info.get("mac", ""), info.get("ip", "")))
    return 0


def cmd_test(args):
    conf = read_conf(args.conf)
    server = args.server or conf.get("radius-server")
    secret = args.secret or conf.get("radius-secret")
    if not server or not secret:
        print("ERROR: radius-server / radius-secret belum diset", file=sys.stderr)
        return 2
    nas_id = args.nas_id or DEFAULT_NAS_ID
    nas_ip = args.nas_ip or conf.get("nas-ip") or local_source_ip(server, args.port)
    mac = args.mac.lower()
    sid = "ipoe-test-%s-%d" % (mac.replace(":", ""), int(time.time()))
    attrs = build_attrs(mac, args.ip, nas_ip, nas_id, 1, sid)
    ok, msg = send_acct(server, args.port, secret, attrs, args.timeout)
    print("Test Start %s (%s): %s" % (mac, args.ip, msg))
    if not ok:
        return 1
    attrs = build_attrs(mac, args.ip, nas_ip, nas_id, 2, sid, terminate=1)
    ok, msg = send_acct(server, args.port, secret, attrs, args.timeout)
    print("Test Stop  %s (%s): %s" % (mac, args.ip, msg))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="RADIUS Accounting IPoE (Titian -> myRadDASH)")
    ap.add_argument("--server", default=None, help="RADIUS server IPv4 (default: radius-server di ipoe.conf)")
    ap.add_argument("--port", type=int, default=ACCT_PORT)
    ap.add_argument("--secret", default=None, help="RADIUS shared secret (default: radius-secret di ipoe.conf)")
    ap.add_argument("--nas-ip", default=None, help="NAS-IP-Address (default: nas-ip di ipoe.conf)")
    ap.add_argument("--nas-id", default=None, help="NAS-Identifier (default: titian-test)")
    ap.add_argument("--leases", default=DEFAULT_LEASES, help="lease file dhcpd")
    ap.add_argument("--state", default=DEFAULT_STATE, help="state file JSON sesi dilaporkan")
    ap.add_argument("--conf", default=DEFAULT_CONF, help="ipoe.conf")
    ap.add_argument("--timeout", type=float, default=3)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("push", help="kirim Start (lease baru) + Stop (lease hilang)")
    sub.add_parser("status", help="tampilkan lease aktif + sesi dilaporkan")
    t = sub.add_parser("test", help="kirim Start lalu Stop untuk MAC/IP uji (tanpa ubah state)")
    t.add_argument("mac", help="MAC uji (aa:bb:cc:dd:ee:ff)")
    t.add_argument("ip", help="IP uji")
    a = ap.parse_args()
    if a.cmd == "push":
        return cmd_push(a)
    if a.cmd == "status":
        return cmd_status(a)
    if a.cmd == "test":
        return cmd_test(a)
    return 2


if __name__ == "__main__":
    sys.exit(main())
