# Panduan Teknis Titian 0.1.1 — Instalasi dan Penggunaan

Titian adalah CLI gaya Cisco/Junos untuk router, dibangun di atas klish 2.2.5
dan BIRD 2, untuk FreeBSD/BSDRP. Dokumen ini menjelaskan instalasi dari
paket rilis 0.1.1 dan penggunaan dasar. Panduan ini hanya untuk branch
`bsdrp` (FreeBSD/BSDRP saja, tanpa API); untuk Debian (Linux), lihat
panduan di branch `main`. Dashboard web belum termasuk di rilis
ini; CLI adalah satu-satunya lapisan query/eksekusi (prinsip single-engine:
jangan mengedit konfigurasi BIRD atau file di `/opt/titian` dengan tangan —
semua lewat perintah CLI).

## Persyaratan

- FreeBSD/BSDRP amd64.
- Akses root/sudo di mesin router.
- Koneksi internet saat instalasi (untuk dependensi dari repositori OS).

## Instalasi

Unduh paket dari halaman Releases repositori ini:

- FreeBSD: `titian-bsdrp-0.1.1.pkg`

### FreeBSD

```sh
sudo pkg add ./titian-bsdrp-0.1.1.pkg
```

Dependensi: `bird2`, `sudo`, `expat`.

## Menjalankan CLI

```sh
sudo /usr/local/bin/titian
```

Perintah yang tersedia di dalam sesi interaktif bisa dilihat dengan `?`.
Keluar dari sesi dengan `exit`.

## Penggunaan dasar

Melihat ringkasan sistem dan daftar interface (mode exec):

```
show system
show interfaces
```

Masuk ke mode konfigurasi:

```
configure terminal
```

Menyimpan konfigurasi (dari mode exec, bukan dari dalam mode konfigurasi):

```
save
```

Setelah `save`, konfigurasi tersimpan di `/opt/titian/etc/startup-config`
dan dimuat lagi saat service start. Konfigurasi BIRD yang dihasilkan CLI
jangan diedit manual — ubah lewat perintah CLI lalu `save` lagi.

## Lingkup rilis 0.1.1

Rilis 0.1.1 memuat CLI Fase 1: definisi perintah klish, manajemen interface
dasar, dan pembangkit konfigurasi BIRD dengan persistensi, ditambah tuning,
speed, VXLAN, checkpoint/rollback, rename interface, dan firewall/NAT.
Daemon API `titian-api` dan web UI operator TIDAK termasuk di branch ini —
keduanya ada di branch `titian-api`.

## Uninstalasi

FreeBSD:

```sh
sudo pkg delete titian
```
