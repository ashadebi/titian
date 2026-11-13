# Panduan Lengkap CLI Titian (klish)

Panduan ini menjelaskan cara penggunaan CLI Titian menu per menu, sesuai
perintah yang ada di tree (`tree/`) repositori ini. Semua contoh memakai
alamat TEST-NET (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24,
2001:db8::/32) — ganti dengan alamat jaringanmu sendiri.

Prinsip yang mengikat seluruh panduan ini: **single-engine**. Binary klish
yang terinstal adalah satu-satunya lapisan query/eksekusi. Jangan mengedit
`bird.conf`, file di `/opt/titian`, atau konfigurasi sistem (systemd-networkd,
rc.conf, nftables, pf) dengan tangan — semua perubahan lewat perintah CLI,
lalu `save`. Perintah yang diedit manual akan tertimpa atau tidak konsisten
dengan state Titian.

## 0. Masuk, mode, dan konvensi

### 0.1 Masuk ke CLI

```sh
sudo /usr/local/bin/titian
```

CLI juga bisa menerima perintah lewat stdin (untuk skrip/batch), tetapi
bantuan interaktif (`?` dan Tab) hanya bekerja di sesi interaktif (PTY).

### 0.2 Mode dan prompt

| Mode | Cara masuk | Prompt | Cara keluar |
|---|---|---|---|
| Exec (privileged) | awal sesi | `...#` | `logout` / `exit` |
| Configure | `configure terminal` | `cli-...(config)#` | `exit` atau `end` |
| Interface | `interface <tipe> <nama>` dari configure | `...(config-if-<nama>)#` | `exit` |
| Firewall | `firewall` dari configure | `...(config-firewall)#` | `exit` |
| BIRD | `bird` atau `bird terminal` dari exec | `titian-...(birdc)#` | `exit` |
| SSH service | `service ssh` dari configure | `...(config-system-...)#` | `exit` |
| Name-server | `system name-servers` dari configure | `...(config-system-...)#` | `exit` |
| Options (tuning) | `options` dari view interface | `...(config-if-<nama>-options)#` | `exit` |

Catatan mode:

- `configure` saja (tanpa `terminal`) = perintah tidak lengkap
  (Incompleted command). Selalu pakai `configure terminal`.
- `exit` mundur satu level; `end` dari mode configure langsung kembali ke
  exec. Di mode configure, `do <perintah-exec>` menjalankan perintah exec
  tanpa keluar dari configure, contoh: `do show interfaces terse`.
- `save` hanya ada di mode exec. Di dalam mode configure, `save` =
  Unknown command. Urutan yang benar: `end` dulu, baru `save`.
- `?` menampilkan daftar sintaks lanjutan di posisi kursor; Tab melengkapi
  perintah. Keduanya hanya di sesi interaktif.
- `no` meniadakan perintah (menghapus setelan / mengembalikan default).
  Untuk firewall, `no` memakai sintaks lengkap yang sama dengan perintah
  pembuatnya (rule diidentifikasi dari ISInya, bukan dari ID).
- Perintah yang mengubah live sistem (mis. `ip address`) langsung berlaku
  saat dieksekusi; `save` hanya soal persistensi (menulis running-config
  ke startup-config di `/opt/titian/etc/startup-config`).
- `show running-config` menampilkan konfigurasi berjalan saat ini;
  `show startup-config` menampilkan isi file startup-config.
- `show history` menampilkan riwayat perintah sesi.

### 0.3 Konvensi penulisan di panduan ini

- `<iface>` = nama interface sistem (lihat `show interfaces`).
- `<CIDR>` = alamat/prefix, contoh `198.51.100.0/24`.
- `any` = semua (khusus firewall).
- Perintah dalam blok kode ditulis tanpa prompt, kecuali dinyatakan lain.
- Tanda `[Linux]` / `[FreeBSD]` = perintah hanya ada di OS tersebut.

---

## 1. Mode exec — perintah show dan utilitas

Mode exec adalah tempat memeriksa keadaan dan menjalankan aksi tingkat
sistem. Semua perintah di bawah ini diketik di prompt exec.

### 1.1 Show dasar

```
show                    # ringkasan informasi sistem berjalan
show running-config     # konfigurasi berjalan saat ini
show startup-config     # isi file startup-config
show history            # riwayat perintah
show pwd                # direktori kerja saat ini
```

### 1.2 Show interface

```
show interfaces              # semua interface + info IP-nya
show interfaces terse        # semua interface, satu baris per interface
                             # (status admin/link); interface DOWN tampil (D)
show interfaces all          # semua interface, detail penuh
show interfaces ethernet <iface> [detail]
                             # status + konfigurasi satu interface fisik
show interfaces vlan <iface> [detail]
show interfaces vxlan [iface]
                             # status VXLAN + VNI + local/remote + FDB
show interfaces bonding <iface> [detail]   # [Linux]
show interfaces lagg <iface> [detail]      # [FreeBSD]
show interfaces tuning <iface>
                             # nilai tuning + artinya (mtu/qlen/speed/offload/coalesce)
```

`show interfaces` menampilkan SEMUA interface yang terdeteksi sistem,
termasuk yang DOWN atau ter-disable — bukan hanya yang dikonfigurasi
Titian. Interface DOWN disembunyikan `ifconfig` polos, tapi tetap tampil
di sini (bertanda D); itu perilaku normal, bukan bug.

### 1.3 Show IP dan routing

```
show ip route [ip-atau-prefix]   # tabel routing IPv4 (opsional: filter satu prefix)
show ipv6 route [prefix]         # tabel routing IPv6
show ip neighbor [iface]         # tabel neighbor/ARP (opsional: per interface)
show ipv6                        # informasi IPv6
```

### 1.4 Show system dan hardware

```
show system              # ringkasan informasi sistem
show system date         # tanggal/waktu sistem
show system uptime       # lama sistem menyala
show system process      # proses berjalan
show system memory       # pemakaian memori
show system storage      # pemakaian filesystem
show system login        # info login user
show system connections  # koneksi jaringan aktif
show system top          # top dengan pola
show system sysctl       # nilai sysctl yang dikelola Titian + artinya
show hardware            # detail hardware sistem
show hardware cpu        # info CPU
show hardware pci        # detail bus PCI
show hardware dmi        # detail DMI
```

### 1.5 Show service

```
show service summary          # ringkasan service
show service status <nama>    # perintah init service tertentu
```

### 1.6 Ping dan traceroute

```
ping <tujuan> [source <ip-atau-iface>] [repeat <n>] [size <byte>]
     [interval <detik>] [resolve] [broadcast] [flood] [duplicate-detect]
ping ip <tujuan> ...     # eksplisit IPv4 (default)
ping ipv6 <tujuan> ...   # ICMPv6
ping arp <tujuan> ...    # request ARP ke tetangga
traceroute <tujuan> [source <ip>] [interface <iface>] [resolve]
traceroute ip <tujuan> ...
traceroute ipv6 <tujuan> ...
```

Contoh:

```
ping 192.0.2.1 repeat 4
ping 2001:db8::1 source 2001:db8::2
traceroute 198.51.100.1
```

### 1.7 Perintah exec lain

```
configure terminal   # masuk mode configure
bird                 # masuk view BIRD
bird terminal        # masuk terminal BIRD
save                 # simpan running-config ke startup-config
logout               # keluar dari CLI
reboot               # PERHATIAN: perintah ini hanya mencetak teks,
                     # TIDAK me-reboot mesin. Jangan diandalkan untuk reboot.
help                 # gambaran sintaks titian
```

### 1.8 Pager — output panjang ditampilkan bertahap (less)

Output panjang (`show running-config`, `show startup-config`) ditampilkan
bertahap lewat pager `less` (bukan langsung tercurah semua). Di dalam pager:
`SPACE` = halaman berikut, `ENTER` = baris berikut, `q` = keluar, `/teks`
= cari. Bila output muat satu layar, pager langsung selesai tanpa jeda.

```
show running-config          # bertahap (pager)
show running-config no-more  # tanpa pager, curah semua sekaligus
show startup-config no-more  # sama untuk startup-config
terminal length 24           # pager aktif (default 24 baris)
terminal length 0            # pager mati (semua output tercurah)
terminal no-more             # sama dengan terminal length 0
terminal more                # pager aktif lagi (length 24)
```

Catatan: pager hanya aktif bila output ke terminal interaktif (TTY).
Bila output di-pipe atau di-script (bukan TTY), pager otomatis nonaktif
dan output tercurah penuh — aman untuk automation.

---

## 2. Mode configure — memilih objek yang dikonfigurasi

