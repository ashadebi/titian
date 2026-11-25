# titian-api — API HTTP+JSON untuk Titian (BRAS operator)

Dokumen ini menjelaskan API operator Titian (Fase 2, langkah 1+2):
daemon HTTP+JSON di router BSDRP yang dipakai web UI operator dan
myRadDASH untuk melihat sesi aktif, kick, dan isolir user — lewat
browser, tanpa harus paham FreeBSD/klish.

> English version: `doc/titian-api-en.md` (isi sama).

## 1. Apa itu titian-api

`titian-api` adalah daemon kecil (Python 3 stdlib SAJA, tanpa dependensi
pip) yang berjalan di router BSDRP dan menyajikan operasi operator
sebagai API HTTP+JSON:

- `GET /api/v1/health` — API hidup? versi Titian/BSDRP/BIRD/FRR?
- `GET /api/v1/sessions` — semua sesi aktif (PPPoE + IPoE) + bandwidth
  live rx/tx bps, default urut pemakaian terbesar dulu.
- `GET /api/v1/sessions/:id` — satu sesi.
- `POST /api/v1/sessions/:id/disconnect` — kick (putus sesi).
- `POST /api/v1/sessions/:id/isolate` — isolir user ke web isolir.
- `POST /api/v1/sessions/:id/unisolate` — cabut isolir.
- `GET /api/v1/nas/status` — status NAS (versi, pppoe/pf, jumlah sesi).

## 2. Arsitektur — single-engine

API **tidak pernah** menyentuh mpd5 / BIRD / pf / dummynet langsung.
Semua operasi lewat backend script yang SAMA dengan yang dipakai
`ACTION` klish — satu implementasi per operasi, dipakai CLI dan API:

| Operasi API | Backend yang dipakai |
|---|---|
| Sesi PPPoE | `titian-pppoe.sh sessions-detail` (baru; `user\|framed_ip\|link` dari console mpd5 `show sessions`) |
| Kick PPPoE | `titian-pppoe.sh disconnect <user> <framed-ip>` (konsol mpd5, Opsi A — terbukti live 20 Nov 2026) |
| Sesi IPoE | file lease dhcpd `/var/db/dhcpd.leases` (parser sama dengan `titian-ipoe-acct.py`) |
| Kick IPoE | `titian-dhcp.sh kick-lease <mac>` (lepas lease; reconnect diizinkan) |
| Isolir / cabut isolir | `titian-fw.sh isolate / unisolate / show-isolated` (state `/usr/local/etc/isolated.conf`) |
| Versi | `pkg info titian` + `titian-bird.sh show-version` |
| Bandwidth PPPoE | `netstat -I <ngX> -b` (counter interface) |
| Bandwidth IPoE | `pfctl -a traffic-shape -s rules -v` (counter per rule pf) |

Kenapa tidak lewat `klish` (konf batch)? Output konf berformat
manusia + dibungkus pager, rapuh untuk diparse mesin. Backend script
adalah lapisan yang sama yang dipanggil klish — jadi API dan CLI
tidak pernah berpisah perilakunya.

Input dari web **tidak pernah** diinterpolasi ke shell: subprocess
selalu argv-list (`shell=False`), argumen divalidasi ketat dulu
(username `[A-Za-z0-9_-]+`, IPv4, MAC, session id).

## 3. Instalasi & cara jalan

### 3.1 Install

API ikut ter-install bersama paket Titian (daemon di
`/opt/titian/sbin/titian-api.py`, rc.d di
`/usr/local/etc/rc.d/titian-api`, config contoh di
`/usr/local/etc/titian-api.conf.example`).

### 3.2 Konfigurasi

Salin contoh ke config aktif, lalu isi:

```sh
cp /usr/local/etc/titian-api.conf.example /usr/local/etc/titian-api.conf
chmod 600 /usr/local/etc/titian-api.conf
```

Isi file (lihat juga `titian-api.conf.example`):

```ini
bind 127.0.0.1
port 8443
isolir-web 103.50.129.84:80
rate-limit 60
# cert /etc/titian/titian-api-cert.pem
# key /etc/titian/titian-api-key.pem
# token <nama> <hex>   -- dibuat via gentoken, jangan diisi manual
```

- `bind` — IP yang di-listen. **Harus IP manajemen / 127.0.0.1.
  `0.0.0.0` DITOLAK di startup** (daemon menolak jalan).
- `isolir-web` — alamat web isolir (portal bayar), tujuan dst-nat.
  **Wajib diisi sebelum memakai `isolate`** (bila kosong, isolate
  mengembalikan 400). Alamat ini BELUM diputuskan user (24 Nov 2026)
  — nilai di contoh adalah placeholder, ganti dengan alamat sebenarnya.
- `rate-limit` — request per menit per token (default 60; lewat →
  429 `rate_limited`).
- `cert` / `key` — sertifikat TLS. Bila file belum ada, daemon membuat
  self-signed via openssl saat pertama jalan. Produksi: ganti dengan
  sertifikat proper, lalu restart service.

### 3.3 Token

```sh
service titian-api gentoken --name myraddash
```

Token tercetak **SEKALI** ke terminal admin root — simpan ke record
NAS myRadDASH. Sesudah itu token hanya bisa dibaca dari file config
(mode 600, root-only). Rotasi: jalankan `gentoken --name <nama>` yang
sama (token lama tertimpa), lalu update record NAS.

### 3.4 Menyalakan service

```sh
# /etc/rc.conf
titian_api_enable="YES"
```

```sh
service titian-api start
service titian-api status
```

Cek config + backend tanpa menjalankan aksi:

```sh
/usr/local/bin/python3 /opt/titian/sbin/titian-api.py check
```

## 4. Auth & rate limit

- Semua endpoint wajib `Authorization: Bearer <token>`.
- Tanpa token → **401 `unauthorized`**; token salah → **403 `forbidden`**.
- Rate limit per token (default 60/menit) → **429 `rate_limited`**.
- Semua akses HTTPS (TLS). Sertifikat self-signed default — pin
  fingerprint di myRadDASH bila perlu, atau ganti sertifikat proper.

## 5. Kontrak JSON (mengikat)

Keputusan user 24 Nov 17:46. Berlaku untuk SEMUA endpoint.

Sukses:

```json
{ "status": "ok", "data": {...}, "meta": {...} }
```

Error:

```json
{ "status": "error", "data": null,
  "error": { "code": "KODE_STABIL", "message": "..." } }
```

- HTTP status sesuai makna: 200 sukses, 400 input tidak valid,
  401 tanpa token, 403 token salah, 404 tidak ditemukan,
  429 rate limit, 500 kesalahan internal.
- `error.code` stabil: `unauthorized`, `forbidden`, `not_found`,
  `validation_error`, `rate_limited`, `internal_error`.
- snake_case; angka tetap angka (bps integer); timestamp ISO 8601 UTC
  (`2026-11-24T11:18:52Z`); list bawa `meta` (`total`, `sort`,
  `limit`/`offset`); `Content-Type: application/json; charset=utf-8`
  selalu; versioning di path (`/api/v1/`).
- Kegagalan satu sumber data (mis. console mpd5 tidak menjawab) TIDAK
  menggagalkan seluruh request — dilaporkan di `meta.warnings`
  (list string), sesi dari sumber lain tetap dikembalikan.

## 6. Endpoint

Endpoint 6.1–6.7 adalah API BRAS awal (Fase 2 langkah 1–3). Endpoint 6.8–6.94 adalah perluasan baca-semua-menu CLI (25 Nov 2026): D1 system/config/checkpoints (§6.8–6.22), D2 interfaces/IP/routes (§6.23–6.32), D3 BIRD/routing-protocols (§6.33–6.73), D4a firewall/WireGuard (§6.74–6.79), D4b traffic-shape/BRAS/monitoring (§6.80–6.94). Semua endpoint baru GET saja, di belakang bearer token + rate-limit yang sama (§4); kontrak umum di §5 berlaku untuk semuanya (envelope, snake_case, paginasi `?limit=`/`?offset=`, cap 2000 baris, baris gagal-parse → `raw` + `meta.warnings`). Endpoint tulis tetap yang lama (disconnect/isolate/unisolate, §6.4–6.6); usulan tulis baru dicatat di catatan tiap domain, tidak diimplementasikan.

### 6.1 `GET /api/v1/health`

```http
GET /api/v1/health
Authorization: Bearer <token>
```

Respons sukses (200):

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

Field yang tidak bisa dibaca bernilai `null` (bukan error).

### 6.2 `GET /api/v1/sessions`

```http
GET /api/v1/sessions?sort=usage&sample=2&limit=100&offset=0
Authorization: Bearer <token>
```

Query:

| Param | Default | Arti |
|---|---|---|
| `sort` | `usage` | `usage` (rx+tx desc) \| `user` \| `ip` \| `uptime` |
| `sample` | `2` | detik sampling counter bandwidth (0–5; 0 = tanpa rate, bps 0) |
| `limit` | `100` | 1–1000 |
| `offset` | `0` | >= 0 |

Satu sesi (objek):

| Field | Tipe | Arti |
|---|---|---|
| `id` | string | `pppoe-<user>` atau `ipoe-<mac-tanpa-titik-dua>` |
| `type` | string | `pppoe` \| `ipoe` |
| `user` | string | username PPPoE, atau MAC (IPoE) |
| `ip` | string | Framed-IP / IP lease |
| `mac` | string\|null | MAC (IPoE saja) |
| `interface` | string\|null | interface ng* (PPPoE saja) |
| `uptime_seconds` | int\|null | lama sesi; PPPoE `null` (ng* tidak membawa starts) |
| `rx_bps` / `tx_bps` | int | download / upload live (bit/detik) |
| `rx_bytes_total` / `tx_bytes_total` | int\|null | total byte counter (null bila sumber counter tidak ada) |
| `rate_source` | string | `ng` (netstat ng*) \| `pf` (pf rule counter) \| `none` |
| `isolated` | bool | sedang diisolir? |

Respons sukses (200, contoh — nilai bps contoh):

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

Error: `sort` tidak dikenal → 400 `validation_error`.

### 6.3 `GET /api/v1/sessions/:id`

```http
GET /api/v1/sessions/pppoe-agus?sample=2
Authorization: Bearer <token>
```

Respons sukses (200): `{ "status": "ok", "data": { "session": {...} },
"meta": { "warnings": [] } }` (objek sesi sama seperti §6.2).

Error: id tidak ada → 404 `not_found`; id tidak valid → 400
`validation_error`.

### 6.4 `POST /api/v1/sessions/:id/disconnect` (kick)

```http
POST /api/v1/sessions/pppoe-agus/disconnect
Authorization: Bearer <token>
Content-Type: application/json

{ "reason": "tunggakan 2 bulan" }
```

- `reason` **wajib** (string, 1–200 karakter) — alasan kick tercatat
  di audit syslog. Tanpa reason → 400 `validation_error`.
- PPPoE: `titian-pppoe.sh disconnect <user> <framed-ip>` — tutup sesi
  lewat konsol mpd5 (LCP graceful, Opsi A). IPoE: `titian-dhcp.sh
  kick-lease <mac>` — lepas lease; user boleh reconnect (bukan
  blokir). Blokir MAC penuh (`kick`) tetap CLI / remote-kick saja.
- Sesudah backend sukses, API **memverifikasi** sesi benar-benar
  hilang dari daftar; bila masih ada → 500 `internal_error`.

Respons sukses (200):

```json
{ "status": "ok",
  "data": { "session_id": "pppoe-agus", "type": "pppoe", "user": "agus",
            "ip": "10.99.42.101", "action": "disconnect",
            "reason": "tunggakan 2 bulan", "verified": true },
  "meta": {} }
```

### 6.5 `POST /api/v1/sessions/:id/isolate` (isolir)

```http
POST /api/v1/sessions/pppoe-agus/isolate
Authorization: Bearer <token>
Content-Type: application/json

{ "reason": "tunggakan 2 bulan" }
```

- `reason` wajib (seperti §6.4).
- Syarat: `isolir-web` terisi di config (bila kosong → 400
  `validation_error`), dan firewall **enable** + pf **jalan**
  (bila belum → 400 `validation_error` — jalankan `firewall enable` +
  commit di klish dulu).
- Efek: DUA rule dst-nat pf — `rdr proto tcp from <ip> to any port 80
  -> <web-isolir> port <port>` DAN `rdr proto tcp from <ip> to any
  port 443 -> <web-isolir> port <port>` (keduanya ke port web server).
  TIDAK ADA blokir 443. Tercatat di `/usr/local/etc/isolated.conf`
  (persisten melewati reboot — apply ulang saat boot via rc.d/firewall).
  **Dummynet TIDAK disentuh** — kapasitas bandwidth user tetap profil
  paket; isolir bukan pipe kecil.
