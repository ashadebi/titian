# Titian/klish untuk BSDRP — Daftar Fitur (spesifikasi port)

Perintah user 11 Nov 19:52 WIB: masukkan Titian (klish) FreeBSD ke image BSDRP,
support semua yang pernah diobrolin. Daftar ini = spesifikasi port. Status per
11 Nov 19:52. Yang "terbukti" = sudah lulus uji live/staging; yang "pending"
= menunggu hardware/uji.

## 1. CLI Inti (klish 0.2.0)
- Masuk: perintah `titian` (full path `/usr/local/bin/titian`), prompt `cli-<hostname>#`
- Gaya Cisco/Junos (mode config + show). `commit` = tulis file + restart service
  (service langsung naik). `save` = `config save`. `commit` TIDAK memanggil
  `config apply` (stub).
- Single-engine: binary klish satu-satunya lapisan query/eksekusi.
- `show` untuk semua status; `system logs clear`, `show disk`.
- Hostname, timezone WIB, boot logo merah-putih + version + hostname.

## 2. Routing — BIRD (BGP)
- BIRD2 + BIRD3 (switch BIRD_VERSION, default 2).
- `bird terminal` → view `(birdc)#`.
- Show BGP: status, neighbor, route, community filter (65000:100 TERBUKTI live
  ke MikroTik AS65001, BGP Established).
- BFD + RPKI (CLEAR, berkualifikasi; BFD single-hop test masih pending).
- PtP live (Opsi B) — config via klish; uji live menunggu hardware multi-NIC.
- ATURAN KERAS: BIRD dan FRR TIDAK BOLEH aktif bersamaan — klish deteksi +
  blokir keras saat commit.

## 3. Routing — FRR
- FRR (net/frr10) dikelola via klish (config + start/stop + auto-start).
- CLI FRR sendiri tetap `vtysh` (saat ini via perintah `cli`) — tidak diganggu.
- Mutual exclusion dengan BIRD (lihat §2).
- Penanganan bentrok: Titian dipanggil via full path `/usr/local/bin/titian`
  (alias `titian`); `cli` tetap milik FRR (vtysh). Tidak ada tabrakan nama.

## 4. Firewall & NAT (pf)
- Model Titian terbukti: rule diidentifikasi isi, rebuild penuh, forward
  default DENY. DNAT butuh forward permit ke tujuan TERJEMAHAN.
  Check-before-load.
- Chain output bisa dipakai (in=any + out=iface).
- Guard anti-lockout: protected interface (default em0) — config MENOLAK rule
  yang memakai iface itu.
- pf.conf dasar (nat-anchor + rdr-anchor + anchor firewall + anchor
  traffic-shape). Firewall + NAT via klish.

## 5. Limiter / QoS (dummynet)
- Token bucket + WF2Q+, HZ 1000.
- Backend `ipfw` pipe + pf `dnpipe` (utilitas `dnctl` TIDAK ADA di FreeBSD ini).
- Pipe 1–99, queue 100–199, sched 200–299. Sched objek terpisah
  (fifo/wf2q+/rr/qfq/fq_codel/fq_pie); bw sebelum type; klausa AQM wajib
  paling akhir.
- Mask lengkap (dst-ip/src-ip/dst-ip6/src-ip6/dst-port/src-port/proto/
  flow-id/all). AQM + burst. Traffic-shape via klish.

## 6. LACP/LAGG & VXLAN
- LACP/LAGG (bonding) via klish — uji live vs MikroTik menunggu hardware
  (router 2 NIC, MikroTik 2 port bebas, 2 kabel sama kecepatan, 2 endpoint
  iperf3).
- VXLAN via klish — multicast end-to-end BELUM TERBUKTI (jangan diklaim).

## 7. PPPoE & WireGuard
- PPPoE server via klish (mpd5 5.9_19, netgraph, RADIUS, tanpa CoA).
- WireGuard native + management via klish (server, default manual).

## 8. Interface & Sistem
- Interface config (em0/igb/ixl/dll), IP, default route, rename
  (persistensi reboot — Titian sudah; BSDRP menunggu uji).
- em0 10.9.8.7/24 (default image, sesuai kesepakatan).
- `config save` (persistensi; root read-only, config hanya di /etc +
  /usr/local/etc).

## 9. Monitoring (support, TAPI OFF by default)
- SNMP (net-snmp, community bsdrp-ro — ganti sebelum expose),
  node_exporter (:9100), bird_exporter (:9324), nfacctd/pmacct.
- Semua OFF by default di image ini (hanya em0+SSH+Titian yang nyala);
  bisa di-ON-kan via klish bila perlu.

## 10. TIDAK termasuk (eksplisit)
- VPP (SKIP — keputusan user; tidak jalan normal di FreeBSD).
- wg-easy (butuh Docker — tidak native).
- Web dashboard Titian (komponen terpisah, DITAHAN — bukan bagian port CLI ini).
- FRR + BIRD bersamaan (saling eksklusif, diblokir klish).

## Service yang nyala (default image dengan Titian)
- em0 10.9.8.7/24 + sshd + Titian/klish. Sisanya OFF (snmpd, node_exporter,
  bird_exporter, nfacctd, bird, FRR, VPP, pimd, ngnetflow).

## Banner boot (VGA vs bhyve)
- bhyve = konsol serial (teks 80 kolom); monitor nyata = VGA (menu loader
  berupa kotak). Art ASCII 36 lebar × 18 baris overlap kotak menu di VGA
  ("berantakan", kosmetik).
- Perbaikan: sesuaikan art/loader (lebar/posisi) + set mode konsol supaya
  tampilan VGA sama dengan serial (bhyve). Butuh foto monitor user untuk
  melihat overlap-nya. Masuk build berikutnya (file brand di repo).
