#!/usr/local/bin/python3
# titian-coa.py -- CoA / Disconnect listener untuk Titian (BRAS).
# myRadDASH mengirim RADIUS Disconnect-Request (Code 40) / CoA-Request
# (Code 43) ke NAS (port 3799) saat operator menekan "disconnect" /
# "isolir" di myRadDASH (POST /nas/:id/disconnect, POST /isolir/...).
# mpd5 TIDAK mendengarkan CoA (port 3799) dan isc-dhcpd juga tidak --
# tanpa listener ini, CoA dari myRadDASH TIDAK memutus sesi apa pun
# (celah yang didokumentasikan di MYRADASH-INTEGRATION-DESIGN §1.4).
# Listener ini menutup celah itu:
#   - Verifikasi paket: Request Authenticator =
#     MD5(Code+ID+Length+16 zero bytes+Attributes+Secret) dengan secret
#     NAS (radius-secret di ipoe.conf) + source IP harus RADIUS server
#     (myRadDASH) atau localhost (untuk uji). Paket yang tidak valid
#     DIABAIKAN (tanpa balasan).
#   - Dispatch berdasarkan User-Name:
#       * MAC (aa:bb:cc:dd:ee:ff) -> KICK IPoE: panggil
#         titian-dhcp.sh kick <mac> (hapus lease via OMAPI + blokir MAC).
#       * username (bukan MAC) -> DISCONNECT PPPoE: cari interface tun
#         yang memegang Framed-IP-Address dari paket, lalu
#         `ifconfig <tun> destroy` (sesi mpd5 putus).
#   - Balasan: Disconnect-ACK (41) / Disconnect-NAK (42) untuk
#     Disconnect-Request; CoA-ACK (44) / CoA-NAK (45) untuk CoA-Request.
#     Response Authenticator = MD5(Code+ID+Length+RequestAuth+
#     Attributes+Secret). NAK membawa Error-Cause (101) = 404.
# Listener jalan di foreground (loop). Untuk produksi, jalankan sebagai
# daemon (nohup / rc script); untuk uji, jalankan manual lalu kirim
# paket uji dengan subcommand `send-test`.
# CATATAN: port 3799 (UDP) terbuka di semua interface (socket bind
# 0.0.0.0). Dilindungi secret NAS (hmac, sama seperti RADIUS) + cek
# source IP. Untuk myRadDASH -> Titian lewat NAT publik, perlu
# port-forward 3799 (UDP) ke mesin test (belum ada; lihat panduan §9d).
# Secret TIDAK PERNAH dicetak. Pure Python stdlib.
# Usage:
#   titian-coa.py listen [--port 3799] [--secret <s>] [--conf <path>]
#       [--allow <ip,ip>] [--dhcp-sh <path>] [--one-shot]
#   titian-coa.py send-test <target-ip> <user-or-mac> [--port 3799]
#       [--secret <s>] [--conf <path>] [--framed-ip <ip>]
#       [--code disconnect|coa] [--timeout 3]
# Exit listen: 0 (berhenti normal / one-shot selesai), 1 (error setup).
# Exit send-test: 0 = ACK diterima, 1 = NAK / timeout / error.
import argparse
import hashlib
import os
import re
import socket
import struct
import subprocess
import sys
import time

DEFAULT_STATE_ROOT = os.environ.get("TITIAN_STATE_ROOT", "/etc/titian")
DEFAULT_CONF = os.environ.get(
    "TITIAN_IPOE_CONF", os.path.join(DEFAULT_STATE_ROOT, "ipoe.conf"))
