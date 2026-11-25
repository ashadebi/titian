# titian-api — HTTP+JSON API for Titian (BRAS operator)

This document describes the Titian operator API (Phase 2, steps 1+2):
a small HTTP+JSON daemon on the BSDRP router used by the operator web
UI and myRadDASH to view active sessions, kick, and isolate users —
from a browser, without needing to know FreeBSD/klish.

> Indonesian version: `doc/titian-api.md` (same content).

## 1. What titian-api is

`titian-api` is a small daemon (Python 3 stdlib ONLY, no pip
dependencies) running on the BSDRP router, exposing operator operations
as an HTTP+JSON API:

- `GET /api/v1/health` — is the API up? Titian/BSDRP/BIRD/FRR versions?
- `GET /api/v1/sessions` — all active sessions (PPPoE + IPoE) + live
  rx/tx bandwidth in bps, sorted by usage (largest first) by default.
- `GET /api/v1/sessions/:id` — one session.
- `POST /api/v1/sessions/:id/disconnect` — kick (drop the session).
- `POST /api/v1/sessions/:id/isolate` — isolate a user to the isolir web.
- `POST /api/v1/sessions/:id/unisolate` — remove isolation.
- `GET /api/v1/nas/status` — NAS status (versions, pppoe/pf, session counts).

## 2. Architecture — single-engine

The API **never** touches mpd5 / BIRD / pf / dummynet directly. Every
operation goes through the SAME backend scripts used by the klish
`ACTION`s — one implementation per operation, shared by CLI and API:

| API operation | Backend used |
|---|---|
| PPPoE sessions | `titian-pppoe.sh sessions-detail` (new; `user\|framed_ip\|link` from mpd5 console `show sessions`) |
| PPPoE kick | `titian-pppoe.sh disconnect <user> <framed-ip>` (mpd5 console, Option A — proven live 20 Nov 2026) |
| IPoE sessions | dhcpd lease file `/var/db/dhcpd.leases` (same parser as `titian-ipoe-acct.py`) |
| IPoE kick | `titian-dhcp.sh kick-lease <mac>` (free the lease; reconnect allowed) |
| Isolate / unisolate | `titian-fw.sh isolate / unisolate / show-isolated` (state `/usr/local/etc/isolated.conf`) |
| Versions | `pkg info titian` + `titian-bird.sh show-version` |
| PPPoE bandwidth | `netstat -I <ngX> -b` (interface counters) |
| IPoE bandwidth | `pfctl -a traffic-shape -s rules -v` (per-rule pf counters) |

Why not go through `klish` (konf batch)? Konf output is human-formatted
and pager-wrapped — fragile to parse by machine. The backend scripts
are the same layer klish calls, so API and CLI can never drift apart
in behavior.

Web input is **never** interpolated into a shell: subprocess always
uses argv lists (`shell=False`), arguments are strictly validated
first (username `[A-Za-z0-9_-]+`, IPv4, MAC, session id).

## 3. Installation & running

### 3.1 Install

The API is installed together with the Titian package (daemon at
`/opt/titian/sbin/titian-api.py`, rc.d at
`/usr/local/etc/rc.d/titian-api`, example config at
`/usr/local/etc/titian-api.conf.example`).

### 3.2 Configuration

Copy the example to the live config, then fill it in:

```sh
cp /usr/local/etc/titian-api.conf.example /usr/local/etc/titian-api.conf
chmod 600 /usr/local/etc/titian-api.conf
```

File contents (see also `titian-api.conf.example`):

```ini
bind 127.0.0.1
port 8443
isolir-web 103.50.129.84:80
rate-limit 60
# cert /etc/titian/titian-api-cert.pem
# key /etc/titian/titian-api-key.pem
# token <name> <hex>   -- created via gentoken, do not fill in manually
```

- `bind` — the IP the API listens on. **Must be a management IP /
  127.0.0.1. `0.0.0.0` is REJECTED at startup** (the daemon refuses
  to run).
- `isolir-web` — the isolir web (payment portal) address, the dst-nat
  target. **Required before using `isolate`** (empty → 400). This
  address has NOT been decided by the user (24 Nov 2026) — the value
  in the example is a placeholder; replace it with the real address.
- `rate-limit` — requests per minute per token (default 60; over →
  429 `rate_limited`).
- `cert` / `key` — TLS certificate. If the files do not exist yet,
  the daemon creates a self-signed one via openssl on first start.
  Production: replace with a proper certificate, then restart.

### 3.3 Tokens

```sh
service titian-api gentoken --name myraddash
```

The token is printed **ONCE** to the root admin terminal — store it
in the myRadDASH NAS record. After that, the token can only be read
from the config file (mode 600, root-only). Rotation: run
`gentoken --name <name>` again with the same name (old token is
overwritten), then update the NAS record.

### 3.4 Starting the service

```sh
# /etc/rc.conf
titian_api_enable="YES"
```

```sh
service titian-api start
service titian-api status
```

Validate config + backends without running anything:

```sh
/usr/local/bin/python3 /opt/titian/sbin/titian-api.py check
```

## 4. Auth & rate limit

- Every endpoint requires `Authorization: Bearer <token>`.
- No token → **401 `unauthorized`**; wrong token → **403 `forbidden`**.
- Per-token rate limit (default 60/min) → **429 `rate_limited`**.
- All access is HTTPS (TLS). Default certificate is self-signed — pin
  the fingerprint in myRadDASH if needed, or replace it with a proper
  certificate.

## 5. JSON contract (binding)

User decision 24 Nov 17:46. Applies to ALL endpoints.

Success:

```json
{ "status": "ok", "data": {...}, "meta": {...} }
```

Error:

```json
{ "status": "error", "data": null,
  "error": { "code": "STABLE_CODE", "message": "..." } }
```

- HTTP status by meaning: 200 success, 400 invalid input, 401 no
  token, 403 wrong token, 404 not found, 429 rate limit, 500 internal
  error.
- Stable `error.code`: `unauthorized`, `forbidden`, `not_found`,
  `validation_error`, `rate_limited`, `internal_error`.
- snake_case; numbers stay numbers (bps as integers); timestamps ISO
  8601 UTC (`2026-11-24T11:18:52Z`); lists carry `meta` (`total`,
  `sort`, `limit`/`offset`); `Content-Type: application/json;
  charset=utf-8` always; versioning in the path (`/api/v1/`).
- A failure of one data source (e.g. the mpd5 console not answering)
  does NOT fail the whole request — it is reported in `meta.warnings`
  (list of strings); sessions from other sources are still returned.

## 6. Endpoints

Endpoints 6.1–6.7 are the original BRAS API (Phase 2 steps 1–3). Endpoints 6.8–6.94 are the read-all-CLI-menus expansion (25 Nov 2026): D1 system/config/checkpoints (§6.8–6.22), D2 interfaces/IP/routes (§6.23–6.32), D3 BIRD/routing-protocols (§6.33–6.73), D4a firewall/WireGuard (§6.74–6.79), D4b traffic-shape/BRAS/monitoring (§6.80–6.94). All new endpoints are GET only, behind the same bearer token + rate-limit (§4); the common contract in §5 applies to all of them (envelope, snake_case, pagination `?limit=`/`?offset=`, 2000-line cap, unparseable lines → `raw` + `meta.warnings`). Write endpoints remain the old ones (disconnect/isolate/unisolate, §6.4–6.6); new write proposals are recorded in each domain's notes, not implemented.

### 6.1 `GET /api/v1/health`

```http
GET /api/v1/health
Authorization: Bearer <token>
```

Success response (200):

```json
{ "status": "ok",
  "data": {
    "api_version": "1.0.0",
    "titian_version": "0.1.1",
    "bsdrp_version": "n314296",
    "bird_variant": "BIRD 2",
    "bird_version": 2,
    "frr_version": "10.7.1 (not running)",
    "uptime_seconds": 3600,
    "time_utc": "2026-11-24T11:18:52Z"
  },
  "meta": { "warnings": [] } }
```

Fields that cannot be read are `null` (not an error).

### 6.2 `GET /api/v1/sessions`

```http
GET /api/v1/sessions?sort=usage&sample=2&limit=100&offset=0
Authorization: Bearer <token>
```

Query:

| Param | Default | Meaning |
|---|---|---|
| `sort` | `usage` | `usage` (rx+tx desc) \| `user` \| `ip` \| `uptime` |
| `sample` | `2` | bandwidth counter sampling seconds (0–5; 0 = no rate, bps 0) |
| `limit` | `100` | 1–1000 |
| `offset` | `0` | >= 0 |

One session (object):

| Field | Type | Meaning |
|---|---|---|
| `id` | string | `pppoe-<user>` or `ipoe-<mac-without-colons>` |
| `type` | string | `pppoe` \| `ipoe` |
| `user` | string | PPPoE username, or MAC (IPoE) |
| `ip` | string | Framed-IP / lease IP |
| `mac` | string\|null | MAC (IPoE only) |
| `interface` | string\|null | ng* interface (PPPoE only) |
| `uptime_seconds` | int\|null | session age; PPPoE `null` (ng* carries no start time) |
| `rx_bps` / `tx_bps` | int | live download / upload (bits/second) |
| `rx_bytes_total` / `tx_bytes_total` | int\|null | total counter bytes (null when the counter source is absent) |
| `rate_source` | string | `ng` (netstat ng*) \| `pf` (pf rule counter) \| `none` |
| `isolated` | bool | currently isolated? |

Success response (200, example — bps values are examples):

```json
{ "status": "ok",
  "data": { "sessions": [
    { "id": "pppoe-agus", "type": "pppoe", "user": "agus",
      "ip": "10.99.42.101", "mac": null, "interface": "ng1",
      "uptime_seconds": null, "rx_bps": 850000, "tx_bps": 120000,
      "rx_bytes_total": 123456789, "tx_bytes_total": 9876543,
      "rate_source": "ng", "isolated": false }
  ] },
  "meta": { "total": 1, "count": 1, "pppoe_count": 1, "ipoe_count": 0,
            "isolated_count": 0, "sort": "usage", "sample_seconds": 2,
            "limit": 100, "offset": 0, "warnings": [] } }
```

Error: unknown `sort` → 400 `validation_error`.

### 6.3 `GET /api/v1/sessions/:id`

```http
GET /api/v1/sessions/pppoe-agus?sample=2
Authorization: Bearer <token>
```

Success response (200): `{ "status": "ok", "data": { "session": {...} },
"meta": { "warnings": [] } }` (same session object as §6.2).

Error: id not found → 404 `not_found`; invalid id → 400
`validation_error`.

### 6.4 `POST /api/v1/sessions/:id/disconnect` (kick)

```http
POST /api/v1/sessions/pppoe-agus/disconnect
Authorization: Bearer <token>
Content-Type: application/json

{ "reason": "2 months in arrears" }
```

- `reason` is **required** (string, 1–200 characters) — the kick reason
  is recorded in the syslog audit. Missing reason → 400
  `validation_error`.
- PPPoE: `titian-pppoe.sh disconnect <user> <framed-ip>` — closes the
  session via the mpd5 console (graceful LCP, Option A). IPoE:
  `titian-dhcp.sh kick-lease <mac>` — frees the lease; the user may
  reconnect (not a block). A full MAC block (`kick`) stays CLI /
  remote-kick only.
- After the backend succeeds, the API **verifies** the session is
  really gone from the list; if it is still there → 500
  `internal_error`.

Success response (200):

```json
{ "status": "ok",
  "data": { "session_id": "pppoe-agus", "type": "pppoe", "user": "agus",
            "ip": "10.99.42.101", "action": "disconnect",
            "reason": "2 months in arrears", "verified": true },
  "meta": {} }
```

### 6.5 `POST /api/v1/sessions/:id/isolate` (isolate)

```http
POST /api/v1/sessions/pppoe-agus/isolate
Authorization: Bearer <token>
Content-Type: application/json

{ "reason": "2 months in arrears" }
```

- `reason` required (as in §6.4).
- Requirements: `isolir-web` set in config (empty → 400
  `validation_error`), and the firewall **enabled** + pf **running**
  (otherwise → 400 `validation_error` — run `firewall enable` +
  commit in klish first).
- Effect: TWO pf dst-nat rules — `rdr proto tcp from <ip> to any port
  80 -> <isolir-web> port <port>` AND `rdr proto tcp from <ip> to any
  port 443 -> <isolir-web> port <port>` (both to the web server port).
  NO 443 blocking. Recorded in `/usr/local/etc/isolated.conf`
  (persistent across reboots — re-applied at boot via rc.d/firewall).
  **Dummynet is NOT touched** — the user's bandwidth capacity stays
  the package profile; isolation is not a small pipe.
- Consequence: an HTTPS client (TCP 443) redirected to the web server
  on port 80 receives a **plain HTTP response, not TLS** — the browser
  shows a certificate/connection error, not the neat isolir page.
  This is a consequence of the requested design (dst-nat 443 → 80),
  not a bug. HTTP (TCP 80) clients see the isolir page normally.
- Idempotent: isolating an already-isolated IP still returns 200.
- Verified: the IP is really in the isolated list, otherwise → 500.

Success response (200):

```json
{ "status": "ok",
  "data": { "session_id": "pppoe-agus", "type": "pppoe", "user": "agus",
            "ip": "10.99.42.101", "action": "isolate",
            "isolir_web": "103.50.129.84:80",
            "reason": "2 months in arrears", "verified": true },
  "meta": {} }
```

