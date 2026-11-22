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
  ke startup-config di `/etc/titian/startup-config`, cermin `/cfg/titian/startup-config`).
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

Pager berlaku **global untuk semua perintah show**: bila output melebihi
satu layar, output ditampilkan bertahap lewat pager `less` (bukan
langsung tercurah semua). Berlaku untuk `show interfaces`, `show ip
route`, `show bgp summary`, `show ospf neighbors`, `show running-config`,
`show startup-config`, dan semua perintah show lain — termasuk perintah
`birdc show ...` di view BIRD. Di dalam pager: `SPACE` = halaman
berikut, `ENTER` = baris berikut, `q` = keluar, `/teks` = cari. Bila
output muat satu layar, pager langsung selesai tanpa jeda. Warna status
(hijau/merah) tetap tampil di dalam pager.

```
show interfaces              # bertahap bila melebihi satu layar
show running-config          # bertahap (pager)
show running-config no-more  # tanpa pager, curah semua sekaligus
show startup-config no-more  # sama untuk startup-config
show route help              # daftar sub-perintah show route, dipager
show help                    # daftar sub-perintah show, dipager
help all                     # daftar semua perintah top-level, dipager
terminal length 24           # pager aktif (default 24 baris)
terminal length 0            # pager mati (semua output tercurah)
terminal no-more             # sama dengan terminal length 0
terminal more                # pager aktif lagi (length 24)
```

Catatan: pager hanya aktif bila output ke terminal interaktif (TTY).
Bila output di-pipe atau di-script (bukan TTY), pager otomatis nonaktif
dan output tercurah penuh — aman untuk automation. Perintah yang TIDAK
dipager (harus tetap streaming/live): `ping`, `traceroute`,
`show system top`, tampilan live `monitoring`, serta perintah
`factory-reset` (arm/confirm/restore) — dan perintah yang mengubah state
(mis. `reload`, `restart`, `disable`, `enable` di view BIRD) yang
output-nya hanya satu-dua baris konfirmasi.

Batas yang diketahui: `?` (help inline — daftar sub-perintah saat mengetik
mis. `show route ?`) TIDAK BISA dipager. Daftar itu dirender klish
sendiri di dalam line editor, sebelum perintah dieksekusi — tanpa ACTION
apa pun — dan klish 2.2.5 tidak punya opsi/hook pager untuknya (`terminal
length 0` pun tidak mengubah output `?`). Alternatif yang dipager
(dibaca dari XML saat runtime, jadi selalu sinkron dengan definisi
perintah; lewat pager `less` bila melebihi satu layar): `show route help`
— daftar sub-perintah yang sama dengan `show route ?`; `show help` —
daftar sub-perintah yang sama dengan `show ?` (36 entri); `help all` —
daftar semua perintah top-level yang sama dengan `?` di prompt
(27 entri, termasuk `!` untuk komentar). `show route help` juga muncul
sebagai opsi `help` di dalam `show route ?` itu sendiri, dan `show help`
muncul sebagai opsi `help` di dalam `show ?`. Perintah `help` bawaan
TIDAK diubah: ia hanya menampilkan ringkasan 9 baris (tentang `?` dan
hotkey), bukan daftar perintah, dan tidak butuh pager.

### Nama terlihat + auto-complete (Tab) — checkpoint, filter, community, protocol, neighbor

Nama entitas yang sudah ada bisa dilengkapi dengan Tab — tidak perlu
mengetik nama lengkap dari ingatan. Ketik awalan lalu tekan Tab: bila
hanya satu yang cocok, nama dilengkapi langsung; bila beberapa yang
cocok, Tab menampilkan daftar kandidatnya. Daftar dibaca saat runtime
(dinamis, bukan hardcode), jadi selalu sinkron dengan keadaan saat ini.
Bila nama yang diketik tidak dikenal, perintah ditolak lantang (rc 33)
dengan menyebutkan nama yang tersedia — tanpa mengubah apa pun.

```
rollback 2026-          # Tab -> rollback 2026-11-20 (lengkap bila satu)
rollback                # Tab -> daftar/lengkap checkpoint yang ada
checkpoint delete       # Tab -> daftar/lengkap checkpoint yang ada
checkpoint list         # daftar checkpoint (nama + tanggal + penanda *)
```

Entitas yang dilengkapi Tab (pola yang sama untuk semua):

- Checkpoint: `rollback <nama>`, `checkpoint delete <nama>` — daftar
  dari dir checkpoints (`.last-save` disembunyikan).
- Filter BGP: `import filter`, `export filter`, `filter` — sudah ada
  sebelumnya (dari kerja filter-name); pola yang sama.
- Community list: `community list delete <nama>` — daftar dari
  `define` di `bird.d/filter.conf`. Nilai community: `community export
  delete <community>`, `community import delete <community>` — daftar
  dari community yang sedang dipakai (export `bgp_community.add(...)`
  + import `bgp_*_community`), dalam bentuk CLI (`64512:300`,
  `no-export`, `no-advertise`, `no-peer`, `blackhole`, `rt:AA:NN`,
  `large:AA:X:NN`).
- Protocol-name BGP: `protocol-name <Nama>` — daftar dari nama
  protocol yang sudah dipakai di intent `bgp.conf` (hanya kemudahan
  reuse; nama baru tetap bebas dibuat).
- Neighbor BGP: `neighbor <IP>`, `no neighbor <IP>` — daftar dari
  neighbor yang ada di intent `bgp.conf`.
- Interface: sudah ada sebelumnya (`Get_if_*`).

Yang sengaja TIDAK dilengkapi Tab (nama BARU yang diciptakan user,
completion tidak bermakna): `checkpoint save`, `community list add`
(nama), `community export/import add` (nilai), definisi `filter` baru.

Batas yang diketahui: `?` hanya menampilkan struktur statis perintah
(nama PARAM + pola), TIDAK menampilkan daftar nama dinamis. Daftar
dinamis hanya muncul lewat Tab (dan lewat perintah list, mis.
`checkpoint list`). Ini keterbatasan klish 2.2.5 — `?` dirender line
editor dari XML statis tanpa menjalankan perintah completion — sama
seperti `?` yang tidak bisa dipager di atas.

`show startup-config` membaca file startup-config yang sebenarnya
(`/etc/titian/startup-config`); bila file belum ada, tampil pesan kosong,
bukan error. `show running-config` membaca dump running-config; bila
dump belum ada, file dibuat dulu.

### 1.9 Tanggal dan zona waktu (show date)

```
show date                      # tanggal/waktu lokal + zona waktu + UTC
```

Output `show date` menampilkan waktu lokal (mengikuti zona waktu
sistem), nama zona, dan waktu UTC sebagai pembanding. Zona waktu
diatur lewat mode configure:

```
configure terminal
system time-zone Asia/Jakarta  # WIB (UTC+7); pilihan lain: Asia/Makassar (WITA), UTC
end
save
```

Zona waktu tersimpan sebagai baris `system time-zone ...` di
startup-config (di-replay saat boot) dan diterapkan langsung ke
`/etc/localtime`. Bila zona belum pernah diatur, `show date` menampilkan
petunjuk pengaturannya (bukan menebak).

### 1.10 Profile paket — pembatasan bandwidth per pelanggan (traffic-shape)

*Profile paket* adalah template pembatasan bandwidth untuk satu paket
layanan (mis. 10M, 100M): kecepatan *download* + *upload* dan *burst*
masing-masing arah. Satu profile bisa dipakai banyak pelanggan lewat
*bind*: ke satu interface/VLAN utuh, atau ke satu IP/CIDR di satu
interface. Setiap *bind* otomatis membuat 2 *pipe* + 2 *rule* turunan
di dummynet (lihat §9e).

```
configure terminal
traffic-shape
enable
profile paket10
download 10Mbit/s
download-burst 1000000
upload 10Mbit/s
upload-burst 1000000
bind interface vlan100
end
configure terminal
commit
save
```

Format *rate*: bilangan bulat + satuan, mis. `10Mbit/s`, `512Kbit/s`,
`1Gbit/s`. Nama profile: maks 12 karakter, `[A-Za-z0-9_-]`, karakter
pertama huruf/angka.

Catatan: *burst* dummynet BUKAN *burst-rate* berkelanjutan ala
MikroTik. *Burst* adalah jatah BYTE sesudah *idle* — efektif
`MAX(burst, bw × idle_time)`. Contoh: 10M + `burst 1000000` = sesudah
*idle*, sampai 1.000.000 byte (≈1 MB) lolos secepat link fisik, lalu
kembali ke 10 Mbit/s. Jangan tawarkan *burst* sebagai kecepatan
berkelanjutan — itu bukan semantiknya.

Verifikasi:

```
show traffic-shape profile paket10   # profile + bind + pipe/rule turunan
show traffic-shape profile           # semua profile
show traffic-shape                   # konfigurasi traffic-shape
show traffic-shape statistics        # counter pipe/sched/queue kernel (ipfw)
```

Catatan: perubahan profile/*bind* langsung tertulis ke
`/usr/local/etc/traffic-shape.conf`, tapi *pipe* baru masuk kernel
saat `commit` (service *traffic-shape* di-*restart* bila config
kotor), saat boot, atau lewat *apply* eksplisit dari shell
(`/opt/titian/sbin/titian-traffic-shape.sh apply`). Tanpa itu, `show`
sudah menampilkan profile-nya tapi kernel belum membatasi apa pun.
Detail lengkap + arah *download*/*upload* per jenis *bind*: §9e.

Bukti ukur (21 Nov 2026): profile `paket8` → 8,001 Mbit/s (target 8);
profile `paket14` → 14,004 Mbit/s (target 14). Diukur dari *counter*
*pipe* dummynet dengan *UDP flood* — bukan iperf3 *end-to-end*
(MikroTik tidak menjalankan iperf3).

Notes: konfigurasi profile 100M di `vlan100` lolos di *mock* saja;
uji *throughput* live 100 Mbps via `vlan100` BELUM terukur
(keterbatasan mesin, diterima 22 Nov 2026).

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

`ip address` bersifat additive: satu interface boleh memegang banyak alamat
IPv4 sekaligus, tanpa batas jumlah — tiap perintah menambah satu alamat
(alias), tidak menggantikan yang sudah ada. Hapus satu per satu dengan
`no ip address <alamat-CIDR>`; interface-nya sendiri dihapus dengan
`no interface <tipe> <nama>`.

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

### Multi-VXLAN (10 segmen, terbukti 17 Nov 2026)

Pola di atas diskalakan ke 10 VXLAN sekaligus: `vxlan101`–`vxlan110`
(VNI 101–110) + `vlan101`–`vlan110` (VID 101–110, parent `ge3`) +
`bridge101`–`bridge110` (member `vxlan10x` + `vlan10x`, IP
`10.99.101.1`–`10.99.110.1/24`), VTEP lokal `10.10.2.3` ↔ remote
`192.168.91.32` (RB3011, VNI sama, IP `10.99.101.2`–`10.99.110.2/24`
langsung di interface vxlan — tanpa bridge di sisi RB3011, dan ARP
statis `10.99.10x.1` → MAC `bridge10x`). Ping overlay 10/10 dua arah
0% loss; `tcpdump -i vxlan10x` membuktikan trafik lewat segmennya
sendiri (FDB bridge10x mempelajari MAC vxlan RB3011). Catatan: RB3011
me-redistribute connected via BGP, jadi `10.99.101–110.0/24` juga
muncul di tabel BIRD via `10.99.40.2` — tetapi FIB kernel memakai route
connected (`bridge10x`), jadi tidak membayangi. Jangan pakai
`import all` ke peer yang me-redistribute connected: prefix underlay
(mis. `192.168.91.0/24`, jaringan VTEP) yang keimpor lewat tunnel
membuat loop VXLAN (pernah terjadi saat build 10 peer BGP, 17 Nov
2026) — pakai `import filter F-RB3011-IN`.

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
BFD-over-BGP di atas jalur data TERBUKTI gagal
(RB3011 tidak pernah membuat sesi BFD — deadlock BGP↔BFD, F3.4).
BFD-over-OSPF TERVERIFIKASI live 17 Nov 2026 (B26): sesi Up dua arah
(300 ms × 3, hold 900 ms); sisi RB3011 perlu `use-bfd=yes`
di interface-template OSPF (default kosong = BFD diam).
Multihop-BGP sudah diverifikasi di lab.

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

### 8.6 ipfw — allow SSH + ping WAJIB sebelum main firewall

Traffic-shape memakai **ipfw + dummynet**. ipfw punya aturan default 65535:

```
65535 deny ip from any to any
```

Saat ipfw aktif tanpa aturan allow, **semua trafik ditolak** — termasuk SSH
dan ping (ge0 dapat IP via `dhclient` tapi ping RTO, 13 Nov 2026). Karena
itu, pasang dulu aturan allow SSH + ping **sebelum** mengaktifkan ipfw atau
main firewall:

```sh
ipfw add 100 allow tcp from any to any 22
ipfw add 110 allow tcp from any 22 to any
ipfw add 120 allow icmp from any to any
```

| Aturan | Fungsi |
|---|---|
| 100 | SSH masuk (TCP tujuan port 22) |
| 110 | SSH keluar / balasan (TCP sumber port 22) |
| 120 | Ping / ICMP (dua arah) |

Verifikasi: `ipfw show` (ketiga aturan ada) + `sysctl net.inet.ip.fw.enable`
(1 = aktif, 0 = nonaktif). Darurat bila terkunci:

```sh
ipfw add 65535 allow ip from any to any   # ubah default deny → allow
service ipfw stop                          # atau matikan ipfw sekalian
```

Catatan: aturan ipfw **tidak persisten** (hilang saat reboot) — pasang ulang
saat boot bila perlu. Aturan ini hanya melindungi SSH + ping; saat ipfw aktif
dengan default deny, trafik lain (BGP TCP 179, VXLAN UDP 4789, DNS, dst.)
tetap ditolak kecuali ada aturan allow-nya. Firewall fitur Titian (§8.1–8.5)
memakai **pf**, bukan ipfw — ipfw di sini hanya pengaman akses.

### 8.7 protect-interface — guard anti-lockout + migrasi

`protect-interface` melindungi interface mgmt dari rule firewall (rule tidak
boleh memakai interface itu sebagai in/out). Default: **`ge0`** (mgmt sejak
rename 12 Nov).

**Migrasi config live TIDAK otomatis.** Setelah deploy script baru (default
ge0), config lama di `/usr/local/etc/firewall.conf` masih `protected em0`.
Migrasikan dengan urutan ini:

```
protect-interface ge0       # tambah DULU
no protect-interface em0    # baru hapus (hapus butuh minimal 2 entri)
commit
save
```

Dengan ge0 terproteksi, filter di ge0 akan **ditolak** saat add — itu guard
yang bekerja. Tes firewall di ge0 harus pakai interface non-mgmt, atau
sengaja unprotect ge0 dulu dengan risiko sendiri.

**Insiden 13 Nov 2026 (SUDAH TERBUKTI):** commit firewall (`filter input
deny dport 18081 + enable`) menggantung lalu SSH putus total sejak ~17:55
WIB — **lockout pf** (uptime mesin 6 jam membuktikan bukan crash). Akses
pulih 22:54 setelah `pfctl -d` di konsol. **Dibersihkan 14 Nov 00:04:**
rule deny 18081 dihapus, `enable` dimatikan, protected `em0` → `ge0`
(via klish + commit + save; terverifikasi `show firewall` = no rules,
protected ge0, pf not running). Jangan ulangi commit firewall sebelum guard
ge0 terpasang + filter diuji di interface non-mgmt.

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

