# titian-cli/tree — tree XML Titian (Fase 1)

Basis: **XML rtcli-conf 1.1 pemberian user, yang sudah berjalan normal**.
File dan hierarki view dipertahankan; yang diubah hanya penyesuaian
Fase 1 di bawah. Jangan build ulang tree dari nol.

## Yang diubah dari rtcli (adaptasi)

| File | Perubahan |
|---|---|
| Semua `*.xml` | Path `/opt/rt` -> `/opt/titian` (prefix instalasi baru) |
| `enable-mode.xml` | Entry `bird` / `bird terminal` yang dikomentari di rtcli **diaktifkan kembali** -> view `bird-view` |
| `bird.xml` | Jalur bird.conf lewat helper per-OS (`titian-bird.sh conf-path`); `more` -> `cat` (aman batch); tambah `generate <section>` dan `generate check <section>` |
| `types-dev.xml` | Dulu: `IFACE_DEV` + nama prediktif Debian (`enp1s0`, `eno`, `enx`); `IFACE_ANY` jadi gabungan Linux+FreeBSD (dipakai target route). Sejak 2 Nov 2026: SATU PTYPE terpadu `IFACE_SYS` (charset nama sah, maks 15 karakter) untuk semua parameter interface sistem kedua OS; `IFACE_DEV`/`IFACE_ANY` dihapus; `IFACE_VLAN` (Linux) jadi parent-charset + VID 1-4094 |
| `types-ip6.xml` (baru) | PTYPE IPv6: `IP6_ADDR`, `IP6_ADDR_MASK` (prefix maks /128), `IP6_ADDR_ANY`; plus `IFACE_VLAN_FBSD`, `IFACE_LAGG` (`IFACE_DEV_FBSD` dihapus 2 Nov 2026 — diganti `IFACE_SYS`) |
| `startup.xml` | Banner lewat `titian-sysinfo.sh`; daftar interface (`Get_if_*`) lewat `titian-if-list.sh` (Linux /sys, FreeBSD ifconfig); tambah `Get_if_lagg` |
| `en-show.xml` | `show ip route`/`show interfaces`/`show interfaces ethernet`/`show ip neighbor`/`show service` lewat helper per-OS; `show interfaces` kini menampilkan **inet6** (rtcli sengaja membuangnya); tambah `show ipv6 route`; `more` -> `cat`; perintah show vlan/bonding dipisah ke file sendiri (lihat bawah) |
| `en-show-if-vlan.xml`, `en-show-if-bond.xml` (pisahan) | Isi `show interfaces vlan`/`bonding` dari `en-show.xml` rtcli, tanpa ubahan perilaku; hanya diinstal di Linux |
| `en-show-if-vlan-fbsd.xml`, `en-show-if-lagg.xml` (baru) | Padanan FreeBSD (nama `vlan<N>`, `lagg<N>`); hanya diinstal di FreeBSD |
| `conf-if-eth.xml`, `conf-if-vlan.xml`, `conf-if-bond.xml`, `conf-if-lo.xml` | Tambah `ipv6 address` + `no ipv6 address`; `ip address`/`no ip address`/`ipv6 address` lewat `titian-if.sh` (alasan: logika /31 + peer + persist tidak bisa inline); hook `titian-persist.sh` (mark/sync/drop); `no ip address` di lo kini menghapus tepat alamat yang disebut (rtcli: flush semua — diperbaiki, dicatat) |
| `conf-if-eth-fbsd.xml`, `conf-if-vlan-fbsd.xml`, `conf-if-lagg-fbsd.xml`, `conf-if-lo-fbsd.xml` (baru) | Padanan FreeBSD, struktur disalin dari file Linux: `ifconfig` ganti `ip`; vlan = `interface vlan <id> <parent>` (bukan `parent.tag`); bonding -> `lagg` + `laggport`; `ipv6 address` **tanpa** parameter peer (gated, lihat bawah) |
| `conf-route.xml` | Tidak diubah (Linux, `ip route`) |
| `conf-route-fbsd.xml` (baru) | Padanan FreeBSD (`route(8)`); hanya diinstal di FreeBSD |
| `conf-route6.xml` (baru) | Keluarga `ipv6 route` / `ipv6 default-gateway` / `ipv6 route blackhole` lewat `titian-route.sh` (kedua OS) |
| `conf-sys.xml`, `conf-serv-ssh.xml` | Hostname/timezone/ssh lewat `titian-sys.sh` (cabang OS); backup sshd_config dipertahankan (`-save-titian`) |
| `conf-sys-dns.xml` | Tidak diubah (edit `/etc/resolv.conf` langsung; caveat Debian systemd-resolved lihat bawah) |
| `en-show-hw.xml` | Perintah non-portabel (`free`, `lscpu`, `lspci`, `dmidecode`, `netstat`, `ps axf`) lewat `titian-sys.sh`; pager `|less` dihapus (aman batch) |
| `ping.xml` (+ non-root) | IPv6: `ping6` -> `ping -6`, `traceroute6` -> `traceroute -6` (biner `ping6`/`traceroute6` sudah tidak ada di iputils baru maupun FreeBSD) |
| `tree-nonroot/*` | Path disesuaikan; `lastlog` diberi fallback `last` (FreeBSD tidak punya `lastlog`) |

