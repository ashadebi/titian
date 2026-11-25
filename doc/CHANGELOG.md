# CHANGELOG — Titian (BSDRP)

## 0.1.2 — 2026-11-25

> **Status: masih terbuka (work in progress) — BELUM FINAL, BELUM
> DIRILIS.** Rilis 0.1.2 baru dilakukan atas perintah user terpisah
> (perintah 25 Nov 12:00: jangan dirilis dulu sampai API lengkap
> selesai). API lengkap (semua menu CLI) SUDAH masuk di bawah ini
> (25 Nov 2026); verifikasi guest bhyve sweep penuh SUDAH selesai
> (25 Nov 2026, 101/121 HTTP 200 — lihat `doc/titian-api.md` §13);
> verifikasi guest ulang SELESAI (ronde 8: T2/T5/T4 + regresi LOLOS;
> ronde 9: fallback bandwidth T3a/T3b TERBUKTI); yang masih menunggu
> sebelum rilis: diagnosis flap sesi PPPoE (T1 — diagnosis r7
> terblokir cek keamanan, butuh persetujuan eksplisit user) +
> keputusan user untuk merilis.

Rilis titian-api: paket yang sama dengan 0.1.1 ditambah daemon API
HTTPS+JSON v1 untuk operator BRAS (Fase 2). Versi ini adalah versi
titian-api sendiri, bukan versi titian 0.1.1 kemarin.

### Baru

- **titian-api** — daemon HTTPS+JSON v1 (Python 3 stdlib saja, tanpa
  dependensi pip): 7 endpoint (`/api/v1/health`,
  `/api/v1/sessions`, `/api/v1/sessions/:id`,
  `POST /api/v1/sessions/:id/disconnect`,
  `POST /api/v1/sessions/:id/isolate`,
  `POST /api/v1/sessions/:id/unisolate`, `/api/v1/nas/status`);
  bearer token per NAS (`gentoken`); `reason` wajib untuk
  disconnect/isolate/unisolate; verifikasi pasca-aksi + audit ke
  syslog; envelope JSON standar (`status`/`data`/`meta`/`error`,
  snake_case, ISO 8601 UTC).
- **rc.d `titian-api`** — service baru: `gentoken` (argumen `--name`
  diteruskan), `service start` kembali ke SSH dalam 0 detik (stdio
  supervisor dialihkan, tidak gantung), `service status` benar
  ("running as pid …").
- **Isolate/unisolate** (`titian-fw.sh` + `conf-fw.xml`) — isolir =
  dst-nat TCP 80 DAN TCP 443 ke web isolir (port web server, 80),
  tanpa blokir 443; klien HTTPS menerima respons HTTP polos
  (konsekuensi desain, bukan bug). Dummynet tidak disentuh.
- **`show pppoe-server sessions detail`** (`titian-pppoe.sh` +
  `conf-pppoe.xml`) — detail sesi untuk API (user, framed IP, link)
  + bandwidth live rx/tx per sesi (PPPoE via `netstat -I`, IPoE via
  counter pf `traffic-shape`).
- **Alamat web isolir final: `103.50.129.84:80`**
  (myradash-isolir-web via NPM, default server) — menggantikan
  placeholder `203.0.113.10:80` di contoh config.