- Konsekuensi: klien HTTPS (TCP 443) yang dialihkan ke web server port
  80 menerima respons **HTTP polos, bukan TLS** — browser menampilkan
  galat sertifikat/koneksi, bukan halaman isolir yang rapi. Ini
  konsekuensi desain yang diminta (dst-nat 443 → 80), bukan bug.
  Klien HTTP (TCP 80) melihat halaman isolir normal.
- Idempotent: isolate IP yang sudah terisolir tetap 200.
- Verifikasi: IP benar-benar ada di daftar isolir, bila tidak → 500.

Respons sukses (200):

```json
{ "status": "ok",
  "data": { "session_id": "pppoe-agus", "type": "pppoe", "user": "agus",
            "ip": "10.99.42.101", "action": "isolate",
            "isolir_web": "103.50.129.84:80",
            "reason": "tunggakan 2 bulan", "verified": true },
  "meta": {} }
```

### 6.6 `POST /api/v1/sessions/:id/unisolate` (cabut isolir)

```http
POST /api/v1/sessions/pppoe-agus/unisolate
Authorization: Bearer <token>
Content-Type: application/json

{ "reason": "sudah lunas" }
```

- `reason` wajib. Idempotent (IP yang tidak terisolir tetap 200,
  `was_isolated: false`). Verifikasi: IP benar-benar hilang dari
  daftar isolir.

Respons sukses (200):

```json
{ "status": "ok",
  "data": { "session_id": "pppoe-agus", "type": "pppoe", "user": "agus",
            "ip": "10.99.42.101", "action": "unisolate",
            "reason": "sudah lunas", "was_isolated": true,
            "verified": true },
  "meta": {} }
```

### 6.7 `GET /api/v1/nas/status`

```http
GET /api/v1/nas/status
Authorization: Bearer <token>
```

Respons sukses (200):

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

### 6.8 `GET /api/v1/system/version` — versi (Tier S)

Backend: `get_versions()` yang sama dengan `/health` (`pkg info titian` +
`titian-bird.sh show-version`).

Skema `data`: `api_version` (string), `titian_version` (string|null),
`bsdrp_version` (string|null), `bird_variant` (string|null, mis. `"BIRD 2"`),
`bird_version` (int|null), `frr_version` (string|null,
mis. `"10.7.1 (not running)"`), `time_utc` (string ISO 8601 UTC).

```http
GET /api/v1/system/version
```

```json
{"status": "ok", "data": {"api_version": "1.0.0", "titian_version": "0.1.1",
"bsdrp_version": "n314296", "bird_variant": "BIRD 2", "bird_version": 2,
"frr_version": "10.7.1 (not running)", "time_utc": "2026-11-25T05:00:00Z"},
"meta": {"warnings": []}}
```

Error: tanpa token → 401 `unauthorized`; token salah → 403 `forbidden`.

### 6.9 `GET /api/v1/system` — ringkasan sistem (Tier S)

Backend: `titian-sys.sh summary` (label `Label......: nilai`, FreeBSD
maupun Linux). `time_utc` diisi daemon.

Skema `data`: `hostname`, `os`, `kernel`, `kernel_build`, `architecture`,
`time_local`, `time_wib`, `uptime` (string apa adanya, mis.
`"10 days, 3:12"`), `cpu` (string), `cpu_count` (int|null, dari
`"(N CPU)"`), `memory_used_mb`/`memory_total_mb` (int|null),
`load_average` ([float ×3]|null), `disk_root` (`{used, total, use_percent}`|null,
dari baris `Disk (/)`), `titian_cli`, `bird`, `time_utc`, `extra` (dict
label→nilai untuk label yang tidak dipetakan).

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

Error: backend gagal → 500 `internal_error`.

### 6.10 `GET /api/v1/system/memory` — memori (Tier S)

Backend: `titian-sys.sh memory`. FreeBSD: `sysctl hw.physmem/hw.usermem`
(byte) + `vmstat -s`; Linux: `free -h`.

Skema `data`: `total_bytes`, `used_bytes`, `free_bytes`,
`available_bytes`, `shared_bytes`, `buffers_cache_bytes`,
`swap_total_bytes`, `swap_used_bytes`, `swap_free_bytes` (int|null),
`source` (`"freebsd"`|`"linux"`|`"unknown"`), `vmstat_lines` (list string
mentah `vmstat -s`, hanya FreeBSD). FreeBSD: `used_bytes =
physmem - usermem`; `available_bytes = hw.usermem` (memori yang tersedia
untuk proses user); `free_bytes` null (tidak ada angka free yang sebanding
di output ini).

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

### 6.11 `GET /api/v1/system/processes` — proses (Tier S, paginasi)

Backend: `titian-sys.sh process` (FreeBSD `ps aux`, Linux `ps axf`).

Skema item: `user` (string|null — Linux `ps axf` tidak membawa user),
`pid` (int), `cpu_percent`/`mem_percent` (float|null),
`vsz_kb`/`rss_kb` (int|null), `tty`, `state`, `started` (string|null),
`time` (string), `command` (string). Baris gagal parse → `{"raw": ...}`.

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

Error: `?limit=0` / `?limit=2000` → 400 `validation_error`.

### 6.12 `GET /api/v1/system/connections` — koneksi (Tier S, paginasi)

Backend: `titian-sys.sh connections` (FreeBSD `netstat -an`, Linux `ss -tunap`).

Skema item: `protocol` (mis. `"tcp4"` / `"tcp"` netid ss), `state`
(string|null — UDP netstat tidak punya state), `recv_q`/`send_q`
(int|null), `local_address`, `foreign_address`, `process` (string|null —
hanya `ss`). Bagian "Active UNIX domain sockets" pada `netstat -an`
sengaja tidak di-parse (bukan koneksi internet).

```http
GET /api/v1/system/connections?limit=1&offset=1
```

```json
{"status": "ok", "data": {"connections": [
{"protocol": "tcp4", "recv_q": 0, "send_q": 0, "local_address": "*.8443",
"foreign_address": "*.*", "state": "LISTEN", "process": null}]},
"meta": {"total": 3, "count": 1, "limit": 1, "offset": 1, "warnings": []}}
```

### 6.13 `GET /api/v1/system/storage` — storage (Tier S, paginasi)

Backend: subcommand BARU `titian-sys.sh storage` (D1, read-only, hanya
`df -h`): satu baris per filesystem, pipe-delimited tanpa header:
`filesystem|size|used|avail|use_pct|mounted_on`.

Skema item: `filesystem`, `size`, `used`, `available` (string `df -h`,
mis. `"7.9G"`), `use_percent` (int|null), `mounted_on`,
`size_bytes`/`used_bytes`/`available_bytes` (int|null, hasil parse
ukuran manusia → byte; null bila tidak bisa di-parse).

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

### 6.14 `GET /api/v1/system/sysctl` — sysctl yang dikelola Titian (Tier S, paginasi)

Backend: `titian-sysctl.sh show`: per kunci
`"  key = live  (tersimpan: saved)"` + baris `"    arti: ..."`.
State kosong → list kosong (200), bukan 404.

Skema item: `key`, `value_live`, `value_saved` (string — nilai vektor
berspasi seperti `"4096 87380 6291456"` tetap string), `meaning`
(string|null). Baris gagal parse → `{"key": null, ..., "raw": ...}`.

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

### 6.15 `GET /api/v1/system/logins` — login aktif (Tier S, paginasi)

Backend: `w -h` argv langsung (perintah baca sistem, tanpa argumen dari
web). Kolom: `USER TTY FROM LOGIN@ IDLE JCPU PCPU WHAT` (`WHAT` boleh
kosong). Parse best-effort; baris gagal parse → `{"raw": ...}` + warning.

Skema item: `user`, `tty`, `from`, `login`, `idle`, `jcpu`, `pcpu`,
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

Backend: `titian-sys.sh cpu` + `dmi` + `pci` (3 seksi). Tiap seksi:
`text` (string mentah), `lines` (int), `truncated` (bool, cap 2000 baris),
`lines_total` (int), `error` (string|null). Satu seksi gagal → seksi itu
`error` terisi + `meta.warnings`, seksi lain tetap dikembalikan (200).
Ketiga seksi gagal → 500 `internal_error`.

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

### 6.17 `GET /api/v1/services` — daftar service (Tier S, paginasi)

Backend: `titian-sys.sh services`. FreeBSD: `service -e` (satu path rc
per baris → `status: "enabled"`). Linux: `service --status-all`
(`[ + ]` → `"running"`, `[ - ]` → `"stopped"`, `[ ? ]` → `"unknown"`).
Diurutkan menurut nama.

Skema item: `name`, `status` (`"enabled"`|`"running"`|`"stopped"`|
`"unknown"`|null), `raw` (baris asli).

```http
GET /api/v1/services?limit=1
```

```json
{"status": "ok", "data": {"services": [
{"name": "bird", "status": "enabled", "raw": "/etc/rc.d/bird"}]},
"meta": {"total": 3, "count": 1, "limit": 1, "offset": 0, "warnings": []}}
```

### 6.18 `GET /api/v1/services/:name` — status satu service (Tier S)

Backend: `titian-sys.sh service-status <name>`. Nama divalidasi
`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$` (di luar itu → 400
`validation_error`). Status dibaca dari teks: mengandung `"not running"`
/ `"stop/waiting"` → `"stopped"`; `"is running"` / `"start/running"` /
`"active (running)"` → `"running"`; selain itu `"unknown"`. FreeBSD:
`service X status` keluar rc 1 bila service berhenti — itu tetap 200
`"stopped"`, bukan error. Service tidak dikenal (teks `"does not exist"`
/ `"unknown service"` / `"not found"` / `"no such"`) → 404 `not_found`.

Skema `data`: `name`, `status`, `text` (output backend mentah),
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

### 6.19 `GET /api/v1/services/ssh` — state SSH service (Tier S)

Backend: `titian-sys.sh service-ssh` (baca `/etc/ssh/sshd_config` baris
uncommented terakhir menang + status proses sshd). Bila sshd tidak
terinstal → 200 `{"available": false, "reason": ...}` (bukan 500).

Skema `data`: `name` (`"ssh"`), `sshd_running` (bool|null),
`sshd_pid` (int|null), `port` (int|null), `permit_root_login`
(string|null), `use_dns` (string|null), `listen` (list string, mis.
`["0.0.0.0:22", "[::]:22"]`).

```http
GET /api/v1/services/ssh
```

```json
{"status": "ok", "data": {"name": "ssh", "sshd_running": true, "sshd_pid": 123,
"port": 22, "permit_root_login": "prohibit-password", "use_dns": "no",
"listen": ["0.0.0.0:22", "[::]:22"]}, "meta": {"warnings": []}}
```

### 6.20 `GET /api/v1/config/running` — running-config (Tier T, redaksi wajib)

Backend: `titian-checkpoint.sh dump-running <tmpfile>` — BUKAN
`titian-show-config.sh running`, karena script itu hanya men-cat file
dump `/tmp/titian-show-run.conf` yang ditulis klish `<CONFIG
operation="dump">` di ACTION `show running-config`; dari API file itu
basi/kosong. `dump-running` adalah jalur baca yang sama dengan
`checkpoint save` (konf dump → batch clish `show running-config` →
fallback startup-config); sudah diverifikasi read-only dari sumber
`titian-checkpoint.sh` (hanya menulis ke file tmp yang diberikan daemon).
Catatan: dump ini membuang baris stempel (`! version` / `! last commit`)
dan memastikan terminator `end` — sama seperti checkpoint. Bila dump live
gagal dan fallback ke startup-config, `meta.warnings` berisi peringatan
itu. Bila dump live gagal DAN tidak ada startup-config (router belum
pernah di-save): 200 dengan `data.available: false`, `config_text: ""`,
`lines: 0`, dan `note` berisi arahan commit + save — bukan 500
(perbaikan pasca-verifikasi guest 25 Nov 2026, T2).

Redaksi WAJIB: tiap baris cocok `/password|secret|token|passwd/i`
diganti `# <redacted>` SEBELUM masuk respons. Cap 5000 baris
(`meta.truncated` + `meta.lines_total` bila terpotong).

Skema `data`: `config_text` (string), `lines` (int),
`source` (`"show running-config"`). Meta tambahan: `redacted_lines` (int).

```http
GET /api/v1/config/running
```

