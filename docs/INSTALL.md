# INSTALL — BSDRP + Titian (deploy)

Panduan install/deploy image BSDRP+Titian, ditulis dari pengalaman
**build ke-10** (11 Nov 2026) yang sudah terverifikasi end-to-end:
build → image bird2 + bird3 → dd ke UFD → sha256 read-back cocok →
CLI teruji → boot bhyve OK. Bukan teori — semua langkah di bawah
pernah dijalankan dan hasilnya dicatat.

## 0. Ringkasan alur

```
clone BSDRP resmi → apply.sh (branch ini) → build (poudriere, berjam-jam)
→ verifikasi image (sha256) → dd ke UFD → boot (bhyve dulu, lalu hardware)
→ konfigurasi awal (em0, sshd, titian) → uji CLI
```

## 1. Prasyarat

### Host build (contoh yang dipakai: "kopler")

- **FreeBSD 16.0-CURRENT** (host build; image yang dihasilkan FreeBSD 16).
  BSDRP 2.4 WIP membutuhkan FreeBSD 16 — FreeBSD 15 tidak cukup.
- **poudriere** (poudriere-git 3.4.99) + ZFS. Repo BSDRP mem-pin:
  FreeBSD src `775e421dc38`, ports tree `076f4cba6304`.
- **RAM 8 GB** (host kopler). Ini sempit — build pernah OOM (rust,
  gcc14, x265, llvm19). Patch sudah mengatur `PARALLEL_JOBS=2`,
  `USE_TMPFS=no`, `MAKE_JOBS_NUMBER=2` (di `BSDRPj-make.conf`) dan
  `MAX_EXECUTION_TIME_llvm19=345600` (4 hari, llvm19 saja).
  Jangan naikkan job paralel di host 8 GB.
- **Disk**: ZFS dengan ruang bebas memadai (image 15 GB per varian,
  plus obj/ports + packages; kopler: zroot 1,64 TB bebas).
- **Jaringan**: host build harus bisa fetch. klish 2.2.5 di-fetch dari
  `src.libcode.org` — kalau fetch gagal, salin tarball klish ke
  `/root/distfiles/` (mode 644) lalu build ulang (itu fix build 9b).
- **pkg host harus sehat**. Pernah rusak (build 7): `pkg -v` gagal
  `ld-elf.so.1: /lib/libc.so.7: version FBSD_1.9 required`. Perbaikan:
  backup `/usr/local/sbin/pkg` yang rusak, ganti dengan salinan
  `pkg-static` 2.8.4, lalu `pkg -v` harus OK sebelum build.
- **JANGAN** jalankan `make upstream-sync` (menarik upstream dan bisa
  menghapus perubahan lokal). **JANGAN** `make clean-all` (mulai dari
  nol — WORLD + PORTS + BULK dari awal, berjam-jam hilang).

### Mesin target

- Router x86-64, boot dari **UFD 16 GB** (image 15 GB). Disarankan
  SanDisk Cruzer Blade 16 GB (yang dipakai build 10).
- Untuk uji CLI interaktif di hardware: mesin multi-NIC
  (igb/ixl) + kabel ke MikroTik + akses konsol.

## 2. Siapkan tree BSDRP + Titian

```sh
# Di host build (FreeBSD), sebagai root:
git clone https://github.com/ocochard/BSDRP.git
cd BSDRP
git checkout c3d134a3036a763a6698d806e00c210a5fa9514a   # HEAD yang dipakai patch

# Ambil branch ini (patch + file tambahan + sumber Titian)
git clone -b bsdrp https://github.com/ashadebi/titian.git bsdrp-titian

# Terapkan patch + salin file baru
./bsdrp-titian/apply.sh /path/ke/BSDRP
```

Verifikasi: `git status --short` di checkout BSDRP harus menunjukkan
**21 entri** (12 modified + 9 untracked). Kalau beda, jangan lanjut —
periksa error `apply.sh` (patch hanya cocok untuk HEAD `c3d134a`).

## 3. Build image

Build didorong Makefile repo (poudriere). Target utama:

| Perintah | Hasil |
|---|---|
| `make` (atau `make release`) | Image varian default (**BIRD_VERSION=2**) |
| `make BIRD_VERSION=3 release` | Image varian bird3 |
| `make help` | Daftar variabel (termasuk `BIRD_VERSION=2\|3`) |
| `make compress-images` / `make checksum-images` | Kompres + sha256 (bagian dari release) |

Catatan penting:

- **Satu varian per pemanggilan make.** Build ke-10 membangun bird2
  dulu, lalu bird3 (dengan `rm -f obj/build-packages` di antaranya —
  sentinel poudriere; tanpa itu bulk kedua tidak jalan). Kalau pakai
  driver skrip sendiri, urutkan: WORLD → PORTS → BULK bird2 →
  IMAGE bird2 → BULK bird3 → IMAGE bird3 → VERIFY → RELEASE.
- **Waktu**: berjam-jam. WORLD + PORTS + BULK (ratusan paket, termasuk
  llvm19 yang bisa 24 jam+) + IMAGE. Build ke-10 selesai dalam satu
  sesi malam. **Jalankan detached** (contoh pola yang dipakai):
  `nohup make release >/root/build.log 2>&1 &`, lalu monitor log
  berkala. Jangan biarkan sesi SSH putus di tengah build.
