#!/usr/bin/env python3
# titian-web.py -- Web UI operator Titian (Fase 2 langkah 4)
# Python 3 stdlib SAJA + sqlite3, tanpa dependensi pip.
# Server-side rendered, vanilla JS kecil (auto-refresh + modal alasan).
#
# Prinsip mengikat (blueprint Fase 2):
#  - single-engine: web TIDAK PERNAH menyentuh mpd5/BIRD/pf langsung,
#    hanya titian-api (HTTPS + bearer token per NAS), dari SISI SERVER.
#  - Token NAS TIDAK PERNAH tampil di browser/log. Token disimpan di
#    file mode 600 (nas-tokens.conf); DB hanya menyimpan referensi.
#  - TLS self-signed titian-api diterima HANYA dengan pin fingerprint
#    SHA-256 yang dicatat per NAS (atau flag lab eksplisit
#    tls_insecure_lab -- JANGAN dipakai produksi).
#  - Semua kick/isolir/unisolir wajib beralasan + tercatat di audit log
#    lokal; audit TIDAK BISA dihapus siapa pun (tidak ada endpoint hapus).
#  - TIDAK ADA menu Keuangan.
#
# Jalankan:  python3 titian-web.py serve [--data DIR] [--port 9091]
# Admin pertama: python3 titian-web.py create-admin --username admin
#   (password dibuat acak & dicetak SEKALI bila --password tidak diisi)
# Fingerprint TLS API: python3 titian-web.py fetch-fingerprint --url https://IP:8443
import argparse
import hashlib
import hmac
import html
import http.client
import json
import os
import re
import secrets
import sqlite3
import ssl
import sys
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"
PBKDF2_ITER = 200_000
SESSION_TTL = 8 * 3600
DATA_DIR = os.environ.get("TITIAN_WEB_DATA") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "data")
TOKEN_FILE = os.path.join(DATA_DIR, "nas-tokens.conf")
DB_FILE = os.path.join(DATA_DIR, "titian-web.db")
ISOLIR_WEB_DEFAULT = "203.0.113.10:80"  # PLACEHOLDER (TEST-NET-3), belum diputuskan user

# ---------------------------------------------------------------- util
def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def esc(s):
    return html.escape("" if s is None else str(s), quote=True)

def fmt_bps(v):
    try:
        v = int(v)
    except (TypeError, ValueError):
        return "-"
    if v >= 1_000_000:
        return "%.2f Mbps" % (v / 1_000_000)
    if v >= 1_000:
        return "%.1f Kbps" % (v / 1_000)
    return "%d bps" % v

def fmt_uptime(v):
    if v is None:
        return "-"
    try:
        v = int(v)
    except (TypeError, ValueError):
        return "-"
    h, r = divmod(v, 3600)
    m, s = divmod(r, 60)
    return "%02d:%02d:%02d" % (h, m, s) if h else "%02d:%02d" % (m, s)

def hash_password(pw, salt=None):
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, PBKDF2_ITER)
    return salt.hex(), dk.hex()

def verify_password(pw, salt_hex, hash_hex):
    salt = bytes.fromhex(salt_hex)
    dk = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, PBKDF2_ITER)
    return hmac.compare_digest(dk.hex(), hash_hex)

# ---------------------------------------------------------------- DB
def db():
    os.makedirs(DATA_DIR, exist_ok=True)
    con = sqlite3.connect(DB_FILE)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys=ON")
    con.executescript("""
    CREATE TABLE IF NOT EXISTS users(
      id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL,
      salt TEXT NOT NULL, pw_hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'operator',
      disabled INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS nas(
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL,
      api_url TEXT NOT NULL, token_name TEXT NOT NULL, isolir_web TEXT NOT NULL DEFAULT '',
      enabled INTEGER NOT NULL DEFAULT 1, tls_fingerprint TEXT NOT NULL DEFAULT '',
      tls_insecure_lab INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS user_nas(
      user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      nas_id INTEGER NOT NULL REFERENCES nas(id) ON DELETE CASCADE,
      PRIMARY KEY(user_id, nas_id));
    CREATE TABLE IF NOT EXISTS sessions(
      token TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      csrf TEXT NOT NULL, expires INTEGER NOT NULL, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS audit(
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, username TEXT NOT NULL,
      action TEXT NOT NULL, session_id TEXT, session_user TEXT, session_ip TEXT,
      nas_name TEXT, reason TEXT, result TEXT NOT NULL, detail TEXT);
    """)
    con.commit()
    return con

def audit_log(username, action, result, session_id=None, session_user=None,
              session_ip=None, nas_name=None, reason=None, detail=None):
    con = db()
    con.execute("INSERT INTO audit(ts,username,action,session_id,session_user,"
                "session_ip,nas_name,reason,result,detail) VALUES(?,?,?,?,?,?,?,?,?,?)",
                (now_iso(), username, action, session_id, session_user, session_ip,
                 nas_name, reason, result, detail))
    con.commit()
    con.close()

# ---------------------------------------------------------------- token NAS (file 600, bukan DB)
def _read_tokens():
    toks = {}
    try:
        with open(TOKEN_FILE) as f:
            for line in f:
                parts = line.strip().split(None, 1)
                if len(parts) == 2:
                    toks[parts[0]] = parts[1]
    except FileNotFoundError:
        pass
    return toks

def token_present(name):
    return name in _read_tokens()

def set_token(name, token):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", name):
        raise ValueError("nama token tidak valid")
    if not re.fullmatch(r"[A-Za-z0-9]{32,128}", token or ""):
        raise ValueError("token harus hex/alnum 32-128 karakter")
    toks = _read_tokens()
    toks[name] = token
    tmp = TOKEN_FILE + ".tmp"
    with open(tmp, "w") as f:
        for k in sorted(toks):
            f.write("%s %s\n" % (k, toks[k]))
    os.chmod(tmp, 0o600)
    os.replace(tmp, TOKEN_FILE)
    os.chmod(TOKEN_FILE, 0o600)

def delete_token(name):
    toks = _read_tokens()
    toks.pop(name, None)
    tmp = TOKEN_FILE + ".tmp"
    with open(tmp, "w") as f:
        for k in sorted(toks):
            f.write("%s %s\n" % (k, toks[k]))
    os.chmod(tmp, 0o600)
    os.replace(tmp, TOKEN_FILE)