## Perintah baru (tuning, 30 Okt 2026 — bukan Fase 1)

- `system sysctl <key> <value>` + `no system sysctl <key>` +
  `show system sysctl` — sysctl persisten (Linux
  `/etc/sysctl.d/99-titian.conf`, FreeBSD blok `#-TITIAN-#` di
  `/etc/sysctl.conf`); `no` mengembalikan nilai sebelum-set pertama
  (file `sysctl.titian.prev`).
- `mtu`/`no mtu`, `qlen`/`no qlen` (Linux saja), view `options` +
  `no` form untuk tso/gro/lro/gso/rx/tx/sg/rx-usecs/adaptive-rx —
  lewat `titian-tune.sh` (state `<iface>.tuning` + prev
  `<iface>.tuning.prev`); cermin: Debian `[Link]` networkd,
  FreeBSD suffix rc.conf; boot menjalankan `apply-all` sesudah
  replay. FreeBSD hanya tso/lro/rx/tx (ifconfig); sisanya ditolak.
- `show interfaces tuning <iface>` — nilai live + arti tiap nilai
  (tanda `*` = tercatat Titian).
- Tool read-only `titian-tune-recommend.sh` (wrapper
  `/usr/local/bin/titian-tune-recommend`): rekomendasi per interface
  + perintah CLI persis, profil default router.
- `speed <nilai> [duplex <full|half>]` + `no speed` (Linux saja,
  1 Nov 2026 — penutup celah LACP §16.6 panduan): ethtool live +
  readback, persistensi running-config + `<iface>.tuning` +
  `.tuning.prev`, apply-all boot; keanggotaan bond dicatat
  `<slave>.bond` (`bond-group`/`no bond-group` di
  `titian-persist.sh`) + `attach-bond` sesudah setiap sync +
  `apply-bond` paling akhir di `titian-boot.sh` (networkd
  melepas slave saat reconfigure — bond bukan NetDev, `Bond=`
  diabaikan; lihat panduan §15.5/§16.8).
- **Deploy tree WAJIB per-OS** (COMMON + LINUX_ONLY / FBSD_ONLY):
  copy file asing ke guest lain merusak tree (`Duplicate COMMAND`,
  terbukti 30 Okt 2026).

## Perintah baru (checkpoint + rollback, 2 Nov 2026)

- `checkpoint save <nama>` / `checkpoint list` (+ `show
  checkpoints`) / `checkpoint delete <nama>` / `rollback
  <nama>` / `rollback` polos (exec view) — titik simpan bernama
  + rollback PERSISTEN (menulis startup-config, restart service,
  `birdc configure`). Snapshot di
  `/opt/titian/etc/checkpoints/<nama>/` (running-config tanpa
  stempel + bird.conf + bird.d + netstate + sysctl + meta);
  `save` juga menulis titik tersembunyi `.last-save` untuk
  rollback polos. Detail + bukti + insiden cermin enp1s0 +
  pelajaran urutan prune: panduan §18. File baru
  `en-checkpoint.xml` (COMMON) + `sbin/titian-checkpoint.sh`;
  guard `sync_debian` di `titian-persist.sh` (jangan buat cermin
  untuk interface tanpa state titian).

