# Lab BSDRP — Titian klish di atas image BSDRP

Dokumen ini adalah catatan lab Titian di atas BSDRP (FreeBSD-based
router project), 3–4 November 2026: apa yang diuji, apa yang lulus,
bug apa yang ketemu dan diperbaiki, dan apa yang belum terbukti.
§8 merangkum keadaan akhir yang terpasang di kedua sisi (BSDRP +
MikroTik) per verifikasi terakhir.
Semua alamat di bawah adalah alamat privat jaringan lab, bukan alamat
publik. Dokumen pendamping: `lab-cli.md` (lab utama Debian/FreeBSD +
CHR), `panduan-cli.md` (cara pakai CLI).

BSDRP di sini BUKAN lab utama Titian. Lab utama memakai Debian 13 dan
FreeBSD 15 dengan BIRD 2.17.5/2.19.2. Lab BSDRP memakai image BSDRP
(FreeBSD 16.0-CURRENT) dengan BIRD 2.17.2 bawaan image — jadi hasilnya
adalah bukti portabilitas Titian ke sistem file read-only BSDRP,
bukan pengganti hasil lab utama.

## 1. Topologi lab BSDRP

```
                    ┌──────────────────────────────────┐
                    │  Host FreeBSD (bhyve)            │
                    │  iface live 10.10.2.254/24       │
                    │  bridge0 = iface live + tap0     │
                    └──────────────┬───────────────────┘
                                   │  bridge
                                   ▼
                    ┌─────────────────────────────┐
                    │  Guest BSDRP (bhyve, 1 vCPU)│
                    │  FreeBSD 16.0-CURRENT       │
                    │  em0 = 10.10.2.200/24       │
                    │  klish 2.2.5, BIRD 2.17.2    │
                    │  ASN lab 65000              │
                    └──────────────┬──────────────┘
                                   │  10.10.2.0/24
                                   ▼
                    ┌─────────────────────────────┐
                    │  MikroTik (lawan uji BGP)   │
                    │  10.10.2.1, ASN lab 65001    │
                    │  RouterOS 6.49.19           │
                    └─────────────────────────────┘
```

Keterangan:

- **Host** menjalankan bhyve (1 vCPU untuk guest; host hanya
  menyediakan 1 vCPU). Guest di-boot lewat `bhyveload` (loader prompt
  → `set console=comconsole` → `boot`) + `bhyve` dengan konsol serial
  stdio. Konsol guest diakses lewat FIFO host (bukan SSH) selama
  instalasi — SSH guest baru dipakai setelah servisnya jalan.
- **Guest** adalah image BSDRP (pilihan lab, bukan build dari source):
  partisi root read-only, partisi `cfg` dan `data` (keduanya `noauto`,
  hanya di-mount saat `config save`/`config load`). Root partition
  di-mount read-only saat boot; tulis ke `/` / `/opt` / `/root` wajib
  `mount -uw /` dulu.
- **MikroTik** adalah lawan uji BGP (bukan Titian). SSH-nya gagal dari
  sisi server (disconnect sebelum KEX selesai); konfigurasinya diset
  lewat telnet dari host (wajib `-l agoes`) — lihat §6. Winbox tidak
  dipakai untuk set BGP ini.

## 2. Cara Titian masuk ke BSDRP

Dua jalur, berurutan:

1. **Instalasi manual (3 Nov, untuk uji).** Paket 0.1.0 ditransfer
   lewat netcat, lalu file disalin manual: `/opt/titian` penuh,
   `/usr/local/bin/titian` (+ symlink `cli`), `rc.d/titian`,
   `sbin/titian-bird-reopen`, newsyslog. Servis dijalankan lewat
   `rc.d/titian onestart` (konfd via socket `/tmp/konfd.socket`).
   Jalur ini yang dipakai untuk semua uji §3–§5.
2. **Paket BSDRP (4 Nov, hasil akhir).** Setelah semua uji lulus,
   instalasi manual di atas dirakit jadi paket
   `titian-bsdrp-0.1.0.pkg` (lihat §5) dan diuji install bersih di
   guest yang sama (hapus manual → `pkg add` → verifikasi → restore
   state lab). Guest kini menjalankan paket, bukan instalasi manual.

Perbedaan paket BSDRP dengan paket 0.1.0 biasa:

| Item | Paket 0.1.0 (net/titian) | Paket BSDRP (net/titian-bsdrp) |
|---|---|---|
| Nama / versi | `titian` 0.1.0 | `titian-bsdrp` 0.1.0 |
| Dependensi | bird2, sudo, expat | TIDAK ADA (ketiganya sudah di image BSDRP) |
| Log BIRD di seed | `/var/log/bird/bird.log` | `/var/log/bird.log` (lihat §4.3) |
| Filter BGP | contoh saja | contoh + filter wajib CLI (lihat §4.2) |
| Ukuran / md5 | 362.914 byte | 360.825 byte, `4db7323bf257ab1f2b8e299074d0547b` |

## 3. Hasil uji per fitur