`factory-reset confirm` otomatis membuat titik pra-reset bernama tanggal
WIB (`YYYY-MM-DD`, mis. `2026-11-19`) sebelum menghapus config — titik
ini DIPERTAHANKAN saat wipe (titik lain ikut terhapus) dan bisa dimuat
kembali dengan `rollback <tanggal>` (lihat §9.4).

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

### 9.4 Factory reset — mulai dari awal

```
factory-reset          # HANYA menampilkan ringkasan + konfirmasi (tidak menghapus apa pun)
factory-reset confirm  # EKSEKUSI: backup otomatis, hapus semua konfigurasi, pulihkan default, restart service
```

**Perintah ini di mode exec (enable-view), BUKAN di `configure terminal`.**
Jalankan dari prompt `cli-...#`, bukan dari `(config)#`.

`factory-reset` menghapus SEMUA konfigurasi Titian dan mengembalikan
default pabrik (kosong). Perintah ini IREVERSIBEL dan memakai dua langkah
(mengikuti pola birdc `down` / `graceful-restart`): langkah pertama
HANYA menampilkan ringkasan — tanpa `factory-reset confirm`, TIDAK ADA
yang dihapus.

Ringkasan `factory-reset` ditampilkan lewat pager `less` (seperti
`show`) bila output ke terminal interaktif — `SPACE` = halaman
berikut, `q` = keluar (lihat §1.8). Bila output di-pipe/di-script
(bukan TTY) atau `terminal length 0`, ringkasan tercurah langsung
tanpa pager. `factory-reset confirm` sengaja TIDAK dipager supaya
progresnya (backup, hapus, restart) terlihat live.

`factory-reset confirm` juga menghancurkan interface live buatan
Titian (Temuan 3): vlan, vxlan, bridge, lagg, cloned loopback lo1..,
dan IP di interface fisik non-mgmt — sesudah birdc configure (route
BIRD sudah dicabut) dan sebelum restart service. Yang dipertahankan:
interface mgmt (dari default route, fallback ge0) + lo0 + default
route, supaya SSH tidak putus. TIDAK disentuh confirm (tindak lanjut
terpisah): rule pf live (inert sesudah interface hilang), nilai
sysctl live, daemon mpd5, dan route kernel yang ditambah manual di
luar BIRD.

Sebelum menghapus apa pun, `confirm` membuat **checkpoint pra-reset**
(Temuan 4): titik bernama tanggal WIB (`YYYY-MM-DD`, mis.
`2026-11-19`) yang berisi config sebelum reset dan **DIPERTAHANKAN**
saat wipe (titik checkpoint lain ikut terhapus). Muat kembali dengan
`rollback <tanggal>` (lihat §9.1–§9.2); daftar titik di `checkpoint
list`. Bila nama tanggal sudah ada, dipakai `YYYY-MM-DD-HHMM` (lalu
`YYYY-MM-DD-HHMMSS`). Bila pembuatan checkpoint gagal, confirm tetap
jalan (peringatan lantang) — backup tarball otomatis tetap menjadi
jaring pengaman utama.

Yang dihapus (bila ada): `startup-config`, intent `*.conf`, `netstate/`,
`bird.d/`, `bird-backup/`, `checkpoints/` (termasuk `.last-save`;
KECUALI titik pra-reset yang baru dibuat — lihat di bawah),
`sysctl.titian(.prev)`, `frr.conf` (intent lama + snapshot), `bird.conf`
(live + `/etc/local` + `/cfg/local` — dipulihkan dari `*.sample` bila
ada, bila tidak ada sample: dihapus), `frr.conf` live (idem), dan blok
`#-TITIAN-#` / `#-TITIAN-L2-#` / `#-TITIAN-RENAME-#` di `/etc/rc.conf` +
`/cfg/rc.conf` (isi lain rc.conf tidak disentuh).

Yang TIDAK PERNAH dihapus: binary + XML Titian (`/opt/titian`),
struktur direktori `/cfg` + `/etc`, `firewall.conf`, `rc.local`
(+hook newsyslog), `sshd_config`, password root, disk/partisi lain.
Perintah `write-memory` klish tetap dihapus (keputusan 18 Nov 2026)
dan TIDAK dihidupkan lagi oleh fitur ini.

Sebelum menghapus, `factory-reset confirm` membuat backup otomatis
(tarball di `/cfg`, `titian-factory-reset-bak-<WIB>.tgz`) — gagal
backup = batal, tidak ada yang dihapus. Sesudah menghapus, perintah
memulihkan default, menghentikan FRR, `birdc configure`, lalu me-restart
service titian (replay `startup-config` yang kini kosong → running-config
bersih). Verifikasi sesudahnya: `show startup-config` (harus kosong)
+ `show bird` + `bird.conf` sama dengan sample.

Memulihkan dari backup (lewat shell, bukan klish — belum ada perintah
klish `restore`): jalankan skrip langsung, lalu restart service:

```sh
sh /opt/titian/sbin/titian-factory-reset.sh restore <backup.tgz>
service titian restart
```

Tarball bisa dari backup otomatis (`/cfg/titian-factory-reset-bak-<WIB>.tgz`)
atau backup pra-uji mana pun. Restore bekerja dua fase: ekstrak semua
entri kecuali `usr/local/etc/*` langsung, lalu salin entri
`usr/local/etc/*` file-per-file mengikuti symlink
`/usr/local/etc -> /etc/local` (sehingga `frr.conf` live kembali dengan
mode 600 + owner `frr:frr`, dan `bird.conf` live tetap satu inode dengan
`/etc/local/bird.conf`). Verifikasi akhir: setiap entri file di backup
HARUS ada di tujuan — bila ada yang hilang, restore GAGAL lantang
(rc 33 + daftar yang hilang; symlink yang targetnya menggantung tetap
terhitung pulih bila symlink-nya kembali). Sesudah restore, verifikasi
anchor (startup-config, bird.conf, BGP). Restore yang butuh langkah
manual APA PUN sesudahnya = GAGAL.

**Peringatan — /cfg tabrakan label:** bila `/cfg` ter-mount dari disk
BERBEDA dengan root (dua disk punya partisi berlabel `cfg`), reset
menghapus konfigurasi disk LAIN itu. Langkah `factory-reset` menampilkan
peringatan keras bila perangkat `/cfg` dan root beda disk — baca
peringatan itu sebelum mengetik `confirm`. Untuk tes UFD yang
benar-benar bersih: disable/cabut disk internal sementara (atau relabel
`cfg` internal), baru boot UFD.

### 9.5 Titian update — cek + install rilis dari GitHub

```
update check           # READ-ONLY: rilis terbaru vs versi ter-install
update install         # HANYA menampilkan versi baru + ringkasan (tidak download/install)
update install confirm # EKSEKUSI: download -> verifikasi sha256 -> pkg add -f -> restart -> verifikasi
```

**Perintah ini di mode exec (enable-view), BUKAN di `configure terminal`.**
Jalankan dari prompt `cli-...#`, bukan dari `(config)#`.

`update check` membaca rilis terbaru repo `ashadebi/titian` di GitHub
Releases (API publik, tanpa auth) dan membandingkannya dengan versi
ter-install (`pkg info titian`). Laporan: UPDATE TERSEDIA / SUDAH
TERBARU / TIDAK DAPAT DIHUBUNGI. Perintah ini read-only — tidak
mengubah apa pun.

`update install` hanya menampilkan rencana (versi baru, ukuran asset,
sumber checksum, alur eksekusi). `update install confirm` yang
mengeksekusi: download `titian-bsdrp-<versi>.pkg` ke direktori temp,
verifikasi sha256-nya, install dengan `pkg add -f`, restart service
titian, lalu verifikasi config. Tanpa konfirmasi, TIDAK ADA yang
berubah.

Aturan keamanan update:

- Checksum sha256 file .pkg HARUS cocok dengan yang dipublikasikan
  rilis (body rilis atau asset `.pkg.sha256`). Bila tidak
  dipublikasikan / tidak cocok → GAGAL LANTANG, jangan install, versi
  lama tetap utuh.
- Install menolak bila sudah terbaru, bila titian belum ter-install
  via pkg, bila tag rilis tidak berpola `titian-bsdrp-<versi>`, atau
  bila ruang kosong di direktori temp tidak cukup (cek `df` dulu;
  ingat /var tmpfs 32M, .pkg ~2,6MB).
- File temp dihapus sesudah selesai (berhasil maupun gagal).
- Sesudah restart, verifikasi mengikat: startup-config vs /cfg,
  bird.conf md5 (harus SAMA dengan sebelum update — paket tidak
  memiliki config), jumlah BGP Established (harus kembali ke jumlah
  sebelum update). Gagal di langkah mana pun → gagal lantang.
- Konfigurasi di /cfg TIDAK PERNAH disentuh. TIDAK ADA cron
  auto-apply — cek + install hanya atas perintah.

Syarat proses rilis (agar `update` bisa jalan — lihat
UPDATE-LIVE-PLAN.md): tiap rilis WAJIB menaikkan PORTVERSION, tag
berpola `titian-bsdrp-<versi>`, asset bernama
`titian-bsdrp-<versi>.pkg`, dan mempublikasikan sha256 di body rilis
atau sebagai asset `.pkg.sha256`.

---

## 9a. IPoE — DHCP client & server

**Catatan penting:** mpd5 TIDAK mendukung IPoE. mpd5 adalah daemon PPP
(PPPoE/PPTP/L2TP). IPoE adalah IP polos di atas Ethernet, alias DHCP —
tanpa sesi PPP, tanpa username/password. Titian mengimplementasikan IPoE
via DHCP: `dhclient` (client) dan `isc-dhcpd` (server), keduanya sudah
ada di image.

Dokumentasi layanan BRAS yang detail (PPPoE + IPoE + RADIUS sebagai
satu layanan akses subscriber — arsitektur, alur, bukti uji live,
operasional): lihat **§9d**.

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

### 9a.3 IPoE server + RADIUS MAC-auth

IPoE tidak punya username/password, jadi auth berbasis MAC (MAB — MAC
Authentication Bypass). isc-dhcpd TIDAK punya dukungan RADIUS native,
dan hook `on commit` + `execute()` TIDAK BISA mem-veto lease (lease
sudah ter-commit saat hook jalan). Mekanisme yang dipakai (native
isc-dhcpd): class `radius-allowed` + subclass per MAC yang lolos
RADIUS + pool `allow members of "radius-allowed";` + `deny
unknown-clients;`. RADIUS adalah otoritas: saat `commit`, tiap MAC
yang dideklarasikan diverifikasi ke RADIUS (PAP, User-Name = MAC,
User-Password = MAC); hanya yang Accept yang masuk allowlist. MAC yang
Reject / tidak terverifikasi (RADIUS tak terjangkau) DIKELUARKAN +
warning (fail-closed). Bila mac-auth aktif tapi NOL MAC lolos, generate
GAGAL lantang (rc 33) dan config lama dipertahankan.

```
configure terminal
ipoe-server
radius-server 103.50.129.84
radius-secret <secret>
radius-mac 02:00:00:00:00:01
radius-mac-auth
enable
end
configure terminal
commit
save
```

Matikan RADIUS MAC-auth (kembali DHCP terbuka):

```
configure terminal
ipoe-server
no radius-mac-auth
no radius-server
no radius-secret
no radius-mac 02:00:00:00:00:01
end
configure terminal
commit
save
```

Catatan:
- `radius-server` / `radius-secret` mengikuti pola PPPoE (lihat
  §9d.2). Secret disimpan di `/etc/titian/ipoe.conf` (mode 600)
  DAN ikut tersimpan di startup-config via `<CONFIG/>` + `save`
  (koreksi 19 Nov 2026 — lihat §9d.4). Baris perintah klish
  `radius-secret` di-echo oleh klish — jangan tampilkan nilainya
  di log/laporan.
- Auth per-request real-time (cek RADIUS tiap DHCPDISCOVER) TIDAK
  dimungkinkan isc-dhcpd. Arsitektur yang benar untuk itu adalah
  FreeRADIUS `rlm_dhcp` (FreeRADIUS sebagai DHCP server) — butuh paket
  baru + keputusan arsitektur (FreeRADIUS tidak bisa di-install di mesin
  test, repo pkg 404).
- Verifikasi RADIUS dilakukan saat generate/commit, bukan per-request.
  MAC yang dicabut dari RADIUS sesudah commit tetap dapat lease sampai
  commit berikutnya (regenerasi allowlist).
- Uji klien DHCP (DORA) end-to-end BELUM terbukti live (broadcast
  same-machine tidak sampai ke dhcpd — keterbatasan platform, bukan
  RADIUS). Detail + bukti: §9d.3.

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
| `protocol-name <NAMA>` | Nama protocol BIRD custom (default `bgp_<IP>`; contoh `protocol-name bgp_AS1194`) |

Nama filter di `import filter` / `export filter` dilengkapi otomatis
dengan TAB (sumber: filter yang sudah dibuat; ketik `import filter
<TAB>` untuk melihat daftar). Merujuk filter yang belum ada gagal
dengan pesan jelas saat perintah dijalankan — buat dulu filternya.
`protocol-name` harus identifier BIRD (`[A-Za-z_][A-Za-z0-9_]*`,
tidak diawali angka) dan tidak boleh bentrok dengan nama protocol lain
(neighbor lain — termasuk nama default `bgp_<IP>` mereka, template,
atau protocol lain); `no protocol-name` kembali ke default `bgp_<IP>`.

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
| `accept <prefix>` | Terima prefix ini — boleh pola `{low,high}`, mis. `accept 103.50.128.0/22{22,24}` |
| `reject <prefix>` | Tolak prefix ini — boleh pola `{low,high}` |
| `accept community <AS:NN>` | Terima route dengan community ini |
| `reject community <AS:NN>` | Tolak route dengan community ini |

Filter selalu diakhiri `reject;` (default-deny). Nama filter boleh
mengandung `-` di CLI, tapi di-generate menjadi `_` di bird.conf
(BIRD menolak `-` di nama identifier).

Pola `{low,high}` membatasi panjang prefix yang cocok (mis.
`103.50.128.0/22{22,24}` = prefix /22 sampai /24 di dalam
103.50.128.0/22). Suffix `+` (prefix ini dan yang lebih spesifik) dan
`-` (hanya prefix ini) juga didukung. `accept prefix-pattern <pola>`
adalah alias lama untuk bentuk yang sama. Nama filter di view ini juga
dilengkapi otomatis dengan TAB (`filter <TAB>`).

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

**RPKI `lab` sesudah reboot (perbaikan 20 Nov 2026):** BIRD naik sebelum
default route ada (dhclient jalan belakangan di rc.local), sehingga
protokol RPKI `lab` (remote 10.1.1.62:3323) sempat macet `Connecting`
(18 Nov: 11 Established, lab Connecting 10+ mnt). Kini `titian-boot.sh`
meluncurkan penunggu latar saat boot: tunggu default route muncul
(maks ~120 dtk), lalu `birdc restart lab` bila `lab` belum
`Established` (log: `/var/log/titian-rpki-boot.log`). Terbukti di uji
reboot 20 Nov 2026: penunggu me-restart `lab`, `lab` Established
(~1 mnt pasca-boot), BGP tetap 12 Established.

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

### 9b.7 TCP MD5 authentication (RFC 2385) — hanya untuk testing lab

