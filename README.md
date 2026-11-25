# BSDRP + Titian — branch `titian-api`

Patch + file tambahan untuk memasang **Titian/klish** ke image **BSDRP resmi**
(FreeBSD), **ditambah API HTTP+JSON + web UI operator** untuk BRAS.
Branch ini BUKAN fork BSDRP — isinya hanya perubahan (patch) dan file baru
yang diperlukan supaya checkout BSDRP resmi bisa di-build jadi image
BSDRP+Titian. Hanya code/teks, **tanpa binary** (tanpa `.img`, `.img.xz`,
`.pkg` hasil build).

> **FreeBSD/BSDRP saja.** Varian Linux/Debian (`.deb`) ditunda — keputusan
> 24 Nov 2026, dikerjakan nanti. Jangan cari `.deb` di branch ini.

> **Calon rilis 0.1.2 — BELUM DIRILIS.** Rilis ditahan sampai API lengkap
> selesai. Yang sudah dirilis tetap 0.1.1 (branch `bsdrp`).

- BSDRP resmi: https://github.com/ocochard/BSDRP (HEAD yang dipakai patch
  ini: `c3d134a`, 23 Okt 2026, BSDRP 2.4 WIP)
- Titian/klish: klish upstream **2.2.5**, paket Titian **0.1.1** (rilis,
  branch `bsdrp`) + API di branch ini (calon **0.1.2**)
- Status: CLI + BIRD terverifikasi (build ke-10, 11 Nov 2026); API +
  web UI terverifikasi di guest bhyve (mock + live PPPoE + redirect
  isolir E2E, 24–25 Nov 2026).

## Cara pakai (ringkas)

```sh
# 1. Clone BSDRP resmi
git clone https://github.com/ocochard/BSDRP.git
cd BSDRP

# 2. Ambil branch ini (berisi patch + file tambahan)
git clone -b titian-api https://github.com/ashadebi/titian.git bsdrp-titian

# 3. Terapkan patch + salin file baru ke checkout BSDRP
chmod +x bsdrp-titian/apply.sh   # bit executable tidak terbawa push GitHub;
                                 # atau jalankan: sh bsdrp-titian/apply.sh ...
./bsdrp-titian/apply.sh /path/ke/BSDRP

# 4. Build image seperti biasa (lihat docs/INSTALL.md)
```

`apply.sh` aman diulang (patch yang sudah terpasang
di-skip, file disalin ulang dengan isi yang sama).

## API HTTP+JSON — titian-api

Daemon `titian-api.py` (Python 3 stdlib SAJA, tanpa dependensi pip) di
router BSDRP. Dipakai web UI operator dan myRadDASH untuk melihat sesi
aktif, kick, dan isolir user lewat browser — tanpa harus paham
FreeBSD/klish. Detail lengkap: `doc/titian-api.md` (ID) /
`doc/titian-api-en.md` (EN).

- **Expose**: HTTPS, `https://<IP-manajemen>:8443` (port default 8443).
  Daemon hanya bind ke IP yang ditulis di config — `0.0.0.0` **ditolak**
  saat start. Buka TCP 8443 di pf dari host yang berhak (mis. host
  myRadDASH) — daemon tidak membuka pf sendiri.
- **Auth**: bearer token per NAS. Token dibuat sekali pakai
  `service titian-api gentoken` (hanya tampil di terminal root admin),
  disimpan di `/usr/local/etc/titian-api.conf` (mode 600). Tanpa token
  → 401, token salah → 403. Token tidak pernah dikembalikan API.
- **TLS**: sertifikat self-signed dibuat otomatis saat pertama jalan
  (`/etc/titian/*.pem`, mode 600). Sertifikat proper + pin fingerprint
  masih TODO.
- **Format JSON standar** (bisa dipakai developer lain):
  sukses `{ "status": "ok", "data": {...}, "meta": {...} }`;
  gagal `{ "status": "error", "data": null,
  "error": { "code": "KODE_STABIL", "message": "..." } }`.
  Semua jawaban `Content-Type: application/json; charset=utf-8`,
  snake_case, angka tetap angka, timestamp ISO 8601 UTC, list bawa
  `meta` (`total`, `sort`, `limit`/`offset`). Versioning di path
  (`/api/v1/`). Kode error stabil: `unauthorized`, `forbidden`,
  `not_found`, `validation_error`, `internal_error`.