- **Hasil build** ada di `/usr/local/poudriere/data/images/`:
  `BSDRP-n314296-full-bird2-amd64.img` (+ `.img.xz` + `.sha256`) dan
  varian `-bird3-` yang sama. Ukuran `.img` = **15.357.501.440 byte**
  (15 GB). Nama image sudah dibedakan per varian — jangan tertukar.
- **Verifikasi image** (wajib sebelum dd):
  `sha256 -c BSDRP-...-bird2-amd64.img.sha256` (atau bandingkan
  manual `sha256 <file>` dengan isi `.sha256`). Build ke-10:
  bird2 `.img` sha256
  `64c5b2a0914c2d5f31b42470303b10616ae1670ce8536c96ac199a97d9744820`,
  bird3 `.img` sha256
  `892179d82b96e7c1ea43f6389b4700b8280cd83e9d6da55b0f7f99b096e8daf7`.
  Catatan: `make release` menghapus `.img` asli setelah xz — kalau
  butuh `.img`-nya lagi, restore dengan `xz -dk <file>.img.xz`.
- **Celah yang pernah terjadi**: kompresi xz bisa OOM-killed di host
  8 GB (build 8: `.img.xz` bird2 parsial 190 MB, tanpa `.sha256`).
  Kalau `.img.xz` tidak lengkap / tanpa `.sha256`, jangan dipakai —
  kompres ulang saat RAM lega.

## 4. Tulis image ke UFD (dd)

**PERINGATAN — baca dulu, jangan asal dd.**

- **Target = UFD (`da*`), JANGAN PERNAH `ada0`** (boot disk host build,
  WDC 2 TB di kopler). Salah target = host build hilang.
- Kenali dulu UFD-nya: `gpart show` / `diskinfo da0` — SanDisk Cruzer
  Blade 16 GB ≈ 15.669.919.744 byte. Pastikan ukurannya cocok dan
  serial-nya benar sebelum dd.
- dd menimpa **seluruh** UFD (wipe penuh). Pastikan tidak ada data
  penting di UFD itu.

```sh
# Contoh build ke-10 (bird2, 15.357.501.440 byte, ~21 menit, ~12 MB/s):
dd if=BSDRP-n314296-full-bird2-amd64.img of=/dev/da0 bs=1m conv=sync
# Tunggu sampai selesai (DD_EXIT=0). Jangan cabut UFD sebelum selesai.
```

**Verifikasi wajib — sha256 read-back:**

```sh
# Baca balik seluruh isi UFD dan hitung sha256-nya; harus COCOK PERSIS
# dengan sha256 file .img (bukan .img.xz).
dd if=/dev/da0 bs=1m count=14647 | sha256
# atau: sha256 -q /dev/da0  (baca penuh; ~29 menit di build 10)
```

Build ke-10: read-back cocok persis `64c5b2a0…` (bird2).
**Jangan boot UFD yang sha256 read-back-nya tidak cocok.**
Flag `[CORRUPT]` pada `gpart show da0` setelah dd adalah ekspektasi
(bukan kerusakan) — sama seperti build 8.

## 5. Boot

### 5a. Uji bhyve dulu (sebelum hardware)

- Buat VM bhyve **1 vCPU** (host kopler hanya menyediakan 1 vCPU
  untuk bhyve — `-c 2` gagal), RAM 2 GB, disk dari **SALINAN** image
  (jangan pakai file image asli; jangan pakai image yang dipatch
  untuk uji sebagai sumber dd).
- Konsol serial via **nmdm** (`-l com1,/dev/nmdm0A`, host baca
  `/dev/nmdm0B`) + `console="comconsole"` di `/boot/loader.conf.local`
  **pada salinan saja**. Backend com1 file biasa DITOLAK bhyve (ENOTTY).
- Yang terverifikasi di bhyve (build 10): bhyveload rc=0, kernel boot,
  logo + menu **tanpa baris Version**, konfd start, sshd start, login
  prompt ttyu0, em0 + inet 10.9.8.7, ping guest OK.
- Yang BELUM terverifikasi di bhyve (harness, bukan image): CLI
  interaktif di guest (getty ttyu0 cycling, tap0 flaky, SSH auth
  ditolak meski kredensial benar). **Jangan simpulkan image rusak
  dari kegagalan harness bhyve** — uji di hardware nyata.

### 5b. Boot hardware (mesin target)

- Boot dari UFD (pilih UFD di boot menu).
- **Gotcha config lama (penting!)**: kalau disk internal mesin sudah
  berisi install BSDRP lama, ada **dua partisi berlabel `cfg`** (satu
  di disk internal, satu di UFD). BSDRP me-restore config dari partisi
  `cfg` — dan config lama dari disk internal bisa menimpa image baru
  (ini yang terjadi 11 Nov malam: hostname lama, error vppctl ×8,
  error pimd, jam UTC — semuanya dari config lama, BUKAN dari image).
  **Sebelum boot pertama dari UFD baru di mesin yang punya install
  lama**: kosongkan kedua partisi `cfg` (internal + UFD), lalu tulis
  config bersih yang sama ke keduanya (lihat §6). Backup dulu config
  lama (tarball) sebelum menghapus.