> **DITUTUP B25 (17 Nov 2026) — MD5 BGP TERBUKTI TIDAK BERFUNGSI di platform ini.**
> Keempat varian uji live (password saja; `authentication md5;` eksplisit;
> `setkey on`; `setkey off`) SEMUA gagal `connect()` ENOENT — lihat §9b.8.
> Prosedur di bawah ini dipertahankan sebagai ARSIP REPRODUKSI (cara memasang
> + mencabut MD5 + cara memverifikasi digest), BUKAN untuk mengaktifkan MD5
> di lab. JANGAN pasang MD5 di sesi BGP lab ini.

> **Catatan:** password BGP MD5 di sini HANYA untuk testing lab.
> Bukan kredensial produksi. Password test yang dipakai di lab
> dicatat di `HASIL.md` (tindak lanjut FASE 3) — bukan di panduan
> ini — karena panduan ini prosedur umum, passwordnya spesifik
> per sesi test.

TCP MD5 menandatangani setiap segmen TCP sesi BGP dengan kunci
rahasia bersama (shared secret). Kedua sisi HARUS memakai password
yang SAMA persis — satu karakter beda saja = sesi GAGAL total
(tidak ada fallback ke tanpa-MD5).

**Syarat mutlak:** password IDENTIK di BSDRP dan di RB3011.
Bila hanya satu sisi yang dipasang MD5, sesi TIDAK PERNAH
Established — sisi tanpa MD5 menolak SYN yang ditandatangani MD5,
sisi dengan MD5 menolak SYN tanpa tanda tangan. Gejalanya di
`show protocol`: sesi mentok `Active` / `Connect` dengan
`Socket: Connection closed` atau `Connection refused`, dan di
`tcpdump` terlihat SYN berulang (retransmit) tanpa SYN-ACK.
Itu BUKAN masalah link — itu MD5 tidak cocok / hanya satu sisi.

**1. Generate password (host-side, di mesin BSDRP)**

Password acak kuat, 20 karakter alfanumerik (tanpa spasi — klish
menolak spasi). Generate di mesin, JANGAN tulis di chat:

```
PW=$(LC_ALL=C tr -dc "A-Za-z0-9" < /dev/urandom | head -c 20)
echo "$PW" > /tmp/bgpmd5-test-pw.txt; chmod 600 /tmp/bgpmd5-test-pw.txt
```

(`LC_ALL=C` wajib — `tr` FreeBSD tanpa itu gagal
`Illegal byte sequence` pada byte acak. Cek panjang = 20
sebelum dipakai.)

**2. Sisi BSDRP (klish) — pasang password ke neighbor**

Perintah klish ada di view `neighbor` (`password <teks>`),
atau via backend `titian-bgp.sh`:

```
configure terminal
router bird
neighbor 10.99.40.2
password <PASSWORD-TEST>
exit
end
configure terminal
commit
save
```

Atau via backend (hasil sama — intent yang ditulis identik):

```
/opt/titian/sbin/titian-bgp.sh neighbor-set 10.99.40.2 password <PASSWORD-TEST>
/opt/titian/sbin/titian-bgp.sh generate
```

Hasil di bird.conf (section `bgp_10_99_40_2`):

```
protocol bgp bgp_10_99_40_2 {
    ...
    neighbor 10.99.40.2 as 65001;
    password "<PASSWORD-TEST>";
    ...
}
```

**3. Sisi RB3011 (RouterOS 7) — pasang kunci yang SAMA**

Password dibaca dari file di mesin BSDRP (jangan ketik ulang
manual — rawan typo satu karakter = sesi gagal):

```
PW=$(cat /tmp/bgpmd5-test-pw.txt)
ssh -i /root/.ssh/rb3011_key agoes@192.168.91.32 \
  "/routing/bgp/connection/set [find name=bgp-bsdRP] tcp-md5-key=$PW"
```

Atau langsung di terminal RB3011:

```
/routing/bgp/connection/set [find name=bgp-bsdRP] tcp-md5-key=<PASSWORD-TEST>
```

Gotcha RouterOS 7.25.1:

- `tcp-md5-key` adalah properti **connection**, BUKAN template.
  Set di template DITOLAK: `bad parameter tcp-md5-key`.
- `print` (termasuk `print detail`) TIDAK menampilkan
  `tcp-md5-key` — RouterOS menyembunyikan nilai kunci.
  Tidak tampil di print BUKAN berarti tidak terpasang.
  `set` yang sukses (exit 0, tanpa error) = terpasang.
  Verifikasi nyata = sesi Established + digest MD5 valid
  (lihat § verifikasi di bawah).

**4. Verifikasi — sesi kembali Established dengan MD5 aktif**

Sesi akan drop saat MD5 dipasang di satu sisi, lalu
re-Established sesudah kedua sisi sama. Tunggu sampai
`show protocol` menunjukkan `Established` (di link lossy
bisa beberapa menit — retransmit TCP butuh jendela loss
rendah; itu masalah link, bukan MD5):

```
show protocol bgp           # harus Established
birdc show route protocol bgp_10_99_40_2
```

Bukti MD5 aktif (dari mesin BSDRP) — tangkap SYN port 179,
cek opsi MD5 pada paket:

```
tcpdump -n -v -i bridge0 "tcp port 179 and tcp[tcpflags] & tcp-syn != 0"
```

SYN dari peer yang memakai MD5 menampilkan
`options [..., md5 ..., mss ...]`. Untuk memverifikasi
digest-nya cocok dengan password yang dipakai, beri password
ke tcpdump lewat `-M`:

```
PW=$(cat /tmp/bgpmd5-test-pw.txt)
tcpdump -n -v -M "$PW" -i bridge0 "tcp port 179 and tcp[tcpflags] & tcp-syn != 0"
```

Hasil yang benar: `options [nop,nop,md5 valid,mss ...]`.
`md5 valid` = digest cocok = kedua sisi memakai password
yang sama. Bila digest salah, tcpdump melaporkan MD5 gagal —
artinya password kedua sisi TIDAK sama, samakan ulang.

**5. Mencabut MD5 (kembali tanpa password)**

```
configure terminal
router bird
neighbor 10.99.40.2
no password
exit
end
configure terminal
commit
save
```

Dan di RB3011:

```
/routing/bgp/connection/set [find name=bgp-bsdRP] tcp-md5-key=""
```

Cabut di KEDUA sisi — bila hanya satu sisi dicabut, sesi
gagal dengan gejala yang sama seperti di atas (satu sisi
ber-MD5, satu tidak).

---

### 9b.8 PERINGATAN — TCP MD5 memecahkan connect() BIRD di platform ini (ditemukan 16 Nov 2026; TERBUKTI B25, 17 Nov 2026)

Pada BIRD 2.20.0 + FreeBSD 16.0-CURRENT, mengaktifkan TCP MD5 pada sesi BGP memecahkan `connect()` dengan `Socket error: connect: No such file or directory` (ENOENT) — sesi mentok `Active`, tidak pernah Established, dan restart daemon TIDAK memperbaiki. Ini BUKAN password tidak cocok: `tcpdump -M` membuktikan digest cocok di kedua sisi, dan SYN ber-MD5 dari RB3011 dibuang diam-diam tanpa SYN-ACK/RST (socket listen BIRD tidak menerapkan kunci MD5).

**Hasil B25 (17 Nov 2026, laporan `BIRD-B25-REPORT.md`):** keempat varian uji live SEMUA gagal ENOENT secara deterministik, dengan kunci uji sekali pakai yang sama di kedua sisi (digest `tcpdump -M` = "md5 valid"):

1. **Password saja** (emit Titian hari ini) — Active + ENOENT (reproduksi insiden 16 Nov).
2. **`authentication md5;` eksplisit + password** — Active + ENOENT, bahkan sesudah `birdc restart` protokol (socket baru). Hipotesis "opsi auth eksplisit yang kurang" TERBUKTI SALAH.
3. **Password + `setkey on`** (jalur SADB kernel) — Active + ENOENT. SA `tcp-md5` TERPASANG di SADB (`setkey -D`, state=mature) — jalurnya jalan, koneksinya tetap gagal.
4. **Password + `setkey off`** (jalur setsockopt `TCP_MD5SIG`) — Active + ENOENT. SADB kosong; `setsockopt TCP_MD5SIG` diterima kernel — jalurnya jalan, koneksinya tetap gagal.

Kontrol: MD5 OFF di kedua sisi → Established <1 menit, stabil. Kernel mendukung `TCP_MD5SIG` (setsockopt OK) dan punya kode MD5 (`tcpmd5`); yang rusak adalah penanganan soket MD5 BIRD 2.20.0 di platform ini (BIRD tidak pernah mengirim SYN saat MD5 aktif; `connect()` gagal sebelum paket keluar).

**Status:** MD5 **DIMATIKAN** di lab (kedua sisi), BGP jalan tanpa MD5 di link lab privat ini. **JANGAN pasang MD5 lagi di sesi BGP lab ini.** Bila MD5 dibutuhkan di masa depan, jalurnya: upgrade BIRD (hipotesis, BELUM teruji — tidak ada BIRD lebih baru di image ini) atau platform lain — itu keputusan desain tersendiri, bukan perbaikan emit Titian (tidak ada varian emit yang memperbaiki).

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
| Masuk CLI native (vtysh) | — | Ya — `vtysh` di view `router frr` (§9c.2) |
| Show status/versi | Ya (`show bird`, `show route`) | Ya (`show frr`, `show frr version`, `show frr bgp summary`, `show frr ospf neighbor`) |

Konfigurasi routing protocol FRR (BGP neighbor, route-map,
prefix-list, community, local-pref, MED, AS-path prepend) dilakukan
**langsung di `vtysh`** (§9c.2), bukan lewat klish. Model native FRR:
config via vtysh berlaku langsung (running) + `write memory` agar
persisten ke `/usr/local/etc/frr/frr.conf`. Daemon FRR sendiri
mendukung semua fitur itu (route-map, prefix-list, community
standard/large, local-pref, MED, prepend) — hanya saja jalurnya
vtysh, bukan klish.

> **Perubahan desain 17 Nov 2026 (keputusan user):** perintah klish
> FRR untuk config (`router-id`, `log syslog`, `write-memory`,
> `router bgp`, `router ospf`, `route-map`, `ip prefix-list`,
> `ip community-list`) **DIHAPUS**. Program coverage klish penuh
> untuk FRR dibatalkan; semua config kini lewat handoff `vtysh`.
> Catatan migrasi ada di §9c.7. File intent lama `/etc/titian/frr.conf`
> tidak dipakai lagi dan tidak boleh dipasang sebagai `frr.conf` live.

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

### 9c.2 Masuk vtysh dari klish (handoff)

```
configure terminal
router frr
vtysh
! ... kini di CLI native FRR (prompt vtysh) — konfigurasi seperti biasa ...
exit
! kembali ke klish (config-frr); running-config otomatis disinkronkan ke /cfg
exit
end
```

| Hal | Arti |
|---|---|
| `vtysh` di view `router frr` | Masuk CLI native FRR sebagai child klish — `exit` di vtysh kembali ke klish |
| Syarat | FRR harus sudah jalan (`router frr enable` + `commit`); perintah ini butuh sesi interaktif (TTY) — dari pipe/skrip gagal LOUD (rc=33), bukan hang diam-diam |
| Sesudah keluar | Wrapper menjalankan `write memory` lalu menyalin frr.conf live ke `/cfg/titian/frr.conf` (best-effort, §9c.6) |
| `save` | Juga menjalankan sinkronisasi yang sama (hook di `titian-cfg.sh`) |

Di luar klish, perintah shell BSDRP `cli` tetap masuk ke vtysh
seperti dulu. Nama perintah klish-nya `vtysh`, bukan `cli` — `cli`
sudah dipakai perintah socket CLI BIRD di klish (conf-bgp.xml),
sehingga `cli` di dalam klish akan ambigu.

### 9c.3 Show

```
show frr
show frr version
show frr bgp summary
show frr ospf neighbor
show ip bgp
show ip bgp summary
show ip ospf
show ip ospf neighbor
show frr route
```

`show frr` menampilkan versi, intent enable, `frr_enable` di
rc.conf, status service, dan pid `zebra` bila jalan. `show frr
version` menampilkan versi + output `vtysh show version`.
`show frr bgp summary` dan `show frr ospf neighbor` adalah
pasangan namespace-FRR dari `show ip bgp summary` dan `show ip
ospf neighbor` (passthrough `vtysh -c` yang sama). `show frr
route` menampilkan tabel route FRR/zebra (`vtysh show ip route`;
`show ip route` yang biasa adalah tabel kernel).

### 9c.4 BGP via vtysh — contoh (bukan klish)

Masuk ke vtysh lewat handoff §9c.2, lalu konfigurasi
BGP seperti biasa di FRR (contoh eBGP ke RB3011, AS 65001 — padanan
persis konfigurasi BIRD §9b.1):

> **Route-map WAJIB:** FRR 10.x menolak eBGP tanpa route-map in DAN
> out (log: `EBGP outbound policy not properly setup`; tanpa
> route-map, `show ip bgp summary` menampilkan PfxRcd/PfxSnt = 0,
> summary di RB3011 menampilkan `(Policy)`). Terbukti di tes 14 —
> session Established tapi 0 prefix sampai route-map dipasang.

