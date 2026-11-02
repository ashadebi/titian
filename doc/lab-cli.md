# Lab CLI Titian — Hasil Uji dengan Lawan MikroTik CHR

Dokumen ini menampilkan hasil lab CLI Titian: apa yang diuji, melawan apa,
dan apa yang terbukti — termasuk apa yang TIDAK terbukti. Lab ini dijalankan
28 Oktober – 2 November 2026 di atas tiga mesin virtual: dua guest Titian
(Debian dan FreeBSD) dan satu MikroTik CHR sebagai lawan uji routing.
Semua alamat di bawah adalah alamat privat jaringan lab (NAT libvirt dan
link point-to-point terisolasi), bukan alamat publik.

Dokumen pendamping: `panduan-cli.md` (cara pakai CLI),
`../PANDUAN.md` (instalasi dari paket rilis).

## 1. Bagan topologi lab

```
                    ┌─────────────────────────────┐
                    │  Host virtualisasi (KVM)    │
                    │  jaringan NAT libvirt       │
                    │  192.168.122.0/24           │
                    └──────┬──────────┬──────┬───┘
                           │          │      │
                 mgmt      │          │      │      mgmt
              192.168.122.50│  .116    │      │ .219
                           ▼          ▼      ▼
                  ┌────────────┐ ┌──────────┐ ┌──────────────┐
                  │ titian-    │ │ titian-  │ │ titian-chr   │
                  │ debian     │ │ freebsd  │ │ MikroTik CHR │
                  │ Debian 13  │ │ FreeBSD  │ │ RouterOS 7.25│
                  │ BIRD 2.17.5│ │ 15.0     │ │ AS 64513     │
                  │ AS 64512   │ │ BIRD     │ │              │
                  │            │ │ 2.19.2_1 │ │              │
                  │            │ │ AS 64514 │ │              │
                  └─────┬──────┘ └──────────┘ └──────┬───────┘
                        │  link PtP terisolasi        │
                        │  (jaringan khusus PtP,      │
                        │   bukan lewat NAT)          │
                        └─────────────┬───────────────┘
                                      │
                        Debian enp9s0 ◄──► CHR ether2
                        PtP: 203.0.113.77
                        peer: 10.44.55.66
```

Keterangan bagan:

- **Jaringan management (NAT)** dipakai untuk SSH dan kontrol lab. Ketiga
  VM terhubung ke sini. RPKI cache lab (StayRTR) juga berada di jaringan
  ini.
- **Link PtP terisolasi** hanya menghubungkan Debian dan CHR — inilah
  jalur yang dipakai untuk uji point-to-point, BGP, dan ping dua arah.
  FreeBSD tidak punya alamat IPv4 di interface PtP-nya pada kondisi awal
  (jangkar); sesi FreeBSD↔CHR dibangun lewat jalur management/multihop
  (lihat §4).
- CHR pada lab ini memakai lisensi gratis (limit throughput 1 Mbps).
  Uji lab fokus pada kebenaran fungsi, bukan benchmark throughput.

### Tabel peran

| Mesin | OS / routing | AS | Peran di lab |
|---|---|---|---|
| titian-debian | Debian 13, BIRD 2.17.5 | 64512 | Guest Titian utama; PtP ke CHR |
| titian-freebsd | FreeBSD 15.0, BIRD 2.19.2_1 (netlink) | 64514 | Guest Titian kedua; uji portabilitas per-OS |
| titian-chr | RouterOS 7.25 | 64513 | Lawan uji independen (bukan Titian) |
| RPKI cache | StayRTR (container di host) | — | Cache VRP untuk uji validasi RPKI |

### Disiplin lab (mengapa hasil di bawah bisa dipercaya)

Setiap tahap lab mengikuti pola yang sama, dan pola ini yang membuat
hasilnya bisa diikuti ulang:

1. **Jangkar dulu.** Sebelum tahap dimulai, sidik jari file konfigurasi
   (`startup-config` dan `bird.conf` kedua guest) dicatat.
2. **Uji.** Tahap dijalankan, hasil dicatat (lulus/gagal + bukti).
3. **Bersih ke jangkar.** Setelah tahap selesai, konfigurasi
   dikembalikan dan sidik jari dicocokkan lagi — tahap berikutnya selalu
   mulai dari keadaan bersih yang sama.
4. **Satu perubahan dalam satu waktu.** Tidak ada dua tahap yang
   menyentuh guest secara paralel.

Prinsip ini penting: bila sebuah tahap mengubah guest dan tidak
dibersihkan, tahap berikutnya menguji keadaan yang sudah terkontaminasi.

---

## 2. Hasil lab per area

Ringkasan eksekutif — detail tiap baris ada di sub-bagian setelah tabel.