Masuk dulu:

```
configure terminal
```

Di mode configure, perintah-perintah berikut memilih objek atau mengatur
parameter global. Perintah `no <...>` menghapus setelan yang bersangkutan.

### 2.1 Memilih interface

Bentuk perintah berbeda per tipe dan per OS. Nama interface yang valid
mengikuti charset IFACE_SYS (maksimal 15 karakter, huruf/angka/`_`/`-`/`.`);
keberadaan interface diperiksa saat perintah dijalankan — interface yang
tidak ada di sistem ditolak dengan pesan jelas.

```
# Ethernet (kedua OS)
interface ethernet <iface>

# Loopback / dummy
interface loopback <nama>

# VLAN — Linux: namanya parent.VLAN-ID; FreeBSD: id + parent terpisah
interface vlan <parent>.<id>              # Linux, contoh: interface vlan enp1s0.100
interface vlan <id> <parent>              # FreeBSD, contoh: interface vlan 100 enp1s0

# VXLAN (kedua OS)
interface vxlan <vxlanN>                  # contoh: interface vxlan vxlan10

# Bonding / agregasi — Linux: bonding, FreeBSD: lagg
interface bonding <bondN>                 # Linux, contoh: interface bonding bond0
interface lagg <laggN>                    # FreeBSD, contoh: interface lagg lagg0
```

Menghapus objek interface:

```
no interface ethernet <iface>     # (bentuk no mengikuti perintah pembuatnya)
no interface loopback <nama>
no interface vlan <parent>.<id>   # Linux
no interface vlan <id>            # FreeBSD
no interface vxlan <vxlanN>
no interface bonding <bondN>      # Linux
no interface lagg <laggN>         # FreeBSD
```

Perhatian:

- Masuk ke view interface membuat section persisten di running-config.
  Section itu hanya hilang bila startup-config di-restore dan service
  di-restart, atau objek dihapus dengan `no interface ...`.
- `no interface bonding` gagal dengan `[slave lock]` bila masih ada slave
  yang menempel — lepas dulu slave-nya (`no bond-group <bondN>` di view
  interface member), baru hapus bond-nya.
- Bare `no bond-group` (tanpa nama bond) = Incompleted command; nama bond
  wajib ditulis.
- Kreasi VLAN di FreeBSD kadang gagal intermiten (`SIOCIFCREATE2`); bila
  terjadi, ulangi perintahnya — guard create mencegah konfigurasi korup.

### 2.2 Route dan gateway global (mode configure)

```
ip default-gateway <ip>
no ip default-gateway
ip route <prefix> <next-hop-ip>
ip route <prefix> dev <iface>
no ip route <prefix>
ip route blackhole <ip>
no ip route blackhole <ip>

ipv6 default-gateway <ipv6>
no ipv6 default-gateway
ipv6 route <prefix> <next-hop-ipv6>
ipv6 route <prefix> dev <iface>
no ipv6 route <prefix>
ipv6 route blackhole <ipv6>
no ipv6 route blackhole <ipv6>
```

Contoh:

```
ip route 198.51.100.0/24 192.0.2.1
ip route 203.0.113.0/24 dev enp1s0
ipv6 route 2001:db8:1::/48 2001:db8::1
```

### 2.3 System (mode configure)

```
system hostname <nama>
system time-zone <zona>     # pilihan: WIB / WITA / UTC (dan alias pulau
                            # Jawa, Bali, Singapore, Malaysia — lihat ?)
system sysctl <kunci> <nilai>
                            # contoh: system sysctl net.ipv4.ip_forward 1
                            # (Linux) / net.inet.ip.forwarding (FreeBSD)
                            # nilai berv interval pakai tanda kutip:
                            # system sysctl net.ipv4.tcp_mem "4096 87380 16777216"
no system sysctl <kunci>
system domain-name <domain>
no system domain-name
system name-servers         # masuk view name-server
```

Di view name-server:

```
nameserver <ip>
no nameserver <ip>
exit
```

Arti tiap kunci sysctl yang dikelola Titian bisa dilihat dengan
`show system sysctl` (mode exec).

### 2.4 Service SSH (mode configure)

```
service ssh                 # masuk view SSH
```

Di view SSH:

```
port <nomor>                # port service SSH
allow-root                  # izinkan login root lewat SSH
no allow-root               # larang login root lewat SSH
disable-host-validation     # jangan validasi hostname remote dengan DNS
no disable-host-validation  # validasi hostname remote dengan DNS
exit
```

### 2.5 Firewall (mode configure)

```
firewall                    # masuk view firewall (lihat §8)
no firewall                 # hapus SELURUH konfigurasi firewall (semua rule)
```

---

## 3. View interface — perintah di dalam satu interface

Setelah `interface <tipe> <nama>`, prompt berubah menjadi
`...(config-if-<nama>)#`. Perintah berikut berlaku di semua tipe view
interface, kecuali dinyatakan lain.

### 3.1 Perintah umum view interface

```
ip address <alamat-CIDR> [peer <ip-peer>]
                            # alamat IPv4; bentuk peer = link point-to-point
                            # (PtP, /31 RFC 3021, lokal+peer bebas — lihat §3.2)
no ip address <alamat-CIDR> [peer <ip-peer>]
ipv6 address <alamat-CIDR> [peer <ipv6-peer>]
                            # FreeBSD (eth/vlan/lagg/loopback): tanpa peer
no ipv6 address <alamat-CIDR> [peer <ipv6-peer>]
description <teks>          # alias/deskripsi interface
mtu <68-9000>               # MTU, live + persisten (1500 default, 9000 jumbo)
no mtu                      # hapus setelan MTU Titian (kembali ke nilai pra-Titian)
disable                     # matikan interface (admin down)
enable                      # hidupkan interface (admin up)
options                     # masuk view tuning lanjutan (§3.4)
exit                        # kembali ke mode configure
```

`ip address` langsung live saat dieksekusi; `save` (dari exec) hanya
menentukan apakah setelan bertahan melewati reboot.

### 3.2 Alamat point-to-point (PtP)

Titian mendukung PtP gaya MikroTik/PPP: alamat lokal dan peer boleh
sembarang (tidak harus satu subnet), contoh:

```
interface ethernet enp1s0
ip address 192.0.2.10/31 peer 192.0.2.11
```

Aturan khusus FreeBSD: PtP Ethernet broadcast TIDAK memakai `dstaddr`
(ifconfig mengabaikannya, ping loss 100%). Bentuk yang benar di FreeBSD
adalah `/32` lokal + route host ke peer via interface — dan itu yang
diterapkan Titian secara otomatis; cukup pakai sintaks `peer` yang sama,
perilaku per-OS ditangani di belakang layar.

### 3.3 Perintah khusus per tipe

```
# Ethernet Linux — di view interface ethernet:
qlen <metode>               # panjang antrean kirim (1000 untuk 1G, 10000 untuk 10G)
no qlen
speed <nilai> [duplex <full|half>]
                            # nilai Mb/s: 10, 100, 1000, 2500, 5000, 10000,
                            # 25000, 40000, 50000, 100000 (Linux saja, persisten)
no speed
bond-group <bondN>          # gabungkan interface ini sebagai slave bondN
no bond-group <bondN>       # lepas dari bondN

# Bonding Linux — di view interface bonding:
mode <metode>               # 802.3ad (LACP) atau round-robin
hash-policy <lapisan>       # kebijakan hash transmit (mis. layer2/MAC)

# LAGG FreeBSD — di view interface lagg:
laggport <member>           # tambah member ke lagg
no laggport <member>        # hapus member dari lagg
```

`speed` wajib dilaporkan driver dengan benar untuk bonding 802.3ad di
atas interface virtual (virtio) — tanpa itu LACP tidak nego dengan benar.

### 3.4 View options — tuning lanjutan (perintah `options`)

Dari view interface, `options` membuka view tuning. Semua setelan di sini
live + persisten (disimpan di netstate `.tuning` + *mirror*, diterapkan ulang
saat boot lewat apply-all). `no <setelan>` menghapus setelan Titian dan
mengembalikan nilai pra-Titian.

Linux (lengkap):

```
tso <on|off>                # TCP segmentation offload
no tso
gro <on|off>                # generic receive offload
no gro
lro <on|off>                # large receive offload (hardware; default off)
no lro
gso <on|off>                # generic segmentation offload
no gso
rx <on|off>                 # RX checksumming
no rx
tx <on|off>                 # TX checksumming
no tx
sg <on|off>                 # scatter-gather (prasyarat TSO/GSO)
no sg
rx-usecs <0-1000>           # jeda tunda interupsi receive, mikrodetik
                            # (nilai besar = interupsi lebih jarang, latensi naik)
no rx-usecs
adaptive-rx <on|off>        # driver menyesuaikan rx-usecs otomatis ikut beban
no adaptive-rx
smp_affinity <mask>         # mask afinitas CPU (contoh: 4, 0-3, 12-19)
smp_affinity_XPS <mask>     # afinitas XPS enable
```