DEFAULT_DHCP_SH = os.environ.get(
    "TITIAN_DHCP_SH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "titian-dhcp.sh"))
COA_PORT = 3799
MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")


def md5(b):
    return hashlib.md5(b).digest()


def log(msg):
    sys.stdout.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stdout.flush()


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


def parse_attrs(data):
    # Kembalikan dict type -> list of raw values (bytes).
    attrs = {}
    off = 0
    while off + 2 <= len(data):
        t = data[off]
        ln = data[off + 1]
        if ln < 2 or off + ln > len(data):
            break
        attrs.setdefault(t, []).append(data[off + 2:off + ln])
        off += ln
    return attrs


def attr_str(attrs, t):
    v = attrs.get(t)
    if not v:
        return None
    try:
        return v[0].decode("utf-8", "replace")
    except Exception:
        return None


def parse_ip(attrs, t):
    v = attrs.get(t)
    if not v or len(v[0]) != 4:
        return None
    return ".".join(str(b) for b in v[0])


def attr(t, v):
    if isinstance(v, str):
        v = v.encode()
    return bytes([t, len(v) + 2]) + v


def attr_ip(t, ip):
    parts = [int(x) for x in ip.split(".")]
    return bytes([t, 6]) + bytes(parts)


def attr_int(t, v):
    return bytes([t, 6]) + struct.pack("!I", v)


def verify_req_auth(data, secret_b):
    # CoA/Disconnect-Request: Request Authenticator =
    # MD5(Code+ID+Length+16 zero bytes+Attributes+Secret).
    if len(data) < 20:
        return False
    code, ident, length = data[0], data[1], struct.unpack("!H", data[2:4])[0]
    if length != len(data):
        return False
    expect = md5(struct.pack("!BBH", code, ident, length) + b"\x00" * 16
                 + data[20:] + secret_b)
    return expect == data[4:20]


def build_response(req_code, req_id, req_auth, secret_b, ack, err_cause=None):
    # ACK/NAK. Response Authenticator =
    # MD5(Code+ID+Length+RequestAuth+Attributes+Secret).
    if req_code == 40:      # Disconnect-Request
        code = 41 if ack else 42
    elif req_code == 43:    # CoA-Request
        code = 44 if ack else 45
    else:
        return None
    attrs = b""
    if not ack and err_cause is not None:
        attrs = attr_int(101, err_cause)  # Error-Cause
    length = 20 + len(attrs)
    resp_auth = md5(struct.pack("!BBH", code, req_id, length) + req_auth
                    + attrs + secret_b)
    return struct.pack("!BBH", code, req_id, length) + resp_auth + attrs


def find_tun_by_ip(framed_ip):
    # Cari interface tun* yang memegang IP ini (sesi PPPoE mpd5).
    # Output ifconfig: "tun0: flags=..." lalu "inet <ip> --> ...".
    if not framed_ip:
        return None
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True,
                             timeout=10).stdout
    except Exception:
        return None
    cur = None
    for line in out.splitlines():
        m = re.match(r"^(\S+):\s", line)
        if m:
            cur = m.group(1)
            continue
        if cur and cur.startswith("tun"):
            m = re.match(r"\s+inet\s+(\S+)\s", line)
            if m and m.group(1) == framed_ip:
                return cur
    return None


def do_ipoe_kick(mac, dhcp_sh):
    # Panggil titian-dhcp.sh kick <mac>. Return (ok, output).
    try:
        r = subprocess.run([dhcp_sh, "kick", mac], capture_output=True,
                           text=True, timeout=60)
        out = (r.stdout or "") + (r.stderr or "")
        return (r.returncode == 0), out.strip()
    except Exception as e:
        return False, str(e)


def do_pppoe_disconnect(username, framed_ip):
    # Putuskan sesi PPPoE: cari tun yang memegang Framed-IP-Address,
    # lalu `ifconfig <tun> destroy`. Return (ok, msg).
    if not framed_ip:
        return False, "tidak ada Framed-IP-Address di paket (tidak bisa cari sesi PPPoE)"
    tun = find_tun_by_ip(framed_ip)
    if not tun:
        return False, "tidak ada interface tun untuk IP %s (sesi %s tidak ditemukan)" % (framed_ip, username)
    try:
        r = subprocess.run(["ifconfig", tun, "destroy"], capture_output=True,
                           text=True, timeout=10)
        if r.returncode == 0:
            return True, "interface %s (sesi %s, IP %s) di-destroy" % (tun, username, framed_ip)
        return False, "ifconfig %s destroy gagal: %s" % (tun, (r.stderr or "").strip())
    except Exception as e:
        return False, str(e)


