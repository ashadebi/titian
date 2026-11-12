# Titian CLI — sumber (source)

Sumber Titian/klish yang dipasang port `net/titian` ke `/opt/titian/` di image
BSDRP. Ini file yang sama dengan yang di-vendor port sebagai payload — tapi
di sini sebagai file mandiri, supaya bisa dibaca, di-review, dan diedit
tanpa harus mengekstrak shar.

## Isi

- `tree/` — 36 file XML definisi perintah klish.
  Dipasang ke `/opt/titian/etc/clish-en/` di image. Meliputi: perintah inti
  (`startup.xml`, `enable-mode.xml`, `configure-mode.xml`, `conf-commit.xml`),
  routing BIRD (`bird.xml`, `en-show-routing.xml`), FRR (`conf-frr.xml`),
  firewall/NAT pf (`conf-fw.xml`), limiter dummynet (`traffic-shape.xml`),
  PPPoE (`conf-pppoe.xml`), WireGuard (`conf-wireguard.xml`),
  monitoring (`conf-monitoring.xml`), interface/route/sistem
  (`conf-if-*.xml`, `conf-route*.xml`, `conf-sys*.xml`, `en-show*.xml`,
  `conf-serv-ssh.xml`, `ping.xml`, `types*.xml`, `common.xml`).
- `sbin/` — 24 script backend (POSIX sh) yang dipanggil XML.
  Dipasang ke `/opt/titian/sbin/` di image. Contoh: `titian-bird.sh`,
  `titian-frr.sh`, `titian-fw.sh`, `titian-traffic-shape.sh`,
  `titian-pppoe.sh`, `titian-wireguard.sh`, `titian-monitoring.sh`,
  `titian-commit.sh`, `titian-route.sh`, `titian-if.sh`.

## Hubungan dengan port (shar)

Port `net/titian` ada di `files/BSDRP/patches/ports.titian.shar`. Shar itu
mem-vendor file XML + sbin **yang sama** sebagai payload port — saat build
BSDRP, Makefile mengekstrak shar jadi port lokal, lalu port menginstal
file-file ini ke `/opt/titian/` di image.

**Kalau mengedit XML/sbin di sini, shar-nya ikut ketinggalan.**
Supaya build memakai versi terbaru, update juga
`files/BSDRP/patches/ports.titian.shar` (rebuild shar dari sumber ini),
atau catat di commit message bahwa shar perlu di-rebuild dari `titian/`.

## Versi

- klish upstream: **2.2.5** (bukan "0.2.0" — itu label image BSDRP lama).
- Paket Titian: **0.1.0**.
- Port FreeBSD `net/titian` resmi **tidak ada** — ini port lokal yang
  dibuat sendiri di repo BSDRP (bukan diajukan ke FreeBSD ports).
  MAINTAINER di port masih placeholder (`titian@bsdrp.local`) — ganti
  sebelum submit ke mana pun.