| Fitur | Hasil |
|---|---|
| Show: interfaces, ip route, ipv6 route, service, running/startup-config | LULUS |
| Configure: interface ethernet/loopback/vlan, ip/ipv6 address, ip route, system, service ssh, mtu, description, enable/disable + semua no-form | LULUS |
| Ping (default 5 paket) | LULUS, 0% loss ke host |
| VLAN (buat + IP + hapus) | LULUS (hapus asimetris, §4.4) |
| IPv6 loopback (buat + hapus) | LULUS |
| LAGG | SKIP (butuh 2 NIC; guest hanya 1 em0) |
| Bird view: generate/check, show route/protocol, community, redistribute | LULUS (setelah perbaikan filter §4.2) |
| Save (klish) + config save (BSDRP) + restart guest | LULUS (2x reboot, §4.5) |
| Paket BSDRP install bersih | LULUS (§5) |
| BGP peer ke MikroTik | LULUS (Established dua arah + prefix test + uji restart, §6) |
| PtP live em0↔MikroTik | BELUM TERBUKTI (definisi + status di §7) |

### 3.1 Show dan configure dasar

- `show interfaces` (terse/all/ethernet), `show ip route`,
  `show ipv6 route`, `show running-config`, `show startup-config`,
  `show history`, `show pwd`, `show service summary` semua jalan.
- `show service status` WAJIB pakai argumen nama servis (tanpa argumen
  = "Incompleted command").
- `show version` BUKAN perintah valid. `do show ...` hanya valid di
  dalam configure; di top-level = Unknown command. `exit` di top-level
  = Unknown command (pakai `logout`).
- Mode batch: `?` / `show?` tidak didukung.
- `service ssh` di configure masuk view `config-system-ssh`, lalu
  `port <n>`: port 2222 teruji (sshd pindah, port 22 hilang), revert
  port 22 teruji (sshd kembali). Keduanya dua arah.
- `system hostname`: set → prompt + running-config berubah; revert →
  pulih persis.
- `interface ethernet em0` + `ip address 10.10.2.200/24` +
  `description BSDRP-LAB` tercatat di running-config dan bertahan
  lewat reboot (lihat §4.5).

### 3.2 IP route — sintaks yang terbukti

- Cabang gateway: `ip route <dest> <gateway-ip>` — TANPA kata
  "forward". "forward" adalah PARAM IP_ADDR langsung; mengetik kata
  "forward" = Illegal parameter.
- Cabang device: `ip route <dest> dev <iface>`.
- Keduanya teruji live (gateway `10.99.98.0/24 via 10.10.2.254` UGS,
  device `10.99.97.0/24 dev em0` US) dan tercatat di running-config.
- Hapus: `no ip route <dest>` (cukup dest, tanpa gateway/device).

### 3.3 Loopback, /31, dan PtP (loopback, bukan live)

- Loopback hanya `lo1`–`lo9` (pattern `lo([1-9])$`); `lo0` DITOLAK
  "Illegal parameter".
- Loopback pakai `addr-set` (REPLACE semua alamat IPv4 interface —
  by design rtcli): di loopback, hanya alamat terakhir yang live,
  sementara running-config mengakumulasi semua baris (divergensi
  loopback, bukan bug jalur ethernet yang pakai `addr-add`).
- `/31` di loopback JALAN (netmask `0xfffffffe`, tanpa broadcast).
- `/31` di em0 JALAN (alias menumpuk di atas /24, ping host 0% loss,
  dihapus bersih via no-form, rc.conf kembali kosong).
- PtP FreeBSD (koreksi dari lab utama, berlaku juga di sini): lokal
  `/32` + `route add -host <peer> -iface <iface>` (BUKAN ifconfig
  `dstaddr` di Ethernet broadcast — diabaikan, ping loss).
  Sintaks klish: `ip address <ip> peer <peer_ip>`.
- PtP LIVE em0↔MikroTik belum teruji (definisi + alasan tertunda
  di §7).

### 3.4 VLAN dan IPv6

- Buat: `interface vlan 99 em0` + `ip address 10.99.99.1/24` →
  vlan99 up/active, parent em0, MAC = MAC em0.
- Hapus: `no interface vlan 99` SAJA (tanpa parent — dengan parent =
  "Illegal command line"). Asimetri ini dicatat, bukan bug.
- IPv6 loopback: `ipv6 address 2001:db8::1/128` → inet6 prefixlen 128
  jalan; hapus via `no interface loopback lo1` jalan.
- LAGG: tree + show ada, tapi SKIP live (guest hanya 1 em0; butuh
  2 NIC fisik). Dicatat sebagai skip, bukan gagal.

### 3.5 Bird view dan generate

- Masuk bird view pakai `bird terminal` (bukan `bird` saja =
  Incompleted command; perintah bird BUKAN top-level).
- `generate check <section>` → parse OK; `generate <section>` →
  backup timestamped ke `bird-backup/` + `bird -p` + tulis +
  `birdc configure` (Reconfigured).
