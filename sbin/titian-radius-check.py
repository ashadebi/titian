#!/usr/local/bin/python3
# titian-radius-check.py -- klien RADIUS minimal (PAP) untuk IPoE MAC-auth.
# Dipakai titian-dhcp.sh saat generate: verifikasi SATU MAC terhadap
# RADIUS (User-Name = MAC, User-Password = MAC -- pola MAC-auth / MAB
# standar: MAC adalah username sekaligus password). Hanya MAC yang
# RADIUS-accept yang masuk ke allowlist DHCP (class radius-allowed).
# Berbasis titian-radius-test-client.py koordinator RADIUS (19 Nov 2026,
# terbukti PAP vs myRadDASH) -- diparameterisasi (server/secret/user),
# tanpa secret hardcode, tanpa mencetak secret ke output.
# Usage:
#   titian-radius-check.py --server <ip> --secret <secret>
#       --user <mac> [--password <mac>] [--port 1812] [--timeout 3]
#       [--nas-id titian-ipoe]
# Exit: 0 = Access-Accept, 1 = Access-Reject, 2 = error
# (timeout / response-authenticator salah / jaringan).
# Output: satu baris "Access-Accept" / "Access-Reject" / "ERROR: ...".
# Secret TIDAK PERNAH dicetak.
import argparse
import hashlib
import os
import socket
import struct
import sys


def md5(b):
    return hashlib.md5(b).digest()


def attr(t, v):
    if isinstance(v, str):
        v = v.encode()
    return bytes([t, len(v) + 2]) + v


def enc_password(pw, req_auth, secret):
    pw = pw.encode()
    pw += b"\x00" * ((16 - len(pw) % 16) % 16)
    out = b""
    prev = req_auth
    for off in range(0, len(pw), 16):
        block = pw[off:off + 16]
        c = bytes(x ^ y for x, y in zip(block, md5(secret + prev)))
        out += c
        prev = c
    return out


def main():
    ap = argparse.ArgumentParser(description="RADIUS PAP check (IPoE MAC-auth)")
    ap.add_argument("--server", required=True, help="RADIUS server IPv4")
    ap.add_argument("--secret", required=True, help="RADIUS shared secret")
    ap.add_argument("--user", required=True, help="User-Name (MAC untuk MAC-auth)")
    ap.add_argument("--password", default=None,
                    help="User-Password (default = --user)")
    ap.add_argument("--port", type=int, default=1812)
    ap.add_argument("--timeout", type=float, default=3)
    ap.add_argument("--nas-id", default="titian-ipoe")
    a = ap.parse_args()

    secret = a.secret.encode()
    pw = a.password if a.password is not None else a.user
    req_auth = os.urandom(16)
    ident = 1
    # Atribut: User-Name(1), User-Password(2), Calling-Station-Id(31)=MAC,
    # NAS-Identifier(32). NAS dikenali FreeRADIUS dari source IP paket
    # (tabel nas), bukan dari atribut ini.
    attrs = (
        attr(1, a.user)
        + attr(2, enc_password(pw, req_auth, secret))
        + attr(31, a.user)
        + attr(32, a.nas_id)
    )
    pkt = struct.pack("!BBH", 1, ident, 20 + len(attrs)) + req_auth + attrs
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(a.timeout)
    try:
        s.sendto(pkt, (a.server, a.port))
        data, _ = s.recvfrom(4096)
    except socket.timeout:
        print("ERROR: timeout (tidak ada jawaban dari %s:%d)" % (a.server, a.port))
        return 2
    except OSError as e:
        print("ERROR: jaringan: %s" % e)
        return 2
    finally:
        s.close()
    if len(data) < 20:
        print("ERROR: jawaban terlalu pendek (%d byte)" % len(data))
        return 2
    code = data[0]
    # Verifikasi Response Authenticator:
    # MD5(Code+ID+Length+RequestAuth+Attributes+Secret).
    expect = md5(data[:4] + req_auth + data[20:] + secret)
    if expect != data[4:20]:
        print("ERROR: response-authenticator SALAH (secret tidak cocok?)")
        return 2
    if code == 2:
        print("Access-Accept")
        return 0
    if code == 3:
        print("Access-Reject")
        return 1
    print("ERROR: code jawaban tak dikenal: %d" % code)
    return 2


if __name__ == "__main__":
    sys.exit(main())