# ---------------------------------------------------------------- titian-api client (server-side saja)
class ApiError(Exception):
    def __init__(self, msg, status=None):
        super().__init__(msg)
        self.status = status

def api_call(nas, method, path, body=None):
    """nas: sqlite Row. Token tidak pernah keluar dari fungsi ini."""
    token = _read_tokens().get(nas["token_name"])
    if not token:
        raise ApiError("token NAS '%s' belum disimpan (admin: isi token di menu NAS)"
                       % nas["token_name"])
    u = urllib.parse.urlparse(nas["api_url"])
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ApiError("api_url NAS tidak valid: %s" % nas["api_url"])
    port = u.port or (443 if u.scheme == "https" else 80)
    headers = {"Authorization": "Bearer " + token,
               "Content-Type": "application/json"}
    payload = json.dumps(body) if body is not None else None
    if u.scheme == "https":
        ctx = ssl._create_unverified_context()
        conn = http.client.HTTPSConnection(u.hostname, port, timeout=20, context=ctx)
    else:
        conn = http.client.HTTPConnection(u.hostname, port, timeout=20)
    try:
        conn.request(method, "/api/v1" + path, body=payload, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        if u.scheme == "https" and not nas["tls_insecure_lab"]:
            fp = (nas["tls_fingerprint"] or "").lower().replace(":", "")
            cert = conn.sock.getpeercert(binary_form=True) if conn.sock else None
            if not fp:
                raise ApiError("fingerprint TLS NAS belum dicatat "
                               "(admin: catat via fetch-fingerprint / menu NAS)")
            if not cert:
                raise ApiError("tidak dapat membaca sertifikat TLS NAS")
            actual = hashlib.sha256(cert).hexdigest()
            if not hmac.compare_digest(actual, fp):
                sys.stderr.write("TLS FP MISMATCH expected=%s actual=%s url=%s\n"
                                 % (fp, actual, nas["api_url"]))
                raise ApiError("fingerprint TLS NAS TIDAK COCOK -- koneksi ditolak")
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except Exception:
            raise ApiError("respons API bukan JSON (HTTP %d)" % resp.status, resp.status)
        return resp.status, parsed
    finally:
        conn.close()

def fetch_fingerprint(url):
    u = urllib.parse.urlparse(url)
    if u.scheme != "https" or not u.hostname:
        raise ValueError("URL harus https://host:port")
    ctx = ssl._create_unverified_context()
    conn = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=10, context=ctx)
    conn.request("GET", "/")
    conn.getresponse().read()
    cert = conn.sock.getpeercert(binary_form=True)
    conn.close()
    return hashlib.sha256(cert).hexdigest()

# ---------------------------------------------------------------- akses NAS per pengguna
def nas_visible_to(user):
    con = db()
    if user["role"] == "admin":
        rows = con.execute("SELECT * FROM nas ORDER BY name").fetchall()
    else:
        rows = con.execute(
            "SELECT n.* FROM nas n JOIN user_nas un ON un.nas_id=n.id "
            "WHERE un.user_id=? ORDER BY n.name", (user["id"],)).fetchall()
    con.close()
    return rows

def user_can_nas(user, nas_id):
    if user["role"] == "admin":
        return True
    con = db()
    r = con.execute("SELECT 1 FROM user_nas WHERE user_id=? AND nas_id=?",
                    (user["id"], nas_id)).fetchone()
    con.close()
    return r is not None

# ---------------------------------------------------------------- HTML
LOGO_SVG = ('<svg width="34" height="34" viewBox="0 0 40 40" aria-hidden="true">'
            '<polygon points="20,4 36,34 4,34" fill="#efa9c8"/>'
            '<polygon points="20,12 30,30 10,30" fill="#fffafc"/></svg>')

def page(title, user, body, active=""):
    nav = ""
    if user:
        items = [("dashboard", "Dashboard", "/"), ("sessions", "Sesi Aktif", "/sessions"),
                 ("clients", "Klien", "/clients"), ("nas", "NAS", "/nas"),
                 ("audit", "Audit Log", "/audit")]
        if user["role"] == "admin":
            items.append(("users", "Pengguna & Peran", "/users"))
        links = "".join(
            '<a href="%s" class="%s">%s</a>' % (href, "on" if active == k else "", label)
            for k, label, href in items)
        nav = ('<nav>%s<span class="who">%s (%s) &middot; '
               '<a href="/logout" onclick="return false" id="logout-link">Keluar</a></span></nav>'
               % (links, esc(user["username"]), esc(user["role"])))
        nav += ('<form id="logout-form" method="post" action="/logout" style="display:none">'
                '<input type="hidden" name="csrf" value=""></form>'
                '<script>document.getElementById("logout-link").onclick=function(){'
                'var f=document.getElementById("logout-form");'
                'f.csrf.value=document.querySelector("meta[name=csrf]").content;'
                'f.submit();return false;}</script>')
    csrf = ""
    if user:
        con = db()
        # csrf diambil dari sesi aktif (cookie) di handler; placeholder diganti di sana
        con.close()
    return ("<!DOCTYPE html><html lang=\"id\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<meta name=\"csrf\" content=\"__CSRF__\">"
            "<title>%s &middot; TITIAN</title>"
            "<link rel=\"stylesheet\" href=\"/static/style.css\"></head><body>"
            "<header><div class=\"brand\">%s<span>TITIAN</span>"
            "<small>Web Operator BRAS</small></div>%s</header>"
            "<main>%s</main>"
            "<footer>TITIAN web v%s &middot; single-engine: semua aksi lewat titian-api &middot; "
            "token NAS tidak pernah tampil di browser</footer></body></html>"
            % (esc(title), LOGO_SVG, nav, body, VERSION))