FreeBSD (subset, via ifconfig):

```
tso <on|off>                # ifconfig tso/-tso
no tso
lro <on|off>                # ifconfig lro/-lro
no lro
rx <on|off>                 # ifconfig rxcsum/-rxcsum
no rx
tx <on|off>                 # ifconfig txcsum/-txcsum
no tx
```

Memeriksa hasil tuning:

```
show interfaces tuning <iface>   # mode exec
```

Tool bantu read-only (di luar CLI, di host): `titian-tune-recommend`
memberi rekomendasi tuning tanpa mengubah apa pun. Notes: sukses
live coalesce (rx-usecs) belum terbukti di NIC lab; "dso" ditafsirkan
sebagai keluarga TSO/GSO.

---

## 4. View VXLAN — overlay L2 di atas UDP/IP

```
interface vxlan <vxlanN>
```

Di view VXLAN (kedua OS, kecuali dinyatakan lain):

```
vni <1-16777215>            # VXLAN Network Identifier
no vni                      # kembali ke placeholder (Linux: id 1;
                            # FreeBSD: tanpa vxlanid)
local <ipv4>                # alamat VTEP lokal (underlay, harus terjangkau lawan)
no local
remote <ipv4>               # alamat VTEP lawan (unicast); menghapus group+dev bila ada
no remote
group <multicast> dev <iface>
                            # varian multicast + underlay device;
                            # menghapus remote bila ada
no group                    # hapus multicast group + dev
dstport <1-65535>           # UDP dstport VXLAN
no dstport                  # kembali ke 4789
ip address <CIDR> [peer <ip-peer>]
no ip address <CIDR>
ipv6 address <CIDR> [peer <ipv6-peer>]   # Linux; FreeBSD tanpa peer
no ipv6 address <CIDR>
description <teks>
no description
mtu <nilai>                 # MTU overlay; batas berguna 1450 untuk overhead
                            # VXLAN ~50 byte (dibuktikan uji DF)
no mtu
disable / enable
options                     # [Linux] tuning lanjutan (§3.4)
exit
```

Aturan penting:

- **Unicast vs multicast saling meniadakan.** Mengatur `remote` menghapus
  `group`+`dev`, dan sebaliknya. Pilih satu.
- **Mengubah VNI = recreate interface** (flap singkat; MAC stabil). Jangan
  heran bila interface berkedip saat VNI diubah.
- **dstport:** Linux WAJIB 4789 (IANA); default historis Linux 8472 jangan
  dibiarkan. FreeBSD tetap 4789 — nilai lain ditolak.
- **MTU overlay:** 1450 adalah batas berguna untuk overhead VXLAN; MTU
  underlay yang lebih kecil dari itu akan memecah paket.
- Status VXLAN: `show interfaces vxlan [iface]` (mode exec) menampilkan
  status + VNI + local/remote + FDB.
- Status uji: unicast guest-ke-guest terbukti di kedua OS; multicast
  end-to-end TIDAK terbukti (FreeBSD tidak join grup) — jangan mengandalkan
  multicast sebelum diuji di lingkunganmu.

Contoh pasangan unicast (dua sisi, VNI sama, local/remote bersilangan):

```
# Sisi A
interface vxlan vxlan10
vni 10
local 192.0.2.10
remote 192.0.2.11
ip address 198.51.100.1/24
exit

# Sisi B
interface vxlan vxlan10
vni 10
local 192.0.2.11
remote 192.0.2.10
ip address 198.51.100.2/24
exit
```

---

## 5. Bonding (Linux) dan LAGG (FreeBSD)

### 5.1 Linux bonding

```
configure terminal
interface bonding bond0
mode 802.3ad
hash-policy layer2
ip address 198.51.100.1/24
exit
interface ethernet enp1s0
speed 1000 duplex full
bond-group bond0
exit
interface ethernet enp2s0
speed 1000 duplex full
bond-group bond0
exit
end
save
```

Urutan yang benar: buat bond dulu, atur mode, baru tempelkan slave.
`speed` pada slave wajib benar untuk LACP di atas NIC virtual. Melepas
slave: `no bond-group bond0` di view interface member. Menghapus bond
yang masih punya slave gagal (`[slave lock]`) — lepas semua slave dulu.
Status: `show interfaces bonding bond0 detail`.

### 5.2 FreeBSD lagg

```
configure terminal
interface lagg lagg0
laggport vtnet1
laggport vtnet2
ip address 198.51.100.1/24
exit
end
save
```

Perintah member di FreeBSD adalah `laggport <member>` / `no laggport
<member>` di view interface lagg (bukan di view member). Status:
`show interfaces lagg lagg0 detail`.

---

## 6. Routing — verifikasi

Route dan gateway diatur di mode configure (§2.2). Verifikasi dari exec:

```
show ip route                 # tabel IPv4 lengkap
show ip route 198.51.100.0/24 # filter satu prefix
show ipv6 route
show ip neighbor              # ARP/neighbor
```

Route statik yang dibuat lewat CLI ikut di-generate ke BIRD (section
static) dan bisa di-redistribute ke BGP dari view BIRD (§7.4).

---

## 7. View BIRD — routing dinamis

Masuk dari exec:

```
bird
bird terminal
```

View BIRD mengelola daemon BIRD2: menampilkan status, me-render dan
menerapkan section konfigurasi, mengelola community BGP dan redistribusi.
Definisi protokol (BGP/OSPF/BFD/direct/pipe) hidup sebagai section di
`bird.d/` (template contoh tersedia di repo) dan diterapkan dengan
`generate` — view ini tidak membuat neighbor dari nol, ia mengelola
section, community, dan redistribusi di atasnya.

### 7.1 Show BIRD

```
show configuration [function|filter|protocol|static|bgp|ospf]
                            # cek konfigurasi per section
show route                  # route BIRD
show route ip <ip-atau-prefix>
show route all              # hitung route
show route count            # hitung route
show route protocol [bgp|ospf] [prefix]
show route export <protokol>
show protocol               # daftar protokol
show protocol summary       # ringkasan protokol
show protocol all           # detail semua protokol
show protocol neighbors <protokol>
```

### 7.2 Generate — render, cek, terapkan

```
generate check <section>    # render + cek sintaks satu section TANPA menerapkan
generate <section>          # render + cek sintaks + backup + terapkan satu section
```

Section: `function`, `filter`, `protocol`, `static`, `bgp`, `ospf`,
`direct`, `bfd`, `pipe`. Alur yang benar: `generate check` dulu, bila
bersih baru `generate`. `generate` tidak bisa mereproduksi bird.conf
*anchor* dari nol — untuk kembali ke keadaan awal, restore salinan file
bird.conf + `birdc configure` (atau rollback checkpoint, §9).

### 7.3 Community BGP

```
community list add <nama> <nilai>     # definisikan named community list
community list delete <nama>
community list show                   # daftar list yang terdefinisi
community export add <nilai>          # set community pada export BGP
community export delete <nilai>
community export show                 # filter export BGP
community import add <nilai> <aksi>   # match community pada import + aksi
                                      # (aksi: reject, localpref:N, med:N)
community import delete <nilai>
community import show                 # filter import BGP
```

Nilai community mencakup standard, well-known, extended, dan large.
Contoh:

```
community list add pelanggan 64512:100
community export add 64512:100
community import add 64512:100 localpref:200
community import show
```

### 7.4 Redistribusi ke BGP

```
redistribute static enable    # ekspor route statik ke BGP
redistribute static disable
redistribute direct enable    # ekspor route connected ke BGP
redistribute direct disable
redistribute show             # status redistribusi
```

### 7.5 Kontrol protokol

```
reload <protokol>             # reload satu protokol
reload in <protokol>          # reload route inbound protokol
reload out <protokol>         # reload route outbound protokol
restart <protokol>            # restart satu protokol
restart all                   # restart semua protokol
disable <protokol>            # nonaktifkan protokol
enable <protokol>             # aktifkan protokol
exit                          # keluar dari view BIRD
```