### 6.6 `POST /api/v1/sessions/:id/unisolate` (remove isolation)

```http
POST /api/v1/sessions/pppoe-agus/unisolate
Authorization: Bearer <token>
Content-Type: application/json

{ "reason": "paid" }
```

- `reason` required. Idempotent (an IP that is not isolated still
  returns 200, `was_isolated: false`). Verified: the IP is really
  gone from the isolated list.

Success response (200):

```json
{ "status": "ok",
  "data": { "session_id": "pppoe-agus", "type": "pppoe", "user": "agus",
            "ip": "10.99.42.101", "action": "unisolate",
            "reason": "paid", "was_isolated": true,
            "verified": true },
  "meta": {} }
```

### 6.7 `GET /api/v1/nas/status`

```http
GET /api/v1/nas/status
Authorization: Bearer <token>
```

Success response (200):

```json
{ "status": "ok",
  "data": {
    "bsdrp_version": "n314296", "titian_version": "0.1.1",
    "bird_variant": "BIRD 2", "bird_version": 2,
    "frr_version": "10.7.1 (not running)",
    "pppoe_enabled": true, "pppoe_interface": "ge1",
    "pf_enabled": true, "firewall_enabled": true,
    "sessions_pppoe": 12, "sessions_ipoe": 3, "sessions_total": 15,
    "isolated_count": 1, "isolir_web": "103.50.129.84:80",
    "time_utc": "2026-11-24T11:18:52Z"
  },
  "meta": { "warnings": [] } }
```


**D1 — system / config / checkpoints.**

### 6.8 `GET /api/v1/system/version` — version (Tier S)

Backend: the same `get_versions()` as `/health` (`pkg info titian` +
`titian-bird.sh show-version`).

Schema of `data`: `api_version` (string), `titian_version` (string|null),
`bsdrp_version` (string|null), `bird_variant` (string|null, e.g. `"BIRD 2"`),
`bird_version` (int|null), `frr_version` (string|null,
e.g. `"10.7.1 (not running)"`), `time_utc` (string, ISO 8601 UTC).

```http
GET /api/v1/system/version
```

```json
{"status": "ok", "data": {"api_version": "1.0.0", "titian_version": "0.1.1",
"bsdrp_version": "n314296", "bird_variant": "BIRD 2", "bird_version": 2,
"frr_version": "10.7.1 (not running)", "time_utc": "2026-11-25T05:00:00Z"},
"meta": {"warnings": []}}
```

Errors: no token → 401 `unauthorized`; wrong token → 403 `forbidden`.

### 6.9 `GET /api/v1/system` — system summary (Tier S)

Backend: `titian-sys.sh summary` (labels `Label......: value`, FreeBSD
or Linux). `time_utc` is filled by the daemon.

Schema of `data`: `hostname`, `os`, `kernel`, `kernel_build`, `architecture`,
`time_local`, `time_wib`, `uptime` (string as-is, e.g.
`"10 days, 3:12"`), `cpu` (string), `cpu_count` (int|null, from
`"(N CPU)"`), `memory_used_mb`/`memory_total_mb` (int|null),
`load_average` ([float ×3]|null), `disk_root` (`{used, total, use_percent}`|null,
from the `Disk (/)` line), `titian_cli`, `bird`, `time_utc`, `extra` (dict
label→value for labels that are not mapped).

```http
GET /api/v1/system
```

```json
{"status": "ok", "data": {"hostname": "titian-mock", "os": "FreeBSD 14.3-RELEASE",
"kernel": "14.3-RELEASE", "kernel_build": "FreeBSD 14.3-RELEASE releng/14.3-n314296",
"architecture": "amd64", "time_local": "Tue Nov 25 11:00:00 UTC 2026",
"time_wib": "Tue Nov 25 18:00:00 WIB 2026", "uptime": "10 days, 3:12",
"cpu": "Intel(R) Xeon(R) CPU E5-2699 v3 @ 2.30GHz (4 CPU)", "cpu_count": 4,
"memory_used_mb": 2048, "memory_total_mb": 8192,
"load_average": [0.1, 0.2, 0.3],
"disk_root": {"used": "1.2G", "total": "7.9G", "use_percent": 15},
"titian_cli": "klish 2.2.5 (tree /opt/titian/etc/clish-en)", "bird": "2.0.12",
"time_utc": "2026-11-25T05:00:00Z", "extra": {}},
"meta": {"warnings": []}}
```

Errors: backend failure → 500 `internal_error`.

### 6.10 `GET /api/v1/system/memory` — memory (Tier S)

Backend: `titian-sys.sh memory`. FreeBSD: `sysctl hw.physmem/hw.usermem`
(bytes) + `vmstat -s`; Linux: `free -h`.

Schema of `data`: `total_bytes`, `used_bytes`, `free_bytes`,
`available_bytes`, `shared_bytes`, `buffers_cache_bytes`,
`swap_total_bytes`, `swap_used_bytes`, `swap_free_bytes` (int|null),
`source` (`"freebsd"`|`"linux"`|`"unknown"`), `vmstat_lines` (list of raw
`vmstat -s` strings, FreeBSD only). FreeBSD: `used_bytes =
physmem - usermem`; `available_bytes = hw.usermem` (memory available
to user processes); `free_bytes` is null (there is no comparable free
number in this output).

```http
GET /api/v1/system/memory
```

```json
{"status": "ok", "data": {"total_bytes": 8589934592, "used_bytes": 2147483648,
"free_bytes": null, "available_bytes": 6442450944, "shared_bytes": null,
"buffers_cache_bytes": null, "swap_total_bytes": null, "swap_used_bytes": null,
"swap_free_bytes": null, "source": "freebsd",
"vmstat_lines": ["2097152 pages managed", "1500000 pages free", "100000 pages active"]},
"meta": {"warnings": []}}
```

### 6.11 `GET /api/v1/system/processes` — processes (Tier S, paginated)

Backend: `titian-sys.sh process` (FreeBSD `ps aux`, Linux `ps axf`).

Schema of each item: `user` (string|null — Linux `ps axf` carries no user),
`pid` (int), `cpu_percent`/`mem_percent` (float|null),
`vsz_kb`/`rss_kb` (int|null), `tty`, `state`, `started` (string|null),
`time` (string), `command` (string). Lines that fail to parse → `{"raw": ...}`.

```http
GET /api/v1/system/processes?limit=2&offset=0
```

```json
{"status": "ok", "data": {"processes": [
{"user": "root", "pid": 11, "cpu_percent": 0.0, "mem_percent": 0.1,
"vsz_kb": 13200, "rss_kb": 2400, "tty": "-", "state": "Is",
"started": "10Nov26", "time": "0:00.12", "command": "/sbin/init"},
{"user": "root", "pid": 123, "cpu_percent": 0.1, "mem_percent": 0.5,
"vsz_kb": 45000, "rss_kb": 8000, "tty": "-", "state": "Ss",
"started": "10Nov26", "time": "0:01.05",
"command": "/usr/local/sbin/bird -c /usr/local/etc/bird.conf"}]},
"meta": {"total": 3, "count": 2, "limit": 2, "offset": 0, "warnings": []}}
```

Errors: `?limit=0` / `?limit=2000` → 400 `validation_error`.

### 6.12 `GET /api/v1/system/connections` — connections (Tier S, paginated)

Backend: `titian-sys.sh connections` (FreeBSD `netstat -an`, Linux `ss -tunap`).

Schema of each item: `protocol` (e.g. `"tcp4"` / `ss` netid `"tcp"`), `state`
(string|null — UDP netstat has no state), `recv_q`/`send_q`
(int|null), `local_address`, `foreign_address`, `process` (string|null —
`ss` only). The "Active UNIX domain sockets" part of `netstat -an` is
deliberately not parsed (not internet connections).

```http
GET /api/v1/system/connections?limit=1&offset=1
```

```json
{"status": "ok", "data": {"connections": [
{"protocol": "tcp4", "recv_q": 0, "send_q": 0, "local_address": "*.8443",
"foreign_address": "*.*", "state": "LISTEN", "process": null}]},
"meta": {"total": 3, "count": 1, "limit": 1, "offset": 1, "warnings": []}}
```

### 6.13 `GET /api/v1/system/storage` — storage (Tier S, paginated)

Backend: NEW subcommand `titian-sys.sh storage` (D1, read-only, only
`df -h`): one line per filesystem, pipe-delimited, no header:
`filesystem|size|used|avail|use_pct|mounted_on`.

Schema of each item: `filesystem`, `size`, `used`, `available` (`df -h`
strings, e.g. `"7.9G"`), `use_percent` (int|null), `mounted_on`,
`size_bytes`/`used_bytes`/`available_bytes` (int|null, human-size → bytes
parse result; null when unparseable).

```http
GET /api/v1/system/storage
```

```json
{"status": "ok", "data": {"storage": [
{"filesystem": "zroot/ROOT/default", "size": "7.9G", "used": "1.2G",
"available": "6.7G", "use_percent": 15, "mounted_on": "/",
"size_bytes": 8482560409, "used_bytes": 1288490188, "available_bytes": 7194070220},
{"filesystem": "tmpfs", "size": "512M", "used": "148K", "available": "512M",
"use_percent": 1, "mounted_on": "/tmp", "size_bytes": 536870912,
"used_bytes": 151552, "available_bytes": 536870912}]},
"meta": {"total": 2, "count": 2, "limit": 100, "offset": 0, "warnings": []}}
```

### 6.14 `GET /api/v1/system/sysctl` — Titian-managed sysctl (Tier S, paginated)

Backend: `titian-sysctl.sh show`: per key
`"  key = live  (tersimpan: saved)"` + a `"    arti: ..."` line.
Empty state → empty list (200), not 404.

Schema of each item: `key`, `value_live`, `value_saved` (strings — vector
values with spaces such as `"4096 87380 6291456"` stay strings), `meaning`
(string|null). Lines that fail to parse → `{"key": null, ..., "raw": ...}`.

```http
GET /api/v1/system/sysctl
```

```json
{"status": "ok", "data": {"sysctl": [
{"key": "net.inet.ip.forwarding", "value_live": "1", "value_saved": "1",
"meaning": "router wajib 1: kernel meneruskan paket antar interface; 0 = host biasa (endpoint)."},
{"key": "net.inet.tcp.sendbuf_max", "value_live": "262144", "value_saved": "262144",
"meaning": "buffer TCP maksimum FreeBSD; naikkan untuk sesi throughput tinggi/latensi tinggi."}]},
"meta": {"total": 2, "count": 2, "limit": 100, "offset": 0, "warnings": []}}
```

### 6.15 `GET /api/v1/system/logins` — active logins (Tier S, paginated)

Backend: `w -h` as a direct argv (a system read command, no arguments
from the web). Columns: `USER TTY FROM LOGIN@ IDLE JCPU PCPU WHAT`
(`WHAT` may be empty). Best-effort parse; lines that fail to parse →
`{"raw": ...}` + warning.

Schema of each item: `user`, `tty`, `from`, `login`, `idle`, `jcpu`, `pcpu`,
`what` (string|null).

```http
GET /api/v1/system/logins
```

```json
{"status": "ok", "data": {"logins": [
{"user": "agoes", "tty": "pts/0", "from": "10.99.42.50", "login": "11:00",
"idle": "0.00s", "jcpu": "0.01s", "pcpu": "0.00s", "what": "/usr/local/bin/clish"},
{"user": "root", "tty": "pts/1", "from": "-", "login": "10:30",
"idle": "5:00", "jcpu": "0.02s", "pcpu": "0.01s", "what": "-"},
{"raw": "garbage-line"}]},
"meta": {"total": 3, "count": 3, "limit": 100, "offset": 0,
"warnings": ["baris w tidak bisa di-parse: garbage-line"]}}
```

### 6.16 `GET /api/v1/system/hardware` — hardware (Tier T)

Backend: `titian-sys.sh cpu` + `dmi` + `pci` (3 sections). Each section:
`text` (raw string), `lines` (int), `truncated` (bool, 2000-line cap),
`lines_total` (int), `error` (string|null). One section failing → that
section carries `error` + `meta.warnings`, the other sections are still
returned (200). All three sections failing → 500 `internal_error`.

```http
GET /api/v1/system/hardware
```

```json
{"status": "ok", "data": {"sections": {
"cpu": {"text": "hw.model: Intel(R) Xeon(R) CPU E5-2699 v3 @ 2.30GHz\nhw.ncpu: 4\nhw.machine: amd64\n",
"lines": 3, "truncated": false, "lines_total": 3, "error": null},
"dmi": {"text": "# dmidecode 3.4\nSystem Information\n\tManufacturer: QEMU\n\tProduct Name: Standard PC\n",
"lines": 4, "truncated": false, "lines_total": 4, "error": null},
"pci": {"text": "hostb0@pci0:0:0:0:\tclass=0x060000 rev=0x00 hdr=0x00 vendor=0x8086 device=0x1237\n",
"lines": 1, "truncated": false, "lines_total": 1, "error": null}},
"source": "show hardware cpu/dmi/pci"},
"meta": {"warnings": []}}
```

### 6.17 `GET /api/v1/services` — service list (Tier S, paginated)

Backend: `titian-sys.sh services`. FreeBSD: `service -e` (one rc path
per line → `status: "enabled"`). Linux: `service --status-all`
(`[ + ]` → `"running"`, `[ - ]` → `"stopped"`, `[ ? ]` → `"unknown"`).
Sorted by name.

