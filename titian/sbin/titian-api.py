#!/usr/local/bin/python3
# titian-api.py -- HTTP+JSON API untuk Titian (BRAS operator, Fase 2).
#
# Daemon kecil (Python stdlib SAJA, tanpa dependensi pip) yang membungkus
# backend klish Titian dan menyajikannya sebagai API JSON terstruktur
# untuk web UI operator + myRadDASH.
#
# PRINSIP (blueprint Fase 2):
# - Single-engine: API TIDAK PERNAH menyentuh mpd5/BIRD/pf/dummynet
#   langsung. Semua operasi lewat backend script yang SAMA dengan yang
#   dipakai ACTION klish (titian-pppoe.sh, titian-dhcp.sh, titian-fw.sh,
#   titian-bird.sh, titian-traffic-shape counters via pfctl/netstat).
#   Satu implementasi per operasi; CLI dan API berbagi lapisan itu.
# - Input dari web TIDAK PERNAH diinterpolasi ke shell: subprocess
#   selalu argv-list (shell=False), argumen divalidasi ketat dulu.
# - Token + password TIDAK PERNAH dicetak ke log/respons, kecuali token
#   yang baru dibuat via `gentoken` (dicetak SEKALI ke terminal admin
#   root, supaya bisa disimpan ke record NAS myRadDASH).
#
# Kontrak JSON (keputusan user 24 Nov 17:46 — MENGIKAT):
# - Sukses: {"status": "ok", "data": {...}, "meta": {...}}
# - Error:  {"status": "error", "data": null,
#            "error": {"code": "KODE_STABIL", "message": "..."}}
# - HTTP status sesuai makna; error.code stabil; snake_case; angka tetap
#   angka; timestamp ISO 8601 UTC; list bawa meta (total/sort/limit/
#   offset); Content-Type: application/json; charset=utf-8 selalu.
#
# Cara jalan:
#   titian-api.py serve [--config /usr/local/etc/titian-api.conf]
#   titian-api.py gentoken --name <nama> [--config ...]
#   titian-api.py check [--config ...]   (validasi config + backend)
# Service rc.d: titian-api (daemon -p /var/run/titian-api.pid).
#
# Env (untuk mock/test): TITIAN_API_CONF, TITIAN_SBIN, TITIAN_ROOT,
#   PPPOE_CONF, FW_CONF, ISOLATED_CONF, DHCPD_LEASES, TITIAN_STATE_ROOT.
import argparse
import calendar
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import secrets
import signal
import socket
import ssl
import subprocess
import sys
import syslog
import tempfile
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

API_VERSION = "1.0.0"
DEFAULT_CONF = os.environ.get(
    "TITIAN_API_CONF", "/usr/local/etc/titian-api.conf")
DEFAULT_SBIN = os.environ.get("TITIAN_SBIN", "/opt/titian/sbin")
DEFAULT_ROOT = os.environ.get("TITIAN_ROOT", "/opt/titian")
DEFAULT_STATE_ROOT = os.environ.get("TITIAN_STATE_ROOT", "/etc/titian")
DEFAULT_LEASES = os.environ.get("DHCPD_LEASES", "/var/db/dhcpd.leases")
DEFAULT_CERT = os.path.join(DEFAULT_STATE_ROOT, "titian-api-cert.pem")
DEFAULT_KEY = os.path.join(DEFAULT_STATE_ROOT, "titian-api-key.pem")

IP_RE = re.compile(r"^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
                   r"\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
                   r"\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
                   r"\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$")
USER_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MAC_RE = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
TOKEN_RE = re.compile(r"^[0-9a-f]{32,128}$")
SESSION_ID_RE = re.compile(r"^(pppoe-[A-Za-z0-9_-]{1,64}"
                           r"|ipoe-[0-9a-f]{12})$")
IFACE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")
BRIDGE_RE = re.compile(r"^bridge[0-9]+$")
VXLAN_RE = re.compile(r"^vxlan[0-9]+$")
SECRET_WORDS = re.compile(r"password|secret|token|passwd", re.IGNORECASE)

log = logging.getLogger("titian-api")


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def valid_ip(s):
    return isinstance(s, str) and IP_RE.match(s) is not None


def valid_user(s):
    return isinstance(s, str) and USER_RE.match(s) is not None


def valid_mac(s):
    return isinstance(s, str) and MAC_RE.match(s.lower()) is not None


def valid_iface(s):
    return isinstance(s, str) and IFACE_RE.match(s) is not None


def sanitize_backend_text(text):
    # Pesan error backend boleh masuk ke respons — KECUALI bila mengandung
    # kata password/secret/token (jangan bocorkan kredensial lewat API).
    if not text:
        return ""
    first = text.strip().split("\n")[0][:300]
    if SECRET_WORDS.search(first):
        return "backend error (detail disembunyikan — lihat syslog router)"
    return first


class ApiError(Exception):
    def __init__(self, http_status, code, message):
        super().__init__(message)
        self.http_status = http_status
        self.code = code
        self.message = message


class BackendError(Exception):
    pass


# ---------------------------------------------------------------- config
class Config:
    def __init__(self, path):
        self.path = path
        self.bind = "127.0.0.1"
        self.port = 8443
        self.isolir_web_ip = None
        self.isolir_web_port = None
        self.rate_limit = 60
        self.cert = DEFAULT_CERT
        self.key = DEFAULT_KEY
        self.tokens = {}  # name -> hex

    def load(self):
        if not os.path.isfile(self.path):
            raise ApiError(500, "internal_error",
                           "config tidak ditemukan: %s" % self.path)
        with open(self.path, "r") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if not parts:
                    continue
                key = parts[0]
                if key == "bind" and len(parts) == 2:
                    self.bind = parts[1]
                elif key == "port" and len(parts) == 2:
                    self.port = int(parts[1])
                elif key == "isolir-web" and len(parts) == 2:
                    ip, _, port = parts[1].partition(":")
                    if not valid_ip(ip):
                        raise ApiError(500, "internal_error",
                                       "config isolir-web: IP tidak valid")
                    try:
                        port = int(port)
                    except ValueError:
                        raise ApiError(500, "internal_error",
                                       "config isolir-web: port tidak valid")
                    if not 1 <= port <= 65535:
                        raise ApiError(500, "internal_error",
                                       "config isolir-web: port 1-65535")
                    self.isolir_web_ip = ip
                    self.isolir_web_port = port
                elif key == "rate-limit" and len(parts) == 2:
                    self.rate_limit = int(parts[1])
                elif key == "cert" and len(parts) == 2:
                    self.cert = parts[1]
                elif key == "key" and len(parts) == 2:
                    self.key = parts[1]
                elif key == "token" and len(parts) == 3:
                    self.tokens[parts[1]] = parts[2]
        if self.bind == "0.0.0.0":
            raise ApiError(500, "internal_error",
                           "config bind 0.0.0.0 DITOLAK — API hanya boleh "
                           "listen di IP manajemen / 127.0.0.1")
        if not valid_ip(self.bind):
            raise ApiError(500, "internal_error",
                           "config bind bukan IPv4 valid: %s" % self.bind)
        if not 1 <= self.port <= 65535:
            raise ApiError(500, "internal_error",
                           "config port 1-65535")
        if not self.tokens:
            raise ApiError(500, "internal_error",
                           "config tidak berisi token — buat dulu: "
                           "titian-api.py gentoken --name <nama>")
        for name, tok in self.tokens.items():
            if not TOKEN_RE.match(tok):
                raise ApiError(500, "internal_error",
                               "config token %s bukan hex 32-128 char" % name)

    def token_name(self, presented):
        # Return nama token bila cocok (hmac.compare_digest — anti timing).
        for name, tok in self.tokens.items():
            if hmac.compare_digest(tok, presented):
                return name
        return None


def cmd_gentoken(args):
    # Buat token baru (atau ganti token nama yang sama), tulis ke config
    # mode 600, CETAK SEKALI ke terminal admin root (supaya bisa disimpan
    # ke record NAS myRadDASH). Sesudah ini token tidak ditampilkan lagi.
    if not USER_RE.match(args.name):
        print("gentoken: nama harus [A-Za-z0-9_-]{1,64}", file=sys.stderr)
        return 2
    path = args.config
    token = secrets.token_hex(32)
    lines = []
    if os.path.isfile(path):
        with open(path, "r") as f:
            for raw in f:
                if raw.strip().startswith("token %s " % args.name):
                    continue
                lines.append(raw)
    lines.append("token %s %s\n" % (args.name, token))
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(lines)
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    print("token %s: %s" % (args.name, token))
    print("SIMPAN SEKARANG ke record NAS myRadDASH — token ini tidak "
          "ditampilkan lagi (tersimpan di %s, mode 600)." % path)
    return 0


def ensure_tls(cfg):
    # Sertifikat self-signed bila belum ada (openssl). Produksi: ganti
    # dengan sertifikat proper (cert/key di config) + pin fingerprint
    # di myRadDASH bila perlu.
    if os.path.isfile(cfg.cert) and os.path.isfile(cfg.key):
        return
    if not os.path.isfile(cfg.cert) or not os.path.isfile(cfg.key):
        log.warning("TLS cert/key belum ada — generate self-signed")
        for p in (os.path.dirname(cfg.cert), os.path.dirname(cfg.key)):
            try:
                os.makedirs(p, exist_ok=True)
            except OSError:
                pass
        rc = subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048",
             "-keyout", cfg.key, "-out", cfg.cert, "-days", "3650",
             "-nodes", "-subj", "/CN=titian-api"],
            capture_output=True, timeout=60).returncode
        if rc != 0:
            raise ApiError(500, "internal_error",
                           "gagal generate sertifikat TLS self-signed "
                           "(openssl tidak ada?)")
        for p in (cfg.cert, cfg.key):
            try:
                os.chmod(p, 0o600)
            except OSError:
                pass


# ------------------------------------------------------------- backend run
def run_backend(argv, timeout=15):
    # argv = list (TIDAK PERNAH shell=True). Return (rc, stdout, stderr).
    try:
        p = subprocess.run(argv, capture_output=True, text=True,
                           timeout=timeout)
        return p.returncode, p.stdout or "", p.stderr or ""
    except subprocess.TimeoutExpired:
        raise BackendError("backend timeout sesudah %ds: %s"
                           % (timeout, argv[0]))
    except OSError as e:
        raise BackendError("backend tidak bisa dijalankan %s: %s"
                           % (argv[0], e))


def sbin(name):
    return os.path.join(DEFAULT_SBIN, name)


# ------------------------------------------------------------ lease parser
def parse_lease_datetime(s):
    # Format isc-dhcpd: "4 2026/11/19 12:00:00" (dow yyyy/mm/dd hh:mm:ss UTC)
    m = re.match(r"\d+\s+(\d+)/(\d+)/(\d+)\s+(\d+):(\d+):(\d+)", s.strip())
    if not m:
        return None
    y, mo, d, h, mi, sec = (int(x) for x in m.groups())
    try:
        return calendar.timegm((y, mo, d, h, mi, sec, 0, 0, 0))
    except Exception:
        return None


def read_active_leases(path):
    # Sama seperti titian-ipoe-acct.py read_active_leases: blok TERAKHIR
    # per IP yang berlaku (file lease append-only).
    # Return {ip: {mac, starts_epoch, ends_epoch}} untuk state active.
    if not os.path.isfile(path):
        return {}
    blocks = {}
    cur = None
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
            out[ip] = {"mac": b["mac"],
                       "starts_epoch": b.get("starts"),
                       "ends_epoch": b.get("ends")}
    return out