Catatan khusus BGP FreeBSD: sesi BGP di atas alamat PtP `/32` yang tidak
directly-connected di device protocol BIRD membutuhkan `multihop` +
static peer route agar Established — itu perilaku BIRD, bukan bug Titian.
BFD-over-BGP single-hop di atas interface management belum pernah diuji;
BFD direct (OSPF) dan multihop-BGP sudah diverifikasi di lab.

---

## 8. View firewall — filter, SNAT, DNAT (IPv4 saja)

Masuk dari configure:

```
firewall
```

Catatan: `show firewall` hanya ada di mode exec (menampilkan daftar rule
urut prioritas + dump backend live + status forwarding). Di dalam view
firewall, `show firewall` = Unknown command — `exit` dulu.

### 8.1 Semantik dasar

- **Forward default DENY; input/output default ACCEPT.** Trafik transit
  yang tidak di-permit filter forward akan dibuang.
- **Rule diidentifikasi dari ISInya, bukan ID.** Menghapus rule memakai
  sintaks lengkap yang sama dengan perintah pembuatnya.
- **DNAT dan filter berinteraksi pre/post-NAT:** filter menilai sumber
  sebelum NAT dan tujuan sesudah NAT. DNAT membutuhkan filter forward
  permit ke alamat tujuan hasil terjemahan.
- Backend: nftables (tabel `inet titian`) di Linux, pf anchor di
  FreeBSD. Setiap load dicek dulu (`nft -c` / `pfctl -n`).
- Persistensi: rule disimpan di netstate firewall dan di-replay saat
  boot (`titian-fw.sh apply-all`); checkpoint ikut menyalin netstate.

### 8.2 Filter

```
filter <forward|input|output> <permit|deny> proto <tcp|udp|icmp|all>
       src <CIDR|any> dst <CIDR|any>
       sport <port|any> dport <port|any>
       in <iface|any> out <iface|any>
```

Semua field wajib; untuk `icmp`/`all`, port tidak dipakai (isi `any`).
Menghapus: `no filter ...` dengan sintaks lengkap yang sama.

Contoh — izinkan transit HTTP dari LAN ke internet, buang sisanya
(forward default sudah DENY, jadi cukup permit yang diizinkan):

```
filter forward permit proto tcp src 198.51.100.0/24 dst any sport any dport 80 in enp1s0 out any
filter forward permit proto tcp src 198.51.100.0/24 dst any sport any dport 443 in enp1s0 out any
```

### 8.3 SNAT

```
snat <srcnet> to <alamat|masquerade> out <iface|any>
no snat <srcnet> to <alamat|masquerade> out <iface|any>
```

Contoh:

```
snat 198.51.100.0/24 to masquerade out enp1s0
snat 198.51.100.0/24 to 203.0.113.10 out enp1s0
```

### 8.4 DNAT / port forwarding

```
dnat <tcp|udp> in <iface> dport <port-publik> to <alamat> port <port-tujuan|same>
no dnat <tcp|udp> in <iface> dport <port-publik> to <alamat> port <port-tujuan|same>
```

`in` wajib — DNAT selalu terikat interface masuk. Contoh (lengkap
dengan filter forward ke tujuan terjemahan):

```
dnat tcp in enp1s0 dport 8080 to 198.51.100.5 port 80
filter forward permit proto tcp src any dst 198.51.100.5 sport any dport 80 in enp1s0 out any
```

### 8.5 Hapus semua dan batasan FreeBSD (pf)

```
no firewall     # dari mode configure: hapus SELURUH konfigurasi firewall
```

Batasan pf yang ditolak mentah-mentah (bukan diem-diem diubah):

- filter dengan `out` = interface (bukan `any`) → ditolak;
- filter dengan `in` = `any` → ditolak (wajib iface);
- snat tanpa `out` interface → ditolak;
- forward default-deny di FreeBSD hanya berlaku untuk interface yang
  disebut filter-forward/dnat.

Tanpa IPv6, tanpa redirect, tanpa shaping/scrub di versi ini.

---

## 9. Checkpoint, rollback, dan rename (mode exec)

### 9.1 Checkpoint — titik simpan bernama

```
checkpoint save <nama>     # simpan running-config saat ini sebagai titik
                           # bernama (beku; save biasa tidak mengubahnya)
checkpoint list            # daftar titik (nama + waktu WIB;
                           # * = sama dengan running-config saat ini)
show checkpoints           # sama dengan checkpoint list
checkpoint delete <nama>   # hapus satu titik
```

Nama titik: `[A-Za-z0-9_-]+`. Snapshot berisi running-config + bird.conf
+ bird.d + netstate + sysctl + meta, di
`/opt/titian/etc/checkpoints/<nama>/`.

### 9.2 Rollback

```
rollback <nama>   # kembali ke titik checkpoint bernama
rollback          # tanpa nama = kembali ke startup-config
                  # (membuang perubahan running yang belum di-save)
```

Rollback bersifat PERSISTEN dan me-restart service. Urutan aman sebelum
perubahan berisiko: `checkpoint save pra-ubah`, lakukan perubahan, bila
gagal `rollback pra-ubah`, bila berhasil `save`.

### 9.3 Rename interface (persisten)

```
rename <nama-lama> <nama-baru>
```

**Perintah ini di mode exec (enable-view), BUKAN di `configure terminal`.**
Jalankan dari prompt `cli-...#`, bukan dari `(config)#`.

Contoh (Linux):

```
show interfaces terse
rename enp1s0 wan0
```

Contoh (FreeBSD, gaya Junos — ge untuk 1G, xe untuk 10G):

```
show interfaces terse
rename igb1 ge1
rename ixl3 xe3
```

Rename memigrasi netstate + startup-config + *mirror* + referensi
(laggport, parent VLAN FreeBSD) dan persisten melewati reboot: Linux
memakai systemd `.link` (MACAddress), FreeBSD memakai blok
`#-TITIAN-RENAME-#` di rc.conf. Perintah ini me-restart service dan punya
fail-rollback pra-restart.

**Peringatan:** rename me-restart service titian, dan restart service
mengosongkan running-config. Sesudah rename, jalankan
`show running-config` — bila kosong atau ada seksi hilang (mis. interface
yang baru di-rename atau VLAN yang parent-nya di-rename), rebuild seksi
tersebut lewat CLI, lalu `commit` + `save`. (Contoh nyata: rename
`ixl3`→`xe3` membuat `interface ethernet xe3` + `interface vlan 99 ge3`
hilang dari running-config; keduanya harus dibuat ulang manual.)

Batasan:

- Nama baru memakai charset IFACE_SYS (maks 15 karakter), belum dipakai
  sistem, dan bukan nama objek Titian (bond/vxlan/lagg/vlan/loopback —
  objek-objek itu TIDAK bisa di-rename; hapus dan buat ulang).
- Validasi lantang: bila ada perubahan running yang belum di-save dan
  menyentuh interface tersebut, perintah meminta save dulu (heuristic
  live-only) — jalankan `save`, lalu ulangi `rename`.
- Rename TIDAK mengubah nama interface di dalam bird.conf mentah; yang
  dimigrasi adalah state Titian dan referensinya.

---

## 9a. IPoE — DHCP client & server

**Catatan penting:** mpd5 TIDAK mendukung IPoE. mpd5 adalah daemon PPP
(PPPoE/PPTP/L2TP). IPoE adalah IP polos di atas Ethernet, alias DHCP —
tanpa sesi PPP, tanpa username/password. Titian mengimplementasikan IPoE
via DHCP: `dhclient` (client) dan `isc-dhcpd` (server), keduanya sudah
ada di image.

### 9a.1 IPoE client — WAN via DHCP

```
configure terminal
interface ethernet ge1
ip address dhcp
commit
save
```

Interface mendapat IP + gateway + DNS dari DHCP server di ujung sana.
Untuk berhenti:

```
configure terminal
interface ethernet ge1
no ip address dhcp
commit
```

### 9a.2 IPoE server — DHCP untuk subscriber

```
configure terminal
ipoe-server
interface bridge0
pool 10.99.40.0/24 10.99.40.100 10.99.40.200 10.99.40.1 8.8.8.8
enable
end
configure terminal
commit
save
```

Format pool: `pool <subnet>/<prefix> <awal> <akhir> <gateway> <dns>
[lease-detik]`. Lease default 86400 detik (1 hari). `commit` men-generate
`/usr/local/etc/dhcpd.conf` dan menjalankan `dhcpd` pada interface yang
dipilih. Syarat: interface harus punya IP di subnet pool yang sama
(mis. pool 10.99.40.0/24 butuh interface ber-IP 10.99.40.x) — kalau tidak,
`dhcpd` menolak start.

Hapus seluruh konfigurasi IPoE server:

