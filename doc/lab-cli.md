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
  (*anchor*); sesi FreeBSD↔CHR dibangun lewat jalur management/multihop
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

1. **Catat *anchor* dulu.** Sebelum tahap dimulai, *fingerprint* file konfigurasi
   (`startup-config` dan `bird.conf` kedua guest) dicatat.
2. **Uji.** Tahap dijalankan, hasil dicatat (lulus/gagal + bukti).
3. **Bersih ke *anchor*.** Setelah tahap selesai, konfigurasi
   dikembalikan dan *fingerprint* dicocokkan lagi — tahap berikutnya selalu
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
   │ Catat *anchor* │  *fingerprint* startup-config + bird.conf
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
   │ Bersihkan     │  restore + restart; *fingerprint* kembali sama dengan *anchor*
   └──────┬───────┘
          ▼
     Tahap berikutnya (mulai dari *anchor* yang sama)
```

Untuk mereplikasi lab ini secara garis besar: siapkan tiga VM (Debian
13, FreeBSD 15, CHR RouterOS) di satu jaringan management, tambahkan
satu link PtP terisolasi antara guest Titian dan CHR, pasang paket
Titian 0.1.0 (atau build dari source repo ini), lalu jalankan skenario
per area mengikuti urutan di §2 — selalu kembali ke *anchor* antar
tahap. Lisensi CHR gratis membatasi throughput 1 Mbps, jadi fokuskan
pada kebenaran fungsi.

## 4. Terapan dari panduan CLI — set IP /31, model PtP, dan hasil ping

Bagian ini adalah bentuk terapan dari `panduan-cli.md`: sintaks yang
benar-benar dipakai di lab, bukan contoh karangan. Modelnya: **PtP /31
(RFC 3021)** — satu link hanya memakai 2 alamat, tanpa alamat network
dan broadcast — dipadukan dengan **model PtP custom gaya MikroTik/PPP**:
alamat lokal dan peer boleh sembarang, tidak harus satu subnet. Pasangan
lab memakai model custom ini: lokal `203.0.113.77` dengan peer
`10.44.55.66` (beda subnet), di atas link PtP terisolasi Debian↔CHR.

### 4.1 Sesi CLI di Debian (sisi Titian)

```
sudo /usr/local/bin/titian
show interfaces terse
configure terminal
interface ethernet enp9s0
description "PtP ke CHR"
ip address 203.0.113.77/31 peer 10.44.55.66
exit
end
save
```

Penjelasan per baris:

- `show interfaces terse` — pastikan `enp9s0` ada dan kenali namanya
  sebelum dikonfigurasi.
- `configure terminal` — masuk mode configure (bare `configure` saja
  = Incompleted command).
- `interface ethernet enp9s0` — masuk view interface tersebut.
- `ip address 203.0.113.77/31 peer 10.44.55.66` — pasang alamat lokal
  /31 + peer. Perintah ini langsung live; belum persisten sebelum `save`.
- `exit` → keluar dari view interface; `end` → kembali ke exec;
  `save` → tulis running-config ke startup-config (di exec, bukan di
  dalam configure).

Di sisi CHR (lawan), ether2 memegang alamat peer `10.44.55.66` sebagai
pasangan dari `203.0.113.77` — pasangan bersilangan inilah yang membuat
link PtP hidup.

### 4.2 Perilaku per-OS di balik sintaks yang sama

Sintaks yang diketik pengguna sama di kedua OS, tetapi implementasi di
belakangnya berbeda — dan perbedaan ini ditemukan dari lab, bukan dari
dokumen:

- **Linux:** PtP diterapkan sebagai link point-to-point dengan peer
  tersebut.
- **FreeBSD:** PtP TIDAK memakai `dstaddr` (ifconfig mengabaikannya di
  interface Ethernet broadcast → ping loss 100%). Bentuk yang benar dan
  sudah diterapkan Titian: alamat lokal `/32` + route host ke peer via
  interface, dengan persistensi yang sama di rc.conf.

Jadi bila mengulang di FreeBSD, ketik sintaks `peer` yang sama — jangan
coba meniru `dstaddr` manual.

### 4.3 Verifikasi dan hasil ping lab

```
show interfaces ethernet enp9s0 detail
show ip neighbor
ping 10.44.55.66 repeat 4
```

Hasil yang tercatat di lab:

- **Ping IPv4 Debian → CHR dan sebaliknya: 0% loss** (4/4 balasan pada
  uji penghitung; ping lawan CHR 0% loss dua arah).
- **Ping IPv6 ke CHR: dua arah 0% loss** untuk prefix `/127`, `/126`,
  `/56`, dan `/64`.
- Verifikasi dilakukan dari kedua sisi (guest Titian dan CHR), bukan
  hanya dari satu sisi.

Notes: hasil di atas adalah ringkasan hasil uji (jumlah
balasan dan persentase loss), bukan salinan mentah output ping — nilai
RTT per paket tidak dicatat sebagai bukti lab, sehingga tidak ditulis
di sini.

## 5. Terapan lanjutan — BGP, OSPF, RPKI, dan lainnya

Prinsip mekanisme yang wajib dipahami dulu: **definisi protokol dan
filter BIRD tidak dibuat lewat satu perintah khusus**. Definisi section
hidup di file staging (`bird.d/`), lalu diterapkan dari bird view dengan
alur wajib `generate check <section>` → `generate <section>` (generate
selalu membackup `bird.conf` sebelum apply, lalu `bird -p -c` +
`birdc configure`). Perintah CLI di bird view mengelola show, community,
redistribusi, dan kontrol protokol di atas section tersebut. Bagian ini
menampilkan isi lab yang tercatat: sisi Titian dan sisi CHR.

### 5.1 BGP melawan CHR — sisi Titian

ASN global berasal dari header `bird.conf` (`define TITIAN_ASN`,
diatur saat install; default 64512). Blok section yang teruji:

```bird
# Debian ↔ CHR via PtP (teruji)
protocol bgp bgp_chr {
    local as TITIAN_ASN;
    neighbor 10.44.55.66 as 64513;
    ipv4 {
        import filter bgp_import_comm;
        export filter bgp_export_attr;
    };
    ipv6 { import none; export none; };
}
```

```bird
# FreeBSD ↔ CHR via PtP (teruji) — multihop WAJIB
protocol bgp bgp_chr {
    multihop 2;
    bfd on;
    source address 203.0.113.90;
    local as TITIAN_ASN;
    neighbor 10.44.55.99 as 64513;
    ipv4 {
        import filter rpki_import;
        export none;
    };
    ipv6 { import none; export none; };
}
```

Mengapa FreeBSD wajib `multihop 2` + static peer route: alamat /32
FreeBSD tidak directly-connected di pandangan device protocol BIRD,
sehingga tanpa multihop sesi stuck Idle (`Waiting for <peer-ip> to
become my neighbor`) meski route kernel ke peer ada dan ping jalan.
Tambahan wajib: static peer route + `generate static`, supaya next-hop
route BGP ter-resolve jadi unicast (tanpa itu route hasil BGP bertipe
`unreachable`). Sesi lewat jaringan management yang memang connected
tidak butuh multihop.

Menerapkan dan memverifikasi (bird view):

```
generate check bgp
generate bgp
show protocol summary
show protocol neighbors bgp_chr
show route protocol bgp
show route export bgp_chr
```

Community (bird view) — contoh yang teruji di lab:

```
community list add PEER-AS 64513:100
community list show
community export add 64512:100
community export show
community import add 64513:200 localpref:300
community import show
```

Yang teruji dua arah lawan CHR: standard, well-known (no-export,
no-advertise, no-peer, blackhole), extended, large; lewat filter export
juga teruji ORIGIN, AS_PATH, NEXT_HOP, LOCAL_PREF, MED, prepend.
ATOMIC_AGGREGATE/AGGREGATOR bersifat read-only (dihasilkan sistem saat
agregasi) dan tidak applicable di lab ini.

Redistribusi (bird view):

```
redistribute static enable
redistribute direct enable
redistribute show
```

Semantik direct berbeda per OS (keduanya benar): Debian mengumumkan
alamat peer /32, FreeBSD mengumumkan alamat lokal /32.

Hasil demo 30 Okt (Debian ↔ CHR via PtP): peer `bgp_chr` Established
dalam 8 detik; `community export add 64512:100` → route export membawa
`BGP.community: (64512,100)`; CHR mengiklankan 198.51.100.0/24 via
filter-chain → `community import add 64513:200 localpref:300` → route
tampil `BGP.local_pref: 300` + community (64513,200); CHR menerima
`DAb 203.0.113.0/24 via 203.0.113.77`. Kontrol negatif: setelah kedua
rule dihapus, community export hilang dan localpref kembali 100, sesi
tetap Established.

Kaki IPv6 (`bgp_chr6`, 1 Nov, kedua kaki lalu cleanup total): Debian
(local 64512, neighbor CHR 2001:db8:1::3 as 64513) dan FreeBSD (local
64514, neighbor CHR 2001:db8:11::3 as 64513, `multihop 2` + static peer
route — kunci yang sama seperti IPv4 FreeBSD). Debian impor
2001:db8:200::/48 localpref 300 + community (64513,200), ekspor
2001:db8:100::/48 community (64512,100); FreeBSD impor
2001:db8:210::/48 localpref 300 + community (64513,200), ekspor
2001:db8:110::/48 community (64514,100); CHR menerima dengan distance
20 dan prefix-count=1 di kedua sesi. Kontrol negatif kedua kaki:
localpref impor kembali 100, community ekspor hilang, sesi tetap
Established.

Menghapus peer (urutan penting): hapus blok `protocol bgp ...` dulu,
lalu `generate check bgp` → `generate bgp` — kebalikan urutan pasang.
Bila filter dihapus dulu sementara bgp masih merujuknya, render
bird.conf gagal parse. Verifikasi: `show protocol summary` (protokol
hilang) + `show route` (route BGP hilang). Hapus juga sisi CHR dan
peer route statik bila tidak dipakai lagi.

### 5.2 BGP — sisi CHR (RouterOS 7.25, tercatat live)

```routeros
# AS milik INSTANCE, bukan connection (local.as di connection DITOLAK ROS 7.25)
/routing bgp instance add name=default as=64513 router-id=192.168.122.219