Schema of each item: `name`, `status` (`"enabled"`|`"running"`|`"stopped"`|
`"unknown"`|null), `raw` (the original line).

```http
GET /api/v1/services?limit=1
```

```json
{"status": "ok", "data": {"services": [
{"name": "bird", "status": "enabled", "raw": "/etc/rc.d/bird"}]},
"meta": {"total": 3, "count": 1, "limit": 1, "offset": 0, "warnings": []}}
```

### 6.18 `GET /api/v1/services/:name` — one service status (Tier S)

Backend: `titian-sys.sh service-status <name>`. The name is validated
against `^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$` (anything else → 400
`validation_error`). The status is read from the text: containing
`"not running"` / `"stop/waiting"` → `"stopped"`; `"is running"` /
`"start/running"` / `"active (running)"` → `"running"`; otherwise
`"unknown"`. FreeBSD: `service X status` exits rc 1 when the service is
stopped — that is still 200 `"stopped"`, not an error. Unknown service
(text `"does not exist"` / `"unknown service"` / `"not found"` /
`"no such"`) → 404 `not_found`.

Schema of `data`: `name`, `status`, `text` (raw backend output),
`lines` (int).

```http
GET /api/v1/services/sshd
```

```json
{"status": "ok", "data": {"name": "sshd", "status": "running",
"text": "sshd is running as pid 123.", "lines": 1}, "meta": {}}
```

```http
GET /api/v1/services/nosuchsvc
```

```json
{"status": "error", "data": null,
"error": {"code": "not_found", "message": "service tidak dikenal: nosuchsvc"}}
```

### 6.19 `GET /api/v1/services/ssh` — SSH service state (Tier S)

Backend: `titian-sys.sh service-ssh` (reads `/etc/ssh/sshd_config`, last
uncommented line wins + sshd process status). When sshd is not
installed → 200 `{"available": false, "reason": ...}` (not 500).

Schema of `data`: `name` (`"ssh"`), `sshd_running` (bool|null),
`sshd_pid` (int|null), `port` (int|null), `permit_root_login`
(string|null), `use_dns` (string|null), `listen` (list of strings, e.g.
`["0.0.0.0:22", "[::]:22"]`).

```http
GET /api/v1/services/ssh
```

```json
{"status": "ok", "data": {"name": "ssh", "sshd_running": true, "sshd_pid": 123,
"port": 22, "permit_root_login": "prohibit-password", "use_dns": "no",
"listen": ["0.0.0.0:22", "[::]:22"]}, "meta": {"warnings": []}}
```

### 6.20 `GET /api/v1/config/running` — running-config (Tier T, redaction mandatory)

Backend: `titian-checkpoint.sh dump-running <tmpfile>` — NOT
`titian-show-config.sh running`, because that script only cats the dump
file `/tmp/titian-show-run.conf` written by the klish `<CONFIG
operation="dump">` in the `show running-config` ACTION; from the API that
file is stale/empty. `dump-running` is the same read path as
`checkpoint save` (konf dump → batch clish `show running-config` →
startup-config fallback); verified read-only from the
`titian-checkpoint.sh` source (it only writes to the tmp file the daemon
passes). Note: this dump drops stamp lines (`! version` / `! last commit`)
and ensures the `end` terminator — same as a checkpoint. When the live
dump fails and falls back to startup-config, `meta.warnings` carries that
warning.

Redaction MANDATORY: every line matching `/password|secret|token|passwd/i`
is replaced with `# <redacted>` BEFORE entering the response. Cap 5000 lines
(`meta.truncated` + `meta.lines_total` when truncated).

Schema of `data`: `config_text` (string), `lines` (int),
`source` (`"show running-config"`). Extra meta: `redacted_lines` (int).

```http
GET /api/v1/config/running
```

```json
{"status": "ok", "data": {"config_text": "!\ninterface vlan 101 vtnet0\n  description uplink\n# <redacted>\n  exit\n# <redacted>\nend",
"lines": 7, "source": "show running-config"},
"meta": {"warnings": [], "truncated": false, "lines_total": 7, "redacted_lines": 2}}
```

### 6.21 `GET /api/v1/config/startup` — startup-config (Tier T, redaction mandatory)

Backend: `titian-show-config.sh startup no-more` (cats
`$TITIAN_STATE_ROOT/startup-config` through the pager; non-TTY → cat).
Redaction + cap as in §6.20. When the file does not exist yet, the backend
returns the message `(startup-config kosong — ...)` with rc 0 (200, not 404).

Schema of `data`: `config_text`, `lines`, `source` (`"show startup-config"`).
Extra meta: `redacted_lines`.

```http
GET /api/v1/config/startup
```

```json
{"status": "ok", "data": {"config_text": "! version 0.1.1\n! last commit: 2026-11-24 10:00:00 WIB\n!\nhostname titian-mock\ninterface vlan 101 vtnet0\n  description uplink\n# <redacted>\n  exit\nend",
"lines": 9, "source": "show startup-config"},
"meta": {"warnings": [], "truncated": false, "lines_total": 9, "redacted_lines": 1}}
```

### 6.22 `GET /api/v1/checkpoints` — checkpoint list (Tier S, paginated)

Backend: `titian-checkpoint.sh list` (header `Name  DIBUAT (WIB)  SAAT INI`,
lines `nama  YYYY-MM-DD HH:MM:SS WIB  [*]`; `*` = the point content is
exactly equal to the current running-config; footer `* = ...`). No
checkpoints yet → empty list (200). A name without meta → `created_wib: null`.

Schema of each item: `name`, `created_wib` (string `"YYYY-MM-DD HH:MM:SS WIB"`|null),
`current` (bool). Lines that fail to parse → `{"name": null, "created_wib": null,
"current": false, "raw": ...}` + warning.

```http
GET /api/v1/checkpoints
```

```json
{"status": "ok", "data": {"checkpoints": [
{"name": "alpha", "created_wib": "2026-11-24 10:00:00 WIB", "current": true},
{"name": "beta", "created_wib": "2026-11-24 11:00:00 WIB", "current": false}]},
"meta": {"total": 2, "count": 2, "limit": 100, "offset": 0, "warnings": []}}
```

**Not exposed by D1.**

`show date` (`time_utc` already in health + §6.8/§6.9), `show pwd`,
`show history`, `show help` (local CLI), `show system top` (transient
screen), `show configuration` (only prints the bird.conf path).

**`check` changes + new backend.**

- `titian-api.py check` now also verifies `titian-sys.sh`,
  `titian-sysctl.sh`, `titian-checkpoint.sh`, `titian-show-config.sh`
  and the `w` tool.
- New backend subcommand (the only one): `titian-sys.sh storage`
  (format in §6.13; read-only, only `df -h`).


**D2 — interfaces / IP / routes.**

### 6.23 `GET /api/v1/interfaces`

```http
GET /api/v1/interfaces
GET /api/v1/interfaces?terse=true
GET /api/v1/interfaces?limit=2&offset=4
Authorization: Bearer <token>
```

Query:

| Param | Default | Meaning |
|---|---|---|
| `terse` | `false` | `true` = the `titian-show.sh terse` table (admin/link per interface); `false` = the `titian-show.sh interfaces` table |
| `include_down` | `false` | accepted but a no-op: the list ALWAYS contains up+down interfaces |
| `limit` | `100` | 1–1000 |
| `offset` | `0` | >= 0 |

Backend: `titian-show.sh interfaces` (FreeBSD: `ifconfig -a`; Linux:
`ip -o addr`). The CLI `terse`/`all` variants are presentations of the
same data: `terse` is exposed via `?terse=true`; `all` (per-interface
detail block) is NOT exposed — use `GET /api/v1/interfaces/:name`.

One interface (object):

| Field | Type | Meaning |
|---|---|---|
| `name` | string | interface name (`ge1`, `bridge0`, `vxlan100`, `lo0`) |
| `state` | string\|null | `up` \| `down` \| `loopback` |
| `state_code` | string\|null | CLI code: `u` \| `D` \| `L` |
| `admin` | string\|null | `up` \| `disabled` (terse mode only; default `null`) |
| `link` | string\|null | `up` \| `down` (terse mode only; default `null`) |
| `addresses` | array | addresses (see below; continuation addresses from an empty-name line are merged into the same interface) |
| `description` | string\|null | interface description (Description column; terse: `null`) |
| `raw` | string | only when a line fails to parse (with `meta.warnings`) |

One address (object in `addresses`):

| Field | Type | Meaning |
|---|---|---|
| `address` | string | IP address (no prefix; the `%iface` zone is split into `zone`) |
| `prefix_length` | int\|null | prefix length (`/64` etc.); `null` when the table does not carry it (FreeBSD IPv4 inet is printed without a prefix) |
| `family` | string\|null | `ipv4` \| `ipv6` |
| `peer` | string\|null | PtP peer (`inet A peer B`) |
| `zone` | string\|null | link-local zone (`fe80::1%vxlan100` → `vxlan100`) |

Success response (200):

```json
{ "status": "ok",
  "data": { "interfaces": [
    { "name": "ge1", "state": "up", "state_code": "u",
      "admin": null, "link": null,
      "addresses": [
        { "address": "10.10.2.6", "prefix_length": null,
          "family": "ipv4", "peer": null, "zone": null },
        { "address": "2001:db8::6", "prefix_length": 64,
          "family": "ipv6", "peer": null, "zone": null } ],
      "description": "uplink" },
    { "name": "em0", "state": "down", "state_code": "D",
      "admin": null, "link": null, "addresses": [],
      "description": null }
  ] },
  "meta": { "total": 5, "count": 2, "terse": false,
            "limit": 2, "offset": 0, "warnings": [] } }
```

Errors: `terse` not a boolean → 400 `validation_error`.

### 6.24 `GET /api/v1/interfaces/:name`

```http
GET /api/v1/interfaces/ge1
GET /api/v1/interfaces/ge1?detail=true
Authorization: Bearer <token>
```

Backend: `titian-show.sh if-detail <iface> [detail]` (FreeBSD:
`ifconfig <iface>`; Linux: `ip -d link show` + `ip -d addr show`).
`?detail=true` forwards the CLI `detail` argument (FreeBSD: hardware
notes unavailable, only a message; Linux: `ethtool` + `udevadm` when
present).

One interface (object `data.interface`):

| Field | Type | Meaning |
|---|---|---|
| `name` | string | interface name |
| `state` | string | `up` \| `down` \| `loopback` |
| `state_code` | string | `u` \| `D` \| `L` |
| `admin` | string | `up` (UP flag) \| `disabled` |
| `link` | string\|null | `up` \| `down`; `null` when it cannot be determined (no `status:` line and no RUNNING/LOWER_UP flag) |
| `mtu` | int\|null | MTU |
| `mac` | string\|null | ether address (`link/ether` / `ether`) |
| `flags` | array | flag list (`UP`, `BROADCAST`, `RUNNING`, …) |
| `addresses` | array | addresses (same schema as §6.23; `prefix_length` filled from hex `netmask` / `prefixlen` / `/N`) |
| `description` | string\|null | the `description:` line |
| `media` | string\|null | the `media:` line (FreeBSD) |
| `status` | string\|null | the `status:` line (`active`, …) |
| `options` | string\|null | the `options=<...>` line (FreeBSD) |
| `groups` | array | the `groups:` line |
| `extra_lines` | array | other ifconfig/ip lines that were not parsed (information, not an error) |

Success response (200):

```json
{ "status": "ok",
  "data": { "interface": {
    "name": "ge1", "state": "up", "state_code": "u",
    "admin": "up", "link": "up", "mtu": 1500,
    "mac": "52:54:00:12:34:56",
    "flags": ["UP", "BROADCAST", "RUNNING", "SIMPLEX",
              "MULTICAST", "LOWER_UP"],
    "addresses": [
      { "address": "10.10.2.6", "prefix_length": 24,
        "family": "ipv4", "peer": null, "zone": null } ],
    "description": "uplink", "media": "Ethernet autoselect (1000baseT <full-duplex>)",
    "status": "active", "options": "800b8<VLAN_MTU,VLAN_HWTAGGING,JUMBO_MTU,VLAN_HWCSUM,LINKSTATE>",
    "groups": ["uplink"], "extra_lines": ["nd6 options=29<PERFORMNUD,IFDISABLED,AUTO_LINKLOCAL>"]
  } },
  "meta": { "warnings": [] } }
```

Errors: interface missing → 404 `not_found`; name not matching
`^[A-Za-z0-9_.-]{1,32}$` → 400 `validation_error`.

### 6.25 `GET /api/v1/interfaces/:name/tuning` (Tier T)

```http
GET /api/v1/interfaces/ge1/tuning
Authorization: Bearer <token>
```

Backend: `titian-tune.sh show <iface>` (read-only: reads live values +
the `.tuning` file). Tier T — text as-is, because the content is an
explanation per knob (mtu, qlen, offload, coalesce), not records.

Success response (200):

```json
{ "status": "ok",
  "data": { "interface": "ge1",
            "config_text": "Tuning ge1 (FreeBSD) — value live + arti singkat\n  mtu*: 9000 — ...\n",
            "lines": 10,
            "source": "show interfaces tuning ge1" },
  "meta": { "warnings": [] } }
```

