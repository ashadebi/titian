# BSDRP + Titian — branch `bsdrp`

Patch + file tambahan untuk memasang **Titian/klish** ke image **BSDRP resmi**.
Branch ini BUKAN fork BSDRP — isinya hanya perubahan (patch) dan file baru
yang diperlukan supaya checkout BSDRP resmi bisa di-build jadi image
BSDRP+Titian. Hanya code/teks, **tanpa binary** (tanpa `.img`, `.img.xz`,
`.pkg` hasil build).

- BSDRP resmi: https://github.com/ocochard/BSDRP (HEAD yang dipakai patch
  ini: `c3d134a`, 23 Okt 2026, BSDRP 2.4 WIP)
- Titian/klish: klish upstream **2.2.5**, paket Titian **0.1.0**
- Status: **terverifikasi build ke-10** (11 Nov 2026, image bird2 + bird3
  selesai, dd ke UFD + sha256 read-back cocok, CLI teruji di kopler)

## Cara pakai (ringkas)

```sh
# 1. Clone BSDRP resmi
git clone https://github.com/ocochard/BSDRP.git
cd BSDRP

# 2. Ambil branch ini (berisi patch + file tambahan)
git clone -b bsdrp https://github.com/ashadebi/titian.git bsdrp-titian

# 3. Terapkan patch + salin file baru ke checkout BSDRP
chmod +x bsdrp-titian/apply.sh   # bit executable tidak terbawa push GitHub;
                                 # atau jalankan: sh bsdrp-titian/apply.sh ...
./bsdrp-titian/apply.sh /path/ke/BSDRP

# 4. Build image seperti biasa (lihat docs/INSTALL.md)
```

`apply.sh` idempotent — dijalankan 2x aman (patch yang sudah terpasang
di-skip, file disalin ulang dengan isi yang sama). Setelah apply,
`git status` di checkout BSDRP menunjukkan 21 entri (12 modified +
9 untracked) — sama persis dengan keadaan build ke-10.

## Isi branch

| Path | Isi |
|---|---|
| `apply.sh` | Skrip pasang: terapkan patch + salin `files/` ke checkout BSDRP |
| `patches/bsdrp-titian.patch` | Diff 12 file yang diubah vs BSDRP resmi `c3d134a` (35 KB, 859 baris) |
| `files/` | 9 file baru, path relatif sama seperti di repo BSDRP |
| `files/BSDRP/patches/ports.titian.shar` | Port lokal `net/titian` (shar teks) — payload port = XML + sbin Titian |
| `files/BSDRP/Files/etc/pf.conf` | pf.conf dasar (anchor nat/rdr/firewall/traffic-shape) |
| `files/BSDRP/Files/usr/local/etc/nfacctd.conf` + `rc.d/nfacctd` + `newsyslog.conf.d/nfacctd` | pmacct/nfacctd (port pmacct tidak menyediakan rc script) |
| `files/BSDRP/Files/usr/local/sbin/clear-logs` | `system logs clear` (hanya /var/log) |
| `files/BSDRP/Files/usr/local/share/info/.keep` | Direktori kosong penahan (fix indexinfo post-install) |
| `files/poudriere.etc/poudriere.d/BSDRP-pkglist.bird2` / `.bird3` | Pkglist per varian BIRD (switch `BIRD_VERSION`, default 2) |
| `titian/` | **Sumber Titian CLI sebagai file mandiri** (bukan hanya di dalam shar) |
| `titian/tree/` | 36 file XML definisi perintah klish → `/opt/titian/etc/clish-en/` |
| `titian/sbin/` | 24 script backend → `/opt/titian/sbin/` |
| `titian/README.md` | Catatan sumber + hubungan dengan shar port |
| `docs/INSTALL.md` | Panduan install/deploy lengkap (dari pengalaman build ke-10) |
| `docs/titian-bsdRP-feature-list.md` | Daftar fitur Titian untuk BSDRP (spesifikasi port) |