```
configure terminal
no ipoe-server
commit
```

---

## 9b. BGP — neighbor, filter, atribut (BIRD)

BGP dikonfigurasi lewat view `router bird` (configure-view). Intent
disimpan di `/etc/titian/bgp.conf` (dipersistenkan ke `/cfg/titian/`
oleh `save`), di-generate menjadi section BIRD
`/etc/titian/bird.d/bgp.conf`, lalu diterapkan ke `bird.conf` lewat
marker `#-BGP-#` … `#-ENDBGP-#` oleh `titian-bird.sh generate bgp`
saat `commit`. BIRD **tidak** perlu di-restart — `birdc configure`
cukup (commit sudah memanggilnya).

### 9b.1 Alur dasar — satu neighbor eBGP

```
configure terminal
router bird
router-id 10.99.40.1
local-as 65000
neighbor 10.99.40.2
remote-as 65001
description RB3011-TEST
local-pref 100
med 50
prepend 2
community 65000:100
exit
network 10.99.40.0/24
end
configure terminal
commit
save
```

Perintah di dalam view `neighbor` (prompt
`(config-bird-neighbor-<IP>)#`):

| Perintah | Arti |
|---|---|
| `remote-as <AS>` | AS neighbor (wajib — neighbor baru dibuat di sini, import/export default `all`) |
| `description <teks>` | Deskripsi (satu kata; tampil di bird.conf) |
| `import all` / `import none` | Terima semua / tidak ada route |
| `import filter <NAMA>` | Terima hanya route yang lolos filter NAMA |
| `export all` / `export none` | Kirim semua / tidak ada route |
| `export filter <NAMA>` | Kirim hanya route yang lolos filter NAMA |
| `local-pref <N>` | Local-preference default untuk route dari neighbor ini |
| `med <N>` | MED yang dikirim ke neighbor ini |
| `prepend <N>` | Jumlah AS-path prepend saat export (panggil `bgp_path.prepend()` N kali) |
| `community <AS:NN>` | Community yang ditambahkan saat export |

### 9b.2 Filter

```
configure terminal
router bird
filter F-RB3011-IN
accept 10.0.0.0/8
reject 192.168.0.0/16
exit
neighbor 10.99.40.2
import filter F-RB3011-IN
exit
end
configure terminal
commit
```

Perintah di dalam view `filter` (prompt
`(config-bird-filter-<NAMA>)#`):

| Perintah | Arti |
|---|---|
| `accept <prefix>` | Terima prefix ini |
| `reject <prefix>` | Tolak prefix ini |
| `accept community <AS:NN>` | Terima route dengan community ini |
| `reject community <AS:NN>` | Tolak route dengan community ini |

Filter selalu diakhiri `reject;` (default-deny). Nama filter boleh
mengandung `-` di CLI, tapi di-generate menjadi `_` di bird.conf
(BIRD menolak `-` di nama identifier).

### 9b.3 Network yang diiklankan

```
router bird
network 10.99.40.0/24
```

Prefix harus ada di tabel routing (connected / kernel / static)
dan lolos export filter. Bila `export all`, semua route di tabel
teriklankan; bila `export filter`, pastikan filter menerima prefix
tersebut.

### 9b.4 Verifikasi

```
show bgp                    # intent bgp.conf + section bird.d/bgp.conf
show protocol               # status protokol BIRD (birdc)
show protocol bgp           # detail sesi BGP
birdc show route protocol bgp_10_99_40_2
```

Status sesi BGP di `show protocol`: `Active` = BIRD mencoba
connect ke peer (belum Established — peer belum konfig / belum
listen port 179). `Established` = sesi jalan, route bertukar.
`Socket: Connection refused` = peer reachable tapi port 179
belum ada yang listen (BGP belum dikonfigurasi di sisi peer).

### 9b.5 Gotcha (ditemukan saat uji live 13 Nov 2026)

- **import/export WAJIB di dalam channel `ipv4 { }`.** BIRD 2.20.0
  menolak `import all;` langsung di dalam `protocol bgp`
  (`syntax error, unexpected IMPORT`). Generator selalu menulis
  channel `ipv4 { }`.
- **`router id` adalah setting GLOBAL**, bukan per-protocol.
  Generator menulisnya ke bird.conf di luar section BGP.
- **`bgp_path.prepend()` hanya terima 1 argumen (AS).**
  Untuk prepend N kali, generator memanggilnya N kali.
- **Nama filter/protocol tidak boleh mengandung `-`** di BIRD.
  Generator mengubah `-` menjadi `_` (konsisten di definisi
  dan referensi).
- **Prefix set di filter WAJIB pakai suffix `+`.**
  `if net ~ [ 10.0.0.0/8 ]` (tanpa `+`) TIDAK match prefix yang
  lebih spesifik (mis. 10.99.98.0/24) — filter menolak semua route.
  Yang benar: `if net ~ [ 10.0.0.0/8+ ]` (prefix ini atau lebih
  spesifik). Sama untuk community: `bgp_community ~ [ (65000,100) ]`.
- **`network` di Titian hanya mencatat niat (komentar di bird.conf),
  bukan route BIRD.** Prefix baru diiklankan bila ada di tabel routing
  BIRD (via kernel/direct/static) DAN lolos export filter. Catatan:
  protocol `kernel` di bird.conf stock TIDAK punya `learn;` — route
  statik kernel (mis. `route add`) TIDAK masuk tabel BIRD. Untuk
  mengiklankan prefix baru, definisikan via protocol `static` di
  bird.conf (`route <prefix> via <nexthop>;`).
- **`router bird` (masuk view) vs `router bird enable`.**
  `router bird` saja masuk ke `(config-bird)#`; `router bird
  enable` tetap perintah di configure-view (mengaktifkan BIRD).
- **BGP section marker** `#-BGP-#` … `#-ENDBGP-#` harus ada di
  bird.conf (ditambahkan sekali saat deploy; stock bird.conf
  tidak memilikinya).

### 9b.6 Hapus

```
configure terminal
router bird
no neighbor 10.99.40.2
no network 10.99.40.0/24
no filter F-RB3011-IN
end
configure terminal
commit
save
```

---

## 9c. FRR — routing suite alternatif (bukan BIRD)

FRR (`net/frr10`, versi 10.7.1 di image) adalah routing suite
alternatif pengganti BIRD. BIRD dan FRR **tidak bisa jalan bersamaan**
— mutual exclusion keras dua arah (exit 33): `router bird enable` +
`router frr enable` bersamaan ditolak, dicek dari tiga sumber
(`bird_enable`/`frr_enable` di rc.conf, status service, proses
`bird`/`zebra` yang jalan, dan niat pending di
`/etc/titian/netstate/routing.intent`).

**Perbedaan penting vs BIRD — fiturnya TIDAK sama di lapisan klish:**

| Aspek | BIRD (klish) | FRR (klish) |
|---|---|---|
| BGP neighbor, filter, network | Ya — lengkap via `router bird` (§9b) | Tidak — tidak ada perintah neighbor/filter di klish |
| Atribut (local-pref, MED, prepend, community) | Ya — per-neighbor | Tidak — tidak ada di klish |
| Enable/disable + `commit` | Ya | Ya (`router frr enable`) |
| Config dasar (router-id, log) | Ya (`router-id`, via bird.conf) | Ya — langsung via `vtysh` + `write memory` |
| Show status/versi | Ya (`show bird`, `show route`) | Ya (`show frr`, `show frr version`) |

Konfigurasi routing protocol FRR (BGP neighbor, route-map,
prefix-list, community, local-pref, MED, AS-path prepend) dilakukan
**langsung di `vtysh`** (perintah `cli` di Titian masuk ke vtysh),
bukan lewat klish. Model native FRR: config via vtysh berlaku
langsung (running) + `write memory` agar persisten ke
`/usr/local/etc/frr/frr.conf`. Daemon FRR sendiri mendukung semua
fitur itu (route-map, prefix-list, community standard/large,
local-pref, MED, prepend) — hanya saja jalurnya vtysh, bukan klish.

### 9c.1 Enable — BIRD harus mati dulu (dua commit terpisah)

Exclusion dicek terhadap service/proses yang **masih jalan**, bukan
hanya niat. Jadi matikan BIRD + `commit` dulu, baru enable FRR:

```
! Langkah 1 — matikan BIRD
configure terminal
no router bird enable
end
configure terminal
commit
save
! Langkah 2 — baru enable FRR
configure terminal
router frr enable
end
configure terminal
commit
save
```