```
! di vtysh (lewat handoff §9c.2)
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

BGP FRR **sengaja vtysh-only by design**: klish FRR hanya mengatur
enable/disable + handoff `vtysh` + show. Menambah perintah
route-map/policy penuh di klish tidak masuk akal — BGP FRR sendiri
sudah vtysh-only (lihat §9c.2) dan route-map adalah konfigurasi
sekali-pakai per-neighbor, bukan state yang perlu di-replay klish.
Pola kerja: niat enable di klish → `commit` → daemon naik →
konfigurasi BGP (neighbor + route-map) di vtysh → `write memory`
(atau keluar vtysh / `save` — sinkronisasi otomatis, §9c.6).

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

### 9c.5 Status uji (jujur) — diperbarui 17 Nov 2026

FRR **SUDAH jalan live** di mesin test (tes 14, 15 Nov 2026):
daemon naik via klish (`router frr enable` + `commit`), sub-command
router-id/log/write-memory LOLOS, mutual exclusion dua arah LOLOS,
BGP eBGP via FRR ke RB3011 **Established + tukar route dua arah**
(PfxRcd/PfxSnt = 2/2) sesudah route-map vtysh (§9c.4), lalu kembali
ke BIRD bersih + BGP re-Established. Detail: `~/workspace/titian-live-test-20261113/HASIL.md` (tes 14).

- CLI FRR (enable, router-id, log, write-memory, show) **ada** dan
  mutual exclusion vs BIRD **sudah diuji** (gagal rc=33 dua arah).
- Paket `frr10-10.7.1_1` ter-install di image, rc script `frr` ada.

**Temuan tes 14 yang sudah diperbaiki di repo (push ini):**
- `service frr stop` hanya mematikan watchfrr — kini stop path
  mematikan SEMUA daemon (watchfrr, zebra, bgpd, ospfd, ripd,
  staticd, mgmtd) dengan grace period lalu paksa bila perlu.
- Pesan commit menyesatkan diperbaiki (tidak lagi mencetak
  "bird disabled + stopped" saat enable FRR; `birdc configure`
  dilewati bila bird tidak jalan; label "BIRD unknown" diganti
  label versi yang benar).

**Desain baru 17 Nov 2026 — SUDAH diuji live (17 Nov 2026, 17:30–17:59 WIB, LOLOS):**
- Handoff `vtysh` (§9c.2), persistensi frr.conf ↔ /cfg + boot
  reconcile (§9c.6), depresiasi perintah config klish (§9c.7),
  dan batas waktu pemanggilan backend (`service frr start` 60 dtk,
  `vtysh -c` 30 dtk — anti-hang `router frr enable`+`commit`, lihat
  diagnosis di bawah) — deploy 5/5 md5 cocok, `router frr enable` +
  commit 8 detik TANPA hang (vs >4 menit 2× pada 16 Nov), masuk
  vtysh + `exit` kembali ke klish, BGP via FRR Established dua arah
  ke RB3011 (PfxRcd 21/23, as-path 65000×3, community 65000:100,
  MED 50), `show frr bgp summary` jalan, frr.conf live==/cfg
  `ff589198…` (native), reboot: FRR naik + BGP kembali, lalu kembali
  ke anchor BIRD + BGP 12 Established. Mock `FRR-HANDOFF-MOCK.sh`
  65 PASS/0 FAIL (staging) + bukti live di atas.
- Perintah `router-id` / `log syslog` / `write-memory` di klish
  SUDAH DIHAPUS (bukan sekadar tidak diuji) — padanannya kini
  perintah vtysh yang sama namanya di dalam sesi `vtysh` (§9c.7).

**Diagnosis hang `router frr enable`+`commit` (>4 menit, 2×, 16 Nov 2026):**
dari KODE, tiga pemanggilan tanpa batas di jalur commit — (1)
`service frr start` (menunggu daemon yang tidak naik, mis. karena
frr.conf live hilang/basi); (2) `vtysh -c "show running-config"` dan
`vtysh -f` di rekonsiliasi intent lama (menunggu mgmtd yang tidak
responsif — wait-loop readiness-nya berbatas 10 dtk, tapi
pemanggilan sesudahnya tidak); (3) `service frr onestop`/`stop` di
jalur disable. Fix staging: semua pemanggilan backend satu-tembak
kini lewat watchdog `run_bounded` (vtysh 30 dtk, service start 60
dtk, stop 30 dtk); sesi interaktif `vtysh` TIDAK PERNAH dibungkus
timeout. **Verifikasi live 17 Nov 2026: enable+commit FRR 8 detik, disable FRR 2 detik, enable BIRD 8 detik — hang tidak terulang di semua commit run ini (juga di run perbaikan sesudahnya, enable ~6–8 dtk).**

**Batasan yang masih berlaku:**
- BGP/OSPF FRR = vtysh-only (lihat §9c.4 — route-map in+out wajib).
- Quirk FreeBSD (§9c.4): `show ip route` FRR 9.x–10.1.1 tidak
  menampilkan default gateway & static route kernel (issue
  #17113) — di 10.7.1 kemungkinan sudah diperbaiki, **wajib
  verifikasi `show ip route` memuat route kernel** saat uji FRR
  berikutnya, bukan cuma route BGP.

**Perbaikan 5 temuan live test (17 Nov 2026, ~18:30–19:07 WIB, LOLOS live):**
(1) race boot frr.conf — `frr-boot-reconcile` me-restart FRR
sesudah restore (bila snapshot baru dipasang + zebra jalan);
terbukti di uji reboot: FRR naik dengan config LENGKAP tanpa
restart manual (BGP Established, frr.conf live==/cfg `ff589198…`);
(2) L2 tidak pulih saat boot — blok `#-TITIAN-L2-#`
(`cloned_interfaces` + ifconfig + member bridge) ditulis ke
`/etc/rc.conf` + `/cfg/rc.conf` tiap `save`/`restore` (`sync-rc-l2`);
terbukti di uji reboot: 33 clone iface + VXLAN 11 UP + ping
overlay 0% loss tanpa pemulihan manual; (3) replay berhenti
diam-diam di intent FRR lama — blok intent 19 baris dihapus dari
startup-config (anchor BARU isi-tanpa-stamp
`48bd81b083cf8b466783d9d86812aa6f`, 407 baris; bird.conf tetap
`bb21986089d77002e227315a216ea4be`); replay jalan penuh + `save`
aman; (4) checkpoint `.last-save/bird.conf` berisi default —
`mirror_bird_conf()` mencerminkan bird.conf hasil generate ke
`/cfg/local/bird.conf` + guard snapshot menolak bird.conf tanpa
marker `#-GLOBAL-#`; (5) daemon FRR yatim sesudah disable — daftar
stop kini 14 nama + sweep `/usr/local/lib/frr/*`; terbukti live:
`ps` FRR = 0 sesudah disable (run lalu 7 yatim). Mock sesudah
perbaikan: `FRR-HANDOFF-MOCK.sh` 72 PASS/0 FAIL,
`BOOT-PERSIST-MOCK.sh` (baru) 38 PASS/0 FAIL; `verify.py` NOL
error (2117 COMMAND).

**Referensi:**
- FreeBSD port `net/frr10`, rc script resmi: https://raw.githubusercontent.com/freebsd/freebsd-ports/main/net/frr10/files/frr.in
- BSDRP User Guide (pilih Bird atau FRRouting): https://bsdrp.net/documentation/end-users_docs
- Lab BSDRP (BGP/OSPF/RIP/ISIS/BABEL dengan FRR): https://bsdrp.net/documentation/examples/simple-bgp-rip-ospf-lab/
- Lab BSDRP (route-reflector + confederation Bird 3 + FRR 10): https://bsdrp.net/documentation/examples/bgp-route-reflector-and-confederation-using-frr-and-bird/
- Dok resmi FRR 10.0 (BGP): https://docs.frrouting.org/en/stable-10.0/bgp.html
- Dok resmi FRR 10.0 (route-map): https://docs.frrouting.org/en/stable-10.0/routemap.html
- Issue FRR #17113 (`show ip route` tidak tampilkan route kernel di FreeBSD): https://github.com/FRRouting/frr/issues/17113

### 9c.6 Persistensi frr.conf ↔ /cfg + boot

`/usr/local/etc/frr/frr.conf` hidup di RAM disk BSDRP (hilang saat
reboot) — dulu tidak pernah dipersistenkan (bug a: frr.conf hilang
pasca-reboot). Kini:

| Momen | Yang terjadi |
|---|---|
| Keluar `vtysh` (§9c.2) | `write memory` lalu salin frr.conf live → `/cfg/titian/frr.conf` (best-effort) |
| `save` | Hook yang sama via `titian-cfg.sh` (sinkron, sesudah dump startup-config mendarat) |
| Boot | `titian-cfg.sh restore` memasang snapshot `/cfg/titian/frr.conf` → lokasi live; **namun FRR sudah naik LEBIH DULU** (rcorder menempatkan `frr` sebelum `titian`) dengan config minimal dari RAM disk kosong — memasang file saja tidak membuat daemon memakai config itu. `frr-boot-reconcile` lalu **me-restart FRR** sesudah restore (hanya bila snapshot memang baru dipasang + zebra jalan) agar config yang dipulihkan benar-benar dipakai (Temuan 1, live test 17 Nov 2026 — klaim lama "restore SEBELUM FRR naik" SALAH pada rcorder saat ini). Bila FRR belum jalan saat boot, restart tidak perlu: `apply-all` nanti men-start-nya dengan file yang sudah dipulihkan. `frr-boot-reconcile` juga menyelaraskan `bird_enable`/`frr_enable` di rc.conf dari `routing.intent` + menghentikan daemon yang salah bila sempat naik (menutup bug b: boot restore BIRD meski intent FRR — akarnya: `sysrc` hanya menulis `/etc/rc.conf` tmpfs, sementara `/cfg/rc.conf` yang basi (`bird_enable=YES`) dipulihkan saat boot dan rc menaikkan BIRD; kini flag dicerminkan ke `/cfg/rc.conf` tiap commit + direkonsiliasi tiap boot) |

Aman diulang: `save`/boot dua kali = hasil sama (salinan dilewati
bila isi identik). Snapshot format intent klish lama (baris `bgp
...`/`route-map ...`, header "intent klish") **DITOLAK** saat
restore — itu bukan config FRR native; memasangnya akan membuat
daemon gagal parse. Snapshot begitu dibiarkan; `save` berikutnya
menimpanya dengan config native.

### 9c.7 Catatan migrasi — perintah klish lama → vtysh

Semua perintah di bawah DIHAPUS dari klish 17 Nov 2026. Padanan
vtysh-nya diketik di dalam sesi `vtysh` (§9c.2):

| Perintah klish lama (dihapus) | Padanan vtysh |
|---|---|
| `router frr` → `router-id <IP>` | `configure terminal` → `router-id <IP>` → `end` → `write memory` |
| `router frr` → `no router-id` | `configure terminal` → `no router-id` → `end` → `write memory` |
| `router frr` → `log syslog` / `no log syslog` | `configure terminal` → `log syslog` / `no log syslog` → `end` → `write memory` |
| `router frr` → `write-memory` | `write memory` (di vtysh) — atau keluar `vtysh` / `save` (sinkronisasi otomatis, §9c.6) |
| `router bgp <AS>` + `neighbor <IP>` + `remote-as` / `description` / `route-map` / `prefix-list` / `send-community` / `timers` + `network` | `configure terminal` → `router bgp <AS>` → `neighbor <IP> remote-as ...` dst. (contoh lengkap §9c.4) |
| `router ospf` + `network ... area ...` / `redistribute ...` | `configure terminal` → `router ospf` → `network ... area ...` / `redistribute ...` |
| `route-map <NAMA> <permit\|deny> <SEQ>` + `match ...` / `set ...` | `route-map <NAMA> <permit\|deny> <SEQ>` + `match ...` / `set ...` (contoh §9c.4) |
| `ip prefix-list ...` | `ip prefix-list ...` (contoh §9c.4) |
| `ip community-list standard <NAMA> <NILAI>` | `bgp community-list standard <NAMA> permit <NILAI>` (sintaks FRR 10.7.1; `ip community-list` ditolak daemon) |

Catatan: config yang dulu ditulis sebagai intent klish di
`/etc/titian/frr.conf` TIDAK dimigrasikan otomatis — file itu
tidak dipakai lagi. Konfigurasi ulang via `vtysh` sekali, lalu
`write memory` / keluar `vtysh` / `save` agar persisten (§9c.6).

---

## 9d. BRAS — Broadband Remote Access Server (PPPoE + IPoE + RADIUS)

BRAS adalah layanan akses subscriber Titian: satu layanan yang
menyatukan server PPPoE (mpd5), server IPoE (isc-dhcpd), dan
autentikasi RADIUS (FreeRADIUS — di lab ini myRadDASH host 84).
Subscriber tersambung lewat PPPoE atau IPoE; keduanya memakai RADIUS
yang sama sebagai otoritas autentikasi, dan keduanya memberi IP dari
pool yang dikelola Titian. Bab ini adalah dokumentasi layanan yang
detail — arsitektur, alur, bukti uji live, dan operasional. Perintah
per komponen yang ringkas ada di §9a.2 (IPoE server), §9a.3 (IPoE +
RADIUS), dan baris 14–15 tabel §14 (PPPoE).

### 9d.1 Gambaran — arsitektur dan alur subscriber

Komponen:

- **PPPoE server — mpd5 5.9.** Melayani sesi PPP lewat Ethernet
  (discovery → LCP → auth CHAP/PAP → IPCP). Memberi IP dari pool.
- **IPoE server — isc-dhcpd 4.4.3P1.** Melayani IP polos di atas
  Ethernet (DHCP DISCOVER → OFFER → REQUEST → ACK). Tanpa sesi PPP,
  tanpa username/password — auth berbasis MAC.
- **RADIUS — FreeRADIUS 3 (myRadDASH host 84, 103.50.129.84:1812).**
  Otoritas autentikasi untuk PPPoE (username/password) dan IPoE
  (MAC). Basis data: MariaDB (`radcheck`, `nas`, `clients`).
- **Pool IP.** PPPoE: 10.99.42.100–110 (pool1), server 10.254.254.1.
  IPoE: 10.99.50.100–110 (subnet 10.99.50.0/24, gateway 10.99.50.1,
  DNS 8.8.8.8).

Alur subscriber PPPoE:

1. Klien kirim PADI (discovery) → server jawab PADO → PADR → PADS
   (sesi terbentuk).
2. LCP negosiasi → auth CHAP (atau PAP).
3. mpd5 kirim Access-Request ke RADIUS (bila RADIUS aktif) atau cek
   user lokal (bila tidak).
4. RADIUS jawab Access-Accept (atau Reject). Bila Accept → IPCP
   memberi IP dari pool → sesi UP. Bila Reject → sesi gagal, klien
   TIDAK dapat IP.
5. Bila RADIUS aktif, RADIUS adalah otoritas — bukan fallback lokal.

Alur subscriber IPoE:

1. Klien kirim DHCPDISCOVER (broadcast) → server jawab OFFER →
   REQUEST → ACK (DORA).
2. Server TIDAK mengecek RADIUS per-request. Sebaliknya, saat
   `commit`, tiap MAC yang dideklarasikan di klish diverifikasi ke
   RADIUS (PAP, User-Name = MAC, User-Password = MAC). MAC yang
   lolos masuk allowlist (`radius-allowed`); MAC yang ditolak
   dikeluarkan.
3. dhcpd hanya menawarkan IP ke MAC di allowlist (pool
   `allow members of "radius-allowed"` + `deny unknown-clients`).
   MAC di luar allowlist tidak mendapat OFFER.
4. MAC yang dicabut dari RADIUS sesudah commit tetap dapat lease
   sampai commit berikutnya (regenerasi allowlist).

Kapan pakai PPPoE vs IPoE:

- **PPPoE** — bila subscriber perlu username/password (akun per
  pelanggan), sesi yang bisa dimonitor/diputus, dan auth per-sesi.
  Cocok untuk layanan broadband rumahan.
- **IPoE** — bila perangkat subscriber tidak mendukung PPP, atau
  akses berbasis perangkat (MAC) sudah cukup (mis. perangkat yang
  didaftarkan MAC-nya). Tanpa sesi, tanpa password — lebih sederhana,
  tapi auth hanya berbasis MAC (yang bisa di-spoof).
- Keduanya bisa jalan bersamaan (pool berbeda, interface berbeda)
  di mesin yang sama.

### 9d.2 PPPoE (mpd5) — detail

Perintah (view `pppoe-server`, mode configure):

```
configure terminal
pppoe-server
interface bridge0
pool 10.99.42.100 10.99.42.110
enable
end
configure terminal
commit
save
```

`commit` men-generate `/usr/local/etc/mpd5/mpd.conf` dan menjalankan
`mpd5`. Pool: `pool <awal> <akhir>` (rentang IP untuk klien).
Server memakai IP 10.254.254.1 (ujung IPCP), MTU/MRU 1492,
acfcomp/protocomp aktif. Interface PPPoE di lab: `bridge0`
(subscriber tersambung lewat bridge0 / vxlan100).

User lokal (tanpa RADIUS): akun CHAP/PAP didefinisikan di konfigurasi
mpd5 (chap/pap secrets). Uji 15 Nov 2026 (auth lokal): RB3011 sebagai
klien — discovery/LCP/CHAP/IPCP LOLOS, klien dapat 10.99.42.100 dari
pool1, ping dua arah 5/5 0% loss. PPPoE via VXLAN juga LOLOS 16 Nov.

RADIUS (perintah di view `pppoe-server`):

```
configure terminal
pppoe-server
radius-server 103.50.129.84
radius-secret <secret>
enable
end
configure terminal
commit
save
```