def handle_packet(data, addr, secret_b, allow_ips, dhcp_sh):
    # Kembalikan (response_bytes atau None, log_msg).
    src_ip = addr[0]
    if len(data) < 20:
        return None, "paket terlalu pendek dari %s (%d byte) — diabaikan" % (src_ip, len(data))
    code = data[0]
    if code not in (40, 43):
        return None, "code %d dari %s bukan CoA/Disconnect — diabaikan" % (code, src_ip)
    if allow_ips is not None and src_ip not in allow_ips:
        return None, "source %s tidak diizinkan (allow: %s) — diabaikan" % (src_ip, ",".join(sorted(allow_ips)))
    if not verify_req_auth(data, secret_b):
        return None, "Request Authenticator SALAH dari %s (secret tidak cocok?) — diabaikan" % src_ip
    ident = data[1]
    req_auth = data[4:20]
    attrs = parse_attrs(data[20:])
    user = attr_str(attrs, 1)
    framed_ip = parse_ip(attrs, 8)
    kind = "Disconnect" if code == 40 else "CoA"
    if not user:
        resp = build_response(code, ident, req_auth, secret_b, False, 404)
        return resp, "%s dari %s: tanpa User-Name -> NAK" % (kind, src_ip)
    if MAC_RE.match(user):
        mac = user.lower()
        ok, out = do_ipoe_kick(mac, dhcp_sh)
        resp = build_response(code, ident, req_auth, secret_b, ok, None if ok else 404)
        status = "ACK" if ok else "NAK"
        return resp, "%s %s (IPoE MAC %s, framed-ip %s): kick %s -> %s | %s" % (
            kind, src_ip, mac, framed_ip or "-", "OK" if ok else "GAGAL", status, out.splitlines()[-1] if out else "")
    ok, msg = do_pppoe_disconnect(user, framed_ip)
    resp = build_response(code, ident, req_auth, secret_b, ok, None if ok else 404)
    status = "ACK" if ok else "NAK"
    return resp, "%s %s (PPPoE user %s, framed-ip %s): %s -> %s | %s" % (
        kind, src_ip, user, framed_ip or "-", "OK" if ok else "GAGAL", status, msg)


def cmd_listen(args):
    conf = read_conf(args.conf)
    secret = args.secret or conf.get("radius-secret")
    if not secret:
        print("ERROR: radius-secret belum diset (ipoe.conf / --secret) — CoA butuh secret NAS", file=sys.stderr)
        return 1
    secret_b = secret.encode()
    allow = set()
    if args.allow:
        allow.update([x.strip() for x in args.allow.split(",") if x.strip()])
    else:
        rs = conf.get("radius-server")
        if rs:
            allow.add(rs)
        allow.add("127.0.0.1")
        allow.add("::1")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("0.0.0.0", args.port))
    except OSError as e:
        print("ERROR: tidak bisa bind UDP %d: %s" % (args.port, e), file=sys.stderr)
        return 1
    s.settimeout(1.0)
    log("CoA listener jalan di UDP %d (allow source: %s; dhcp-sh: %s)"
        % (args.port, ",".join(sorted(allow)), args.dhcp_sh))
    try:
        while True:
            try:
                data, addr = s.recvfrom(4096)
            except socket.timeout:
                if args.one_shot:
                    break
                continue
            resp, msg = handle_packet(data, addr, secret_b, allow, args.dhcp_sh)
            log(msg)
            if resp is not None:
                try:
                    s.sendto(resp, addr)
                except OSError as e:
                    log("gagal kirim balasan ke %s: %s" % (addr[0], e))
            if args.one_shot:
                break
    except KeyboardInterrupt:
        log("CoA listener berhenti (KeyboardInterrupt)")
    finally:
        s.close()
    return 0


