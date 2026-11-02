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
| BIRD | `bird` atau `bird terminal` dari exec | `rtcli-...(birdc)#` | `exit` |
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
help                 # gambaran sintaks RTCLI
```

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
live + persisten (disimpan di netstate `.tuning` + cermin, diterapkan ulang
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
memberi rekomendasi tuning tanpa mengubah apa pun. Catatan jujur: sukses
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
jangkar dari nol — untuk kembali ke keadaan awal, restore salinan file
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

Contoh:

```
show interfaces terse
rename enp1s0 wan0
```

Rename memigrasi netstate + startup-config + cermin + referensi
(laggport, parent VLAN FreeBSD) dan persisten melewati reboot: Linux
memakai systemd `.link` (MACAddress), FreeBSD memakai blok
`#-TITIAN-RENAME-#` di rc.conf. Perintah ini me-restart service dan punya
fail-rollback pra-restart.

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

Batasan yang diketahui (jujur, bukan janji):

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

## Penutup

Dokumen ini mendeskripsikan permukaan CLI sesuai tree di repositori ini
(`tree/` + `tree-nonroot/`). Bila ada perintah di sesi interaktif yang
tidak ada di sini, `?` di posisi tersebut adalah sumber kebenaran —
tree adalah definisi CLI, dokumen ini ringkasannya.

Dokumen terkait di repo: `PANDUAN.md` (instalasi dari paket rilis +
penggunaan dasar), `README-panjang.md` (gambaran proyek + layout +
fitur). Instalasi dari paket: lihat Releases.