Errors: interface missing → 404 `not_found`; invalid name → 400
`validation_error`.

### 6.26 `GET /api/v1/neighbors`

```http
GET /api/v1/neighbors
GET /api/v1/neighbors?interface=ge1
Authorization: Bearer <token>
```

Query:

| Param | Default | Meaning |
|---|---|---|
| `interface` | — | exact-match filter on the interface name (validated against `^[A-Za-z0-9_.-]{1,32}$`) |
| `limit` / `offset` | `100` / `0` | pagination |

Backend: `titian-show.sh neighbor` (FreeBSD: `arp -a`; Linux:
`ip -d neighbor show`). Filtering is done in the daemon (exact match):
the FreeBSD backend filters with `grep -F` (substring), so it is not
used for filtering.

One neighbor (object):

| Field | Type | Meaning |
|---|---|---|
| `ip` | string\|null | neighbor IP address |
| `mac` | string\|null | MAC (`null` for `(incomplete)` / FAILED without lladdr) |
| `interface` | string\|null | interface |
| `state` | string\|null | FreeBSD: `complete` \| `incomplete`; Linux: `reachable` \| `stale` \| `delay` \| `probe` \| `failed` \| `incomplete` \| `permanent` \| `noarp` |
| `expires_seconds` | int\|null | remaining ARP entry lifetime (FreeBSD only; Linux `null`) |
| `family` | string\|null | `ipv4` \| `ipv6` |
| `raw` | string | only when a line fails to parse |

Success response (200):

```json
{ "status": "ok",
  "data": { "neighbors": [
    { "ip": "10.10.2.1", "mac": "52:54:00:ab:cd:ef",
      "interface": "ge1", "state": "complete",
      "expires_seconds": 1149, "family": "ipv4" },
    { "ip": "10.99.44.2", "mac": null, "interface": "bridge0",
      "state": "incomplete", "expires_seconds": 0, "family": "ipv4" }
  ] },
  "meta": { "total": 3, "count": 2, "limit": 100, "offset": 0,
            "warnings": [] } }
```

Errors: invalid `interface` → 400 `validation_error`. A filter that
matches nothing = 200 + empty list (not 404).

### 6.27 `GET /api/v1/bridges`

```http
GET /api/v1/bridges
GET /api/v1/bridges?bridge=bridge0
Authorization: Bearer <token>
```

Query:

| Param | Default | Meaning |
|---|---|---|
| `bridge` | — | bridge name `bridge[N]` (e.g. `bridge0`); without the parameter = all bridges |
| `limit` / `offset` | `100` / `0` | pagination |

Backend: `titian-bridge.sh show [bridge]` (read-only: `ifconfig`).

One bridge (object):

| Field | Type | Meaning |
|---|---|---|
| `name` | string | bridge name |
| `flags` | string\|null | contents of the `flags=...` line |
| `mac` | string\|null | bridge ether address |
| `addresses` | array | `inet`/`inet6` addresses (§6.23 schema) |
| `members` | array | members: `{ "interface": string, "flags": string }` |
| `unparsed_lines` | array | unrecognized block lines (when present) |

Success response (200):

```json
{ "status": "ok",
  "data": { "bridges": [
    { "name": "bridge0",
      "flags": "1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500",
      "mac": "58:9c:fc:00:11:22",
      "addresses": [
        { "address": "10.99.44.254", "prefix_length": 24,
          "family": "ipv4", "peer": null, "zone": null } ],
      "members": [
        { "interface": "vxlan100",
          "flags": "143<LEARNING,DISCOVER,AUTOEDGE,AUTOPTP>" },
        { "interface": "vlan100",
          "flags": "143<LEARNING,DISCOVER,AUTOEDGE,AUTOPTP>" } ]
    } ] },
  "meta": { "total": 2, "count": 1, "limit": 100, "offset": 0,
            "warnings": [] } }
```

Errors: bridge missing → 404 `not_found`; `?bridge=` not
`bridge[N]` → 400 `validation_error`. No bridges at all = 200 +
empty list.

### 6.28 `GET /api/v1/vxlan`

```http
GET /api/v1/vxlan
Authorization: Bearer <token>
```

Backend: `titian-vxlan.sh show` (read-only: `ifconfig`/`ip` +
`sysctl` FDB). Object schema as in §6.29. No vxlan interfaces
= 200 + empty list.

### 6.29 `GET /api/v1/vxlan/:name`

```http
GET /api/v1/vxlan/vxlan100
Authorization: Bearer <token>
```

Backend: `titian-vxlan.sh show <name>`.

One vxlan (object `data.vxlan`):

| Field | Type | Meaning |
|---|---|---|
| `name` | string | interface name (`vxlan100`) |
| `state` | string | `up` \| `down` |
| `mtu` | int\|null | MTU |
| `vni` | int\|null | VNI (`null` for `?`) |
| `local` | string\|null | local VTEP address (`null` for `?`/unset) |
| `remote` | string\|null | unicast peer (`null` in group mode / no peer) |
| `group` | string\|null | multicast group address (`null` in unicast mode) |
| `dev` | string\|null | underlay interface (group mode, Linux only) |
| `dstport` | int\|null | UDP dstport (FreeBSD always 4789) |
| `addresses` | array | `inet`/`inet6` addresses (§6.23 schema) |
| `fdb` | array | raw FDB entries (one string per line; `[]` for `(kosong)`) |
| `unparsed_lines` | array | unrecognized block lines (when present) |

Success response (200):

```json
{ "status": "ok",
  "data": { "vxlan": {
    "name": "vxlan100", "state": "up", "mtu": 1500, "vni": 100,
    "local": "10.10.2.6", "remote": "10.10.2.5",
    "group": null, "dev": null, "dstport": 4789,
    "addresses": [
      { "address": "10.99.44.1", "prefix_length": 24,
        "family": "ipv4", "peer": null, "zone": null } ],
    "fdb": ["0x00000001 52:54:00:11:22:33"]
  } },
  "meta": { "warnings": [] } }
```

Errors: vxlan missing → 404 `not_found`; name not `vxlan[N]` → 400
`validation_error`.

### 6.30 `GET /api/v1/routes`

```http
GET /api/v1/routes
GET /api/v1/routes?family=ipv6&prefix=2001:db8::/32
Authorization: Bearer <token>
```

Query:

| Param | Default | Meaning |
|---|---|---|
| `family` | `ipv4` | `ipv4` \| `ipv6` |
| `prefix` | — | IP or CIDR; the prefix family MUST match `family` |
| `limit` / `offset` | `100` / `0` | pagination |

Backend: `titian-show.sh route [prefix]` / `route6 [prefix]`
(FreeBSD: `netstat -rn -f inet|inet6`, grepped when a prefix is given;
Linux: `ip route show [prefix]`). Note: on FreeBSD, `route
<prefix>` returns ONLY the matching lines (no header) — the daemon
parser detects the format from the line shape, not the header.
A prefix that matches nothing = 200 + empty list (not 404).

One route (object; ALL keys always present, `null` when absent from
the source):

| Field | Type | Meaning |
|---|---|---|
| `destination` | string | destination prefix (`default`, `10.10.2.0/24`, `2001:db8::/32`) |
| `gateway` | string\|null | nexthop (FreeBSD: `link#N` for directly connected routes; Linux: the `via` value) |
| `flags` | string\|null | netstat flags (`UGS`, `U`, `UH` — FreeBSD only) |
| `interface` | string\|null | egress interface |
| `expire_seconds` | int\|null | netstat Expire column (FreeBSD only) |
| `family` | string | `ipv4` \| `ipv6` |
| `protocol` | string\|null | `proto` (Linux only: `kernel`, `static`, `bird`, …) |
| `metric` | int\|null | metric (Linux only) |
| `scope` | string\|null | scope (Linux only) |
| `src` | string\|null | `src` (Linux only) |
| `type` | string | `unicast` (default) \| `local` \| `blackhole` \| `unreachable` \| `prohibit` \| `broadcast` \| `throw` (Linux) |
| `link_down` | bool | `linkdown` (Linux only) |
| `onlink` | bool | `onlink` (Linux only) |

Success response (200):

```json
{ "status": "ok",
  "data": { "routes": [
    { "destination": "default", "gateway": "10.10.2.1",
      "flags": "UGS", "interface": "em0", "expire_seconds": null,
      "family": "ipv4", "protocol": null, "metric": null,
      "scope": null, "src": null, "type": "unicast",
      "link_down": false, "onlink": false }
  ], "family": "ipv4" },
  "meta": { "total": 5, "count": 1, "limit": 100, "offset": 0,
            "warnings": [] } }
```

Errors: `family` not `ipv4|ipv6` → 400; `prefix` not a valid IP/CIDR
→ 400; prefix family ≠ `family` → 400 `validation_error`.

### 6.31 `GET /api/v1/routing` (Tier T)

```http
GET /api/v1/routing
Authorization: Bearer <token>
```

Backend: `titian-bird.sh show-routing` (read-only: BIRD vs FRR daemon
status). Tier T — two status lines, not records.

Success response (200):

```json
{ "status": "ok",
  "data": { "config_text": "Routing daemon: BIRD 2.20.0 (bird2, enabled, running, pid 123)\nFRR: 10.7.1 (no, not running)\n",
            "lines": 2,
            "source": "show routing" },
  "meta": { "warnings": [] } }
```

Even with BIRD not installed it is still 200 (the text states
`BIRD not installed`).

### 6.32 `GET /api/v1/routing/static` (Tier T)

```http
GET /api/v1/routing/static
Authorization: Bearer <token>
```

Backend: `titian-static.sh show` (read-only: the `static.conf`
intent + the `bird.d/static.conf` section + `birdc show protocol
static`). Tier T — three text sections; do NOT mix with kernel routes
(`GET /api/v1/routes`): BIRD static routes live in the BIRD routing
table and only reach the kernel when the kernel channel exports them.

Success response (200):

```json
{ "status": "ok",
  "data": { "config_text": "--- static.conf (intent) ---\ncheck-link on\nroute 10.99.44.0/24 via 10.10.2.1\nroute 203.0.113.0/24 blackhole\n--- bird.d/static.conf (section, bila ada) ---\nprotocol static static4 {\n    check link;\n    ipv4;\n    route 10.99.44.0/24 via 10.10.2.1;\n    route 203.0.113.0/24 blackhole;\n}\n--- birdc show protocol static ---\nName       Proto      Table      State  Since         Info\nstatic4    Static     master4    up     2026-11-24\n",
            "lines": 15,
            "source": "show static" },
  "meta": { "warnings": [] } }
```

### D2 notes (not exposed)

- `show interfaces all` — per-interface detail blocks; covered by
  `GET /api/v1/interfaces/:name`.
- `show interfaces bird` / `show interfaces bird summary` — domain D3
  (`GET /api/v1/bird/interfaces`).
- `show interfaces ethernet|vlan|lagg <iface>` — aliases of if-detail;
  covered by `GET /api/v1/interfaces/:name`.
- `show route` (BIRD) — domain D3 (`GET /api/v1/bird/routes`), not
  kernel routes (`GET /api/v1/routes`).

### Assumptions needing guest verification (coordinator, bhyve)

1. The `titian-show.sh interfaces`/`terse` table format — parsed from
   the script source (fixed-width printf + awk ifconfig); not yet tested
   against a real `ifconfig -a`. Main risk: long IPv6 addresses
   (>19 columns) shifting columns — the parser uses tokens, not column
   positions, so it is safe against that shift.
2. The FreeBSD `arp -a` and `netstat -rn` formats — parsed from the
   standard formats of both commands; not tested live yet.
3. FreeBSD `titian-vxlan.sh show` FDB lines (`sysctl
   net.link.vxlan.N.ftable.dump`) — the exact format is not yet known;
   the parser treats each FDB line as a raw string.
4. The Linux parser branches (`ip route`, `ip neigh`, `ip -d link`) —
   unit-tested directly on the parser functions (mock test §17b), NOT
   over HTTP; on the BSDRP guest the FreeBSD branch is the one running.


**D3 — BIRD / routing-protocols.**

**D3 contract.** Envelope, snake_case, pagination, the 2000-line cap, and `raw`+`warnings` are as in §5. D3-specific: a down subsystem (BIRD down / FRR down) → HTTP 200 with `{"available": false, "reason": "..."}` — NOT 500. An empty list = 200 with an empty list.

**BIRD — BGP.**

### 6.33 `GET /api/v1/bird/bgp` — Tier T

CLI: `show bgp`. Backend: `titian-bgp.sh show` (prints the `bgp.conf`
intent).

Success example: the Tier T shape above, `"source": "show bgp"`.

### 6.34 `GET /api/v1/bird/bgp/summary` — Tier S

CLI: `show bgp summary`. Backend: `titian-birdc.sh show-bgp-summary`
(a klish COMPOSITION — NOT a real birdc command; BIRD has no
`show bgp summary`. Per neighbor from the `bgp.conf` intent:
`birdc show protocols all <proto>` + `birdc show route protocol
<proto> count`).

Schema of `data.neighbors[]`:

| Field | Type | Meaning |
|---|---|---|
| `neighbor` | string | neighbor IP |
| `protocol` | string | BIRD protocol name |
| `state` | string\|null | protocol state (`up`, …) |
| `since` | string\|null | since when (birdc) |
| `info` | string\|null | birdc info (`Established`, …) |
| `routes` | int\|null | route count from `show route protocol <proto> count` |
| `routes_total` | int\|null | total routes (the "of N" column) |
| `networks` | int\|null | network count |