- `show protocol summary` (device/kernel up, bgp Active —
  keadaan pra-BGP; kini Established, §6),
  `show route count` (baseline pra-BGP 0/0 benar: kernel import
  none + BGP belum Established; kini prefix test masuk, §6),
  `show community` (kosong baseline),
  `show redistribute` (static enabled, direct disabled baseline).
- Layout BIRD asli (bukan `bird.d` + include): `bird.conf` TUNGGAL
  bermarker `#-<SEKSI>-#` / `#-END<SEKSI>-#` + sumber section di
  `/opt/titian/etc/bird.d/<section>.conf`. Marker: FUNCTION, FILTER,
  PROTOCOL, PROTOCOL-STATIC, BGP, OSPF, DIRECT, BFD, PIPE.
- **GAP tree (wajib diketahui):** tree 0.1.0 TIDAK punya perintah
  `router bgp` / neighbor BGP. Peer BGP ditulis manual ke fragmen
  `bird.d/bgp.conf` lalu `generate bgp`. Ini keterbatasan tree,
  bukan bug generate.
- `generate check bgp` SEBELUM konversi seed GAGAL sesuai prediksi
  (marker `#-BGP-#` tidak ada di `bird.conf` live) — teratasi dengan
  konversi seed (router id + ASN + log, lihat §4.3).

## 4. Temuan dan perbaikan

### 4.1 Urutan aman: set IP dulu, baru rute gateway

Setelah `ip address` em0 via klish, `show ip route` KEHILANGAN rute
gateway (running-config masih punya). Akar: `addr-add` em0 sempat
melepas primary (`-alias`) lalu pasang lagi (`alias`); FreeBSD
menghapus rute gateway yang bergantung pada alamat tersebut saat
primary dilepas. Perbaikan: tambah ulang rute (kernel kembali UGS;
running-config TIDAK duplikat — konfd mengganti, bukan menumpuk).
Urutan aman: set IP interface dulu, baru tambah rute gateway.

### 4.2 Bug filter BGP + perbaikan (masuk paket)

Temuan uji: `community export add`, `community import add`,
`redistribute static disable` / `direct enable` semua GAGAL di
install segar: "filter bgp_export_attr / cabang RTS_STATIC tidak
ditemukan" dan "filter bgp_import_comm tidak ditemukan". Akar:
seed `filter.conf` hanya berisi contoh `f_accept`/`f_reject`
(grep bgp_export_attr = 0). Urutan pemakaian tidak menolong
(community add sendiri butuh filter yang sama). Delete entri
tak-ada graceful; no-op toggle short-circuit benar.

Perbaikan (di `bird.d/filter.conf`, 21 baris,
md5 `79c630ee72737df3a98700cd7b328595`):

```bird
filter bgp_export_attr {
    if source = RTS_STATIC then { accept; }
    reject;
}
filter bgp_import_comm {
    accept;
}
```

(`f_accept`/`f_reject` dipertahankan.) Filter hanya DIDEFINISIKAN,
belum ditempel ke protokol bgp_mikrotik (masih import all/export
none) — meski BGP kini Established (§6), penempelan tetap langkah
kebijakan terpisah yang belum dilakukan. Uji ulang semua jalan (backup + parse OK +
Reconfigured): export add/delete 65000:100, import add/delete
65000:200 reject, redistribute static disable→enable, direct
enable→disable (direct.conf FreeBSD: protocol direct1; birdc sempat
"Reconfiguration in progress" = notice async, state akhir
terverifikasi disabled). Perbaikan ini WAJIB ada di paket (§5) dan
di source repo (sudah disamakan).

### 4.3 Bug log BIRD saat reboot + perbaikan (masuk paket)

Reboot pertama: bird GAGAL start — "Unable to open log file
'/var/log/bird/bird.log': No such file or directory". Akar: seed
memakai subdir `/var/log/bird` yang tidak ada saat boot karena
`/var` di-reset BSDRP (mkdir sekali saat install tidak bertahan).
Perbaikan: log dipindah ke `/var/log/bird.log` (file di `/var/log`
yang selalu ada saat boot, tanpa mkdir). Seed paket + post-install
(2 cabang awk) sudah memakai path baru; reboot kedua membuktikan
bird auto-start bersih. Jangan kembalikan path lama di BSDRP.

### 4.4 Catatan kosmetik dan gotcha konsol

- Ping: 2 baris `expr: syntax error` sebelum output (expr ACTION
  ping gagal pada variabel kosong) — dicatat, tidak diperbaiki
  (di luar scope uji ini).
- Boot guest BERHENTI di emergency shell (`/tmp` symlink ke
  `/var/tmp` yang belum ada) — Ctrl-D melanjutkan boot (terbukti
  2x). Ini perilaku image BSDRP, bukan Titian.
- Perintah titian yang dikirim saat konsol di prompt login akan
  dimakan sebagai username — login dulu sebagai root baru kirim
  perintah (Ctrl-C membatalkan login nyasar).