- **Single-engine**: API tidak pernah menyentuh mpd5 / BIRD / pf /
  dummynet langsung — semua operasi lewat backend script yang SAMA
  dengan yang dipakai `ACTION` klish.
- **Tidak ada yang perlu di-install tambahan di BSDRP** — Python 3.12
  sudah ada di image, daemon melayani HTTPS sendiri (tanpa nginx/DB).
  Setelah `pkg add`: `gentoken` → isi config (bind IP manajemen,
  port 8443, isolir-web `103.50.129.84:80`) → `service titian-api start`
  + `enable`.

### Endpoint (94, `/api/v1/`)

| Grup | Endpoint (ringkas) |
|---|---|
| Health / NAS | `GET health`, `GET nas/status`, `GET system/version` |
| Sesi BRAS | `GET sessions` (PPPoE+IPoE, bandwidth live rx/tx bps, urut pemakaian terbesar), `GET sessions/:id` |
| Aksi tulis | `POST sessions/:id/disconnect` (kick), `POST sessions/:id/isolate`, `POST sessions/:id/unisolate` — `reason` wajib |
| Sistem | `GET system`, `memory`, `processes`, `connections`, `storage`, `sysctl`, `logins`, `hardware` |
| Service & config | `GET services`, `services/:name`, `config/running`, `config/startup`, `checkpoints` |
| Interface & jaringan | `GET interfaces`, `interfaces/:name`, `interfaces/:name/tuning`, `neighbors`, `bridges`, `vxlan`, `vxlan/:name`, `routes`, `routing`, `routing/static` |
| BIRD | `GET bird/bgp`, `bird/bgp/summary`, `bird/protocols`, `bird/protocols/:name`, `bird/routes`, `bird/routes/stats`, `bird/status`, `bird/symbols`, `bird/tables`, `bird/global`, `bird/interfaces` |
| Routing protocol | `GET ospf` (+ interfaces/neighbors/state/topology/lsadb), `rip` (+ interfaces/neighbors), `bfd`, `bfd/sessions`, `rpki`, `babel`, `direct`, `pipe`, `device`, `kernel`, `l3vpn`, `mrt`, `bmp`, `aggregator`, `radv` |
| FRR | `GET frr`, `frr/bgp`, `frr/bgp/summary`, `frr/ospf`, `frr/ospf/neighbors`, `frr/routes`, `frr/version` |
| Firewall | `GET firewall`, `firewall/filter`, `firewall/nat`, `firewall/isolated` |
| WireGuard | `GET wireguard`, `wireguard/:name` |
| Traffic-shape | `GET traffic-shape`, `profiles`, `profiles/:name`, `pipes`, `queues`, `rules`, `sched`, `statistics` |
| PPPoE / IPoE | `GET pppoe`, `pppoe/users`, `ipoe`, `ipoe/leases`, `ipoe/blocked` |
| Monitoring | `GET monitoring`, `monitoring/bandwidth` |

Endpoint tulis tetap hanya 3 (disconnect/isolate/unisolate). Semua menu
CLI lain diekspos sebagai GET (baca saja); kandidat tulis didokumentasikan
sebagai proposal, bukan diimplementasikan. Isolir = dst-nat TCP 80 **dan**
443 ke web isolir port 80 (`103.50.129.84:80`) — klien HTTPS menerima
respons HTTP polos (konsekuensi desain, bukan bug).

## Web UI operator

`web/titian-web.py` (Python 3 stdlib + sqlite3, server-side rendered) —
dashboard operator di host myRadDASH, port 9091. Akun lokal
(PBKDF2-HMAC-SHA256), peran admin vs operator (operator hanya melihat NAS
yang ditugaskan), Sesi Aktif (bandwidth live, urut pemakaian, auto-refresh
5 detik, modal alasan wajib untuk Kick/Isolir), Klien, NAS (test koneksi,
pin fingerprint TLS), Audit Log (tanpa tombol hapus). Tanpa menu Keuangan.
Web hanya memanggil titian-api dari sisi server — token tidak pernah sampai
ke browser. Detail: `web/README.md`, panduan operator di
`workspace/goals/titian-router-cli-and-web-dashboard/files/panduan-operator-titian.md`.