```json
{"status": "ok", "data": {"config_text": "!\ninterface vlan 101 vtnet0\n  description uplink\n# <redacted>\n  exit\n# <redacted>\nend",
"lines": 7, "source": "show running-config"},
"meta": {"warnings": [], "truncated": false, "lines_total": 7, "redacted_lines": 2}}
```

### 6.21 `GET /api/v1/config/startup` — startup-config (Tier T, redaksi wajib)

Backend: `titian-show-config.sh startup no-more` (men-cat
`$TITIAN_STATE_ROOT/startup-config` lewat pager; non-TTY → cat).
Redaksi + cap sama seperti §6.20. Bila file belum ada, backend
mengembalikan pesan `(startup-config kosong — ...)` rc 0 (200, bukan 404).

Skema `data`: `config_text`, `lines`, `source` (`"show startup-config"`).
Meta tambahan: `redacted_lines`.

```http
GET /api/v1/config/startup
```

```json
{"status": "ok", "data": {"config_text": "! version 0.1.1\n! last commit: 2026-11-24 10:00:00 WIB\n!\nhostname titian-mock\ninterface vlan 101 vtnet0\n  description uplink\n# <redacted>\n  exit\nend",
"lines": 9, "source": "show startup-config"},
"meta": {"warnings": [], "truncated": false, "lines_total": 9, "redacted_lines": 1}}
```

### 6.22 `GET /api/v1/checkpoints` — daftar checkpoint (Tier S, paginasi)

Backend: `titian-checkpoint.sh list` (header `Name  DIBUAT (WIB)  SAAT INI`,
baris `nama  YYYY-MM-DD HH:MM:SS WIB  [*]`; `*` = isi titik sama persis
dengan running-config saat ini; footer `* = ...`). Belum ada checkpoint →
list kosong (200). Nama tanpa meta → `created_wib: null`.

Skema item: `name`, `created_wib` (string `"YYYY-MM-DD HH:MM:SS WIB"`|null),
`current` (bool). Baris gagal parse → `{"name": null, "created_wib": null,
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

**Yang tidak diekspos D1.**

`show date` (sudah ada `time_utc` di health + §6.8/§6.9), `show pwd`,
`show history`, `show help` (lokal-CLI), `show system top` (layar
transient), `show configuration` (hanya mencetak path bird.conf).

**Perubahan `check` + backend baru.**

- `titian-api.py check` kini juga memeriksa `titian-sys.sh`,
  `titian-sysctl.sh`, `titian-checkpoint.sh`, `titian-show-config.sh`
  dan tool `w`.
- Subcommand backend baru (satu-satunya): `titian-sys.sh storage`
  (format di §6.13; read-only, hanya `df -h`).


**D2 — interfaces / IP / routes.**

### 6.23 `GET /api/v1/interfaces`

```http
GET /api/v1/interfaces
GET /api/v1/interfaces?terse=true
GET /api/v1/interfaces?limit=2&offset=4
Authorization: Bearer <token>
```

Query:

| Param | Default | Arti |
|---|---|---|
| `terse` | `false` | `true` = tabel `titian-show.sh terse` (admin/link per interface); `false` = tabel `titian-show.sh interfaces` |
| `include_down` | `false` | diterima tapi no-op: daftar SELALU memuat interface up+down |
| `limit` | `100` | 1–1000 |
| `offset` | `0` | >= 0 |

Backend: `titian-show.sh interfaces` (FreeBSD: `ifconfig -a`; Linux:
`ip -o addr`). Varian `terse`/`all` di CLI adalah presentasi dari data
yang sama: `terse` diekspos lewat `?terse=true`; `all` (blok detail per
interface) TIDAK diekspos — pakai `GET /api/v1/interfaces/:name`.

Satu interface (objek):

| Field | Tipe | Arti |
|---|---|---|
| `name` | string | nama interface (`ge1`, `bridge0`, `vxlan100`, `lo0`) |
| `state` | string\|null | `up` \| `down` \| `loopback` |
| `state_code` | string\|null | kode CLI: `u` \| `D` \| `L` |
| `admin` | string\|null | `up` \| `disabled` (hanya mode terse; default `null`) |
| `link` | string\|null | `up` \| `down` (hanya mode terse; default `null`) |
| `addresses` | array | alamat (lihat bawah; alamat lanjutan dari baris kosong-nama digabung ke interface yang sama) |
| `description` | string\|null | deskripsi interface (kolom Description; terse: `null`) |
| `raw` | string | hanya bila baris gagal di-parse (bersama `meta.warnings`) |

Satu alamat (objek di `addresses`):

| Field | Tipe | Arti |
|---|---|---|
| `address` | string | alamat IP (tanpa prefix; zona `%iface` dipisah ke `zone`) |
| `prefix_length` | int\|null | panjang prefix (`/64` dst); `null` bila tabel tidak membawanya (inet IPv4 FreeBSD dicetak tanpa prefix) |
| `family` | string\|null | `ipv4` \| `ipv6` |
| `peer` | string\|null | peer PtP (`inet A peer B`) |
| `zone` | string\|null | zona link-local (`fe80::1%vxlan100` → `vxlan100`) |

Respons sukses (200):

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

Error: `terse` bukan boolean → 400 `validation_error`.

### 6.24 `GET /api/v1/interfaces/:name`

```http
GET /api/v1/interfaces/ge1
GET /api/v1/interfaces/ge1?detail=true
Authorization: Bearer <token>
```

Backend: `titian-show.sh if-detail <iface> [detail]` (FreeBSD:
`ifconfig <iface>`; Linux: `ip -d link show` + `ip -d addr show`).
`?detail=true` meneruskan argumen `detail` CLI (FreeBSD: catatan
hardware tidak tersedia, hanya pesan; Linux: `ethtool` + `udevadm`
bila ada).

Satu interface (objek `data.interface`):

| Field | Tipe | Arti |
|---|---|---|
| `name` | string | nama interface |
| `state` | string | `up` \| `down` \| `loopback` |
| `state_code` | string | `u` \| `D` \| `L` |
| `admin` | string | `up` (flag UP) \| `disabled` |
| `link` | string\|null | `up` \| `down`; `null` bila tidak bisa ditentukan (tanpa baris `status:` dan tanpa flag RUNNING/LOWER_UP) |
| `mtu` | int\|null | MTU |
| `mac` | string\|null | alamat ether (`link/ether` / `ether`) |
| `flags` | array | daftar flag (`UP`, `BROADCAST`, `RUNNING`, …) |
| `addresses` | array | alamat (skema sama seperti §6.23; `prefix_length` diisi dari `netmask` hex / `prefixlen` / `/N`) |
| `description` | string\|null | baris `description:` |
| `media` | string\|null | baris `media:` (FreeBSD) |
| `status` | string\|null | baris `status:` (`active`, …) |
| `options` | string\|null | baris `options=<...>` (FreeBSD) |
| `groups` | array | baris `groups:` |
| `extra_lines` | array | baris ifconfig/ip lain yang tidak diparse (info, bukan error) |

Respons sukses (200):

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

Error: interface tidak ada → 404 `not_found`; nama tidak cocok
`^[A-Za-z0-9_.-]{1,32}$` → 400 `validation_error`.

### 6.25 `GET /api/v1/interfaces/:name/tuning` (Tier T)

```http
GET /api/v1/interfaces/ge1/tuning
Authorization: Bearer <token>
```

Backend: `titian-tune.sh show <iface>` (read-only: baca nilai live +
file `.tuning`). Tier T — teks apa adanya, karena isinya penjelasan
per knob (mtu, qlen, offload, coalesce) bukan record.

Respons sukses (200):

```json
{ "status": "ok",
  "data": { "interface": "ge1",
            "config_text": "Tuning ge1 (FreeBSD) — value live + arti singkat\n  mtu*: 9000 — ...\n",
            "lines": 10,
            "source": "show interfaces tuning ge1" },
  "meta": { "warnings": [] } }
```

Error: interface tidak ada → 404 `not_found`; nama tidak valid → 400
`validation_error`.

### 6.26 `GET /api/v1/neighbors`

```http
GET /api/v1/neighbors
GET /api/v1/neighbors?interface=ge1
Authorization: Bearer <token>
```

Query:

| Param | Default | Arti |
|---|---|---|
| `interface` | — | filter exact-match nama interface (validasi `^[A-Za-z0-9_.-]{1,32}$`) |
| `limit` / `offset` | `100` / `0` | paginasi |

Backend: `titian-show.sh neighbor` (FreeBSD: `arp -a`; Linux:
`ip -d neighbor show`). Filter dilakukan di daemon (exact match):
backend FreeBSD mem-filter dengan `grep -F` (substring) sehingga tidak
dipakai untuk filter.

Satu neighbor (objek):

| Field | Tipe | Arti |
|---|---|---|
| `ip` | string\|null | alamat IP tetangga |
| `mac` | string\|null | MAC (`null` bila `(incomplete)` / FAILED tanpa lladdr) |
| `interface` | string\|null | interface |
| `state` | string\|null | FreeBSD: `complete` \| `incomplete` \| `permanent` \| `expired`; Linux: `reachable` \| `stale` \| `delay` \| `probe` \| `failed` \| `incomplete` \| `permanent` \| `noarp` |
| `expires_seconds` | int\|null | sisa umur entri ARP (FreeBSD saja; Linux `null`) |
| `family` | string\|null | `ipv4` \| `ipv6` |
| `raw` | string | hanya bila baris gagal di-parse |

Respons sukses (200):

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

Error: `interface` tidak valid → 400 `validation_error`. Filter yang
tidak cocok = 200 + list kosong (bukan 404).

### 6.27 `GET /api/v1/bridges`

```http
GET /api/v1/bridges
GET /api/v1/bridges?bridge=bridge0
Authorization: Bearer <token>
```

Query:

| Param | Default | Arti |
|---|---|---|
| `bridge` | — | nama bridge `bridge[N]` (contoh `bridge0`); tanpa param = semua bridge |
| `limit` / `offset` | `100` / `0` | paginasi |

Backend: `titian-bridge.sh show [bridge]` (read-only: `ifconfig`).
Satu bridge (objek):

| Field | Tipe | Arti |
|---|---|---|
| `name` | string | nama bridge |
| `flags` | string\|null | isi baris `flags=...` |
| `mac` | string\|null | alamat ether bridge |
| `addresses` | array | alamat `inet`/`inet6` (skema §6.23) |
| `members` | array | anggota: `{ "interface": string, "flags": string }` |
| `unparsed_lines` | array | baris blok yang tidak dikenal (bila ada) |

Respons sukses (200):

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

Error: bridge tidak ada → 404 `not_found`; `?bridge=` bukan
`bridge[N]` → 400 `validation_error`. Tanpa bridge sama sekali = 200 +
list kosong.

### 6.28 `GET /api/v1/vxlan`

```http
GET /api/v1/vxlan
Authorization: Bearer <token>
```

Backend: `titian-vxlan.sh show` (read-only: `ifconfig`/`ip` +
`sysctl` FDB). Skema objek sama seperti §6.29. Tanpa interface vxlan
= 200 + list kosong.

### 6.29 `GET /api/v1/vxlan/:name`

```http
GET /api/v1/vxlan/vxlan100
Authorization: Bearer <token>
```

Backend: `titian-vxlan.sh show <name>`.

Satu vxlan (objek `data.vxlan`):

| Field | Tipe | Arti |
|---|---|---|
| `name` | string | nama interface (`vxlan100`) |
| `state` | string | `up` \| `down` |
| `mtu` | int\|null | MTU |
| `vni` | int\|null | VNI (`null` bila `?`) |
| `local` | string\|null | alamat lokal VTEP (`null` bila `?`/tidak diset) |
| `remote` | string\|null | peer unicast (`null` bila mode group / tanpa peer) |
| `group` | string\|null | alamat multicast group (`null` bila mode unicast) |
| `dev` | string\|null | interface underlay (mode group, Linux saja) |
| `dstport` | int\|null | UDP dstport (FreeBSD selalu 4789) |
| `addresses` | array | alamat `inet`/`inet6` (skema §6.23) |
| `fdb` | array | entri FDB mentah (string per baris; `[]` bila `(kosong)`) |
| `unparsed_lines` | array | baris blok yang tidak dikenal (bila ada) |

Respons sukses (200):

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

Error: vxlan tidak ada → 404 `not_found`; nama bukan `vxlan[N]` → 400
`validation_error`.

### 6.30 `GET /api/v1/routes`

```http
GET /api/v1/routes
GET /api/v1/routes?family=ipv6&prefix=2001:db8::/32
Authorization: Bearer <token>
```

Query:

| Param | Default | Arti |
|---|---|---|
| `family` | `ipv4` | `ipv4` \| `ipv6` |
| `prefix` | — | IP atau CIDR; keluarga prefix HARUS cocok dengan `family` |
| `limit` / `offset` | `100` / `0` | paginasi |

Backend: `titian-show.sh route [prefix]` / `route6 [prefix]`
(FreeBSD: `netstat -rn -f inet|inet6`, di-grep bila prefix diisi;
Linux: `ip route show [prefix]`). Catatan: di FreeBSD, `route
<prefix>` mengembalikan HANYA baris yang cocok (tanpa header) —
parser daemon mendeteksi format dari bentuk baris, bukan header.
Prefix yang tidak cocok = 200 + list kosong (bukan 404).

Satu route (objek; SEMUA kunci selalu hadir, `null` bila tidak ada di
sumber):

| Field | Tipe | Arti |
|---|---|---|
| `destination` | string | prefix tujuan (`default`, `10.10.2.0/24`, `2001:db8::/32`) |
| `gateway` | string\|null | nexthop (FreeBSD: `link#N` untuk route terhubung langsung; Linux: nilai `via`) |
| `flags` | string\|null | flags netstat (`UGS`, `U`, `UH` — FreeBSD saja) |
| `interface` | string\|null | interface keluar |
| `expire_seconds` | int\|null | kolom Expire netstat (FreeBSD saja) |
| `family` | string | `ipv4` \| `ipv6` |
| `protocol` | string\|null | `proto` (Linux saja: `kernel`, `static`, `bird`, …) |
| `metric` | int\|null | metric (Linux saja) |
| `scope` | string\|null | scope (Linux saja) |
| `src` | string\|null | `src` (Linux saja) |
| `type` | string | `unicast` (default) \| `local` \| `blackhole` \| `unreachable` \| `prohibit` \| `broadcast` \| `throw` (Linux) |
| `link_down` | bool | `linkdown` (Linux saja) |
| `onlink` | bool | `onlink` (Linux saja) |