- Login SSH ulang sempat gagal bukan karena kunci: klien ssh
  berjalan sebagai root membaca `/root/.ssh/` (kosong), bukan
  `/home/hatch/.ssh/` tempat kunci berada. Solusi: `IdentityFile`
  eksplisit di config SSH (ProxyJump via host).
- Root guest read-only: tulis ke `/` / `/opt` / `/root` wajib
  `mount -uw /` dulu (pola instalasi manual).
- Transfer file ke guest: scp dari host GAGAL (guest publickey-only,
  host tanpa kunci) — dipakai heredoc via FIFO, chunk kecil
  (<300 karakter per kiriman; kiriman ~700 karakter overflow buffer
  uart guest). Ctrl-C membatalkan heredoc parsial dengan aman.

### 4.5 Save, config save BSDRP, dan restart (2x reboot pra-BGP; reboot ke-3 di §6)

Payload restart (running-config): hostname, service ssh port 22,
interface em0 (description + ip address), ip route gateway.
`save` → `startup-config` (235 byte, header version + last commit)
terverifikasi ada dan isinya = running-config.

Enable: `sysrc titian_enable=YES` (bird_enable=yes sudah ada).
`/etc/rc.conf`: ifconfig_em0 lama `10.3.0.1/30` (baris awal) +
blok `#-TITIAN-#` ifconfig_em0 `10.10.2.200/24` (baris akhir →
menang saat boot, last assignment wins).

BSDRP `config save`: "Archiving... /etc/rc.conf -> /cfg/rc.conf
Done." (`/cfg` tidak ter-mount sesudahnya — tool meng-unmount;
verifikasi via `mount /cfg`: `/cfg/rc.conf` memuat blok TITIAN +
titian_enable=YES).

Shutdown bersih 2x (poweroff, sync 0, bhyve exit). Relaunch:
bhyveload (3 → set console=comconsole → boot) + bhyve stdio+FIFO,
Ctrl-D di emergency shell, login prompt normal.

Hasil reboot 1: konfd up (titian_enable), startup-config ter-replay
utuh, em0 10.10.2.200, sshd+cron up, running-config == saved persis,
SSH pasca-reboot jalan (host key guest TIDAK berubah — pin tetap
cocok). Satu-satunya gagal: bird (log path, §4.3, diperbaiki).
Hasil reboot 2 (setelah perbaikan log): bird AUTO-START tanpa
error, konfd up, replay utuh, bgp_mikrotik Active. Guest NORMAL
penuh setelah restart. Reboot ke-3 (uji restart pasca-BGP, 4 Nov
09:17 WIB) ada di §6: bgp_mikrotik Established lagi + prefix
kembali.

## 5. Paket BSDRP siap install

File: `titian-bsdrp-0.1.0.pkg` (360.825 byte,
md5 `4db7323bf257ab1f2b8e299074d0547b`). Dibangun di guest
(`pkg create` dari staging + manifest + plist eksplisit; kunci
manifest "deps:" tidak dipakai karena tanpa dependensi).
Isi: 71 entri (68 file/link + 3 @dir db/bird-backup/netstate):
klish runtime (bin/lib), tree 22+6 XML, sbin, bird.d 6 file
pristine (termasuk filter hasil perbaikan §4.2), bird.conf.seed
(log path §4.3), wrapper + symlink cli, rc.d, newsyslog +
bird-reopen. TIDAK berisi: startup-config, section live
(direct.conf, bgp_mikrotik), backup CLI — instalasi bersih mulai
dari keadaan kosong, seperti seharusnya.

### 5.1 Cara install (BSDRP segar)

Prasyarat: image BSDRP dengan bird + sudo + expat (sudah di image
standar; paket tidak menarik dependensi). Di guest (sebagai root,
setelah `mount -uw /` bila perlu):

```
pkg add titian-bsdrp-0.1.0.pkg
```

Post-install otomatis: mkdir `/var/log/bird` (tidak berbahaya di
BSDRP, tapi bukan andalan — andalannya path log §4.3); konversi
seed `bird.conf` HANYA bila marker belum ada (PRIMARY dari ifconfig
pertama non-loopback, ASN default 64512; `bird.conf` yang sudah
bermarker TIDAK ditimpa); cek parse `bird -p`; `sysrc
titian_enable=YES` + `bird_enable=YES` (hanya bila belum ada);
`service titian start` (konfd + replay startup-config bila ada).

Setelah install, konfigurasi seperti biasa lewat klish, lalu:

```
save
config save
```

(`save` = klish startup-config; `config save` = BSDRP /cfg.
Keduanya wajib agar konfigurasi bertahan lewat reboot: yang
pertama untuk replay Titian, yang kedua untuk rc.conf + enable.)

Reboot: guest berhenti di emergency shell `/tmp` — tekan Ctrl-D
untuk lanjut. Verifikasi pasca-reboot: `show running-config`
(== saved), `show ip route`, `birdc show protocols` (bird up),
login SSH.

### 5.2 Uji install bersih (terbukti)