## Perubahan dari branch `bsdrp`

Branch ini = `bsdrp` @ `29225eb2` (0.1.1) + 10 commit berikut (18 file:
13 baru, 5 diubah):

- **Daemon API** (`titian/sbin/titian-api.py`, baru): 94 endpoint v1,
  HTTPS 8443, bearer token, JSON envelope standar, rate-limit 60,
  redaksi secret dari respons.
- **rc.d** (`files/BSDRP/Files/usr/local/etc/rc.d/titian-api`, baru):
  `gentoken` / start 0 detik / status benar (fix supervisor `daemon(8)`
  yang menahan stdio SSH).
- **Backend**: `titian-pppoe.sh` (+`sessions-detail`),
  `titian-fw.sh` (+`isolate`/`unisolate`/`show-isolated`, state
  `/usr/local/etc/isolated.conf`), `titian-sys.sh` (endpoint sistem).
- **XML klish**: `titian/tree/conf-pppoe.xml`, `conf-fw.xml`
  (perintah API di CLI).
- **Dokumen**: `doc/titian-api.md` + `doc/titian-api-en.md`,
  `doc/titian-api.conf.example` (isolir-web final `103.50.129.84:80`),
  `doc/CHANGELOG.md` (0.1.2, status masih terbuka).
- **Web UI operator** (`web/`, baru): `titian-web.py`, `Dockerfile`,
  `static/style.css`, `README.md`, `test-web.py`.
- **Port**: `TITIAN_SBIN` 67→68, pkg-plist 164→165 file (CHANGELOG ikut
  di `.pkg` di `/opt/titian/share/doc/titian/CHANGELOG.md`).

Yang TIDAK berubah dari `bsdrp`: CLI klish (59 XML / 2173 command),
BIRD/FRR/pf/dummynet, patch BSDRP 12 file, image n314296.

## Isi branch (di luar API — sama dengan `bsdrp`)

| Path | Isi |
|---|---|
| `apply.sh` | Skrip pasang: terapkan patch + salin `files/` ke checkout BSDRP |
| `patches/bsdrp-titian.patch` | Diff 12 file yang diubah vs BSDRP resmi `c3d134a` (35 KB, 859 baris) |
| `files/BSDRP/patches/ports.titian.shar` | Port lokal `net/titian` (shar teks) — payload port = XML + sbin Titian |
| `titian/tree/` | 59 file XML definisi perintah klish → `/opt/titian/etc/clish-en/` |
| `titian/sbin/` | 68 script backend → `/opt/titian/sbin/` (termasuk `titian-api.py`) |
| `titian/README.md` | Catatan sumber + hubungan dengan shar port |
| `docs/INSTALL.md` | Panduan install/deploy lengkap (dari pengalaman build ke-10) |

## Aturan keras

- **BIRD dan FRR TIDAK BOLEH aktif bersamaan** — klish deteksi + blokir
  keras saat commit (terverifikasi dua arah).
- **VPP SKIP** — tidak jalan normal di FreeBSD (baris `#net/vpp` dihapus).
- **wg-easy TIDAK BISA** (butuh Docker) — WireGuard native via klish.
- **VXLAN multicast end-to-end BELUM TERBUKTI** — jangan diklaim.
- Port `net/titian` resmi **tidak ada** — ini port lokal. MAINTAINER masih
  placeholder (`titian@bsdrp.local`), jangan submit ke FreeBSD sebelum diganti.
- API: token per NAS, config mode 600, TLS self-signed (proper cert TODO),
  pf buka TCP 8443 hanya dari host yang berhak.

Detail lengkap: `docs/INSTALL.md` · API: `doc/titian-api.md` ·
CHANGELOG: `doc/CHANGELOG.md`.
