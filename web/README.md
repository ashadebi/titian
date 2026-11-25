# TITIAN Web UI operator — Fase 2 langkah 4

Web UI operator Titian (BRAS): login, Dashboard, Sesi Aktif (bandwidth live,
urut pemakaian terbesar), Klien, NAS, Audit Log, Pengguna & Peran.
**Tidak ada menu Keuangan.**

## Stack (keputusan yang ditetapkan)

Python 3 stdlib SAJA + sqlite3, server-side rendered, vanilla JS kecil
(auto-refresh 5 detik + modal alasan). Alasan: preseden titian-api +
`titian-ipoe-acct.py` (stdlib saja, tanpa build step), paling sederhana
dirawat di host 84, dan kontrak API-nya identik sehingga port ke stack
myRadDASH (Next.js) tetap bisa dilakukan nanti tanpa mengubah API.

## Prinsip mengikat

- Single-engine: web TIDAK PERNAH menyentuh mpd5/BIRD/pf langsung —
  hanya titian-api, dari SISI SERVER (token tidak pernah ke browser).
- Token NAS: file `data/nas-tokens.conf` mode 600 (`nama <token>`),
  ditulis via UI admin / CLI. DB hanya menyimpan referensi + flag.
- TLS self-signed titian-api: diterima HANYA dengan pin fingerprint
  SHA-256 per NAS. Tanpa fingerprint → koneksi ditolak. Pengecualian
  `tls_insecure_lab` HANYA untuk lab — jangan dipakai produksi.
- Kick/Isolir/Buka Isolir: alasan wajib (1–200 karakter), tercatat di
  audit log. Audit log TIDAK BISA dihapus siapa pun (tidak ada endpoint hapus).
- Isolir = dst-nat TCP 80 DAN 443 ke web isolir (port web server, 80),
  tanpa blokir 443; dummynet TIDAK diubah. Web isolir default masih
  placeholder `203.0.113.10:80` (TEST-NET-3) — belum diputuskan user.

## Jalankan lokal

```sh
python3 titian-web.py check --data ./data
python3 titian-web.py create-admin --username admin   # password dicetak SEKALI
python3 titian-web.py serve --data ./data --port 9091
# buka http://127.0.0.1:9091/login
```

Fingerprint TLS titian-api (untuk diisi di menu NAS):

```sh
python3 titian-web.py fetch-fingerprint --url https://10.0.0.1:8443
```

## Uji (mock)

```sh
python3 test-web.py   # butuh mock titian-api di ../mock/ ; hasil di test-web-log.txt
```

## Deploy (host 84)

```sh
docker build -t titian-web:1.0.0 .
docker run -d --name titian-web --restart unless-stopped \
  -v /opt/titian-web/data:/data -p 0.0.0.0:9091:9091 titian-web:1.0.0
docker exec titian-web python3 /app/titian-web.py create-admin --username admin
# password admin dicetak SEKALI di output exec — simpan, lalu jangan dicatat lagi
```

Data persisten di `/opt/titian-web/data` (`titian-web.db` + `nas-tokens.conf`
mode 600). Backup: salin direktori data itu.