| Area | Uji | Hasil |
|---|---|---|
| CLI dasar + persistensi | show, configure, save, reboot | LULUS |
| PtP IPv4/IPv6 | ping dua arah Debian↔CHR | LULUS, 0% loss |
| BGP IPv4 | sesi Debian↔CHR, FreeBSD↔CHR | LULUS |
| BGP IPv6 | kedua kaki + kontrol negatif | LULUS |
| BGP community | standard, well-known, extended, large; set/match/filter dua arah | LULUS |
| Redistribusi route statik via BGP | terlihat di CHR | LULUS |
| OSPF | Full, stub/NSSA, auth, virtual-link (BIRD) | LULUS (CHR tanpa virtual-link) |
| BFD | OSPF direct; multihop-BGP | LULUS berkualifikasi (lihat §2.6) |
| RPKI | VRP valid/invalid/unknown | LULUS (trust anchor lab-lokal) |
| VXLAN unicast | guest↔guest + learning ke CHR | LULUS |
| VXLAN multicast | end-to-end | TIDAK TERBUKTI |
| Bonding/LACP (Linux) | nego + perintah speed persisten | LULUS (setelah akar ditemukan) |
| Tuning | sysctl, mtu/qlen/offload/coalesce persisten | LULUS (coalesce live belum terbukti) |
| Checkpoint/rollback | save/list/delete, rollback bernama + polos, melewati reboot | LULUS |
| Rename interface | persisten melewati reboot, kedua OS | LULUS 12/12 |
| Firewall/NAT | srcnat, dnat, filter, persistensi reboot, negatif, regresi | LULUS (batas pf §2.9) |
| Paket 0.1.0 | install .deb/.pkg di guest lab | LULUS |

### 2.1 CLI dasar dan persistensi

Perintah `show interfaces` menampilkan semua interface sistem (up/down/
disabled), bukan hanya yang dikonfigurasi. `ip address` langsung live;
`save` hanya menentukan persistensi. Verifikasi dilakukan pada artefak
yang disentuh user (file konfigurasi dan sesi CLI), bukan hanya dari
sisi host.

### 2.2 Point-to-point dan ping

```
Debian enp9s0 (203.0.113.77) ◄──► CHR ether2 (peer 10.44.55.66)
   ping dua arah: 0% loss
   IPv6 ke CHR: prefix /127, /126, /56, /64 — dua arah 0% loss
```

Temuan penting (FreeBSD): mengatur PtP FreeBSD dengan `dstaddr` di
interface Ethernet broadcast SALAH — ifconfig mengabaikannya dan ping
loss 100%. Bentuk yang benar: alamat lokal `/32` + route host ke peer
via interface, dengan persistensi yang sama di rc.conf. Perilaku ini
sudah diterapkan Titian, jadi pengguna cukup memakai sintaks `peer`
yang sama di kedua OS.

### 2.3 BGP melawan CHR

```
        AS 64512 (Debian) ◄──► AS 64513 (CHR) ◄──► AS 64514 (FreeBSD)
              IPv4 + IPv6              IPv4 + IPv6
              communities              communities
              dua arah                 dua arah
```

- Sesi BGP IPv4 dan IPv6 kedua kaki Established.
- Kontrol negatif dilakukan (sesi yang seharusnya tidak terbentuk
  memang tidak terbentuk) dan verifikasi dilakukan dari sisi CHR juga,
  bukan hanya dari guest Titian.
- **FreeBSD membutuhkan multihop:** alamat PtP `/32` tidak
  directly-connected di device protocol BIRD, sehingga sesi BGP FreeBSD
  hanya Established dengan `multihop 2` + static peer route. Vonis awal
  "platform-blocked" untuk BGP FreeBSD dicabut setelah akar ini ditemukan
  — ini pelajaran lab yang paling berharga: jangan vonis platform
  sebelum akar diisolasi.
- Community: standard, well-known, extended, dan large — set, match,
  dan filter — terverifikasi dua arah melawan CHR.
- Redistribusi route statik via BGP terbukti terlihat di CHR.

### 2.4 OSPF

OSPF mencapai Full, termasuk area stub/NSSA, autentikasi, dan
virtual-link di sisi BIRD. CHR tidak mendukung virtual-link — itu
keterbatasan CHR, bukan Titian, dan dicatat apa adanya.

### 2.5 RPKI

Validasi RPKI diuji melawan cache StayRTR di jaringan lab dengan trust
anchor lab-lokal (JSON, bukan hierarki global). Hasil VRP valid, invalid,
dan unknown masing-masing teruji di kedua guest.

### 2.6 BFD

- BFD di atas OSPF direct: UP.
- BFD multihop-BGP: gagal karena perbedaan tipe — satu sisi memakai
  UDP 4784, sisi lain 3784. Ini ketidakcocokan konfigurasi, bukan bug
  Titian.
- **BFD-over-BGP single-hop di atas interface management BELUM diuji.**
  Jangan klaim bagian ini.

### 2.7 VXLAN