Example:

```json
{"status": "ok",
 "data": {"available": true,
          "neighbors": [{"neighbor": "203.0.113.1",
                         "protocol": "bgp_203_0_113_1", "state": "up",
                         "since": "2026-11-24 09:05:00",
                         "info": "Established",
                         "routes": 5, "routes_total": 5, "networks": 5}]},
 "meta": {"total": 1, "count": 1, "limit": 100, "offset": 0, "warnings": []}}
```

No BGP neighbor in `bgp.conf` yet → 200 + `"neighbors": []`.

**BIRD — protokol.**

### 6.35 `GET /api/v1/bird/protocols` — Tier S

CLI: `show protocols` (+`all`). Backend: `titian-birdc.sh
show-protocols` / `show-protocols-all`. Query: `?all=true`
(per-protocol detail), pagination.

Schema of `data.protocols[]`:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | protocol name |
| `protocol` | string | type (`BGP`, `OSPF`, `Device`, `Kernel`, …) |
| `table` | string | table (`---` when none) |
| `state` | string | state (`up`, `down`, …) |
| `since` | string\|null | since when |
| `info` | string | birdc info |
| `details` | string[] | (only `?all=true`) indented detail lines |
| `raw` | string | (only when a line fails to parse) the line as-is |

Example:

```json
{"status": "ok",
 "data": {"available": true, "all": false,
          "protocols": [{"name": "bgp_203_0_113_1", "protocol": "BGP",
                         "table": "---", "state": "up",
                         "since": "2026-11-24 09:05:00",
                         "info": "Established"}]},
 "meta": {"total": 4, "count": 4, "limit": 100, "offset": 0, "warnings": []}}
```

### 6.36 `GET /api/v1/bird/protocols/summary` — Tier S

CLI: `show protocol summary`. Backend: `titian-birdc.sh show-protocols`
(no arguments — the existing `show-protocols` subcommand; NO new
backend subcommand). Returns the same list as
`/bird/protocols` + counts.

Schema of `data`: `{"available": true, "protocols": [...],
"counts": {"total": 4, "by_state": {"up": 4},
"by_protocol": {"BGP": 1, "OSPF": 1, "Device": 1, "Kernel": 1}}}`.

### 6.37 `GET /api/v1/bird/protocols/:name` — Tier S

CLI: `show protocol neighbors`. Backend: `titian-birdc.sh
show-protocols <name>`. `:name` must be `[A-Za-z0-9_]{1,64}`.

Schema of `data.protocol`: the protocol-table fields above +

| Field | Type | Meaning |
|---|---|---|
| `details` | object | detail lines `Key: value` → `snake_case` (e.g. `bgp_state`, `neighbor_address`, `neighbor_as`, `local_as`) |
| `channels` | object | per channel (`ipv4`, …): `state`, `table`, `preference`, `input_filter`, `output_filter`, `routes` (string as-is, e.g. `"5 imported, 0 exported, 5 preferred"`) |
| `detail_lines` | string[] | other detail lines that are not `Key: value` (when present) |

Example (shortened):

```json
{"status": "ok",
 "data": {"available": true,
          "protocol": {"name": "bgp_203_0_113_1", "protocol": "BGP",
                       "table": "---", "state": "up",
                       "since": "2026-11-24 09:05:00",
                       "info": "Established",
                       "details": {"bgp_state": "Established",
                                   "neighbor_address": "203.0.113.1",
                                   "neighbor_as": "65001",
                                   "local_as": "65000"},
                       "channels": {"ipv4": {"state": "UP",
                                             "table": "master4",
                                             "preference": "100",
                                             "input_filter": "ACCEPT",
                                             "output_filter": "REJECT",
                                             "routes": "5 imported, 0 exported, 5 preferred"}}}},
 "meta": {"warnings": []}}
```

Errors: protocol missing → 404 `not_found`; invalid name → 400
`validation_error`; BIRD not running → 200 `{"available": false,
"reason": "BIRD tidak jalan", "protocol": null}`.

**BIRD — rute.**

### 6.38 `GET /api/v1/bird/routes` — Tier S

CLI: `show route` (+ variants). Backend: `titian-birdc.sh show-route*`
(30-second timeout). Query:

| Query | Meaning |
|---|---|
| `?table=<name\|all>` | `show route table <name>` |
| `?protocol=<name>` | `show route protocol <name>` |
| `?prefix=<IP/prefix>` | `show route for <prefix>` (IPv4/IPv6, `ipaddress` validation) |
| `?view=export\|import\|preexport\|noexport\|primary\|filtered` | see below |
| `?where=<condition>` | `show route where <condition>`; charset `[A-Za-z0-9_ .=<>!&|()"']`, max 200 characters |
| `?all=true` | `show route all` |
| `?count_only=true` | counts only (see below) |
| pagination | `?limit=` / `?offset=` |

Precedence — exactly ONE subcommand is used:
`prefix` > `where` > `view` > `protocol` > `table` > `all` > default
(`show route`).

`view`:
- `export` / `preexport` / `noexport` — `?protocol=<protocol-name>` is
  REQUIRED (without it → 400).
- `import` — `?protocol=<PROTO.CHANNEL>` is REQUIRED (e.g.
  `bgp_203_0_113_1.ipv4`; without a `.` → 400).
- `primary` / `filtered` — no protocol.

Schema of `data.routes[]`:

| Field | Type | Meaning |
|---|---|---|
| `prefix` | string | route prefix |
| `type` | string | type (`unicast`, …) |
| `protocol` | string\|null | source protocol |
| `updated` | string\|null | update time (the bracketed content after the protocol) |
| `preferred` | bool | has a `*` mark |
| `preference` | int | number in `(…)` |
| `attributes` | string\|null | attribute brackets (`[AS65001i]`) |
| `flags` | string\|null | rest of the line |
| `table` | string\|null | active table (`Table X:`) |
| `details` | string[] | indented continuation lines (`via …`, `dev …`) |
| `raw` | string | (only when a line fails to parse) |

Example:

```json
{"status": "ok",
 "data": {"available": true,
          "routes": [{"prefix": "10.99.42.0/24", "type": "unicast",
                      "protocol": "static1", "updated": "2026-11-24",
                      "preferred": true, "preference": 200,
                      "attributes": null, "flags": null,
                      "table": "master4", "details": ["dev lo"]},
                     {"prefix": "203.0.113.0/24", "type": "unicast",
                      "protocol": "bgp_203_0_113_1",
                      "updated": "2026-11-24 09:05:00",
                      "preferred": true, "preference": 100,
                      "attributes": "[AS65001i]", "flags": null,
                      "table": "master4",
                      "details": ["via 203.0.113.1 on ge1"]}]},
 "meta": {"total": 2, "count": 2, "limit": 100, "offset": 0,
          "warnings": [], "truncated": false, "lines_total": 5}}
```

`?count_only=true` → `data`: `{"available": true, "counts":
{"routes": 2, "routes_total": 2, "networks": 2}}` (from
`show route count`: "N of N routes for N networks").

Errors: unknown `view` / invalid `protocol` / `table` / `prefix` /
`where` → 400 `validation_error` (the message states the requirement);
BIRD not running → 200 `{"available": false, "reason": "BIRD tidak
jalan", "routes": []}`.

### 6.39 `GET /api/v1/bird/routes/stats` — Tier S

CLI: `show route stats` + `show route count`. Backend:
`titian-birdc.sh show-route-stats` + `show-route-count`.

Schema of `data`: `{"available": true, "tables":
[{"table": "master4", "metrics": {"routes": 2, "networks": 2}}],
"counts": {"routes": 2, "routes_total": 2, "networks": 2}}`.
Stats lines that do not match the `Table X:` / `Key: number` pattern go
into the per-table `raw_lines` + `meta.warnings`.

**BIRD — status / simbol / tabel / global / interface.**

### 6.40 `GET /api/v1/bird/status` — Tier S

CLI: `show status`. Backend: `titian-birdc.sh show-status`.

Schema of `data`: `{"available": true, "router_id": "10.99.42.1",
"server_time": "2026-11-25 10:00:00",
"last_reboot": "2026-11-24 09:00:00",
"last_reconfiguration": "2026-11-25 09:30:00",
"daemon_state": "up"}`. Other unrecognized lines go to
`extra_lines` + warning.

### 6.41 `GET /api/v1/bird/symbols` — Tier S

CLI: `show symbols` (+ filter). Backend: `titian-birdc.sh show-symbols
[KIND]`. Query: `?type=function|protocol|roa|symbol|table|template|filter`
(anything else → 400); pagination.

Schema of `data.symbols[]`: `{"kind": "table", "name": "master4"}`.
`kind` comes from the output section (`Routing tables:` → `table`, …) or
from a `table <name>` line.

### 6.42 `GET /api/v1/bird/tables` — Tier S

CLI: `show tables`. Backend: `titian-global.sh show-tables`
(stable format: `<nettype> <name> [opt=val ...]`).

Schema of `data.tables[]`: `{"nettype": "ipv4", "name": "master4",
"options": {}}`; example with options: `{"nettype": "ipv4",
"name": "mytable", "options": {"sorted": "yes"}}`.

### 6.43 `GET /api/v1/bird/global` — Tier T

CLI: `show global`. Backend: `titian-global.sh show` (the
`bird-global.conf` intent + section). Tier T shape, `"source": "show global"`.

### 6.44 `GET /api/v1/bird/interfaces` — Tier S

CLI: `show interfaces bird` (+`summary`). Backend:
`titian-birdc.sh show-interfaces-bird [summary]`. Query:
`?summary=true`; pagination.

Schema of `data.interfaces[]`: `{"name": "ge1", "state": "up",
"index": 2, "flags": "MultiAccess Broadcast Multicast AdminUp LinkUp
MTU=1500", "details": ["203.0.113.10/24 (Primary, scope site)"]}`.
`data.summary` echoes `?summary=`.

**OSPF.**

### 6.45 `GET /api/v1/ospf` — Tier T

CLI: `show ospf`. Backend: `titian-ospf.sh show` (intent + section +
`birdc show protocol ospf4/ospf6` + `show ospf neighbors`).
Tier T shape, `"source": "show ospf"`.

### 6.46 `GET /api/v1/ospf/interfaces` — Tier S

CLI: `show ospf interface`. Backend: `titian-birdc.sh
show-ospf-interface`. Schema of `data.interfaces[]`: `{"id": "ge1",
"title": "Interface ge1 (203.0.113.10/24):", "instance": "ospf4",
"area": "0.0.0.0", "fields": {"type": "broadcast",
"state": "DR (1)", "cost": "10", "hello": "10", "dead": "40"},
"lines": []}`. When NO record parses at all, `data` carries `raw_text`
(the output as-is) + warning.

### 6.47 `GET /api/v1/ospf/neighbors` — Tier S

CLI: `show ospf neighbor(s)`. Backend: `titian-birdc.sh
show-ospf-neighbors` — CHOSEN over `titian-ospf.sh show-neighbors`:
both call the same `birdc show ospf neighbors`; the birdc wrapper adds
soft-fail + strips the BIRD banner. Schema of
`data.neighbors[]`: `{"id": "203.0.113.1", "instance": "ospf4",
"area": "0.0.0.0", "fields": {"interface": "ge1",
"ip_address": "203.0.113.1", "state": "Full", "dr": "203.0.113.1",
"bdr": "203.0.113.10"}, "lines": []}`.

### 6.48 `GET /api/v1/ospf/state` — Tier S

CLI: `show ospf state` (+`all`). Backend: `titian-birdc.sh
show-ospf-state`. Schema of `data.entries[]`: `{"id": "Router
203.0.113.1", "instance": "ospf4", "area": "0.0.0.0",
"fields": {"age": "123", "sequence": "0x80000001",
"checksum": "0x1234"}, "lines": []}`.

### 6.49 `GET /api/v1/ospf/topology` — Tier S

CLI: `show ospf topology` (+`all`). Backend: `titian-birdc.sh
show-ospf-topology`. Same schema as `ospf/state`
(`data.entries[]`, `id` e.g. `"Router 203.0.113.1"` /
`"Network 203.0.113.0/24"`, `fields` e.g. `links` / `distance`).

### 6.50 `GET /api/v1/ospf/lsadb` — Tier S

CLI: `show ospf lsadb`. Backend: `titian-birdc.sh show-ospf-lsadb`.
Schema of `data.entries[]`: `{"id": "Router-LSA 203.0.113.1 203.0.113.1",
"instance": "ospf4", "area": "0.0.0.0", "fields": {}, "lines": []}`
(`title` carries the whole LSA line including `(seq …, age …,
checksum …)`).

**RIP / BFD / RPKI.**

### 6.51 `GET /api/v1/rip` — Tier T

CLI: `show rip`. Backend: `titian-rip.sh show`. Tier T shape,
`"source": "show rip"`.

### 6.52 `GET /api/v1/rip/interfaces` — Tier S

CLI: `show rip interfaces`. Backend: `titian-birdc.sh
show-rip-interfaces`. Schema of `data.interfaces[]` as for OSPF
(`id` = interface name, `fields` e.g. `mode`, `metric`).

### 6.53 `GET /api/v1/rip/neighbors` — Tier S