## Perintah baru (PTYPE terpadu + rename, 2 Nov 2026)

- PTYPE interface terpadu `IFACE_SYS` (COMMON, kedua OS): charset
  nama interface yang sah (maks 15 karakter, tanpa `/`, spasi,
  `:`, awalan `.`/`-`) — menggantikan pola nama per-OS
  (`IFACE_DEV`/`IFACE_DEV_FBSD`/`IFACE_ANY` dihapus). Keberadaan
  interface dicek helper ACTION (gagal lantang + petunjuk
  `show interfaces`, tanpa perubahan state). Completion kategori
  `eth` di `titian-if-list.sh` kini exclusion-based (semua interface
  sistem kecuali lo + objek Titian bond/lagg/vlan/vxlan + nama
  bertitik di Linux) sehingga interface hasil rename MUNCUL di
  completion. Model romawi kecepatan (`e` = Ethernet): xe = 10G,
  xxve = 25G, xle = 40G (permintaan user), le = 50G, ce = 100G,
  cce = 200G, cde = 400G (ekstensi model). Objek buatan Titian
  (bond/vxlan/lagg/vlan) tetap PTYPE nama Titian — rename objek
  Titian di level OS bukan operasi yang didukung.
- `rename <lama> <baru>` (exec view, [L+F]) — ganti nama interface
  sistem + migrasi state Titian (netstate, cermin, startup-config
  termasuk section interface, `laggport`, token parent VLAN, route
  dev, vxlan group dev) + restart service. PERSISTEN melewati
  reboot: Linux `.link` (match MAC → Name), FreeBSD
  `ifconfig_<asal>_name` di blok `#-TITIAN-RENAME-#` rc.conf.
  Validasi gagal lantang: lama harus ada, baru lolos `IFACE_SYS` +
  belum dipakai, tolak namespace objek/loopback/nama bertitik, tolak
  state live yang belum di-`save` ("save dulu"). JANGAN rename
  interface mgmt/produksi. Detail + bukti + batas (PTY, vlan
  FreeBSD intermiten): panduan §19. File baru `en-rename.xml`
  (COMMON) + `sbin/titian-rename.sh`.

## Perintah baru (VXLAN, 1 Nov 2026 — bukan Fase 1)

- `interface vxlan <vxlan[N]>` (view `configure-vxlan-view` /
  `configure-vxlan-fbsd-view`) + `vni <1-16777215>` +
  `local <VTEP>` + `remote <VTEP-peer>` (unicast) ATAU
  `group <mcast> dev <iface>` (multicast) + `dstport` +
  `mtu` + `ip address` + `ipv6 address` (FreeBSD: tanpa peer) +
  `no` form lengkap + `show interfaces vxlan [<nama>]` —
  lewat `titian-vxlan.sh` (state `<iface>.vxlan`).
- Model: setiap ubah vni/local/remote/group/dstport = recreate
  interface dari netstate (Linux: id/dstport tak bisa diubah
  live; FreeBSD: tanpa negasi -vxlan*; dstport FreeBSD tetap
  4789, nilai lain ditolak). Alamat dipulihkan dari
  `<iface>.addr`, MTU dari `<iface>.tuning`, up-state dipulihkan.
  MAC stabil per nama di lab (terbukti hapus+buat ulang +
  reboot). Cermin: Debian `00-titian-<iface>.network`, FreeBSD
  rc.conf `#-TITIAN-#`; boot: kldload if_vxlan sebelum replay
  (FreeBSD) + `apply-vxlan` sesudah `apply-bond`.
  `drop-if` juga menghapus `<iface>.vxlan`.
- Deploy per-OS: Linux `conf-if-vxlan.xml` +
  `en-show-if-vxlan.xml`; FreeBSD `conf-if-vxlan-fbsd.xml` +
  `en-show-if-vxlan-fbsd.xml`; COMMON `types-dev.xml`
  (IFACE_VXLAN, VNI_ID, DSTPORT) + `startup.xml`
  (Get_if_vxlan). Detail + bukti: panduan §17.