`commit` langkah 2 menjalankan `titian-frr.sh frr-apply`:
`sysrc frr_enable="YES"` + `service frr start` (daemon `zebra` naik
dulu; `bgpd`/`ospfd` naik bila dikonfigurasi di `frr.conf`).
Matikan FRR: `no router frr enable` + `commit` + `save`
(`service frr onestop` + `frr_enable="NO"`).

**Di balik layar (FreeBSD `net/frr10`, rc script resmi `frr.in`):**
`service frr start` → `watchfrr` → restart semua daemon di
`frr_daemons` → `vtysh -b` memuat boot config. Variabel rc.conf
yang relevan (default dari `frr.in`):

```
frr_enable="YES"
frr_daemons="mgmtd zebra staticd bgpd"   # minimal untuk BGP; default = semua daemon
frr_vtysh_boot="YES"                     # default; config terpadu (frr.conf)
watchfrr_enable="YES"                    # default; watchfrr mengawasi & me-restart daemon
frr_default_profile="traditional"        # alternatif: "datacenter"
zebra_flags="-A 127.0.0.1"               # default
```

Urutan `frr_daemons` penting — `mgmtd` dulu, lalu `zebra`. Saat
start dengan `frr_vtysh_boot=YES`, rc script otomatis membuat
`/usr/local/etc/frr/vtysh.conf` (`service integrated-vtysh-config`)
dan `/usr/local/etc/frr/frr.conf` (`log syslog informational`) bila
belum ada (owner `frr:frr`). Config terpadu di
`/usr/local/etc/frr/frr.conf` (header lazim: `frr version 10.x` +
`frr defaults traditional` + `hostname <nama>`). Socket/PID daemon:
`/var/run/frr/`. Reload tanpa restart: `service frr reload` (butuh
paket `frr10-pythontools`).

**BSDRP (dokumentasi resmi):** BSDRP menyertakan KEDUA daemon —
*"For a routing protocol daemon, you can choose between Bird and
FRRouting."* Cara enable di BSDRP (User Guide, Quick start):
`sysrc frr_enable=yes` → `service frr start` → `cli` (masuk CLI
FRR) → `wr` (simpan) → `exit` → `config save` (persist `/etc` +
`/usr/local/etc`, keduanya di RAM disk BSDRP). Ada service
`autosave` (`sysrc autosave_enable=yes`) agar `config save` jalan
otomatis tiap ada perubahan. BSDRP 2.0 = bird 2.17 + frr 10.4.1;
lab terbaru menyebut Bird 3 + FRRouting 10.

**Kenapa tidak bisa bersamaan:** BIRD (protocol bgp) dan FRR
`bgpd` sama-sama listen TCP 179 untuk sesi BGP masuk — dua proses
tidak bisa bind port yang sama. BSDRP memperlakukan keduanya
sebagai **alternatif** ("choose between"), bukan untuk dijalankan
bersamaan. Interop BIRD↔FRR terbukti di level protokol (lab BSDRP
route-reflector + confederation mencampur Bird 3 dan FRR 10 sebagai
peer BGP) — tapi itu di **router berbeda**, bukan satu host.

### 9c.2 Config dasar via klish (langsung vtysh + write memory)

```
configure terminal
router frr
router-id 10.99.40.1
log syslog
write-memory
exit
end
```

| Perintah | Arti |
|---|---|
| `router-id <IPv4>` | Router ID FRR (dipakai OSPF/BGP) — langsung via vtysh + `write memory` |
| `no router-id` | Hapus router-id |
| `log syslog` / `no log syslog` | Log FRR ke syslog / matikan |
| `write-memory` | Tulis running-config FRR ke `/usr/local/etc/frr/frr.conf` (persisten) |

Perintah ini berlaku **langsung** (tidak menunggu `commit`) —
hanya enable/disable yang menunggu `commit`.

### 9c.3 Show

```
show frr
show frr version
```

`show frr` menampilkan versi, intent, `frr_enable` di rc.conf,
status service, dan pid `zebra` bila jalan. `show frr version`
menampilkan versi + output `vtysh show version`.

### 9c.4 BGP via vtysh — contoh (bukan klish)

Masuk ke vtysh lewat perintah `cli` di Titian, lalu konfigurasi
BGP seperti biasa di FRR (contoh eBGP ke RB3011, AS 65001 — padanan
persis konfigurasi BIRD §9b.1):

```
! di vtysh (lewat `cli`)
configure terminal
router bgp 65000
 bgp router-id 10.99.40.1
 bgp default local-preference 100
 neighbor 10.99.40.2 remote-as 65001
 neighbor 10.99.40.2 description RB3011-TEST
 neighbor 10.99.40.2 send-community
 neighbor 10.99.40.2 route-map F-RB3011-IN in
 neighbor 10.99.40.2 route-map EXPORT-OUT out
 network 10.99.40.0/24
exit
ip prefix-list F-RB3011-IN seq 5 permit 10.0.0.0/8 le 32
ip prefix-list F-RB3011-IN seq 10 deny 192.168.0.0/16 le 32
ip prefix-list F-RB3011-IN seq 20 deny any
ip prefix-list EXPORT-NET seq 5 permit 10.99.40.0/24
route-map F-RB3011-IN permit 10
 match ip address prefix-list F-RB3011-IN
 set local-preference 100
route-map F-RB3011-IN deny 20
route-map EXPORT-OUT permit 10
 match ip address prefix-list EXPORT-NET
 set community 65000:100
 set metric 50
 set as-path prepend 65000 65000
end
write memory
```

Padanan atribut BIRD → FRR: `local-pref` = `set
local-preference` (atau `bgp default local-preference`),
`med` = `set metric`, `prepend N` = `set as-path prepend`
(bisa banyak ASN sekaligus), `community` = `set community`
(+ `neighbor X send-community` agar dikirim ke peer), filter
import/export = `route-map ... in/out` + `prefix-list` (+
`match community` bila perlu). Route-map + prefix-list FRR
**lebih ekspresif** dari filter BIRD karena bisa match
community/AS-path/metric, bukan hanya prefix. Yang tidak ada
padanannya 1:1 di FRR: bahasa filter BIRD (`if ... then` di
`bird.conf`) — di FRR semua policy lewat route-map/prefix-list/
community-list.

**Community — standard, large, well-known:**
- Standard: `set community 65000:100`; kirim: `neighbor X
  send-community`.
- Large (RFC 8092, format `ASN:V1:V2`): `set large-community
  65000:100:999` + `neighbor X send-community large` (`both` =
  standard+large, `all` = +extended).
- Match: `ip community-list standard NAMA permit 65000:100`
  lalu `match community NAMA` di route-map.
- Well-known: `no-export` = 65535:65281 (jangan advertise ke
  luar confederation); `no-advertise` = 65535:65282 (jangan
  advertise ke peer mana pun); `local-AS` = 65535:65283;
  `no-peer` = 65535:65284; `blackhole` = 65535:666 (RFC 7999).
  Di route-map: `set community no-export`. Tambah tanpa
  menimpa: `set community ... additive`.

**Verifikasi (vtysh):**

```
show ip bgp summary
show ip bgp neighbors 10.99.40.2 advertised-routes
show ip bgp neighbors 10.99.40.2 received-routes
show ip bgp community 65000:100
show ip route
```