def cmd_send_test(args):
    conf = read_conf(args.conf)
    secret = args.secret or conf.get("radius-secret")
    if not secret:
        print("ERROR: radius-secret belum diset (ipoe.conf / --secret)", file=sys.stderr)
        return 1
    secret_b = secret.encode()
    code = 40 if args.code == "disconnect" else 43
    ident = 1
    attrs = attr(1, args.user)
    if args.framed_ip:
        attrs += attr_ip(8, args.framed_ip)
    attrs += attr(32, "titian-test")
    length = 20 + len(attrs)
    req_auth = md5(struct.pack("!BBH", code, ident, length) + b"\x00" * 16
                   + attrs + secret_b)
    pkt = struct.pack("!BBH", code, ident, length) + req_auth + attrs
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(args.timeout)
    try:
        s.sendto(pkt, (args.target, args.port))
        data, _ = s.recvfrom(4096)
    except socket.timeout:
        print("send-test: TIMEOUT (tidak ada jawaban dari %s:%d — listener jalan?)" % (args.target, args.port))
        return 1
    except OSError as e:
        print("send-test: jaringan: %s" % e)
        return 1
    finally:
        s.close()
    if len(data) < 20:
        print("send-test: jawaban terlalu pendek (%d byte)" % len(data))
        return 1
    rcode = data[0]
    expect = md5(data[:4] + req_auth + data[20:] + secret_b)
    if expect != data[4:20]:
        print("send-test: response-authenticator SALAH (secret tidak cocok?)")
        return 1
    names = {41: "Disconnect-ACK", 42: "Disconnect-NAK", 44: "CoA-ACK", 45: "CoA-NAK"}
    print("send-test: %s (code %d) dari %s:%d untuk %s"
          % (names.get(rcode, "code %d" % rcode), rcode, args.target, args.port, args.user))
    return 0 if rcode in (41, 44) else 1


def main():
    ap = argparse.ArgumentParser(description="CoA / Disconnect listener Titian")
    ap.add_argument("--conf", default=DEFAULT_CONF, help="ipoe.conf")
    ap.add_argument("--secret", default=None, help="secret NAS (default: radius-secret di ipoe.conf)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    li = sub.add_parser("listen", help="jalankan listener CoA/Disconnect di UDP 3799")
    li.add_argument("--port", type=int, default=COA_PORT)
    li.add_argument("--secret", default=None, help="secret NAS (default: radius-secret di ipoe.conf)")
    li.add_argument("--allow", default=None, help="source IP yang diizinkan, koma (default: radius-server + 127.0.0.1)")
    li.add_argument("--dhcp-sh", default=DEFAULT_DHCP_SH, help="path titian-dhcp.sh")
    li.add_argument("--one-shot", action="store_true", help="tangani satu paket lalu berhenti (untuk uji)")
    st = sub.add_parser("send-test", help="kirim Disconnect/CoA uji ke listener")
    st.add_argument("target", help="IP target listener")
    st.add_argument("user", help="User-Name (MAC untuk IPoE, username untuk PPPoE)")
    st.add_argument("--port", type=int, default=COA_PORT)
    st.add_argument("--secret", default=None, help="secret NAS (default: radius-secret di ipoe.conf)")
    st.add_argument("--framed-ip", default=None, help="Framed-IP-Address")
    st.add_argument("--code", choices=["disconnect", "coa"], default="disconnect")
    st.add_argument("--timeout", type=float, default=3)
    a = ap.parse_args()
    if a.cmd == "listen":
        return cmd_listen(a)
    if a.cmd == "send-test":
        return cmd_send_test(a)
    return 2


if __name__ == "__main__":
    sys.exit(main())