Tiga hal yang wajib diketahui (ditemukan saat uji 19 Nov 2026):

- **Backend RADIUS diaktifkan via `set auth enable radius-auth`.**
  Perintah `set auth enable radius` adalah **INVALID** di mpd5 5.9
  (log: `option "radius" ambiguous`) — jangan dipakai.
- **`set radius server` saja TIDAK mengaktifkan backend RADIUS.**
  Tanpa `radius-auth`, mpd5 hanya mencoba INTERNAL lalu "ran out of
  backends" — RADIUS tidak pernah dicoba. Perintah yang benar adalah
  `set auth enable radius-auth` (sumber:
  `/usr/local/etc/mpd5/mpd.conf.sample`, label `radius:`).
- **Cabang RADIUS wajib meng-emit `set link enable chap` + `set link
  accept chap pap`.** Tanpa keduanya, backend dipilih tanpa protokol
  link → klien tidak bisa auth. (Bug ini ditemukan + diperbaiki
  19 Nov; mock PPPOE-MOCK 77/0, termasuk console 20 Nov.)
- Generate: `set radius server <ip> <secret> 1812 1813`, retries 3,
  timeout 3. **`radius-acct` — perintah klish `radius-acct` (tanpa
  argumen) + `radius-nas-ip <ip>`.** `radius-acct yes` adalah
  **SALAH** (`Syntax error ... Illegal command line`) — argumen `yes`
  milik skrip backend, bukan klish. `radius-acct` meng-emit
  `set auth enable radius-acct` hanya bila `radius-server` ter-set.
  Matikan: `no radius-acct`. **Uji live 20 Nov 2026 — LOLOS:**
  Start tercatat di `radacct` (`acctsessionid 5130773-L-1`,
  `titian-test`, `10.99.42.100`, `acctstoptime NULL`) + muncul di
  `GET /v0/sessions` (`active`, `source: radius`); Stop sesudah
  klien disconnect (`acctstoptime` terisi, `acctsessiontime 130`,
  sesi hilang dari API `[]`). Monitoring PPPoE via RADIUS
  Accounting **SELESAI**. Detail + bukti: laporan
  `PPPOE-MONITORING-20261119.md` §1.

Bukti uji live (19 Nov 2026, myRadDASH host 84):

- **radtest 4/4 LOLOS** — PAP benar → Access-Accept, PAP salah →
  Access-Reject, CHAP benar → Access-Accept, CHAP salah →
  Access-Reject; Response Authenticator OK.
- **PPPoE E2E via RADIUS LOLOS** — klien lokal `ppp` (user
  `titian-test`): mpd5 log `RADIUS: Authenticating user
  'titian-test'` → `Rec'd RAD_ACCESS_ACCEPT` → `CHAP: sending
  SUCCESS`; `tun0` UP, IP **10.99.42.100** dari pool1.
- **Uji negatif LOLOS** — password salah → `RAD_ACCESS_REJECT`,
  `tun0` TIDAK dapat IP. RADIUS adalah otoritas auth, bukan fallback
  lokal.

Catatan jujur:

- **Ping klien → 10.254.254.1 GAGAL (100% loss) saat klien lokal.**
  Bukan kegagalan RADIUS. Penyebab: konflik route same-machine —
  klien dan server mpd5 di mesin yang SAMA; route ke IP klien
  10.99.42.100 mengarah ke `lo0`, jadi balasan ICMP server tidak
  kembali lewat tunnel. LCP/IPCP (yang memberi IP) bekerja. Pada uji
  15 Nov (RB3011 sebagai klien terpisah), ping dua arah 5/5 LOLOS.
- **RB3011 sebagai klien — BISA via API, TIDAK via SSH password.**
  SSH key RB3011 ditolak pasca-upgrade RouterOS v7.25.1, dan
  password SSH juga TIDAK BEKERJA (server hanya tawar `publickey` —
  RouterOS `always-allow-password-login=no` mematikan password auth
  bila user punya key terkonfigurasi; password user TIDAK salah).
  Namun **RouterOS API port 8728 BEKERJA** (login password OK) dan
  dipakai untuk konfigurasi RB3011 — DORA via RB3011 LOLOS 20 Nov
  2026 (lihat §9d.3). SSH key tetap perlu ditambah ulang via
  Winbox/API bila SSH interaktif mau dipakai. Akses RB3011 hanya
  dari mesin test (VM Muse tidak menjangkau IP privat 192.168.91.32).
- **FreeRADIUS TIDAK bisa di-install di mesin test** (repo pkg
  `data.tzst` 404) — alasan pivot ke myRadDASH.

Matikan RADIUS (kembali auth lokal) + matikan server:

```
configure terminal
pppoe-server
no radius-server
no radius-secret
no enable
end
configure terminal
commit
save
```

Console mpd5 (fitur permanen, 20 Nov 2026):

```
configure terminal
pppoe-server
console
end
configure terminal
commit
save
```

Console mendengarkan di `127.0.0.1:5005` (loopback saja, tidak
terekspos ke jaringan). User `titian-console`, password 16 hex char
auto-generate — tersimpan mode 600 di `/etc/titian/mpd-console.pw` +
`/cfg/titian/mpd-console.pw`, **TIDAK PERNAH dicetak** (perintah
`show pppoe-server` hanya menampilkan "set/unset", bukan nilainya).
Rotasi password: `console password` (generate baru, lalu `commit`).
Matikan: `no console` (state + file password ikut dihapus).

Tiga hal yang wajib diketahui (ditemukan saat uji 19 Nov 2026):

- **Sintaks console yang benar adalah `set console self 127.0.0.1
  5005`.** Bentuk `set console ip 127.0.0.1 5005` **SALAH** — ditolak
  mpd5 5.9 sebagai "Unknown command" (sumber:
  `/usr/local/etc/mpd5/mpd.conf.sample`). Generator meng-emit
  `set user titian-console <pw> admin` + `set console self
  127.0.0.1 5005` + `set console open` di seksi `startup:` mpd.conf.
- **Password HARUS 16 hex char.** Password 32 hex char **GAGAL
  login** (padahal hash file sama dengan hash di mpd.conf) — batas
  efektif `set user` mpd5 adalah 16 char. Generator selalu memakai
  16 hex.
- **Restart mpd5 wajib tunggu proses lama mati.** `pkill` + start
  langsung bisa gagal "already running as process <pid lama>" —
  generator kini stop → poll `pgrep` kosong (maks ~10 detik) → start.

Console HANYA untuk manajemen mpd5 (cek status) — JANGAN dipakai
untuk melihat/menutup sesi PPPoE. Pemutusan sesi dari myRadDASH tetap
via SSH (`titian-remote-kick.sh`, §9d.7).

Catatan restore: auto-backup factory-reset TIDAK berisi `pppoe.conf` /
`mpd.conf` (runtime file mpd5). Sesudah restore, `mpd.conf` bisa
masih berisi RADIUS (stale) karena `cmd_apply` sengaja return lebih
awal saat PPPoE disable (tidak regenerasi mpd.conf) — tapi mpd5 ikut
berhenti. Hal yang sama berlaku untuk baris console (`set user
titian-console` + `set console ...`) — stale di mpd.conf sesudah
disable, tapi mpd5 berhenti sehingga console tidak listen; bersihkan
dengan `no console` + commit bila perlu. Bersihkan eksplisit: `no radius-server` + `no radius-secret`
+ `no enable` via klish → commit; lalu regenerasi mpd.conf via siklus
enable→commit→disable→commit; `service mpd5 onestop`. Hasil akhir:
`pppoe.conf` = `enable no`, tanpa radius; `mpd.conf` bersih; mpd5
berhenti.

### 9d.3 IPoE (isc-dhcpd) — detail

Perintah (view `ipoe-server`, mode configure):

```
configure terminal
ipoe-server
interface lagg0
pool 10.99.50.0/24 10.99.50.100 10.99.50.110 10.99.50.1 8.8.8.8 3600
enable
end
configure terminal
commit
save
```

Format pool: `pool <subnet>/<prefix> <awal> <akhir> <gateway> <dns>
[lease-detik]`. Lease default 86400 detik (1 hari). `commit`
men-generate `/usr/local/etc/dhcpd.conf` dan menjalankan `dhcpd`
pada interface yang dipilih. Syarat: interface harus punya IP di
subnet pool yang sama (mis. pool 10.99.50.0/24 butuh interface
ber-IP 10.99.50.x) — kalau tidak, `dhcpd` menolak start. Perintah
lengkap + contoh ada di §9a.2.

mpd5 TIDAK mendukung IPoE. IPoE adalah IP polos di atas Ethernet,
alias DHCP — tanpa sesi PPP, tanpa username/password.

RADIUS MAC-auth (MAB — MAC Authentication Bypass):

IPoE tidak punya username/password, jadi auth berbasis MAC.
isc-dhcpd TIDAK punya dukungan RADIUS native, dan hook `on commit` +
`execute()` TIDAK BISA mem-veto lease (lease sudah ter-commit saat
hook jalan). Mekanisme yang dipakai (native isc-dhcpd): class
`radius-allowed` + subclass per MAC yang lolos RADIUS + pool
`allow members of "radius-allowed";` + `deny unknown-clients;`.
RADIUS adalah otoritas: saat `commit`, tiap MAC yang dideklarasikan
diverifikasi ke RADIUS (PAP, User-Name = MAC, User-Password = MAC).
MAC yang RADIUS Reject / tidak terverifikasi (RADIUS tak terjangkau)
DIKELUARKAN + warning (fail-closed). Bila mac-auth aktif tapi NOL
MAC lolos, generate GAGAL lantang (rc 33) dan config lama
dipertahankan. Perintah lengkap ada di §9a.3.

```
configure terminal
ipoe-server
radius-server 103.50.129.84
radius-secret <secret>
radius-mac 02:00:00:00:00:01
radius-mac-auth
enable
end
configure terminal
commit
save
```

`radius-mac` menerima alamat MAC (huruf kecil dinormalisasi,
idempotent — tambah MAC yang sama dua kali tetap rc 0 tanpa duplikat).
`radius-secret` tidak pernah di-echo oleh backend (tapi baris perintah
klish-nya di-echo oleh klish — lihat §9d.4). Matikan RADIUS MAC-auth
(kembali DHCP terbuka): `no radius-mac-auth` + `no radius-server` +
`no radius-secret` + `no radius-mac <MAC>` → commit → save (§9a.3).

Bukti uji live:

- **13 Nov 2026 (DHCP terbuka, tanpa RADIUS): LOLOS.** RB3011
  (DHCP client) bound 10.99.41.100/24, gw 10.99.41.1, DNS 8.8.8.8,
  ping 3/3. Akar awal gagal: VTEP RB3011 kosong (broadcast putus) —
  fix sintaks v7 `/interface vxlan vteps add interface=vxlan100
  remote-ip=10.10.2.3`.
- **19 Nov 2026 (RADIUS MAC-auth via myRadDASH): verifikasi RADIUS
  saat generate LOLOS live.** Commit mencetak warning `radius-mac
  02:00:00:00:00:03 DITOLAK / tidak terverifikasi RADIUS
  (103.50.129.84) — dikeluarkan dari allowlist` + `ipoe: RADIUS
  MAC-auth aktif (103.50.129.84): 1 MAC lolos, 1 ditolak/tak-terjangkau`
  + `dhcpd.conf generated` + `IPoE server (dhcpd) started on: lagg0`.
  Artinya: MAC `:01` **Access-Accept** dari myRadDASH (secret cocok —
  response-authenticator terverifikasi), MAC `:03` **Reject** (tidak
  ada entri) dan dikeluarkan dari allowlist. `dhcpd.conf` hasil
  generate BENAR: class `"radius-allowed"` hanya berisi `subclass
  "radius-allowed" 1:02:00:00:00:00:01;` (hanya `:01`), pool `allow
  members of "radius-allowed"` + range 10.99.50.100–110 + routers
  10.99.50.1 + DNS 8.8.8.8 + lease 3600, `deny unknown-clients`,
  subnet 10.99.50.0/24 di lagg0. **dhcpd JALAN.**
- **Mock: IPOE-RADIUS-MOCK 33/0** (dijalankan di mesin test FreeBSD;
  UDP loopback di VM Muse diblokir sandbox). FASE A (mac-auth OFF,
  backward compat), B (MAC Accept masuk allowlist, MAC Reject
  dikeluarkan + warning), C (tanpa radius-server → gagal lantang),
  D (RADIUS mati → NOL MAC → gagal lantang + config lama
  dipertahankan), E (validasi MAC/secret/IP, idempotent), F (helper
  Accept/Reject/secret salah→rc 2/timeout→rc 2), G (`dhcpd -t`
  gagal → gagal lantang + config lama aman), H (`sh -n` +
  `py_compile`).

Uji klien DHCP (DORA) — **LOLOS 20 Nov 2026 via RB3011**:

DORA (DISCOVER→OFFER→REQUEST→ACK) **TERBUKTI live** dari host
terpisah. RB3011 sebagai klien DHCP di `bond1` (subnet lagg0
10.99.50.0/24) via RouterOS API 8728 — DHCP client `client3`
(`add-default-route=no`, `use-peer-dns=no`, agar routing/DNS
manajemen RB3011 tidak terganggu) — **bound 10.99.50.100/24**,
gateway 10.99.50.1, DNS 8.8.8.8, `dhcp-server=10.99.50.1`,
`expires-after=59m58s`. Sisi server: lease tercatat di
`/var/db/dhcpd.leases` (`binding state active`, MAC
`6c:3b:6b:ff:d7:95`, hostname `TEST`); ping mesin test →
10.99.50.100 **3/3, 0% loss**; ARP `10.99.50.100 at
6c:3b:6b:ff:d7:95 on lagg0`. Siklus DORA lengkap + lease + IP
dapat dipakai — **IPoE DORA SELESAI**. DHCP client dihapus sesudah
uji (RB3011 kembali pra-uji). Detail: laporan
`PPPOE-MONITORING-20261119.md` §2.

Catatan — keterbatasan same-machine (19 Nov 2026, tetap berlaku
untuk uji lokal): broadcast yang dikirim dari mesin test sendiri
TIDAK sampai ke dhcpd di mesin yang sama. Bukti: klien raw-UDP
(`dhcp-raw-client.py`, DISCOVER dengan chaddr spoofed, tanpa option
61, bind ke 10.99.50.1:68) mengirim tanpa error, tapi tcpdump di
lagg0/ge1/ge2/lo0 tidak menangkap apa pun; ping broadcast ke
10.99.50.255 juga terkirim tapi tidak muncul di interface mana pun
(100% loss); DISCOVER unicast ke 10.99.50.1:67 juga tanpa OFFER
(dhcpd melayani broadcast lagg0). Dua bug socket ditemukan +
diperbaiki sebelumnya (bind `0.0.0.0:68` → `Network is
unreachable`; limited broadcast 255.255.255.255 → `No route to
host` — ganti ke broadcast subnet 10.99.50.255 yang punya route via
lagg0), tapi akarnya adalah keterbatasan same-machine: broadcast
dari host sendiri tidak kembali ke daemon di host yang sama. Ini
keterbatasan platform/harness uji, BUKAN kegagalan RADIUS atau
allowlist — keduanya terbukti live. Untuk membuktikan DORA, klien
harus jalan di host TERPISAH di subnet lagg0 (10.99.50.0/24) —
RB3011 via API adalah jalurnya (SSH password tidak bekerja,
lihat §9d.2). Skrip klien (`dhcp-raw-client.py`: bind wajib
10.99.50.1:68, tujuan broadcast subnet 10.99.50.255, exit 0=OFFER+ACK,
1=tanpa OFFER, 2=error) didokumentasikan di sini untuk uji itu;
file-nya dihapus sesudah restore (tulis ulang bila perlu).