Di guest yang sama: backup state lab dulu, stop titian+bird,
hapus instalasi manual (`/opt/titian`, wrapper, rc.d, newsyslog,
bird-reopen), `pkg add` → ekstrak 100%, post-install start konfd.
Verifikasi: `titian --version` 2.2.5; bird.d = 6 pristine;
bgp.conf = contoh bgp_lab; filter.conf md5 perbaikan; `pkg info
titian-bsdrp-0.1.0` terpasang. Uji filter di install bersih:
`bird terminal` → community export add/show/delete 65000:100
jalan (backup + parse OK + Reconfigured). Setelah uji, state lab
di-restore (backup etc + bird.conf) → running-config == saved,
bgp_mikrotik Active lagi (keadaan pra-set MikroTik; kini
Established, §6). Guest kini menjalankan paket + state lab utuh.

Gotcha `pkg create` (untuk yang merakit ulang): entri `@dir`
wajib ada fisik di staging (mkdir dulu) kalau tidak error
"Unable to access file .../db/".

### 5.3 Paket 0.2.0 — filter attach + perbaikan restore (terpasang di guest lab)

File: `titian-bsdrp-0.2.0.pkg` (432.916 byte,
md5 `1f3300599be0b1afb29c36a04d312eca`). Dibangun LOKAL di VM
(bukan di guest): payload 0.1.0 dibaca utuh, hanya 3 file
diganti/ditambah, skrip post/pre verbatim, symlink/direktori/file
lain verbatim — skrip build tersimpan di goal BSDRP
(`hidden_files/build-0.2.0-pkg.py`). Delta dari 0.1.0: TAMBAH
`sbin/titian-filter.sh` (perintah `filter attach/detach/show`),
UBAH `etc/clish-en/bird.xml` (perintah filter baru) dan
`sbin/titian-comm.sh` (perbaikan restore: backup dipindah ke
sebelum edit). Isi: 74 entri tar (69 file + 3 @dir + 2 manifest),
flatsize 1303195, TANPA deps. Verifikasi lokal: semua checksum
file cocok, hanya 2 file berubah + 1 baru, symlink 9 identik.

Terpasang di guest lab 4 Nov 13:54 UTC (`pkg add` di atas file
0.1.0; verifikasi: `pkg info titian-bsdrp-0.2.0`,
`titian --version` 2.2.5, md5 ketiga file baru sama dengan source,
`bird.conf` live + startup-config TIDAK tersentuh post-install,
BGP re-Established 13:54:10 UTC dan stabil).

Gotcha UPGRADE (terbukti saat pasang 0.2.0, bukan teori):