```
   Overlay (VNI sama, local/remote bersilangan)
   Debian vxlan10 ◄──► FreeBSD vxlan10      unicast: LULUS
   Debian/FreeBSD ◄──► CHR (learning)       learning: LULUS
   Multicast end-to-end                     TIDAK TERBUKTI
```

Multicast tidak terbukti karena FreeBSD tidak join grup multicast.
Untuk pemakaian produksi, pakai mode unicast sampai multicast teruji.

### 2.8 Bonding, tuning, checkpoint, rename

- **Bonding/LACP:** penyelidikan menemukan akar masalah di pelaporan
  speed/duplex slave virtio Debian; perintah `speed` persisten dibangun
  untuk menutup celah itu, dan LACP terbukti sesudahnya.
- **Tuning:** `system sysctl` + mtu/qlen/offload/coalesce persisten di
  kedua OS (Linux: sysctl.d; FreeBSD: blok sysctl.conf). Sukses live
  coalesce belum terbukti di NIC lab.
- **Checkpoint/rollback:** titik bernama (save/list/delete), rollback
  bernama dan rollback polos (ke startup-config), persisten melewati
  reboot termasuk bird.conf, netstate, dan sysctl. Satu insiden mode
  file diperbaiki: salinan FreeBSD menularkan mode 600 — restore kini
  memaksa mode baca yang benar.
- **Rename:** 12/12 lulus melewati reboot di kedua OS (nama diubah,
  reboot, state utuh; rename-balik, reboot, nama asal kembali).
  Pengujian memakai NIC tambahan yang persisten — interface dummy/epair
  TIDAK bertahan melewati reboot, jadi tidak bisa dipakai untuk uji ini.

### 2.9 Firewall/NAT melawan backend nyata

Backend nftables (Linux) dan pf anchor (FreeBSD) diuji dengan bukti
tcpdump (alamat benar-benar berubah untuk SNAT), bukan hanya dari
konfigurasi:

| Uji | Hasil |
|---|---|
| Source NAT | 14/14 |
| Destination NAT / port forwarding | 8/8 |
| Filter | 10/10 |
| Persistensi melewati reboot | 4/4 |
| Kasus negatif (yang harus ditolak, memang ditolak) | 38/38 |
| Regresi | 10/10 |

Batasan pf yang ditemukan (dan kini ditolak mentah-mentah, bukan
diam-diam diubah): filter `out` interface, filter `in` any, dan SNAT
tanpa interface keluar. Forward default-deny di FreeBSD hanya berlaku
untuk interface yang disebut filter-forward/dnat. Detail lengkap ada di
`panduan-cli.md` §8.

---

## 3. Bagan alur uji (untuk yang ingin mengulang)

```
   ┌──────────────┐
   │ Catat jangkar │  sidik jari startup-config + bird.conf
   └──────┬───────┘
          ▼
   ┌──────────────┐
   │ Pasang skenario│  contoh: PtP, BGP, VXLAN, firewall
   └──────┬───────┘
          ▼
   ┌──────────────┐
   │ Uji + bukti   │  ping, show, tcpdump, verifikasi dari sisi CHR
   └──────┬───────┘
          ▼
   ┌──────────────┐
   │ Negatif juga  │  yang harus gagal, pastikan gagal
   └──────┬───────┘
          ▼
   ┌──────────────┐
   │ Bersihkan     │  restore + restart; sidik jari = jangkar lagi
   └──────┬───────┘
          ▼
     Tahap berikutnya (mulai dari jangkar yang sama)
```

Untuk mereplikasi lab ini secara garis besar: siapkan tiga VM (Debian
13, FreeBSD 15, CHR RouterOS) di satu jaringan management, tambahkan
satu link PtP terisolasi antara guest Titian dan CHR, pasang paket
Titian 0.1.0 (atau build dari source repo ini), lalu jalankan skenario
per area mengikuti urutan di §2 — selalu kembali ke jangkar antar
tahap. Lisensi CHR gratis membatasi throughput 1 Mbps, jadi fokuskan
pada kebenaran fungsi.

## 4. Yang belum terbukti — jangan diklaim

- VXLAN multicast end-to-end.
- BFD-over-BGP single-hop di atas interface management.
- Coalesce live di NIC lab.
- Kreasi VLAN FreeBSD yang stabil 100% (intermiten `SIOCIFCREATE2`).
- Rewrite `route-dev` dan `vxlan-group-dev` lewat rename end-to-end
  via CLI (baru teruji level skrip).
- Dashboard web (belum dibangun; CLI adalah produknya saat ini).
- Fitur pasca-0.1.0 di dalam paket biner 0.1.0 (tuning, speed, VXLAN,
  checkpoint, rename, firewall ada di source, belum di biner 0.1.0).

Daftar ini sengaja ditulis eksplisit: hasil lab yang jujur menyebut
batasnya sama pentingnya dengan menyebut lulusnya.
