#!/usr/bin/env python3
# test-web.py -- uji titian-web end-to-end dengan mock titian-api
# (daemon titian-api ASLI + stub backend + HTTPS nyata, seperti mock/test-api.py).
# Token/password di sini HANYA untuk mock lokal, bukan produksi.
import http.client
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MOCK = os.path.abspath(os.path.join(HERE, "..", "mock"))
BIN = os.path.join(MOCK, "bin")
ETC = os.path.join(MOCK, "etc")
STATE = os.path.join(MOCK, "state")
DAEMON = os.path.abspath(os.path.join(HERE, "..", "edit", "titian", "sbin", "titian-api.py"))
WEB = os.path.join(HERE, "titian-web.py")
API_PORT = 18443
WEB_PORT = 19091
DATA = os.path.join(HERE, "test-data")
LOG = open(os.path.join(HERE, "test-web-log.txt"), "w")
PASS = FAIL = 0

def logline(s):
    print(s)
    LOG.write(s + "\n")
    LOG.flush()

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        logline("PASS  %s" % name)
    else:
        FAIL += 1
        logline("FAIL  %s  %s" % (name, detail))

class Client:
    def __init__(self):
        self.cookies = {}
    def req(self, method, path, body=None, headers=None):
        h = dict(headers or {})
        if self.cookies:
            h["Cookie"] = "; ".join("%s=%s" % kv for kv in self.cookies.items())
        if body is not None:
            h["Content-Type"] = "application/x-www-form-urlencoded"
            payload = body
        else:
            payload = None
        conn = http.client.HTTPConnection("127.0.0.1", WEB_PORT, timeout=30)
        conn.request(method, path, body=payload, headers=h)
        r = conn.getresponse()
        raw = r.read()
        conn.close()
        setc = r.getheader("Set-Cookie")
        if setc:
            for part in setc.split(","):
                m = re.match(r"\s*([^=]+)=([^;]*)", part)
                if m:
                    self.cookies[m.group(1)] = m.group(2)
        return r.status, r.getheader("Location"), raw.decode("utf-8", "replace")

def login_form(c):
    s, _, b = c.req("GET", "/login")
    m = re.search(r'name="csrf" content="([^"]+)"', b)
    return m.group(1) if m else ""

def post(c, path, fields):
    s, loc, b = c.req("POST", path, body=fields)
    return s, loc, b

def csrf_of(c, path):
    s, _, b = c.req("GET", path)
    m = re.search(r'name="csrf" content="([^"]+)"', b)
    return m.group(1) if m else "", b