Keterbatasan:

- Auth per-request real-time (cek RADIUS tiap DHCPDISCOVER) TIDAK
  dimungkinkan isc-dhcpd. Arsitektur yang benar untuk itu adalah
  FreeRADIUS `rlm_dhcp` (FreeRADIUS sebagai DHCP server) — butuh
  paket baru + keputusan arsitektur (FreeRADIUS tidak bisa di-install
  di mesin test, repo pkg 404).
- Verifikasi RADIUS dilakukan saat generate/commit, bukan
  per-request. MAC yang dicabut dari RADIUS sesudah commit tetap
  dapat lease sampai commit berikutnya (regenerasi allowlist).
- Log dhcpd: `log-facility local7` di `dhcpd.conf`, tapi
  `/etc/syslog.conf` TIDAK punya aturan untuk `local7` — jadi log
  dhcpd (DISCOVER/OFFER) tidak tercatat di mana pun. Bila butuh
  log, tambahkan aturan syslog untuk local7 dulu.

### 9d.4 RADIUS (myRadDASH) — detail

Server: myRadDASH host 84 (103.50.129.84), FreeRADIUS 3 di container
`myradash-freeradius`, port UDP 1812 (auth) / 1813 (acct). Basis data:
MariaDB (`myradash-db`), tabel `nas`, `radcheck`, `radreply`,
`radusergroup`, `clients`, `mitras`. Query SQL FreeRADIUS adalah
STOCK; authorize hanya query radcheck/radreply/radusergroup — TIDAK
join tabel `clients`. Auth RADIUS hanya butuh `nas` + `radcheck`;
baris `clients` hanya untuk konsistensi dashboard.

NAS — `nasname` WAJIB = source IP yang dilihat FreeRADIUS:

Paket UDP dari mesin test ke 103.50.129.84:1812 tiba dengan source IP
**`103.50.128.18`** (NAT MikroTik dari mgmt 10.10.2.3 — BUKAN
10.10.2.3, BUKAN 103.50.128.6). Jadi NAS uji `titian-test` (id 26)
memakai nasname `103.50.128.18`, shortname `titian-test`, platform
`generic`, auth_mode `radius`, mitra 7 (`Mitra Tes SSTP`). Bila
nasname salah → FreeRADIUS menolak dengan `Ignoring request ...
from unknown client` + radtest TIMEOUT.

NAS baru butuh restart container FreeRADIUS:

`read_clients` hanya dibaca saat STARTUP. SIGHUP tidak efektif
(`HUP - No files changed. Ignoring`); touch + HUP me-reload modul/
config file, BUKAN klien SQL. Penyebab: `dynamic-clients` TIDAK
di-enable. Solusi: restart container `myradash-freeradius`
(`docker restart`, ~1–5 detik). Dampak: jendela ±beberapa detik,
login baru FNSNET gagal/delay (NAS retry); sesi yang sudah jalan
TIDAK terdampak. Tidak ada perubahan config produksi — restart
hanya memuat ulang entri DB yang ditambahkan.

`radcheck` op HARUS `:=`, bukan `==`:

Semua 55 baris FNSNET yang bekerja pakai op `:=`. Dengan `==`,
rlm_sql memperlakukan `Cleartext-Password` sebagai check item yang
harus dicocokkan saat authorize — tapi `User-Password` di request
saat itu masih TERENKRIPSI (PAP belum dekripsi), jadi check gagal →
password tidak dimuat ke control list → PAP tidak punya "known
good password" → `No Auth-Type found: rejecting the user`. Dengan
`:=`, rlm_sql me-SET `Cleartext-Password` ke control list, PAP
membandingkannya sesudah dekripsi → cocok → Accept. Gejala bila
salah: password BENAR tetap Access-Reject, dan log debug FreeRADIUS
menunjukkan `sql: User found in radcheck table` +
`WARNING: check items do not match` + `No "known good" password
found`.

Entri uji (mitra 7, DIBIARKAN — user putuskan simpan/hapus):

- **NAS id 26** — nasname `103.50.128.18`, shortname `titian-test`,
  platform `generic`, auth_mode `radius`, mitra 7.
- **PPPoE user** — radcheck id 124: username `titian-test`,
  attribute `Cleartext-Password`, op `:=`, mitra 7. clients:
  username `titian-test`, mitra 7, service_type `pppoe`, status
  `active`, package_id NULL.
- **IPoE MAC** — radcheck id 125: username `02:00:00:00:00:01`,
  attribute `Cleartext-Password`, op `:=`, mitra 7. clients:
  username `02:00:00:00:00:01`, mitra 7, service_type `client`,
  status `active`. (MAB: User-Name = MAC, User-Password = MAC —
  nilai password-nya adalah MAC itu sendiri, huruf kecil,
  ber-titik-dua.) TIDAK ada entri untuk `02:00:00:00:00:03`
  (sengaja — uji negatif).
- **FNSNET (mitra 6) TIDAK disentuh** — radcheck 55, nas 2, utuh.

Secret — KOREKSI PENTING (terverifikasi 19 Nov 2026):

- Secret RADIUS disimpan di `/etc/titian/ipoe.conf` (mode 600)
  **DAN ikut tersimpan di startup-config** via `<CONFIG/>` + `save`
  (terverifikasi: `grep -c "radius-secret" /etc/titian/startup-config`
  = 1 saat RADIUS aktif). Klaim lama bahwa secret "tidak ditulis ke
  startup-config" adalah SALAH. Konsekuensi: secret ikut ter-backup
  saat `save` (dan ikut dalam auto-backup factory-reset). Saat
  restore/bersihkan, verifikasi hitungannya = 0.
- **Baris perintah klish `radius-secret` di-echo oleh klish ke
  output** (prompt + perintah muncul di output tool). Jadi nilai
  secret bisa muncul di output/log runtime — jangan pernah menyalin
  nilai itu ke laporan, file, atau MEMORY. (Backend `titian-dhcp.sh`
  / `titian-pppoe.sh` sendiri tidak pernah me-echo secret; yang
  me-echo adalah klish.)
- Untuk PPPoE, secret yang sama juga ada di `mpd.conf` (runtime file
  mpd5) — bersihkan via `no radius-secret` + commit + regenerasi
  (lihat §9d.2, catatan restore).

`commit` vs `save`:

- **`commit`** meregenerasi config layanan + me-reload daemon, tapi
  TIDAK menulis startup-config. (Bukti: sesudah `commit` saja,
  startup-config tidak berubah.)
- **`save`** (dari enable view) menulis running-config ke
  startup-config + menjadwalkan persist ke `/cfg/titian`.
- Jadi sesudah ubah konfigurasi RADIUS: `commit` lalu `save`, lalu
  verifikasi startup-config (md5 + hitungan `radius-secret`).

### 9d.5 Operasional — backup, restore, verifikasi, troubleshooting

Backup pra-uji (sebelum ubah apa pun):

- IPoE: `ipoe.conf`, `dhcpd.conf`, `startup-config` (backup
  19 Nov: `~/workspace/titian-backups-machine/ipoe-radius-20261119/`).
- PPPoE: `pppoe.conf`, `mpd.conf`, `startup-config`, `resolv.conf`
  (backup 19 Nov:
  `~/workspace/titian-backups-machine/pppoe-radius-20261119/`).

Restore anchor (sesudah uji):

1. Via klish hapus semua konfigurasi RADIUS + `enable` (IPoE:
   `no radius-mac-auth` → `no radius-mac <MAC>` → `no radius-secret`
   → `no radius-server` → `no enable`; PPPoE: `no radius-server` →
   `no radius-secret` → `no enable`) → `commit` → `end` → `save`.
2. Bila startup-config tanpa-stamp ≠ `48bd81b0…`, kembalikan dari
   backup `startup-config.orig` ke `/etc/titian/startup-config` +
   `/cfg/titian/startup-config` (mount rw → cp → remount ro).
   Penyebab selisih yang umum: sesudah restore klish, `commit`
   menulis seksi kosong `ipoe-server` (2 baris: `ipoe-server` + `!`)
   yang tidak ada di anchor — backup restore menghilangkannya.
3. Hapus file uji (`/tmp/dhcp-raw-client.py`, `/tmp/ipoe-secret`,
   dan sejenisnya) di mesin test + VM.

Verifikasi anchor (angka yang harus cocok):

- startup-config dengan-stamp `c8a081c9…` / tanpa-stamp
  `48bd81b0…` (kedua lokasi `/etc/titian` + `/cfg/titian`, sinkron).
- `radius-` di startup-config = 0; `ipoe-server` di startup-config
  = 0 (bila IPoE tidak di-enable).
- bird.conf x3 `b1d64147…`; frr.conf `ff589198…`.
- BGP **12 Established**; VXLAN **11/11 UP**; ping 10.99.40.2
  0% loss.
- dhcpd **berhenti**; mpd5 **berhenti**; `/` **read-only**.
- ipoe.conf = `interface lagg0` + pool saja; pppoe.conf =
  `enable no`, tanpa radius.

Troubleshooting:

| Gejala | Akar (terverifikasi) | Perbaikan |
|---|---|---|
| radtest TIMEOUT + log `Ignoring request ... from unknown client` | NAS belum dimuat FreeRADIUS (`read_clients` hanya saat startup) | Restart container `myradash-freeradius` (§9d.4) |
| radtest Reject + `resp-auth SALAH` (Response Authenticator tidak cocok) | Secret tidak cocok (tiga salinan berbeda — mis. heredoc quoted `<< "EOF"` membuat `$(openssl rand...)` tertulis literal) | Regenerasi secret sebagai nilai literal, samakan di DB + mesin, restart FreeRADIUS, verifikasi via MD5 (hash saja, bukan nilai) |
| Password BENAR tetap Access-Reject + log `No Auth-Type found` | `radcheck` op `==` (bukan `:=`) | `UPDATE radcheck SET op=':=' WHERE username='...'` (§9d.4) |
| mpd5 log `option "radius" ambiguous` | `set auth enable radius` INVALID di mpd5 5.9 | Hapus; pakai `set auth enable radius-auth` (§9d.2) |
| mpd5 `ran out of backends`, RADIUS tidak pernah dicoba | `set radius server` saja tidak mengaktifkan backend | Tambah `set auth enable radius-auth` (§9d.2) |
| PPPoE klien tidak bisa auth (chap/pap tidak jalan) | Cabang RADIUS tidak meng-emit `set link enable chap` + `set link accept chap pap` | Perbaiki generate (sudah diperbaiki di staging `31f30f49…`) |
| `commit` IPoE: semua MAC dikeluarkan + warning, generate gagal rc 33 | NOL MAC lolos RADIUS (RADIUS mati / secret salah / tidak ada entri) | Cek RADIUS hidup, secret cocok, entri MAC ada (fail-closed — sengaja) |
| MAC ada di klish tapi tidak dapat OFFER | MAC di-Reject RADIUS (tidak ada entri) → dikeluarkan dari allowlist saat commit | Buat entri radcheck + clients untuk MAC itu, lalu commit ulang |
| dhcpd tidak start | Interface tidak punya IP di subnet pool | Interface harus ber-IP di subnet pool yang sama (§9d.3) |
| DORA: DISCOVER terkirim tapi tanpa OFFER (semua MAC) | Broadcast same-machine tidak sampai ke dhcpd (keterbatasan platform, §9d.3) — uji lokal saja; **DORA via RB3011 LOLOS 20 Nov 2026** (host terpisah, API 8728) | Uji dari host TERPISAH di subnet lagg0 (RB3011 via API); jangan simpulkan RADIUS gagal dari uji same-machine |
| mpd5 jalan padahal PPPoE tidak di-enable (sesudah restart titian) | Replay restart menambah baris `enable` di bawah `pppoe-server` di startup-config | `no enable` + `commit` + `save` (periksa `pppoe.conf` + `pgrep mpd5`) |
| Log dhcpd tidak ada di mana pun | `log-facility local7` tapi `/etc/syslog.conf` tidak punya aturan local7 | Tambahkan aturan syslog untuk local7 bila butuh log DHCP |
### 9d.6 Monitoring sesi IPoE — RADIUS Accounting ke myRadDASH (19 Nov 2026)

isc-dhcpd tidak mengirim RADIUS accounting, jadi sesi IPoE (DHCP) tidak
muncul otomatis di myRadDASH. Titian mendorongnya sendiri: skrip
`titian-ipoe-acct.py` membaca lease aktif (`/var/db/dhcpd.leases`, blok
terakhir per IP) lalu mengirim Accounting-Request (Start saat lease
diberikan, Stop saat lease berakhir/hilang) ke FreeRADIUS host 84:1813
sebagai NAS `titian-test`. FreeRADIUS menulis `radacct` → sesi muncul di
myRadDASH (`GET /v0/sessions`). Tidak butuh perubahan kode myRadDASH.

Perintah:

```
show ipoe sessions       # lease aktif + sesi yang dilaporkan
ipoe push-sessions       # kirim Start/Stop sekarang (idempotent)
```

Atribut yang dikirim: User-Name = MAC, NAS-Identifier = `titian-test`,
NAS-IP-Address = `nas-ip` (dari ipoe.conf; fallback IP sumber UDP),
Acct-Session-Id = `ipoe-<mac-tanpa-titikdua>-<starts-epoch>`,
Framed-IP-Address = IP lease, Calling-Station-Id = MAC,
Acct-Status-Type Start(1)/Stop(2), Acct-Terminate-Cause User-Request(1)
untuk Stop. State sesi di `/etc/titian/ipoe-acct-state.json` (mode 600):
Start sekali per lease, Stop saat lease hilang/kedaluwarsa.

Konfigurasi (di `configure-ipoe-server`):

```
radius-server 103.50.129.84
radius-secret <secret-NAS-titian-test>   # dari kolom secret tabel nas id 26
nas-ip 103.50.128.18                     # IP NAS (nasname di myRadDASH)
```

Prasyarat: DNS mesin test harus resolve domain API
(`/etc/resolv.conf` + `/cfg/resolv.conf` berisi nameserver 8.8.8.8 +
1.1.1.1 — diperbaiki 19 Nov 2026). Akun layanan Titian untuk API:
` titian-service@myradash.local` (id 21, role `mitra_admin`, mitra 7);
kredensial HANYA di `/etc/titian/myraddash-credentials` +
`/cfg/titian/myraddash-credentials` (mode 600) — jangan pernah dicetak.
Login API: `POST /v0/auth/login` → body `{"ok": true}` + cookie
`myradash_token` (guard mengutamakan cookie, terima juga
`Authorization: Bearer`). **Catatan:** Cloudflare memblokir User-Agent
default Python-urllib (HTTP 403, error 1010) — komponen Python WAJIB
set User-Agent yang pantas (mis. `Titian/1.0`).

Terbukti live 19 Nov 2026: lease sintetis MAC `:01` / IP `.101` →
`ipoe push-sessions` → Start di-ACK → sesi muncul di `GET /v0/sessions`
(username `:01`, NAS `titian-test`, IP `.101`, `client_status: active`,
source `radius`). Sesudah kick → push lagi → Stop di-ACK → `GET
/v0/sessions` kosong (`[]`).

### 9d.7 Kick / disconnect — via SSH dengan key dedikasi (keputusan user 19:30 + 19:31)

