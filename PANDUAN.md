# Panduan Teknis Titian 0.1 — Instalasi dan Penggunaan

Titian adalah CLI gaya Cisco/Junos untuk router, dibangun di atas klish 2.2.5
dan BIRD 2, untuk Debian dan FreeBSD. Dokumen ini menjelaskan instalasi dari
paket rilis 0.1 dan penggunaan dasar. Dashboard web belum termasuk di rilis
ini; CLI adalah satu-satunya lapisan query/eksekusi (prinsip single-engine:
jangan mengedit konfigurasi BIRD atau file di `/opt/titian` dengan tangan —
semua lewat perintah CLI).

## Persyaratan

- Debian 13 amd64, atau FreeBSD 15.0 amd64.
- Akses root/sudo di mesin router.
- Koneksi internet saat instalasi (untuk dependensi dari repositori OS).

## Instalasi

Unduh paket sesuai OS dari halaman Releases repositori ini:

- Debian: `titian_0.1.0_amd64.deb`
- FreeBSD: `titian-0.1.0.pkg`

### Debian

```sh
sudo apt install ./titian_0.1.0_amd64.deb
```

Perintah ini ikut menarik dependensi: `libexpat1`, `bird2`, `iproute2`,
`procps`, `sudo`, `logrotate`.

### FreeBSD

```sh
sudo pkg add ./titian-0.1.0.pkg
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

## Lingkup rilis 0.1

Rilis 0.1 memuat CLI Fase 1: definisi perintah klish, manajemen interface
dasar, dan pembangkit konfigurasi BIRD dengan persistensi. Fitur yang
dikembangkan sesudah 0.1.0 — tuning, speed, VXLAN, checkpoint/rollback,
rename interface, firewall/NAT — tersedia di source tree repositori ini,
tetapi BELUM masuk ke paket biner 0.1.0. Fitur-fitur itu akan ikut pada
rilis berikutnya.

## Uninstalasi

Debian:

```sh
sudo apt remove titian
```

FreeBSD:

```sh
sudo pkg delete titian
```