def main():
    env = dict(os.environ)
    env["PATH"] = BIN + ":" + env.get("PATH", "")
    env["MOCK_ETC"] = ETC
    env["TITIAN_SBIN"] = BIN
    env["TITIAN_STATE_ROOT"] = STATE
    env["DHCPD_LEASES"] = os.path.join(ETC, "dhcpd.leases")
    env["FW_CONF"] = os.path.join(ETC, "firewall.conf")
    env["PPPOE_CONF"] = os.path.join(ETC, "pppoe.conf")
    env["ISOLATED_CONF"] = os.path.join(ETC, "isolated.conf")
    # reset state mock (seperti test-api.py)
    open(os.path.join(ETC, "pppoe-sessions.txt"), "w").write(
        "titian-test|10.99.42.100|ng0\nagus|10.99.42.101|ng1\n")
    open(os.path.join(ETC, "dhcpd.leases"), "w").write(
        "lease 10.99.42.102 {\n  starts 4 2026/11/24 10:00:00;\n"
        "  ends 4 2026/11/24 11:00:00;\n  binding state active;\n"
        "  hardware ethernet 02:00:00:00:00:02;\n}\n")
    open(os.path.join(ETC, "isolated.conf"), "w").write("")
    for f in ("netstat-ng0.cnt", "netstat-ng1.cnt", "pf.cnt"):
        try:
            os.remove(os.path.join(ETC, f))
        except OSError:
            pass
    for f in ("titian-api-cert.pem", "titian-api-key.pem"):
        try:
            os.remove(os.path.join(STATE, f))
        except OSError:
            pass
    conf = os.path.join(ETC, "titian-api.conf")
    with open(conf, "w") as f:
        f.write("bind 127.0.0.1\nport %d\nisolir-web 203.0.113.10:80\n"
                "rate-limit 120\ncert %s\nkey %s\n"
                % (API_PORT, os.path.join(STATE, "titian-api-cert.pem"),
                   os.path.join(STATE, "titian-api-key.pem")))
    os.chmod(conf, 0o600)
    p = subprocess.run([sys.executable, DAEMON, "gentoken", "--name", "myraddash",
                        "--config", conf], capture_output=True, text=True, env=env)
    token = p.stdout.strip().split(":")[1].strip().split()[0]
    check("mock gentoken ok", len(token) == 64)
    errlog = open(os.path.join(MOCK, "daemon-stderr.log"), "w")
    api = subprocess.Popen([sys.executable, DAEMON, "serve", "--config", conf],
                           env=env, stdout=errlog, stderr=subprocess.STDOUT)
    fp = None
    try:
        # tunggu sertifikat selesai dibuat daemon (bukan sha256 dari file kosong)
        cert_path = os.path.join(STATE, "titian-api-cert.pem")
        for _ in range(20):
            if os.path.isfile(cert_path) and os.path.getsize(cert_path) > 0:
                break
            time.sleep(0.5)
        time.sleep(2)
        der = subprocess.run(["openssl", "x509", "-in", cert_path,
                              "-outform", "DER"], capture_output=True).stdout
        import hashlib
        fp = hashlib.sha256(der).hexdigest()
        check("fingerprint TLS mock terhitung (bukan hash kosong)",
              len(fp) == 64 and len(der) > 0
              and fp != hashlib.sha256(b"").hexdigest(), fp[:12])
        # --- web ---
        shutil.rmtree(DATA, ignore_errors=True)
        os.makedirs(DATA, exist_ok=True)
        p = subprocess.run([sys.executable, WEB, "create-admin", "--username", "admin",
                            "--password", "AdminKuat123", "--data", DATA],
                           capture_output=True, text=True)
        check("create-admin CLI ok", p.returncode == 0, p.stdout + p.stderr)
        p = subprocess.run([sys.executable, WEB, "check", "--data", DATA],
                           capture_output=True, text=True)
        check("web check OK", p.returncode == 0 and "check OK" in p.stdout, p.stdout)
        weblog = open(os.path.join(HERE, "test-web-stderr.log"), "w")
        web = subprocess.Popen([sys.executable, WEB, "serve", "--data", DATA,
                                "--port", str(WEB_PORT)],
                               stdout=weblog, stderr=subprocess.STDOUT, text=True)
        try:
            time.sleep(1.5)
            c = Client()
            s, _, b = c.req("GET", "/login")
            check("halaman login 200", s == 200 and "Masuk" in b, str(s))
            csrf = login_form(c)
            s, _, b = post(c, "/login", "csrf=%s&username=admin&password=Salah123" % csrf)
            check("login salah -> 401", s == 401, str(s))
            csrf = login_form(c)
            s, loc, b = post(c, "/login", "csrf=%s&username=admin&password=AdminKuat123" % csrf)
            check("login benar -> 303 ke /", s == 303 and loc == "/", "%s %s" % (s, loc))
            check("cookie sesi HttpOnly diset", "titian-web" in c.cookies)
            # tambah NAS via UI (token HANYA di form sekali)
            csrf, _ = csrf_of(c, "/nas")
            fields = ("csrf=%s&name=bras-mock&api_url=https%%3A%%2F%%2F127.0.0.1%%3A%d"
                      "&token_name=myraddash&token=%s&isolir_web=203.0.113.10%%3A80"
                      "&tls_fingerprint=%s" % (csrf, API_PORT, token, fp))
            s, loc, b = post(c, "/nas/add", fields)
            check("tambah NAS via UI -> 303", s == 303 and loc == "/nas", "%s %s %s" % (s, loc, b[:200]))
            tf = os.path.join(DATA, "nas-tokens.conf")
            check("nas-tokens.conf mode 600", oct(os.stat(tf).st_mode & 0o777) == "0o600")
            s, _, b = c.req("GET", "/nas")
            check("halaman NAS 200 + token TIDAK tampil di browser",
                  s == 200 and token not in b and "Tersimpan" in b, str(s))
            check("halaman NAS tanpa token di HTML", token not in b)
            s, _, b = c.req("GET", "/")
            check("dashboard 200", s == 200 and "Dashboard" in b, str(s))
            check("dashboard tampil jumlah sesi", "sesi aktif" in b.lower(), b[:300])
            s, _, b = c.req("GET", "/sessions")
            check("sesi aktif 200 + agus tampil", s == 200 and "agus" in b, str(s))
            check("sesi aktif tampil bps (800000 -> 800.00 Kbps)",
                  "800.00 Kbps" in b or "Kbps" in b, b[:500])
            totals = [int(x) for x in re.findall(r'data-total="(\d+)"', b)]
            check("sesi aktif urut usage desc (data-total menurun)",
                  len(totals) == 3 and totals == sorted(totals, reverse=True),
                  str(totals))
            s, _, b = c.req("GET", "/sessions.json?nas=1")
            j = json.loads(b)
            check("sessions.json ok + 3 sesi", j.get("ok") and j["html"].count("<tr>") == 3,
                  b[:300])
            # aksi tanpa reason -> 400
            csrf, _ = csrf_of(c, "/sessions")
            s, _, b = post(c, "/sessions/action",
                           "csrf=%s&nas_id=1&session_id=pppoe-titian-test&action=disconnect&reason=" % csrf)
            check("kick tanpa reason -> 400", s == 400, "%s %s" % (s, b[:150]))
            # kick end-to-end
            s, loc, b = post(c, "/sessions/action",
                             "csrf=%s&nas_id=1&session_id=pppoe-titian-test&action=disconnect&reason=tunggakan%%20mock" % csrf)
            check("kick pppoe-titian-test -> 303", s == 303, "%s %s" % (s, b[:200]))
            s, _, b = c.req("GET", "/sessions")
            check("titian-test hilang dari sesi aktif", "titian-test" not in b)
            s, _, b = c.req("GET", "/audit")
            check("audit 200 + kick tercatat (titian-test, alasan)",
                  s == 200 and "titian-test" in b and "tunggakan mock" in b, str(s))
            # isolir + unisolir ipoe
            s, loc, b = post(c, "/sessions/action",
                             "csrf=%s&nas_id=1&session_id=ipoe-020000000002&action=isolate&reason=tunggakan%%20mock" % csrf)
            check("isolir ipoe -> 303", s == 303, "%s %s" % (s, b[:200]))
            s, _, b = c.req("GET", "/sessions")
            check("sesi terisolir tampil ISOLIR", "ISOLIR" in b)
            s, loc, b = post(c, "/sessions/action",
                             "csrf=%s&nas_id=1&session_id=ipoe-020000000002&action=unisolate&reason=lunas%%20mock" % csrf)
            check("buka isolir -> 303", s == 303, "%s %s" % (s, b[:200]))
            s, _, b = c.req("GET", "/audit")
            check("audit: isolir + unisolir tercatat",
                  b.count("isolate") >= 1 and b.count("unisolate") >= 1, "")
            s, _, b = post(c, "/audit/delete", "csrf=%s" % csrf)
            check("tidak ada endpoint hapus audit (bukan 200/303 sukses)",
                  s in (403, 404), str(s))
            s, _, b = c.req("GET", "/clients")
            check("klien 200 + pemberitahuan radacct ditunda jujur",
                  s == 200 and "belum tersedia" in b, str(s))
            # operator: buat via UI admin, tugaskan hanya bras-mock
            csrf, _ = csrf_of(c, "/users")
            s, loc, b = post(c, "/users/add",
                             "csrf=%s&username=op1&password=Operator123&role=operator&nas_ids=1" % csrf)
            check("tambah operator op1 -> 303", s == 303, "%s %s" % (s, b[:150]))
            # NAS kedua (tidak ditugaskan ke op1)
            csrf, _ = csrf_of(c, "/nas")
            fields = ("csrf=%s&name=bras-lain&api_url=https%%3A%%2F%%2F127.0.0.1%%3A%d"
                      "&token_name=myraddash&token=%s&isolir_web=203.0.113.10%%3A80"
                      "&tls_fingerprint=%s" % (csrf, API_PORT, token, fp))
            s, loc, b = post(c, "/nas/add", fields)
            check("tambah NAS kedua -> 303", s == 303, "%s" % b[:150])
            op = Client()
            csrf = login_form(op)
            s, loc, b = post(op, "/login", "csrf=%s&username=op1&password=Operator123" % csrf)
            check("login operator 303", s == 303, str(s))
            s, _, b = op.req("GET", "/users")
            check("operator ditolak halaman Pengguna (403)", s == 403, str(s))
            s, _, b = op.req("GET", "/nas")
            check("operator ditolak halaman NAS (403)", s == 403, str(s))
            s, _, b = op.req("GET", "/sessions")
            check("operator bisa lihat sesi NAS tugasnya", s == 200 and "agus" in b, str(s))
            csrf, _ = csrf_of(op, "/sessions")
            s, _, b = post(op, "/sessions/action",
                           "csrf=%s&nas_id=2&session_id=pppoe-agus&action=disconnect&reason=coba%%20luar%%20tugas" % csrf)
            check("operator di luar NAS tugasnya -> 403", s == 403, "%s %s" % (s, b[:150]))
            s, _, b = op.req("GET", "/audit")
            check("operator bisa lihat audit", s == 200, str(s))
            # logout
            csrf, _ = csrf_of(c, "/sessions")
            s, loc, b = post(c, "/logout", "csrf=%s" % csrf)
            check("logout -> 303 ke /login", s == 303 and loc == "/login", "%s %s" % (s, loc))
            s, loc, b = c.req("GET", "/")
            check("sesudah logout dashboard redirect ke login", s == 303 and loc == "/login",
                  "%s %s" % (s, loc))
        finally:
            web.terminate()
            try:
                web.wait(timeout=5)
            except subprocess.TimeoutExpired:
                web.kill()
    finally:
        api.terminate()
        try:
            api.wait(timeout=5)
        except subprocess.TimeoutExpired:
            api.kill()
        errlog.close()
    try:
        txt = open(os.path.join(MOCK, "daemon-stderr.log")).read()
        check("stderr mock daemon tanpa Traceback", "Traceback" not in txt)
    except OSError:
        check("stderr mock daemon tanpa Traceback", False, "tidak ada log")
    logline("\nHASIL WEB MOCK: PASS=%d FAIL=%d" % (PASS, FAIL))
    LOG.close()
    return 1 if FAIL else 0

if __name__ == "__main__":
    sys.exit(main())