**CoA TIDAK dipakai.** mpd5 tidak mendengarkan CoA port 3799, dan
membangun listener CoA menambah komponen; SSH lebih sederhana + robust.
Keputusan user 19:30: "kalo gak ada coa nya pake via ssh aja". Jalur
kick/disconnect = myRadDASH SSH ke mesin Titian, lalu jalankan perintah
pemutusan lokal di sana. (Listener CoA `titian-coa.py` sempat dibangun +
mock 14/0 sebagai prototipe, tetapi BUKAN jalur yang dipakai — jangan
di-deploy sebagai jalur aktif.)

**SSH pakai key DEDIKASI, bukan password** (keputusan user 19:31).
Password TIDAK dipakai (root password image BSDRP kosong + password auth
tidak bisa diotomasi dengan aman). Key pair khusus myRadDASH → Titian
(bukan key utama user):

- Private key: `/root/.ssh/myraddash-titian-kick` di host myRadDASH (84),
  mode 600. **Jangan pernah dicetak/dibagikan.**
- Public key: dipasang di `/root/.ssh/authorized_keys` mesin Titian
  dengan forced `command=` + pembatasan, agar key itu HANYA bisa
  menjalankan perintah kick/disconnect/status, bukan shell bebas.
- Generate: `ssh-keygen -t ed25519 -f /root/.ssh/myraddash-titian-kick -N "" -C "myradash-titian-kick"` (di host 84; tanpa passphrase agar
  myRadDASH bisa pakai non-interaktif).
- Pasang public key di Titian (satu baris di `authorized_keys`):
  `command="/opt/titian/sbin/titian-remote-kick.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty <public-key>`
- `known_hosts` Titian di host 84: `/root/.ssh/known_hosts_titian`
  (diisi via `ssh-keyscan -p <port> -t ed25519 <ip-titian>`).

Wrapper `titian-remote-kick.sh` (forced command) membaca
`SSH_ORIGINAL_COMMAND`, memvalidasi ketat (MAC / IPv4 / username),
lalu meneruskan ke backend — TIDAK PERNAH `eval`. Perintah yang
diizinkan: `kick <mac>` · `unblock <mac>` · `disconnect-pppoe <user>
<framed-ip>` · `status` · `leases` · `blocked` · `pppoe-sessions`.
Yang lain DITOLAK (termasuk perintah kosong = percobaan shell interaktif,
dan injeksi `;`, `$(...)`, backtick, `|`, `&&`).

Perintah SSH persis yang dipakai myRadDASH (contoh, mesin test via NAT
port 9393):

```
ssh -i /root/.ssh/myraddash-titian-kick -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/root/.ssh/known_hosts_titian \
  -o ConnectTimeout=10 -p 9393 root@103.50.128.6 "kick 02:00:00:00:00:01"
```

**IPoE kick** (`kick <mac>`): hapus lease DHCP via OMAPI (set state=1
free) + blokir MAC (`blocked-mac`, `deny booting` di dhcpd.conf, menang
atas allowlist RADIUS) + regenerate + restart dhcpd bila jalan. Perintah
klish yang sama: `ipoe kick <mac>`; buka blokir: `ipoe unblock <mac>`
(atau via SSH `unblock <mac>`).

**PPPoE disconnect** (`disconnect-pppoe <user> <framed-ip>`) — via
**console mpd5 (Opsi A, keputusan user 20 Nov 12:26)**. Implementasi
(`titian-pppoe.sh` `cmd_disconnect` + `mpd_console`): verifikasi sesi
ada + Framed-IP cocok via `show sessions user <user>` → pilih link
via `authname <user>` → `close` (default layer link = LCP, graceful:
mpd5 kirim LCP Terminate-Request, klien bawa `tun0` DOWN) → verifikasi
sesi hilang via `show sessions user <user>`. Console di
`127.0.0.1:5005`, user `titian-console`, password 16 hex dari file
mode 600 (dibaca skrip, TIDAK PERNAH dicetak); transport `nc`.
Perintah klish yang sama: `pppoe-server disconnect <user> <ip>`.
User TIDAK dihapus dari config — agar tidak bisa login lagi, myRadDASH
harus juga mengisolir user (status `isolated` di DB) sehingga auth
RADIUS berikutnya ditolak. Mock: PPPOE-MOCK FASE I 14/0 (positif +
negatif: sesi tidak ada / IP tidak cocok / auth gagal / sesi masih
ada / console OFF / nc tidak ada). Uji live negatif terkonfirmasi
20 Nov: tanpa sesi aktif, gagal sopan "sesi tidak ditemukan" (rc=1)
via skrip + via klish. **Uji live positif TERBUKTI 20 Nov**: sesi nyata `titian-test` via vnet jail (IP 10.99.42.100, auth RADIUS + accounting Start) → `pppoe-server disconnect titian-test 10.99.42.100` → rc=0 "diputus via console mpd5 (close LCP)" → sesi hilang dari `show sessions`, RADIUS Stop tercatat (`acctterminatecause Admin-Reset`), mpd5 tetap jalan, TANPA black hole (klien langsung redial + dapat sesi baru — bukti konektivitas utuh). **Catatan PADI (investigasi 20 Nov): server PPPoE SEHAT — PADI dari vnet jail / RB3011 DIJAWAB (PADO + PADR + PADS + LCP + CHAP). PADI yang dikirim dari host ITU SENDIRI via bridge0 TIDAK PERNAH dijawab — bukan bug server/Titian, melainkan keterbatasan L2 same-host: paket keluar (outgoing) dari bridge0 tidak melewati hook `orphans` netgraph tempat mpd5 mendengarkan; hanya paket MASUK (incoming) dari member bridge (epair jail / vxlan RB3011) yang sampai ke listener. Jadi uji PPPoE WAJIB dari klien terpisah (vnet jail / RB3011), JANGAN dari host via bridge0. Node pppoe netgraph yang tertinggal sesudah mpd5 berhenti (stale) TIDAK berbahaya — mpd5 berikutnya memakai ulang node itu; bukan penyebab PADI tak dijawab.**

**Pendekatan sisi server (ng0/interface) DINYATAKAN TIDAK VIABLE
(uji live 20 Nov 2026, 6 mekanisme, sesi live vnet jail):**
`ifconfig ng0 destroy` → `Invalid argument` (interface netgraph
tidak bisa di-destroy via ifconfig). `ngctl shutdown ng0:` →
interface hilang tapi bundle tetap + `tun0` klien tetap UP
(**black hole**: PPP up, IP mati, klien tidak sadar).
`ngctl shutdown <bundle>:` → bundle hilang tapi `ng0`/`tun0` tetap
UP, dan **mpd5 MATI** saat klien kemudian disconnect (cleanup
menabrak bundle yang dihancurkan eksternal). `ngctl shutdown ng0:`
+ `<bundle>:` → server bersih tapi `tun0` tetap UP + **mpd5 MATI**.
`ngctl shutdown <link-template>:` → tanpa efek (itu template, bukan
link sesi). `ifconfig ng0 down` → black hole seperti `shutdown ng0:`.
Akar: mpd5 pemilik state sesi; terminasi bersih (klien bawa `tun0`
DOWN) hanya bila mpd5 sendiri kirim LCP Terminate-Request — itu
hanya dipicu lewat kontrol mpd5 (console) atau klien yang memutus.
Manipulasi netgraph dari luar tidak men-terminasi bersih (black
hole) atau me-crash-kan mpd5. **Jangan implementasikan disconnect
via ng0/interface.** Detail + tabel: laporan
`PPPOE-MONITORING-20261119.md` §3.

Jalur yang benar (keputusan user 20 Nov 12:26): **Opsi A — console
mpd5** (mpd5 sendiri men-terminasi + kirim LCP Terminate-Request) —
**SUDAH DIIMPLEMENTASIKAN + TERBUKTI LIVE POSITIF 20 Nov** (lihat paragraf PPPoE disconnect di atas: mock 14/0, deploy staging == mesin, uji live negatif lolos, uji live positif lolos — sesi diputus via console, Admin-Reset, RADIUS Stop tercatat, mpd5 hidup, tanpa black hole). **Opsi B — user tutup
via console sendiri** (asisten beri perintah persis, user jalankan,
asisten verifikasi + restore) — cadangan bila Opsi A bermasalah.
**Opsi C — biarkan dulu** — tidak dipilih (Opsi A sudah diputuskan +
diimplementasikan).

Terbukti live 19 Nov 2026 (dari host 84 ke mesin test): `status`,
`unblock`, `kick` (lease dibebaskan via OMAPI + MAC diblokir), lalu
`push-sessions` → Stop di-ACK → sesi hilang dari myRadDASH (`[]`).
Penolakan keamanan terbukti live: `rm -rf /`, `bash`, SSH tanpa
perintah, dan injeksi `kick ...; id` — semuanya ditolak (rc=1, tanpa
shell).

### 9d.8 Troubleshooting — monitoring & kick (tambahan 19 Nov 2026)

| Gejala | Penyebab | Perbaikan |
|---|---|---|
| `show ipoe leases` kosong padahal lease ada di file | Parser lease lama memakai pola `/binding state /` tanpa jangkar — baris `next binding state free;` ikut cocok dan menimpa state menjadi `state` (bug live 19 Nov 2026) | Update `titian-dhcp.sh` (pola dijangkar `^[[:space:]]*binding state /`); fixture mock kini menyertakan `next binding state free;` |
| `show ipoe blocked` kosong padahal daftar blokir kosong | `grep -c ... \|\| echo 0` menghasilkan `0\n0` (grep -c mencetak 0 DAN exit 1) | Update `titian-dhcp.sh` (pakai `grep -q` + `wc -l`); lihat §9d.6 |
| `ipoe push-sessions` gagal: `jaringan: [Errno 1] Operation not permitted` | UDP diblokir sandbox VM (mock di VM) | Jalankan push/mock di mesin test (UDP jalan di sana) |
| Login API via Python urllib → HTTP 403 (error 1010) | Cloudflare memblokir User-Agent default Python-urllib | Set User-Agent yang pantas (mis. `Titian/1.0`); curl diizinkan |
| `commit` → `Syntax error ... "commit": Unknown command` | `commit` dikirim sesudah `end` (sudah di enable view) | Urutan benar: `configure terminal` → (ubah) → `commit` → `end` → `save` |
| `commit` → `Error: dhcpd failed to start` (tapi dhcpd lama masih jalan) | Restart dhcpd saat instance lama masih memegang port (race) | Stop dulu (`pkill -x dhcpd`) lalu `server-start`; atau abaikan bila dhcpd yang jalan sudah memakai config baru |
| Service restart menghidupkan lagi IPoE yang sudah di-stop | `/cfg/titian/ipoe.conf` (persisten) masih berisi config IPoE dari tes sebelumnya, sementara `/etc/titian/ipoe.conf` sudah interface+pool — service restore dari `/cfg` | Selaraskan `/cfg/titian/ipoe.conf` ke anchor (interface+pool) agar restore stabil; atau hapus config IPoE dari startup-config bila memang tidak dipakai |
| SSH kick ditolak `perintah tidak diizinkan` | Perintah di luar allowlist wrapper, atau SSH tanpa perintah | Pakai salah satu dari 7 perintah allowlist (§9d.7); pastikan ada argumen perintah di SSH |
| `disconnect-pppoe` → `sesi tidak ditemukan` | Tidak ada interface `tun` untuk Framed-IP itu (sesi tidak aktif / IP salah) | Periksa Framed-IP dari `radacct` myRadDASH; pastikan mpd5 jalan + sesi aktif |

---

## 9e. Profile paket dummynet — pembatasan bandwidth per pelanggan (traffic-shape)

*Profile paket* adalah cara BRAS membatasi bandwidth per pelanggan
tanpa menulis *pipe*/*rule* dummynet satu per satu. Satu profile
(template: *download* + *upload* + *burst* tiap arah) di-*bind* ke
interface atau IP, dan Titian menurunkan *pipe* + *rule* dummynet-nya
otomatis. Lapisan mentah (*pipe*/*sched*/*queue*/*rule* manual,
8 Nov 2026) tetap ada di view yang sama; profile duduk di atasnya.

### 9e.1 Konsep — profile, bind, materialisasi

File config: `/usr/local/etc/traffic-shape.conf` (ditulis klish,
jangan edit manual). Baris profile dan *bind*:

```
profile <nama> download <rate> burst <n> upload <rate> burst <n>
bind <profile> interface <if>
bind <profile> ip <addr> on <if> side <uplink|customer>
```

- Nama profile: maks 12 karakter, `[A-Za-z0-9_-]`, karakter pertama
  huruf/angka. Nama lebih panjang ditolak.
- *Rate*: bilangan bulat + satuan — `10Mbit/s`, `512Kbit/s`,
  `1Gbit/s` (tanpa desimal, tanpa angka polos).
- Profile harus lengkap (*download* + *upload* terisi) sebelum bisa
  di-*bind*. *Bind* butuh profile yang sudah ada + interface yang
  sudah ada.
- Setiap perubahan profile/*bind* langsung membuat/memperbarui
  *pipe* + *rule* turunan di config (sinkronisasi otomatis).
  Turunan memakai nama deterministik, maks 32 karakter:
  *pipe* `<profile>-<slug>-d` (*download*) / `-u` (*upload*);
  *rule* `<profile>-<slug>-down` / `-up`. *Slug*: interface = nama
  interface apa adanya; IP/CIDR = `.` `:` `/` diganti `-`
  (mis. `10.99.42.100/32` → `10-99-42-100-32`). *Pipe* turunan
  memakai default `queue 50 delay 0 plr 0`.
- Satu profile boleh punya banyak *bind* (satu *bind* = satu pasang
  *pipe* + satu pasang *rule*). Ubah *rate*/*burst* profile →
  semua *pipe* turunannya ikut berubah. *Unbind* atau hapus profile →
  turunannya ikut terhapus.
- `enable` di view `traffic-shape` adalah gerbang utama: bila
  `enable` bukan `yes`, *apply* menghapus semua objek (flush) dan
  tidak ada yang dibatasi.

### 9e.2 Perintah

Masuk view `traffic-shape` dari mode configure:

```
configure terminal
traffic-shape            # prompt: (config-traffic-shape)#
```

| Perintah | Fungsi |
|---|---|
| `enable` / `no enable` | Aktifkan / matikan traffic-shape |
| `profile <nama>` | Masuk view profile (buat bila belum ada) |
| `no profile <nama>` | Hapus profile + semua *bind* + turunannya |
| `download <rate>` | Batas *download* profile (di view profile) |
| `download-burst <byte>` | *Burst download* dalam byte (di view profile) |
| `upload <rate>` | Batas *upload* profile (di view profile) |
| `upload-burst <byte>` | *Burst upload* dalam byte (di view profile) |
| `bind interface <if>` | Terapkan profile ke satu interface/VLAN |
| `bind ip <addr> <if> [side]` | Terapkan profile ke satu IP/CIDR (`side` default `uplink`) |
| `no bind interface <if>` | Lepas *bind* interface (+ hapus turunannya) |
| `no bind ip <addr> <if>` | Lepas *bind* IP (+ hapus turunannya) |

Perintah *show* (mode exec):

```
show traffic-shape                 # enable + pipe/sched/queue/rule/profile/bind
show traffic-shape profile [nama]  # semua profile, atau satu profile + bind + turunannya
show traffic-shape pipe            # pipe mentah (termasuk turunan profile)
show traffic-shape rule            # rule mentah (termasuk turunan profile)
show traffic-shape statistics      # counter pipe/sched/queue kernel (ipfw)
```