# --------------------------------------------------------------- counters
def netstat_iface_bytes(iface):
    # netstat -I <iface> -b -> (ibytes, obytes). Return None bila gagal.
    # Kolom dari kanan: Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll.
    try:
        p = subprocess.run(["netstat", "-I", iface, "-b"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 7 and parts[0] == iface:
            try:
                return (int(parts[-5]), int(parts[-2]))
            except ValueError:
                return None
    return None


def pf_rule_bytes():
    # pfctl -a traffic-shape -s rules -v -> {ip: {"rx": bytes, "tx": bytes}}
    # Rule berisi `from <ip>` (upload, dari user) atau `to <ip>`
    # (download, ke user). Counter yang bergerak = Bytes per rule.
    out = {}
    try:
        p = subprocess.run(
            ["pfctl", "-a", "traffic-shape", "-s", "rules", "-v"],
            capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return out
    if p.returncode != 0:
        return out
    cur_rule = None
    for line in p.stdout.splitlines():
        s = line.strip()
        if s.startswith("pass ") or s.startswith("block "):
            cur_rule = s
            continue
        m = re.search(r"Bytes:\s*(\d+)", s)
        if m and cur_rule:
            nbytes = int(m.group(1))
            mfrom = re.search(r" from (\d+\.\d+\.\d+\.\d+)(?:\s|$)", cur_rule)
            mto = re.search(r" to (\d+\.\d+\.\d+\.\d+)(?:\s|$)", cur_rule)
            if mfrom:
                ip = mfrom.group(1)
                out.setdefault(ip, {"rx": 0, "tx": 0})
                out[ip]["tx"] += nbytes
            if mto:
                ip = mto.group(1)
                out.setdefault(ip, {"rx": 0, "tx": 0})
                out[ip]["rx"] += nbytes
            cur_rule = None
    return out


class RateSampler:
    # Sample counter dua kali (selang `interval` detik) -> bps per IP.
    def __init__(self, sessions, interval):
        self.sessions = sessions
        self.interval = interval

    def _sample(self):
        snap = {}
        for s in self.sessions:
            if s["type"] == "pppoe" and s.get("interface") not in (None, "-"):
                b = netstat_iface_bytes(s["interface"])
                if b is not None:
                    snap[s["id"]] = ("ng", b[0], b[1])
            elif s["type"] == "ipoe":
                snap.setdefault(s["id"], None)
        pf = pf_rule_bytes()
        for s in self.sessions:
            if s["type"] == "ipoe" and s["ip"] in pf:
                snap[s["id"]] = ("pf", pf[s["ip"]]["rx"], pf[s["ip"]]["tx"])
        return snap

    def rates(self):
        a = self._sample()
        time.sleep(self.interval)
        b = self._sample()
        res = {}
        for sid, first in a.items():
            second = b.get(sid)
            if first is None or second is None or first[0] != second[0]:
                res[sid] = {"rx_bps": 0, "tx_bps": 0,
                            "rx_bytes_total": (second[1] if second else None),
                            "tx_bytes_total": (second[2] if second else None),
                            "rate_source": first[0] if first else "none"}
                continue
            dt = self.interval
            rx = max(0, (second[1] - first[1]) * 8 // dt)
            tx = max(0, (second[2] - first[2]) * 8 // dt)
            res[sid] = {"rx_bps": rx, "tx_bps": tx,
                        "rx_bytes_total": second[1],
                        "tx_bytes_total": second[2],
                        "rate_source": first[0]}
        for sid in b:
            if sid not in res:
                res[sid] = {"rx_bps": 0, "tx_bps": 0,
                            "rx_bytes_total": b[sid][1] if b[sid] else None,
                            "tx_bytes_total": b[sid][2] if b[sid] else None,
                            "rate_source": b[sid][0] if b[sid] else "none"}
        return res


# ------------------------------------------------------------ sessions core
def get_pppoe_sessions():
    # Return (sessions, warnings). Session: dict dengan id/type/user/ip/
    # interface. Sumber: titian-pppoe.sh sessions-detail (user|ip|link).
    rc, out, err = run_backend([sbin("titian-pppoe.sh"), "sessions-detail"],
                               timeout=10)
    if rc != 0:
        return [], ["pppoe sessions-detail gagal: %s"
                    % sanitize_backend_text(err or out)]
    sessions = []
    for line in out.splitlines():
        line = line.strip()
        if not line or "|" not in line:
            continue
        parts = line.split("|")
        if len(parts) != 3:
            continue
        user, ip, link = (p.strip() for p in parts)
        if not valid_user(user) or not valid_ip(ip):
            continue
        sessions.append({"id": "pppoe-" + user, "type": "pppoe",
                         "user": user, "ip": ip, "mac": None,
                         "interface": link if link else "-",
                         "uptime_seconds": None, "starts_epoch": None})
    return sessions, []


def get_ipoe_sessions():
    # Return (sessions, warnings). Sumber: file lease dhcpd (parser sama
    # dengan titian-ipoe-acct.py) — list-leases tidak membawa starts.
    try:
        leases = read_active_leases(DEFAULT_LEASES)
    except OSError as e:
        return [], ["ipoe lease file tidak bisa dibaca: %s" % e]
    now = int(time.time())
    sessions = []
    for ip, b in leases.items():
        if not valid_ip(ip) or not valid_mac(b["mac"]):
            continue
        starts = b.get("starts_epoch")
        sessions.append({"id": "ipoe-" + b["mac"].replace(":", ""),
                         "type": "ipoe", "user": b["mac"], "ip": ip,
                         "mac": b["mac"], "interface": None,
                         "uptime_seconds": (max(0, now - starts)
                                            if starts else None),
                         "starts_epoch": starts})
    return sessions, []


def get_isolated_ips():
    rc, out, _err = run_backend([sbin("titian-fw.sh"), "show-isolated"],
                                timeout=10)
    if rc != 0:
        return set(), ["show-isolated gagal"]
    ips = set()
    for line in out.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2 and parts[0] == "isolate" and valid_ip(parts[1]):
            ips.add(parts[1])
    return ips, []


def get_versions():
    # (titian_version, bsdrp_version, bird_variant, bird_version,
    #  frr_version, warnings)
    titian_ver = None
    rc, out, _err = run_backend(["pkg", "info", "titian"], timeout=10)
    if rc == 0:
        m = re.search(r"^Version\s*:\s*(\S+)", out, re.M)
        if m:
            titian_ver = m.group(1)
    rc, out, err = run_backend([sbin("titian-bird.sh"), "show-version"],
                               timeout=10)
    bsdrp = bird_variant = bird_version = frr_version = None
    warnings = []
    if rc != 0:
        warnings.append("show-version gagal: %s"
                        % sanitize_backend_text(err or out))
    else:
        m = re.search(r"^BSDRP\s+(\S+)", out, re.M)
        if m:
            bsdrp = m.group(1)
        m = re.search(r"bird_version=(\d+)", out)
        if m:
            bird_version = int(m.group(1))
            bird_variant = "BIRD %d" % bird_version
        m = re.search(r"FRR\s+([\d.]+)\s*\(([^)]+)\)", out)
        if m:
            frr_version = "%s (%s)" % (m.group(1), m.group(2))
    return titian_ver, bsdrp, bird_variant, bird_version, frr_version, warnings


def collect_sessions(sample_seconds=2):
    # (sessions list lengkap incl. rates + isolated, meta-warnings)
    pppoe, w1 = get_pppoe_sessions()
    ipoe, w2 = get_ipoe_sessions()
    isolated, w3 = get_isolated_ips()
    warnings = w1 + w2 + w3
    sessions = pppoe + ipoe
    if sample_seconds > 0:
        rates = RateSampler(sessions, sample_seconds).rates()
    else:
        rates = {}
    now = int(time.time())
    for s in sessions:
        r = rates.get(s["id"], {"rx_bps": 0, "tx_bps": 0,
                                "rx_bytes_total": None,
                                "tx_bytes_total": None,
                                "rate_source": "none"})
        s["rx_bps"] = r["rx_bps"]
        s["tx_bps"] = r["tx_bps"]
        s["rx_bytes_total"] = r["rx_bytes_total"]
        s["tx_bytes_total"] = r["tx_bytes_total"]
        s["rate_source"] = r["rate_source"]
        s["isolated"] = s["ip"] in isolated
        s.pop("starts_epoch", None)
        if s["type"] == "pppoe" and s.get("uptime_seconds") is None:
            # ng* tidak membawa starts; uptime PPPoE tidak tersedia.
            s["uptime_seconds"] = None
    return sessions, warnings


def sort_sessions(sessions, sort):
    if sort == "usage":
        sessions.sort(key=lambda s: (s["rx_bps"] + s["tx_bps"]),
                      reverse=True)
    elif sort == "user":
        sessions.sort(key=lambda s: s["user"])
    elif sort == "ip":
        sessions.sort(key=lambda s: [int(x) for x in s["ip"].split(".")])
    elif sort == "uptime":
        sessions.sort(key=lambda s: s["uptime_seconds"] or 0, reverse=True)
    else:
        raise ApiError(400, "validation_error",
                       "sort tidak dikenal: %s "
                       "(pilihan: usage|user|ip|uptime)" % sort)
    return sessions


def find_session(sid):
    if not SESSION_ID_RE.match(sid):
        raise ApiError(400, "validation_error",
                       "session id tidak valid: %s" % sid)
    sessions, warnings = collect_sessions(sample_seconds=0)
    for s in sessions:
        if s["id"] == sid:
            return s, warnings
    raise ApiError(404, "not_found", "sesi tidak ditemukan: %s" % sid)


def audit(token_name, action, session, reason, ok, detail=""):
    try:
        syslog.openlog("titian-api", syslog.LOG_PID, syslog.LOG_DAEMON)
        syslog.syslog(syslog.LOG_INFO,
                      "%s %s %s %s (%s) reason=%s ok=%s %s"
                      % (token_name, action, session.get("id", "-"),
                         session.get("user", "-"), session.get("ip", "-"),
                         reason, "yes" if ok else "no", detail))
    except Exception:
        pass


def parse_sample(q):
    raw = q.get("sample", ["2"])[0]
    try:
        v = int(raw)
    except ValueError:
        raise ApiError(400, "validation_error",
                       "sample harus integer detik (0-5)")
    if v < 0 or v > 5:
        raise ApiError(400, "validation_error",
                       "sample harus 0-5 detik")
    return v


def parse_paging(q):
    try:
        limit = int(q.get("limit", ["100"])[0])
        offset = int(q.get("offset", ["0"])[0])
    except ValueError:
        raise ApiError(400, "validation_error",
                       "limit/offset harus integer")
    if limit < 1 or limit > 1000:
        raise ApiError(400, "validation_error", "limit 1-1000")
    if offset < 0:
        raise ApiError(400, "validation_error", "offset >= 0")
    return limit, offset


def parse_reason(body):
    # Alasan WAJIB (blueprint §6: semua aksi kick/isolir beralasan).
    if not isinstance(body, dict):
        raise ApiError(400, "validation_error",
                       "body harus objek JSON")
    reason = body.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        raise ApiError(400, "validation_error",
                       "field 'reason' wajib diisi (alasan kick/isolir)")
    if len(reason) > 200:
        raise ApiError(400, "validation_error",
                       "field 'reason' maksimal 200 karakter")
    return reason.strip()


# ------------------------------------------------------- D1 helpers
# Helper khusus domain D1 (system/config/checkpoints). Semua parser
# best-effort: baris yang gagal di-parse TIDAK dibuang — masuk sebagai
# {"raw": ...} + satu entri di meta.warnings (kontrak §1 DESAIN).
_SIZE_SUFFIX = {"": 1, "B": 1, "K": 1024, "M": 1024 ** 2,
                "G": 1024 ** 3, "T": 1024 ** 4, "P": 1024 ** 5}


def parse_human_size(s):
    # "7.9G" / "456M" / "1024" -> bytes (int). None bila tidak bisa.
    if s is None:
        return None
    s = str(s).strip()
    if not s:
        return None
    m = re.match(r"^(\d+(?:\.\d+)?)\s*([KMGTPE]?)(?:i?B)?$", s, re.I)
    if not m:
        try:
            return int(s)
        except ValueError:
            return None
    return int(float(m.group(1)) * _SIZE_SUFFIX[m.group(2).upper()])


def cap_text_lines(text, max_lines=2000):
    # (teks_dipotong, truncated, lines_total)
    lines = text.splitlines()
    total = len(lines)
    if total > max_lines:
        return "\n".join(lines[:max_lines]), True, total
    return text, False, total


def redact_secret_lines(text):
    # Tiap baris cocok SECRET_WORDS -> "# <redacted>".
    # Return (teks, jumlah_baris_diredaksi).
    out = []
    n = 0
    for line in text.splitlines():
        if SECRET_WORDS.search(line):
            out.append("# <redacted>")
            n += 1
        else:
            out.append(line)
    return "\n".join(out), n


def _to_int(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


def _to_float(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def _page(items, limit, offset):
    return items[offset:offset + limit]


def _list_meta(total, page, limit, offset, warnings, truncated=False,
               lines_total=None):
    meta = {"total": total, "count": len(page), "limit": limit,
            "offset": offset, "warnings": warnings}
    if truncated:
        meta["truncated"] = True
    if lines_total is not None:
        meta["lines_total"] = lines_total
    return meta


# ---------------------------------------------------------------- endpoints
def ep_health(cfg):
    titian_ver, bsdrp, bird_variant, bird_version, frr_version, warnings = \
        get_versions()
    try:
        uptime = int(time.time() - START_TIME)
    except NameError:
        uptime = None
    data = {"api_version": API_VERSION,
            "titian_version": titian_ver,
            "bsdrp_version": bsdrp,
            "bird_variant": bird_variant,
            "bird_version": bird_version,
            "frr_version": frr_version,
            "uptime_seconds": uptime,
            "time_utc": utc_now()}
    return 200, data, {"warnings": warnings}


def ep_sessions(cfg, q):
    sample = parse_sample(q)
    limit, offset = parse_paging(q)
    sort = q.get("sort", ["usage"])[0]
    sessions, warnings = collect_sessions(sample_seconds=sample)
    sort_sessions(sessions, sort)
    total = len(sessions)
    page = sessions[offset:offset + limit]
    data = {"sessions": page}
    meta = {"total": total, "count": len(page),
            "pppoe_count": sum(1 for s in sessions if s["type"] == "pppoe"),
            "ipoe_count": sum(1 for s in sessions if s["type"] == "ipoe"),
            "isolated_count": sum(1 for s in sessions if s["isolated"]),
            "sort": sort, "sample_seconds": sample,
            "limit": limit, "offset": offset, "warnings": warnings}
    return 200, data, meta


def ep_session_detail(cfg, sid, q):
    sample = parse_sample(q)
    s, warnings = find_session(sid)
    if sample > 0:
        rates = RateSampler([s], sample).rates()
        r = rates.get(sid, {})
        s["rx_bps"] = r.get("rx_bps", 0)
        s["tx_bps"] = r.get("tx_bps", 0)
        s["rx_bytes_total"] = r.get("rx_bytes_total")
        s["tx_bytes_total"] = r.get("tx_bytes_total")
        s["rate_source"] = r.get("rate_source", "none")
    isolated, w = get_isolated_ips()
    s["isolated"] = s["ip"] in isolated
    warnings += w
    return 200, {"session": s}, {"warnings": warnings}


def ep_disconnect(cfg, sid, body, token_name):
    reason = parse_reason(body)
    s, _w = find_session(sid)
    if s["type"] == "pppoe":
        rc, out, err = run_backend(
            [sbin("titian-pppoe.sh"), "disconnect", s["user"], s["ip"]],
            timeout=30)
    else:
        # IPoE: kick-lease = lepas lease (reconnect diizinkan). Full kick
        # (blokir MAC) tetap CLI/remote-kick saja.
        rc, out, err = run_backend(
            [sbin("titian-dhcp.sh"), "kick-lease", s["mac"]], timeout=30)
    if rc != 0:
        audit(token_name, "disconnect", s, reason, False,
              sanitize_backend_text(err or out))
        raise ApiError(500, "internal_error",
                       "disconnect gagal: %s" % sanitize_backend_text(err or out))
    # Verifikasi: sesi benar-benar hilang.
    sessions2, _w2 = collect_sessions(sample_seconds=0)
    gone = all(x["id"] != sid for x in sessions2)
    audit(token_name, "disconnect", s, reason, gone,
          "verified=%s" % ("yes" if gone else "no"))
    if not gone:
        raise ApiError(500, "internal_error",
                       "disconnect dilaporkan sukses tapi sesi masih ada")
    data = {"session_id": sid, "type": s["type"], "user": s["user"],
            "ip": s["ip"], "action": "disconnect", "reason": reason,
            "verified": True}
    return 200, data, {}


def ep_isolate(cfg, sid, body, token_name):
    reason = parse_reason(body)
    if not cfg.isolir_web_ip or not cfg.isolir_web_port:
        raise ApiError(400, "validation_error",
                       "web isolir belum dikonfigurasi "
                       "(isi 'isolir-web <ip>:<port>' di config)")
    s, _w = find_session(sid)
    # Firewall harus enable (conf + pf jalan) — isolir tanpa itu sia-sia.
    rc, out, err = run_backend([sbin("titian-fw.sh"), "status"], timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "status firewall gagal: %s"
                       % sanitize_backend_text(err or out))
    if "Enabled" not in out:
        raise ApiError(400, "validation_error",
                       "firewall belum enable — jalankan "
                       "'firewall enable' + commit dulu di klish")
    rc, out, err = run_backend(
        [sbin("titian-fw.sh"), "isolate", s["ip"],
         cfg.isolir_web_ip, str(cfg.isolir_web_port)], timeout=20)
    if rc != 0:
        audit(token_name, "isolate", s, reason, False,
              sanitize_backend_text(err or out))
        raise ApiError(500, "internal_error",
                       "isolate gagal: %s" % sanitize_backend_text(err or out))
    isolated, _w2 = get_isolated_ips()
    ok = s["ip"] in isolated
    audit(token_name, "isolate", s, reason, ok,
          "web=%s:%s" % (cfg.isolir_web_ip, cfg.isolir_web_port))
    if not ok:
        raise ApiError(500, "internal_error",
                       "isolate dilaporkan sukses tapi IP tidak ada "
                       "di daftar isolir")
    data = {"session_id": sid, "type": s["type"], "user": s["user"],
            "ip": s["ip"], "action": "isolate",
            "isolir_web": "%s:%d" % (cfg.isolir_web_ip,
                                     cfg.isolir_web_port),
            "reason": reason, "verified": True}
    return 200, data, {}


def ep_unisolate(cfg, sid, body, token_name):
    reason = parse_reason(body)
    s, _w = find_session(sid)
    isolated, _w2 = get_isolated_ips()
    was = s["ip"] in isolated
    rc, out, err = run_backend(
        [sbin("titian-fw.sh"), "unisolate", s["ip"]], timeout=20)
    if rc != 0:
        audit(token_name, "unisolate", s, reason, False,
              sanitize_backend_text(err or out))
        raise ApiError(500, "internal_error",
                       "unisolate gagal: %s" % sanitize_backend_text(err or out))
    isolated2, _w3 = get_isolated_ips()
    ok = s["ip"] not in isolated2
    audit(token_name, "unisolate", s, reason, ok, "")
    if not ok:
        raise ApiError(500, "internal_error",
                       "unisolate dilaporkan sukses tapi IP masih "
                       "di daftar isolir")
    data = {"session_id": sid, "type": s["type"], "user": s["user"],
            "ip": s["ip"], "action": "unisolate", "reason": reason,
            "was_isolated": was, "verified": True}
    return 200, data, {}


def ep_nas_status(cfg):
    titian_ver, bsdrp, bird_variant, bird_version, frr_version, warnings = \
        get_versions()
    pppoe, w1 = get_pppoe_sessions()
    ipoe, w2 = get_ipoe_sessions()
    isolated, w3 = get_isolated_ips()
    warnings += w1 + w2 + w3
    rc, out, err = run_backend([sbin("titian-pppoe.sh"), "show"], timeout=10)
    pppoe_enabled = None
    pppoe_iface = None
    if rc == 0:
        m = re.search(r"pppoe-server:\s*(\S+)", out)
        if m:
            pppoe_enabled = m.group(1).lower() == "yes"
        m = re.search(r"interface:\s*(\S+)", out)
        if m:
            pppoe_iface = m.group(1)
    else:
        warnings.append("pppoe show gagal: %s" % sanitize_backend_text(err or out))
    rc, out, err = run_backend([sbin("titian-fw.sh"), "status"], timeout=10)
    pf_enabled = None
    if rc == 0:
        pf_enabled = "Enabled" in out
    else:
        warnings.append("firewall status gagal: %s"
                        % sanitize_backend_text(err or out))
    # firewall enable = baca langsung dari firewall.conf (status output
    # tidak mencetak baris enable).
    fw_conf = os.environ.get("FW_CONF", "/usr/local/etc/firewall.conf")
    fw_enabled = None
    try:
        with open(fw_conf, "r") as f:
            for line in f:
                if line.strip() == "enable yes":
                    fw_enabled = True
                    break
                if line.strip() == "enable no":
                    fw_enabled = False
                    break
    except OSError:
        fw_enabled = None
    data = {"bsdrp_version": bsdrp,
            "titian_version": titian_ver,
            "bird_variant": bird_variant,
            "bird_version": bird_version,
            "frr_version": frr_version,
            "pppoe_enabled": pppoe_enabled,
            "pppoe_interface": pppoe_iface,
            "pf_enabled": pf_enabled,
            "firewall_enabled": fw_enabled,
            "sessions_pppoe": len(pppoe),
            "sessions_ipoe": len(ipoe),
            "sessions_total": len(pppoe) + len(ipoe),
            "isolated_count": len(isolated),
            "isolir_web": ("%s:%d" % (cfg.isolir_web_ip, cfg.isolir_web_port)
                           if cfg.isolir_web_ip else None),
            "time_utc": utc_now()}
    return 200, data, {"warnings": warnings}


# ------------------------------------------------------------ D1 endpoints
# Domain D1 — system / config / checkpoints (DESAIN §2 D1, 25 Nov 2026).
# Backend: titian-sys.sh / titian-sysctl.sh / titian-checkpoint.sh /
# titian-show-config.sh / titian-bird.sh show-version (dipakai ulang
# get_versions()) + `w -h` argv langsung. Semua GET, read-only.
def ep_system_version(cfg):
    titian_ver, bsdrp, bird_variant, bird_version, frr_version, warnings = \
        get_versions()
    data = {"api_version": API_VERSION,
            "titian_version": titian_ver,
            "bsdrp_version": bsdrp,
            "bird_variant": bird_variant,
            "bird_version": bird_version,
            "frr_version": frr_version,
            "time_utc": utc_now()}
    return 200, data, {"warnings": warnings}


def ep_system(cfg):
    rc, out, err = run_backend([sbin("titian-sys.sh"), "summary"],
                               timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "system summary gagal: %s"
                       % sanitize_backend_text(err or out))
    fields = {}
    warnings = []
    for line in out.splitlines():
        s = line.strip()
        if not s:
            continue
        if ":" not in s:
            warnings.append("baris summary tidak bisa di-parse: %s"
                            % s[:80])
            continue
        label, _, value = s.partition(":")
        fields[label.strip().rstrip(".").strip()] = value.strip()
    cpu_count = None
    m = re.search(r"\((\d+)\s*CPU\)", fields.get("CPU", ""))
    if m:
        cpu_count = int(m.group(1))
    mem_used_mb = mem_total_mb = None
    m = re.search(r"(\d+)\s*MB terpakai\s*/\s*(\d+)\s*MB total",
                  fields.get("Memori", ""))
    if m:
        mem_used_mb, mem_total_mb = int(m.group(1)), int(m.group(2))
    load_average = None
    parts = fields.get("Beban CPU", "").split()
    if len(parts) >= 3:
        vals = [_to_float(p) for p in parts[:3]]
        if all(v is not None for v in vals):
            load_average = vals
    disk_root = None
    m = re.search(r"(\S+)\s+terpakai\s*/\s*(\S+)\s+total\s*\((\d+)%\)",
                  fields.get("Disk (/)", ""))
    if m:
        disk_root = {"used": m.group(1), "total": m.group(2),
                     "use_percent": int(m.group(3))}
    known = {"Hostname", "OS", "Kernel", "Kernel build", "Arsitektur",
             "Architecture", "Waktu system", "Waktu WIB", "Uptime", "CPU",
             "Memori", "Beban CPU", "Disk (/)", "Titian CLI", "BIRD"}
    data = {"hostname": fields.get("Hostname"),
            "os": fields.get("OS"),
            "kernel": fields.get("Kernel"),
            "kernel_build": fields.get("Kernel build"),
            "architecture": fields.get("Arsitektur")
                            or fields.get("Architecture"),
            "time_local": fields.get("Waktu system"),
            "time_wib": fields.get("Waktu WIB"),
            "uptime": fields.get("Uptime"),
            "cpu": fields.get("CPU"),
            "cpu_count": cpu_count,
            "memory_used_mb": mem_used_mb,
            "memory_total_mb": mem_total_mb,
            "load_average": load_average,
            "disk_root": disk_root,
            "titian_cli": fields.get("Titian CLI"),
            "bird": fields.get("BIRD"),
            "time_utc": utc_now(),
            "extra": {k: v for k, v in fields.items() if k not in known}}
    return 200, data, {"warnings": warnings}


def ep_system_memory(cfg):
    rc, out, err = run_backend([sbin("titian-sys.sh"), "memory"],
                               timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "system memory gagal: %s"
                       % sanitize_backend_text(err or out))
    data = {"total_bytes": None, "used_bytes": None, "free_bytes": None,
            "available_bytes": None, "shared_bytes": None,
            "buffers_cache_bytes": None, "swap_total_bytes": None,
            "swap_used_bytes": None, "swap_free_bytes": None,
            "source": "unknown", "vmstat_lines": []}
    warnings = []
    m_phys = re.search(r"^hw\.physmem:\s*(\d+)", out, re.M)
    m_user = re.search(r"^hw\.usermem:\s*(\d+)", out, re.M)
    if m_phys and m_user:
        # FreeBSD: sysctl hw.physmem/hw.usermem (byte) + vmstat -s.
        # hw.usermem = memori yang tersedia untuk proses user.
        total = int(m_phys.group(1))
        avail = int(m_user.group(1))
        data.update({"total_bytes": total, "used_bytes": total - avail,
                     "available_bytes": avail, "source": "freebsd"})
        for line in out.splitlines():
            s = line.strip()
            if s and not s.startswith("hw."):
                data["vmstat_lines"].append(s)
    else:
        for line in out.splitlines():
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "Mem:" and len(parts) >= 7:
                data.update({"total_bytes": parse_human_size(parts[1]),
                             "used_bytes": parse_human_size(parts[2]),
                             "free_bytes": parse_human_size(parts[3]),
                             "shared_bytes": parse_human_size(parts[4]),
                             "buffers_cache_bytes":
                                 parse_human_size(parts[5]),
                             "available_bytes": parse_human_size(parts[6]),
                             "source": "linux"})
            elif parts[0] == "Swap:" and len(parts) >= 4:
                data.update({"swap_total_bytes":
                                 parse_human_size(parts[1]),
                             "swap_used_bytes": parse_human_size(parts[2]),
                             "swap_free_bytes": parse_human_size(parts[3]),
                             "source": "linux"})
    if data["source"] == "unknown":
        warnings.append("format output memory tidak dikenali "
                        "(bukan sysctl FreeBSD maupun free Linux)")
    return 200, data, {"warnings": warnings}


def ep_system_processes(cfg, q):
    limit, offset = parse_paging(q)
    rc, out, err = run_backend([sbin("titian-sys.sh"), "process"],
                               timeout=15)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "system process gagal: %s"
                       % sanitize_backend_text(err or out))
    lines = out.splitlines()
    _capped, truncated, lines_total = cap_text_lines(out)
    shape = None
    start = 0
    for i, line in enumerate(lines):
        if line.startswith("USER") and "%CPU" in line:
            shape, start = "freebsd", i + 1
            break
        if line.startswith("PID") and "COMMAND" in line:
            shape, start = "linux", i + 1
            break
    procs = []
    warnings = []
    if shape is None:
        warnings.append("header ps tidak dikenali — semua baris "
                        "dikembalikan sebagai raw")
        for line in lines:
            if line.strip():
                procs.append({"raw": line})
    else:
        for line in lines[start:]:
            if not line.strip():
                continue
            if shape == "freebsd":
                # USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND
                parts = line.split(None, 10)
                if len(parts) < 11:
                    procs.append({"raw": line})
                    warnings.append("baris ps tidak bisa di-parse: %s"
                                    % line[:80])
                    continue
                (user, pid, cpu, mem, vsz, rss, tty, stat, started,
                 ptime, cmd) = parts
                procs.append({"user": user, "pid": _to_int(pid),
                              "cpu_percent": _to_float(cpu),
                              "mem_percent": _to_float(mem),
                              "vsz_kb": _to_int(vsz), "rss_kb": _to_int(rss),
                              "tty": tty, "state": stat,
                              "started": started, "time": ptime,
                              "command": cmd})
            else:
                # Linux `ps axf`: PID TTY STAT TIME COMMAND
                parts = line.split(None, 4)
                if len(parts) < 5:
                    procs.append({"raw": line})
                    warnings.append("baris ps tidak bisa di-parse: %s"
                                    % line[:80])
                    continue
                pid, tty, stat, ptime, cmd = parts
                procs.append({"user": None, "pid": _to_int(pid),
                              "cpu_percent": None, "mem_percent": None,
                              "vsz_kb": None, "rss_kb": None,
                              "tty": tty, "state": stat,
                              "started": None, "time": ptime,
                              "command": cmd})
    page = _page(procs, limit, offset)
    meta = _list_meta(len(procs), page, limit, offset, warnings,
                      truncated=truncated, lines_total=lines_total)
    return 200, {"processes": page}, meta


def ep_system_connections(cfg, q):
    limit, offset = parse_paging(q)
    rc, out, err = run_backend([sbin("titian-sys.sh"), "connections"],
                               timeout=15)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "system connections gagal: %s"
                       % sanitize_backend_text(err or out))
    lines = out.splitlines()
    _capped, truncated, lines_total = cap_text_lines(out)
    shape = None
    start = 0
    for i, line in enumerate(lines):
        if line.startswith("Proto"):
            shape, start = "netstat", i + 1
            break
        if line.startswith("Netid"):
            shape, start = "ss", i + 1
            break
    conns = []
    warnings = []
    if shape is None:
        warnings.append("header connections tidak dikenali — semua "
                        "baris dikembalikan sebagai raw")
        for line in lines:
            if line.strip():
                conns.append({"raw": line})
    else:
        for line in lines[start:]:
            s = line.strip()
            if not s:
                continue
            if shape == "netstat" and s.startswith("Active"):
                # Bagian "Active UNIX domain sockets" — bukan koneksi
                # internet; berhenti di sini (terdokumentasi).
                break
            if shape == "netstat":
                # Proto Recv-Q Send-Q Local Foreign [State]
                parts = s.split()
                if len(parts) < 5:
                    conns.append({"raw": line})
                    warnings.append("baris netstat tidak bisa di-parse: "
                                    "%s" % s[:80])
                    continue
                conns.append({"protocol": parts[0],
                              "recv_q": _to_int(parts[1]),
                              "send_q": _to_int(parts[2]),
                              "local_address": parts[3],
                              "foreign_address": parts[4],
                              "state": parts[5] if len(parts) > 5 else None,
                              "process": None})
            else:
                # ss: Netid State Recv-Q Send-Q Local Peer [Process]
                parts = s.split(None, 6)
                if len(parts) < 6:
                    conns.append({"raw": line})
                    warnings.append("baris ss tidak bisa di-parse: %s"
                                    % s[:80])
                    continue
                conns.append({"protocol": parts[0], "state": parts[1],
                              "recv_q": _to_int(parts[2]),
                              "send_q": _to_int(parts[3]),
                              "local_address": parts[4],
                              "foreign_address": parts[5],
                              "process": parts[6] if len(parts) > 6
                                         else None})
    page = _page(conns, limit, offset)
    meta = _list_meta(len(conns), page, limit, offset, warnings,
                      truncated=truncated, lines_total=lines_total)
    return 200, {"connections": page}, meta


def ep_system_storage(cfg, q):
    limit, offset = parse_paging(q)
    rc, out, err = run_backend([sbin("titian-sys.sh"), "storage"],
                               timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "system storage gagal: %s"
                       % sanitize_backend_text(err or out))
    items = []
    warnings = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) != 6:
            items.append({"raw": line})
            warnings.append("baris storage tidak bisa di-parse: %s"
                            % line[:80])
            continue
        fs, size, used, avail, pct, mnt = (p.strip() for p in parts)
        use_pct = _to_int(pct)
        if use_pct is None:
            warnings.append("use_pct storage bukan angka: %s" % line[:80])
        items.append({"filesystem": fs, "size": size, "used": used,
                      "available": avail, "use_percent": use_pct,
                      "mounted_on": mnt,
                      "size_bytes": parse_human_size(size),
                      "used_bytes": parse_human_size(used),
                      "available_bytes": parse_human_size(avail)})
    page = _page(items, limit, offset)
    meta = _list_meta(len(items), page, limit, offset, warnings)
    return 200, {"storage": page}, meta


def ep_system_sysctl(cfg, q):
    limit, offset = parse_paging(q)
    rc, out, err = run_backend([sbin("titian-sysctl.sh"), "show"],
                               timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "system sysctl gagal: %s"
                       % sanitize_backend_text(err or out))
    items = []
    warnings = []
    lines = out.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^\s+(\S+)\s+=\s+(.+?)\s+\(tersimpan:\s+(.*?)\)\s*$",
                     line)
        if m:
            meaning = None
            if i + 1 < len(lines):
                m2 = re.match(r"^\s+arti:\s*(.*)$", lines[i + 1])
                if m2:
                    meaning = m2.group(1).strip()
                    i += 1
            items.append({"key": m.group(1),
                          "value_live": m.group(2).strip(),
                          "value_saved": m.group(3).strip(),
                          "meaning": meaning})
        elif (not line.strip() or line.startswith("Sysctl")
              or "(none yet" in line):
            pass
        else:
            items.append({"key": None, "value_live": None,
                          "value_saved": None, "meaning": None,
                          "raw": line.strip()})
            warnings.append("baris sysctl tidak bisa di-parse: %s"
                            % line.strip()[:80])
        i += 1
    page = _page(items, limit, offset)
    meta = _list_meta(len(items), page, limit, offset, warnings)
    return 200, {"sysctl": page}, meta


def ep_system_logins(cfg, q):
    limit, offset = parse_paging(q)
    # `w -h` argv langsung (bukan lewat sbin): perintah baca sistem,
    # tanpa argumen dari web. Format kolom: USER TTY FROM LOGIN@ IDLE
    # JCPU PCPU WHAT (WHAT boleh kosong).
    rc, out, err = run_backend(["w", "-h"], timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "system logins gagal: %s"
                       % sanitize_backend_text(err or out))
    items = []
    warnings = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split(None, 7)
        if len(parts) < 7:
            items.append({"raw": line})
            warnings.append("baris w tidak bisa di-parse: %s"
                            % line[:80])
            continue
        items.append({"user": parts[0], "tty": parts[1],
                      "from": parts[2], "login": parts[3],
                      "idle": parts[4], "jcpu": parts[5],
                      "pcpu": parts[6],
                      "what": parts[7] if len(parts) == 8 else None})
    page = _page(items, limit, offset)
    meta = _list_meta(len(items), page, limit, offset, warnings)
    return 200, {"logins": page}, meta


def ep_system_hardware(cfg):
    sections = {}
    warnings = []
    ok = 0
    any_truncated = False
    for name in ("cpu", "dmi", "pci"):
        rc, out, err = run_backend([sbin("titian-sys.sh"), name],
                                   timeout=15)
        if rc != 0:
            warnings.append("hardware %s gagal: %s"
                            % (name, sanitize_backend_text(err or out)))
            sections[name] = {"text": "", "lines": 0, "truncated": False,
                              "lines_total": 0,
                              "error": sanitize_backend_text(err or out)}
            continue
        ok += 1
        text, trunc, total = cap_text_lines(out)
        any_truncated = any_truncated or trunc
        sections[name] = {"text": text,
                          "lines": len(text.splitlines()) if text else 0,
                          "truncated": trunc, "lines_total": total,
                          "error": None}
    if ok == 0:
        raise ApiError(500, "internal_error",
                       "hardware gagal (cpu/dmi/pci semua gagal): %s"
                       % "; ".join(warnings))
    meta = {"warnings": warnings}
    if any_truncated:
        meta["truncated"] = True
    data = {"sections": sections,
            "source": "show hardware cpu/dmi/pci"}
    return 200, data, meta


def ep_services(cfg, q):
    limit, offset = parse_paging(q)
    rc, out, err = run_backend([sbin("titian-sys.sh"), "services"],
                               timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "services gagal: %s"
                       % sanitize_backend_text(err or out))
    items = []
    warnings = []
    for line in out.splitlines():
        s = line.strip()
        if not s:
            continue
        m = re.match(r"^\[\s*([+\-?])\s*\]\s+(\S+)\s*$", s)
        if m:
            # Linux `service --status-all`: + jalan, - berhenti,
            # ? tidak diketahui.
            status = {"+": "running", "-": "stopped",
                      "?": "unknown"}[m.group(1)]
            items.append({"name": m.group(2), "status": status, "raw": s})
            continue
        if "/" in s:
            # FreeBSD `service -e`: satu path rc per baris (= enabled).
            name = s.rsplit("/", 1)[-1]
            if re.match(r"^[A-Za-z0-9_.-]+$", name):
                items.append({"name": name, "status": "enabled", "raw": s})
                continue
        if re.match(r"^[A-Za-z0-9_.-]+$", s):
            items.append({"name": s, "status": None, "raw": s})
            continue
        items.append({"name": None, "status": None, "raw": s})
        warnings.append("baris services tidak bisa di-parse: %s" % s[:80])
    items.sort(key=lambda x: x["name"] or "")
    page = _page(items, limit, offset)
    meta = _list_meta(len(items), page, limit, offset, warnings)
    return 200, {"services": page}, meta


def ep_service_detail(cfg, name, q):
    if not re.match(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$", name):
        raise ApiError(400, "validation_error",
                       "nama service tidak valid: %s" % name)
    rc, out, err = run_backend([sbin("titian-sys.sh"), "service-status",
                                name], timeout=10)
    text = (out or "").strip() or (err or "").strip()
    low = text.lower()
    if "not running" in low or "stop/waiting" in low:
        status = "stopped"
    elif ("is running" in low or "start/running" in low
          or "active (running)" in low):
        status = "running"
    else:
        status = "unknown"
    if rc != 0:
        if ("does not exist" in low or "unknown service" in low
                or "not found" in low or "no such" in low):
            raise ApiError(404, "not_found",
                           "service tidak dikenal: %s" % name)
        if status == "unknown":
            # rc != 0 tanpa status terbaca: gagal backend sungguhan
            # (FreeBSD: status keluar 1 bila service berhenti — tapi
            # itu sudah tertangkap sebagai "stopped" di atas).
            raise ApiError(500, "internal_error",
                           "service-status gagal: %s"
                           % sanitize_backend_text(err or out))
    data = {"name": name, "status": status, "text": text,
            "lines": len(text.splitlines()) if text else 0}
    return 200, data, {}


def ep_service_ssh(cfg):
    rc, out, err = run_backend([sbin("titian-sys.sh"), "service-ssh"],
                               timeout=10)
    if rc != 0:
        low = ((err or "") + " " + (out or "")).lower()
        if "tidak ditemukan" in low or "not found" in low:
            return 200, {"available": False,
                         "reason": sanitize_backend_text(err or out),
                         "name": "ssh"}, {"warnings": []}
        raise ApiError(500, "internal_error",
                       "service-ssh gagal: %s"
                       % sanitize_backend_text(err or out))
    data = {"name": "ssh", "sshd_running": None, "sshd_pid": None,
            "port": None, "permit_root_login": None, "use_dns": None,
            "listen": []}
    warnings = []
    for line in out.splitlines():
        s = line.strip()
        if not s or s == "SSH service:":
            continue
        m = re.match(r"^sshd:\s+running\s+\(pid\s+(\d+)\)", s)
        if m:
            data["sshd_running"] = True
            data["sshd_pid"] = int(m.group(1))
            continue
        if re.match(r"^sshd:\s+not running", s):
            data["sshd_running"] = False
            continue
        m = re.match(r"^Port:\s+(\d+)\s*$", s)
        if m:
            data["port"] = int(m.group(1))
            continue
        m = re.match(r"^PermitRootLogin:\s+(\S+)\s*$", s)
        if m:
            data["permit_root_login"] = m.group(1)
            continue
        m = re.match(r"^UseDNS:\s+(\S+)\s*$", s)
        if m:
            data["use_dns"] = m.group(1)
            continue
        m = re.match(r"^Listen:\s+(.+)$", s)
        if m:
            data["listen"] = m.group(1).split()
            continue
        warnings.append("baris service-ssh tidak bisa di-parse: %s"
                        % s[:80])
    return 200, data, {"warnings": warnings}


def ep_config(cfg, which):
    # which = "running" | "startup". Tier T + REDAKSI WAJIB (tiap baris
    # cocok SECRET_WORDS -> "# <redacted>"), cap 5000 baris.
    warnings = []
    if which == "running":
        # titian-show-config.sh running HANYA men-cat file dump
        # /tmp/titian-show-run.conf yang ditulis klish `<CONFIG
        # operation="dump">` — dari API file itu basi/kosong. Jalur
        # yang benar: titian-checkpoint.sh dump-running <file> (baca
        # saja: konf dump -> batch clish show running-config ->
        # fallback startup-config; sudah dipakai checkpoint save).
        # Verifikasi read-only dari sumber titian-checkpoint.sh.
        tmp = tempfile.NamedTemporaryFile(
            prefix="titian-show-run-", suffix=".conf", delete=False)
        tmp.close()
        try:
            rc, out, err = run_backend(
                [sbin("titian-checkpoint.sh"), "dump-running", tmp.name],
                timeout=30)
            if rc != 0:
                raise ApiError(500, "internal_error",
                               "config running gagal: %s"
                               % sanitize_backend_text(err or out))
            if "fallback ke startup-config" in (err or ""):
                warnings.append("dump live gagal — isi dari "
                                "startup-config (config terakhir yang "
                                "di-save), bukan tree live")
            with open(tmp.name, "r", errors="replace") as f:
                text = f.read()
        finally:
            try:
                os.unlink(tmp.name)
            except OSError:
                pass
        source = "show running-config"
    else:
        rc, out, err = run_backend(
            [sbin("titian-show-config.sh"), "startup", "no-more"],
            timeout=15)
        if rc != 0:
            raise ApiError(500, "internal_error",
                           "config startup gagal: %s"
                           % sanitize_backend_text(err or out))
        text = out
        source = "show startup-config"
    redacted, nred = redact_secret_lines(text)
    lines_total = len(text.splitlines())
    truncated = False
    if lines_total > 5000:
        redacted = "\n".join(redacted.splitlines()[:5000])
        truncated = True
    data = {"config_text": redacted,
            "lines": len(redacted.splitlines()) if redacted else 0,
            "source": source}
    meta = {"warnings": warnings, "truncated": truncated,
            "lines_total": lines_total, "redacted_lines": nred}
    return 200, data, meta


def ep_checkpoints(cfg, q):
    limit, offset = parse_paging(q)
    rc, out, err = run_backend([sbin("titian-checkpoint.sh"), "list"],
                               timeout=30)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "checkpoints gagal: %s"
                       % sanitize_backend_text(err or out))
    items = []
    warnings = []
    if "(none yet" not in out:
        for line in out.splitlines():
            s = line.rstrip()
            if not s.strip():
                continue
            if s.startswith("Name") and "DIBUAT" in s:
                continue
            if s.strip().startswith("* ="):
                continue
            m = re.match(r"^(\S+)\s+(\d{4}-\d{2}-\d{2} "
                         r"\d{2}:\d{2}:\d{2} WIB)\s*(\*)?\s*$", s)
            if m:
                items.append({"name": m.group(1),
                              "created_wib": m.group(2),
                              "current": bool(m.group(3))})
                continue
            m2 = re.match(r"^(\S+)\s+\(tanpa meta\)\s*(\*)?\s*$", s)
            if m2:
                items.append({"name": m2.group(1), "created_wib": None,
                              "current": bool(m2.group(2))})
                continue
            items.append({"name": None, "created_wib": None,
                          "current": False, "raw": s})
            warnings.append("baris checkpoint tidak bisa di-parse: %s"
                            % s[:80])
    page = _page(items, limit, offset)
    meta = _list_meta(len(items), page, limit, offset, warnings)
    return 200, {"checkpoints": page}, meta


# ------------------------------------------------------- D2: interfaces
# Domain D2 — interfaces / IP / routes (25 Nov 2026). Semua endpoint di
# sini GET read-only dan hanya membungkus backend klish yang SAMA dengan
# ACTION `show` (titian-show.sh, titian-tune.sh, titian-bridge.sh,
# titian-vxlan.sh, titian-bird.sh show-routing, titian-static.sh show).
# TIDAK ADA subcommand backend baru: parser di bawah membaca output
# `show` yang sudah ada (tabel fixed-width titian-show.sh, ifconfig/ip,
# netstat -rn, arp -a, blok `== bridge ==`, blok show_one vxlan).
# Backend diverifikasi read-only dari sumber sbin-ref (hanya ifconfig/ip/
# netstat/arp/sysctl/cat/birdc show — tanpa set/destroy/add).
# Baris yang gagal di-parse TIDAK dibuang: masuk field `raw` (record) /
# `unparsed_lines` (sub-baris) + `meta.warnings`.
# Cap output backend: 2000 baris (meta.truncated + meta.lines_total).

def parse_bool_param(q, name, default=False):
    raw = q.get(name, [None])[0]
    if raw is None:
        return default
    v = raw.strip().lower()
    if v in ("true", "1", "yes", "on"):
        return True
    if v in ("false", "0", "no", "off"):
        return False
    raise ApiError(400, "validation_error",
                   "%s harus boolean (true|false): %s" % (name, raw))


def _cap_lines(text, limit=2000):
    # Terima teks (str) ATAU daftar baris (list): D1/D2 memanggil dengan
    # out.splitlines() (list), D3/D4a/D4b dengan out (str). Empat definisi
    # per-domain digabung di sini (merge) agar tidak saling menimpa.
    # -> (lines, truncated, lines_total)
    if isinstance(text, (list, tuple)):
        lines = list(text)
    else:
        lines = (text or "").splitlines()
    if len(lines) > limit:
        return lines[:limit], True, len(lines)
    return lines, False, len(lines)


def _cap_text(out, limit=2000):
    # -> (text, lines_shown, truncated, lines_total)
    lines = out.splitlines()
    if len(lines) > limit:
        return "\n".join(lines[:limit]), limit, True, len(lines)
    return out, len(lines), False, len(lines)


def _to_int(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


def _netmask_to_prefix(mask, family):
    # "0xffffff00" / "255.255.255.0" -> jumlah bit 1. None bila tak dikenal.
    if not mask:
        return None
    try:
        if mask.lower().startswith("0x"):
            return bin(int(mask, 16)).count("1")
        parts = mask.split(".")
        if len(parts) == 4:
            return sum(bin(int(p)).count("1") for p in parts)
    except ValueError:
        return None
    return None


def _parse_addr_token(tok):
    # "10.10.2.6", "10.10.2.6/24", "2001:db8::1/64", "fe80::1%em0/64"
    # -> dict alamat, atau None untuk "-" / kosong. family None bila
    # alamat tidak dikenali ipaddress (tetap dikembalikan + warning).
    if not tok or tok == "-":
        return None
    m = re.match(r"^([^/%]+)(?:%([^/]+))?(?:/(\d+))?$", tok)
    if not m:
        return {"address": tok, "prefix_length": None, "family": None,
                "peer": None, "zone": None}
    addr, zone, plen = m.group(1), m.group(2), m.group(3)
    try:
        fam = "ipv6" if ipaddress.ip_address(addr).version == 6 else "ipv4"
    except ValueError:
        fam = None
    return {"address": addr,
            "prefix_length": int(plen) if plen is not None else None,
            "family": fam, "peer": None, "zone": zone}


def _looks_like_addr(tok):
    # Baris lanjutan tabel interfaces: token pertama = alamat, bukan nama.
    # Nama interface tidak pernah mengandung ":" dan tidak pernah berbentuk
    # dotted-quad IPv4.
    if ":" in tok:
        return True
    return re.match(r"^\d{1,3}(\.\d{1,3}){3}(/\d+)?$", tok) is not None


def _add_addr_tokens(addrs, toks, warnings):
    # toks: [addr] atau [addr, "peer", peeraddr]. Token "-" = tanpa alamat.
    if not toks:
        return
    d = _parse_addr_token(toks[0])
    if d is None:
        return
    if len(toks) >= 3 and toks[1] == "peer":
        d["peer"] = toks[2]
    if d["family"] is None:
        warnings.append("alamat tidak dikenal: %s" % toks[0][:40])
    addrs.append(d)


def _state_from_code(code):
    return {"u": ("up", "u"), "D": ("down", "D"),
            "L": ("loopback", "L")}.get(code, (None, None))


def _state_from_admin_link(name, admin, link):
    if name.startswith("lo"):
        return "loopback", "L"
    if link == "up":
        return "up", "u"
    return "down", "D"


def _parse_interfaces_table(lines):
    # Tabel `titian-show.sh interfaces` (FreeBSD ifconfig -a + Linux
    # `ip -o addr`): baris `nama alamat [peer x] state desc`, baris
    # lanjutan alamat tambahan (nama kosong), header "Codes:"/kolom/garis.
    items = []
    warnings = []
    cur = None
    for line in lines:
        s = line.strip()
        if not s:
            continue
        if s.startswith("Codes:") or s.startswith("Interface"):
            continue
        if set(s) <= set("- "):
            continue
        toks = s.split()
        if _looks_like_addr(toks[0]):
            if cur is None:
                warnings.append("baris alamat tanpa interface: %s"
                                % s[:80])
                continue
            _add_addr_tokens(cur["addresses"], toks, warnings)
            continue
        name = toks[0]
        if len(toks) < 3:
            warnings.append("baris interface tidak bisa di-parse: %s"
                            % s[:80])
            cur = {"name": name, "state": None, "state_code": None,
                   "admin": None, "link": None, "addresses": [],
                   "description": None, "raw": s}
            items.append(cur)
            continue
        idx = 2
        peer = None
        if toks[idx] == "peer":
            peer = toks[idx + 1] if idx + 1 < len(toks) else None
            idx += 2
        if idx >= len(toks) or toks[idx] not in ("u", "D", "L"):
            warnings.append("baris interface tidak bisa di-parse: %s"
                            % s[:80])
            cur = {"name": name, "state": None, "state_code": None,
                   "admin": None, "link": None, "addresses": [],
                   "description": None, "raw": s}
            items.append(cur)
            continue
        state, code = _state_from_code(toks[idx])
        desc = " ".join(toks[idx + 1:]) or None
        cur = {"name": name, "state": state, "state_code": code,
               "admin": None, "link": None, "addresses": [],
               "description": desc}
        _add_addr_tokens(cur["addresses"], [toks[1]] +
                         (["peer", peer] if peer else []), warnings)
        items.append(cur)
    return items, warnings


def _parse_terse_table(lines):
    # Tabel `titian-show.sh terse`: `nama admin link alamat[, alamat...]`.
    items = []
    warnings = []
    for line in lines:
        s = line.strip()
        if not s or s.startswith("Interface"):
            continue
        if set(s) <= set("- "):
            continue
        toks = s.split()
        if len(toks) < 3:
            warnings.append("baris terse tidak bisa di-parse: %s" % s[:80])
            continue
        name, admin, link = toks[0], toks[1], toks[2]
        if admin not in ("up", "disabled") or link not in ("up", "down"):
            warnings.append("baris terse tidak bisa di-parse: %s" % s[:80])
            items.append({"name": name, "admin": None, "link": None,
                          "state": None, "state_code": None,
                          "addresses": [], "description": None, "raw": s})
            continue
        addrs = []
        rest = " ".join(toks[3:])
        if rest and rest != "-":
            for part in rest.split(","):
                part = part.strip()
                if part:
                    _add_addr_tokens(addrs, part.split(), warnings)
        state, code = _state_from_admin_link(name, admin, link)
        items.append({"name": name, "state": state, "state_code": code,
                      "admin": admin, "link": link, "addresses": addrs,
                      "description": None})
    return items, warnings


def _parse_inet_line(rec, toks, warnings):
    # Baris `inet ...` / `inet6 ...` (ifconfig FreeBSD maupun `ip addr`):
    # toks[0]=inet|inet6, toks[1]=alamat, lalu `--> peer`, `netmask HEX`,
    # `prefixlen N`, `brd ...`, `scope ...`.
    fam = "ipv6" if toks[0] == "inet6" else "ipv4"
    d = _parse_addr_token(toks[1])
    if d is None:
        return
    d["family"] = fam
    i = 2
    while i < len(toks):
        if toks[i] == "-->" and i + 1 < len(toks):
            d["peer"] = toks[i + 1]
            i += 2
        elif toks[i] == "netmask" and i + 1 < len(toks):
            d["prefix_length"] = _netmask_to_prefix(toks[i + 1], fam)
            i += 2
        elif toks[i] == "prefixlen" and i + 1 < len(toks):
            d["prefix_length"] = _to_int(toks[i + 1])
            i += 2
        else:
            i += 1
    if d["family"] is None:
        warnings.append("alamat tidak dikenal: %s" % toks[1][:40])
    rec["addresses"].append(d)


def _parse_if_detail(lines, name):
    # `titian-show.sh if-detail <iface>`: ifconfig FreeBSD ATAU
    # `ip -d link show` + `ip -d addr show` (Linux). Best-effort:
    # baris yang tidak dikenali masuk `extra_lines` (bukan warning —
    # itu info, bukan record gagal).
    rec = {"name": name, "state": None, "state_code": None, "admin": None,
           "link": None, "mtu": None, "mac": None, "flags": [],
           "addresses": [], "description": None, "media": None,
           "status": None, "options": None, "groups": [],
           "extra_lines": []}
    warnings = []
    flags = []
    linux_state = None
    for raw in lines:
        s = raw.strip()
        if not s:
            continue
        m = re.match(r"^\d+: (\S+): <([^>]*)> mtu (\d+)"
                     r"(?:.*\bstate (\S+))?", s)
        if m and m.group(1) == name:
            flags = [f for f in m.group(2).split(",") if f]
            rec["mtu"] = int(m.group(3))
            linux_state = m.group(4)
            continue
        m = re.match(r"^(\S+): flags=\S+<([^>]*)>.*\bmtu (\d+)", s)
        if m and m.group(1) == name:
            flags = [f for f in m.group(2).split(",") if f]
            rec["mtu"] = int(m.group(3))
            continue
        m = re.match(r"^link/ether\s+([0-9a-fA-F:]{17})\b", s)
        if m:
            rec["mac"] = m.group(1).lower()
            continue
        m = re.match(r"^ether\s+([0-9a-fA-F:]{17})\b", s)
        if m:
            rec["mac"] = m.group(1).lower()
            continue
        toks = s.split()
        if toks[0] in ("inet", "inet6") and len(toks) >= 2:
            _parse_inet_line(rec, toks, warnings)
            continue
        if s.startswith("valid_lft"):
            continue
        m = re.match(r"^description:\s*(.*)$", s)
        if m:
            rec["description"] = m.group(1) or None
            continue
        m = re.match(r"^media:\s*(.*)$", s)
        if m:
            rec["media"] = m.group(1) or None
            continue
        m = re.match(r"^status:\s*(\S+)", s)
        if m:
            rec["status"] = m.group(1)
            continue
        m = re.match(r"^options=(.*)$", s)
        if m:
            rec["options"] = m.group(1) or None
            continue
        m = re.match(r"^groups:\s*(.*)$", s)
        if m:
            rec["groups"] = m.group(1).split() if m.group(1) else []
            continue
        rec["extra_lines"].append(s)
    rec["flags"] = flags
    admin_up = "UP" in flags
    rec["admin"] = "up" if admin_up else "disabled"
    if name.startswith("lo"):
        rec["link"] = "up"
    elif rec["status"] is not None:
        rec["link"] = "up" if rec["status"] == "active" else "down"
    elif linux_state is not None:
        rec["link"] = ("up" if linux_state == "UP" else
                       "down" if linux_state == "DOWN" else None)
    elif flags:
        rec["link"] = ("up" if ("RUNNING" in flags or "LOWER_UP" in flags)
                       and admin_up else None)
    if name.startswith("lo"):
        rec["state"], rec["state_code"] = "loopback", "L"
    elif admin_up and rec["link"] != "down":
        rec["state"], rec["state_code"] = "up", "u"
    else:
        rec["state"], rec["state_code"] = "down", "D"
    return rec, warnings


def _parse_neighbors(lines):
    # FreeBSD `arp -a`: `? (IP) at MAC on IFACE expires in N seconds
    # [ethernet]`; Linux `ip -d neighbor show`: `IP dev IFACE [lladdr
    # MAC] STATE [...]`.
    items = []
    warnings = []
    states_linux = ("reachable", "stale", "delay", "probe", "failed",
                    "incomplete", "permanent", "noarp")
    for line in lines:
        s = line.strip()
        if not s:
            continue
        m = re.match(r"^\?\s+\(([^)]+)\)\s+at\s+(\S+)\s+on\s+(\S+)"
                     r"\s+expires in\s+(\d+)\s+seconds\s+\[(\w+)\]", s)
        if m:
            ip, mac, iface, exp = m.group(1), m.group(2), m.group(3), m.group(4)
            try:
                fam = ("ipv6" if ipaddress.ip_address(ip).version == 6
                       else "ipv4")
            except ValueError:
                fam = None
            items.append({"ip": ip,
                          "mac": None if mac == "(incomplete)" else mac.lower(),
                          "interface": iface,
                          "state": ("incomplete" if mac == "(incomplete)"
                                    else "complete"),
                          "expires_seconds": int(exp), "family": fam})
            continue
        toks = s.split()
        if len(toks) >= 3 and toks[1] == "dev":
            ip, iface = toks[0], toks[2]
            rest = toks[3:]
            mac = None
            if rest and rest[0] == "lladdr" and len(rest) >= 2:
                mac = rest[1].lower()
                rest = rest[2:]
            state = rest[0].lower() if rest else None
            try:
                fam = ("ipv6" if ipaddress.ip_address(ip).version == 6
                       else "ipv4")
            except ValueError:
                fam = None
            if state not in states_linux:
                warnings.append("baris neighbor tidak bisa di-parse: %s"
                                % s[:100])
                items.append({"ip": ip, "mac": mac, "interface": iface,
                              "state": state, "expires_seconds": None,
                              "family": fam, "raw": s})
                continue
            items.append({"ip": ip, "mac": mac, "interface": iface,
                          "state": state, "expires_seconds": None,
                          "family": fam})
            continue
        warnings.append("baris neighbor tidak bisa di-parse: %s" % s[:100])
        items.append({"ip": None, "mac": None, "interface": None,
                      "state": None, "expires_seconds": None,
                      "family": None, "raw": s})
    return items, warnings


def _parse_bridges(lines):
    # `titian-bridge.sh show [bridge]`: blok `== <nama> ==` berisi baris
    # `flags=...`, `ether ...`, `inet ...`, `member: <iface> flags=...`.
    items = []
    warnings = []
    cur = None
    for line in lines:
        s = line.strip()
        if not s or s == "(no bridges)":
            continue
        m = re.match(r"^==\s+(\S+)\s+==$", s)
        if m:
            cur = {"name": m.group(1), "flags": None, "mac": None,
                   "addresses": [], "members": []}
            items.append(cur)
            continue
        if cur is None:
            warnings.append("baris bridge di luar blok: %s" % s[:100])
            continue
        if s.startswith("flags="):
            cur["flags"] = s[len("flags="):]
            continue
        m = re.match(r"^ether\s+([0-9a-fA-F:]{17})", s)
        if m:
            cur["mac"] = m.group(1).lower()
            continue
        toks = s.split()
        if toks[0] in ("inet", "inet6") and len(toks) >= 2:
            _parse_inet_line(cur, toks, warnings)
            continue
        m = re.match(r"^member:\s+(\S+)\s+flags=(.*)$", s)
        if m:
            cur["members"].append({"interface": m.group(1),
                                   "flags": m.group(2).strip()})
            continue
        warnings.append("baris bridge tidak dikenal: %s" % s[:100])
        cur.setdefault("unparsed_lines", []).append(s)
    return items, warnings


def _parse_vxlan(lines):
    # `titian-vxlan.sh show [iface]`: per blok `nama: UP|DOWN, mtu N`,
    # lalu `VNI .. local .. remote|group [dev ..]|peer - dstport ..`,
    # baris `inet...`, lalu `FDB: ...` (+ baris lanjutan FDB).
    items = []
    missing = []
    warnings = []
    cur = None
    in_fdb = False
    for line in lines:
        s = line.strip()
        if not s:
            cur = None
            in_fdb = False
            continue
        if s == "tidak ada interface vxlan":
            continue
        m = re.match(r"^(\S+):\s+(UP|DOWN),\s+mtu\s+(\S+)\s*$", s)
        if m:
            cur = {"name": m.group(1),
                   "state": "up" if m.group(2) == "UP" else "down",
                   "mtu": _to_int(m.group(3)), "vni": None, "local": None,
                   "remote": None, "group": None, "dev": None,
                   "dstport": None, "addresses": [], "fdb": []}
            items.append(cur)
            in_fdb = False
            continue
        m = re.match(r"^(\S+):\s+tidak ada\s*$", s)
        if m:
            missing.append(m.group(1))
            cur = None
            continue
        if cur is None:
            warnings.append("baris vxlan di luar blok: %s" % s[:100])
            continue
        if in_fdb:
            cur["fdb"].append(s)
            continue
        m = re.match(r"^VNI\s+(\S+)\s+local\s+(\S+)\s+"
                     r"(?:remote\s+(\S+)|group\s+(\S+)"
                     r"(?:\s+dev\s+(\S+))?|peer\s+-)\s+"
                     r"dstport\s+(\S+)\s*$", s)
        if m:
            cur["vni"] = _to_int(m.group(1))
            cur["local"] = None if m.group(2) == "?" else m.group(2)
            cur["remote"] = m.group(3)
            cur["group"] = m.group(4)
            cur["dev"] = m.group(5)
            cur["dstport"] = _to_int(m.group(6))
            continue
        toks = s.split()
        if toks[0] in ("inet", "inet6") and len(toks) >= 2:
            _parse_inet_line(cur, toks, warnings)
            continue
        if s.startswith("FDB:"):
            rest = s[4:].strip()
            if rest == "(kosong)":
                cur["fdb"] = []
            elif rest:
                cur["fdb"].append(rest)
            in_fdb = True
            continue
        warnings.append("baris vxlan tidak dikenal: %s" % s[:100])
        cur.setdefault("unparsed_lines", []).append(s)
    return items, missing, warnings


def _parse_routes_netstat(lines, family):
    # FreeBSD `netstat -rn -f inet|inet6`: kolom Destination Gateway
    # Flags Netif [Expire]. Header "Routing tables"/"Internet[:]".
    items = []
    warnings = []
    for line in lines:
        s = line.strip()
        if (not s or s.startswith("Routing tables")
                or s in ("Internet:", "Internet6:")
                or s.startswith("Destination")):
            continue
        toks = s.split()
        if len(toks) < 4:
            warnings.append("baris route tidak bisa di-parse: %s" % s[:100])
            continue
        expire = None
        if len(toks) >= 5:
            expire = _to_int(toks[4])
        items.append({"destination": toks[0], "gateway": toks[1],
                      "flags": toks[2], "interface": toks[3],
                      "expire_seconds": expire, "family": family,
                      "protocol": None, "metric": None, "scope": None,
                      "src": None, "type": "unicast",
                      "link_down": False, "onlink": False})
    return items, warnings


def _parse_routes_ip(lines, family):
    # Linux `ip route show [prefix]`: `dest [via GW] [dev IF] [proto P]
    # [metric N] [src IP] [scope S] [linkdown] [onlink]`; tipe di depan
    # (`local`/`blackhole`/...) bila ada.
    items = []
    warnings = []
    for line in lines:
        s = line.strip()
        if not s:
            continue
        toks = s.split()
        rtype = "unicast"
        idx = 0
        if toks[0] in ("local", "broadcast", "unreachable", "blackhole",
                       "prohibit", "throw"):
            rtype = toks[0]
            idx = 1
        if idx >= len(toks):
            warnings.append("baris route tidak bisa di-parse: %s" % s[:100])
            continue
        rec = {"destination": toks[idx], "gateway": None, "flags": None,
               "interface": None, "expire_seconds": None,
               "family": family, "protocol": None, "metric": None,
               "scope": None, "src": None, "type": rtype,
               "link_down": False, "onlink": False}
        idx += 1
        while idx < len(toks):
            k = toks[idx]
            if k in ("via", "dev", "proto", "metric", "src", "scope") \
                    and idx + 1 < len(toks):
                v = toks[idx + 1]
                if k == "via":
                    rec["gateway"] = v
                elif k == "dev":
                    rec["interface"] = v
                elif k == "proto":
                    rec["protocol"] = v
                elif k == "metric":
                    rec["metric"] = _to_int(v)
                elif k == "src":
                    rec["src"] = v
                elif k == "scope":
                    rec["scope"] = v
                idx += 2
            elif k == "linkdown":
                rec["link_down"] = True
                idx += 1
            elif k == "onlink":
                rec["onlink"] = True
                idx += 1
            else:
                idx += 1
        items.append(rec)
    return items, warnings


def _parse_routes(lines, family):
    # Deteksi format: header netstat ("Destination"/"Internet:") ATAU
    # baris bentuk netstat (dest gateway FLAGS netif, FLAGS huruf besar).
    # Bentuk kedua WAJIB karena `route <prefix>` di FreeBSD meng-grep
    # netstat -rn sehingga header hilang dan hanya baris cocok yang
    # tersisa — tanpa ini baris itu salah masuk parser `ip route`.
    for line in lines:
        s = line.strip()
        if not s:
            continue
        if s.startswith("Destination") or s in ("Internet:", "Internet6:"):
            return _parse_routes_netstat(lines, family)
        toks = s.split()
        if (len(toks) >= 4 and re.fullmatch(r"[A-Z]+", toks[2])
                and toks[1] not in ("via", "dev", "proto", "metric",
                                    "src", "scope", "table")):
            return _parse_routes_netstat(lines, family)
    return _parse_routes_ip(lines, family)


def _parse_route_prefix(q, family):
    raw = q.get("prefix", [None])[0]
    if raw is None:
        return None
    try:
        net = ipaddress.ip_network(raw, strict=False)
    except ValueError:
        raise ApiError(400, "validation_error",
                       "prefix tidak valid (IP/CIDR): %s" % raw)
    fam = "ipv6" if net.version == 6 else "ipv4"
    if fam != family:
        raise ApiError(400, "validation_error",
                       "prefix %s adalah %s, bukan %s" % (raw, fam, family))
    return raw


def _text_response(argv, source, timeout=15):
    # Tier T: kembalikan output backend apa adanya sebagai config_text.
    rc, out, err = run_backend(argv, timeout=timeout)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "%s gagal: %s" % (source,
                                         sanitize_backend_text(err or out)))
    text, nlines, truncated, total = _cap_text(out)
    data = {"config_text": text, "lines": nlines, "source": source}
    meta = {"warnings": []}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total
    return 200, data, meta


def _paged_list(items, q, warnings, extra_meta=None):
    limit, offset = parse_paging(q)
    total = len(items)
    page = items[offset:offset + limit]
    meta = {"total": total, "count": len(page), "limit": limit,
            "offset": offset, "warnings": warnings}
    if extra_meta:
        meta.update(extra_meta)
    return page, meta


def ep_interfaces(cfg, q):
    terse = parse_bool_param(q, "terse", False)
    parse_bool_param(q, "include_down", False)
    # include_down diterima tapi no-op: daftar SELALU memuat up+down.
    sub = "terse" if terse else "interfaces"
    rc, out, err = run_backend([sbin("titian-show.sh"), sub], timeout=15)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "show interfaces gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, total_lines = _cap_lines(out.splitlines())
    if terse:
        items, warnings = _parse_terse_table(lines)
    else:
        items, warnings = _parse_interfaces_table(lines)
    page, meta = _paged_list(items, q, warnings, {"terse": terse})
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total_lines
    return 200, {"interfaces": page}, meta


def ep_interface_detail(cfg, name, q):
    if not valid_iface(name):
        raise ApiError(400, "validation_error",
                       "nama interface tidak valid: %s" % name)
    detail = parse_bool_param(q, "detail", False)
    argv = [sbin("titian-show.sh"), "if-detail", name]
    if detail:
        argv.append("detail")
    rc, out, err = run_backend(argv, timeout=15)
    if rc != 0:
        if "tidak ditemukan" in (err or out) or "not found" in (err or out):
            raise ApiError(404, "not_found",
                           "interface tidak ditemukan: %s" % name)
        raise ApiError(500, "internal_error",
                       "if-detail gagal: %s" % sanitize_backend_text(err or out))
    lines, truncated, total_lines = _cap_lines(out.splitlines())
    rec, warnings = _parse_if_detail(lines, name)
    meta = {"warnings": warnings}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total_lines
    return 200, {"interface": rec}, meta


def ep_interface_tuning(cfg, name):
    if not valid_iface(name):
        raise ApiError(400, "validation_error",
                       "nama interface tidak valid: %s" % name)
    rc, out, err = run_backend([sbin("titian-tune.sh"), "show", name],
                               timeout=15)
    if rc != 0:
        if "tidak ditemukan" in (err or out) or "not found" in (err or out):
            raise ApiError(404, "not_found",
                           "interface tidak ditemukan: %s" % name)
        raise ApiError(500, "internal_error",
                       "tuning gagal: %s" % sanitize_backend_text(err or out))
    text, nlines, truncated, total = _cap_text(out)
    data = {"interface": name, "config_text": text, "lines": nlines,
            "source": "show interfaces tuning %s" % name}
    meta = {"warnings": []}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total
    return 200, data, meta


def ep_neighbors(cfg, q):
    iface = q.get("interface", [None])[0]
    if iface is not None and not valid_iface(iface):
        raise ApiError(400, "validation_error",
                       "interface tidak valid: %s" % iface)
    # Filter di daemon (exact match): backend FreeBSD mem-filter pakai
    # grep substring, jadi jangan serahkan filter ke backend.
    rc, out, err = run_backend([sbin("titian-show.sh"), "neighbor"],
                               timeout=15)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "show neighbor gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, total_lines = _cap_lines(out.splitlines())
    items, warnings = _parse_neighbors(lines)
    if iface is not None:
        items = [x for x in items if x.get("interface") == iface]
    extra = {"interface": iface} if iface is not None else None
    page, meta = _paged_list(items, q, warnings, extra)
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total_lines
    return 200, {"neighbors": page}, meta


def ep_bridges(cfg, q):
    bridge = q.get("bridge", [None])[0]
    if bridge is not None:
        if not BRIDGE_RE.match(bridge):
            raise ApiError(400, "validation_error",
                           "nama bridge harus bridge[N] (contoh bridge0): %s"
                           % bridge)
    argv = [sbin("titian-bridge.sh"), "show"]
    if bridge is not None:
        argv.append(bridge)
    rc, out, err = run_backend(argv, timeout=15)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "show bridge gagal: %s"
                       % sanitize_backend_text(err or out))
    if bridge is not None and re.search(r"^%s not found$"
                                        % re.escape(bridge), out, re.M):
        raise ApiError(404, "not_found",
                       "bridge tidak ditemukan: %s" % bridge)
    lines, truncated, total_lines = _cap_lines(out.splitlines())
    items, warnings = _parse_bridges(lines)
    extra = {"bridge": bridge} if bridge is not None else None
    page, meta = _paged_list(items, q, warnings, extra)
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total_lines
    return 200, {"bridges": page}, meta


def ep_vxlan_list(cfg, q):
    rc, out, err = run_backend([sbin("titian-vxlan.sh"), "show"], timeout=15)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "show vxlan gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, total_lines = _cap_lines(out.splitlines())
    items, _missing, warnings = _parse_vxlan(lines)
    page, meta = _paged_list(items, q, warnings)
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total_lines
    return 200, {"vxlan": page}, meta


def ep_vxlan_detail(cfg, name):
    if not VXLAN_RE.match(name):
        raise ApiError(400, "validation_error",
                       "nama vxlan harus vxlan[N] (contoh vxlan100): %s"
                       % name)
    rc, out, err = run_backend([sbin("titian-vxlan.sh"), "show", name],
                               timeout=15)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "show vxlan gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, total_lines = _cap_lines(out.splitlines())
    items, missing, warnings = _parse_vxlan(lines)
    if name in missing or not items:
        raise ApiError(404, "not_found",
                       "interface vxlan tidak ditemukan: %s" % name)
    meta = {"warnings": warnings}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total_lines
    return 200, {"vxlan": items[0]}, meta


def ep_routes(cfg, q):
    family = q.get("family", ["ipv4"])[0]
    if family not in ("ipv4", "ipv6"):
        raise ApiError(400, "validation_error",
                       "family harus ipv4|ipv6: %s" % family)
    prefix = _parse_route_prefix(q, family)
    sub = "route6" if family == "ipv6" else "route"
    argv = [sbin("titian-show.sh"), sub]
    if prefix is not None:
        argv.append(prefix)
    rc, out, err = run_backend(argv, timeout=30)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "show route gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, total_lines = _cap_lines(out.splitlines())
    items, warnings = _parse_routes(lines, family)
    extra = {"prefix": prefix} if prefix is not None else None
    page, meta = _paged_list(items, q, warnings, extra)
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total_lines
    return 200, {"routes": page, "family": family}, meta


def ep_routing(cfg):
    return _text_response([sbin("titian-bird.sh"), "show-routing"],
                          "show routing")


def ep_routing_static(cfg):
    return _text_response([sbin("titian-static.sh"), "show"],
                          "show static")


# ------------------------------------------------------- D3: bird/routing
# Perluasan JSON semua menu CLI (D3, 25 Nov 2026): BIRD + protokol
# routing + FRR. Semua GET, read-only, lewat backend titian-*.sh yang
# SAMA dengan ACTION klish; daemon TIDAK PERNAH memanggil birdc/vtysh
# langsung. Parser best-effort: baris gagal parse -> field `raw` +
# meta.warnings, baris tidak dikenali tidak pernah dibuang diam-diam.
# ASUMSI FORMAT (belum terverifikasi di mesin live — verifikasi guest
# oleh koordinator): format tabular birdc 2.20 / vtysh FRR 10.x seperti
# yang dipakai stub mock (lihat laporan D3). Bila format live berbeda,
# parser mengembalikan `raw` + warning, bukan 500.
D3_MAX_LINES = 2000
BIRD_NAME_RE = re.compile(r"^[A-Za-z0-9_]{1,64}$")
BIRD_CHANNEL_RE = re.compile(r"^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$")
WHERE_RE = re.compile(r"^[A-Za-z0-9_ .=<>!&|()\"']{1,200}$")
BIRD_DOWN_MARKERS = ("(BIRD tidak jalan", "(birdc tidak ada")





def _redact_text(text):
    # Desain §1: baris yang cocok /password|secret|token|passwd/i
    # diganti "# <redacted>" SEBELUM masuk respons (Tier T).
    out = []
    for line in (text or "").splitlines():
        if SECRET_WORDS.search(line):
            out.append("# <redacted>")
        else:
            out.append(line)
    return "\n".join(out)


def _text_result(out, source, extra=None):
    # Tier T: {"config_text", "lines", "source"} + redaksi + cap.
    red = _redact_text(out)
    lines, truncated, total = _cap_lines(red)
    data = {"config_text": "\n".join(lines), "lines": len(lines),
            "source": source}
    if extra:
        data.update(extra)
    meta = {"truncated": truncated, "lines_total": total, "warnings": []}
    if truncated:
        meta["warnings"].append("output dipotong di %d baris"
                                % D3_MAX_LINES)
    return 200, data, meta


def _backend_or_500(argv, timeout=15):
    rc, out, err = run_backend(argv, timeout=timeout)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "backend gagal: %s"
                       % sanitize_backend_text(err or out))
    return out


def _bird_down(out):
    return any(m in (out or "") for m in BIRD_DOWN_MARKERS)


def _list_page(items, q, warnings, extra_meta=None):
    limit, offset = parse_paging(q)
    total = len(items)
    page = items[offset:offset + limit]
    meta = {"total": total, "count": len(page), "limit": limit,
            "offset": offset, "warnings": warnings}
    if extra_meta:
        meta.update(extra_meta)
    return page, meta


def _to_int(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


# ------------------------------------------------------------ parser birdc
def _parse_protocols_table(out, warnings, warn_no_header=True):
    # birdc `show protocols [all] [NAME]`:
    #   Name  Proto  Table  State  Since  Info
    #   bgp_x BGP    ---    up     2026-11-24 09:05:00  Established
    # Baris menjorok sesudah satu baris = detail protokol itu.
    protos = []
    header_seen = False
    for line in (out or "").splitlines():
        if not line.strip() or line.startswith("("):
            continue
        if not header_seen:
            if line.startswith("Name") and "Proto" in line:
                header_seen = True
            continue
        if line[0] in " \t":
            if protos:
                protos[-1].setdefault("details", []).append(line.strip())
            else:
                warnings.append("baris detail tanpa protokol: %s"
                                % line.strip()[:120])
            continue
        parts = line.split()
        if len(parts) < 4:
            warnings.append("baris protocols tidak ter-parse: %s"
                            % line[:120])
            protos.append({"raw": line})
            continue
        rest = parts[4:]
        since = None
        info = ""
        if len(rest) >= 2:
            since = rest[0] + " " + rest[1]
            info = " ".join(rest[2:])
        elif len(rest) == 1:
            since = rest[0]
        protos.append({"name": parts[0], "protocol": parts[1],
                       "table": parts[2], "state": parts[3],
                       "since": since, "info": info})
    if not header_seen and warn_no_header:
        warnings.append("header tabel protocols tidak ditemukan")
    return protos


def _detail_lines_to_struct(details):
    # Baris detail `show protocols <nama>`: "Key: value" -> fields,
    # "Channel <nama>:" -> sub-dict channel, sisanya -> detail_lines.
    fields = {}
    channels = {}
    cur_chan = None
    extra = []
    for ln in details or []:
        m = re.match(r"^Channel\s+(\S+):\s*$", ln)
        if m:
            cur_chan = m.group(1)
            channels[cur_chan] = {}
            continue
        m = re.match(r"^([^:]+):\s*(.*)$", ln)
        if m:
            key = m.group(1).strip().lower().replace(" ", "_")
            val = m.group(2).strip()
            if cur_chan is not None:
                channels[cur_chan][key] = val
            else:
                fields[key] = val
            continue
        extra.append(ln)
    return fields, channels, extra


ROUTE_RE = re.compile(
    r"^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s*(\*)?\s*\((\d+)\)"
    r"\s*(\[[^\]]*\])?\s*(.*)$")


def _parse_bird_routes(out, warnings):
    # birdc `show route*`: baris
    #   10.0.0.0/24 unicast [static1 2026-11-24] * (200) [AS65001i]
    # baris menjorok = detail rute itu; "Table X:" = tabel aktif.
    routes = []
    table = None
    for line in (out or "").splitlines():
        if not line.strip() or line.startswith("("):
            continue
        m = re.match(r"^Table\s+(\S+):\s*$", line)
        if m:
            table = m.group(1)
            continue
        if line[0] in " \t":
            if routes:
                routes[-1].setdefault("details", []).append(line.strip())
            continue
        m = ROUTE_RE.match(line)
        if not m:
            warnings.append("baris route tidak ter-parse: %s" % line[:120])
            routes.append({"raw": line, "table": table})
            continue
        prefix, rtype, bracket, star, pref, attrs, rest = m.groups()
        bp = bracket.split(None, 1)
        routes.append({"prefix": prefix, "type": rtype,
                       "protocol": bp[0] if bp else None,
                       "updated": bp[1] if len(bp) > 1 else None,
                       "preferred": star == "*",
                       "preference": int(pref),
                       "attributes": attrs or None,
                       "flags": rest or None, "table": table})
    return routes


def _parse_route_count(out):
    # birdc `show route count`: "N of N routes for N networks [...]".
    m = re.search(r"(\d+)\s+of\s+(\d+)\s+routes\s+for\s+(\d+)\s+networks",
                  out or "")
    if m:
        return {"routes": int(m.group(1)), "routes_total": int(m.group(2)),
                "networks": int(m.group(3))}
    return None


def _parse_route_stats(out, warnings):
    # birdc `show route stats` (format asumsi — lihat laporan D3):
    #   Table master4:
    #     Routes: 2
    tables = []
    cur = None
    for line in (out or "").splitlines():
        if not line.strip() or line.startswith("("):
            continue
        m = re.match(r"^Table\s+(\S+):\s*$", line)
        if m:
            cur = {"table": m.group(1), "metrics": {}}
            tables.append(cur)
            continue
        m = re.match(r"^\s*([^:]+):\s*(\d+)\s*$", line)
        if m and cur is not None:
            cur["metrics"][m.group(1).strip().lower().replace(" ", "_")] = \
                int(m.group(2))
            continue
        if cur is not None:
            cur.setdefault("raw_lines", []).append(line.strip())
        else:
            warnings.append("baris route stats tidak ter-parse: %s"
                            % line.strip()[:120])
    return tables


def _parse_bird_status(out, warnings):
    data = {"available": True}
    for line in (out or "").splitlines():
        if not line.strip() or line.startswith("("):
            continue
        m = re.match(r"^Router ID:\s*(\S+)", line)
        if m:
            data["router_id"] = m.group(1)
            continue
        m = re.match(r"^Current server time is\s+(.+)$", line)
        if m:
            data["server_time"] = m.group(1).strip()
            continue
        m = re.match(r"^Last reboot on\s+(.+)$", line)
        if m:
            data["last_reboot"] = m.group(1).strip()
            continue
        m = re.match(r"^Last reconfiguration on\s+(.+)$", line)
        if m:
            data["last_reconfiguration"] = m.group(1).strip()
            continue
        if "Daemon is up and running" in line:
            data["daemon_state"] = "up"
            continue
        data.setdefault("extra_lines", []).append(line)
    if "router_id" not in data and "daemon_state" not in data:
        warnings.append("output show status tidak dikenali")
    return data


def _parse_symbols(out, warnings):
    # birdc `show symbols [KIND]`: seksi "Routing tables:" / "Protocols:"
    # berisi nama, atau baris "table master4" / "protocol device1".
    kind_map = {"routing tables": "table", "tables": "table",
                "protocols": "protocol", "filters": "filter",
                "functions": "function", "templates": "template",
                "symbols": "symbol", "roa": "roa"}
    symbols = []
    kind = None
    for line in (out or "").splitlines():
        s = line.strip()
        if not s or s.startswith("("):
            continue
        if s.endswith(":"):
            kind = kind_map.get(s[:-1].lower(),
                                s[:-1].lower().replace(" ", "_"))
            continue
        m = re.match(r"^(table|filter|function|protocol|template|roa|symbol)"
                     r"\s+(\S+)\s*$", s, re.I)
        if m:
            symbols.append({"kind": m.group(1).lower(),
                            "name": m.group(2)})
            continue
        parts = s.split()
        if len(parts) == 1:
            symbols.append({"kind": kind, "name": parts[0]})
        else:
            warnings.append("baris symbols tidak ter-parse: %s" % s[:120])
            symbols.append({"kind": kind, "name": parts[0], "raw": s})
    return symbols


def _parse_global_tables(out, warnings):
    # titian-global.sh show-tables: "<nettype> <nama> [opt=val ...]".
    tables = []
    for line in (out or "").splitlines():
        s = line.strip()
        if not s or s.startswith("("):
            continue
        m = re.match(r"^(\S+)\s+(\S+)(?:\s+\[(.*)\])?\s*$", s)
        if not m:
            warnings.append("baris tables tidak ter-parse: %s" % s[:120])
            tables.append({"raw": s})
            continue
        opts = {}
        if m.group(3):
            for kv in m.group(3).split():
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    opts[k] = v
        tables.append({"nettype": m.group(1), "name": m.group(2),
                       "options": opts})
    return tables


BIRDC_IFACE_RE = re.compile(r"^(\S+)\s+(\S+)\s+\(index=(\d+)\)\s*(.*)$")


def _parse_bird_interfaces(out, warnings):
    # birdc `show interfaces [summary]`: "ge1 up (index=2)" + detail.
    ifaces = []
    for line in (out or "").splitlines():
        if not line.strip() or line.startswith("("):
            continue
        if line[0] in " \t":
            if ifaces:
                ifaces[-1].setdefault("details", []).append(line.strip())
            continue
        m = BIRDC_IFACE_RE.match(line)
        if not m:
            warnings.append("baris interfaces tidak ter-parse: %s"
                            % line[:120])
            ifaces.append({"raw": line})
            continue
        ifaces.append({"name": m.group(1), "state": m.group(2),
                       "index": int(m.group(3)),
                       "flags": m.group(4) or None})
    return ifaces


def _parse_bird_records(out, record_re, warnings):
    # Parser generik blok birdc berindentasi (OSPF/RIP): baris yang cocok
    # record_re memulai satu record (group 1 = id); baris "X:" di kolom 0
    # = instance; "Area X:" = area; "Key: value" menjorok = fields.
    records = []
    preamble = []
    cur = None
    instance = None
    area = None
    for line in (out or "").splitlines():
        if not line.strip() or line.startswith("("):
            continue
        m = re.match(r"^([A-Za-z0-9_]+):\s*$", line)
        if m:
            instance = m.group(1)
            continue
        m = re.match(r"^\s*Area\s+(\S+)\s*:\s*$", line)
        if m:
            area = m.group(1)
            continue
        m = record_re.match(line)
        if m:
            cur = {"id": m.group(1), "title": line.strip(),
                   "fields": {}, "lines": []}
            if instance:
                cur["instance"] = instance
            if area:
                cur["area"] = area
            records.append(cur)
            continue
        if cur is None:
            preamble.append(line.strip())
            continue
        s = line.strip()
        m2 = re.match(r"^([^:]{1,40}):\s+(.+)$", s)
        if m2:
            cur["fields"][m2.group(1).strip().lower().replace(" ", "_")] = \
                m2.group(2).strip()
        else:
            cur["lines"].append(s)
    if not records:
        warnings.append("tidak ada record ter-parse (format birdc belum "
                        "dikenali — verifikasi guest diperlukan)")
    return records, preamble


BFD_STATES = {"Up", "Down", "Init", "AdminDown"}


def _parse_bfd_sessions(out, warnings):
    # birdc `show bfd sessions` (format asumsi — lihat laporan D3):
    #   IP address  Interface  State  Since  Interval  Timeout
    #   203.0.113.1 ge1        Up     2026-11-25 09:00:00  0.100  0.300
    sessions = []
    for line in (out or "").splitlines():
        s = line.strip()
        if not s or s.startswith("(") or s.endswith(":"):
            continue
        if s.startswith("IP address"):
            continue
        parts = s.split()
        if len(parts) < 3 or parts[2] not in BFD_STATES:
            warnings.append("baris bfd tidak ter-parse: %s" % s[:120])
            sessions.append({"raw": s})
            continue
        rest = parts[3:]
        since = interval = timeout = None
        if len(rest) >= 4:
            since = rest[0] + " " + rest[1]
            interval, timeout = rest[2], rest[3]
        elif len(rest) == 3:
            since, interval, timeout = rest
        elif len(rest) == 2:
            since, interval = rest
        elif len(rest) == 1:
            since = rest[0]
        sessions.append({"ip": parts[0], "interface": parts[1],
                         "state": parts[2], "since": since,
                         "interval": interval, "timeout": timeout})
    return sessions


# ------------------------------------------------------------- parser frr
def _frr_not_running(out, err):
    return "belum jalan" in ((err or "") + (out or ""))


def _frr_down_data(key):
    return {"available": False,
            "reason": "FRR belum jalan "
                      "(enable dulu: router frr enable + commit)",
            key: []}


def _parse_frr_bgp_summary(out, warnings):
    # vtysh `show ip bgp summary`: header Neighbor/V/AS/MsgRcvd/.../
    # State-PfxRcd + "Total number of neighbors N".
    neighbors = []
    total = None
    header_seen = False
    for line in (out or "").splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith("Neighbor") and "State/PfxRcd" in s:
            header_seen = True
            continue
        m = re.match(r"^Total number of neighbors\s+(\d+)", s)
        if m:
            total = int(m.group(1))
            continue
        if not header_seen:
            continue
        parts = s.split()
        if len(parts) < 10:
            warnings.append("baris bgp summary tidak ter-parse: %s"
                            % s[:120])
            neighbors.append({"raw": s})
            continue
        pfx = _to_int(parts[9])
        neighbors.append({"neighbor": parts[0],
                          "version": _to_int(parts[1]),
                          "as": _to_int(parts[2]),
                          "msg_rcvd": _to_int(parts[3]),
                          "msg_sent": _to_int(parts[4]),
                          "tblver": _to_int(parts[5]),
                          "inq": _to_int(parts[6]),
                          "outq": _to_int(parts[7]),
                          "up_down": parts[8],
                          "prefixes_received": pfx,
                          "state": None if pfx is not None else parts[9]})
    return neighbors, total


def _parse_frr_bgp(out, warnings):
    # vtysh `show ip bgp`: "Network Next Hop Metric LocPrf Weight Path",
    # baris diawali kode status ("*>", ">", ...). LocPrf kosong di output
    # vtysh runtuh jadi 5 kolom — ditangani sebagai locprf=None.
    routes = []
    for line in (out or "").splitlines():
        s = line.strip()
        if not s or s.startswith("Status codes") \
                or s.startswith("Origin codes") \
                or s.startswith("Network") \
                or s.startswith("Total number"):
            continue
        parts = s.split()
        status = None
        if len(parts) >= 2 and re.fullmatch(r"[*>\s=sdhirSR]+", parts[0]) \
                and ("/" in parts[1] or ":" in parts[1]):
            status = parts[0]
            parts = parts[1:]
        if len(parts) < 5:
            warnings.append("baris frr bgp tidak ter-parse: %s" % s[:120])
            routes.append({"raw": s})
            continue
        if len(parts) >= 6:
            metric, locprf, weight = parts[2], parts[3], parts[4]
            path = " ".join(parts[5:])
        else:
            # 5 kolom: LocPrf kosong runtuh di output vtysh (kasus umum:
            # rute lokal, Weight 32768, Path "i") -> locprf=None.
            metric, locprf, weight = parts[2], None, parts[3]
            path = " ".join(parts[4:])
        routes.append({"status": status, "network": parts[0],
                       "next_hop": parts[1],
                       "metric": _to_int(metric),
                       "locprf": _to_int(locprf),
                       "weight": _to_int(weight), "path": path})
    return routes


def _parse_frr_ospf_neighbors(out, warnings):
    # vtysh `show ip ospf neighbor`: Neighbor ID Pri State Dead Time
    # Address Interface RXmtL RqstL DBsmL.
    neighbors = []
    header_seen = False
    for line in (out or "").splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith("Neighbor ID") and "Pri" in s:
            header_seen = True
            continue
        if not header_seen:
            continue
        parts = s.split()
        if len(parts) < 9:
            warnings.append("baris ospf neighbor tidak ter-parse: %s"
                            % s[:120])
            neighbors.append({"raw": s})
            continue
        neighbors.append({"neighbor_id": parts[0],
                          "priority": _to_int(parts[1]),
                          "state": parts[2], "dead_time": parts[3],
                          "address": parts[4], "interface": parts[5],
                          "rxmtl": _to_int(parts[6]),
                          "rqstl": _to_int(parts[7]),
                          "dbsml": _to_int(parts[8])})
    return neighbors


def _parse_frr_ospf(out, warnings):
    # vtysh `show ip ospf`: "OSPF Routing Process, Router ID: X" +
    # seksi "Area X:" berisi "Key: value".
    info = {}
    areas = []
    cur = None
    for line in (out or "").splitlines():
        s = line.strip()
        if not s:
            continue
        m = re.match(r"^OSPF Routing Process.*Router ID:\s*(\S+)", s)
        if m:
            info["router_id"] = m.group(1)
            continue
        m = re.match(r"^Area\s+(\S+):\s*$", s)
        if m:
            cur = {"id": m.group(1), "fields": {}}
            areas.append(cur)
            continue
        m = re.match(r"^([^:]+):\s*(.+)$", s)
        if m:
            key = m.group(1).strip().lower().replace(" ", "_")
            if cur is not None:
                cur["fields"][key] = m.group(2).strip()
            else:
                info[key] = m.group(2).strip()
            continue
        warnings.append("baris frr ospf tidak ter-parse: %s" % s[:120])
        info.setdefault("unparsed_lines", []).append(s)
    return info, areas


def _parse_frr_routes(out, warnings):
    # vtysh `show ip route`: "C 10.0.0.0/24 [110/20] via X, IF, AGE" /
    # "C 10.0.0.0/24 is directly connected, IF, AGE".
    routes = []
    for line in (out or "").splitlines():
        s = line.strip()
        if not s or s.startswith("Codes:"):
            continue
        m = re.match(r"^(\S+)\s+(\S+)\s+\[(\d+)/(\d+)\]\s+via\s+(\S+),\s+"
                     r"(\S+),\s+(\S+)\s*$", s)
        if m:
            routes.append({"code": m.group(1), "prefix": m.group(2),
                           "admin_distance": int(m.group(3)),
                           "metric": int(m.group(4)), "via": m.group(5),
                           "interface": m.group(6), "age": m.group(7)})
            continue
        m = re.match(r"^(\S+)\s+(\S+)\s+is directly connected,\s+"
                     r"(\S+),\s+(\S+)\s*$", s)
        if m:
            routes.append({"code": m.group(1), "prefix": m.group(2),
                           "admin_distance": None, "metric": None,
                           "via": None, "interface": m.group(3),
                           "age": m.group(4),
                           "directly_connected": True})
            continue
        warnings.append("baris frr route tidak ter-parse: %s" % s[:120])
        routes.append({"raw": s})
    return routes


def _parse_frr_version(out):
    # titian-frr.sh show-version baris 1: "FRR 10.7.1 (running, pid N)"
    # atau "FRR 10.7.1 (not running)".
    m = re.search(r"^FRR\s+(\S+)\s+\(([^)]*)\)", out or "", re.M)
    if not m:
        return None, None, None
    note = m.group(2)
    running = "not running" not in note and "running" in note
    pm = re.search(r"pid\s+(\d+)", note)
    return m.group(1), running, int(pm.group(1)) if pm else None


# ---------------------------------------------------------- endpoint D3: T
def _d3_text(script, sub, source, timeout=15, extra=None):
    out = _backend_or_500([sbin(script), sub], timeout=timeout)
    return _text_result(out, source, extra=extra)


def ep_bird_bgp(cfg, q):
    return _d3_text("titian-bgp.sh", "show", "show bgp")


def ep_bird_global(cfg, q):
    return _d3_text("titian-global.sh", "show", "show global")


def ep_ospf(cfg, q):
    return _d3_text("titian-ospf.sh", "show", "show ospf")


def ep_rip(cfg, q):
    return _d3_text("titian-rip.sh", "show", "show rip")


def ep_bfd(cfg, q):
    return _d3_text("titian-bfd.sh", "show", "show bfd")


def ep_babel(cfg, q):
    return _d3_text("titian-babel.sh", "show", "show babel")


def ep_direct(cfg, q):
    return _d3_text("titian-direct.sh", "show", "show direct")


def ep_pipe(cfg, q):
    return _d3_text("titian-pipe.sh", "show", "show pipe")


def ep_device(cfg, q):
    return _d3_text("titian-protocol.sh", "show", "show device",
                    extra={"kind": "device"})


def ep_kernel(cfg, q):
    return _d3_text("titian-protocol.sh", "show", "show kernel",
                    extra={"kind": "kernel"})


def ep_l3vpn(cfg, q):
    return _d3_text("titian-l3vpn.sh", "show", "show l3vpn")


def ep_mrt(cfg, q):
    return _d3_text("titian-mrt.sh", "show", "show mrt")


def ep_bmp(cfg, q):
    return _d3_text("titian-bmp.sh", "show", "show bmp")


def ep_aggregator(cfg, q):
    return _d3_text("titian-aggregator.sh", "show", "show aggregator")


def ep_radv(cfg, q):
    return _d3_text("titian-radv.sh", "show", "show radv")


# ---------------------------------------------------------- endpoint D3: S
def ep_bird_bgp_summary(cfg, q):
    # KOMPOSISI klish (BUKAN perintah birdc asli — lihat titian-birdc.sh):
    # "=== BGP neighbor IP (protocol PROTO) ===" + tabel protocols +
    # "N of N routes for N networks".
    warnings = []
    out = _backend_or_500([sbin("titian-birdc.sh"), "show-bgp-summary"],
                          timeout=30)
    if _bird_down(out):
        return 200, {"available": False, "reason": "BIRD tidak jalan",
                     "neighbors": []}, {"warnings": warnings}
    neighbors = []
    cur = None
    for line in out.splitlines():
        m = re.match(r"^=== BGP neighbor\s+(\S+)\s+\(protocol\s+(\S+)\)"
                     r"\s*===", line)
        if m:
            cur = {"neighbor": m.group(1), "protocol": m.group(2),
                   "state": None, "since": None, "info": None,
                   "routes": None, "routes_total": None, "networks": None}
            neighbors.append(cur)
            continue
        if cur is None or not line.strip() or line.startswith("("):
            continue
        c = _parse_route_count(line)
        if c:
            cur["routes"] = c["routes"]
            cur["routes_total"] = c["routes_total"]
            cur["networks"] = c["networks"]
            continue
        if line.startswith("Name") and "Proto" in line:
            continue
        if line[0] in " \t":
            continue
        parts = line.split()
        if len(parts) >= 4 and parts[0] == cur["protocol"] \
                and cur.get("state") is None:
            cur["state"] = parts[3]
            rest = parts[4:]
            if len(rest) >= 2:
                cur["since"] = rest[0] + " " + rest[1]
                cur["info"] = " ".join(rest[2:])
            elif len(rest) == 1:
                cur["since"] = rest[0]
    page, meta = _list_page(neighbors, q, warnings)
    return 200, {"available": True, "neighbors": page}, meta


def ep_bird_protocols(cfg, q):
    all_flag = q.get("all", ["false"])[0].lower() == "true"
    warnings = []
    argv = [sbin("titian-birdc.sh"),
            "show-protocols-all" if all_flag else "show-protocols"]
    out = _backend_or_500(argv, timeout=30)
    if _bird_down(out):
        return 200, {"available": False, "reason": "BIRD tidak jalan",
                     "protocols": []}, {"warnings": warnings}
    protos = _parse_protocols_table(out, warnings)
    page, meta = _list_page(protos, q, warnings)
    return 200, {"available": True, "all": all_flag, "protocols": page}, meta


def ep_bird_protocols_summary(cfg, q):
    warnings = []
    out = _backend_or_500([sbin("titian-birdc.sh"), "show-protocols"],
                          timeout=30)
    if _bird_down(out):
        return 200, {"available": False, "reason": "BIRD tidak jalan",
                     "protocols": [],
                     "counts": {"total": 0, "by_state": {},
                                "by_protocol": {}}}, {"warnings": warnings}
    protos = _parse_protocols_table(out, warnings)
    by_state = {}
    by_proto = {}
    for p in protos:
        if "state" in p:
            by_state[p["state"]] = by_state.get(p["state"], 0) + 1
        if "protocol" in p:
            by_proto[p["protocol"]] = by_proto.get(p["protocol"], 0) + 1
    data = {"available": True, "protocols": protos,
            "counts": {"total": len(protos), "by_state": by_state,
                       "by_protocol": by_proto}}
    return 200, data, {"warnings": warnings}


def ep_bird_protocol_detail(cfg, name, q):
    if not BIRD_NAME_RE.match(name):
        raise ApiError(400, "validation_error",
                       "nama protokol tidak valid: %s" % name)
    warnings = []
    out = _backend_or_500([sbin("titian-birdc.sh"), "show-protocols", name],
                          timeout=30)
    if _bird_down(out):
        return 200, {"available": False, "reason": "BIRD tidak jalan",
                     "protocol": None}, {"warnings": warnings}
    # run_ro mencetak jawaban birdc + diagnosa bila gagal: daemon UP +
    # gagal = protokol tidak ada (bentuk jawaban "not found" / diagnosa).
    if re.search(r"not found|no such|unknown protocol", out, re.I) \
            or ("(birdc" in out and "gagal" in out):
        raise ApiError(404, "not_found",
                       "protokol tidak ditemukan: %s" % name)
    protos = _parse_protocols_table(out, warnings)
    if not protos or "name" not in protos[0]:
        raise ApiError(404, "not_found",
                       "protokol tidak ditemukan: %s" % name)
    p = dict(protos[0])
    fields, channels, extra = _detail_lines_to_struct(p.pop("details", []))
    p["details"] = fields
    p["channels"] = channels
    if extra:
        p["detail_lines"] = extra
    return 200, {"available": True, "protocol": p}, {"warnings": warnings}


def ep_bird_routes(cfg, q):
    # Precedence SATU subcommand: prefix > where > view > protocol >
    # table > all > default. view export/preexport/noexport butuh
    # ?protocol= (nama protokol); view import butuh ?protocol=
    # <PROTO.CHANNEL>; view primary/filtered tanpa protokol.
    warnings = []
    count_only = q.get("count_only", ["false"])[0].lower() == "true"
    table = q.get("table", [None])[0]
    protocol = q.get("protocol", [None])[0]
    prefix = q.get("prefix", [None])[0]
    view = q.get("view", [None])[0]
    where = q.get("where", [None])[0]
    all_flag = q.get("all", ["false"])[0].lower() == "true"
    if table is not None and table != "all" \
            and not BIRD_NAME_RE.match(table):
        raise ApiError(400, "validation_error",
                       "table tidak valid: %s" % table)
    if view is not None and view not in ("export", "import", "preexport",
                                         "noexport", "primary", "filtered"):
        raise ApiError(400, "validation_error",
                       "view tidak dikenal: %s (pilihan: export|import|"
                       "preexport|noexport|primary|filtered)" % view)
    if prefix is not None:
        try:
            ipaddress.ip_network(prefix, strict=False)
        except ValueError:
            raise ApiError(400, "validation_error",
                           "prefix tidak valid: %s" % prefix)
    if where is not None and not WHERE_RE.match(where):
        raise ApiError(400, "validation_error",
                       "where hanya charset [A-Za-z0-9_ .=<>!&|()\"'] "
                       "maks 200 karakter")
    if view in ("export", "preexport", "noexport"):
        if not protocol or not BIRD_NAME_RE.match(protocol):
            raise ApiError(400, "validation_error",
                           "view=%s butuh ?protocol=<nama-protokol>" % view)
    elif view == "import":
        if not protocol or not BIRD_CHANNEL_RE.match(protocol):
            raise ApiError(400, "validation_error",
                           "view=import butuh ?protocol=<PROTO.CHANNEL> "
                           "(mis. bgp_203_0_113_1.ipv4)")
    elif protocol is not None and not BIRD_NAME_RE.match(protocol):
        raise ApiError(400, "validation_error",
                       "protocol tidak valid: %s" % protocol)
    if count_only:
        out = _backend_or_500([sbin("titian-birdc.sh"), "show-route-count"],
                              timeout=30)
        if _bird_down(out):
            return 200, {"available": False, "reason": "BIRD tidak jalan",
                         "counts": None}, {"warnings": warnings}
        counts = _parse_route_count(out)
        if counts is None:
            warnings.append("show-route-count tidak ter-parse")
        return 200, {"available": True, "counts": counts}, \
            {"warnings": warnings}
    if prefix is not None:
        argv = [sbin("titian-birdc.sh"), "show-route-for", prefix]
    elif where is not None:
        argv = [sbin("titian-birdc.sh"), "show-route-where", where]
    elif view is not None:
        if view in ("export", "preexport", "noexport"):
            argv = [sbin("titian-birdc.sh"), "show-route-" + view, protocol]
        elif view == "import":
            argv = [sbin("titian-birdc.sh"), "show-route-import-table",
                    protocol]
        elif view == "primary":
            argv = [sbin("titian-birdc.sh"), "show-route-primary"]
        else:
            argv = [sbin("titian-birdc.sh"), "show-route-filtered"]
    elif protocol is not None:
        argv = [sbin("titian-birdc.sh"), "show-route-protocol", protocol]
    elif table is not None:
        argv = [sbin("titian-birdc.sh"), "show-route-table", table]
    elif all_flag:
        argv = [sbin("titian-birdc.sh"), "show-route-all"]
    else:
        argv = [sbin("titian-birdc.sh"), "show-route"]
    out = _backend_or_500(argv, timeout=30)
    if _bird_down(out):
        return 200, {"available": False, "reason": "BIRD tidak jalan",
                     "routes": []}, {"warnings": warnings}
    lines, truncated, total = _cap_lines(out)
    routes = _parse_bird_routes("\n".join(lines), warnings)
    page, meta = _list_page(routes, q, warnings,
                            extra_meta={"truncated": truncated,
                                        "lines_total": total})
    return 200, {"available": True, "routes": page}, meta


def ep_bird_routes_stats(cfg, q):
    warnings = []
    out1 = _backend_or_500([sbin("titian-birdc.sh"), "show-route-stats"],
                           timeout=30)
    out2 = _backend_or_500([sbin("titian-birdc.sh"), "show-route-count"],
                           timeout=30)
    if _bird_down(out1) or _bird_down(out2):
        return 200, {"available": False, "reason": "BIRD tidak jalan",
                     "tables": [], "counts": None}, {"warnings": warnings}
    tables = _parse_route_stats(out1, warnings)
    counts = _parse_route_count(out2)
    if counts is None:
        warnings.append("show-route-count tidak ter-parse")
    return 200, {"available": True, "tables": tables, "counts": counts}, \
        {"warnings": warnings}


def ep_bird_status(cfg, q):
    warnings = []
    out = _backend_or_500([sbin("titian-birdc.sh"), "show-status"],
                          timeout=30)
    if _bird_down(out):
        return 200, {"available": False, "reason": "BIRD tidak jalan"}, \
            {"warnings": warnings}
    data = _parse_bird_status(out, warnings)
    return 200, data, {"warnings": warnings}


def ep_bird_symbols(cfg, q):
    typ = q.get("type", [None])[0]
    if typ is not None and typ not in ("function", "protocol", "roa",
                                       "symbol", "table", "template",
                                       "filter"):
        raise ApiError(400, "validation_error",
                       "type tidak dikenal: %s (pilihan: function|protocol|"
                       "roa|symbol|table|template|filter)" % typ)
    warnings = []
    argv = [sbin("titian-birdc.sh"), "show-symbols"]
    if typ:
        argv.append(typ)
    out = _backend_or_500(argv, timeout=30)
    if _bird_down(out):
        return 200, {"available": False, "reason": "BIRD tidak jalan",
                     "symbols": []}, {"warnings": warnings}
    symbols = _parse_symbols(out, warnings)
    page, meta = _list_page(symbols, q, warnings)
    return 200, {"available": True, "symbols": page}, meta


def ep_bird_tables(cfg, q):
    warnings = []
    out = _backend_or_500([sbin("titian-global.sh"), "show-tables"],
                          timeout=15)
    tables = _parse_global_tables(out, warnings)
    page, meta = _list_page(tables, q, warnings)
    return 200, {"tables": page}, meta


def ep_bird_interfaces(cfg, q):
    summary = q.get("summary", ["false"])[0].lower() == "true"
    warnings = []
    argv = [sbin("titian-birdc.sh"), "show-interfaces-bird"]
    if summary:
        argv.append("summary")
    out = _backend_or_500(argv, timeout=30)
    if _bird_down(out):
        return 200, {"available": False, "reason": "BIRD tidak jalan",
                     "interfaces": []}, {"warnings": warnings}
    ifaces = _parse_bird_interfaces(out, warnings)
    page, meta = _list_page(ifaces, q, warnings)
    return 200, {"available": True, "summary": summary,
                 "interfaces": page}, meta


def _bird_records_ep(sub, record_re, key, q):
    warnings = []
    out = _backend_or_500([sbin("titian-birdc.sh"), sub], timeout=30)
    if _bird_down(out):
        return 200, {"available": False, "reason": "BIRD tidak jalan",
                     key: []}, {"warnings": warnings}
    records, preamble = _parse_bird_records(out, record_re, warnings)
    page, meta = _list_page(records, q, warnings)
    data = {"available": True, key: page}
    if preamble:
        data["preamble"] = preamble
    if not records:
        lines, _tr, _tot = _cap_lines(out)
        data["raw_text"] = "\n".join(lines)
    return 200, data, meta


def ep_ospf_interfaces(cfg, q):
    return _bird_records_ep(
        "show-ospf-interface",
        re.compile(r"^\s*Interface\s+(\S+?)\s*(?:\(.*\))?\s*:\s*$"),
        "interfaces", q)


def ep_ospf_neighbors(cfg, q):
    # DIPILIH: titian-birdc.sh show-ospf-neighbors (bukan titian-ospf.sh
    # show-neighbors) — keduanya memanggil `birdc show ospf neighbors`
    # yang sama; wrapper birdc memberi soft-fail + strip banner BIRD.
    return _bird_records_ep(
        "show-ospf-neighbors",
        re.compile(r"^\s*Router ID:\s*(\S+)\s*$"), "neighbors", q)


def ep_ospf_state(cfg, q):
    return _bird_records_ep(
        "show-ospf-state",
        re.compile(r"^\s*((?:Router|Network)\s+\S+)\s*:\s*$"),
        "entries", q)


def ep_ospf_topology(cfg, q):
    return _bird_records_ep(
        "show-ospf-topology",
        re.compile(r"^\s*((?:Router|Network)\s+\S+)\s*:\s*$"),
        "entries", q)


def ep_ospf_lsadb(cfg, q):
    return _bird_records_ep(
        "show-ospf-lsadb",
        re.compile(r"^\s*((?:Router-LSA|Network-LSA|Summary-LSA|"
                   r"AS-External-LSA|NSSA-LSA|Link-LSA|"
                   r"Intra-Area-Prefix-LSA)\s+\S+\s+\S+)"),
        "entries", q)


def ep_rip_interfaces(cfg, q):
    return _bird_records_ep(
        "show-rip-interfaces",
        re.compile(r"^\s*Interface\s+(\S+?)\s*(?:\(.*\))?\s*:\s*$"),
        "interfaces", q)


def ep_rip_neighbors(cfg, q):
    return _bird_records_ep(
        "show-rip-neighbors",
        re.compile(r"^\s*Neighbor\s+(\S+)\s*:\s*$"), "neighbors", q)


def ep_bfd_sessions(cfg, q):
    warnings = []
    out = _backend_or_500([sbin("titian-bfd.sh"), "show-sessions"],
                          timeout=30)
    if _bird_down(out) or "(BFD tidak jalan" in out \
            or "(bird tidak jalan" in out:
        return 200, {"available": False,
                     "reason": "BFD/BIRD tidak jalan", "sessions": []}, \
            {"warnings": warnings}
    sessions = _parse_bfd_sessions(out, warnings)
    page, meta = _list_page(sessions, q, warnings)
    return 200, {"available": True, "sessions": page}, meta


def ep_rpki(cfg, q):
    # S/T hibrida: `titian-rpki.sh show` = intent + section + birdc
    # show protocol per instance (TIDAK ADA perintah birdc `show rpki`
    # khusus). Kembalikan teks (Tier T) + instance yang berhasil
    # di-parse dari baris tabel protokol di dalamnya.
    warnings = []
    out = _backend_or_500([sbin("titian-rpki.sh"), "show"], timeout=30)
    protos = _parse_protocols_table(out, warnings, warn_no_header=False)
    instances = [{"name": p.get("name"), "protocol": p.get("protocol"),
                  "table": p.get("table"), "state": p.get("state"),
                  "since": p.get("since"), "info": p.get("info")}
                 for p in protos if "name" in p]
    status, data, meta = _text_result(
        out, "show rpki",
        extra={"available": True, "instances": instances})
    if not instances:
        meta["warnings"].append("tidak ada instance RPKI ter-parse dari "
                                "output birdc (mungkin belum ada instance "
                                "/ BIRD tidak jalan)")
    meta["warnings"] += warnings
    return status, data, meta


# ---------------------------------------------------------- endpoint D3: FRR
def _frr_list_ep(sub, parse_fn, key, q):
    warnings = []
    rc, out, err = run_backend([sbin("titian-frr.sh"), sub], timeout=30)
    if rc != 0:
        if _frr_not_running(out, err):
            return 200, _frr_down_data(key), {"warnings": warnings}
        raise ApiError(500, "internal_error",
                       "backend gagal: %s" % sanitize_backend_text(err or out))
    items = parse_fn(out, warnings)
    page, meta = _list_page(items, q, warnings)
    return 200, {"available": True, key: page}, meta


def ep_frr(cfg, q):
    warnings = []
    out = _backend_or_500([sbin("titian-frr.sh"), "show"], timeout=30)
    first = (out.splitlines() or [""])[0]
    m = re.match(r"^FRR:\s*(\S+)\s+\(intent:\s*(\S+),\s*rc:\s*(\S+),\s*"
                 r"(.+)\)\s*$", first)
    if m:
        note = m.group(4)
        running = "not running" not in note
        pm = re.search(r"pid\s+(\d+)", note)
        extra = {"available": running, "frr_version": m.group(1),
                 "intent": m.group(2),
                 "rc_enabled": m.group(3) == "enabled",
                 "running": running,
                 "zebra_pid": int(pm.group(1)) if pm else None}
    else:
        warnings.append("baris status FRR tidak ter-parse")
        extra = {"available": False}
    status, data, meta = _text_result(out, "show frr", extra=extra)
    meta["warnings"] += warnings
    return status, data, meta


def ep_frr_bgp(cfg, q):
    return _frr_list_ep("show-ip-bgp", _parse_frr_bgp, "routes", q)


def ep_frr_bgp_summary(cfg, q):
    warnings = []
    rc, out, err = run_backend([sbin("titian-frr.sh"), "show-ip-bgp-summary"],
                               timeout=30)
    if rc != 0:
        if _frr_not_running(out, err):
            return 200, {"available": False,
                         "reason": "FRR belum jalan (enable dulu: router "
                                   "frr enable + commit)",
                         "neighbors": [], "total_neighbors": 0}, \
                {"warnings": warnings}
        raise ApiError(500, "internal_error",
                       "backend gagal: %s" % sanitize_backend_text(err or out))
    neighbors, total = _parse_frr_bgp_summary(out, warnings)
    page, meta = _list_page(neighbors, q, warnings)
    return 200, {"available": True, "neighbors": page,
                 "total_neighbors": total if total is not None
                 else len(neighbors)}, meta


def ep_frr_ospf(cfg, q):
    warnings = []
    rc, out, err = run_backend([sbin("titian-frr.sh"), "show-ip-ospf"],
                               timeout=30)
    if rc != 0:
        if _frr_not_running(out, err):
            return 200, {"available": False,
                         "reason": "FRR belum jalan (enable dulu: router "
                                   "frr enable + commit)",
                         "info": {}, "areas": []}, {"warnings": warnings}
        raise ApiError(500, "internal_error",
                       "backend gagal: %s" % sanitize_backend_text(err or out))
    info, areas = _parse_frr_ospf(out, warnings)
    return 200, {"available": True, "info": info, "areas": areas}, \
        {"warnings": warnings}


def ep_frr_ospf_neighbors(cfg, q):
    return _frr_list_ep("show-ip-ospf-neighbor", _parse_frr_ospf_neighbors,
                        "neighbors", q)


def ep_frr_routes(cfg, q):
    return _frr_list_ep("show-ip-route", _parse_frr_routes, "routes", q)


def ep_frr_version(cfg, q):
    warnings = []
    out = _backend_or_500([sbin("titian-frr.sh"), "show-version"],
                          timeout=30)
    ver, running, pid = _parse_frr_version(out)
    if ver is None:
        warnings.append("versi FRR tidak ter-parse")
    lines = [l for l in out.splitlines() if l.strip()]
    version_text = "\n".join(lines[1:]) if len(lines) > 1 else ""
    return 200, {"available": bool(running), "frr_version": ver,
                 "running": running, "zebra_pid": pid,
                 "version_text": version_text,
                 "source": "show frr version"}, {"warnings": warnings}


# ------------------------------------------------------- D4a firewall/wg
# Perluasan JSON v1 D4a (25 Nov 2026): firewall + WireGuard, semua GET.
# Backend: titian-fw.sh (show/status/show-filter/show-nat/show-isolated)
# dan titian-wireguard.sh (show/show-one) — subcommand baca yang sudah
# ada, TIDAK ADA subcommand backend baru. Format sumber (dari sbin-ref):
#   fw show: "firewall: yes|no", "protected interfaces:", "  <if>",
#     "rules ...:", "  N. <rule>" / "  (no rules)"
#   fw status: "forwarding: ...", "pf: Enabled" atau "pf: not running",
#     "-- live anchor firewall (filter):" + baris pf (indent 3 spasi),
#     "-- live anchor nat (nat/rdr):" + baris pf
#   fw show-filter: "filter <chain> <action> proto <p> src <a> dst <a>
#     sport <s> dport <d> in <if> out <if>" (17 token) / "(no filter rules)"
#   fw show-nat: "snat <srcnet> to <target> out <if>" (6 token) /
#     "dnat <tcp|udp> in <if> dport <n> to <addr> port <n|same>"
#     (10 token) / "(no NAT rules)"
#   fw show-isolated: "isolate <ip> <web-ip> <web-port>" /
#     "(no isolated users)"
#   wg show: "<wgN>: yes|no, addr <cidr|unset>, port <n>, peers <n>,
#     up (interface ada)|down (interface belum dibuat)" /
#     "(no WireGuard interfaces configured)", lalu "-- wg show:" +
#     output tool `wg` (indent 2 spasi)
#   wg show-one: state file (indent 2 spasi, TANPA baris public-key) +
#     "-- live:" + `wg show <iface>` (indent 2 spasi) atau
#     "(interface <iface> belum dibuat / wg tidak ada)"
# ASUMSI (belum terverifikasi di mesin live): format `wg show` adalah
# format standar tool wg (interface:/public key:/listening port:/
# peer:/endpoint:/allowed ips:/latest handshake:/transfer:). Bila di
# guest formatnya berbeda, parser live best-effort → `live_raw` + warning.
WG_RE = re.compile(r"^wg[0-9]{1,2}$")
FW_FILTER_RE = re.compile(
    r"^filter (forward|input|output) (permit|deny) proto "
    r"(tcp|udp|icmp|all) src (\S+) dst (\S+) sport (\S+) dport (\S+) "
    r"in (\S+) out (\S+)$")
FW_SNAT_RE = re.compile(r"^snat (\S+) to (\S+) out (\S+)$")
FW_DNAT_RE = re.compile(
    r"^dnat (tcp|udp) in (\S+) dport (\d+) to (\S+) port (\S+)$")
FW_ISOLATE_RE = re.compile(r"^isolate (\S+) (\S+) (\d+)$")
WG_SHOW_RE = re.compile(
    r"^(wg[0-9]{1,2}): (yes|no), addr (\S+), port (\d+), peers (\d+), "
    r"(up \(interface ada\)|down \(interface belum dibuat\))$")
WG_PEER_RE = re.compile(
    r"^peer (\S+) allowed-ips (\S+) endpoint (\S+) keepalive (\d+)$")





def _port_or_none(s):
    try:
        v = int(s)
    except (TypeError, ValueError):
        return None
    return v if 1 <= v <= 65535 else None


def _parse_fw_filter_line(line, warnings):
    m = FW_FILTER_RE.match(line)
    if not m:
        warnings.append("baris filter gagal di-parse: %s" % line[:120])
        return {"raw": line}
    chain, action, proto, src, dst, sport, dport, inf, outf = m.groups()
    return {"chain": chain, "action": action, "protocol": proto,
            "src": src, "dst": dst,
            "sport": _port_or_none(sport), "dport": _port_or_none(dport),
            "in_interface": inf, "out_interface": outf, "raw": line}


def _parse_fw_nat_line(line, warnings):
    m = FW_SNAT_RE.match(line)
    if m:
        srcnet, target, outf = m.groups()
        return {"type": "snat", "srcnet": srcnet, "target": target,
                "out_interface": outf, "raw": line}
    m = FW_DNAT_RE.match(line)
    if m:
        proto, inf, dport, target, tport = m.groups()
        return {"type": "dnat", "protocol": proto,
                "in_interface": inf, "dport": int(dport),
                "target": target,
                "target_port": (_port_or_none(tport)
                                if tport != "same" else None),
                "target_port_same": tport == "same", "raw": line}
    warnings.append("baris nat gagal di-parse: %s" % line[:120])
    return {"raw": line}


def _parse_wg_live(text):
    # Parse output `wg show [iface]` (format standar tool wg) best-effort.
    # Return (live_dict|None, raw_lines, warnings).
    raw_lines, warnings = [], []
    live = {"interface": None, "public_key": None,
            "listening_port": None, "peers": []}
    cur = None
    for ln in (text or "").splitlines():
        s = ln.strip()
        if not s:
            continue
        raw_lines.append(s)
        m = re.match(r"^interface:\s*(\S+)$", s)
        if m:
            live["interface"] = m.group(1)
            continue
        m = re.match(r"^public key:\s*(\S+)$", s)
        if m:
            live["public_key"] = m.group(1)
            continue
        m = re.match(r"^listening port:\s*(\d+)$", s)
        if m:
            live["listening_port"] = int(m.group(1))
            continue
        m = re.match(r"^peer:\s*(\S+)$", s)
        if m:
            cur = {"public_key": m.group(1), "endpoint": None,
                   "allowed_ips": None, "latest_handshake": None,
                   "transfer": None}
            live["peers"].append(cur)
            continue
        if cur is not None:
            m = re.match(r"^endpoint:\s*(.+)$", s)
            if m:
                cur["endpoint"] = m.group(1)
                continue
            m = re.match(r"^allowed ips:\s*(.+)$", s)
            if m:
                cur["allowed_ips"] = m.group(1)
                continue
            m = re.match(r"^latest handshake:\s*(.+)$", s)
            if m:
                cur["latest_handshake"] = m.group(1)
                continue
            m = re.match(r"^transfer:\s*(.+)$", s)
            if m:
                cur["transfer"] = m.group(1)
                continue
        if s.startswith("private key:"):
            continue  # `wg show` mencetak "(hidden)" — bukan rahasia
        warnings.append("baris wg show gagal di-parse: %s" % s[:120])
    if live["interface"] is None and not live["peers"]:
        return None, raw_lines, warnings
    return live, raw_lines, warnings


def ep_firewall(cfg):
    warnings = []
    rc, out, err = run_backend([sbin("titian-fw.sh"), "show"], timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "firewall show gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, lines_total = _cap_lines(out)
    enabled = None
    protected = []
    rules = []
    section = None
    for ln in lines:
        s = ln.strip()
        m = re.match(r"^firewall:\s*(yes|no)$", s)
        if m:
            enabled = m.group(1) == "yes"
            continue
        if s == "protected interfaces:":
            section = "protected"
            continue
        if s.startswith("rules "):
            section = "rules"
            continue
        if section == "protected" and s and not s.startswith("rules"):
            protected.append(s)
            continue
        if section == "rules":
            m = re.match(r"^\d+\.\s+(.+)$", s)
            if m:
                rules.append(m.group(1))
    rc2, out2, err2 = run_backend([sbin("titian-fw.sh"), "status"],
                                  timeout=10)
    pf_running = None
    live_filter, live_nat = [], []
    if rc2 != 0:
        warnings.append("firewall status gagal: %s"
                        % sanitize_backend_text(err2 or out2))
    else:
        pf_running = "Enabled" in out2
        section = None
        for ln in out2.splitlines():
            s = ln.strip()
            if s.startswith("-- live anchor firewall"):
                section = "filter"
                continue
            if s.startswith("-- live anchor nat"):
                section = "nat"
                continue
            if section == "filter" and s:
                live_filter.append(s)
            elif section == "nat" and s:
                live_nat.append(s)
    data = {"enabled": enabled, "protected_interfaces": protected,
            "rules": rules, "rule_count": len(rules),
            "config_text": "\n".join(lines), "lines": len(lines),
            "pf_running": pf_running,
            "live_filter": live_filter, "live_nat": live_nat}
    meta = {"warnings": warnings}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = lines_total
    return 200, data, meta


def ep_firewall_filter(cfg, q):
    limit, offset = parse_paging(q)
    warnings = []
    rc, out, err = run_backend([sbin("titian-fw.sh"), "show-filter"],
                               timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "firewall show-filter gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, lines_total = _cap_lines(out)
    rules = []
    for ln in lines:
        s = ln.strip()
        if not s or s == "(no filter rules)":
            continue
        rules.append(_parse_fw_filter_line(s, warnings))
    total = len(rules)
    page = rules[offset:offset + limit]
    data = {"rules": page}
    meta = {"total": total, "count": len(page), "limit": limit,
            "offset": offset, "warnings": warnings}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = lines_total
    return 200, data, meta


def ep_firewall_nat(cfg, q):
    limit, offset = parse_paging(q)
    warnings = []
    rc, out, err = run_backend([sbin("titian-fw.sh"), "show-nat"],
                               timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "firewall show-nat gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, lines_total = _cap_lines(out)
    rules = []
    for ln in lines:
        s = ln.strip()
        if not s or s == "(no NAT rules)":
            continue
        rules.append(_parse_fw_nat_line(s, warnings))
    total = len(rules)
    page = rules[offset:offset + limit]
    data = {"rules": page}
    meta = {"total": total, "count": len(page), "limit": limit,
            "offset": offset, "warnings": warnings}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = lines_total
    return 200, data, meta


def get_isolated_list():
    # (list objek isolate, warnings) — parser penuh dari show-isolated.
    rc, out, _err = run_backend([sbin("titian-fw.sh"), "show-isolated"],
                                timeout=10)
    if rc != 0:
        return [], ["show-isolated gagal"]
    items, warnings = [], []
    for ln in out.splitlines():
        s = ln.strip()
        if not s or s == "(no isolated users)":
            continue
        m = FW_ISOLATE_RE.match(s)
        if m:
            ip, web_ip, web_port = m.groups()
            if valid_ip(ip) and valid_ip(web_ip):
                items.append({"ip": ip, "web_ip": web_ip,
                              "web_port": int(web_port)})
            else:
                warnings.append("baris isolir IP tidak valid: %s" % s[:120])
                items.append({"raw": s})
        else:
            warnings.append("baris isolir gagal di-parse: %s" % s[:120])
            items.append({"raw": s})
    return items, warnings


def ep_firewall_isolated(cfg, q):
    limit, offset = parse_paging(q)
    items, warnings = get_isolated_list()
    total = len(items)
    page = items[offset:offset + limit]
    data = {"isolated": page}
    meta = {"total": total, "count": len(page), "limit": limit,
            "offset": offset, "warnings": warnings}
    return 200, data, meta


def _wg_live_text(out):
    # Potong seksi "-- wg show:" dari output `wg show` (list).
    lines = (out or "").splitlines()
    for i, ln in enumerate(lines):
        if ln.strip() == "-- wg show:":
            return "\n".join(lines[i + 1:])
    return None


def ep_wireguard(cfg, q):
    limit, offset = parse_paging(q)
    warnings = []
    rc, out, err = run_backend([sbin("titian-wireguard.sh"), "show"],
                               timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "wireguard show gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, lines_total = _cap_lines(out)
    ifaces = []
    for ln in lines:
        s = ln.strip()
        if not s or s == "(no WireGuard interfaces configured)" \
                or s == "-- wg show:":
            continue
        m = WG_SHOW_RE.match(s)
        if not m:
            continue  # baris seksi live wg show — bukan ringkasan iface
        name, en, addr, port, peers, live_s = m.groups()
        ifaces.append({"name": name, "enabled": en == "yes",
                       "address": None if addr == "unset" else addr,
                       "listen_port": int(port),
                       "peer_count": int(peers),
                       "live": live_s.startswith("up")})
    live_text = _wg_live_text(out)
    live = None
    if live_text:
        live, _raw, w = _parse_wg_live(live_text)
        warnings += w
    total = len(ifaces)
    page = ifaces[offset:offset + limit]
    data = {"interfaces": page, "live": live,
            "live_text": live_text}
    meta = {"total": total, "count": len(page), "limit": limit,
            "offset": offset, "warnings": warnings}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = lines_total
    return 200, data, meta


def ep_wireguard_one(cfg, name):
    if not WG_RE.match(name):
        raise ApiError(400, "validation_error",
                       "nama interface WireGuard harus wg<N>: %s" % name)
    # Keberadaan = file state (jangan panggil show-one dulu: backend
    # membuat file state baru bila belum ada — show-one di nama yang
    # belum ada akan terlihat "ada").
    state_file = os.path.join(DEFAULT_STATE_ROOT, "netstate",
                              "wireguard", name + ".conf")
    if not os.path.isfile(state_file):
        raise ApiError(404, "not_found",
                       "interface WireGuard tidak ditemukan: %s" % name)
    warnings = []
    rc, out, err = run_backend([sbin("titian-wireguard.sh"), "show-one",
                                name], timeout=10)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "wireguard show-one gagal: %s"
                       % sanitize_backend_text(err or out))
    lines, truncated, lines_total = _cap_lines(out)
    data = {"name": name, "enabled": None, "address": None,
            "listen_port": None, "peers": [], "live": None,
            "live_available": False, "live_raw": []}
    section = "config"
    live_lines = []
    for ln in lines:
        s = ln.strip()
        if s == "-- live:":
            section = "live"
            continue
        if section == "config":
            if s.startswith("enable "):
                data["enabled"] = s.split(None, 1)[1] == "yes"
            elif s.startswith("address "):
                data["address"] = s.split(None, 1)[1]
            elif s.startswith("listen-port "):
                try:
                    data["listen_port"] = int(s.split(None, 1)[1])
                except ValueError:
                    warnings.append("listen-port bukan angka: %s" % s[:120])
            elif s.startswith("peer "):
                m = WG_PEER_RE.match(s)
                if m:
                    pub, aip, ep, ka = m.groups()
                    data["peers"].append(
                        {"public_key": pub,
                         "allowed_ips": None if aip == "-" else aip,
                         "endpoint": None if ep == "-" else ep,
                         "keepalive": int(ka)})
                else:
                    warnings.append("baris peer gagal di-parse: %s"
                                    % s[:120])
                    data["peers"].append({"raw": s})
            elif s.startswith("public-key "):
                continue  # backend sengaja menyembunyikan — jangan bocorkan
            elif s and not s.startswith("#"):
                warnings.append("baris config wg gagal di-parse: %s"
                                % s[:120])
        else:
            live_lines.append(s)
    if data["listen_port"] is None:
        data["listen_port"] = 51820
    live_text = "\n".join(live_lines)
    if live_lines and not live_text.startswith("(interface"):
        data["live_available"] = True
        live, raw, w = _parse_wg_live(live_text)
        warnings += w
        data["live"] = live
        data["live_raw"] = raw
    elif live_lines:
        data["live_raw"] = [s for s in live_lines if s]
    meta = {"warnings": warnings}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = lines_total
    return 200, data, meta


# ------------------------------------------------------- D4b: traffic-shape / BRAS / monitoring
# Perluasan JSON v1 (25 Nov 2026, perintah user "buatkan JSON untuk
# semua menu CLI"). Parser best-effort atas output backend klish yang
# SAMA dengan CLI; baris gagal parse -> {"raw": ...} + meta.warnings.
# Format sumber (dari sbin-ref, bukan tebakan):
#   pipe:  pipe <name> bw <rate> queue <n> delay <ms> plr <x> burst <n> [aqm ...]
#   sched: sched <name> type <t> [bw <rate>] [quantum <n>] [limit <n>] [flows <n>]
#   queue: queue <name> <pipe|sched> <parent> mask <spec> <val> weight <n> queue <n> [aqm ...]
#   rule:  rule <name> <in|out> on <if> <pipe|queue> <ref> [src <a>] [dst <a>] [proto <p>] [dport <n>]
#   profile: profile <name> download <rate> burst <n> upload <rate> burst <n>
#   bind:  bind <profile> interface <if> | bind <profile> ip <addr> on <if> side <uplink|customer>
#   pppoe show-users: header "USER  STATIC-IP", baris "<user> <ip|-|pool>"
#   dhcp list-leases: "<ip> <mac> <yyyy/mm/dd> <hh:mm:ss>" per lease aktif
#   monitoring show: "<proc> (port <p>): intent <yes|no>, rc <YES|NO|?>, <running|not running>[, community <c>]"
#   monitoring bandwidth: tabel "Interface RX TX Total", nilai "N.NN Mbps|Kbps|Gbps|bps"
#   ipfw pipe/sched/queue di stats TIDAK di-parse kolomnya (format
#   ipfw tidak ada di sbin-ref; quirk BKT terbukti live 22 Nov 2026) —
#   stats dikembalikan per seksi sebagai teks + lines.
PROFILE_RE = re.compile(r"^[A-Za-z0-9_-]{1,12}$")
MON_SERVICES = ("snmp", "node-exporter", "bird-exporter", "nfacctd")
MON_PROC = {"snmpd": "snmp", "node_exporter": "node-exporter",
            "bird_exporter": "bird-exporter", "nfacctd": "nfacctd"}
RATE_RE = re.compile(r"^([0-9]+(?:\.[0-9]+)?)\s*(bps|Kbps|Mbps|Gbps)$")
MON_LINE_RE = re.compile(
    r"^(\S+) \(port ([^)]+)\): intent (\S+), rc (\S+), "
    r"(running|not running)(?:, community (\S+))?$")





def _meta_list(total, count, limit, offset, warnings, truncated=False,
               lines_total=None):
    meta = {"total": total, "count": count, "limit": limit,
            "offset": offset, "warnings": warnings}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = lines_total
    return meta


def _to_int(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


def _parse_bps(s):
    m = RATE_RE.match((s or "").strip())
    if not m:
        return None
    mult = {"bps": 1, "Kbps": 1000, "Mbps": 1000000,
            "Gbps": 1000000000}[m.group(2)]
    return int(float(m.group(1)) * mult)


def _dhcp_dt_iso(s):
    m = re.match(r"(\d{4})/(\d{1,2})/(\d{1,2})\s+"
                 r"(\d{1,2}):(\d{2}):(\d{2})", s.strip())
    if not m:
        return None, None
    y, mo, d, h, mi, sec = (int(x) for x in m.groups())
    try:
        ep = calendar.timegm((y, mo, d, h, mi, sec, 0, 0, 0))
    except Exception:
        return None, None
    return (datetime.fromtimestamp(ep, timezone.utc)
            .strftime("%Y-%m-%dT%H:%M:%SZ"), ep)


def _kv_after(tokens, start):
    # Pasangan key/value berurutan mulai index start; "aqm" menelan sisa.
    out = {}
    rest = ""
    i = start
    while i < len(tokens):
        if tokens[i] == "aqm":
            rest = " ".join(tokens[i:])
            break
        if i + 1 < len(tokens):
            out[tokens[i]] = tokens[i + 1]
            i += 2
        else:
            out[tokens[i]] = None
            i += 1
    return out, rest


def _parse_pipe_line(line, warnings):
    t = line.split()
    if len(t) < 12 or t[0] != "pipe":
        warnings.append("baris pipe tidak bisa di-parse: %s" % line[:120])
        return {"raw": line}
    kv, aqm = _kv_after(t, 2)
    d = {"name": t[1], "bw": kv.get("bw"),
         "queue": _to_int(kv.get("queue")),
         "delay_ms": _to_int(kv.get("delay")),
         "plr": kv.get("plr"),
         "burst": _to_int(kv.get("burst"))}
    try:
        d["plr"] = float(kv.get("plr")) if kv.get("plr") not in (None, "") \
            else None
    except ValueError:
        d["plr"] = kv.get("plr")
    if aqm:
        d["aqm"] = aqm
    return d


def _parse_sched_line(line, warnings):
    t = line.split()
    if len(t) < 4 or t[0] != "sched":
        warnings.append("baris sched tidak bisa di-parse: %s" % line[:120])
        return {"raw": line}
    kv, _rest = _kv_after(t, 2)
    return {"name": t[1], "type": kv.get("type"), "bw": kv.get("bw"),
            "quantum": _to_int(kv.get("quantum")),
            "limit": _to_int(kv.get("limit")),
            "flows": _to_int(kv.get("flows"))}


def _parse_queue_line(line, warnings):
    t = line.split()
    if len(t) < 11 or t[0] != "queue":
        warnings.append("baris queue tidak bisa di-parse: %s" % line[:120])
        return {"raw": line}
    kv, aqm = _kv_after(t, 7)
    # t: queue name kind parent mask spec val | weight w queue n [aqm...]
    # kv_after(7) membaca weight/queue dari posisi 7: "weight"->w, "queue"->n
    d = {"name": t[1], "parent_kind": t[2], "parent": t[3],
         "mask": t[5] if len(t) > 5 else None,
         "mask_value": t[6] if len(t) > 6 else None,
         "weight": _to_int(kv.get("weight")),
         "queue": _to_int(kv.get("queue"))}
    if aqm:
        d["aqm"] = aqm
    return d


def _parse_rule_line(line, warnings):
    t = line.split()
    if len(t) < 7 or t[0] != "rule":
        warnings.append("baris rule tidak bisa di-parse: %s" % line[:120])
        return {"raw": line}
    kv, _rest = _kv_after(t, 7)
    return {"name": t[1], "direction": t[2], "interface": t[4],
            "target_kind": t[5], "target": t[6],
            "src": kv.get("src"), "dst": kv.get("dst"),
            "proto": kv.get("proto"),
            "dport": _to_int(kv.get("dport"))}


def _parse_profile_line(line, warnings):
    t = line.split()
    if len(t) != 10 or t[0] != "profile":
        warnings.append("baris profile tidak bisa di-parse: %s" % line[:120])
        return {"raw": line}
    # Posisi tetap: profile name download rate burst n upload rate burst n
    return {"name": t[1], "download": t[3],
            "download_burst": _to_int(t[5]),
            "upload": t[7],
            "upload_burst": _to_int(t[9])}


def _parse_bind_line(line, warnings):
    t = line.split()
    if len(t) < 4 or t[0] != "bind":
        warnings.append("baris bind tidak bisa di-parse: %s" % line[:120])
        return {"raw": line}
    d = {"profile": t[1], "target_type": t[2]}
    if t[2] == "interface" and len(t) >= 4:
        d["interface"] = t[3]
    elif t[2] == "ip" and len(t) >= 8:
        d["ip"] = t[3]
        d["interface"] = t[5]
        d["side"] = t[7]
    else:
        d["raw"] = line
    return d


def _run_or_500(argv, what, timeout=15):
    rc, out, err = run_backend(argv, timeout=timeout)
    if rc != 0:
        raise ApiError(500, "internal_error",
                       "%s gagal: %s" % (what, sanitize_backend_text(err or out)))
    return out


def _parse_config_lines(out, prefix, empty_marker, parse_fn, warnings):
    items = []
    for line in out.splitlines():
        s = line.strip()
        if not s or s == empty_marker:
            continue
        if s.startswith(prefix):
            items.append(parse_fn(s, warnings))
        else:
            warnings.append("baris tidak dikenal: %s" % s[:120])
            items.append({"raw": s})
    return items


def ep_traffic_shape(cfg, q):
    out = _run_or_500([sbin("titian-traffic-shape.sh"), "show"],
                      "traffic-shape show")
    lines, truncated, total = _cap_lines(out)
    enabled = None
    m = re.search(r"^traffic-shape:\s*(yes|no)", out, re.M)
    if m:
        enabled = m.group(1) == "yes"
    data = {"enabled": enabled, "config_text": "\n".join(lines),
            "lines": len(lines), "source": "show traffic-shape"}
    meta = {"warnings": []}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total
    return 200, data, meta


def ep_ts_profiles(cfg, q):
    limit, offset = parse_paging(q)
    out = _run_or_500([sbin("titian-traffic-shape.sh"), "show-profile"],
                      "traffic-shape show-profile")
    warnings = []
    profiles = {}
    order = []
    section = None
    for line in out.splitlines():
        s = line.strip()
        if s == "(no profiles)":
            continue
        if s == "profiles:":
            section = "profiles"
            continue
        if s == "bindings:":
            section = "bindings"
            continue
        if section == "profiles" and s.startswith("profile "):
            p = _parse_profile_line(s, warnings)
            if "name" in p:
                p["bindings"] = []
                profiles[p["name"]] = p
                order.append(p["name"])
        elif section == "bindings" and s.startswith("bind "):
            b = _parse_bind_line(s, warnings)
            if isinstance(b.get("profile"), str) and b["profile"] in profiles:
                profiles[b["profile"]]["bindings"].append(b)
            else:
                warnings.append("bind tanpa profile dikenal: %s" % s[:120])
    items = [profiles[n] for n in order]
    page = items[offset:offset + limit]
    return 200, {"profiles": page}, _meta_list(
        len(items), len(page), limit, offset, warnings)


def ep_ts_profile(cfg, name, q):
    if not PROFILE_RE.match(name):
        raise ApiError(400, "validation_error",
                       "nama profile tidak valid: %s "
                       "(maks 12 char [A-Za-z0-9_-])" % name)
    out = _run_or_500([sbin("titian-traffic-shape.sh"), "show-profile", name],
                      "traffic-shape show-profile")
    if "(no profile %s)" % name in out:
        raise ApiError(404, "not_found",
                       "profile traffic-shape tidak ditemukan: %s" % name)
    warnings = []
    profile = None
    bindings = []
    pipes = []
    rules = []
    section = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("profile ") and profile is None and \
                not s.startswith("profile %s:" % name):
            profile = _parse_profile_line(s, warnings)
        elif s == "bindings:":
            section = "bindings"
        elif s == "derived pipes:":
            section = "pipes"
        elif s == "derived rules:":
            section = "rules"
        elif s == "(none)":
            continue
        elif section == "bindings" and s.startswith("bind "):
            bindings.append(_parse_bind_line(s, warnings))
        elif section == "pipes" and s.startswith("pipe "):
            pipes.append(_parse_pipe_line(s, warnings))
        elif section == "rules" and s.startswith("rule "):
            rules.append(_parse_rule_line(s, warnings))
    if profile is None:
        raise ApiError(404, "not_found",
                       "profile traffic-shape tidak ditemukan: %s" % name)
    profile["bindings"] = bindings
    profile["derived_pipes"] = pipes
    profile["derived_rules"] = rules
    return 200, {"profile": profile}, {"warnings": warnings}


def ep_ts_pipes(cfg, q):
    limit, offset = parse_paging(q)
    out = _run_or_500([sbin("titian-traffic-shape.sh"), "show-pipe"],
                      "traffic-shape show-pipe")
    warnings = []
    items = _parse_config_lines(out, "pipe ", "(no pipes)",
                                _parse_pipe_line, warnings)
    page = items[offset:offset + limit]
    return 200, {"pipes": page}, _meta_list(
        len(items), len(page), limit, offset, warnings)


def ep_ts_queues(cfg, q):
    limit, offset = parse_paging(q)
    out = _run_or_500([sbin("titian-traffic-shape.sh"), "show-queue"],
                      "traffic-shape show-queue")
    warnings = []
    items = _parse_config_lines(out, "queue ", "(no queues)",
                                _parse_queue_line, warnings)
    page = items[offset:offset + limit]
    return 200, {"queues": page}, _meta_list(
        len(items), len(page), limit, offset, warnings)


def ep_ts_rules(cfg, q):
    limit, offset = parse_paging(q)
    out = _run_or_500([sbin("titian-traffic-shape.sh"), "show-rule"],
                      "traffic-shape show-rule")
    warnings = []
    items = _parse_config_lines(out, "rule ", "(no rules)",
                                _parse_rule_line, warnings)
    page = items[offset:offset + limit]
    return 200, {"rules": page}, _meta_list(
        len(items), len(page), limit, offset, warnings)


def ep_ts_sched(cfg, q):
    limit, offset = parse_paging(q)
    out = _run_or_500([sbin("titian-traffic-shape.sh"), "show-sched"],
                      "traffic-shape show-sched")
    warnings = []
    items = _parse_config_lines(out, "sched ", "(no schedulers)",
                                _parse_sched_line, warnings)
    page = items[offset:offset + limit]
    return 200, {"schedulers": page}, _meta_list(
        len(items), len(page), limit, offset, warnings)


def ep_ts_statistics(cfg, q):
    out = _run_or_500([sbin("titian-traffic-shape.sh"), "stats"],
                      "traffic-shape stats")
    lines, truncated, total = _cap_lines(out)
    warnings = []
    note = None
    for line in lines:
        if line.startswith("NOTE:"):
            note = line
            break
    sections = []
    cur = None
    for line in lines:
        m = re.match(r"^==\s+(.+?)\s+==$", line.strip())
        if m:
            cur = {"name": m.group(1), "lines": []}
            sections.append(cur)
            continue
        if cur is not None:
            cur["lines"].append(line)
    for s in sections:
        s["text"] = "\n".join(s["lines"]).strip()
        s["line_count"] = len(s["lines"])
        del s["lines"]
    dummynet = "dummynet not loaded" not in out
    meta = {"warnings": warnings}
    if truncated:
        meta["truncated"] = True
        meta["lines_total"] = total
    if not dummynet:
        return 200, {"available": False,
                     "reason": "dummynet belum dimuat "
                     "(traffic-shape belum pernah di-apply)",
                     "dummynet_loaded": False, "sections": []}, meta
    return 200, {"available": True, "dummynet_loaded": True,
                 "sections": sections, "note": note}, meta


def ep_pppoe(cfg, q):
    out = _run_or_500([sbin("titian-pppoe.sh"), "show"], "pppoe show")
    warnings = []
    vals = {}
    for line in out.splitlines():
        m = re.match(r"^([a-z-]+):\s*(.*)$", line.strip())
        if m:
            vals[m.group(1)] = m.group(2).strip()
    enabled = None
    if vals.get("pppoe-server") in ("yes", "no"):
        enabled = vals["pppoe-server"] == "yes"
    pool_start = pool_end = None
    pool = vals.get("pool")
    if pool and pool != "unset" and "-" in pool:
        pool_start, _, pool_end = pool.partition("-")
    sessions, w = get_pppoe_sessions()
    warnings += w
    data = {"enabled": enabled,
            "interface": vals.get("interface")
            if vals.get("interface") != "unset" else None,
            "pool": pool if pool != "unset" else None,
            "pool_start": pool_start, "pool_end": pool_end,
            "radius_server": vals.get("radius-server")
            if vals.get("radius-server") != "local auth" else None,
            "radius_auth": vals.get("radius-server") != "local auth"
            if "radius-server" in vals else None,
            "radius_acct": vals.get("radius-acct") == "yes"
            if vals.get("radius-acct") in ("yes", "no") else None,
            "radius_nas_ip": vals.get("radius-nas-ip")
            if vals.get("radius-nas-ip") != "unset" else None,
            "console": vals.get("console") == "yes"
            if vals.get("console") in ("yes", "no") else None,
            "console_password_set":
                "console password: set" in out,
            "users": _to_int(vals.get("users")),
            "mpd5_running": True if "mpd5 running" in out else
            (False if "mpd5 not running" in out else None),
            "sessions_active": len(sessions)}
    return 200, data, {"warnings": warnings}


def ep_pppoe_users(cfg, q):
    limit, offset = parse_paging(q)
    out = _run_or_500([sbin("titian-pppoe.sh"), "show-users"],
                      "pppoe show-users")
    warnings = []
    users = []
    for line in out.splitlines():
        s = line.strip()
        if not s or s == "(no users)":
            continue
        parts = s.split()
        if parts[0] == "USER":
            continue
        if len(parts) < 2 or not valid_user(parts[0]):
            warnings.append("baris user tidak bisa di-parse: %s" % s[:120])
            users.append({"raw": s})
            continue
        users.append({"user": parts[0],
                      "static_ip": parts[1]
                      if parts[1] not in ("pool", "-") else None})
    page = users[offset:offset + limit]
    return 200, {"users": page}, _meta_list(
        len(users), len(page), limit, offset, warnings)


def _read_ipoe_conf():
    # Baca ipoe.conf HANYA field non-rahasia (enable/interface/pool/
    # radius-server/nas-ip + hitungan MAC). radius-secret / omapi-key
    # TIDAK PERNAH dibaca ke respons.
    path = os.path.join(DEFAULT_STATE_ROOT, "ipoe.conf")
    conf = {"exists": os.path.isfile(path)}
    if not conf["exists"]:
        return conf
    conf.update({"enabled": False, "interface": None, "pool": None,
                 "radius_server": None, "nas_ip": None,
                 "radius_mac_auth": False, "radius_mac_count": 0,
                 "blocked_mac_count": 0})
    try:
        with open(path, "r") as f:
            for raw in f:
                line = raw.strip()
                if line == "enable":
                    conf["enabled"] = True
                elif line.startswith("interface "):
                    conf["interface"] = line.split(None, 1)[1]
                elif line.startswith("pool "):
                    conf["pool"] = line.split(None, 1)[1]
                elif line.startswith("radius-server "):
                    conf["radius_server"] = line.split(None, 1)[1]
                elif line.startswith("nas-ip "):
                    conf["nas_ip"] = line.split(None, 1)[1]
                elif line == "radius-mac-auth":
                    conf["radius_mac_auth"] = True
                elif line.startswith("radius-mac "):
                    conf["radius_mac_count"] += 1
                elif line.startswith("blocked-mac "):
                    conf["blocked_mac_count"] += 1
    except OSError:
        conf["exists"] = False
    return conf


def ep_ipoe(cfg, q):
    # titian-ipoe-acct.py TIDAK ADA di sbin-ref (hanya dirujuk komentar)
    # -> status dibangun dari ipoe.conf + dhcp server-status + lease file.
    warnings = []
    conf = _read_ipoe_conf()
    rc, out, err = run_backend([sbin("titian-dhcp.sh"), "server-status"],
                               timeout=10)
    dhcpd_running = None
    if rc == 0:
        if "running (pid" in out or ": running" in out:
            dhcpd_running = True
        elif "not running" in out:
            dhcpd_running = False
    else:
        warnings.append("dhcp server-status gagal: %s"
                        % sanitize_backend_text(err or out))
    try:
        leases = read_active_leases(DEFAULT_LEASES)
    except OSError as e:
        leases = {}
        warnings.append("lease file tidak bisa dibaca: %s" % e)
    if not conf["exists"]:
        return 200, {"available": False,
                     "reason": "IPoE belum dikonfigurasi "
                     "(ipoe.conf tidak ada)",
                     "enabled": False, "dhcpd_running": dhcpd_running,
                     "active_leases": len(leases),
                     "radius_mac_auth": False,
                     "blocked_mac_count": 0}, {"warnings": warnings}
    data = {"available": True, "reason": None,
            "enabled": conf["enabled"],
            "interface": conf["interface"], "pool": conf["pool"],
            "dhcpd_running": dhcpd_running,
            "active_leases": len(leases),
            "radius_server": conf["radius_server"],
            "nas_ip": conf["nas_ip"],
            "radius_mac_auth": conf["radius_mac_auth"],
            "radius_mac_count": conf["radius_mac_count"],
            "blocked_mac_count": conf["blocked_mac_count"]}
    return 200, data, {"warnings": warnings}


def ep_ipoe_leases(cfg, q):
    limit, offset = parse_paging(q)
    out = _run_or_500([sbin("titian-dhcp.sh"), "list-leases"],
                      "dhcp list-leases")
    warnings = []
    leases = []
    for line in out.splitlines():
        s = line.strip()
        if not s or s == "(tidak ada lease aktif)":
            continue
        parts = s.split()
        if len(parts) < 4 or not valid_ip(parts[0]) \
                or not valid_mac(parts[1]):
            warnings.append("baris lease tidak bisa di-parse: %s" % s[:120])
            leases.append({"raw": s})
            continue
        iso, epoch = _dhcp_dt_iso(parts[2] + " " + parts[3].rstrip(";"))
        if iso is None:
            warnings.append("tanggal ends lease tidak bisa di-parse: %s"
                            % s[:120])
            leases.append({"raw": s})
            continue
        leases.append({"ip": parts[0], "mac": parts[1].lower(),
                       "ends": iso, "ends_epoch": epoch})
    page = leases[offset:offset + limit]
    return 200, {"leases": page}, _meta_list(
        len(leases), len(page), limit, offset, warnings)


def ep_ipoe_blocked(cfg, q):
    limit, offset = parse_paging(q)
    out = _run_or_500([sbin("titian-dhcp.sh"), "list-blocked"],
                      "dhcp list-blocked")
    warnings = []
    blocked = []
    for line in out.splitlines():
        s = line.strip()
        if not s or s == "(tidak ada MAC diblokir)":
            continue
        if valid_mac(s):
            blocked.append({"mac": s.lower()})
        else:
            warnings.append("baris blocked tidak bisa di-parse: %s" % s[:120])
            blocked.append({"raw": s})
    page = blocked[offset:offset + limit]
    return 200, {"blocked": page}, _meta_list(
        len(blocked), len(page), limit, offset, warnings)


def ep_monitoring(cfg, q):
    service = q.get("service", [None])[0]
    if service is not None and service not in MON_SERVICES:
        raise ApiError(400, "validation_error",
                       "service tidak dikenal: %s "
                       "(pilihan: %s)" % (service, "|".join(MON_SERVICES)))
    limit, offset = parse_paging(q)
    argv = [sbin("titian-monitoring.sh"), "show"]
    if service:
        argv.append(service)
    out = _run_or_500(argv, "monitoring show")
    warnings = []
    services = []
    for line in out.splitlines():
        s = line.strip()
        if not s:
            continue
        m = MON_LINE_RE.match(s)
        if not m:
            warnings.append("baris monitoring tidak bisa di-parse: %s"
                            % s[:120])
            services.append({"raw": s})
            continue
        proc, port, intent, rc_flag, run, comm = m.groups()
        services.append({
            "service": MON_PROC.get(proc, proc),
            "process": proc, "port": port,
            "enabled": True if intent == "yes" else
            (False if intent == "no" else None),
            "intent": intent,
            "rc_enabled": True if rc_flag == "YES" else
            (False if rc_flag == "NO" else None),
            "running": run == "running",
            "community": comm})
    page = services[offset:offset + limit]
    return 200, {"services": page}, _meta_list(
        len(services), len(page), limit, offset, warnings)


def _parse_seconds(q):
    raw = q.get("seconds", ["60"])[0]
    try:
        v = int(raw)
    except ValueError:
        raise ApiError(400, "validation_error",
                       "seconds harus integer detik (1-3600)")
    if v < 1 or v > 3600:
        raise ApiError(400, "validation_error",
                       "seconds harus 1-3600 detik")
    return v


def ep_monitoring_bandwidth(cfg, q):
    seconds = _parse_seconds(q)
    out = _run_or_500([sbin("titian-monitoring.sh"), "bandwidth",
                       str(seconds)], "monitoring bandwidth",
                      timeout=seconds + 10)
    out = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", out)
    warnings = []
    # Mode live (>1 detik) mencetak tabel berulang — ambil tabel TERAKHIR.
    tables = []
    cur = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("Interface") and "RX" in s and "TX" in s:
            cur = []
            tables.append(cur)
            continue
        if cur is not None:
            if not s:
                cur = None
                continue
            cur.append(s)
    rows = tables[-1] if tables else []
    ifaces = []
    for s in rows:
        parts = s.split()
        if len(parts) != 7:
            warnings.append("baris bandwidth tidak bisa di-parse: %s"
                            % s[:120])
            ifaces.append({"raw": s})
            continue
        rx_bps = _parse_bps(parts[1] + " " + parts[2])
        tx_bps = _parse_bps(parts[3] + " " + parts[4])
        tot_bps = _parse_bps(parts[5] + " " + parts[6])
        if rx_bps is None or tx_bps is None or tot_bps is None:
            warnings.append("nilai bandwidth tidak bisa di-parse: %s"
                            % s[:120])
            ifaces.append({"raw": s})
            continue
        ifaces.append({"interface": parts[0],
                        "rx": parts[1] + " " + parts[2], "rx_bps": rx_bps,
                        "tx": parts[3] + " " + parts[4], "tx_bps": tx_bps,
                        "total": parts[5] + " " + parts[6],
                        "total_bps": tot_bps})
    if not tables:
        warnings.append("tidak ada tabel bandwidth di output backend")
    data = {"seconds": seconds, "interfaces": ifaces,
            "measured_at": utc_now()}
    return 200, data, {"warnings": warnings}


# ------------------------------------------------------------------- server
START_TIME = time.time()
RATE_BUCKETS = {}  # token-name -> [window_start_epoch, count]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "titian-api/" + API_VERSION

    def log_message(self, fmt, *args):
        # Log akses ke stderr (rc.d daemon menangkapnya) — tanpa token.
        log.info("%s %s" % (self.address_string(), fmt % args))

    def _send_json(self, http_status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(http_status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _ok(self, http_status, data, meta=None):
        payload = {"status": "ok", "data": data,
                   "meta": meta if meta is not None else {}}
        self._send_json(http_status, payload)

    def _err(self, http_status, code, message):
        payload = {"status": "error", "data": None,
                   "error": {"code": code, "message": message}}
        self._send_json(http_status, payload)

    def _read_json_body(self):
        length = self.headers.get("Content-Length")
        if length is None:
            return {}
        try:
            n = int(length)
        except ValueError:
            raise ApiError(400, "validation_error",
                           "Content-Length tidak valid")
        if n > 4096:
            raise ApiError(400, "validation_error",
                           "body terlalu besar (maks 4 KB)")
        raw = self.rfile.read(n) if n > 0 else b""
        if not raw:
            return {}
        ctype = self.headers.get("Content-Type", "")
        if "application/json" not in ctype:
            raise ApiError(400, "validation_error",
                           "Content-Type harus application/json")
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "validation_error",
                           "body bukan JSON valid")
        return body

    def _auth(self):
        cfg = self.server.cfg
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            raise ApiError(401, "unauthorized",
                           "Authorization: Bearer <token> wajib")
        presented = auth[7:].strip()
        if not presented or not TOKEN_RE.match(presented):
            raise ApiError(403, "forbidden", "token tidak dikenal")
        name = cfg.token_name(presented)
        if name is None:
            raise ApiError(403, "forbidden", "token tidak dikenal")
        return name

    def _rate_limit(self, token_name):
        cfg = self.server.cfg
        if cfg.rate_limit <= 0:
            return
        now = int(time.time())
        window, count = RATE_BUCKETS.get(token_name, (now, 0))
        if now - window >= 60:
            RATE_BUCKETS[token_name] = (now, 1)
            return
        if count >= cfg.rate_limit:
            raise ApiError(429, "rate_limited",
                           "terlalu banyak request (%d/menit per token)"
                           % cfg.rate_limit)
        RATE_BUCKETS[token_name] = (window, count + 1)

    def _route(self, method):
        cfg = self.server.cfg
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        q = parse_qs(parsed.query)
        m = re.match(r"^/api/v1/sessions/([^/]+)/(disconnect|isolate|unisolate)$",
                     path)
        if method == "GET" and path == "/api/v1/health":
            return ep_health(cfg)
        if method == "GET" and path == "/api/v1/sessions":
            return ep_sessions(cfg, q)
        if method == "GET" and path == "/api/v1/nas/status":
            return ep_nas_status(cfg)
        # --- D1: system / config / checkpoints (urut: exact dulu,
        # --- services/ssh sebelum services/:name) ---
        if method == "GET" and path == "/api/v1/system/version":
            return ep_system_version(cfg)
        if method == "GET" and path == "/api/v1/system":
            return ep_system(cfg)
        if method == "GET" and path == "/api/v1/system/memory":
            return ep_system_memory(cfg)
        if method == "GET" and path == "/api/v1/system/processes":
            return ep_system_processes(cfg, q)
        if method == "GET" and path == "/api/v1/system/connections":
            return ep_system_connections(cfg, q)
        if method == "GET" and path == "/api/v1/system/storage":
            return ep_system_storage(cfg, q)
        if method == "GET" and path == "/api/v1/system/sysctl":
            return ep_system_sysctl(cfg, q)
        if method == "GET" and path == "/api/v1/system/logins":
            return ep_system_logins(cfg, q)
        if method == "GET" and path == "/api/v1/system/hardware":
            return ep_system_hardware(cfg)
        if method == "GET" and path == "/api/v1/services":
            return ep_services(cfg, q)
        if method == "GET" and path == "/api/v1/services/ssh":
            return ep_service_ssh(cfg)
        m_svc = re.match(r"^/api/v1/services/([^/]+)$", path)
        if method == "GET" and m_svc:
            return ep_service_detail(cfg, m_svc.group(1), q)
        if method == "GET" and path == "/api/v1/config/running":
            return ep_config(cfg, "running")
        if method == "GET" and path == "/api/v1/config/startup":
            return ep_config(cfg, "startup")
        if method == "GET" and path == "/api/v1/checkpoints":
            return ep_checkpoints(cfg, q)
        # D2 — interfaces / IP / routes
        m_if_tune = re.match(r"^/api/v1/interfaces/([^/]+)/tuning$", path)
        m_if = re.match(r"^/api/v1/interfaces/([^/]+)$", path)
        m_vx = re.match(r"^/api/v1/vxlan/([^/]+)$", path)
        if method == "GET" and path == "/api/v1/interfaces":
            return ep_interfaces(cfg, q)
        if method == "GET" and m_if_tune:
            return ep_interface_tuning(cfg, m_if_tune.group(1))
        if method == "GET" and m_if:
            return ep_interface_detail(cfg, m_if.group(1), q)
        if method == "GET" and path == "/api/v1/neighbors":
            return ep_neighbors(cfg, q)
        if method == "GET" and path == "/api/v1/bridges":
            return ep_bridges(cfg, q)
        if method == "GET" and path == "/api/v1/vxlan":
            return ep_vxlan_list(cfg, q)
        if method == "GET" and m_vx:
            return ep_vxlan_detail(cfg, m_vx.group(1))
        if method == "GET" and path == "/api/v1/routes":
            return ep_routes(cfg, q)
        if method == "GET" and path == "/api/v1/routing/static":
            return ep_routing_static(cfg)
        if method == "GET" and path == "/api/v1/routing":
            return ep_routing(cfg)
        m2 = re.match(r"^/api/v1/sessions/([^/]+)$", path)
        if method == "GET" and m2:
            return ep_session_detail(cfg, m2.group(1), q)
        if method == "POST" and m:
            sid, action = m.group(1), m.group(2)
            body = self._read_json_body()
            if action == "disconnect":
                return ep_disconnect(cfg, sid, body, self._token_name)
            if action == "isolate":
                return ep_isolate(cfg, sid, body, self._token_name)
            return ep_unisolate(cfg, sid, body, self._token_name)
        # D3: bird / routing-protocols (GET saja, read-only).
        if method == "GET" and path == "/api/v1/bird/bgp":
            return ep_bird_bgp(cfg, q)
        if method == "GET" and path == "/api/v1/bird/bgp/summary":
            return ep_bird_bgp_summary(cfg, q)
        if method == "GET" and path == "/api/v1/bird/protocols":
            return ep_bird_protocols(cfg, q)
        if method == "GET" and path == "/api/v1/bird/protocols/summary":
            return ep_bird_protocols_summary(cfg, q)
        m3 = re.match(r"^/api/v1/bird/protocols/([^/]+)$", path)
        if method == "GET" and m3:
            return ep_bird_protocol_detail(cfg, m3.group(1), q)
        if method == "GET" and path == "/api/v1/bird/routes/stats":
            return ep_bird_routes_stats(cfg, q)
        if method == "GET" and path == "/api/v1/bird/routes":
            return ep_bird_routes(cfg, q)
        if method == "GET" and path == "/api/v1/bird/status":
            return ep_bird_status(cfg, q)
        if method == "GET" and path == "/api/v1/bird/symbols":
            return ep_bird_symbols(cfg, q)
        if method == "GET" and path == "/api/v1/bird/tables":
            return ep_bird_tables(cfg, q)
        if method == "GET" and path == "/api/v1/bird/global":
            return ep_bird_global(cfg, q)
        if method == "GET" and path == "/api/v1/bird/interfaces":
            return ep_bird_interfaces(cfg, q)
        if method == "GET" and path == "/api/v1/ospf":
            return ep_ospf(cfg, q)
        if method == "GET" and path == "/api/v1/ospf/interfaces":
            return ep_ospf_interfaces(cfg, q)
        if method == "GET" and path == "/api/v1/ospf/neighbors":
            return ep_ospf_neighbors(cfg, q)
        if method == "GET" and path == "/api/v1/ospf/state":
            return ep_ospf_state(cfg, q)
        if method == "GET" and path == "/api/v1/ospf/topology":
            return ep_ospf_topology(cfg, q)
        if method == "GET" and path == "/api/v1/ospf/lsadb":
            return ep_ospf_lsadb(cfg, q)
        if method == "GET" and path == "/api/v1/rip":
            return ep_rip(cfg, q)
        if method == "GET" and path == "/api/v1/rip/interfaces":
            return ep_rip_interfaces(cfg, q)
        if method == "GET" and path == "/api/v1/rip/neighbors":
            return ep_rip_neighbors(cfg, q)
        if method == "GET" and path == "/api/v1/bfd":
            return ep_bfd(cfg, q)
        if method == "GET" and path == "/api/v1/bfd/sessions":
            return ep_bfd_sessions(cfg, q)
        if method == "GET" and path == "/api/v1/rpki":
            return ep_rpki(cfg, q)
        if method == "GET" and path == "/api/v1/babel":
            return ep_babel(cfg, q)
        if method == "GET" and path == "/api/v1/direct":
            return ep_direct(cfg, q)
        if method == "GET" and path == "/api/v1/pipe":
            return ep_pipe(cfg, q)
        if method == "GET" and path == "/api/v1/device":
            return ep_device(cfg, q)
        if method == "GET" and path == "/api/v1/kernel":
            return ep_kernel(cfg, q)
        if method == "GET" and path == "/api/v1/l3vpn":
            return ep_l3vpn(cfg, q)
        if method == "GET" and path == "/api/v1/mrt":
            return ep_mrt(cfg, q)
        if method == "GET" and path == "/api/v1/bmp":
            return ep_bmp(cfg, q)
        if method == "GET" and path == "/api/v1/aggregator":
            return ep_aggregator(cfg, q)
        if method == "GET" and path == "/api/v1/radv":
            return ep_radv(cfg, q)
        if method == "GET" and path == "/api/v1/frr":
            return ep_frr(cfg, q)
        if method == "GET" and path == "/api/v1/frr/bgp/summary":
            return ep_frr_bgp_summary(cfg, q)
        if method == "GET" and path == "/api/v1/frr/bgp":
            return ep_frr_bgp(cfg, q)
        if method == "GET" and path == "/api/v1/frr/ospf/neighbors":
            return ep_frr_ospf_neighbors(cfg, q)
        if method == "GET" and path == "/api/v1/frr/ospf":
            return ep_frr_ospf(cfg, q)
        if method == "GET" and path == "/api/v1/frr/routes":
            return ep_frr_routes(cfg, q)
        if method == "GET" and path == "/api/v1/frr/version":
            return ep_frr_version(cfg, q)
        # D4a — firewall / wireguard
        if method == "GET" and path == "/api/v1/firewall":
            return ep_firewall(cfg)
        if method == "GET" and path == "/api/v1/firewall/filter":
            return ep_firewall_filter(cfg, q)
        if method == "GET" and path == "/api/v1/firewall/nat":
            return ep_firewall_nat(cfg, q)
        if method == "GET" and path == "/api/v1/firewall/isolated":
            return ep_firewall_isolated(cfg, q)
        if method == "GET" and path == "/api/v1/wireguard":
            return ep_wireguard(cfg, q)
        m_wg = re.match(r"^/api/v1/wireguard/([^/]+)$", path)
        if method == "GET" and m_wg:
            return ep_wireguard_one(cfg, m_wg.group(1))
        # D4b — traffic-shape / BRAS / monitoring
        if method == "GET" and path == "/api/v1/traffic-shape":
            return ep_traffic_shape(cfg, q)
        if method == "GET" and path == "/api/v1/traffic-shape/profiles":
            return ep_ts_profiles(cfg, q)
        if method == "GET" and path == "/api/v1/traffic-shape/pipes":
            return ep_ts_pipes(cfg, q)
        if method == "GET" and path == "/api/v1/traffic-shape/queues":
            return ep_ts_queues(cfg, q)
        if method == "GET" and path == "/api/v1/traffic-shape/rules":
            return ep_ts_rules(cfg, q)
        if method == "GET" and path == "/api/v1/traffic-shape/sched":
            return ep_ts_sched(cfg, q)
        if method == "GET" and path == "/api/v1/traffic-shape/statistics":
            return ep_ts_statistics(cfg, q)
        if method == "GET" and path == "/api/v1/pppoe":
            return ep_pppoe(cfg, q)
        if method == "GET" and path == "/api/v1/pppoe/users":
            return ep_pppoe_users(cfg, q)
        if method == "GET" and path == "/api/v1/ipoe":
            return ep_ipoe(cfg, q)
        if method == "GET" and path == "/api/v1/ipoe/leases":
            return ep_ipoe_leases(cfg, q)
        if method == "GET" and path == "/api/v1/ipoe/blocked":
            return ep_ipoe_blocked(cfg, q)
        if method == "GET" and path == "/api/v1/monitoring":
            return ep_monitoring(cfg, q)
        if method == "GET" and path == "/api/v1/monitoring/bandwidth":
            return ep_monitoring_bandwidth(cfg, q)
        m_tsprof = re.match(r"^/api/v1/traffic-shape/profiles/([^/]+)$", path)
        if method == "GET" and m_tsprof:
            return ep_ts_profile(cfg, m_tsprof.group(1), q)
        if path.startswith("/api/v1/"):
            raise ApiError(404, "not_found",
                           "endpoint tidak dikenal: %s %s" % (method, path))
        raise ApiError(404, "not_found", "path tidak dikenal: %s" % path)

    def _handle(self, method):
        self._token_name = None
        try:
            self._token_name = self._auth()
            self._rate_limit(self._token_name)
            status, data, meta = self._route(method)
            self._ok(status, data, meta)
        except ApiError as e:
            self._err(e.http_status, e.code, e.message)
        except BackendError as e:
            self._err(500, "internal_error", str(e))
        except BrokenPipeError:
            pass
        except Exception as e:
            log.exception("handler error")
            self._err(500, "internal_error", "kesalahan internal: %s" % e)

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_DELETE(self):
        self._handle("DELETE")

    def do_PATCH(self):
        self._handle("PATCH")


class ApiServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, cfg):
        self.cfg = cfg
        super().__init__((cfg.bind, cfg.port), Handler)


def cmd_serve(args):
    cfg = Config(args.config)
    cfg.load()
    ensure_tls(cfg)
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    server = ApiServer(cfg)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cfg.cert, cfg.key)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    log.info("titian-api %s listen https://%s:%d (isolir-web %s)",
             API_VERSION, cfg.bind, cfg.port,
             ("%s:%d" % (cfg.isolir_web_ip, cfg.isolir_web_port)
              if cfg.isolir_web_ip else "belum dikonfigurasi"))

    def _sigterm(signum, frame):
        log.info("SIGTERM — shutdown")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _sigterm)
    signal.signal(signal.SIGINT, _sigterm)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
    return 0


def cmd_check(args):
    # Validasi config + keberadaan backend (tanpa menjalankan aksi).
    cfg = Config(args.config)
    cfg.load()
    missing = []
    for name in ("titian-pppoe.sh", "titian-dhcp.sh", "titian-fw.sh",
                 "titian-bird.sh", "titian-sys.sh", "titian-sysctl.sh",
                 "titian-checkpoint.sh", "titian-show-config.sh",
                 "titian-show.sh", "titian-tune.sh",
                 "titian-bridge.sh", "titian-vxlan.sh", "titian-static.sh",
                 "titian-birdc.sh", "titian-bgp.sh",
                 "titian-ospf.sh", "titian-rip.sh", "titian-bfd.sh",
                 "titian-rpki.sh", "titian-frr.sh", "titian-global.sh",
                 "titian-babel.sh", "titian-direct.sh", "titian-pipe.sh",
                 "titian-protocol.sh", "titian-l3vpn.sh", "titian-mrt.sh",
                 "titian-bmp.sh", "titian-aggregator.sh", "titian-radv.sh",
                 "titian-wireguard.sh", "titian-traffic-shape.sh",
                 "titian-monitoring.sh"):
        if not os.path.isfile(sbin(name)):
            missing.append(sbin(name))
    for tool in ("pfctl", "netstat", "openssl", "w"):
        if subprocess.run(["which", tool], capture_output=True).returncode != 0:
            missing.append(tool)
    print("config: %s" % args.config)
    print("bind: %s:%d" % (cfg.bind, cfg.port))
    print("tokens: %s" % ", ".join(sorted(cfg.tokens)))
    print("isolir-web: %s" % ("%s:%d" % (cfg.isolir_web_ip, cfg.isolir_web_port)
                               if cfg.isolir_web_ip else "BELUM DIKONFIGURASI"))
    print("cert: %s key: %s" % (cfg.cert, cfg.key))
    if missing:
        print("HILANG: %s" % ", ".join(missing))
        return 1
    print("check OK")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="titian-api.py",
                                 description="titian-api — HTTP+JSON API "
                                 "untuk Titian (BRAS operator, Fase 2)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_serve = sub.add_parser("serve", help="jalankan daemon HTTPS")
    p_serve.add_argument("--config", default=DEFAULT_CONF)
    p_serve.set_defaults(fn=cmd_serve)
    p_gen = sub.add_parser("gentoken", help="buat/rotasi token bearer")
    p_gen.add_argument("--name", required=True)
    p_gen.add_argument("--config", default=DEFAULT_CONF)
    p_gen.set_defaults(fn=cmd_gentoken)
    p_chk = sub.add_parser("check", help="validasi config + backend")
    p_chk.add_argument("--config", default=DEFAULT_CONF)
    p_chk.set_defaults(fn=cmd_check)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