Respons sukses (200):

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

Error: `family` bukan `ipv4|ipv6` → 400; `prefix` bukan IP/CIDR sah
→ 400; keluarga prefix ≠ `family` → 400 `validation_error`.

### 6.31 `GET /api/v1/routing` (Tier T)

```http
GET /api/v1/routing
Authorization: Bearer <token>
```

Backend: `titian-bird.sh show-routing` (read-only: status daemon
BIRD vs FRR). Tier T — dua baris status, bukan record.

Respons sukses (200):

```json
{ "status": "ok",
  "data": { "config_text": "Routing daemon: BIRD 2.20.0 (bird2, enabled, running, pid 123)\nFRR: 10.7.1 (no, not running)\n",
            "lines": 2,
            "source": "show routing" },
  "meta": { "warnings": [] } }
```

BIRD tidak terpasang pun tetap 200 (teks menyatakan
`BIRD not installed`).

### 6.32 `GET /api/v1/routing/static` (Tier T)

```http
GET /api/v1/routing/static
Authorization: Bearer <token>
```

Backend: `titian-static.sh show` (read-only: isi `static.conf`
intent + section `bird.d/static.conf` + `birdc show protocol
static`). Tier T — tiga seksi teks; JANGAN dicampur dengan route
kernel (`GET /api/v1/routes`): route static BIRD hidup di tabel
routing BIRD dan hanya masuk kernel bila channel kernel mengekspornya.

Respons sukses (200):

```json
{ "status": "ok",
  "data": { "config_text": "--- static.conf (intent) ---\ncheck-link on\nroute 10.99.44.0/24 via 10.10.2.1\nroute 203.0.113.0/24 blackhole\n--- bird.d/static.conf (section, bila ada) ---\nprotocol static static4 {\n    check link;\n    ipv4;\n    route 10.99.44.0/24 via 10.10.2.1;\n    route 203.0.113.0/24 blackhole;\n}\n--- birdc show protocol static ---\nName       Proto      Table      State  Since         Info\nstatic4    Static     master4    up     2026-11-24\n",
            "lines": 15,
            "source": "show static" },
  "meta": { "warnings": [] } }
```

**Catatan D2 (tidak diekspos).**

- `show interfaces all` — blok detail per interface; tercakup
  `GET /api/v1/interfaces/:name`.
- `show interfaces bird` / `show interfaces bird summary` — domain D3
  (`GET /api/v1/bird/interfaces`).
- `show interfaces ethernet|vlan|lagg <iface>` — alias dari if-detail;
  tercakup `GET /api/v1/interfaces/:name`.
- `show route` (BIRD) — domain D3 (`GET /api/v1/bird/routes`), bukan
  route kernel `GET /api/v1/routes`.

**Asumsi yang perlu verifikasi guest (koordinator, bhyve).**

1. Format tabel `titian-show.sh interfaces`/`terse` — diparse dari
   sumber script (printf fixed-width + awk ifconfig); belum diuji
   dengan `ifconfig -a` asli. Risiko utama: alamat IPv6 panjang
   (>19 kolom) menggeser kolom — parser memakai token, bukan posisi
   kolom, sehingga aman terhadap geseran itu.
2. Format `arp -a` FreeBSD dan `netstat -rn` FreeBSD — diparse dari
   format standar kedua perintah itu; belum diuji live.
3. Baris FDB `titian-vxlan.sh show` FreeBSD (`sysctl
   net.link.vxlan.N.ftable.dump`) — format pastinya belum diketahui;
   parser memperlakukan tiap baris FDB sebagai string mentah.
4. Cabang parser Linux (`ip route`, `ip neigh`, `ip -d link`) —
   diuji unit langsung pada fungsi parser (mock test §17b), BUKAN
   lewat HTTP; di guest BSDRP yang berjalan adalah cabang FreeBSD.


**D3 — BIRD / routing-protocols.**

**Kontrak D3.** Envelope, snake_case, paginasi, cap 2000 baris, dan `raw`+`warnings` sama seperti §5. Khusus D3: subsistem tidak jalan (BIRD down / FRR down) → HTTP 200 dengan `{"available": false, "reason": "..."}` — BUKAN 500. List kosong = 200 dengan list kosong.

**BIRD — BGP.**

### 6.33 `GET /api/v1/bird/bgp` — Tier T

CLI: `show bgp`. Backend: `titian-bgp.sh show` (mencetak intent
`bgp.conf`).

Contoh sukses: bentuk Tier T di atas, `"source": "show bgp"`.

### 6.34 `GET /api/v1/bird/bgp/summary` — Tier S

CLI: `show bgp summary`. Backend: `titian-birdc.sh show-bgp-summary`
(KOMPOSISI klish — BUKAN perintah birdc asli; BIRD tidak punya
`show bgp summary`. Per neighbor dari intent `bgp.conf`:
`birdc show protocols all <proto>` + `birdc show route protocol
<proto> count`).

Skema `data.neighbors[]`:

| Field | Tipe | Arti |
|---|---|---|
| `neighbor` | string | IP neighbor |
| `protocol` | string | nama protokol BIRD |
| `state` | string\|null | state protokol (`up`, …) |
| `since` | string\|null | sejak kapan (birdc) |
| `info` | string\|null | info birdc (`Established`, …) |
| `routes` | int\|null | jumlah rute dari `show route protocol <proto> count` |
| `routes_total` | int\|null | total rute (kolom "of N") |
| `networks` | int\|null | jumlah network |

Contoh:

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

Belum ada neighbor BGP di `bgp.conf` → 200 + `"neighbors": []`.

**BIRD — protokol.**

### 6.35 `GET /api/v1/bird/protocols` — Tier S

CLI: `show protocols` (+`all`). Backend: `titian-birdc.sh
show-protocols` / `show-protocols-all`. Query: `?all=true`
(detail per protokol), paginasi.

Skema `data.protocols[]`:

| Field | Tipe | Arti |
|---|---|---|
| `name` | string | nama protokol |
| `protocol` | string | jenis (`BGP`, `OSPF`, `Device`, `Kernel`, …) |
| `table` | string | tabel (`---` bila tidak ada) |
| `state` | string | state (`up`, `down`, …) |
| `since` | string\|null | sejak kapan |
| `info` | string | info birdc |
| `details` | string[] | (hanya `?all=true`) baris detail menjorok |
| `raw` | string | (hanya bila baris gagal parse) baris apa adanya |

Contoh:

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
(tanpa argumen — subcommand `show-protocols` yang sudah ada; TIDAK ADA
subcommand backend baru). Mengembalikan daftar yang sama dengan
`/bird/protocols` + hitungan.

Skema `data`: `{"available": true, "protocols": [...],
"counts": {"total": 4, "by_state": {"up": 4},
"by_protocol": {"BGP": 1, "OSPF": 1, "Device": 1, "Kernel": 1}}}`.

### 6.37 `GET /api/v1/bird/protocols/:name` — Tier S

CLI: `show protocol neighbors`. Backend: `titian-birdc.sh
show-protocols <nama>`. `:name` harus `[A-Za-z0-9_]{1,64}`.

Bila BIRD tidak jalan: 200 `available: false` untuk nama apa pun
(keberadaan protokol tidak bisa dipastikan — pola subsystem-down; bukan
404). Bila BIRD jalan dan nama tidak ada: 404 `not_found` (keputusan
pasca-verifikasi guest 25 Nov 2026, T4).

Skema `data.protocol`: field tabel protokol di atas +

| Field | Tipe | Arti |
|---|---|---|
| `details` | object | baris detail `Key: value` → `snake_case` (mis. `bgp_state`, `neighbor_address`, `neighbor_as`, `local_as`) |
| `channels` | object | per channel (`ipv4`, …): `state`, `table`, `preference`, `input_filter`, `output_filter`, `routes` (string apa adanya, mis. `"5 imported, 0 exported, 5 preferred"`) |
| `detail_lines` | string[] | baris detail lain yang bukan `Key: value` (bila ada) |

Contoh (ringkas):

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

Error: protokol tidak ada → 404 `not_found`; nama tidak valid → 400
`validation_error`; BIRD tidak jalan → 200 `{"available": false,
"reason": "BIRD tidak jalan", "protocol": null}`.

**BIRD — rute.**

### 6.38 `GET /api/v1/bird/routes` — Tier S

CLI: `show route` (+ varian). Backend: `titian-birdc.sh show-route*`
(timeout 30 detik). Query:

| Query | Arti |
|---|---|
| `?table=<nama\|all>` | `show route table <nama>` |
| `?protocol=<nama>` | `show route protocol <nama>` |
| `?prefix=<IP/prefix>` | `show route for <prefix>` (IPv4/IPv6, validasi `ipaddress`) |
| `?view=export\|import\|preexport\|noexport\|primary\|filtered` | lihat bawah |
| `?where=<kondisi>` | `show route where <kondisi>`; charset `[A-Za-z0-9_ .=<>!&|()"']`, maks 200 karakter |
| `?all=true` | `show route all` |
| `?count_only=true` | hanya hitungan (lihat bawah) |
| paginasi | `?limit=` / `?offset=` |

Precedence SATU subcommand (hanya satu yang dipakai):
`prefix` > `where` > `view` > `protocol` > `table` > `all` > default
(`show route`).

`view`:
- `export` / `preexport` / `noexport` — WAJIB `?protocol=<nama-protokol>`
  (tanpa itu → 400).
- `import` — WAJIB `?protocol=<PROTO.CHANNEL>` (mis.
  `bgp_203_0_113_1.ipv4`; tanpa `.` → 400).
- `primary` / `filtered` — tanpa protokol.

Skema `data.routes[]`:

| Field | Tipe | Arti |
|---|---|---|
| `prefix` | string | prefix rute |
| `type` | string | tipe (`unicast`, …) |
| `protocol` | string\|null | protokol sumber |
| `updated` | string\|null | waktu update (isi kurung siku sesudah protokol) |
| `preferred` | bool | ada tanda `*` |
| `preference` | int | angka dalam `(…)` |
| `attributes` | string\|null | kurung siku atribut (`[AS65001i]`) |
| `flags` | string\|null | sisa baris |
| `table` | string\|null | tabel aktif (`Table X:`) |
| `details` | string[] | baris lanjutan menjorok (`via …`, `dev …`) |
| `raw` | string | (hanya bila baris gagal parse) |