## Yang diubah patch (12 file)

- **Brand/boot**: logo router merah-putih (18 baris × 36 kolom), judul menu
  `BSDRP - bsdrp.ashadebi-kopler.net`. **Baris `Version: n314296` DIHAPUS
  dari banner** (keputusan user 11 Nov).
- **Service default**: hanya **em0 10.9.8.7/24 + sshd + Titian/klish** yang
  nyala. bird, FRR, VPP, pimd OFF; monitoring (snmpd, node_exporter,
  bird_exporter, nfacctd) OFF — bisa di-ON-kan via klish bila perlu.
- **BIRD 2 vs 3**: switch `BIRD_VERSION` (default 2) di Makefile; pkglist
  terpisah per varian; 4 nama image bersuffix `-bird${BIRD_VERSION}`;
  `net/bird2` dihapus dari pkglist.common (diganti file per-varian).
- **Kernel**: `device mlx4` + `device mlx4en` ditambah; `device igb` dihapus
  (igb dilebur ke `em` sejak FreeBSD 12 — ini penyebab build 1 gagal).
- **Paket**: +33 paket (nano, htop, net-snmp, node_exporter,
  prometheus-bird-exporter, dpdk, mpd5, dsb.); `net/aquantia-atlantic-kmod`
  dihapus (tidak ada paketnya); dnsdist dihapus (gagal build).
- **Config default**: `rc.conf` (hostname `bsdrp.ashadebi-kopler.net`,
  em0 10.9.8.7/24, sshd/titian YES, sisanya NO), `vendor.conf`
  (monitoring NO), `snmpd.conf` (SNMPv2c RO — ganti community `bsdrp-ro`
  sebelum expose), `BSDRPj-make.conf` + `BSDRPj-poudriere.conf`
  (tuning build: PARALLEL_JOBS=2, USE_TMPFS=no, fix llvm19/dpdk/libsoup3).
- **Ukuran image**: 15 GB (`-s 15g`, muat UFD 16 GB).

## Aturan keras

- **BIRD dan FRR TIDAK BOLEH aktif bersamaan** — klish deteksi + blokir
  keras saat commit (terverifikasi dua arah).
- **VPP SKIP** — tidak jalan normal di FreeBSD (baris `#net/vpp` dihapus).
- **wg-easy TIDAK BISA** (butuh Docker) — WireGuard native via klish.
- **Web dashboard Titian TIDAK termasuk** (komponen terpisah, ditahan).
- **VXLAN multicast end-to-end BELUM TERBUKTI** — jangan diklaim.
- Port `net/titian` resmi **tidak ada** — ini port lokal. MAINTAINER masih
  placeholder (`titian@bsdrp.local`), jangan submit ke FreeBSD sebelum diganti.

## Verifikasi build ke-10 (yang sudah terbukti)

- Image bird2: `BSDRP-n314296-full-bird2-amd64.img`, 15.357.501.440 byte,
  sha256 `64c5b2a0914c2d5f31b42470303b10616ae1670ce8536c96ac199a97d9744820`
- Image bird3: sha256 `892179d82b96e7c1ea43f6389b4700b8280cd83e9d6da55b0f7f99b096e8daf7`
- CLI terverifikasi di kopler: prompt `cli-kopler#`, nol error parse XML
  (36 file), `show system/interfaces/routing/firewall/monitoring/traffic-shape`
  jalan, mutual-exclusion dua arah OK, `bird terminal` masuk sub-mode.
- DD ke UFD (SanDisk Cruzer Blade 15,6 GB) + sha256 read-back **cocok persis**.
- Boot bhyve terverifikasi (konfd+sshd start, em0 10.9.8.7, ping OK).
  CLI interaktif di guest BELUM teruji — perlu uji di hardware nyata.

Detail lengkap: `docs/INSTALL.md` · fitur: `docs/titian-bsdRP-feature-list.md`.