- **API JSON semua menu CLI (25 Nov 2026)** — perluasan v1 dari 7
  menjadi **94 endpoint** (87 baru, semua GET baca): D1
  system/config/checkpoints (15: `system/version`, `system`,
  `system/memory|processes|connections|storage|sysctl|logins|hardware`,
  `services`, `services/:name`, `services/ssh`, `config/running|startup`,
  `checkpoints`), D2 interfaces/IP/routes (10: `interfaces`,
  `interfaces/:name`, `interfaces/:name/tuning`, `neighbors`, `bridges`,
  `vxlan`, `vxlan/:name`, `routes`, `routing`, `routing/static`), D3
  BIRD/routing-protocols (41: `bird/bgp`, `bird/bgp/summary`,
  `bird/protocols`, `bird/protocols/summary`, `bird/protocols/:name`,
  `bird/routes`, `bird/routes/stats`, `bird/status|symbols|tables|global|interfaces`,
  `ospf`, `ospf/interfaces|neighbors|state|topology|lsadb`, `rip`,
  `rip/interfaces|neighbors`, `bfd`, `bfd/sessions`, `rpki`, `babel`,
  `direct`, `pipe`, `device`, `kernel`, `l3vpn`, `mrt`, `bmp`,
  `aggregator`, `radv`, `frr`, `frr/bgp`, `frr/bgp/summary`, `frr/ospf`,
  `frr/ospf/neighbors`, `frr/routes`, `frr/version`), D4a
  firewall/WireGuard (6: `firewall`, `firewall/filter|nat|isolated`,
  `wireguard`, `wireguard/:name`), D4b traffic-shape/BRAS/monitoring
  (15: `traffic-shape`, `traffic-shape/profiles`,
  `traffic-shape/profiles/:name`, `traffic-shape/pipes|queues|rules|sched|statistics`,
  `pppoe`, `pppoe/users`, `ipoe`, `ipoe/leases|blocked`, `monitoring`,
  `monitoring/bandwidth`). Kontrak JSON yang sama (envelope, snake_case,
  paginasi, cap 2000 baris, `raw`+`warnings` untuk baris gagal-parse;
  subsistem down → 200 `available: false`, bukan 500). Satu-satunya
  backend baru: subcommand `titian-sys.sh storage`. Mock gabungan
  (daemon asli + backend stub + HTTPS asli) **213/213 PASS** (sesudah
  perbaikan pasca-guest di bawah); verifikasi guest bhyve sweep penuh
  SUDAH selesai 25 Nov 2026 (101/121 HTTP 200 — rincian di
  `doc/titian-api.md` §13). Endpoint tulis tetap yang lama
  (disconnect/isolate/unisolate); usulan tulis baru dicatat di
  `doc/titian-api.md` §13, tidak diimplementasikan.

- **Perbaikan pasca-verifikasi guest (25 Nov 2026)** — `/config/running`
  tanpa save → 200 `available: false` (bukan 500); `monitoring/bandwidth`
  fallback sampling counter netstat bila `bwm-ng` tidak terpasang
  (image 0.1.1); entri ARP `permanent`/`expired` FreeBSD kini ter-parse
  di `/neighbors`; `/bird/protocols/:name` → 200 `available: false` bila
  BIRD down (diputuskan, bukan bug), 404 bila BIRD up + nama tak ada.
  Koreksi lanjutan (commit `40ae9d3`, teruji guest ronde 9): `bwm-ng`
  ternyata ADA di image (`bwm-ng-0.6.3_1`) — 500 di ronde 3 adalah
  deteksi PATH-dependent, bukan biner hilang; backend kini meresolusi
  `bwm-ng` via PATH + lokasi absolut; kolom fallback diperbaiki
  ($7/$10 → $8/$11 Ibytes/Obytes + kupas `*` enc0) — fallback
  TERBUKTI: judul fallback + em0 ~71–74 Kbps saat trafik ping, cocok
  dengan `netstat -ib`.

### Dokumen (di repo, tidak ikut ter-install paket)

- `doc/titian-api.md` + `doc/titian-api-en.md` (panduan API ID+EN —
  kini 94 endpoint, §6.1–6.94, + catatan asumsi & usulan tulis di §13),
  `doc/titian-api.conf.example`. File changelog ini satu-satunya
  dokumen yang ikut di dalam .pkg
  (`/opt/titian/share/doc/titian/CHANGELOG.md`).

### Tidak berubah / di luar paket ini

- Integrasi myRadDASH dan web UI operator adalah repo/layanan lain
  (bukan isi .pkg ini).
- klish 2.2.5, BIRD 2, FRR 10.7.1 — sama seperti 0.1.1.

## 0.1.1 — 2026-11-24

Rilis sebelumnya (tag `titian-bsdrp-0.1.1`): perbaikan checkpoint,
auto-up parent VLAN, updater, dan nama paket — lihat rilis GitHub.