# connection wajib instance + local.role=ebgp (tanpa keduanya: error/prompt)
/routing bgp connection add name=to-debian-ptp instance=default \
    remote.address=203.0.113.77 remote.as=64512 local.role=ebgp \
    local.address=10.44.55.66

# alamat PtP CHR (mirror Debian)
/ip address add address=10.44.55.66/32 network=203.0.113.77 interface=ether2
```

Koreksi sintaks ROS 7.25 yang ditemukan live: connection memakai
`output.filter-chain`, **bukan** `output.filter` (yang terakhir ditolak
`bad parameter`; `output.filter` adalah properti template). Default CHR:
tanpa `output.redistribute`/filter, CHR **tidak mengiklankan apa pun**.
Menghapus: `/routing bgp connection remove`. Temuan CHR lain untuk
IPv6: TIDAK ada parameter `address-families` (AF IPv6 ternegosiasi
otomatis dari alamat neighbor); `/ipv6 route` TIDAK ada `type=blackhole`
(dipakai device route via ether2).

### 5.3 OSPF — sisi Titian dan catatan lawan

OSPF dikelola sama seperti BGP: definisi section + `generate check
ospf` → `generate ospf`, verifikasi `show protocol summary` dan
`show route protocol ospf`. Yang teruji: Full, area stub/NSSA,
autentikasi, dan virtual-link di sisi BIRD. Catatan lab yang wajib
diingat:

- Area range: sintaksnya `networks { ...; }` di blok area, **bukan**
  `range` (parser menolak `range`). Varian `hidden` menyembunyikan
  summary dari peer.
- Virtual link: sintaksnya `virtual link <router-id>` di area transit,
  dan router harus multi-area. **CHR RouterOS 7.25 tidak mendukung
  virtual link** (menunya tidak ada) — itu batas CHR, bukan Titian.
- Autentikasi OSPF: interop MD5 mensyaratkan key-id 0 di sisi BIRD.
- Sisi CHR untuk OSPF tidak meninggalkan transkrip perintah di catatan
  lab selain butir-butir di atas; yang tercatat adalah perilaku
  interopnya (Full tercapai, virtual-link tidak tersedia di CHR).

### 5.4 RPKI — cache StayRTR + filter import BGP

| Item | Nilai lab |
|---|---|
| Cache | StayRTR v0.6.4 (container di host lab, restart `unless-stopped`) |
| Alamat RTR | `192.168.122.1:3323` (lewat gateway NAT) |
| VRP | file JSON lab-lokal (edit VRP lalu restart container, atau tunggu refresh 60 detik) |

VRP lab (contoh, bukan ROA global):

| Prefix | ASN | Status uji |
|---|---|---|
| `198.51.100.0/24` | AS64513 (AS CHR) | VALID → localpref 500 |
| `198.51.101.0/24` | AS64501 | INVALID → di-reject |
| `198.51.102.0/24` | (tanpa VRP) | UNKNOWN → localpref 100 |

Cara kerja di BIRD: protokol `rpki` menunjuk ke RTR, lalu `roa check`
di filter import BGP memilah tiga status di atas (contoh blok FreeBSD
di §5.1 memakai `import filter rpki_import`). Verifikasi dari bird
view: `show protocol summary` (sesi RTR) dan `show route` + efek filter
yang teramati (localpref/reject). Untuk perintah birdc mentah, pakai
`bird terminal` lalu perintah birdc langsung.

**Notes:** trust anchor lab ini lab-lokal (file JSON statis,
bukan hierarki RPKI global). "Valid" di sini berarti
valid-terhadap-VRP-lab — jangan klaim ROA ini berlaku terhadap ROA
global di internet.

### 5.5 BFD — sisi Titian dan sisi CHR

BFD diikat ke sesi lewat section BFD (`bfd on` di blok protokol, lihat
blok FreeBSD §5.1) + `generate check bfd` → `generate bfd`. Yang
teruji: BFD via OSPF direct (UP). Dua catatan lawan:

```
# CHR: BFD HARUS didaftarkan dulu, kalau tidak sesi berstatus forbidden
/routing bfd configuration add interfaces=<iface>
```

- BFD-over-BGP-multihop tidak jalan karena beda port (BIRD UDP 4784
  vs CHR UDP 3784) — pakai BFD via OSPF (direct) atau single-hop.
- BFD-over-BGP single-hop di atas interface management belum diuji
  (lihat §6).

### 5.6 VXLAN — guest dan CHR sebagai VTEP learning

Perintah guest (view `configure-vxlan-view`, masuk lewat
`interface vxlan <nama>`):

```
configure terminal
interface vxlan vxlan110
vni 110
local 192.168.122.50
remote 192.168.122.116
dstport 4789
mtu 1450
ip address 198.51.110.1/24
ipv6 address 2001:db8:310::1/64
enable
end
show interfaces vxlan vxlan110
```

Sisi CHR sebagai VTEP ketiga — TERBUKTI via model learning (PtP/mgmt
tidak disentuh): RouterOS 7.25 **tidak punya** parameter
`remote-address` di `/interface/vxlan` (terbukti: `bad parameter
remote-address`) maupun di submenu vtep — CHR TIDAK BISA di-set unicast
statis seperti Linux/FreeBSD. Model CHR: learning (tanpa grup, VTEP
dipelajari dari trafik yang diterima). Parameter CHR yang tercatat:
vxlan111, vni 111, local 192.168.122.219, port 4789, mtu 1450, IP
198.51.111.3/24 + 2001:db8:311::3/64; Debian vxlan111 unicast ke CHR
(vni 111, remote 192.168.122.219, overlay 198.51.111.1/24 +
2001:db8:311::1/64). Hasil: Debian→CHR v4+v6 4/4 0% loss dan CHR→Debian
v4+v6 4/4 0% loss (CHR mempelajari Debian dari trafik yang diterima,
lalu dua arah jalan; FDB Debian mempelajari MAC CHR → 192.168.122.219).
Cleanup CHR terverifikasi: IP + interface vxlan111 dihapus, print
vxlan kosong, PtP/mgmt tidak berubah.

Catatan MTU: batas berguna overlay 1450 untuk overhead VXLAN ~50 byte
— dibuktikan uji DF (`ping -M do -s 1422` = 1450 byte), bukan dari
dokumen. Multicast end-to-end tetap tidak terbukti (FreeBSD tidak
join grup).

### 5.7 Lainnya — firewall, tuning, checkpoint, rename (terapan singkat)

- **Firewall/NAT:** sintaks lengkap ada di `panduan-cli.md` §8
  (filter/snat/dnat + `no` bersintaks lengkap). Bukti lab bukan dari
  konfigurasi saja: tcpdump membuktikan alamat benar-benar berubah
  untuk SNAT. Angka: srcnat 14/14, dnat 8/8, filter 10/10, persistensi
  reboot 4/4, negatif 38/38, regresi 10/10.
- **Tuning:** `system sysctl` + mtu/qlen/offload/coalesce persisten
  kedua OS; periksa dengan `show interfaces tuning <iface>`. Coalesce
  live belum terbukti di NIC lab.
- **Checkpoint/rollback:** alur lab yang dipakai sebelum setiap
  perubahan berisiko: `checkpoint save pra-ubah` → ubah → bila gagal
  `rollback pra-ubah`, bila berhasil `save`. Rollback persisten +
  restart service, termasuk bird.conf, netstate, dan sysctl.
- **Rename:** `rename <lama> <baru>` persisten melewati reboot kedua
  OS (12/12 lulus). Pengujian memakai NIC tambahan yang persisten —
  interface dummy/epair tidak bertahan melewati reboot sehingga tidak
  bisa dipakai untuk uji ini.

## 6. Yang belum terbukti — jangan diklaim

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