### 9e.3 Arah download/upload — tergantung jenis bind

*Download* = dari internet ke pelanggan; *upload* = dari pelanggan
ke internet. Arah *rule* turunan mengikuti sisi mana interface
menghadap:

| Bind | Rule *download* | Rule *upload* |
|---|---|---|
| `bind interface <if>` (interface menghadap pelanggan) | `out` di `<if>` | `in` di `<if>` |
| `bind ip <addr> <if> side uplink` (default; interface menghadap *upstream*) | `in` di `<if>`, `dst <addr>` | `out` di `<if>`, `src <addr>` |
| `bind ip <addr> <if> side customer` (interface menghadap pelanggan) | `out` di `<if>`, `dst <addr>` | `in` di `<if>`, `src <addr>` |

Salah pilih `side` = arah terbalik: *download* pelanggan malah
dibatasi *rate upload* dan sebaliknya. Bila ragu, periksa hasil
`show traffic-shape profile <nama>` — *rule* turunannya tercetak
lengkap dengan arah + `src`/`dst`.

### 9e.4 Burst — semantik jujur dummynet

*Burst* dummynet adalah jatah BYTE sesudah *idle*, bukan kecepatan
tambahan yang berkelanjutan:

- Efektif: `MAX(burst, bw × idle_time)`. Sesudah *idle*, sampai
  `burst` byte boleh lewat *scheduler* sekaligus (secepat link
  fisik); sesudah jatah habis, kembali ke *rate* profile.
- Contoh: 10M + `burst 1000000` = sesudah *idle*, sampai 1.000.000
  byte (≈1 MB) lolos secepat link fisik, lalu kembali ke 10 Mbit/s.
- `burst 0` = tanpa *burst*. *Burst* tidak menaikkan *rate*
  rata-rata jangka panjang — jangan tawarkan sebagai "kecepatan
  burst" ala MikroTik; itu bukan semantiknya.
- *Burst* dihitung per *pipe* (per arah, per *bind*), bukan per
  profile secara keseluruhan.

### 9e.5 Kapan pipe masuk kernel — commit, boot, apply eksplisit

Perubahan profile/*bind* hanya mengubah file config. *Pipe* masuk
kernel saat *apply* berjalan — tiga jalurnya:

1. **`commit`** (jalur normal). Setiap perubahan menandai config
   kotor; `commit` menjalankan *hook* yang me-*restart* service
   *traffic-shape* bila config kotor (dan `enable yes`). Bila
   `enable` bukan `yes`, `commit` malah me-*flush* semua objek.
2. **Boot.** Service *traffic-shape* (*rc script*) menjalankan
   *apply* atas config saat boot.
3. ***Apply* eksplisit dari shell** (tanpa `commit`) — untuk
   menguji langsung atau menerapkan tanpa *commit*:
   ```
   /opt/titian/sbin/titian-traffic-shape.sh apply
   ```
   Perintah ini idempotent (boleh diulang); `apply --flush`
   membersihkan semua objek + *anchor*.

Catatan: *rule* pf yang dihasilkan selalu memakai `no state` —
`pass` biasa di TCP bersifat *stateful* (hanya SYN yang cocok
*rule*, data besar lewat *state* dan lolos dari *dnpipe*).
Terbukti live 13 Nov 2026 (tes 11): *rule stateful* membentuk 0,
sedangkan `no state` membentuk *pipe* 10 Mbit/s ke ~9,5 Mbit/s.

Syarat agar trafik benar-benar dialihkan: `/etc/pf.conf` harus
mereferensikan *anchor* `"traffic-shape"` (sesudah *scrub*,
sebelum *rule filter*). *Apply* memberi peringatan bila *anchor*
tidak ada, atau bila pf mati (saat itu *pipe* tetap dibuat tapi
tidak ada trafik yang dialihkan). Firewall ipfw sendiri sengaja
dimatikan (`net.inet.ip.fw.enable=0`) — ipfw di sini hanya menjadi
tuan rumah *pipe* dummynet; *filtering* tetap pf
(pelajaran *lockout* 16 Nov 2026: ipfw yang aktif dengan
*default-deny* dan tanpa *rule* memblokir semua trafik).

### 9e.6 Contoh lengkap

Pelanggan A — PPPoE 10M, IP `10.99.42.100/32` di `ge0` (uplink),
*burst* 500000:

```
configure terminal
traffic-shape
enable
profile pppoe10
download 10Mbit/s
download-burst 500000
upload 10Mbit/s
upload-burst 500000
bind ip 10.99.42.100/32 ge0
end
configure terminal
commit
save
```

Hasilnya di config (turunan otomatis):

```
profile pppoe10 download 10Mbit/s burst 500000 upload 10Mbit/s burst 500000
bind pppoe10 ip 10.99.42.100/32 on ge0 side uplink
pipe pppoe10-10-99-42-100-32-d bw 10Mbit/s queue 50 delay 0 plr 0 burst 500000
pipe pppoe10-10-99-42-100-32-u bw 10Mbit/s queue 50 delay 0 plr 0 burst 500000
rule pppoe10-10-99-42-100-32-down in on ge0 pipe pppoe10-10-99-42-100-32-d dst 10.99.42.100/32
rule pppoe10-10-99-42-100-32-up out on ge0 pipe pppoe10-10-99-42-100-32-u src 10.99.42.100/32
```

Pelanggan B — 100M untuk seluruh VLAN pelanggan `vlan100`:

```
configure terminal
traffic-shape
profile paket100
download 100Mbit/s
upload 100Mbit/s
bind interface vlan100
end
configure terminal
commit
save
```

Turunan: *pipe* `paket100-vlan100-d` / `-u` + *rule*
`paket100-vlan100-down` (`out` di `vlan100`) /
`-up` (`in` di `vlan100`).

Menghapus:

```
configure terminal
traffic-shape
no bind ip 10.99.42.100/32 ge0   # lepas satu bind (+ turunannya)
no profile pppoe10               # hapus profile + semua bind + turunannya
end
configure terminal
commit
save
```

### 9e.7 Verifikasi + bukti ukur

```
show traffic-shape profile pppoe10   # profile + bind + pipe/rule turunan
show traffic-shape statistics        # counter kernel: cek pipe bertambah
```

`show traffic-shape statistics` memanggil `ipfw pipe show` (dan
*sched*/*queue*): kolom *transmitted* menunjukkan byte yang lewat
*pipe*; *dropped* menunjukkan byte yang dibuang karena melebihi
*rate*. Bila *transmitted* jalan tapi *dropped* 0 saat trafik
melebihi *rate*, *pipe* belum diterapkan (cek §9e.5) atau *rule*
salah arah (cek §9e.3).

Bukti ukur (21 Nov 2026, uji throughput dummynet): profile `paket8`
→ **8,001 Mbit/s** (target 8); profile `paket14` → **14,004 Mbit/s**
(target 14) — dummynet bekerja presisi. Metode: *UDP flood* Python
(~3,3 Gbit/s *offered*, paket 1400 B) ke satu *bind* IP di `ge0`
(*burst* 500000); hasil dihitung dari *counter pipe* dummynet
(*transmitted* = *offered* − *dropped*). Bukan iperf3 *end-to-end*
(MikroTik tidak menjalankan iperf3) — jangan klaim sebagai hasil
iperf3.

Catatan: konfigurasi profile 100M di `vlan100` lolos di *mock*,
tapi uji *throughput* live 100 Mbps lewat `vlan100` BELUM terukur —
diterima sebagai keterbatasan mesin (22 Nov 2026); angka 100M di
VLAN belum terukur live. Mock: `TRAFFIC-SHAPE-PROFILE-MOCK.sh` 80/0;
`TRAFFIC-SHAPE-MOCK.sh` (lapisan mentah) 20/0.

### 9e.8 Gotcha — troubleshooting

| Gejala | Penyebab | Perbaikan |
|---|---|---|
| `bind interface` / `bind ip` ditolak: profile belum lengkap | *Download* atau *upload* belum di-set | Set `download` + `upload` dulu, baru `bind` |
| `bind` ditolak: profile tidak ditemukan | Profile belum dibuat | Buat dulu: `profile <nama>`, lalu isi *rate* |
| `bind` ditolak: interface tidak ditemukan | Nama interface salah / belum ada | Cek `show interfaces terse` |
| `bind ip` ditolak: butuh alamat/CIDR | `bind ip any ...` tidak diizinkan | Pakai alamat atau CIDR eksplisit (mis. `10.99.42.100/32`) |
| `bind ip` ditolak: nama turunan >32 karakter | Profile 12 karakter + IP panjang → *slug* melebihi 32 | Pakai nama profile lebih pendek |
| `show traffic-shape profile` menampilkan profile, tapi kernel tidak membatasi | Belum `commit` / belum *apply* (lihat §9e.5) | `commit` (lalu `save`), atau *apply* eksplisit dari shell |
| Sudah `commit` tapi tetap tidak membatasi | `enable` bukan `yes` → *apply* malah *flush* | `traffic-shape` → `enable` → `commit` |
| Sudah `commit` + `enable`, tetap tidak membatasi | *Anchor* `"traffic-shape"` tidak ada di `/etc/pf.conf`, atau pf mati | Tambah `anchor "traffic-shape"` ke `/etc/pf.conf` (sesudah *scrub*); pastikan pf aktif |
| *Download* pelanggan dibatasi *rate upload* (atau sebaliknya) | `side` terbalik di `bind ip` | Cek *rule* turunan di `show traffic-shape profile <nama>`; *rebind* dengan `side` yang benar (`uplink` vs `customer`, lihat §9e.3) |
| `ipfw pipe <n> show` tidak menampilkan apa-apa | Objek memang tidak ada — perintah ini mengembalikan rc 0 BAHKAN untuk objek yang tidak ada | Cek keberadaan dari OUTPUT, bukan dari rc |
| Log kernel `do_config invalid delete type 3` saat *apply* | Dulu: *flush* menghapus objek yang tidak ada (bug, sebelum 19 Nov 2026) | Sudah diperbaiki — *flush* hanya menghapus objek yang ada (cek OUTPUT). Bila masih muncul, laporkan |

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
| 13 | Traffic-shape / dummynet limiter + profile paket | traffic-shape.xml | ✅ LIVE | Function-test (staged, full masks); mock profile 80/0, mock lapisan mentah 20/0. **Model profile paket SELESAI 20 Nov 2026** (profile + bind + turunan otomatis). **Uji throughput live LOLOS 21 Nov 2026**: profile `paket8` → 8,001 Mbit/s (target 8), `paket14` → 14,004 Mbit/s (target 14), diukur dari *counter pipe* dummynet (UDP flood). Detail: §1.10 + §9e. Batasan jujur: *throughput* 100M lewat `vlan100` BELUM terukur live (lolos di *mock* saja). |
| 14 | PPPoE server (mpd5, pool, user, RADIUS) | conf-pppoe.xml | ✅ LIVE | **LOLOS 15 Nov (auth lokal)**: E2E RB3011, CHAP, client dapat 10.99.42.100, ping 5/5. **LOLOS 19 Nov (RADIUS via myRadDASH)**: mpd5 → FreeRADIUS host 84, CHAP, Access-Accept, IP 10.99.42.100; password salah → Access-Reject (tanpa IP). Kunci: backend RADIUS diaktifkan via `set auth enable radius-auth` (bukan `set auth enable radius` — INVALID di mpd5 5.9; `set radius server` saja tidak mengaktifkan backend); radcheck myRadDASH pakai op `:=` (bukan `==`). Catatan: ping ke 10.254.254.1 dari klien lokal gagal (konflik route same-machine, bukan RADIUS); uji RB3011 sebagai klien tertunda (SSH key RB3011 ditolak pasca-upgrade v7.25.1). Detail BRAS: §9d.2. |
| 15 | IPoE server (DHCP) | conf-ipoe.xml | ✅ LIVE | **LOLOS 13 Nov**: RB3011 (DHCP client) bound 10.99.41.100/24, gw 10.99.41.1, DNS 8.8.8.8, ping 3/3. Akar awal gagal: VTEP RB3011 kosong (broadcast putus) — fix sintaks v7 `/interface vxlan vteps add interface=vxlan100 remote-ip=10.10.2.3`. **LOLOS 19 Nov (RADIUS MAC-auth via myRadDASH)**: verifikasi RADIUS saat generate — MAC `02:00:00:00:00:01` Access-Accept, `:03` Reject + dikeluarkan dari allowlist; dhcpd.conf hanya berisi subclass `:01`, pool allow, deny unknown-clients; dhcpd jalan. Mock IPOE-RADIUS 33/0. Uji klien DHCP (DORA) end-to-end BELUM terbukti — broadcast same-machine tidak sampai ke dhcpd (keterbatasan platform, bukan RADIUS). Detail BRAS: §9d.3. |
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
| 28 | Factory reset | en-factory-reset.xml | ⏳ STAGING | Mock hermetik 19 Nov: 41 PASS / 0 FAIL (arm tidak menghapus, confirm hapus tepat + pulihkan sample + backup bisa di-restore, write-memory tetap tidak ada); belum uji live — butuh rencana uji backup-first |
| 29 | Titian update | en-update.xml | ⏳ STAGING | Mock hermetik 19 Nov: 41 PASS / 0 FAIL (check 3 status + fetch fallback + perbandingan numerik 0.10.0>0.9.0; arm tidak mengubah; install-confirm sukses via 2 sumber checksum + menolak 8 kondisi gagal; verifikasi config terdeteksi); belum uji live — butuh rencana uji backup-first |

**Yang paling terbuka (prioritas uji berikut):** FRR live (daemon +
BGP via vtysh, §9c.5) · WireGuard · firewall/NAT ·
traffic-shape · static route `forward` (perbaikan di repo, belum
retest live) · rename CLI · service SSH. Semuanya BLOKIR proxy SSH
VM putus sejak 13 Nov 14:33 (masih putus 14:57). PPPoE (baris 14)
SUDAH LOLOS 15 Nov (lokal) + 19 Nov (RADIUS via myRadDASH).

> **Update hitungan (13 Nov ~15:00, sesudah uji live tes 1–10):**
> dari 27 baris di atas, yang ✅ LIVE = **19**, yang 🟡 SEBAGIAN =
> **5** (FRR, static route, traffic-shape, SSH, rename), yang ❌
> BELUM/GAGAL = **3** (firewall/NAT, PPPoE GAGAL, WireGuard).
> Sebelum uji: 11/7/9. Detail uji: `~/workspace/
> titian-live-test-20261113/HASIL.md` (di VM, bukan di repo).
>
> **Koreksi 19 Nov (PPPoE + RADIUS LOLOS):** PPPoE baris 14 kini
> ✅ LIVE (lokal 15 Nov + RADIUS 19 Nov) — hitungan kini ✅ LIVE =
> **20**, ❌ BELUM/GAGAL = **2** (firewall/NAT, WireGuard).

---

## Penutup

Dokumen ini mendeskripsikan permukaan CLI sesuai tree di repositori ini
(`tree/` + `tree-nonroot/`). Bila ada perintah di sesi interaktif yang
tidak ada di sini, `?` di posisi tersebut adalah sumber kebenaran —
tree adalah definisi CLI, dokumen ini ringkasannya.

Dokumen terkait di repo: `PANDUAN.md` (instalasi dari paket rilis +
penggunaan dasar), `README-panjang.md` (gambaran proyek + layout +
fitur). Instalasi dari paket: lihat Releases.