**Quirk FreeBSD (diketahui):** FRR 9.x–10.1.1 di FreeBSD 14
tidak menampilkan default gateway & static route kernel di
`show ip route` (issue #17113). Di 10.7.1 kemungkinan sudah
diperbaiki, tapi saat uji FRR nanti **wajib verifikasi `show ip
route` memuat route kernel** (default/static), bukan cuma route
BGP.

### 9c.5 Status uji (jujur)

- CLI FRR (enable, router-id, log, write-memory, show) **ada** dan
  mutual exclusion vs BIRD **sudah diuji** (gagal rc=33 dua arah).
- Paket `frr10-10.7.1_1` ter-install di image, rc script `frr` ada.
- **FRR sebagai routing daemon BELUM pernah jalan live** (13 Nov
  2026): tidak ada proses `zebra`/`bgpd`/`ospfd`, tidak ada
  `frr.conf`, `frr_enable` tidak ada di rc.conf. Uji BGP E2E ke
  RB3011 selama ini semuanya pakai BIRD, bukan FRR.
- Uji FRR live yang masih terbuka: enable FRR (BIRD mati dulu,
  §9c.1) → BGP via vtysh ke RB3011 (§9c.4) → verifikasi session
  Established + route exchange + atribut (seperti uji BIRD §9b) +
  verifikasi `show ip route` memuat route kernel (quirk §9c.4).

**Referensi:**
- FreeBSD port `net/frr10`, rc script resmi: https://raw.githubusercontent.com/freebsd/freebsd-ports/main/net/frr10/files/frr.in
- BSDRP User Guide (pilih Bird atau FRRouting): https://bsdrp.net/documentation/end-users_docs
- Lab BSDRP (BGP/OSPF/RIP/ISIS/BABEL dengan FRR): https://bsdrp.net/documentation/examples/simple-bgp-rip-ospf-lab/
- Lab BSDRP (route-reflector + confederation Bird 3 + FRR 10): https://bsdrp.net/documentation/examples/bgp-route-reflector-and-confederation-using-frr-and-bird/
- Dok resmi FRR 10.0 (BGP): https://docs.frrouting.org/en/stable-10.0/bgp.html
- Dok resmi FRR 10.0 (route-map): https://docs.frrouting.org/en/stable-10.0/routemap.html
- Issue FRR #17113 (`show ip route` tidak tampilkan route kernel di FreeBSD): https://github.com/FRRouting/frr/issues/17113

---

## 10. System, DNS, dan SSH — alur pakai

### 10.1 Identitas dan waktu

```
configure terminal
system hostname router-01
system time-zone WIB
end
save
```

Pilihan zona dari tree: WIB, WITA, UTC (plus alias pulau Jawa, Bali,
Singapore, Malaysia — ketik `system time-zone ?` untuk daftar lengkap).
Aturan proyek: zona waktu host dan container aplikasi = GMT+7
(Asia/Jakarta/WIB) untuk server/aplikasi.

### 10.2 Sysctl

```
configure terminal
system sysctl net.ipv4.ip_forward 1
end
save
show system sysctl     # exec: nilai + arti tiap kunci yang dikelola Titian
```

Menghapus: `no system sysctl net.ipv4.ip_forward` (nilai live kembali ke
nilai sebelum di-set Titian, atau bertahan sesuai perilaku kunci).

### 10.3 DNS

```
configure terminal
system domain-name example.net
system name-servers
nameserver 192.0.2.53
nameserver 198.51.100.53
exit
end
save
```

Menghapus: `no system domain-name`, `no nameserver <ip>` (di view
name-server).

### 10.4 SSH service

```
configure terminal
service ssh
port 2222
no allow-root
exit
end
save
```

### 10.5 View non-root (info-mode)

Untuk user tanpa hak privileged, tersedia view terbatas: `ping`,
`traceroute`, overview, dan startup. View ini sengaja tidak memuat
perintah konfigurasi — ia hanya membaca dan menguji konektivitas.

### 10.6 Log console (syslog) — dimatikan di image

FreeBSD default mengirim `*.err`, `kern.warning`, `auth.notice` ke
`/dev/console` (`/etc/syslog.conf` baris 7). Akibatnya log konfd habis
restart, pesan kernel (`bridge0: promiscuous mode`, dst.), dan error
daemon lain muncul di monitor/terminal dan mengganggu kerja di console.

Di image Titian/BSDRP baris itu **dihapus** — console bersih, log tetap
masuk file (`/var/log/messages`, `/var/log/daemon.log`, dst.). File-nya:
`files/BSDRP/Files/etc/syslog.conf` (overlay image; disalin ke
`/etc/syslog.conf` saat build). Pesan darurat (`*.emerg`) tetap
diberitahukan ke semua user yang login (baris `*.emerg *` dipertahankan).

Di mesin yang sudah berjalan, perbaikannya: salin file di atas ke
`/etc/syslog.conf` lalu `service syslogd reload`. Agar selamat dari
reboot (karena `/etc` = tmpfs), simpan salinannya di `/cfg/syslog.conf`
dan tambahkan hook di `/cfg/rc.local`:

```
if [ -f /cfg/syslog.conf ]; then cp /cfg/syslog.conf /etc/syslog.conf; service syslogd reload; fi
```

---

## 11. Tuning — ringkas pemakaian

Semua perintah tuning hidup di view interface (`options`, §3.4) plus
tiga perintah langsung di view interface: `mtu`, `qlen` [Linux],
`speed` [Linux]. Memeriksa: `show interfaces tuning <iface>`.

Alur yang disarankan:

```
show interfaces tuning enp1s0     # lihat nilai sekarang + artinya
configure terminal
interface ethernet enp1s0
mtu 9000
options
tso on
gro on
rx-usecs 125
exit
exit
end
save
```

Tool `titian-tune-recommend` (host, read-only) memberi rekomendasi
sebelum mengubah apa pun. `no <setelan>` selalu mengembalikan nilai
pra-Titian; nilai live bertahan sampai reboot untuk `speed` karena
driver tidak mengembalikan nilai lama.

---

## 12. Perbedaan per-OS dan batasan yang diketahui

| Hal | Linux (Debian) | FreeBSD |
|---|---|---|
| Interface ethernet | `enp*`, `eth*`, `enx*` | `vtnet*`, `em*`, `igb*`, dsb. |
| VLAN | `interface vlan <parent>.<id>` | `interface vlan <id> <parent>` |
| Agregasi | bonding (`bond0`, mode 802.3ad/round-robin) | lagg (`lagg0`, `laggport`) |
| Tuning | mtu/qlen/speed + options lengkap | mtu + options subset (tso/lro/rx/tx) |
| IPv6 peer di eth/vlan/lagg/loopback | didukung | tidak (tanpa peer) |
| VXLAN dstport | wajib 4789 | tetap 4789, nilai lain ditolak |
| Firewall backend | nftables | pf anchor (batasan §8.5) |
| Rename persisten | systemd `.link` | blok `#-TITIAN-RENAME-#` rc.conf |
| Persistensi sysctl | `sysctl.d/99-titian.conf` | blok `#-TITIAN-#` sysctl.conf |

Batasan yang diketahui (Notes: bukan janji):

- PTY Tab/`?` belum terverifikasi di semua terminal SSH nyata.
- Kreasi VLAN FreeBSD intermiten gagal (`SIOCIFCREATE2`, akar belum
  terisolasi) — ulangi perintah bila terjadi.
- Rewrite `route-dev` dan `vxlan-group-dev` lewat rename baru teruji di
  level skrip, belum end-to-end via CLI.
- BFD-over-BGP single-hop di atas interface management belum diuji.
- VXLAN multicast end-to-end belum terbukti (FreeBSD tidak join grup).
- Coalesce live (`rx-usecs`) belum terbukti di NIC lab.
- `reboot` di CLI hanya mencetak teks, bukan me-reboot mesin.
- `show firewall` di dalam view firewall = Unknown (harus `exit` dulu).
- `save` di dalam view configure = Unknown (harus `end` dulu).
- Bare `configure` = Incompleted (pakai `configure terminal`).
- Masuk view interface membuat section persisten (lihat §2.1).

---

## 13. Alur contoh end-to-end

### 13.1 Interface PtP + route statik + simpan + checkpoint

```
sudo /usr/local/bin/titian
show interfaces terse
configure terminal
interface ethernet enp1s0
description "uplink ke ISP"
ip address 192.0.2.10/31 peer 192.0.2.11
mtu 1500
exit
ip route 198.51.100.0/24 192.0.2.11
end
save
checkpoint save pra-ubah
show running-config
```

### 13.2 VLAN + alamat + verifikasi

```
configure terminal
interface vlan enp1s0.100
description "VLAN pelanggan"
ip address 198.51.100.1/24
ipv6 address 2001:db8:100::1/64
exit
end
save
show interfaces vlan enp1s0.100 detail
ping 198.51.100.2 repeat 4
```

### 13.3 Perubahan berisiko dengan jaring pengaman

```
checkpoint save sebelum-firewall
configure terminal
firewall
filter forward permit proto tcp src 198.51.100.0/24 dst any sport any dport 443 in enp1s0 out any
snat 198.51.100.0/24 to masquerade out enp1s0
exit
end
save
show firewall
```

Bila ada yang salah: `rollback sebelum-firewall` (lalu `save` bila
ingin keadaan itu yang permanen).

---

## 14. Inventaris fitur Titian + status uji (13 Nov 2026)

Daftar satu per satu fitur yang sudah dibuat (40 XML, 29 script
`sbin/`), beserta status ujinya. Legenda: ✅ = LOLOS LIVE (terverifikasi
end-to-end di mesin test); 🟡 = SEBAGIAN (sudah ada tapi belum penuh
— mis. function-test saja, via script bukan CLI, atau sebagian
sub-fitur belum); ❌ = BELUM (perintah ada, belum diuji live).

| # | Fitur | File | Status | Catatan |
|---|---|---|---|---|
| 1 | BGP — neighbor, filter, atribut (BIRD) | conf-bgp.xml, titian-bgp.sh, bird.xml | ✅ LIVE | E2E ke RB3011 LOLOS 13 Nov ~02:35: Established, route exchange, prepend 2, MED 50, local-pref 100, community 65000:100, filter F-RB3011-IN |
| 2 | BIRD — show route/protocol, reload | bird.xml, titian-bird.sh | ✅ LIVE | Sweep 13 Nov ~00:11, 0 syntax error |
| 3 | FRR — enable, router-id, log, show | conf-frr.xml, titian-frr.sh | 🟡 SEBAGIAN | CLI + mutual exclusion vs BIRD diuji (rc=33 dua arah). Daemon BELUM pernah jalan live; BGP via FRR (vtysh) BELUM diuji — lihat §9c |
| 4 | Interface ethernet (IP/IPv6, desc, dhcp) | conf-if-eth-fbsd.xml | ✅ LIVE | xe3 (SFP, 10.99.31.1/24 + IPv6), ge0-3 sesudah rename |
| 5 | Interface VLAN | conf-if-vlan-fbsd.xml | ✅ LIVE | vlan 99 ge3 |
| 6 | Interface VXLAN | conf-if-vxlan-fbsd.xml | ✅ LIVE | vxlan100, ping 0% loss dua arah |
| 7 | Interface bridge L2 | conf-if-bridge-fbsd.xml | ✅ LIVE | bridge0 (vxlan100 + vlan99) |
| 8 | Interface LAGG / LACP | conf-if-lagg-fbsd.xml | ✅ LIVE | LACP E2E + IPv4/IPv6 LOLOS 12 Nov |
| 9 | Interface loopback | conf-if-lo-fbsd.xml | ✅ LIVE | LOLOS 13 Nov ~14:20 (lo1 10.99.88.1/32 muncul di show + ifconfig; `no interface loopback lo1` bersih) |
| 10 | Interface options (tso/lro/rx/tx) | conf-if-opt-fbsd.xml | ✅ LIVE | LOLOS 13 Nov ~14:20 (xe3: `rx off` ubah options 4e100bb→4c100ba, `rx on` kembali; `tso off` diterima, NIC ixl tidak expose TSO) |
| 11 | Static route / gateway (v4 + v6) | conf-route-fbsd.xml, conf-route6.xml | 🟡 SEBAGIAN | `ip route ... dev bridge0` LOLOS 13 Nov (muncul di show + netstat, hapus LOLOS). `forward` GAGAL — bug param (IP_ADDR, bukan SUBCOMMAND) — **diperbaiki di repo** (forward jadi subcommand + `gateway`), belum retest live |
| 12 | Firewall / NAT (pf) | conf-fw.xml | ❌ BELUM | pf.ko ADA + TER-LOAD di mesin test (bukan "belum ada di image" — klaim lama salah). Uji live BLOKIR proxy putus 13 Nov 14:33 |
| 13 | Traffic-shape / dummynet limiter | traffic-shape.xml | 🟡 SEBAGIAN | Function-test (staged, full masks); uji E2E live BLOKIR proxy putus 13 Nov 14:33 |
| 14 | PPPoE server (mpd5, pool, user, RADIUS) | conf-pppoe.xml | ❌ GAGAL | **GAGAL 13 Nov**: LCP + auth OK, tapi mpd5 kirim PADT terminate sebelum IPCP (akar belum ketemu, butuh logging verbose). Bug escaping `!` + `no user` **diperbaiki di repo**, retest pending proxy |
| 15 | IPoE server (DHCP) | conf-ipoe.xml | ✅ LIVE | **LOLOS 13 Nov**: RB3011 (DHCP client) bound 10.99.41.100/24, gw 10.99.41.1, DNS 8.8.8.8, ping 3/3. Akar awal gagal: VTEP RB3011 kosong (broadcast putus) — fix sintaks v7 `/interface vxlan vteps add interface=vxlan100 remote-ip=10.10.2.3` |
| 16 | WireGuard | conf-wireguard.xml | ❌ BELUM | `ifconfig wg` belum diuji live |
| 17 | Monitoring (SNMP, node/bird-exporter, nfacctd) | conf-monitoring.xml | ✅ LIVE | **LOLOS 13 Nov**: `snmp enable` + community test + `commit` → snmpd pid 46802, listen 161/udp, snmpget sysDescr OK; `no snmp enable` + community kembali bsdrp-ro, snmpd mati |
| 18 | System (hostname, timezone, sysctl) | conf-sys.xml | ✅ LIVE | **LOLOS 13 Nov**: hostname/time-zone/sysctl `net.inet.tcp.delayed_ack` 1→0→1 terverifikasi; localtime dihapus kembali |
| 19 | DNS (domain-name, name-servers) | conf-sys-dns.xml | ✅ LIVE | **LOLOS 13 Nov**: nameserver 8.8.8.8 masuk resolv.conf; `no nameserver` kembali baseline |
| 20 | Service SSH (port, allow-root) | conf-serv-ssh.xml | 🟡 SEBAGIAN | SSH jalan (OS-level, port 9393 via NAT); perintah klish `service ssh` belum diverifikasi live (BLOKIR proxy putus 13 Nov 14:33) |
| 21 | Checkpoint / rollback | en-checkpoint.xml | ✅ LIVE | **LOLOS 13 Nov**: `checkpoint save` + ubah deskripsi xe3 + `rollback` kembalikan + `checkpoint delete`; BGP sempat bounce lalu re-Established |
| 22 | Rename interface | en-rename.xml | 🟡 SEBAGIAN | Rename igb→ge / ixl→xe LOLOS live via script (SSH); perintah CLI `rename` GAGAL via CLI (BLOKIR proxy putus 13 Nov 14:33) |
| 23 | Terminal / pager (length, no-more) | en-terminal.xml | ✅ LIVE | Pager `less`, sweep 13 Nov 0 syntax error |
| 24 | Show (dasar, interface, routing, system, hardware) | en-show.xml, en-show-hw.xml, en-show-routing.xml, en-show-if-*.xml | ✅ LIVE | Sweep 13 Nov ~00:11, semua show jalan, 0 syntax error |
| 25 | Ping / traceroute | ping.xml | ✅ LIVE | **LOLOS 13 Nov**: ping 10.99.40.2 5/5 0% loss ~0,3 ms; ping 8.8.8.8 5/5 ~28 ms; traceroute 1 hop. Bug kosmetik "expr: syntax error" 2x **diperbaiki di repo** (buang `expr substr`, pakai conditional langsung) |
| 26 | Commit / commit check / save | conf-commit.xml, enable-mode.xml | ✅ LIVE | Commit + save teruji ekstensif (termasuk save 13 Nov 13:55 yang menyinkronkan bgp.conf) |
| 27 | Boot replay / startup-config | startup.xml, titian-boot.sh, titian-cfg.sh | ✅ LIVE | Replay boot LOLOS (reboot ke-5); persistensi /cfg LOLOS |

**Yang paling terbuka (prioritas uji berikut):** FRR live (daemon +
BGP via vtysh, §9c.5) · PPPoE (GAGAL — akar terminate belum ketemu,
butuh logging verbose mpd5) · WireGuard · firewall/NAT ·
traffic-shape · static route `forward` (perbaikan di repo, belum
retest live) · rename CLI · service SSH. Semuanya BLOKIR proxy SSH
VM putus sejak 13 Nov 14:33 (masih putus 14:57).

> **Update hitungan (13 Nov ~15:00, sesudah uji live tes 1–10):**
> dari 27 baris di atas, yang ✅ LIVE = **19**, yang 🟡 SEBAGIAN =
> **5** (FRR, static route, traffic-shape, SSH, rename), yang ❌
> BELUM/GAGAL = **3** (firewall/NAT, PPPoE GAGAL, WireGuard).
> Sebelum uji: 11/7/9. Detail uji: `~/workspace/
> titian-live-test-20261113/HASIL.md` (di VM, bukan di repo).

---

## Penutup

Dokumen ini mendeskripsikan permukaan CLI sesuai tree di repositori ini
(`tree/` + `tree-nonroot/`). Bila ada perintah di sesi interaktif yang
tidak ada di sini, `?` di posisi tersebut adalah sumber kebenaran —
tree adalah definisi CLI, dokumen ini ringkasannya.

Dokumen terkait di repo: `PANDUAN.md` (instalasi dari paket rilis +
penggunaan dasar), `README-panjang.md` (gambaran proyek + layout +
fitur). Instalasi dari paket: lihat Releases.