## Perintah baru (Fase 1)

- `ip address <A.B.C.D/M> [peer <peer-IP>]` — di semua if-view (eth/vlan/bond/lo/lagg).
  PtP custom gaya MikroTik/PPP: `ip address 103.50.128.1/32 peer 10.10.10.10`
  (bentuk bare-IP tanpa `/prefix` juga diterima sejak perbaikan validator,
  lihat bawah). Terjemahan: Linux `ip addr add <local> peer <peer>`;
  FreeBSD **/32 lokal + `route add -host <peer> -iface <iface>`**
  (bukan destination-address ifconfig — terbukti diabaikan diam-diam
  di interface Ethernet broadcast, lihat "Perbaikan E2E").
- `ipv6 address <addr/M>` — di semua if-view (Linux: `ip -6`; FreeBSD: `ifconfig inet6`).
  Peer IPv6 hanya di Linux (FreeBSD: perintah tidak punya parameter peer — gated).
- `ipv6 route`, `ipv6 default-gateway`, `ipv6 route blackhole` (+ bentuk `no`).
- `bird terminal` -> `generate <section>` / `generate check <section>`
  (section: function, filter, protocol, static, bgp, ospf).
- `show ipv6 route`, `show interfaces lagg` (FreeBSD), `show interfaces vlan` (FreeBSD).

## Pengalamatan hemat IP (persyaratan wajib Fase 1)

- **/31 (RFC 3021)**: validator PTYPE lama sudah mengizinkan /0–/32, jadi
  /31 tidak pernah ditolak parser. Eksekusi: Linux **tanpa** `brd +`
  (kernel menangani /31 sebagai dua host); FreeBSD `ifconfig .../31`
  apa adanya. Uji nyata di kedua VM: set /31 -> tampil di show +
  route connected /31 terbentuk.
- **PtP**: 1 IP publik per link (bandingkan /30 yang membuang 2 dari 4
  alamat untuk network+broadcast, /31 memakai 2 dari 2).
- **Catatan verifikasi CONFIG peer: TERBUKTI PULIH (28 Okt, kedua VM).**
  `save` menyimpan baris penuh termasuk peer (`ip address 203.0.113.77
  peer 10.44.55.66`) karena `splitter="false"`, dan replay boot-style
  memulihkan alamat + (FreeBSD) host route ke peer. Pivot bare-CONFIG
  TIDAK diperlukan.

## Perbaikan E2E (ditemukan saat uji CLI, semua sudah di tree/skrip)

- **Parent IPv6:** klish menuntut setiap prefiks progresif terdefinisi —
  `ipv6 address`/`show ipv6 route` gagal karena parent telanjang `ipv6`
  /`show ipv6` tidak ada. Tambah perintah parent help-only di semua
  if-view + configure-view + enable-view (pola parent `ip` yang sudah ada).
- **IFACE_VLAN prediktif:** tambah `enp/eno/enx` ke `IFACE_VLAN` +
  `IFACE_ANY` (sebelumnya hanya `eth/ens/ge/xe`).
- **Networkd vs netplan:** file titian `20-` kalah leksikal dari
  `10-netplan-id0.network` → pakai `00-titian-*.network`; `mark-if`
  ditambahkan ke `interface ethernet` (sebelumnya hanya vlan/bond/lo).
- **Validator PtP bare-IP:** ptype baru `IP_ADDR_MASK_OPT` (types-dev)
  + `IP6_ADDR_MASK_OPT` (types-ip6): IP + `/prefix` opsional (bare =
  /32 v4, /128 v6). Dipakai param `ip` pada `ip/ipv6 address` + `no`
  di semua file if-view (bukan pada route — route tetap wajib CIDR).
- **state_del baris terakhir:** `grep -v ... && mv` gagal saat file
  hanya berisi baris yang dihapus (grep exit 1) → `;` + `|| true`.