- Setelah boot, login konsol. **Password root image = default
  (KOSONG)** — segera set password baru via konsol. SSH root
  key-only (pasang pubkey ke `/root/.ssh/authorized_keys`).

## 6. Konfigurasi awal

Default image (dari patch ini):

- **em0 10.9.8.7/24**, sshd YES, Titian/klish YES.
- bird, FRR, VPP, pimd, ngnetflow: **NO**. Monitoring (snmpd,
  node_exporter, bird_exporter, nfacctd): **NO**.
- Hostname: `bsdrp.ashadebi-kopler.net`.

Contoh config bersih (rc.conf) untuk mesin test:

```
hostname="bsdrp.ashadebi-kopler.net"
ifconfig_igb3="inet 10.10.2.4 netmask 255.255.255.248"
defaultrouter="10.10.2.1"
sshd_enable="YES"
```

Sesuaikan interface (em0/igb0-3/ixl0-3) dengan hardware — em0
**tidak ada** di mesin test user (igb0-3 + ixl0-3). Jangan pakai
`rc.local` lama (mengandung `vppctl` yang tidak ada di image ini).

Masuk CLI Titian:

```sh
titian            # full path /usr/local/bin/titian
cli-<hostname>#   # prompt; `cli` tetap milik FRR (vtysh) — jangan bentrok
```

Perintah yang terverifikasi jalan: `show version` (klish 2.2.5),
`show system`, `show interfaces`, `show routing`, `show firewall`,
`show monitoring`, `show traffic-shape`, `bird terminal` → `(birdc)#`.
`commit` = tulis file + restart service. `save` = `config save`.

## 7. Aturan & catatan operasional

- **BIRD vs FRR saling eksklusif.** Jangan aktifkan keduanya —
  klish memblokir saat commit (terverifikasi dua arah). Pilih satu.
- **VPP skip.** Tidak jalan normal di FreeBSD; jangan tambahkan
  `net/vpp` ke pkglist (baris komentar `#net/vpp` saja sudah pernah
  menggagalkan `pkg install` di tahap image — poudriere image.sh
  melewatkan baris komentar mentah ke `pkg install`).
- **Firewall/NAT**: forward default DENY; DNAT butuh forward permit
  ke tujuan terjemahan; guard anti-lockout menolak rule yang memakai
  protected interface (default em0).
- **Limiter dummynet**: backend `ipfw` pipe + pf `dnpipe` (`dnctl`
  tidak ada di FreeBSD ini). Pipe 1–99, queue 100–199, sched 200–299.
- **VXLAN multicast end-to-end BELUM TERBUKTI** — jangan klaim.
- **PPPoE (mpd5)**: RADIUS, tanpa CoA. Sintaks `mpd.conf` belum
  live-test — verifikasi di hardware sebelum andalkan.
- **WireGuard**: native, default manual. Sintaks `ifconfig wg`
  belum live-test.
- **Monitoring**: SNMP community default `bsdrp-ro` — **ganti sebelum
  expose**. Monitoring OFF by default; nyalakan via klish bila perlu.
- **Port `net/titian`**: MAINTAINER placeholder
  (`titian@bsdrp.local`) — jangan submit ke FreeBSD sebelum diganti.
  Kalau mengedit XML/sbin di `titian/`, rebuild juga shar
  (`files/BSDRP/patches/ports.titian.shar`) — lihat `titian/README.md`.
- **Patch dpdk**: kalau ports tree dibuat ulang, patch dpdk
  (`SYSCTL_NODE_CHILDREN` → `SYSCTL_STATIC_CHILDREN`) harus dipasang
  lagi, dan file patch di ports tree WAJIB mode 644 (poudriere
  patching jalan sebagai user `nobody` — mode 640 pernah menggagalkan
  bulk).
- **File yang disalin ke ports tree / container WAJIB chmod 644.**
  `cp` mempertahankan mode sumber — selalu chmod eksplisit setelah cp.
- **Jangan `make upstream-sync`, jangan `make clean-all`** (lihat §1).

## 8. Yang masih terbuka (per 12 Nov 2026)

- Uji CLI interaktif di hardware nyata (prompt titian, show di guest,
  `service -e`, commit mutual-exclusion end-to-end, `bird terminal` →
  `show status` dengan birdc asli).
- Verifikasi boot bersih pasca-reboot di mesin test (config bersih
  sudah ditulis 11 Nov malam; verifikasi belum selesai).
- Uji live LACP/LAGG, VXLAN, limiter, firewall/NAT (butuh router
  multi-NIC + MikroTik + 2 endpoint iperf3).
- Cek kabel/port MikroTik soal igb3 "no carrier".
- BFD single-hop test (RPKI/BFD CLEAR berkualifikasi, BFD test pending).
- Validasi monitoring (SNMP/node_exporter/bird_exporter/nfacctd)
  setelah di-ON-kan.