CLI: `show rip neighbors`. Backend: `titian-birdc.sh
show-rip-neighbors`. Schema of `data.neighbors[]` (`id` = neighbor IP,
`fields` e.g. `interface`, `last_update`).

### 6.54 `GET /api/v1/bfd` — Tier T

CLI: (bfd config). Backend: `titian-bfd.sh show` (intent + section +
`birdc show bfd sessions`; the password is already redacted by that
script, the daemon redacts again). Tier T shape, `"source": "show bfd"`.

### 6.55 `GET /api/v1/bfd/sessions` — Tier S

CLI: `show bfd sessions`. Backend: `titian-bfd.sh show-sessions`.

Schema of `data.sessions[]`: `{"ip": "203.0.113.1", "interface": "ge1",
"state": "Up", "since": "2026-11-25 09:00:00", "interval": "0.100",
"timeout": "0.300"}`. BFD/BIRD not running → 200
`{"available": false, "reason": "BFD/BIRD tidak jalan", "sessions": []}`.

### 6.56 `GET /api/v1/rpki` — Tier S/T (hybrid)

CLI: `show rpki`. Backend: `titian-rpki.sh show` (intent + section +
`birdc show protocol` per instance — there is NO dedicated birdc
`show rpki` command, so this endpoint is Tier T + parsed instances).

Schema of `data`: Tier T shape (`config_text`, `lines`, `source`:
`"show rpki"`) + `"available": true` + `"instances":
[{"name": "rpki1", "protocol": "RPKI", "table": "---",
"state": "up", "since": "2026-11-24 09:00:00",
"info": "Established"}]`. When no instance parses, `instances` is
empty + a warning in `meta.warnings`.

**Other protocols (Tier T).** Each: CLI `show <x>`, backend `titian-<x>.sh show` (intent + section + `birdc show protocol …`), Tier T shape.

### 6.57 `GET /api/v1/babel` — Tier T