Contoh:

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
{"routes": 2, "routes_total": 2, "networks": 2}}` (dari
`show route count`: "N of N routes for N networks").

Error: `view` tidak dikenal / `protocol` / `table` / `prefix` /
`where` tidak valid → 400 `validation_error` (pesan menyebut syaratnya);
BIRD tidak jalan → 200 `{"available": false, "reason": "BIRD tidak
jalan", "routes": []}`.

### 6.39 `GET /api/v1/bird/routes/stats` — Tier S

CLI: `show route stats` + `show route count`. Backend:
`titian-birdc.sh show-route-stats` + `show-route-count`.

Skema `data`: `{"available": true, "tables":
[{"table": "master4", "metrics": {"routes": 2, "networks": 2}}],
"counts": {"routes": 2, "routes_total": 2, "networks": 2}}`.
Baris stats yang tidak cocok pola `Table X:` / `Key: angka` masuk
`raw_lines` per tabel + `meta.warnings`.

**BIRD — status / simbol / tabel / global / interface.**

### 6.40 `GET /api/v1/bird/status` — Tier S

CLI: `show status`. Backend: `titian-birdc.sh show-status`.

Skema `data`: `{"available": true, "router_id": "10.99.42.1",
"server_time": "2026-11-25 10:00:00",
"last_reboot": "2026-11-24 09:00:00",
"last_reconfiguration": "2026-11-25 09:30:00",
"daemon_state": "up"}`. Baris lain yang tidak dikenali masuk
`extra_lines` + warning.

### 6.41 `GET /api/v1/bird/symbols` — Tier S

CLI: `show symbols` (+ filter). Backend: `titian-birdc.sh show-symbols
[KIND]`. Query: `?type=function|protocol|roa|symbol|table|template|filter`
(selain itu → 400); paginasi.

Skema `data.symbols[]`: `{"kind": "table", "name": "master4"}`.
`kind` diambil dari seksi output (`Routing tables:` → `table`, …) atau
dari baris `table <nama>`.

### 6.42 `GET /api/v1/bird/tables` — Tier S

CLI: `show tables`. Backend: `titian-global.sh show-tables`
(format stabil: `<nettype> <nama> [opt=val ...]`).

Skema `data.tables[]`: `{"nettype": "ipv4", "name": "master4",
"options": {}}`; contoh ber-opsi: `{"nettype": "ipv4",
"name": "mytable", "options": {"sorted": "yes"}}`.

### 6.43 `GET /api/v1/bird/global` — Tier T

CLI: `show global`. Backend: `titian-global.sh show` (intent
`bird-global.conf` + section). Bentuk Tier T, `"source": "show global"`.

### 6.44 `GET /api/v1/bird/interfaces` — Tier S

CLI: `show interfaces bird` (+`summary`). Backend:
`titian-birdc.sh show-interfaces-bird [summary]`. Query:
`?summary=true`; paginasi.

Skema `data.interfaces[]`: `{"name": "ge1", "state": "up",
"index": 2, "flags": "MultiAccess Broadcast Multicast AdminUp LinkUp
MTU=1500", "details": ["203.0.113.10/24 (Primary, scope site)"]}`.
`data.summary` menggemakan `?summary=`.

**OSPF.**

### 6.45 `GET /api/v1/ospf` — Tier T

CLI: `show ospf`. Backend: `titian-ospf.sh show` (intent + section +
`birdc show protocol ospf4/ospf6` + `show ospf neighbors`).
Bentuk Tier T, `"source": "show ospf"`.

### 6.46 `GET /api/v1/ospf/interfaces` — Tier S

CLI: `show ospf interface`. Backend: `titian-birdc.sh
show-ospf-interface`. Skema `data.interfaces[]`: `{"id": "ge1",
"title": "Interface ge1 (203.0.113.10/24):", "instance": "ospf4",
"area": "0.0.0.0", "fields": {"type": "broadcast",
"state": "DR (1)", "cost": "10", "hello": "10", "dead": "40"},
"lines": []}`. Bila TIDAK ADA record ter-parse sama sekali, `data`
membawa `raw_text` (output apa adanya) + warning.

### 6.47 `GET /api/v1/ospf/neighbors` — Tier S

CLI: `show ospf neighbor(s)`. Backend: `titian-birdc.sh
show-ospf-neighbors` — DIPILIH atas `titian-ospf.sh show-neighbors`:
keduanya memanggil `birdc show ospf neighbors` yang sama; wrapper
birdc memberi soft-fail + strip banner BIRD. Skema
`data.neighbors[]`: `{"id": "203.0.113.1", "instance": "ospf4",
"area": "0.0.0.0", "fields": {"interface": "ge1",
"ip_address": "203.0.113.1", "state": "Full", "dr": "203.0.113.1",
"bdr": "203.0.113.10"}, "lines": []}`.

### 6.48 `GET /api/v1/ospf/state` — Tier S

CLI: `show ospf state` (+`all`). Backend: `titian-birdc.sh
show-ospf-state`. Skema `data.entries[]`: `{"id": "Router
203.0.113.1", "instance": "ospf4", "area": "0.0.0.0",
"fields": {"age": "123", "sequence": "0x80000001",
"checksum": "0x1234"}, "lines": []}`.

### 6.49 `GET /api/v1/ospf/topology` — Tier S

CLI: `show ospf topology` (+`all`). Backend: `titian-birdc.sh
show-ospf-topology`. Skema sama dengan `ospf/state`
(`data.entries[]`, `id` mis. `"Router 203.0.113.1"` /
`"Network 203.0.113.0/24"`, `fields` mis. `links` / `distance`).

### 6.50 `GET /api/v1/ospf/lsadb` — Tier S

CLI: `show ospf lsadb`. Backend: `titian-birdc.sh show-ospf-lsadb`.
Skema `data.entries[]`: `{"id": "Router-LSA 203.0.113.1 203.0.113.1",
"instance": "ospf4", "area": "0.0.0.0", "fields": {}, "lines": []}`
(`title` membawa seluruh baris LSA termasuk `(seq …, age …,
checksum …)`).

**RIP / BFD / RPKI.**

### 6.51 `GET /api/v1/rip` — Tier T

CLI: `show rip`. Backend: `titian-rip.sh show`. Bentuk Tier T,
`"source": "show rip"`.

### 6.52 `GET /api/v1/rip/interfaces` — Tier S

CLI: `show rip interfaces`. Backend: `titian-birdc.sh
show-rip-interfaces`. Skema `data.interfaces[]` seperti OSPF
(`id` = nama interface, `fields` mis. `mode`, `metric`).

### 6.53 `GET /api/v1/rip/neighbors` — Tier S

CLI: `show rip neighbors`. Backend: `titian-birdc.sh
show-rip-neighbors`. Skema `data.neighbors[]` (`id` = IP neighbor,
`fields` mis. `interface`, `last_update`).

### 6.54 `GET /api/v1/bfd` — Tier T

CLI: (config bfd). Backend: `titian-bfd.sh show` (intent + section +
`birdc show bfd sessions`; password sudah diredaksi script itu, daemon
meredaksi lagi). Bentuk Tier T, `"source": "show bfd"`.

### 6.55 `GET /api/v1/bfd/sessions` — Tier S

CLI: `show bfd sessions`. Backend: `titian-bfd.sh show-sessions`.

Skema `data.sessions[]`: `{"ip": "203.0.113.1", "interface": "ge1",
"state": "Up", "since": "2026-11-25 09:00:00", "interval": "0.100",
"timeout": "0.300"}`. BFD/BIRD tidak jalan → 200
`{"available": false, "reason": "BFD/BIRD tidak jalan", "sessions": []}`.

### 6.56 `GET /api/v1/rpki` — Tier S/T (hibrida)

CLI: `show rpki`. Backend: `titian-rpki.sh show` (intent + section +
`birdc show protocol` per instance — TIDAK ADA perintah birdc
`show rpki` khusus, jadi endpoint ini Tier T + instance ter-parse).

Skema `data`: bentuk Tier T (`config_text`, `lines`, `source`:
`"show rpki"`) + `"available": true` + `"instances":
[{"name": "rpki1", "protocol": "RPKI", "table": "---",
"state": "up", "since": "2026-11-24 09:00:00",
"info": "Established"}]`. Bila tidak ada instance ter-parse,
`instances` kosong + warning di `meta.warnings`.

**Protokol lain (Tier T).** Masing-masing: CLI `show <x>`, backend `titian-<x>.sh show` (intent + section + `birdc show protocol …`), bentuk Tier T.

### 6.57 `GET /api/v1/babel` — Tier T

Backend: `titian-babel.sh show` (`source`: `show babel`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

### 6.58 `GET /api/v1/direct` — Tier T

Backend: `titian-direct.sh show` (`source`: `show direct`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

### 6.59 `GET /api/v1/pipe` — Tier T

Backend: `titian-pipe.sh show` (`source`: `show pipe`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

### 6.60 `GET /api/v1/device` — Tier T

Backend: `titian-protocol.sh show` (`source`: `show device (+ `"kind": "device"` di `data`)`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

### 6.61 `GET /api/v1/kernel` — Tier T

Backend: `titian-protocol.sh show` (`source`: `show kernel (+ `"kind": "kernel"` di `data`)`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

### 6.62 `GET /api/v1/l3vpn` — Tier T

Backend: `titian-l3vpn.sh show` (`source`: `show l3vpn`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

### 6.63 `GET /api/v1/mrt` — Tier T

Backend: `titian-mrt.sh show` (`source`: `show mrt`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

### 6.64 `GET /api/v1/bmp` — Tier T

Backend: `titian-bmp.sh show` (`source`: `show bmp`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

### 6.65 `GET /api/v1/aggregator` — Tier T

Backend: `titian-aggregator.sh show` (`source`: `show aggregator`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

### 6.66 `GET /api/v1/radv` — Tier T

Backend: `titian-radv.sh show` (`source`: `show radv`). Skema `data` sama seperti endpoint Tier T lain (teks konfigurasi + `lines` + `source`); `device` dan `kernel` memakai backend yang sama (`titian-protocol.sh show` — satu output berisi keduanya), `data.kind` membedakan yang diminta.

**FRR.**

### 6.67 `GET /api/v1/frr` — Tier T

CLI: `show frr`. Backend: `titian-frr.sh show`. FRR tidak jalan →
200 `{"available": false, ...}` (BUKAN 500).

Skema `data`: bentuk Tier T (`"source": "show frr"`) + field ter-parse
dari baris pertama `FRR: <ver> (intent: <x>, rc: <y>, <running|not
running>[, pid N])`: `"available"`, `"frr_version"`,
`"intent"` (`yes`/`no`/`unset`), `"rc_enabled"` (bool),
`"running"` (bool), `"zebra_pid"` (int|null).

Contoh (tidak jalan):

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
(`vtysh -c "show ip bgp"`, batas 30 detik; zebra tidak jalan → rc 33
`"FRR belum jalan …"` → 200 `available:false`).

Skema `data.routes[]`: `{"status": "*>", "network": "203.0.113.0/24",
"next_hop": "203.0.113.1", "metric": 0, "locprf": 100, "weight": 0,
"path": "65001 i"}`. Baris 5 kolom (LocPrf kosong runtuh) → `locprf`
null. Baris gagal parse → `{"raw": …}` + warning.

### 6.69 `GET /api/v1/frr/bgp/summary` — Tier S

CLI: `show ip bgp summary`. Backend: `titian-frr.sh
show-ip-bgp-summary`.

Skema `data`: `{"available": true, "neighbors":
[{"neighbor": "203.0.113.1", "version": 4, "as": 65001,
"msg_rcvd": 10, "msg_sent": 10, "tblver": 0, "inq": 0, "outq": 0,
"up_down": "00:05:00", "prefixes_received": 5, "state": null}],
"total_neighbors": 1}`. Bila kolom terakhir bukan angka (mis.
`Active`/`Idle`), masuk `state` dan `prefixes_received` null.

### 6.70 `GET /api/v1/frr/ospf` — Tier S

CLI: `show ip ospf`. Backend: `titian-frr.sh show-ip-ospf`.

Skema `data`: `{"available": true, "info": {"router_id":
"10.99.42.1", "unparsed_lines": [...]}, "areas": [{"id": "0.0.0.0",
"fields": {"number_of_interfaces_in_this_area": "1",
"number_of_fully_adjacent_neighbors": "1"}}]}`. Baris tanpa `:` masuk
`info.unparsed_lines` + `meta.warnings`.

### 6.71 `GET /api/v1/frr/ospf/neighbors` — Tier S

CLI: `show ip ospf neighbor`. Backend: `titian-frr.sh
show-ip-ospf-neighbor`.

Skema `data.neighbors[]`: `{"neighbor_id": "203.0.113.1",
"priority": 1, "state": "Full/DR", "dead_time": "00:00:35",
"address": "203.0.113.1", "interface": "ge1:203.0.113.10",
"rxmtl": 0, "rqstl": 0, "dbsml": 0}`.

### 6.72 `GET /api/v1/frr/routes` — Tier S

CLI: `show frr route` / `show ip route` (FRR). Backend:
`titian-frr.sh show-ip-route`.

Skema `data.routes[]`: `{"code": "O", "prefix": "203.0.113.0/24",
"admin_distance": 110, "metric": 20, "via": "203.0.113.1",
"interface": "ge1", "age": "00:05:00"}`; rute connected:
`{"code": "C", "prefix": "10.99.42.0/24", "admin_distance": null,
"metric": null, "via": null, "interface": "ge1", "age": "00:05:00",
"directly_connected": true}`.

### 6.73 `GET /api/v1/frr/version` — Tier S

CLI: `show frr version`. Backend: `titian-frr.sh show-version`.

Skema `data`: `{"available": true, "frr_version": "10.7.1",
"running": true, "zebra_pid": 1234,
"version_text": "FRRouting 10.7.1\nCopyright …",
"source": "show frr version"}`. FRR tidak jalan: `available`
false, `running` false, `frr_version` tetap terisi (dari baris
`FRR <ver> (not running)`).

**Asumsi format (WAJIB verifikasi guest).**

Format di bawah ini diasumsikan dari sumber script `sbin-ref` +
pengetahuan format birdc 2.20 / vtysh FRR 10.x — BELUM dilihat dari
mesin live. Bila format live berbeda, parser mengembalikan `raw` +
warning (bukan 500), dan koordinator menyesuaikan parser + stub mock
sesudah verifikasi guest:

1. `show protocols [all]`: header `Name Proto Table State Since Info`;
   `Since` = tanggal + jam (2 token); detail `all` menjorok langsung
   sesudah baris protokolnya.
2. `show protocol <nama>`: baris tabel + blok detail `Key: value` +
   `Channel <nama>:` (mis. `Routes: 5 imported, …`).
3. `show route*`: `PREFIX TYPE [PROTO WAKTU] * (PREF) [ATTRS]`;
   `show route count`: `"N of N routes for N networks"`;
   `show route stats`: seksi `Table X:` + `Key: angka`.
4. `show symbols`: seksi berjudul `:` (`Routing tables:`, …) berisi nama.
5. `show interfaces`: `NAMA STATE (index=N)` + baris detail menjorok.
6. OSPF/RIP detail birdc: seksi instance (`ospf4:`), `Area X:`,
   record (`Interface …:`, `Router ID: …`, `Router …:`, `Network …:`,
   `Router-LSA …`, `Neighbor …:`) + `Key: value` menjorok.
7. `show bfd sessions`: header `IP address Interface State Since
   Interval Timeout`; `Since` = tanggal + jam.
8. vtysh `show ip bgp`: header `Network Next Hop Metric LocPrf Weight
   Path`; kode status menempel di depan network (`*>`); baris 5 kolom =
   LocPrf kosong.
9. vtysh `show ip bgp summary`: header `Neighbor V AS MsgRcvd MsgSent
   TblVer InQ OutQ Up/Down State/PfxRcd` + `Total number of neighbors N`.
10. vtysh `show ip ospf neighbor`: header `Neighbor ID Pri State Dead
    Time Address Interface RXmtL RqstL DBsmL`.
11. vtysh `show ip route`: `CODE PREFIX [AD/METRIC] via GW, IF, AGE`
    atau `CODE PREFIX is directly connected, IF, AGE`.
12. `titian-frr.sh show`: baris pertama `FRR: <ver> (intent: <x>,
    rc: <y>, <running|not running>[, pid N])`.

**Yang TIDAK diekspos (sesuai desain §2 D3).**

- `show route help` (bantuan CLI lokal), `show frr bgp` (tanpa ACTION —
  tidak ada backend), `show protocol neighbors` (tercakup
  `bird/protocols/:name`), `show route export table` / `import table`
  (tercakup `bird/routes?view=…&table=…` — `view=import` memakai
  `show-route-import-table <PROTO.CHANNEL>`).

**Usulan endpoint tulis (TERBUKA — TIDAK diimplementasikan).**

Sesuai desain §0/§3: hanya GET di ronde ini. Bila web UI butuh tulis
agar berguna, usulan di bawah ini dicatat saja (nama + alasan + risiko):

1. `POST /api/v1/bird/protocols/:name/restart` — restart satu protokol
   BIRD dari web UI (backend sudah ada: `titian-birdc.sh proto-restart`;
   risiko: gangguan routing sesaat; butuh konfirmasi + audit seperti
   kick/isolir).
2. `POST /api/v1/bird/protocols/:name/enable|disable` — enable/disable
   protokol (backend `proto-enable`/`proto-disable` sudah ada; risiko:
   protokol mati sampai di-enable lagi).
3. `POST /api/v1/bird/reload` — `configure` ulang BIRD sesudah perubahan
   intent (backend `configure` sudah ada; risiko: config error menolak
   reload — perlu validasi `configure check` dulu).
4. `POST /api/v1/frr/reload` — restart/reload FRR (mutual exclusion vs
   BIRD — risiko TINGGI: salah urutan bisa mematikan routing; JANGAN
   tanpa desain terpisah).


**D4a — firewall / WireGuard.**

### 6.74 `GET /api/v1/firewall` — ringkasan + konfigurasi firewall (Tier S/T)

Backend: `titian-fw.sh show` + `titian-fw.sh status`.

Skema `data`: `enabled` (bool|null, dari baris `firewall: yes|no` di
`firewall.conf`), `protected_interfaces` (list string),
`rules` (list string aturan mentah dari `show`, urutan = prioritas),
`rule_count` (int), `config_text` (string, seluruh output `show`),
`lines` (int, jumlah baris `config_text`), `pf_running` (bool|null —
`true` bila `status` mencetak `pf: Enabled`; `null` bila `status` gagal),
`live_filter` (list string baris pf anchor `firewall`, tanpa indent),
`live_nat` (list string baris pf anchor `nat`, tanpa indent).

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

Error: tanpa token → 401 `unauthorized`; token salah → 403 `forbidden`;
backend gagal → 500 `internal_error`.

### 6.75 `GET /api/v1/firewall/filter` — aturan filter (Tier S)

Backend: `titian-fw.sh show-filter` (baris `filter <chain> <action>
proto <p> src <a> dst <a> sport <s> dport <d> in <if> out <if>`).
Baris yang tidak cocok pola → `{"raw": "<baris>"}` + `meta.warnings`.

Skema tiap item `data.rules`: `chain` (`forward`|`input`|`output`),
`action` (`permit`|`deny`), `protocol` (`tcp`|`udp`|`icmp`|`all`),
`src`/`dst` (string, CIDR atau `any`), `sport`/`dport` (int|null —
`null` = `any`), `in_interface`/`out_interface` (string), `raw` (string
baris asli). Item gagal parse hanya membawa `raw`.

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

Error: `limit`/`offset` tidak valid → 400 `validation_error`.

### 6.76 `GET /api/v1/firewall/nat` — aturan NAT (Tier S)

Backend: `titian-fw.sh show-nat` (baris `snat`/`dnat`).

Skema tiap item `data.rules`: `snat` → `type: "snat"`, `srcnet`,
`target` (IPv4 atau `"masquerade"`), `out_interface`, `raw`;
`dnat` → `type: "dnat"`, `protocol` (`tcp`|`udp`), `in_interface`,
`dport` (int), `target` (IPv4), `target_port` (int|null — `null` bila
`same`), `target_port_same` (bool), `raw`. Item gagal parse hanya
membawa `raw`.

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

Error: `limit`/`offset` tidak valid → 400 `validation_error`.

### 6.77 `GET /api/v1/firewall/isolated` — daftar user terisolir (Tier S)

Backend: `titian-fw.sh show-isolated` (sudah dipakai endpoint lama;
satu baris `isolate <ip> <web-ip> <web-port>` per user).

Skema tiap item `data.isolated`: `ip`, `web_ip` (string IPv4),
`web_port` (int). Daftar kosong → 200 + list kosong (bukan 404).

```http
GET /api/v1/firewall/isolated
```

```json
{"status": "ok", "data": {"isolated": [{"ip": "10.99.42.100",
"web_ip": "203.0.113.10", "web_port": 80}]},
"meta": {"total": 1, "count": 1, "limit": 100, "offset": 0, "warnings": []}}
```

### 6.78 `GET /api/v1/wireguard` — daftar interface WireGuard (Tier S)

Backend: `titian-wireguard.sh show` (ringkasan per interface + seksi
`-- wg show:` dari tool `wg`).

Skema tiap item `data.interfaces`: `name` (mis. `"wg0"`), `enabled`
(bool), `address` (string CIDR|null — `null` bila `unset`),
`listen_port` (int, default 51820), `peer_count` (int), `live` (bool —
interface ada di kernel). `data.live`: hasil parse `wg show`
(`interface`, `public_key`, `listening_port`, `peers[]` dengan
`public_key`/`endpoint`/`allowed_ips`/`latest_handshake`/`transfer`)
atau `null` bila `wg` tidak mengeluarkan output; `data.live_text`:
teks mentah seksi `-- wg show:` (atau `null`).

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

Catatan: private key TIDAK PERNAH dicetak backend maupun API
(`wg show` hanya mencetak `private key: (hidden)`; baris `public-key`
state file disaring backend `show-one` dan dilewati parser daemon).

### 6.79 `GET /api/v1/wireguard/:name` — satu interface WireGuard (Tier S)

Backend: `titian-wireguard.sh show-one <name>` (nama divalidasi
`^wg[0-9]{1,2}$`, bila tidak cocok → 400). Keberadaan dicek dari file
state `$TITIAN_STATE_ROOT/netstate/wireguard/<name>.conf` SEBELUM
memanggil backend — karena `show-one` asli membuat file state baru
bila belum ada, jadi tanpa cek ini nama yang belum ada akan terlihat
"ada".

Skema `data`: `name`, `enabled` (bool|null), `address` (string|null),
`listen_port` (int, default 51820), `peers[]` (`public_key`,
`allowed_ips` string|null — `null` bila `-`, `endpoint` string|null,
`keepalive` int detik), `live` (hasil parse `wg show <iface>` seperti
§6.78, atau `null`), `live_available` (bool), `live_raw` (list string
baris live mentah).

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

Error: nama bukan `wg<N>` → 400 `validation_error`; interface belum
dikonfigurasi (tidak ada file state) → 404 `not_found`.

**Asumsi yang belum terverifikasi di mesin live (TERBUKA, butuh guest bhyve).**

- Format `wg show` diasumsikan format standar tool `wg`
  (`interface:`/`public key:`/`listening port:`/`peer:`/`endpoint:`/
  `allowed ips:`/`latest handshake:`/`transfer:`). Parser live
  best-effort: baris tak dikenal → `live_raw` + `meta.warnings`,
  bukan gagal total. Bila format guest berbeda, sesuaikan parser.
- `GET /api/v1/firewall` membaca `pf_running` dari `titian-fw.sh
  status` (substring `Enabled`); bila `pfctl -s Running` gagal,
  backend mencetak `pf: not running` dan daemon mengembalikan
  `pf_running: false` + `live_filter`/`live_nat` kosong.

**Usulan endpoint tulis (TERBUKA — TIDAK diimplementasikan di ronde ini).**

- `POST /api/v1/firewall/enable` + `POST /api/v1/firewall/filter` /
  `nat` (tambah/hapus rule) — web UI operator butuh ini agar tidak
  harus kembali ke klish; risiko: validasi rule + anti-lockout
  protected-interface harus dipertahankan persis seperti
  `titian-fw.sh`; perlu `reason` wajib + audit syslog seperti
  disconnect/isolate.
- `POST /api/v1/wireguard/:name/peers` (tambah peer) — butuh
  `generate-key` sekali tampil public key; risiko: private key
  TIDAK BOLEH pernah masuk respons/log.


**D4b — traffic-shape / PPPoE / IPoE / monitoring.**

**Traffic-shape.**

### 6.80 `GET /api/v1/traffic-shape` — Tier T
Backend: `titian-traffic-shape.sh show`. Respons `data`:
`{enabled: bool|null, config_text: string, lines: int, source: "show traffic-shape"}`.
Contoh: `{"enabled": true, "config_text": "traffic-shape: yes\npipes:\n  pipe p10m bw 10M ...", "lines": 14, ...}`.

### 6.81 `GET /api/v1/traffic-shape/profiles` — Tier S
Backend: `show-profile` (tanpa argumen). `data.profiles[]`:
`{name, download: "8M", download_burst: 1000000, upload: "2M", upload_burst: 500000, bindings: [{profile, target_type: "interface"|"ip", interface, ip?, side?}]}`.
`download/upload` string laju apa adanya (`"8M"`, `"unset"` bila belum di-set);
burst integer byte. Paginasi berlaku.

### 6.82 `GET /api/v1/traffic-shape/profiles/:name` — Tier S
Backend: `show-profile <name>` (nama `[A-Za-z0-9_-]{1,12}`, selain itu 400
`validation_error`). `data.profile` = objek profile + `derived_pipes[]`
(objek pipe) + `derived_rules[]` (objek rule). Tidak ada → 404 `not_found`
(backend mencetak `(no profile <name>)` dengan rc 0 — daemon yang mengubah
jadi 404).

### 6.83 `GET /api/v1/traffic-shape/pipes` — Tier S
Backend: `show-pipe`. `data.pipes[]`:
`{name, bw: "10M"|"unset", queue: int, delay_ms: int, plr: number|string, burst: int, aqm?: "aqm codel target 5"}`.
Kosong → `[]` (backend `(no pipes)`), bukan 404.

### 6.84 `GET /api/v1/traffic-shape/queues` — Tier S
Backend: `show-queue`. `data.queues[]`:
`{name, parent_kind: "pipe"|"sched", parent, mask: "dst-ip"|..., mask_value: "/32"|"-", weight: int, queue: int, aqm?}`.

### 6.85 `GET /api/v1/traffic-shape/rules` — Tier S
Backend: `show-rule`. `data.rules[]`:
`{name, direction: "in"|"out", interface, target_kind: "pipe"|"queue", target, src?: ip|cidr, dst?, proto?: "tcp"|"udp"|"icmp"|"all", dport?: int}`.

### 6.86 `GET /api/v1/traffic-shape/sched` — Tier S
Backend: `show-sched`. `data.schedulers[]`:
`{name, type: "fifo"|"wf2q+"|"rr"|"qfq"|"fq_codel"|"fq_pie", bw?, quantum?: int, limit?: int, flows?: int}`.

### 6.87 `GET /api/v1/traffic-shape/statistics` — Tier S (seksi)
Backend: `stats`. `data`:
`{available: bool, dummynet_loaded: bool, sections: [{name, text, line_count}], note?: string, reason?}`.
Seksi = header `== ... ==` backend (`pipes`, `schedulers`, `queues`,
`pf anchor traffic-shape rules (...)`, `interface counters (...)`).
Kolom ipfw TIDAK di-parse (format ipfw tidak ada di sbin-ref; quirk BKT
`Tot_pkt/bytes` tidak bergerak terbukti live 22 Nov 2026 — lihat `note`).
Bila dummynet belum dimuat → 200 `{"available": false, "reason": "dummynet belum dimuat (traffic-shape belum pernah di-apply)", "dummynet_loaded": false, "sections": []}`.

**PPPoE.**

### 6.88 `GET /api/v1/pppoe` — Tier S
Backend: `titian-pppoe.sh show` (+ `sessions-detail` untuk hitungan sesi).
`data`: `{enabled, interface, pool: "10.99.42.100-10.99.42.199"|null, pool_start, pool_end, radius_server: ip|null (null bila "local auth"), radius_auth: bool, radius_acct: bool|null, radius_nas_ip, console: bool|null, console_password_set: bool (hanya status set/unset — password TIDAK PERNAH tampil), users: int|null, mpd5_running: bool|null, sessions_active: int}`.
Sesi aktif tetap di `/api/v1/sessions`.

### 6.89 `GET /api/v1/pppoe/users` — Tier S
Backend: `show-users`. `data.users[]`: `{user, static_ip: ip|null}` (`null`
bila `pool`/`-`). Paginasi berlaku. Kosong → `[]`.

**IPoE.**

### 6.90 `GET /api/v1/ipoe` — Tier S
TERKONFIRMASI (25 Nov 2026): `titian-ipoe-acct.py` ADA di repo-root
`sbin/` (bukan `titian/sbin/` — pola yang sama dengan 3 error
pre-existing verify.py), terpasang di guest di `/opt/titian/sbin/`;
fungsi `read_active_leases` daemon adalah salinan setia dari fungsi
yang sama di script itu. Endpoint ini dibangun dari `ipoe.conf` (field
non-rahasia saja — `radius-secret`/`omapi-key` tidak pernah dibaca) +
`titian-dhcp.sh server-status` + lease file (parser yang sama dengan
daemon). `data`: `{available: bool, reason: string|null, enabled, interface, pool, dhcpd_running: bool|null, active_leases: int, radius_server, nas_ip, radius_mac_auth: bool, radius_mac_count: int, blocked_mac_count: int}`.
Bila `ipoe.conf` tidak ada → 200 `{"available": false, "reason": "IPoE belum dikonfigurasi (ipoe.conf tidak ada)", ...}`.
Verifikasi guest: `ipoe.conf` + `server-status` berperilaku sama di
guest (HTTP 200); parsing lease nyata masih TERBUKA (butuh lease DHCP
nyata).

### 6.91 `GET /api/v1/ipoe/leases` — Tier S
Backend: `titian-dhcp.sh list-leases`. `data.leases[]`:
`{ip, mac, ends: "2026-11-24T11:00:00Z" (ISO 8601 UTC), ends_epoch: int}`.
Hanya lease `active` (blok terakhir per IP, file append-only). Paginasi WAJIB
(list bisa besar). Kosong → `[]`.

### 6.92 `GET /api/v1/ipoe/blocked` — Tier S
Backend: `titian-dhcp.sh list-blocked`. `data.blocked[]`: `{mac}`.
Paginasi berlaku. Kosong → `[]`.

**Monitoring.**

### 6.93 `GET /api/v1/monitoring` — Tier S
Backend: `titian-monitoring.sh show [service]`. Query opsional
`?service=snmp|node-exporter|bird-exporter|nfacctd` (lainnya → 400
`validation_error`). `data.services[]`:
`{service, process: "snmpd"|"node_exporter"|"bird_exporter"|"nfacctd", port: "161/udp"|"9100"|"9324"|"2100", enabled: bool|null (dari intent), intent: "yes"|"no"|"unset", rc_enabled: bool|null, running: bool, community?: string (hanya snmp)}`.
`community` adalah string intent (default `bsdrp-ro`), bukan rahasia.

### 6.94 `GET /api/v1/monitoring/bandwidth` — Tier S
Backend: `titian-monitoring.sh bandwidth <seconds>`. Query `?seconds=`
1–3600, default 60 (lainnya → 400). `data`:
`{seconds: int, interfaces: [{interface, rx: "1.23 Mbps", rx_bps: 1230000, tx, tx_bps, total, total_bps}], measured_at: ISO UTC}`.
Baris `total` ikut sebagai interface `"total"`. Mode live (>1 detik)
mencetak tabel berulang — daemon mengambil tabel TERAKHIR. Nilai bps
dihitung desimal (1 Mbps = 1.000.000 bps, sesuai `fmt_bps` backend).
CATATAN: `seconds` besar (mis. 3600) menahan request selama itu (timeout
backend = seconds+10); web UI disarankan memakai 1–10 detik. `bwm-ng` ADA
di image 0.1.1 (`bwm-ng-0.6.3_1`, `/usr/local/bin/bwm-ng`); backend
meresolusi bwm-ng via PATH + lokasi absolut (`/usr/local/bin`,
`/usr/bin`), jadi jalur bwm-ng tetap dipakai walau PATH daemon (rc.d/boot)
tanpa `/usr/local/bin` (akar 500 di ronde 3 — dulu hanya `command -v`).
Bila `bwm-ng` benar-benar tak ada, backend memakai fallback sampling
counter interface (`netstat -ib` di FreeBSD — Ibytes kolom 8, Obytes
kolom 11 — / `/proc/net/dev` di Linux) 2x selama `seconds` detik — tabel
yang dikembalikan sama formatnya (judul tabel menandai "netstat
fallback"). Fallback TERBUKTI di guest ronde 9 (bwm-ng dipindah
sementara: judul fallback + em0 ~71–74 Kbps saat trafik ping, cocok
dengan `netstat -ib`; bwm-ng dikembalikan → jalur bwm-ng lagi). Untuk
update live per detik yang halus, pasang `net-mgmt/bwm-ng`.

**Error umum.**
401 `unauthorized` (tanpa token) · 403 `forbidden` (token salah) ·
404 `not_found` (endpoint/profile tidak ada) · 400 `validation_error`
(parameter/query tidak valid) · 429 `rate_limited` · 500 `internal_error`
(backend gagal/timeout).

**Yang TIDAK jadi / TERBUKA.**
- Tidak ada endpoint D4b yang gagal total — 15/15 jadi (mock).
- Endpoint tulis (usulan TERBUKA, TIDAK diimplementasikan di ronde GET ini):
  `POST /api/v1/traffic-shape/profiles/:name/bind` (bind profile ke
  interface/IP — berguna agar web UI bisa menerapkan paket tanpa klish;
  risiko: mengubah `traffic-shape.conf` + dirty flag → perlu commit/apply;
  butuh validasi interface/IP + otorisasi terpisah),
  `POST /api/v1/ipoe/blocked` / `DELETE /api/v1/ipoe/blocked/:mac`
  (blokir/buka blokir MAC — padanan `kick`/`unblock` yang sudah ada untuk
  sesi; risiko: restart dhcpd saat kick),
  `POST /api/v1/monitoring/:service` (enable/disable intent monitoring —
  hanya mencatat intent + dirty, berlaku saat commit; risiko rendah).
- Verifikasi guest bhyve (25 Nov 2026, backend asli) — 15/15 endpoint
  D4b HTTP 200 di sweep penuh; `traffic-shape/profiles/uji` COCOK dengan
  `show traffic-shape profile uji`. Masih TERBUKA: format tabel
  `ipfw pipe/sched/queue show` di `statistics` (saat ini seksi-teks,
  bukan kolom ter-parse); `monitoring bandwidth` mode live >1 detik
  (mock hanya menguji snapshot 1 detik; fallback netstat cabang FreeBSD
  TERBUKTI di guest ronde 9 — judul fallback + counter ~71–74 Kbps
  cocok dengan `netstat -ib`); `show-profile` untuk
  profile dengan bind IP CIDR (slug mengandung `-`). TERKONFIRMASI:
  `titian-ipoe-acct.py` ADA di repo-root `sbin/` (bukan `titian/sbin/`).


## 7. Isolir — catatan penting

1. **Isolir = dst-nat, bukan pipe kecil.** Trafik web user (TCP 80
   DAN TCP 443) di-redirect ke web isolir (port web server, 80).
   TIDAK ADA blokir 443. Klien HTTPS menerima respons HTTP polos
   (bukan TLS) — konsekuensi desain, bukan bug. Bandwidth (dummynet)
   tidak diubah.
2. **Web isolir di luar router butuh forward permit.** Filter pf
   melihat paket SESUDAH dst-nat (dst = IP web isolir). Bila web
   isolir ada di luar router, tambahkan rule filter yang mengizinkan
   forward ke IP web isolir itu — kalau tidak, trafik ter-redirect
   tapi lalu diblokir trailing block forward. Bila web isolir jalan
   di router sendiri, tidak perlu apa-apa (input default ACCEPT).
3. **Firewall harus enable.** Tanpa itu anchor nat/firewall tidak
   dimuat dan isolir tidak berpengaruh (API menolak dengan 400).
4. **Isolir bertahan reboot** (state file + apply saat boot), tapi
   **sesi tidak**: sesudah reboot, sesi harus dibuat ulang (PPPoE
   redial / DHCP renew) — daftar isolir tetap menunggu IP yang sama
   (bila IP berubah, isolir tidak mengikuti; cabut + isolir ulang).
5. **Isolir per IP, bukan per user.** Bila user ganti IP (reconnect),
   isolir lama tidak mengikuti.

## 8. Kick — catatan penting

- PPPoE: lewat konsol mpd5 (Opsi A, LCP graceful) — user bisa redial
  langsung. RADIUS Stop tercatat bila RADIUS accounting aktif.
- IPoE: `kick-lease` hanya melepas lease — perangkat akan request
  lease baru (DHCP renew) dan kembali online. Ini sengaja: kick IPoE
  = "putus sekarang", bukan "blokir". Untuk blokir MAC permanen,
  pakai `titian-remote-kick.sh kick <mac>` (CLI) — bukan API.
- Semua kick/isolir/unisolate **wajib beralasan** (`reason`) dan
  tercatat di syslog router (lihat §10).

## 9. Bandwidth live — sumber counter

- PPPoE: `netstat -I <ngX> -b` — Ibytes/Obytes interface netgraph
  sesi itu. `rate_source: "ng"`.
- IPoE: counter byte per rule di anchor `traffic-shape` (`pfctl -a
  traffic-shape -s rules -v`) — hanya bila IP itu terikat profil
  traffic-shape; bila tidak terikat, bps = 0, `rate_source: "pf"`
  dengan total null, atau `"none"`.
- **BUKAN `ipfw pipe show` BKT** — counter BKT terbukti tidak bergerak
  (quirk, 22 Nov 2026).
- Rate = delta byte × 8 / detik sampling (default 2 dtk, `sample`
  0–5). `sample=0` = tanpa rate (bps 0, total null) — untuk list cepat.
- Uptime PPPoE selalu `null` (interface ng* tidak membawa waktu mulai
  sesi); uptime IPoE dari `starts` di file lease.

## 10. Audit & log

- Setiap kick / isolir / unisolate (sukses maupun gagal) tercatat di
  syslog router (`daemon.info`, tag `titian-api`): nama token,
  aksi, session id, user, IP, reason, hasil. Contoh:
  `titian-api[1234]: myraddash disconnect pppoe-agus (10.99.42.101) reason=tunggakan 2 bulan ok=yes verified=yes`
- Log akses daemon (request) ke stderr (ditangkap rc.d `daemon`).
- Token dan password **tidak pernah** ditulis ke log/respons. Satu
  pengecualian: `gentoken` mencetak token baru SEKALI ke terminal
  admin root (§3.3).
- Pesan error backend yang mengandung kata password/secret/token
  disembunyikan dari respons API (diganti pesan generik; detail di
  syslog router).

## 11. Token rotation

```sh
service titian-api gentoken --name myraddash   # token baru, cetak sekali
# update record NAS myRadDASH dengan token baru
# (token lama langsung tidak berlaku)
```

Tidak ada masa berlaku token (revokasi = ganti token). Bila token
bocor, rotasi segera; tidak ada cara "hapus satu token" selain
menghapus barisnya dari config lalu restart service.

## 12. Troubleshooting

| Gejala | Penyebab / jalan keluar |
|---|---|
| `401 unauthorized` | Header `Authorization: Bearer <token>` tidak ada. |
| `403 forbidden` | Token salah / belum dibuat (`gentoken`). |
| `400 validation_error` (isolate) | `isolir-web` kosong di config, atau firewall belum enable. |
| `500 internal_error` (disconnect PPPoE) | Console mpd5 tidak menjawab (mpd5 jalan? `console` enable? password console ada?). Cek syslog router. |
| `sessions` kosong padahal user online | PPPoE: console mpd5 belum enable / `sessions-detail` gagal (lihat `meta.warnings`). IPoE: file lease tidak terbaca. |
| bps selalu 0 (IPoE) | IP belum terikat profil traffic-shape (counter pf hanya ada bila ada rule per IP). |
| `rate_limited` | Lewat batas per menit — naikkan `rate-limit` di config, atau kurangi frekuensi polling web UI. |
| Daemon tidak jalan | `titian-api.py check` — config hilang / token kosong / bind 0.0.0.0 / backend hilang. |

## 13. Notes (terbuka)

- **Alamat web isolir: `103.50.129.84:80`** — myradash-isolir-web di
  host 84 (container 172.30.0.22:8080 internal, dipublish 0.0.0.0:8080,
  dijangkau lewat NPM default server di port 80). Diputuskan user
  25 Nov 2026 ("ok webisolir ngikut"). Diverifikasi live dari guest
  bhyve 25 Nov 2026 (ronde 5, dengan SNAT pool PPPoE di guest):
  redirect :80 → HTTP 200 + judul halaman isolir; redirect :443 →
  koneksi selesai (FIN_WAIT_2) — klien HTTPS menerima respons HTTP
  polos, sesuai desain.
- **Bind IP produksi belum diputuskan** — default `127.0.0.1` (hanya
  dari router sendiri). Untuk diakses myRadDASH dari luar, isi IP
  manajemen router (bukan 0.0.0.0).
- **Sertifikat TLS self-signed** secara default — ganti sertifikat
  proper untuk produksi.
- **Web UI operator + integrasi myRadDASH** adalah langkah berikutnya
  (Fase 2 langkah 3+), bukan bagian dokumen ini.
- **Uptime PPPoE** tidak tersedia (`null`) — lihat §9.

- **Perluasan semua-menu CLI (25 Nov 2026)** — 87 endpoint GET baru (§6.8–6.94): D1 system/config/checkpoints (15), D2 interfaces/IP/routes (10), D3 BIRD/routing-protocols (41), D4a firewall/WireGuard (6), D4b traffic-shape/BRAS/monitoring (15). Total API kini 94 endpoint (7 lama + 87 baru). Satu-satunya backend baru: subcommand `titian-sys.sh storage`. Mock gabungan (daemon asli + backend stub + HTTPS asli): **213/213 PASS** (212 awal + 1 check baru T2; 3 check neighbors diperbarui untuk entri permanent).
- **Verifikasi guest bhyve (25 Nov 2026, backend klish asli, daemon `38b84dd9…` = commit `68d32c2`)** — sweep penuh ronde 3: **121 pemanggilan, 101×200, 2×400, 1×401, 1×403, 13×404, 3×500**; 93 dari 94 pola rute teruji langsung. 94/94 pola rute TERBUKTI teruji — "1 pola belum terpetakan" di laporan r3 adalah artefak hitung: diff literal daftar uji vs §6 dokumen menunjukkan 83 pola fixed + 8 pola parametrik (diuji dengan nilai konkret) + 3 POST (disconnect/isolate/unisolate, 404) semua teruji. Smoke 401/403/200 LOLOS semua ronde; log daemon tanpa Traceback. Yang 500: 1× `/config/running` sebelum save (T2, sudah diperbaiki) + 2× `/monitoring/bandwidth` (T3, sudah diperbaiki — akar: deteksi PATH, bukan biner hilang). 404 yang benar: interface/vxlan/wireguard/traffic-profile/service tak dikenal, sesi tak ada. BGP Established TIDAK bisa diverifikasi di guest standalone (butuh peer live — expected). Log: `guest-verify-full-api-r3.log` (sha256 `5b83f6c3…`), 121 body mentah di `api-bodies-r3/api-bodies-full/`, laporan `laporan-akhir-verifikasi-full-api.md` (semua di `~/workspace/titian-api-work/`).
- **Perbaikan pasca-verifikasi guest (commit `ad2a287`, 25 Nov 2026).** T2: `/config/running` tanpa save → 200 `available: false` (bukan 500). T3: `monitoring/bandwidth` fallback sampling counter netstat bila bwm-ng tidak terpasang. T5: entri ARP `permanent`/`expired` FreeBSD kini ter-parse (`state: permanent`, `expires_seconds: null`) — sebelumnya jadi `raw`. T4 (diputuskan BUKAN bug): `/bird/protocols/:name` → 200 `available: false` bila BIRD down, 404 bila BIRD up + nama tak ada. Mock sesudah perbaikan: **213/213 PASS**; verify.py tetap 3 error pre-existing yang sama, 0 baru. **Verifikasi guest ulang (ronde 8, 25 Nov ~14:37): T2 ✅** (200 `available: false` fresh; 200 + redaksi sesudah save), **T5 ✅** (permanent ter-parse, tanpa warning), **T4 ✅** (200 `available: false`, keputusan dikonfirmasi), regresi 6/6 ✅, smoke ✅; T1 terulang (lihat di bawah). **Perbaikan lanjutan commit `40ae9d3` (T3a/T3b):** bwm-ng ternyata ADA di image (`bwm-ng-0.6.3_1`) — 500 di r3 adalah deteksi PATH-dependent, bukan biner hilang; backend kini meresolusi bwm-ng via PATH + lokasi absolut. Kolom fallback diperbaiki ($7/$10 → $8/$11 Ibytes/Obytes + kupas `*` enc0). **Verifikasi guest ronde 9 (25 Nov ~15:05): T3a ✅ + T3b ✅ TERBUKTI** — backend langsung PATH minimal → judul bwm-ng; bwm-ng dipindah sementara → judul "netstat fallback" + em0 ~71–74 Kbps saat trafik ping (tiga pengukuran independen sepakat; `enc0` kini muncul di tabel); API fallback em0 rx_bps=71740, tx_bps=72490; bwm-ng dikembalikan → jalur bwm-ng lagi. 20/22 CHECK PASS (2 FAIL artefak grep harness, terbukti bukan backend).
- **TERBUKA — sesi PPPoE flap di guest (T1, di luar daemon API).** Di ronde guest 25 Nov 2026, sesi PPPoE klien userland `ppp` hidup ~2 detik lalu server mpd5 mengirim Terminate-Request (CCP → IPCP → LCP); `show sessions` kosong, `ngctl` tanpa node `ppp`/`iface`, server tidak mengeluarkan syslog sama sekali. `/sessions` → 200 `[]` adalah jawaban BENAR (daemon dibebaskan). Akibat: `disconnect`/`isolate`/`unisolate` via API BELUM PERNAH teruji BERHASIL di ronde ini (selalu 404 `not_found`) — ketiganya SUDAH terbukti berhasil 24 Nov 2026 (ronde isolir, sesi stabil waktu itu). Diagnosis terarah r7 TERBLOKIR cek keamanan eksekusi sebelum guest dimulai (butuh persetujuan eksplisit user untuk melanjutkan eksekusi skrip verifikasi bhyve/kopler); T1 terulang persis di ronde 8 (flap ~1–2 dtk, `Connect time` 34→36). Petunjuk baru dari log r6: syslog klien `ipcp_InterfaceUp: unable to set ip address` dan server menolak IPV6CP (`Protocol 0x8057 was rejected`) sesaat sebelum terminate — kemungkinan pemicu, belum terbukti. Hipotesis H1 (matikan kompresi bundle), H2 (`set iface up`), H3 (IPCP ranges langsung) tetap BELUM diuji.
- **`titian-ipoe-acct.py` — lokasi TERKONFIRMASI (25 Nov 2026).** File ini hidup di repo-root `sbin/` (bukan `titian/sbin/` — pola yang sama dengan 3 error pre-existing verify.py), terpasang di `/opt/titian/sbin/` guest. Fungsi `read_active_leases` daemon adalah salinan setia dari fungsi yang sama di script itu (logika "last block per IP" + parsing lease-block sama). Parsing lease IPoE sendiri BELUM terbukti (T6 — butuh lease DHCP nyata di guest).
- **Asumsi format yang masih butuh bukti guest.** D2: format tabel `titian-show.sh interfaces`/`terse` dan `netstat -rn` FreeBSD, baris FDB vxlan; cabang parser Linux hanya diuji unit (mock §17b), bukan lewat HTTP; entri ARP `permanent`/`expired` SUDAH terbukti di guest (T5). D3: format `show route stats`, `show symbols`, blok OSPF/RIP/LSADB, `show bfd sessions`, `show ip bgp` 5 kolom. D4a: format `wg show` standar. D4b: `traffic-shape statistics` saat ini seksi-teks (kolom ipfw tidak di-parse — format ipfw tidak ada di referensi + quirk counter BKT); `monitoring/bandwidth` mode live >1 detik hanya diuji snapshot 1 detik di mock; fallback netstat cabang Linux diuji langsung di VM, cabang FreeBSD TERBUKTI di guest ronde 9 (judul fallback + counter ~71–74 Kbps cocok dengan `netstat -ib`).
- **Usulan endpoint tulis (TERBUKA — tidak diimplementasikan di ronde GET ini).** D1: `POST /api/v1/system/sysctl`, `POST /api/v1/checkpoints` (+ rollback/delete), `POST /api/v1/services/:name/restart`. D2: `POST /api/v1/interfaces/:name/tuning`, `POST /api/v1/vxlan*`, `POST /api/v1/bridges*`, `POST /api/v1/routing/static/routes`. D3: `POST /api/v1/bird/protocols/:name/restart|enable|disable`, `POST /api/v1/bird/reload`, `POST /api/v1/frr/reload` (risiko TINGGI — mutual exclusion BIRD/FRR). D4a: `POST /api/v1/firewall/enable`, `POST /api/v1/firewall/filter|nat` (butuh anti-lockout + reason + audit), `POST /api/v1/wireguard/:name/peers` (private key tidak boleh masuk respons/log). D4b: `POST /api/v1/traffic-shape/profiles/:name/bind`, `POST|DELETE /api/v1/ipoe/blocked[/:mac]`, `POST /api/v1/monitoring/:service`. Semua butuh alasan + audit seperti disconnect/isolate; tulis konfigurasi tetap lewat klish sampai diputuskan.