def sessions_table(sess):
    rows = ""
    for s in sess:
        total = (s.get("rx_bps") or 0) + (s.get("tx_bps") or 0)
        badge = ' <span class="tag iso">ISOLIR</span>' if s.get("isolated") else ""
        rows += ("<tr><td>%s%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
                 "<td>%s</td><td>%s</td><td class=\"num\" data-total=\"%d\">%s</td>"
                 "<td><button class=\"btn kick\" data-id=\"%s\" data-user=\"%s\" "
                 "data-action=\"disconnect\">Kick</button> "
                 "%s</td></tr>"
                 % (esc(s.get("user")), badge, esc(s.get("ip")), esc(s.get("type")),
                    esc(s.get("interface") or "-"), fmt_uptime(s.get("uptime_seconds")),
                    fmt_bps(s.get("rx_bps")), fmt_bps(s.get("tx_bps")), total,
                    fmt_bps(total), esc(s.get("id")), esc(s.get("user")),
                    ('<button class="btn uniso" data-id="%s" data-user="%s" '
                     'data-action="unisolate">Buka Isolir</button>'
                     % (esc(s.get("id")), esc(s.get("user")))) if s.get("isolated")
                    else ('<button class="btn iso" data-id="%s" data-user="%s" '
                          'data-action="isolate">Isolir</button>'
                          % (esc(s.get("id")), esc(s.get("user"))))))
    if not rows:
        rows = '<tr><td colspan="9">Tidak ada sesi aktif.</td></tr>'
    return rows

MODAL_JS = """
<div id="modal" class="modal" hidden>
 <div class="box"><h3 id="modal-title">Aksi</h3>
 <p id="modal-text"></p>
 <form method="post" action="/sessions/action" id="action-form">
  <input type="hidden" name="csrf" id="csrf-field">
  <input type="hidden" name="nas_id" id="f-nas">
  <input type="hidden" name="session_id" id="f-sid">
  <input type="hidden" name="action" id="f-act">
  <label>Alasan (wajib diisi)<textarea name="reason" id="f-reason" rows="3" required
   maxlength="200" placeholder="Contoh: tunggakan 2 bulan"></textarea></label>
  <div class="row"><button class="btn primary" type="submit">Jalankan</button>
  <button class="btn" type="button" onclick="document.getElementById('modal').hidden=true">Batal</button></div>
 </form></div></div>
<script>
var CSRF=document.querySelector('meta[name=csrf]').content;
document.getElementById('csrf-field').value=CSRF;
function openModal(btn){
 var act=btn.dataset.action, user=btn.dataset.user;
 document.getElementById('f-nas').value=document.getElementById('nas-select').value;
 document.getElementById('f-sid').value=btn.dataset.id;
 document.getElementById('f-act').value=act;
 var label={disconnect:'Kick (putuskan sesi)',isolate:'Isolir',unisolate:'Buka isolir'}[act];
 document.getElementById('modal-title').textContent=label+' — '+user;
 document.getElementById('modal-text').textContent=
  act==='disconnect' ? 'Sesi akan diputus. Pengguna bisa dial ulang.' :
  act==='isolate' ? 'Internet pengguna diarahkan ke halaman isolir (web isolir). Sesi tetap tersambung, kecepatan tetap sesuai paket.' :
  'Isolir dicabut, internet kembali normal.';
 document.getElementById('modal').hidden=false;
 document.getElementById('f-reason').focus();
}
document.querySelectorAll('button[data-action]').forEach(function(b){
 b.addEventListener('click',function(){openModal(b);});});
</script>
"""