Backend: `titian-babel.sh show` (`source`: `show babel`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

### 6.58 `GET /api/v1/direct` — Tier T

Backend: `titian-direct.sh show` (`source`: `show direct`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

### 6.59 `GET /api/v1/pipe` — Tier T

Backend: `titian-pipe.sh show` (`source`: `show pipe`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

### 6.60 `GET /api/v1/device` — Tier T

Backend: `titian-protocol.sh show` (`source`: `show device (+ `"kind": "device"` di `data`)`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

### 6.61 `GET /api/v1/kernel` — Tier T

Backend: `titian-protocol.sh show` (`source`: `show kernel (+ `"kind": "kernel"` di `data`)`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

### 6.62 `GET /api/v1/l3vpn` — Tier T

Backend: `titian-l3vpn.sh show` (`source`: `show l3vpn`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

### 6.63 `GET /api/v1/mrt` — Tier T

Backend: `titian-mrt.sh show` (`source`: `show mrt`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

### 6.64 `GET /api/v1/bmp` — Tier T

Backend: `titian-bmp.sh show` (`source`: `show bmp`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

### 6.65 `GET /api/v1/aggregator` — Tier T

Backend: `titian-aggregator.sh show` (`source`: `show aggregator`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

### 6.66 `GET /api/v1/radv` — Tier T

Backend: `titian-radv.sh show` (`source`: `show radv`). Schema of `data` as for the other Tier T endpoints (config text + `lines` + `source`); `device` and `kernel` share the same backend (`titian-protocol.sh show` — one output contains both), `data.kind` tells which was requested.

**FRR.**

### 6.67 `GET /api/v1/frr` — Tier T

CLI: `show frr`. Backend: `titian-frr.sh show`. FRR not running →
200 `{"available": false, ...}` (NOT 500).

Schema of `data`: Tier T shape (`"source": "show frr"`) + fields parsed
from the first line `FRR: <ver> (intent: <x>, rc: <y>, <running|not
running>[, pid N])`: `"available"`, `"frr_version"`,
`"intent"` (`yes`/`no`/`unset`), `"rc_enabled"` (bool),
`"running"` (bool), `"zebra_pid"` (int|null).

Example (not running):

```json
{"status": "ok",
 "data": {"config_text": "FRR: 10.7.1 (intent: no, rc: no, not running)",
          "lines": 1, "source": "show frr", "available": false,
          "frr_version": "10.7.1", "intent": "no", "rc_enabled": false,
          "running": false, "zebra_pid": null},
 "meta": {"truncated": false, "lines_total": 1, "warnings": []}}
```

### 6.68 `GET /api/v1/frr/bgp` — Tier S

CLI: `show ip bgp`. Backend: `titian-frr.sh show-ip-bgp`
(`vtysh -c "show ip bgp"`, 30-second limit; zebra not running → rc 33
`"FRR belum jalan …"` → 200 `available:false`).

Schema of `data.routes[]`: `{"status": "*>", "network": "203.0.113.0/24",
"next_hop": "203.0.113.1", "metric": 0, "locprf": 100, "weight": 0,
"path": "65001 i"}`. A 5-column line (empty LocPrf collapsed) → `locprf`
null. Lines that fail to parse → `{"raw": …}` + warning.

### 6.69 `GET /api/v1/frr/bgp/summary` — Tier S

CLI: `show ip bgp summary`. Backend: `titian-frr.sh
show-ip-bgp-summary`.

Schema of `data`: `{"available": true, "neighbors":
[{"neighbor": "203.0.113.1", "version": 4, "as": 65001,
"msg_rcvd": 10, "msg_sent": 10, "tblver": 0, "inq": 0, "outq": 0,
"up_down": "00:05:00", "prefixes_received": 5, "state": null}],
"total_neighbors": 1}`. When the last column is not a number (e.g.
`Active`/`Idle`), it goes to `state` and `prefixes_received` is null.

### 6.70 `GET /api/v1/frr/ospf` — Tier S

CLI: `show ip ospf`. Backend: `titian-frr.sh show-ip-ospf`.

Schema of `data`: `{"available": true, "info": {"router_id":
"10.99.42.1", "unparsed_lines": [...]}, "areas": [{"id": "0.0.0.0",
"fields": {"number_of_interfaces_in_this_area": "1",
"number_of_fully_adjacent_neighbors": "1"}}]}`. Lines without a `:`
go to `info.unparsed_lines` + `meta.warnings`.

### 6.71 `GET /api/v1/frr/ospf/neighbors` — Tier S

CLI: `show ip ospf neighbor`. Backend: `titian-frr.sh
show-ip-ospf-neighbor`.

Schema of `data.neighbors[]`: `{"neighbor_id": "203.0.113.1",
"priority": 1, "state": "Full/DR", "dead_time": "00:00:35",
"address": "203.0.113.1", "interface": "ge1:203.0.113.10",
"rxmtl": 0, "rqstl": 0, "dbsml": 0}`.

### 6.72 `GET /api/v1/frr/routes` — Tier S

CLI: `show frr route` / `show ip route` (FRR). Backend:
`titian-frr.sh show-ip-route`.

Schema of `data.routes[]`: `{"code": "O", "prefix": "203.0.113.0/24",
"admin_distance": 110, "metric": 20, "via": "203.0.113.1",
"interface": "ge1", "age": "00:05:00"}`; a connected route:
`{"code": "C", "prefix": "10.99.42.0/24", "admin_distance": null,
"metric": null, "via": null, "interface": "ge1", "age": "00:05:00",
"directly_connected": true}`.

### 6.73 `GET /api/v1/frr/version` — Tier S

CLI: `show frr version`. Backend: `titian-frr.sh show-version`.

Schema of `data`: `{"available": true, "frr_version": "10.7.1",
"running": true, "zebra_pid": 1234,
"version_text": "FRRouting 10.7.1\nCopyright …",
"source": "show frr version"}`. FRR not running: `available`
false, `running` false, `frr_version` still filled (from the
`FRR <ver> (not running)` line).

**Format assumptions (guest verification REQUIRED).**

The formats below are assumed from the `sbin-ref` script sources +
knowledge of the birdc 2.20 / vtysh FRR 10.x formats — NOT yet seen on a
live machine. If the live format differs, the parser returns `raw` +
warning (not 500), and the coordinator adjusts the parser + mock stub
after guest verification:

1. `show protocols [all]`: header `Name Proto Table State Since Info`;
   `Since` = date + time (2 tokens); `all` detail lines are indented
   directly after their protocol line.
2. `show protocol <name>`: table line + `Key: value` detail block +
   `Channel <name>:` (e.g. `Routes: 5 imported, …`).
3. `show route*`: `PREFIX TYPE [PROTO TIME] * (PREF) [ATTRS]`;
   `show route count`: `"N of N routes for N networks"`;
   `show route stats`: `Table X:` sections + `Key: number`.
4. `show symbols`: sections titled with `:` (`Routing tables:`, …)
   containing names.
5. `show interfaces`: `NAME STATE (index=N)` + indented detail lines.
6. OSPF/RIP birdc detail: instance sections (`ospf4:`), `Area X:`,
   records (`Interface …:`, `Router ID: …`, `Router …:`, `Network …:`,
   `Router-LSA …`, `Neighbor …:`) + indented `Key: value`.
7. `show bfd sessions`: header `IP address Interface State Since
   Interval Timeout`; `Since` = date + time.
8. vtysh `show ip bgp`: header `Network Next Hop Metric LocPrf Weight
   Path`; the status code is glued to the front of the network (`*>`);
   a 5-column line = empty LocPrf.
9. vtysh `show ip bgp summary`: header `Neighbor V AS MsgRcvd MsgSent
   TblVer InQ OutQ Up/Down State/PfxRcd` + `Total number of neighbors N`.
10. vtysh `show ip ospf neighbor`: header `Neighbor ID Pri State Dead
    Time Address Interface RXmtL RqstL DBsmL`.
11. vtysh `show ip route`: `CODE PREFIX [AD/METRIC] via GW, IF, AGE`
    or `CODE PREFIX is directly connected, IF, AGE`.
12. `titian-frr.sh show`: first line `FRR: <ver> (intent: <x>,
    rc: <y>, <running|not running>[, pid N])`.

**Not exposed (per design §2 D3).**

- `show route help` (local CLI help), `show frr bgp` (no ACTION —
  no backend), `show protocol neighbors` (covered by
  `bird/protocols/:name`), `show route export table` / `import table`
  (covered by `bird/routes?view=…&table=…` — `view=import` uses
  `show-route-import-table <PROTO.CHANNEL>`).

**Proposed write endpoints (OPEN — NOT implemented).**

Per design §0/§3: GET only in this round. If the web UI needs writes
to be useful, the proposals below are recorded only (name + reason +
risk):

1. `POST /api/v1/bird/protocols/:name/restart` — restart one BIRD
   protocol from the web UI (backend already exists:
   `titian-birdc.sh proto-restart`; risk: brief routing disruption;
   needs confirmation + audit like kick/isolate).
2. `POST /api/v1/bird/protocols/:name/enable|disable` — enable/disable
   a protocol (backends `proto-enable`/`proto-disable` already exist;
   risk: the protocol stays down until re-enabled).
3. `POST /api/v1/bird/reload` — re-`configure` BIRD after intent changes
   (backend `configure` already exists; risk: a config error rejects
   the reload — `configure check` validation needed first).
4. `POST /api/v1/frr/reload` — restart/reload FRR (mutual exclusion vs
   BIRD — HIGH risk: the wrong order can kill routing; DO NOT attempt
   without a separate design).


**D4a — firewall / WireGuard.**

### 6.74 `GET /api/v1/firewall` — firewall summary + configuration (Tier S/T)

Backend: `titian-fw.sh show` + `titian-fw.sh status`.

Schema of `data`: `enabled` (bool|null, from the `firewall: yes|no` line in
`firewall.conf`), `protected_interfaces` (list of strings),
`rules` (list of raw rule strings from `show`, order = priority),
`rule_count` (int), `config_text` (string, the whole `show` output),
`lines` (int, number of lines in `config_text`), `pf_running` (bool|null —
`true` when `status` prints `pf: Enabled`; `null` when `status` fails),
`live_filter` (list of pf `firewall` anchor rule lines, unindented),
`live_nat` (list of pf `nat` anchor rule lines, unindented).

```http
GET /api/v1/firewall
```

```json
{"status": "ok", "data": {"enabled": true, "protected_interfaces": ["ge0"],
"rules": ["filter forward permit proto tcp src any dst 10.99.42.0/24 sport any dport 80 in ge1 out any",
"snat 10.99.42.0/24 to masquerade out ge1"], "rule_count": 2,
"config_text": "firewall: yes\nprotected interfaces:\n  ge0\nrules (order = priority; delete with the full syntax):\n  1. filter forward permit proto tcp src any dst 10.99.42.0/24 sport any dport 80 in ge1 out any\n  2. snat 10.99.42.0/24 to masquerade out ge1\n",
"lines": 6, "pf_running": true,
"live_filter": ["pass in quick on ge1 inet proto tcp from any to 10.99.42.0/24 port = 80"],
"live_nat": ["nat on ge1 from 10.99.42.0/24 to any -> (ge1)"]},
"meta": {"warnings": []}}
```

Errors: no token → 401 `unauthorized`; wrong token → 403 `forbidden`;
backend failure → 500 `internal_error`.

### 6.75 `GET /api/v1/firewall/filter` — filter rules (Tier S)

Backend: `titian-fw.sh show-filter` (lines of the form `filter <chain>
<action> proto <p> src <a> dst <a> sport <s> dport <d> in <if> out <if>`).
Lines that do not match the pattern → `{"raw": "<line>"}` + `meta.warnings`.

Schema of each item in `data.rules`: `chain` (`forward`|`input`|`output`),
`action` (`permit`|`deny`), `protocol` (`tcp`|`udp`|`icmp`|`all`),
`src`/`dst` (string, CIDR or `any`), `sport`/`dport` (int|null —
`null` = `any`), `in_interface`/`out_interface` (string), `raw` (string,
the original line). Items that fail to parse carry only `raw`.

```http
GET /api/v1/firewall/filter?limit=100&offset=0
```

```json
{"status": "ok", "data": {"rules": [{"chain": "forward", "action": "permit",
"protocol": "tcp", "src": "any", "dst": "10.99.42.0/24", "sport": null,
"dport": 80, "in_interface": "ge1", "out_interface": "any",
"raw": "filter forward permit proto tcp src any dst 10.99.42.0/24 sport any dport 80 in ge1 out any"}]},
"meta": {"total": 1, "count": 1, "limit": 100, "offset": 0, "warnings": []}}
```

Errors: invalid `limit`/`offset` → 400 `validation_error`.

### 6.76 `GET /api/v1/firewall/nat` — NAT rules (Tier S)

Backend: `titian-fw.sh show-nat` (`snat`/`dnat` lines).

Schema of each item in `data.rules`: `snat` → `type: "snat"`, `srcnet`,
`target` (IPv4 or `"masquerade"`), `out_interface`, `raw`;
`dnat` → `type: "dnat"`, `protocol` (`tcp`|`udp`), `in_interface`,
`dport` (int), `target` (IPv4), `target_port` (int|null — `null` for
`same`), `target_port_same` (bool), `raw`. Items that fail to parse carry
only `raw`.

```http
GET /api/v1/firewall/nat
```

```json
{"status": "ok", "data": {"rules": [
{"type": "snat", "srcnet": "10.99.42.0/24", "target": "masquerade",
"out_interface": "ge1", "raw": "snat 10.99.42.0/24 to masquerade out ge1"},
{"type": "dnat", "protocol": "tcp", "in_interface": "ge1", "dport": 8080,
"target": "10.99.42.100", "target_port": null, "target_port_same": true,
"raw": "dnat tcp in ge1 dport 8080 to 10.99.42.100 port same"}]},
"meta": {"total": 2, "count": 2, "limit": 100, "offset": 0, "warnings": []}}
```

Errors: invalid `limit`/`offset` → 400 `validation_error`.

### 6.77 `GET /api/v1/firewall/isolated` — isolated users list (Tier S)

Backend: `titian-fw.sh show-isolated` (already used by the old endpoint;
one line `isolate <ip> <web-ip> <web-port>` per user).

Schema of each item in `data.isolated`: `ip`, `web_ip` (IPv4 string),
`web_port` (int). An empty list → 200 + empty list (not 404).

```http
GET /api/v1/firewall/isolated
```

```json
{"status": "ok", "data": {"isolated": [{"ip": "10.99.42.100",
"web_ip": "203.0.113.10", "web_port": 80}]},
"meta": {"total": 1, "count": 1, "limit": 100, "offset": 0, "warnings": []}}
```

### 6.78 `GET /api/v1/wireguard` — WireGuard interface list (Tier S)

Backend: `titian-wireguard.sh show` (per-interface summary + the
`-- wg show:` section from the `wg` tool).

Schema of each item in `data.interfaces`: `name` (e.g. `"wg0"`), `enabled`
(bool), `address` (CIDR string|null — `null` for `unset`),
`listen_port` (int, default 51820), `peer_count` (int), `live` (bool —
interface present in the kernel). `data.live`: parsed `wg show` output
(`interface`, `public_key`, `listening_port`, `peers[]` with
`public_key`/`endpoint`/`allowed_ips`/`latest_handshake`/`transfer`)
or `null` when `wg` prints no output; `data.live_text`: raw text of the
`-- wg show:` section (or `null`).

```http
GET /api/v1/wireguard
```

```json
{"status": "ok", "data": {"interfaces": [{"name": "wg0", "enabled": true,
"address": "10.8.0.1/24", "listen_port": 51820, "peer_count": 2, "live": true},
{"name": "wg1", "enabled": false, "address": null, "listen_port": 51820,
"peer_count": 0, "live": false}],
"live": {"interface": "wg0", "public_key": "AAAABBBBCCCCDDDD1111222233334444AAAABBBBCCCCDDDD1111222233334444AAo=",
"listening_port": 51820, "peers": [{"public_key": "PEERKEY1111111111111111111111111111111111111111111111111111111111A==",
"endpoint": "203.0.113.5:51820", "allowed_ips": "10.8.0.2/32",
"latest_handshake": "1 minute, 2 seconds ago",
"transfer": "1.00 KiB received, 2.00 KiB sent"}]},
"live_text": "  interface: wg0\n    public key: AAAABBBBCCCCDDDD1111222233334444AAAABBBBCCCCDDDD1111222233334444AAo=\n    private key: (hidden)\n    listening port: 51820\n  peer: PEERKEY1111111111111111111111111111111111111111111111111111111111A==\n    endpoint: 203.0.113.5:51820\n    allowed ips: 10.8.0.2/32\n    latest handshake: 1 minute, 2 seconds ago\n    transfer: 1.00 KiB received, 2.00 KiB sent\n"},
"meta": {"total": 2, "count": 2, "limit": 100, "offset": 0, "warnings": []}}
```

Note: the private key is NEVER printed by the backend or the API
(`wg show` only prints `private key: (hidden)`; the `public-key` line of
the state file is filtered by the backend `show-one` and skipped by the
daemon parser).

### 6.79 `GET /api/v1/wireguard/:name` — one WireGuard interface (Tier S)

Backend: `titian-wireguard.sh show-one <name>` (name validated against
`^wg[0-9]{1,2}$`, mismatch → 400). Existence is checked from the state file
`$TITIAN_STATE_ROOT/netstate/wireguard/<name>.conf` BEFORE calling the
backend — because the original `show-one` creates a new state file when
none exists, so without this check a missing name would look present.

Schema of `data`: `name`, `enabled` (bool|null), `address` (string|null),
`listen_port` (int, default 51820), `peers[]` (`public_key`,
`allowed_ips` string|null — `null` for `-`, `endpoint` string|null,
`keepalive` int seconds), `live` (parsed `wg show <iface>` as in §6.78,
or `null`), `live_available` (bool), `live_raw` (list of raw live lines).

```http
GET /api/v1/wireguard/wg0
```

```json
{"status": "ok", "data": {"name": "wg0", "enabled": true,
"address": "10.8.0.1/24", "listen_port": 51820,
"peers": [{"public_key": "PEERKEY1111111111111111111111111111111111111111111111111111111111A==",
"allowed_ips": "10.8.0.2/32", "endpoint": "203.0.113.5:51820", "keepalive": 25},
{"public_key": "PEERKEY2222222222222222222222222222222222222222222222222222222222B==",
"allowed_ips": null, "endpoint": null, "keepalive": 0}],
"live": {"interface": "wg0", "public_key": "AAAABBBBCCCCDDDD1111222233334444AAAABBBBCCCCDDDD1111222233334444AAo=",
"listening_port": 51820, "peers": [{"public_key": "PEERKEY1111111111111111111111111111111111111111111111111111111111A==",
"endpoint": "203.0.113.5:51820", "allowed_ips": "10.8.0.2/32",
"latest_handshake": "1 minute, 2 seconds ago",
"transfer": "1.00 KiB received, 2.00 KiB sent"}]},
"live_available": true, "live_raw": ["interface: wg0", "public key: AAAABBBBCCCCDDDD1111222233334444AAAABBBBCCCCDDDD1111222233334444AAo=", "listening port: 51820", "peer: PEERKEY1111111111111111111111111111111111111111111111111111111111A==", "endpoint: 203.0.113.5:51820", "allowed ips: 10.8.0.2/32", "latest handshake: 1 minute, 2 seconds ago", "transfer: 1.00 KiB received, 2.00 KiB sent"]},
"meta": {"warnings": []}}
```

Errors: name not `wg<N>` → 400 `validation_error`; interface not configured
(no state file) → 404 `not_found`.

**Assumptions not yet verified on a live machine (OPEN, needs guest bhyve).**

- The `wg show` format is assumed to be the standard `wg` tool format
  (`interface:`/`public key:`/`listening port:`/`peer:`/`endpoint:`/
  `allowed ips:`/`latest handshake:`/`transfer:`). The live parser is
  best-effort: unknown lines go to `live_raw` + `meta.warnings`, not a
  total failure. If the guest format differs, adjust the parser.
- `GET /api/v1/firewall` reads `pf_running` from `titian-fw.sh
  status` (substring `Enabled`); if `pfctl -s Running` fails, the
  backend prints `pf: not running` and the daemon returns
  `pf_running: false` + empty `live_filter`/`live_nat`.

**Proposed write endpoints (OPEN — NOT implemented in this round).**

- `POST /api/v1/firewall/enable` + `POST /api/v1/firewall/filter` /
  `nat` (add/remove rules) — the operator web UI needs these to avoid
  going back to klish; risk: rule validation + the protected-interface
  anti-lockout must be kept exactly as in `titian-fw.sh`; needs a
  mandatory `reason` + syslog audit like disconnect/isolate.
- `POST /api/v1/wireguard/:name/peers` (add a peer) — needs
  `generate-key`, showing the public key once; risk: the private key
  must NEVER enter a response/log.


**D4b — traffic-shape / PPPoE / IPoE / monitoring.**

**Traffic-shape.**

### 6.80 `GET /api/v1/traffic-shape` — Tier T
Backend: `titian-traffic-shape.sh show`. Response `data`:
`{enabled: bool|null, config_text: string, lines: int, source: "show traffic-shape"}`.
Example: `{"enabled": true, "config_text": "traffic-shape: yes\npipes:\n  pipe p10m bw 10M ...", "lines": 14, ...}`.

### 6.81 `GET /api/v1/traffic-shape/profiles` — Tier S
Backend: `show-profile` (no argument). `data.profiles[]`:
`{name, download: "8M", download_burst: 1000000, upload: "2M", upload_burst: 500000, bindings: [{profile, target_type: "interface"|"ip", interface, ip?, side?}]}`.
`download/upload` are rate strings as-is (`"8M"`, `"unset"` when not set);
burst is an integer number of bytes. Pagination applies.

### 6.82 `GET /api/v1/traffic-shape/profiles/:name` — Tier S
Backend: `show-profile <name>` (name `[A-Za-z0-9_-]{1,12}`, otherwise 400
`validation_error`). `data.profile` = profile object + `derived_pipes[]`
(pipe objects) + `derived_rules[]` (rule objects). Not found → 404
`not_found` (the backend prints `(no profile <name>)` with rc 0 — the
daemon turns that into 404).

### 6.83 `GET /api/v1/traffic-shape/pipes` — Tier S
Backend: `show-pipe`. `data.pipes[]`:
`{name, bw: "10M"|"unset", queue: int, delay_ms: int, plr: number|string, burst: int, aqm?: "aqm codel target 5"}`.
Empty → `[]` (backend `(no pipes)`), not 404.

### 6.84 `GET /api/v1/traffic-shape/queues` — Tier S
Backend: `show-queue`. `data.queues[]`:
`{name, parent_kind: "pipe"|"sched", parent, mask: "dst-ip"|..., mask_value: "/32"|"-", weight: int, queue: int, aqm?}`.

### 6.85 `GET /api/v1/traffic-shape/rules` — Tier S
Backend: `show-rule`. `data.rules[]`:
`{name, direction: "in"|"out", interface, target_kind: "pipe"|"queue", target, src?: ip|cidr, dst?, proto?: "tcp"|"udp"|"icmp"|"all", dport?: int}`.

### 6.86 `GET /api/v1/traffic-shape/sched` — Tier S
Backend: `show-sched`. `data.schedulers[]`:
`{name, type: "fifo"|"wf2q+"|"rr"|"qfq"|"fq_codel"|"fq_pie", bw?, quantum?: int, limit?: int, flows?: int}`.

### 6.87 `GET /api/v1/traffic-shape/statistics` — Tier S (sections)
Backend: `stats`. `data`:
`{available: bool, dummynet_loaded: bool, sections: [{name, text, line_count}], note?: string, reason?}`.
A section = a backend `== ... ==` header (`pipes`, `schedulers`, `queues`,
`pf anchor traffic-shape rules (...)`, `interface counters (...)`).
ipfw columns are NOT parsed (no ipfw format in sbin-ref; the BKT
`Tot_pkt/bytes` counter quirk — counters not moving — was proven live
22 Nov 2026 — see `note`).
When dummynet is not loaded → 200 `{"available": false, "reason": "dummynet belum dimuat (traffic-shape belum pernah di-apply)", "dummynet_loaded": false, "sections": []}`.

**PPPoE.**

### 6.88 `GET /api/v1/pppoe` — Tier S
Backend: `titian-pppoe.sh show` (+ `sessions-detail` for the session count).
`data`: `{enabled, interface, pool: "10.99.42.100-10.99.42.199"|null, pool_start, pool_end, radius_server: ip|null (null for "local auth"), radius_auth: bool, radius_acct: bool|null, radius_nas_ip, console: bool|null, console_password_set: bool (set/unset status only — the password NEVER appears), users: int|null, mpd5_running: bool|null, sessions_active: int}`.
Active sessions are still at `/api/v1/sessions`.

### 6.89 `GET /api/v1/pppoe/users` — Tier S
Backend: `show-users`. `data.users[]`: `{user, static_ip: ip|null}` (`null`
for `pool`/`-`). Pagination applies. Empty → `[]`.

**IPoE.**

### 6.90 `GET /api/v1/ipoe` — Tier S
ASSUMPTION (flagged): `titian-ipoe-acct.py` does NOT exist in sbin-ref
(only referenced by comments in `titian-dhcp.sh`/`titian-pppoe.sh`), so
this endpoint is built from `ipoe.conf` (non-secret fields only —
`radius-secret`/`omapi-key` are never read) + `titian-dhcp.sh
server-status` + the lease file (the same parser as the daemon).
`data`: `{available: bool, reason: string|null, enabled, interface, pool, dhcpd_running: bool|null, active_leases: int, radius_server, nas_ip, radius_mac_auth: bool, radius_mac_count: int, blocked_mac_count: int}`.
When `ipoe.conf` is missing → 200 `{"available": false, "reason": "IPoE belum dikonfigurasi (ipoe.conf tidak ada)", ...}`.
Guest verification required: confirm `ipoe.conf` + `server-status` behave
the same on a live machine; if `titian-ipoe-acct.py status` turns out to
exist on kopler, the coordinator may switch the session-status source
(its format is not yet known).

### 6.91 `GET /api/v1/ipoe/leases` — Tier S
Backend: `titian-dhcp.sh list-leases`. `data.leases[]`:
`{ip, mac, ends: "2026-11-24T11:00:00Z" (ISO 8601 UTC), ends_epoch: int}`.
Only `active` leases (last block per IP, append-only file). Pagination is
REQUIRED (the list can be large). Empty → `[]`.

### 6.92 `GET /api/v1/ipoe/blocked` — Tier S
Backend: `titian-dhcp.sh list-blocked`. `data.blocked[]`: `{mac}`.
Pagination applies. Empty → `[]`.

**Monitoring.**

### 6.93 `GET /api/v1/monitoring` — Tier S
Backend: `titian-monitoring.sh show [service]`. Optional query
`?service=snmp|node-exporter|bird-exporter|nfacctd` (anything else → 400
`validation_error`). `data.services[]`:
`{service, process: "snmpd"|"node_exporter"|"bird_exporter"|"nfacctd", port: "161/udp"|"9100"|"9324"|"2100", enabled: bool|null (from intent), intent: "yes"|"no"|"unset", rc_enabled: bool|null, running: bool, community?: string (snmp only)}`.
`community` is an intent string (default `bsdrp-ro`), not a secret.

### 6.94 `GET /api/v1/monitoring/bandwidth` — Tier S
Backend: `titian-monitoring.sh bandwidth <seconds>`. Query `?seconds=`
1–3600, default 60 (anything else → 400). `data`:
`{seconds: int, interfaces: [{interface, rx: "1.23 Mbps", rx_bps: 1230000, tx, tx_bps, total, total_bps}], measured_at: ISO UTC}`.
The `total` row is included as interface `"total"`. Live mode (>1 second)
prints the table repeatedly — the daemon takes the LAST table. bps values
are decimal (1 Mbps = 1,000,000 bps, per the backend's `fmt_bps`).
NOTE: a large `seconds` (e.g. 3600) holds the request for that long
(backend timeout = seconds+10); the web UI should use 1–10 seconds. When
`bwm-ng` is not installed, the backend fails → 500 `internal_error`.

**Common errors.**
401 `unauthorized` (no token) · 403 `forbidden` (wrong token) ·
404 `not_found` (endpoint/profile missing) · 400 `validation_error`
(invalid parameter/query) · 429 `rate_limited` · 500 `internal_error`
(backend failed/timed out).

**Not done / OPEN.**
- No D4b endpoint failed outright — 15/15 done (mock).
- Write endpoints (OPEN proposals, NOT implemented in this GET round):
  `POST /api/v1/traffic-shape/profiles/:name/bind` (bind a profile to an
  interface/IP — useful so the web UI can apply a package without klish;
  risk: it changes `traffic-shape.conf` + dirty flag → needs commit/apply;
  needs interface/IP validation + separate authorization),
  `POST /api/v1/ipoe/blocked` / `DELETE /api/v1/ipoe/blocked/:mac`
  (block/unblock a MAC — the counterpart of the existing session
  `kick`/`unblock`; risk: dhcpd restart on kick),
  `POST /api/v1/monitoring/:service` (enable/disable a monitoring intent —
  only records intent + dirty, takes effect on commit; low risk).
- Verification still waiting on the coordinator (guest bhyve, real backend):
  the `ipfw pipe/sched/queue show` table format in `statistics` (currently
  text sections, not parsed columns); `titian-ipoe-acct.py status`
  (not in sbin-ref — confirm whether it exists on kopler);
  `monitoring bandwidth` live mode >1 second (mock only tested a 1-second
  snapshot); `show-profile` for a profile with a CIDR IP bind (slug
  contains `-`).


## 7. Isolation — important notes

1. **Isolation = dst-nat, not a small pipe.** The user's web traffic
   (TCP 80 AND TCP 443) is redirected to the isolir web (web server
   port, 80). NO 443 blocking. HTTPS clients receive a plain HTTP
   response (not TLS) — a design consequence, not a bug. Bandwidth
   (dummynet) is unchanged.
2. **An isolir web outside the router needs a forward permit.** The
   pf filter sees the packet AFTER dst-nat (dst = isolir web IP). If
   the isolir web lives outside the router, add a filter rule allowing
   forward to that web IP — otherwise the traffic is redirected and
   then dropped by the trailing forward block. If the isolir web runs
   on the router itself, nothing extra is needed (input default ACCEPT).
3. **The firewall must be enabled.** Without it the nat/firewall
   anchors are not loaded and isolation has no effect (the API refuses
   with 400).
4. **Isolation survives reboots** (state file + apply at boot), but
   **sessions do not**: after a reboot, sessions must be re-created
   (PPPoE redial / DHCP renew) — the isolated list still waits for the
   same IP (if the IP changes, isolation does not follow; unisolate
   and isolate again).
5. **Isolation is per IP, not per user.** If a user gets a new IP
   (reconnect), the old isolation does not follow.

## 8. Kick — important notes

- PPPoE: via the mpd5 console (Option A, graceful LCP) — the user can
  redial immediately. A RADIUS Stop is recorded when RADIUS
  accounting is active.
- IPoE: `kick-lease` only frees the lease — the device will request a
  new lease (DHCP renew) and come back online. This is intentional:
  an IPoE kick means "drop now", not "block". For a permanent MAC
  block, use `titian-remote-kick.sh kick <mac>` (CLI) — not the API.
- Every kick / isolate / unisolate **requires a reason** (`reason`)
  and is recorded in the router syslog (see §10).

## 9. Live bandwidth — counter sources

- PPPoE: `netstat -I <ngX> -b` — Ibytes/Obytes of the session's
  netgraph interface. `rate_source: "ng"`.
- IPoE: per-rule byte counters in the `traffic-shape` anchor
  (`pfctl -a traffic-shape -s rules -v`) — only when that IP is bound
  to a traffic-shape profile; if not bound, bps = 0, `rate_source:
  "pf"` with null totals, or `"none"`.
- **NOT `ipfw pipe show` BKT** — the BKT counter was proven not to
  move (quirk, 22 Nov 2026).
- Rate = byte delta × 8 / sampling seconds (default 2 s, `sample`
  0–5). `sample=0` = no rate (bps 0, totals null) — for fast lists.
- PPPoE uptime is always `null` (ng* interfaces carry no session start
  time); IPoE uptime comes from `starts` in the lease file.

## 10. Audit & logs

- Every kick / isolate / unisolate (success or failure) is recorded in
  the router syslog (`daemon.info`, tag `titian-api`): token name,
  action, session id, user, IP, reason, result. Example:
  `titian-api[1234]: myraddash disconnect pppoe-agus (10.99.42.101) reason=2 months in arrears ok=yes verified=yes`
- Daemon access logs (requests) go to stderr (captured by rc.d
  `daemon`).
- Tokens and passwords are **never** written to logs/responses. One
  exception: `gentoken` prints a new token ONCE to the root admin
  terminal (§3.3).
- Backend error messages containing the words password/secret/token
  are hidden from API responses (replaced with a generic message;
  details in the router syslog).

## 11. Token rotation

```sh
service titian-api gentoken --name myraddash   # new token, printed once
# update the myRadDASH NAS record with the new token
# (the old token stops working immediately)
```

Tokens have no expiry (revocation = replacing the token). If a token
leaks, rotate immediately; there is no "delete one token" other than
removing its line from the config and restarting the service.

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `401 unauthorized` | `Authorization: Bearer <token>` header missing. |
| `403 forbidden` | Wrong token / not created yet (`gentoken`). |
| `400 validation_error` (isolate) | `isolir-web` empty in config, or firewall not enabled. |
| `500 internal_error` (PPPoE disconnect) | mpd5 console not answering (is mpd5 running? `console` enabled? console password set?). Check the router syslog. |
| `sessions` empty while users are online | PPPoE: mpd5 console not enabled / `sessions-detail` failing (see `meta.warnings`). IPoE: lease file unreadable. |
| bps always 0 (IPoE) | IP not bound to a traffic-shape profile (pf counters only exist when there is a per-IP rule). |
| `rate_limited` | Over the per-minute limit — raise `rate-limit` in config, or poll less often from the web UI. |
| Daemon does not start | `titian-api.py check` — missing config / empty token list / bind 0.0.0.0 / missing backend. |

## 13. Notes (open)

- **Isolir web address: `103.50.129.84:80`** — myradash-isolir-web on
  host 84 (container 172.30.0.22:8080 internal, published 0.0.0.0:8080,
  reached via the NPM default server on port 80). Decided by the user
  25 Nov 2026 ("ok webisolir ngikut"). Verified live from a bhyve
  guest 25 Nov 2026 (round 5, with PPPoE-pool SNAT in the guest):
  redirect :80 -> HTTP 200 + isolir page title; redirect :443 ->
  connection completed (FIN_WAIT_2) — HTTPS clients receive a plain
  HTTP response, as designed.
- **Production bind IP not decided** — default `127.0.0.1` (router
  itself only). For myRadDASH access from outside, set the router's
  management IP (not 0.0.0.0).
- **Default TLS certificate is self-signed** — replace with a proper
  certificate for production.
- **Operator web UI + myRadDASH integration** are the next steps
  (Phase 2 steps 3+), not part of this document.
- **PPPoE uptime** is unavailable (`null`) — see §9.

- **Read-all-CLI-menus expansion (25 Nov 2026)** — 87 new GET endpoints (§6.8–6.94): D1 system/config/checkpoints (15), D2 interfaces/IP/routes (10), D3 BIRD/routing-protocols (41), D4a firewall/WireGuard (6), D4b traffic-shape/BRAS/monitoring (15). The API now has 94 endpoints in total (7 old + 87 new). The only new backend is the `titian-sys.sh storage` subcommand. Combined mock suite (real daemon + stub backends + real HTTPS): **212/212 PASS**. Guest bhyve verification with the real klish backend: *awaiting the guest round result — this part will be updated afterwards*.
- **Proposed write endpoints (OPEN — not implemented in this GET round).** D1: `POST /api/v1/system/sysctl`, `POST /api/v1/checkpoints` (+ rollback/delete), `POST /api/v1/services/:name/restart`. D2: `POST /api/v1/interfaces/:name/tuning`, `POST /api/v1/vxlan*`, `POST /api/v1/bridges*`, `POST /api/v1/routing/static/routes`. D3: `POST /api/v1/bird/protocols/:name/restart|enable|disable`, `POST /api/v1/bird/reload`, `POST /api/v1/frr/reload` (HIGH risk — BIRD/FRR mutual exclusion). D4a: `POST /api/v1/firewall/enable`, `POST /api/v1/firewall/filter|nat` (needs anti-lockout + reason + audit), `POST /api/v1/wireguard/:name/peers` (the private key must never enter a response/log). D4b: `POST /api/v1/traffic-shape/profiles/:name/bind`, `POST|DELETE /api/v1/ipoe/blocked[/:mac]`, `POST /api/v1/monitoring/:service`. All need a reason + audit like disconnect/isolate; config writes stay in klish until decided otherwise.
- **Format assumptions still needing guest evidence.** D2: the `titian-show.sh interfaces`/`terse` table format, FreeBSD `arp -a` and `netstat -rn`, vxlan FDB lines; the Linux parser branches were only unit-tested (mock §17b), not over HTTP. D3: `show route stats`, `show symbols`, OSPF/RIP/LSADB blocks, `show bfd sessions`, the 5-column `show ip bgp`. D4a: the standard `wg show` format. D4b: `traffic-shape statistics` is currently text sections (ipfw columns not parsed — no ipfw format in the reference + the BKT counter quirk); `/api/v1/ipoe` is built from `ipoe.conf` + `server-status` + the lease file because `titian-ipoe-acct.py` is not in `titian/sbin/` (confirm its location on kopler/guest); `monitoring/bandwidth` live mode >1 second was only tested as a 1-second snapshot in mock.