- `pkg add` MENIMPA fragmen `bird.d/` live dengan seed paket:
  `bgp.conf` seed (bgp_lab) menggantikan `bgp_mikrotik` live,
  sehingga `filter show bgp_mikrotik` sempat gagal ("protokol tidak
  ditemukan") sampai fragmen live di-restore dari backup.
  Prosedur upgrade yang benar: backup dulu → `pkg add` →
  restore `bird.d/` live dari backup → `generate filter` (sinkron
  ulang live `bird.conf` ke baseline) → verifikasi md5.
  Instalasi bersih (perangkat baru) tidak kena gotcha ini — seed
  memang yang seharusnya terpasang di sana.
- Registrasi pkg TIDAK persisten lewat reboot BSDRP: `/var/db/pkg`
  ikut di-reset bersama `/var` (terbukti: sesudah reboot,
  `pkg info` kosong padahal semua file tetap ada dan servis jalan).
  Karena itu instalasi diverifikasi lewat file + versi + servis,
  bukan `pkg info` pasca-reboot. `pkg` juga meninggalkan
  `bgp.conf.pkgsave` (backup fragmen pra-install; artefak, tidak
  berbahaya).

### 5.4 Image bersih titian-bsdrp-0.2.0 (SELESAI, 4 Nov sore)

- Dibangun dari `.xz` pristine (md5 `615fcd43f9a7c9232417b5ea158a7aab`,
  tidak berubah): diekstrak ke image baru 14G; guest lab TIDAK
  dimatikan selama pembangunan (BGP tetap Established).
- Partisi root = BSDRPXYZ1 (p3; p4 = BSDRPXYZ2 cadangan, p5 = cfg,
  p6 = data); paket 0.2.0 di-preload ke `/root` image (md5 cocok).
- Guest prep terpisah (tap + konsol + nama vm sendiri) boot dari
  image baru, `pkg add` 0.2.0, terverifikasi BERSIH: `pkg info`
  0.2.0, titian 2.2.5, `titian-filter.sh` +x, perintah filter di
  `bird.xml`, TANPA startup-config, TANPA bgp_mikrotik di
  `bird.d/bgp.conf`, TANPA blok TITIAN di `rc.conf`, socket konfd
  ada, bird jalan dengan default seed (device + kernel + static1
  kosong).
- Sebelum shutdown: kunci host SSH + `/etc/hostid` + file `.pkg`
  preload DIHAPUS, agar perangkat baru regenerasi kunci hostnya
  sendiri di boot pertama (mekanisme yang sama yang membuatnya di
  boot prep). Shutdown bersih (servis berhenti, buffer tersinkron);
  kopler dibersihkan (tap/FIFO prep dihapus, bridge kembali tap0).
- File akhir (tinggal di kopler, disalin user ke perangkat baru):
  `BSDRPXYZ-klish-0.2.0.img.xz`, 3.428.262.284 byte, md5
  `1547e1c531cd25561835190dc4c3a1e8`, `xz -t` OK.
- Notes: partisi data image pristine menunjukkan inkonsistensi
  fsck bawaan (failok, boot tetap jalan) — teramati, bukan akibat
  build ini, tidak diperbaiki. Default em0 image = 10.3.0.1/30
  warisan; hostname/IP/BGP diset ulang di perangkat baru via klish
  + save (keputusan varian BERSIH 4 Nov 11:32 WIB).

## 6. BGP ke MikroTik — LULUS (Established + prefix test + uji restart)

ASN atas jawaban lab "bebas aja, cuma lab": guest 65000, MikroTik
65001. Fragmen `bird.d/bgp.conf` (ditulis manual, karena GAP tree
§3.5):

```bird
protocol bgp bgp_mikrotik {
    local as TITIAN_ASN;
    neighbor 10.10.2.1 as 65001;
    ipv4 { import all; export none; };
    ipv6 { import none; export none; };
}
```

`generate bgp` SUKSES (parse OK + Reconfigured). Sisi MikroTik
diset 4 Nov 2026 via telnet dari host (SSH MikroTik gagal
server-side — bukan jalur; telnet wajib `-l agoes`, tanpa itu router
langsung minta Password untuk user root). Baseline pra-set bersih:
instance "default" as=65530, tanpa peer, tanpa network. Perintah
set (RouterOS 6.49.19):

```
/routing bgp instance set default as=65001 router-id=10.10.2.1
/routing bgp peer add name=peer-titian remote-address=10.10.2.200 remote-as=65000
/routing bgp network add network=192.0.2.0/24 synchronize=no
```

Hasil (4 Nov 09:11–09:19 WIB):

- MikroTik: peer `peer-titian` **Established** stabil (2x print
  status selang 10 detik, flag E, remote-id=10.10.2.200,
  hold-time=3m, ttl=255).
- Guest: `birdc show protocols` bgp_mikrotik up, Established sejak
  09:11:00; `show route all` =
  `192.0.2.0/24 [bgp_mikrotik] * (100) [AS65001i] via 10.10.2.1 on
  em0`, origin IGP — as-path 65001 + next-hop benar.
- Community di sesi live (klish bird view): export add 65000:100 →
  Reconfigured; show menampilkan
  `bgp_community.add((65000, 100));`; delete → Reconfigured
  (baseline pulih). Notes: filter §4.2 hanya didefinisikan, belum
  ditempel ke bgp_mikrotik (import all/export none) — community
  tidak mengalir ke MikroTik; penempelan = langkah kebijakan
  terpisah. MikroTik tidak belajar rute dari guest (export none,
  sesuai desain).

Uji restart guest (shutdown bersih → bhyveload + bhyve → Ctrl-D
emergency shell → SSH kembali): em0 10.10.2.200/24, rute
10.99.98.0/24 via 10.10.2.254 (bukti replay startup-config), socket
konfd ada (titian auto-start), bird auto-start, bgp_mikrotik
Established lagi 09:17:14, prefix 192.0.2.0/24 kembali. BGP aktif
sesudah restart — LULUS.

Sisa sesudah BGP: PtP live em0↔MikroTik (sintaks `peer` §3.3).

## 7. Yang belum terbukti — jangan diklaim

- PtP live em0↔MikroTik — definisi: uji link point-to-point
  BENAR-BENAR lewat kabel ke MikroTik (bukan loopback, bukan
  /24 broadcast yang dipakai sekarang). Caranya: em0 dipindah ke
  alamat PtP (lokal /32 + rute host ke peer via interface, sintaks
  klish `ip address <ip> peer <peer_ip>`) dan sisi MikroTik diset
  PtP yang berpasangan, lalu dibuktikan ping peer + BGP tetap jalan
  di atas link itu. Tertunda karena em0 adalah satu-satunya NIC
  guest SEKALIGUS jalur mgmt + transport BGP: mengubahnya ke PtP
  memengaruhi jangkauan kopler (10.10.2.254, satu /24 yang sama)
  dan sesi BGP yang baru Established — jadi butuh rencana uji +
  revert ke jangkar /24 yang eksplisit sebelum dijalankan, bukan
  sekadar perintah. Loopback PtP (§3.3) sudah lulus; yang belum
  adalah versi live-nya di em0. Keputusan user 4 Nov 13:35 WIB:
  Opsi B — uji PtP live menunggu perangkat multi-NIC (penantian
  yang sama dengan uji rename), dijalankan di NIC non-mgmt, bukan
  em0. Draf rencana tersimpan di goal BSDRP
  (files/ptp-live-em0-draft-plan.md); tidak ada perintah lab
  yang dijalankan dari draf itu.
- Penempelan filter community ke bgp_mikrotik (kebijakan, bukan bug).
  Syarat (keputusan user 4 Nov): penempelan + filtering nanti HARUS
  bisa lewat klish, dan harus mendukung well-known attribute.
  Perintah `community` sudah menerima well-known
  (no-export/no-advertise/no-peer/blackhole, lihat titian-comm.sh)
  dan teruji dua arah lawan CHR. Perintah klish tempel/lepas filter
  SELESAI diimplementasi di source 4 Nov siang
  (`sbin/titian-filter.sh` + `filter attach/detach/show` di
  `tree/bird.xml`; test lokal 24/24 lulus: edit fragmen single-line
  + multi-line, validasi filter/protokol, no-op idempotent, restore
  saat check gagal, tolak filter inline). Uji live di guest lab
  4 Nov sore — LULUS (paket 0.2.0, §5.3): `filter show` baseline
  (import all/export none) → `community export add 65000:100` →
  `filter attach ... export bgp_export_attr` (backup + parse OK +
  Reconfigured) → `show` membuktikan tempelan → route static
  203.0.113.0/24 (dari `generate static`, fragmen seed) ter-export
  membawa `BGP.community: (65000,100)` (bukti `show route export
  ... all`) → `community import add 65000:200 reject` +
  `filter attach ... import bgp_import_comm` (keduanya ditempel,
  prefix 192.0.2.0/24 tetap ter-import) → `filter detach` keduanya
  + delete kedua rule → baseline kembali byte-persis (md5 fragmen
  + live `bird.conf` sama dengan pra-uji). BGP Established TIDAK
  pernah flap selama semua operasi filter (satu sesi sejak
  13:54:10 UTC). Penerimaan tag di sisi MikroTik TERBUKTI 4 Nov
  sore (cek ulang dengan export ditempel kembali, read-only,
  config MikroTik tidak diubah): route 203.0.113.0/24 via
  10.10.2.200 flag ADb, detail `bgp-as-path 65000, bgp-origin igp,
  bgp-communities 65000:100, received-from peer-titian`,
  prefix-count peer 1; sesudah revert guest, prefix-count kembali
  0 dan route hilang, sesi tetap Established. Batas jujur yang
  tersisa: aksi reject import atas route ber-tag tidak teramati
  (butuh route masuk ber-tag dari MikroTik).
  Catatan mekanisme: export awal sempat KOSONG — bukan karena
  attach gagal, tapi karena master4 hanya berisi prefix BGP-import
  (kernel import none; PROTOCOL-STATIC kosong) dan filter hanya
  accept RTS_STATIC; tag mengalir sesudah route static ada.
  Section static tidak punya perintah un-generate klish, jadi
  revert-nya memakai restore byte-persis live `bird.conf` pra-uji
  + `birdc configure` (terverifikasi: static4 hilang, BGP tidak
  flap, export kosong lagi).
- LAGG live (butuh 2 NIC).
- Uji fitur Titian lain di BSDRP di luar §3 (mis. firewall/NAT,
  OSPF, VXLAN, tuning, checkpoint — tree-nya ada, belum diuji di
  image ini).
- BIRD 2.19.x di BSDRP (image memakai 2.17.2; paket BSDRP tidak
  memaksa versi bird).
- Perilaku di hardware BSDRP nyata (lab ini bhyve 1 vCPU; bukan
  benchmark performa).

## 8. Keadaan akhir yang terpasang (per verifikasi terakhir 4 Nov 14:03 WIB)

Bagian ini adalah satu-satunya rujukan keadaan live: semua yang
diset di guest BSDRP dan di MikroTik, dari mana asalnya (klish,
manual, paket, bawaan image), dan apa yang TIDAK diubah. Keadaan
ini terverifikasi terakhir 4 Nov sore WIB (install 0.2.0 §5.3 +
uji filter §7 + revert ke baseline); sesudah itu tidak ada
perintah apa pun ke kedua host, jadi inilah keadaan sekarang
sampai ada yang mengubahnya.

### 8.1 Guest BSDRP (Titian) — via klish / paket / manual

Paket: `titian-bsdrp-0.2.0` terpasang (`pkg info`, 4 Nov 13:54 UTC;
§5.3); klish 2.2.5; BIRD 2.17.2 bawaan image (jalan sebagai root).
Notes: registrasi pkg tidak persisten lewat reboot (§5.3);
instalasi diverifikasi lewat file + versi + servis.

Konfigurasi Titian (startup-config, 235 byte, last commit 4 Nov
06:39 UTC; running-config == saved, terverifikasi pasca-reboot):

- `system hostname BSDRPXYZ.net`
- `service ssh port 22` (sshd listen 22; port 2222 hanya sesaat saat
  uji, sudah revert)
- `interface ethernet em0 description BSDRP-LAB`
- `interface ethernet em0 ip address 10.10.2.200/24`
- `ip route 10.99.98.0/24 via 10.10.2.254` (UGS em0; rute dev
  10.99.97.0/24 sudah dihapus sebelum save)

Enable + boot (`/etc/rc.conf`, tersimpan ke /cfg via `config save`):

- `titian_enable=YES`, `bird_enable=yes`
- Baris warisan `ifconfig_em0="inet 10.3.0.1/30"` (baris awal,
  tidak dipakai — kalah oleh blok TITIAN)
- Blok `#-TITIAN-#`: `ifconfig_em0="inet 10.10.2.200/24"` (menang,
  last assignment wins)
- TIDAK ada blok `#-TITIAN-RENAME-#` (rename belum pernah jalan di
  guest ini)

BIRD (`/usr/local/etc/bird.conf` + `/opt/titian/etc/bird.d/`):

- Seed: router id 10.10.2.200, `define TITIAN_ASN = 65000`,
  `log "/var/log/bird.log" all` (path perbaikan §4.3)
- `bird.d/bgp.conf` (manual, via `generate bgp`): protokol
  `bgp_mikrotik`, `local as TITIAN_ASN`, neighbor 10.10.2.1 as
  65001, ipv4 import all / export none, ipv6 import none /
  export none — status: Established (§6; re-Established 13:54:10
  UTC sesudah restart install 0.2.0, stabil melewati uji filter +
  revert §7)
- `bird.d/filter.conf` (perbaikan §4.2, md5
  `79c630ee72737df3a98700cd7b328595`): `f_accept`, `f_reject`,
  `bgp_export_attr` (RTS_STATIC accept, sisanya reject),
  `bgp_import_comm` (accept) — penempelan TERBUKTI live (§7:
  attach/detach/show jalan, tag mengalir), saat ini KEMBALI
  baseline (tidak ditempel: import all / export none) menunggu
  keputusan kebijakan
- `bird.d/function.conf`, `ospf.conf`, `protocol.conf`,
  `static.conf`: pristine (tidak pernah diubah CLI)
- `bird.d/direct.conf` (live, di luar paket): protokol direct1;
  redistribute: static enabled, direct disabled (baseline)
- Backup generate di `bird-backup/` (timestamped per generate)

Servis (pasca-install 0.2.0 + revert uji filter, 14:03 WIB):
konfd up (socket `/tmp/konfd.socket`), bird up (bgp_mikrotik
Established sejak 13:54:10 UTC, tidak flap), sshd up, cron up.
Host key SSH guest tidak berubah melewati reboot. Backup
pra-0.2.0: `/root/titian-backup-pre020/` (etc + rc.conf +
live `bird.conf`); backup pra-uji filter: `bird-backup/`
(timestamped per generate).

### 8.2 MikroTik (RouterOS 6.49.19, UNDERTABLE, RB433GL)

Hanya `/routing bgp` yang diubah; interface, address, firewall,
NAT, dan semua bagian lain TIDAK disentuh. Baseline pra-set:
instance "default" as=65530 router-id=0.0.0.0, tanpa peer, tanpa
network.

- Instance `default`: as=65001, router-id=10.10.2.1;
  redistribute-connected/static/rip/ospf/other-bgp = no (tidak
  berubah); out-filter="" (tidak berubah);
  client-to-client-reflection=yes (tidak berubah);
  ignore-as-path-len=no (tidak berubah); routing-table=""
  (tidak berubah)
- Peer `peer-titian`: instance=default,
  remote-address=10.10.2.200, remote-as=65000, hold-time=3m,
  ttl=255, multihop=no, passive=no, address-families=ip,
  default-originate=never, remove-private-as=no, as-override=no,
  use-bfd=no, route-reflect=no, nexthop-choice=default,
  in-filter="" / out-filter="" (tidak berubah), tanpa MD5 —
  status: Established, remote-id=10.10.2.200
- Network: `192.0.2.0/24 synchronize=no` (prefix test; diiklankan
  meski tidak ada di tabel routing MikroTik)

Akses: SSH MikroTik gagal server-side (tidak pernah jalan);
pengelolaan lewat telnet dari host (`-l agoes`). Kredensial
tidak dicatat di dokumen ini (transient, hanya untuk sesi set).

### 8.3 Yang TIDAK terpasang / TIDAK diubah

- File rename (`en-rename.xml`, `titian-rename.sh`) TIDAK
  dipasang ke guest — hanya disiapkan di VM, menunggu perangkat
  multi-NIC (§7).
- Filter community TIDAK ditempel ke bgp_mikrotik (§8.1).
- Alamat uji sudah dihapus bersih sebelum save (alias /31, vlan99,
  ipv6 loopback); pasca-reboot em0 tercatat 10.10.2.200/24.
- Guest export none, sehingga MikroTik tidak menerima rute dari
  guest (sesuai desain).
- Host kopler tidak diubah konfigurasinya dalam pekerjaan BGP ini
  (bhyve/bridge/FIFO hanya penopang lab, bukan set BGP).