- **PtP FreeBSD (koreksi mekanisme):** destination-address ifconfig
  diabaikan diam-diam di Ethernet broadcast (hasil: broadcast=local,
  tanpa route, ping 100% loss). Mekanisme benar: `/32` + host route
  via interface; guard `route get` tidak valid (fallback default
  route) → hapus dulu lalu tambah. Persistensi rc.conf: `ifconfig`
  = /32 + `route_titian_p<N>` + `static_routes` di-MERGE dengan nilai
  lama di luar blok titian.
- **FreeBSD bird_enable:** installer menulis `bird_enable="YES"` ke
  rc.conf (daemon harus jalan untuk `birdc configure`).
- **Hapus VLAN FreeBSD:** `no interface vlan <id>` saja (tanpa parent;
  parent hanya saat membuat).

## Capability gating (instalasi per-OS)

Installer (`install/titian-install.sh`) merakit tree dari daftar file:

- Common (kedua OS): `bird.xml common.xml conf-route6.xml
  conf-serv-ssh.xml conf-sys-dns.xml conf-sys.xml configure-mode.xml
  en-show.xml en-show-hw.xml enable-mode.xml ping.xml startup.xml
  types.xml types-dev.xml types-ip6.xml`
- Linux saja: `conf-if-bond.xml conf-if-eth.xml conf-if-eth-opt.xml
  conf-if-lo.xml conf-if-vlan.xml conf-route.xml en-show-if-vlan.xml
  en-show-if-bond.xml`
- FreeBSD saja: `conf-if-eth-fbsd.xml conf-if-vlan-fbsd.xml
  conf-if-lagg-fbsd.xml conf-if-lo-fbsd.xml conf-route-fbsd.xml
  en-show-if-vlan-fbsd.xml en-show-if-lagg.xml`

Perintah yang tidak didukung satu OS **tidak muncul** di OS itu
(bonding/eth-opt hanya Linux; lagg hanya FreeBSD). Pengecualian yang
disengaja: sub-opsi `arp` pada `ping` tetap ada di kedua OS (FreeBSD
tanpa biner `arping` akan gagal bersih dengan pesan, bukan diam);
`ipv6 address peer` hanya ada di file Linux.

## Persistensi (keputusan default Fase 1)

1. **Utama (kedua OS): replay startup-config saat boot** (model rtcli:
   service titian menjalankan konfd lalu `clish -w configure-view
   startup-config`). Perintah CLI idempotent (`replace`/`change-or-add`).
2. **Cermin deklaratif (keputusan default yang diminta)**:
   - Debian: `/etc/systemd/network/00-titian-<iface>.network` untuk
     interface yang dibuat titian saja (NIC sistem tidak pernah ditulis;
     prefix `00-` agar menang leksikal atas `10-netplan-*.network`).
   - FreeBSD: blok marker `#-TITIAN-# ... #-ENDTITIAN-#` di `/etc/rc.conf`
     (baris di luar blok tidak disentuh; backup + `sh -n` tiap tulis).
   - Sumber cermin = state file `netstate/<iface>.addr` yang ditulis
     `titian-if.sh`, bukan parsing output tool.
   - Uji reboot E2E yang memutuskan apakah networkd + replay bisa
     berdampingan; bila konflik, networkd dinonaktifkan sebagai applier
     (file tetap sebagai cermin) dan replay menjadi satu-satunya applier.

## Caveat yang diketahui

- Debian `/etc/resolv.conf` yang dikelola systemd-resolved (symlink stub):
  perintah `system name-servers` menulis langsung ke file itu (perilaku
  rtcli). Di host resolved-managed, perubahan bisa tertimpa restart
  resolved — Fase 2: tulis via `resolvectl`/`resolved.conf` bila perlu.
- `system hostname` di Debian cloud-init: cloud-init bisa menulis ulang
  hostname saat boot berikutnya (tergantung `preserve_hostname`).
- BIRD lab: `protocol kernel` memakai `import none; export none`
  (BIRD tidak menyentuh tabel kernel) dan contoh BGP/OSPF/static memakai
  `import none; export none` — aman lab, bukan setelan produksi.
- Helper `titian-sys.sh` (hostname/timezone/ssh/dns) diimplementasi
  penuh tapi **tidak masuk daftar uji E2E Fase 1** (di luar cakupan
  butir uji yang ditetapkan); statusnya: terpasang, belum teruji E2E.