# ---------------------------------------------------------------- HTTP handler
class Handler(BaseHTTPRequestHandler):
    server_version = "titian-web/" + VERSION

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (now_iso(), fmt % args))

    # -- helpers
    def _send(self, status, body, ctype="text/html; charset=utf-8", extra=None):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _redirect(self, loc):
        self.send_response(303)
        self.send_header("Location", loc)
        self.end_headers()

    def _cookie_session(self):
        raw = self.headers.get("Cookie", "")
        for part in raw.split(";"):
            part = part.strip()
            if part.startswith("titian-web="):
                return part[len("titian-web="):]
        return None

    def _current_user(self):
        tok = self._cookie_session()
        if not tok:
            return None, None
        con = db()
        row = con.execute(
            "SELECT s.*, u.username, u.role, u.id AS uid, u.disabled FROM sessions s "
            "JOIN users u ON u.id=s.user_id WHERE s.token=?", (tok,)).fetchone()
        if not row or row["expires"] < int(time.time()) or row["disabled"]:
            con.close()
            return None, None
        user = {"id": row["uid"], "username": row["username"], "role": row["role"]}
        con.close()
        return user, {"token": tok, "csrf": row["csrf"]}

    def _require(self):
        user, sess = self._current_user()
        if not user:
            self._redirect("/login")
            return None, None
        return user, sess

    def _render(self, title, user, sess, body, active=""):
        out = page(title, user, body, active)
        if sess:
            out = out.replace("__CSRF__", esc(sess["csrf"]))
        return out

    def _form(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        return urllib.parse.parse_qs(raw)

    def _check_csrf(self, form, sess):
        v = (form.get("csrf") or [""])[0]
        return sess and hmac.compare_digest(v, sess["csrf"])

    def _val(self, form, key, default=""):
        return (form.get(key) or [default])[0].strip()

    # -- routing
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        path, qs = u.path, urllib.parse.parse_qs(u.query)
        if path == "/static/style.css":
            here = os.path.dirname(os.path.abspath(__file__))
            try:
                with open(os.path.join(here, "static", "style.css"), "rb") as f:
                    self._send(200, f.read(), "text/css; charset=utf-8")
            except FileNotFoundError:
                self._send(404, "not found", "text/plain")
            return
        if path == "/login":
            user, _ = self._current_user()
            if user:
                self._redirect("/")
                return
            csrf = secrets.token_hex(16)
            body = ('<h1>Masuk</h1><p class="muted">Login operator TITIAN. '
                    'Akun dibuat admin lewat CLI <code>create-admin</code>; '
                    'tidak ada password default.</p>'
                    '<form method="post" action="/login" class="card">'
                    '<input type="hidden" name="csrf" value="">'
                    '<label>Nama pengguna<input name="username" required autofocus></label>'
                    '<label>Kata sandi<input type="password" name="password" required></label>'
                    '<button class="btn primary" type="submit">Masuk</button></form>'
                    '<script>document.querySelector("input[name=csrf]").value='
                    'document.querySelector("meta[name=csrf]").content;</script>')
            out = page("Masuk", None, body)
            out = out.replace("__CSRF__", esc(csrf))
            self._send(200, out, extra={"Set-Cookie":
                        "titian-login-csrf=%s; HttpOnly; SameSite=Lax; Path=/login; Max-Age=600"
                        % csrf})
            return
        user, sess = self._require()
        if not user:
            return
        if path == "/":
            self._dashboard(user, sess)
        elif path == "/sessions":
            self._sessions(user, sess, qs)
        elif path == "/sessions.json":
            self._sessions_json(user, qs)
        elif path == "/clients":
            self._clients(user, sess, qs)
        elif path == "/nas":
            self._nas_list(user, sess)
        elif path == "/nas/test":
            self._nas_test(user, sess, qs)
        elif path == "/nas/edit":
            self._nas_edit_form(user, sess, qs)
        elif path == "/audit":
            self._audit(user, sess, qs)
        elif path == "/users":
            self._users(user, sess)
        else:
            self._send(404, self._render("Tidak ditemukan", user, sess,
                                          "<h1>404</h1><p>Halaman tidak ada.</p>"))

    # -- pages
    def _dashboard(self, user, sess):
        nases = nas_visible_to(user)
        cards, total, iso_total = "", 0, 0
        for n in nases:
            if not n["enabled"]:
                cards += ('<div class="card"><h3>%s</h3><p class="muted">Nonaktif</p></div>'
                          % esc(n["name"]))
                continue
            try:
                st, b = api_call(n, "GET", "/nas/status")
                d = b.get("data", {}) if b.get("status") == "ok" else {}
                total += int(d.get("sessions_total") or 0)
                iso_total += int(d.get("isolated_count") or 0)
                cards += ('<div class="card"><h3>%s</h3><p>Sesi aktif: <b>%s</b> '
                          '(PPPoE %s, IPoE %s) &middot; terisolir: <b>%s</b></p>'
                          '<p class="muted">Titian %s &middot; BSDRP %s &middot; '
                          'web isolir %s</p></div>'
                          % (esc(n["name"]), d.get("sessions_total", "?"),
                             d.get("sessions_pppoe", "?"), d.get("sessions_ipoe", "?"),
                             d.get("isolated_count", "?"), esc(d.get("titian_version") or "?"),
                             esc(d.get("bsdrp_version") or "?"),
                             esc(d.get("isolir_web") or n["isolir_web"] or "-")))
            except ApiError as e:
                cards += ('<div class="card err"><h3>%s</h3>'
                          '<p>API tidak terjangkau: %s</p>'
                          '<p class="muted">Lihat panduan operator: bila API tidak terjangkau.</p></div>'
                          % (esc(n["name"]), esc(str(e))))
        if not nases:
            cards = ('<div class="card"><p>Belum ada NAS. '
                     'Admin: tambahkan NAS di menu <a href="/nas">NAS</a>.</p></div>')
        body = ('<h1>Dashboard</h1>'
                '<div class="stats"><div><b>%d</b><span>sesi aktif (semua NAS)</span></div>'
                '<div><b>%d</b><span>terisolir</span></div>'
                '<div><b>%d</b><span>NAS</span></div></div>%s'
                % (total, iso_total, len(nases), cards))
        self._send(200, self._render("Dashboard", user, sess, body, "dashboard"))

    def _pick_nas(self, user, qs):
        nases = [n for n in nas_visible_to(user) if n["enabled"]]
        if not nases:
            return None, []
        want = (qs.get("nas") or [""])[0]
        for n in nases:
            if str(n["id"]) == want:
                return n, nases
        return nases[0], nases

    def _nas_options(self, nases, current):
        opts = ""
        for n in nases:
            opts += ('<option value="%d"%s>%s</option>'
                     % (n["id"], " selected" if current and n["id"] == current["id"] else "",
                        esc(n["name"])))
        return opts

    def _sessions(self, user, sess, qs):
        nas, nases = self._pick_nas(user, qs)
        if not nas:
            body = ("<h1>Sesi Aktif</h1><div class=\"card\"><p>Belum ada NAS aktif. "
                    "Admin: tambahkan NAS di menu <a href=\"/nas\">NAS</a>.</p></div>")
            self._send(200, self._render("Sesi Aktif", user, sess, body, "sessions"))
            return
        try:
            st, b = api_call(nas, "GET", "/sessions?sort=usage&sample=1&limit=100")
            sess_list = b.get("data", {}).get("sessions", []) if b.get("status") == "ok" else []
            warn = ""
            for w in (b.get("meta") or {}).get("warnings", []):
                warn += '<p class="warn">Peringatan API: %s</p>' % esc(w)
            err = ""
        except ApiError as e:
            sess_list, warn = [], ""
            err = ('<p class="warn">API NAS %s tidak terjangkau: %s</p>'
                   % (esc(nas["name"]), esc(str(e))))
        body = ('<h1>Sesi Aktif</h1>%s%s'
                '<form method="get" action="/sessions" class="row">'
                '<label>NAS <select name="nas" id="nas-select" onchange="this.form.submit()">%s'
                '</select></label>'
                '<span class="muted">Auto-refresh tiap 5 detik &middot; urut pemakaian terbesar dulu</span>'
                '</form>'
                '<table><thead><tr><th>Pengguna</th><th>IP</th><th>Tipe</th><th>Interface</th>'
                '<th>Uptime</th><th>Unduh (rx)</th><th>Unggah (tx)</th><th>Total</th>'
                '<th>Aksi</th></tr></thead><tbody id="sess-body">%s</tbody></table>%s'
                % (err, warn, self._nas_options(nases, nas), sessions_table(sess_list), MODAL_JS))
        body += ('<script>var NASID=%d;'
                 'setInterval(function(){fetch("/sessions.json?nas="+NASID).then(function(r){return r.json();})'
                 '.then(function(j){if(j.ok){document.getElementById("sess-body").innerHTML=j.html;'
                 'document.querySelectorAll("#sess-body button[data-action]").forEach(function(b){'
                 'b.addEventListener("click",function(){openModal(b);});});}}).catch(function(){});},5000);'
                 '</script>' % nas["id"])
        self._send(200, self._render("Sesi Aktif", user, sess, body, "sessions"))

    def _sessions_json(self, user, qs):
        nas, _ = self._pick_nas(user, qs)
        if not nas:
            self._send(200, json.dumps({"ok": False, "error": "tidak ada NAS"}),
                       "application/json")
            return
        try:
            st, b = api_call(nas, "GET", "/sessions?sort=usage&sample=1&limit=100")
            sess_list = b.get("data", {}).get("sessions", []) if b.get("status") == "ok" else []
            self._send(200, json.dumps({"ok": True, "html": sessions_table(sess_list)}),
                       "application/json")
        except ApiError as e:
            self._send(200, json.dumps({"ok": False, "error": str(e)}), "application/json")

    def _clients(self, user, sess, qs):
        nas, nases = self._pick_nas(user, qs)
        live = []
        try:
            if nas:
                st, b = api_call(nas, "GET", "/sessions?sort=user&sample=0&limit=100")
                live = b.get("data", {}).get("sessions", []) if b.get("status") == "ok" else []
        except ApiError as e:
            live = []
        rows = "".join("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"
                       % (esc(s.get("user")), esc(s.get("ip")), esc(s.get("type")),
                          "Terisolir" if s.get("isolated") else "Aktif")
                       for s in live)
        con = db()
        if user["role"] == "admin":
            hist = con.execute(
                "SELECT DISTINCT session_user, session_ip FROM audit "
                "WHERE session_user IS NOT NULL ORDER BY session_user LIMIT 200").fetchall()
        else:
            names = [n["name"] for n in nases]
            q = ",".join("?" * len(names)) if names else "''"
            hist = con.execute(
                "SELECT DISTINCT session_user, session_ip FROM audit "
                "WHERE session_user IS NOT NULL AND nas_name IN (%s) "
                "ORDER BY session_user LIMIT 200" % q, names).fetchall() if names else []
        con.close()
        hrows = "".join("<tr><td>%s</td><td>%s</td><td>Riwayat (audit log)</td></tr>"
                        % (esc(r["session_user"]), esc(r["session_ip"] or "-")) for r in hist)
        body = ('<h1>Klien</h1>'
                '<p class="notice">Riwayat sesi dari RADIUS (radacct myRadDASH) '
                '<b>belum tersedia di ronde ini</b> — akun layanan myRadDASH belum ada. '
                'Yang tampil di bawah: pengguna dari sesi live + riwayat dari audit log lokal.</p>'
                '<form method="get" action="/clients" class="row"><label>NAS '
                '<select name="nas" onchange="this.form.submit()">%s</select></label></form>'
                '<h2>Sesi live</h2><table><thead><tr><th>Pengguna</th><th>IP</th>'
                '<th>Tipe</th><th>Status</th></tr></thead><tbody>%s</tbody></table>'
                '<h2>Riwayat (audit log lokal)</h2><table><thead><tr><th>Pengguna</th>'
                '<th>IP</th><th>Sumber</th></tr></thead><tbody>%s</tbody></table>'
                % (self._nas_options(nases, nas) if nases else "",
                   rows or '<tr><td colspan="4">Tidak ada sesi live.</td></tr>',
                   hrows or '<tr><td colspan="3">Belum ada riwayat.</td></tr>'))
        self._send(200, self._render("Klien", user, sess, body, "clients"))

    def _nas_list(self, user, sess):
        if user["role"] != "admin":
            self._send(403, self._render("Ditolak", user, sess,
                                          "<h1>403</h1><p>Hanya admin.</p>"))
            return
        con = db()
        rows = con.execute("SELECT * FROM nas ORDER BY name").fetchall()
        con.close()
        tr = ""
        for n in rows:
            tr += ("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
                   "<td><a class=\"btn\" href=\"/nas/test?id=%d\">Test koneksi</a> "
                   "<a class=\"btn\" href=\"/nas/edit?id=%d\">Ubah</a></td></tr>"
                   % (esc(n["name"]), esc(n["api_url"]), esc(n["isolir_web"] or "-"),
                      "Ya" if n["enabled"] else "Tidak",
                      "Tersimpan" if token_present(n["token_name"]) else "<b>Belum ada token</b>",
                      n["id"], n["id"]))
        body = ('<h1>NAS</h1><p class="muted">Token NAS tidak pernah ditampilkan di sini. '
                'Token hanya dimasukkan sekali oleh admin; sesudah itu hanya status '
                '"Tersimpan" yang terlihat.</p>'
                '<table><thead><tr><th>Nama</th><th>API URL</th><th>Web isolir</th>'
                '<th>Aktif</th><th>Token</th><th>Aksi</th></tr></thead><tbody>%s</tbody></table>'
                '<h2>Tambah NAS</h2><form method="post" action="/nas/add" class="card">'
                '<input type="hidden" name="csrf" value="%s">'
                '<label>Nama<input name="name" required pattern="[A-Za-z0-9_-]{1,64}"></label>'
                '<label>API URL<input name="api_url" required placeholder="https://10.0.0.1:8443"></label>'
                '<label>Nama token<input name="token_name" required pattern="[A-Za-z0-9_-]{1,64}" '
                'placeholder="mis. bras-utama"></label>'
                '<label>Token (dimasukkan sekali, tidak ditampilkan lagi)'
                '<input type="password" name="token" required autocomplete="off"></label>'
                '<label>Web isolir<input name="isolir_web" value="%s"></label>'
                '<label>Fingerprint TLS SHA-256 (wajib untuk https; kosong = koneksi ditolak)'
                '<input name="tls_fingerprint" placeholder="diambil via: titian-web.py fetch-fingerprint"></label>'
                '<label><input type="checkbox" name="tls_insecure_lab" value="1"> '
                'LAB SAJA: lewati verifikasi fingerprint (jangan dipakai produksi)</label>'
                '<button class="btn primary" type="submit">Simpan NAS</button></form>'
                % (tr or '<tr><td colspan="6">Belum ada NAS.</td></tr>',
                   esc(sess["csrf"]), esc(ISOLIR_WEB_DEFAULT)))
        self._send(200, self._render("NAS", user, sess, body, "nas"))

    def _nas_test(self, user, sess, qs):
        if user["role"] != "admin":
            self._send(403, self._render("Ditolak", user, sess,
                                          "<h1>403</h1><p>Hanya admin.</p>"))
            return
        try:
            nid = int((qs.get("id") or [""])[0])
        except ValueError:
            self._send(400, "id tidak valid", "text/plain")
            return
        con = db()
        nas = con.execute("SELECT * FROM nas WHERE id=?", (nid,)).fetchone()
        con.close()
        if not nas:
            self._send(404, "NAS tidak ditemukan", "text/plain")
            return
        out = []
        for label, p in (("health", "/health"), ("nas/status", "/nas/status")):
            try:
                st, b = api_call(nas, "GET", p)
                out.append("<p><b>%s</b>: HTTP %d — %s</p>"
                           % (label, st, esc(json.dumps(b.get("data", {}), ensure_ascii=False)[:300])))
            except ApiError as e:
                out.append("<p class=\"warn\"><b>%s</b>: gagal — %s</p>" % (label, esc(str(e))))
        body = "<h1>Test koneksi — %s</h1>%s<p><a href=\"/nas\">Kembali ke NAS</a></p>" % (
            esc(nas["name"]), "".join(out))
        self._send(200, self._render("Test NAS", user, sess, body, "nas"))

    def _nas_edit_form(self, user, sess, qs):
        if user["role"] != "admin":
            self._send(403, self._render("Ditolak", user, sess,
                                          "<h1>403</h1><p>Hanya admin.</p>"))
            return
        try:
            nid = int((qs.get("id") or [""])[0])
        except ValueError:
            self._send(400, "id tidak valid", "text/plain")
            return
        con = db()
        nas = con.execute("SELECT * FROM nas WHERE id=?", (nid,)).fetchone()
        con.close()
        if not nas:
            self._send(404, "NAS tidak ditemukan", "text/plain")
            return
        body = ('<h1>Ubah NAS — %s</h1><form method="post" action="/nas/edit" class="card">'
                '<input type="hidden" name="csrf" value="%s">'
                '<input type="hidden" name="id" value="%d">'
                '<label>API URL<input name="api_url" value="%s" required></label>'
                '<label>Web isolir<input name="isolir_web" value="%s"></label>'
                '<label>Fingerprint TLS SHA-256<input name="tls_fingerprint" value="%s"></label>'
                '<label><input type="checkbox" name="tls_insecure_lab" value="1"%s> '
                'LAB SAJA: lewati verifikasi fingerprint</label>'
                '<label>Token baru (kosong = token lama tetap dipakai; tidak pernah ditampilkan)'
                '<input type="password" name="token" autocomplete="off"></label>'
                '<label><input type="checkbox" name="enabled" value="1"%s> Aktif</label>'
                '<button class="btn primary" type="submit">Simpan</button></form>'
                '<p><a href="/nas">Kembali ke NAS</a></p>'
                % (esc(nas["name"]), esc(sess["csrf"]), nas["id"], esc(nas["api_url"]),
                   esc(nas["isolir_web"]), esc(nas["tls_fingerprint"]),
                   " checked" if nas["tls_insecure_lab"] else "",
                   " checked" if nas["enabled"] else ""))
        self._send(200, self._render("Ubah NAS", user, sess, body, "nas"))

    def _nas_edit(self, user, form):
        try:
            nid = int(self._val(form, "id"))
        except ValueError:
            self._send(400, "id tidak valid", "text/plain")
            return
        con = db()
        nas = con.execute("SELECT * FROM nas WHERE id=?", (nid,)).fetchone()
        if not nas:
            con.close()
            self._send(404, "NAS tidak ditemukan", "text/plain")
            return
        fp = self._val(form, "tls_fingerprint").lower().replace(":", "")
        if fp and not re.fullmatch(r"[0-9a-f]{64}", fp):
            con.close()
            self._send(400, "fingerprint harus SHA-256 hex 64 karakter", "text/plain")
            return
        token = self._val(form, "token")
        if token:
            try:
                set_token(nas["token_name"], token)
            except ValueError as e:
                con.close()
                self._send(400, str(e), "text/plain")
                return
        con.execute("UPDATE nas SET api_url=?, isolir_web=?, tls_fingerprint=?, "
                    "tls_insecure_lab=?, enabled=? WHERE id=?",
                    (self._val(form, "api_url"), self._val(form, "isolir_web"), fp,
                     1 if self._val(form, "tls_insecure_lab") == "1" else 0,
                     1 if self._val(form, "enabled") == "1" else 0, nid))
        con.commit()
        con.close()
        audit_log(user["username"], "nas_edit", "ok", nas_name=nas["name"])
        self._redirect("/nas")

    def _audit(self, user, sess, qs):
        con = db()
        if user["role"] == "admin":
            rows = con.execute("SELECT * FROM audit ORDER BY id DESC LIMIT 200").fetchall()
        else:
            names = [n["name"] for n in nas_visible_to(user)]
            q = ",".join("?" * len(names)) if names else "''"
            rows = con.execute(
                "SELECT * FROM audit WHERE nas_name IN (%s) OR username=? "
                "ORDER BY id DESC LIMIT 200" % q, names + [user["username"]]).fetchall() if names else []
        con.close()
        tr = "".join(
            "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
            "<td>%s</td><td>%s</td></tr>"
            % (esc(r["ts"]), esc(r["username"]), esc(r["action"]), esc(r["session_user"] or "-"),
               esc(r["session_ip"] or "-"), esc(r["nas_name"] or "-"),
               esc(r["reason"] or "-"), esc(r["result"]))
            for r in rows)
        body = ('<h1>Audit Log</h1><p class="muted">Setiap kick / isolir / buka isolir '
                'tercatat di sini. <b>Audit log tidak bisa dihapus siapa pun</b> — '
                'tidak ada tombol hapus.</p>'
                '<table><thead><tr><th>Waktu (UTC)</th><th>Operator</th><th>Aksi</th>'
                '<th>Pengguna</th><th>IP</th><th>NAS</th><th>Alasan</th><th>Hasil</th>'
                '</tr></thead><tbody>%s</tbody></table>'
                % (tr or '<tr><td colspan="8">Belum ada entri.</td></tr>'))
        self._send(200, self._render("Audit Log", user, sess, body, "audit"))

    def _users(self, user, sess):
        if user["role"] != "admin":
            self._send(403, self._render("Ditolak", user, sess,
                                          "<h1>403</h1><p>Hanya admin.</p>"))
            return
        con = db()
        users = con.execute("SELECT id, username, role, disabled, created_at FROM users "
                            "ORDER BY username").fetchall()
        nases = con.execute("SELECT id, name FROM nas ORDER BY name").fetchall()
        assign = {}
        for r in con.execute("SELECT user_id, nas_id FROM user_nas"):
            assign.setdefault(r["user_id"], set()).add(r["nas_id"])
        con.close()
        tr = ""
        for u in users:
            nas_names = ", ".join(esc(n["name"]) for n in nases
                                  if n["id"] in assign.get(u["id"], set())) or "-"
            tr += ("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"
                   % (esc(u["username"]), esc(u["role"]),
                      "Nonaktif" if u["disabled"] else "Aktif", nas_names))
        nas_checks = "".join(
            '<label class="chk"><input type="checkbox" name="nas_ids" value="%d"> %s</label>'
            % (n["id"], esc(n["name"])) for n in nases)
        body = ('<h1>Pengguna &amp; Peran</h1>'
                '<table><thead><tr><th>Pengguna</th><th>Peran</th><th>Status</th>'
                '<th>NAS yang ditugaskan</th></tr></thead><tbody>%s</tbody></table>'
                '<h2>Tambah pengguna</h2><form method="post" action="/users/add" class="card">'
                '<input type="hidden" name="csrf" value="%s">'
                '<label>Nama pengguna<input name="username" required></label>'
                '<label>Kata sandi<input type="password" name="password" required></label>'
                '<label>Peran<select name="role"><option value="operator">operator</option>'
                '<option value="admin">admin</option></select></label>'
                '<fieldset><legend>NAS yang ditugaskan (operator)</legend>%s</fieldset>'
                '<button class="btn primary" type="submit">Simpan pengguna</button></form>'
                '<p class="muted">Operator hanya bisa kick/isolir di NAS yang ditugaskan. '
                'Admin bisa semua NAS. Akun pertama dibuat lewat CLI '
                '<code>create-admin</code>, bukan dari halaman ini.</p>'
                % (tr or '<tr><td colspan="4">Belum ada pengguna.</td></tr>',
                   esc(sess["csrf"]), nas_checks or "Belum ada NAS."))
        self._send(200, self._render("Pengguna & Peran", user, sess, body, "users"))

    # -- POST
    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        path = u.path
        form = self._form()
        if path == "/login":
            # CSRF login: token di cookie titian-login-csrf harus sama dengan field form
            csrf_cookie = None
            for part in self.headers.get("Cookie", "").split(";"):
                part = part.strip()
                if part.startswith("titian-login-csrf="):
                    csrf_cookie = part[len("titian-login-csrf="):]
            if not csrf_cookie or not hmac.compare_digest(
                    (form.get("csrf") or [""])[0], csrf_cookie):
                self._send(403, "CSRF tidak valid", "text/plain")
                return
            username = self._val(form, "username")
            password = self._val(form, "password")
            con = db()
            row = con.execute("SELECT * FROM users WHERE username=? AND disabled=0",
                              (username,)).fetchone()
            ok = row and verify_password(password, row["salt"], row["pw_hash"])
            if not ok:
                con.close()
                # throttle sederhana: jeda tetap, tanpa membocorkan akun ada/tidak
                time.sleep(1)
                self._send(401, page("Masuk", None,
                    '<h1>Masuk</h1><p class="warn">Nama pengguna atau kata sandi salah.</p>'
                    '<p><a href="/login">Coba lagi</a></p>').replace("__CSRF__", ""))
                return
            tok = secrets.token_hex(32)
            csrf = secrets.token_hex(16)
            con.execute("INSERT INTO sessions(token,user_id,csrf,expires,created_at) "
                        "VALUES(?,?,?,?,?)",
                        (tok, row["id"], csrf, int(time.time()) + SESSION_TTL, now_iso()))
            con.commit()
            con.close()
            self.send_response(303)
            self.send_header("Location", "/")
            self.send_header("Set-Cookie",
                             "titian-web=%s; HttpOnly; SameSite=Lax; Path=/; Max-Age=%d"
                             % (tok, SESSION_TTL))
            self.send_header("Set-Cookie",
                             "titian-login-csrf=; HttpOnly; SameSite=Lax; Path=/login; Max-Age=0")
            self.end_headers()
            return
        user, sess = self._require()
        if not user:
            return
        if not self._check_csrf(form, sess):
            self._send(403, self._render("Ditolak", user, sess,
                                          "<h1>403</h1><p>CSRF tidak valid.</p>"))
            return
        if path == "/logout":
            con = db()
            con.execute("DELETE FROM sessions WHERE token=?", (sess["token"],))
            con.commit()
            con.close()
            self.send_response(303)
            self.send_header("Location", "/login")
            self.send_header("Set-Cookie",
                             "titian-web=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0")
            self.end_headers()
            return
        if path == "/sessions/action":
            self._action(user, form)
        elif path == "/nas/add" and user["role"] == "admin":
            self._nas_add(user, form)
        elif path == "/nas/edit" and user["role"] == "admin":
            self._nas_edit(user, form)
        elif path == "/users/add" and user["role"] == "admin":
            self._users_add(user, form)
        else:
            self._send(403, self._render("Ditolak", user, sess,
                                          "<h1>403</h1><p>Aksi tidak diizinkan.</p>"))

    def _action(self, user, form):
        try:
            nas_id = int(self._val(form, "nas_id"))
        except ValueError:
            self._send(400, "NAS tidak valid", "text/plain")
            return
        sid = self._val(form, "session_id")
        action = self._val(form, "action")
        reason = self._val(form, "reason")
        if action not in ("disconnect", "isolate", "unisolate"):
            self._send(400, "aksi tidak dikenal", "text/plain")
            return
        if not reason or len(reason) > 200:
            self._send(400, "alasan wajib diisi (1-200 karakter)", "text/plain")
            return
        if not re.fullmatch(r"[A-Za-z0-9_-]+", sid or ""):
            self._send(400, "session id tidak valid", "text/plain")
            return
        if not user_can_nas(user, nas_id):
            audit_log(user["username"], action, "ditolak: NAS bukan tugas operator",
                      session_id=sid, reason=reason)
            self._send(403, "NAS ini bukan tugas Anda", "text/plain")
            return
        con = db()
        nas = con.execute("SELECT * FROM nas WHERE id=? AND enabled=1", (nas_id,)).fetchone()
        con.close()
        if not nas:
            self._send(404, "NAS tidak ditemukan / nonaktif", "text/plain")
            return
        # ambil info sesi dulu (untuk audit: user + IP)
        s_user, s_ip = sid, None
        try:
            st, b = api_call(nas, "GET", "/sessions/%s?sample=0" % sid)
            if b.get("status") == "ok":
                s = b["data"]["session"]
                s_user, s_ip = s.get("user"), s.get("ip")
        except ApiError:
            pass
        try:
            st, b = api_call(nas, "POST", "/sessions/%s/%s" % (sid, action),
                             {"reason": reason})
        except ApiError as e:
            audit_log(user["username"], action, "gagal: %s" % e,
                      session_id=sid, session_user=s_user, session_ip=s_ip,
                      nas_name=nas["name"], reason=reason)
            self._send(502, "API gagal: %s" % esc(str(e)), "text/plain")
            return
        if b.get("status") != "ok":
            detail = (b.get("error") or {}).get("message", "error API")
            audit_log(user["username"], action, "gagal: %s" % detail,
                      session_id=sid, session_user=s_user, session_ip=s_ip,
                      nas_name=nas["name"], reason=reason)
            self._send(502, "API menolak: %s" % esc(detail), "text/plain")
            return
        audit_log(user["username"], action, "ok",
                  session_id=sid, session_user=s_user, session_ip=s_ip,
                  nas_name=nas["name"], reason=reason,
                  detail=json.dumps(b.get("data", {}), ensure_ascii=False))
        self._redirect("/sessions?nas=%d" % nas_id)

    def _nas_add(self, user, form):
        name = self._val(form, "name")
        api_url = self._val(form, "api_url")
        token_name = self._val(form, "token_name")
        token = self._val(form, "token")
        isolir_web = self._val(form, "isolir_web") or ISOLIR_WEB_DEFAULT
        fp = self._val(form, "tls_fingerprint").lower().replace(":", "")
        insecure = 1 if self._val(form, "tls_insecure_lab") == "1" else 0
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", name or ""):
            self._send(400, "nama NAS tidak valid", "text/plain")
            return
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", token_name or ""):
            self._send(400, "nama token tidak valid", "text/plain")
            return
        if fp and not re.fullmatch(r"[0-9a-f]{64}", fp):
            self._send(400, "fingerprint harus SHA-256 hex 64 karakter", "text/plain")
            return
        try:
            set_token(token_name, token)
        except ValueError as e:
            self._send(400, str(e), "text/plain")
            return
        con = db()
        try:
            con.execute("INSERT INTO nas(name,api_url,token_name,isolir_web,enabled,"
                        "tls_fingerprint,tls_insecure_lab,created_at) VALUES(?,?,?,?,?,?,?,?)",
                        (name, api_url, token_name, isolir_web, 1, fp, insecure, now_iso()))
            con.commit()
        except sqlite3.IntegrityError:
            self._send(400, "nama NAS sudah ada", "text/plain")
            con.close()
            return
        con.close()
        audit_log(user["username"], "nas_add", "ok", nas_name=name,
                  detail="api_url=%s isolir_web=%s" % (api_url, isolir_web))
        self._redirect("/nas")

    def _users_add(self, user, form):
        username = self._val(form, "username")
        password = self._val(form, "password")
        role = self._val(form, "role") or "operator"
        if role not in ("admin", "operator"):
            self._send(400, "peran tidak valid", "text/plain")
            return
        if len(password) < 8:
            self._send(400, "kata sandi minimal 8 karakter", "text/plain")
            return
        salt, pw_hash = hash_password(password)
        con = db()
        try:
            cur = con.execute("INSERT INTO users(username,salt,pw_hash,role,created_at) "
                              "VALUES(?,?,?,?,?)",
                              (username, salt, pw_hash, role, now_iso()))
            uid = cur.lastrowid
            for nid in form.get("nas_ids", []):
                try:
                    con.execute("INSERT INTO user_nas(user_id,nas_id) VALUES(?,?)",
                                (uid, int(nid)))
                except ValueError:
                    pass
            con.commit()
        except sqlite3.IntegrityError:
            self._send(400, "nama pengguna sudah ada", "text/plain")
            con.close()
            return
        con.close()
        audit_log(user["username"], "user_add", "ok", detail="username=%s role=%s" % (username, role))
        self._redirect("/users")

# ---------------------------------------------------------------- CLI + main
def cmd_create_admin(args):
    db()
    con = db()
    if con.execute("SELECT 1 FROM users WHERE username=?", (args.username,)).fetchone():
        print("create-admin: pengguna sudah ada", file=sys.stderr)
        return 1
    pw = args.password or secrets.token_urlsafe(18)
    salt, pw_hash = hash_password(pw)
    con.execute("INSERT INTO users(username,salt,pw_hash,role,created_at) VALUES(?,?,?,?,?)",
                (args.username, salt, pw_hash, "admin", now_iso()))
    con.commit()
    con.close()
    if args.password:
        print("admin '%s' dibuat (peran admin)." % args.username)
    else:
        print("admin '%s' dibuat (peran admin)." % args.username)
        print("PASSWORD (dicetak SEKALI, simpan sekarang): %s" % pw)
    return 0

def main():
    global DATA_DIR, TOKEN_FILE, DB_FILE
    ap = argparse.ArgumentParser(prog="titian-web.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("serve")
    p.add_argument("--data", default=DATA_DIR)
    p.add_argument("--host", default=os.environ.get("TITIAN_WEB_HOST", "0.0.0.0"))
    p.add_argument("--port", type=int, default=int(os.environ.get("TITIAN_WEB_PORT", "9091")))
    p = sub.add_parser("create-admin")
    p.add_argument("--username", default="admin")
    p.add_argument("--password")
    p.add_argument("--data", default=DATA_DIR)
    p = sub.add_parser("fetch-fingerprint")
    p.add_argument("--url", required=True)
    p = sub.add_parser("check")
    p.add_argument("--data", default=DATA_DIR)
    args = ap.parse_args()
    if getattr(args, "data", None):
        DATA_DIR = args.data
        TOKEN_FILE = os.path.join(DATA_DIR, "nas-tokens.conf")
        DB_FILE = os.path.join(DATA_DIR, "titian-web.db")
    if args.cmd == "serve":
        db()
        srv = ThreadingHTTPServer((args.host, args.port), Handler)
        sys.stderr.write("titian-web %s listen %s:%d data=%s\n"
                         % (VERSION, args.host, args.port, DATA_DIR))
        srv.serve_forever()
    elif args.cmd == "create-admin":
        return cmd_create_admin(args)
    elif args.cmd == "fetch-fingerprint":
        print(fetch_fingerprint(args.url))
        return 0
    elif args.cmd == "check":
        db()
        con = db()
        n = con.execute("SELECT COUNT(*) c FROM users").fetchone()["c"]
        con.close()
        print("check OK: db=%s users=%d token_file=%s" % (DB_FILE, n, TOKEN_FILE))
        return 0
    return 0

if __name__ == "__main__":
    sys.exit(main())
