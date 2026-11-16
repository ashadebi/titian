# BIRD-COVERAGE.md — Gap Analysis Program BIRD (FASE 1)

- **Tanggal:** 2026-11-16 WIB
- **Sumber baca:** BIRD User's Guide 2.16.1 — https://bird.network.cz/?get_doc&f=bird.html&v=20
- **File READ (FASE 0 + B0):** `BIRD-READ-ch23-config.md` (103 item) · `BIRD-READ-ch5-filters.md` (166) · `BIRD-READ-ch6-bgp.md` (145 unik) · `BIRD-READ-ch6-ospf-rip-static.md` (176) · `BIRD-READ-ch6-other-birdc.md` (155)
- **Staging yang diperiksa:** `~/workspace/titian-bsdRP-xml/` — `tree/*.xml`, `sbin/*.sh`, `etc/bird.d/*.conf` (dibaca langsung, bukan dari ingatan). Pasca-B9: `verify.py` = 56 XML / 53 PTYPE / 72 VIEW / 1958 COMMAND, NOL error. **Pasca-FASE 3 (16 Nov 2026, lihat §8): `verify.py` = 56 XML / 53 PTYPE / 72 VIEW / 1953 COMMAND, NOL error** (turun 5: −4 `tx-class`/`tx-dscp` BGP di F3.2, −1 `show route filter` di F3.10).
- **Aturan penugasan:** FASE 1 HANYA baca + tulis file ini. Tidak ada file staging lain yang diubah, tidak ada mesin test yang disentuh, tidak ada implementasi.
- **Revisi 2026-11-16 WIB (file ini saja):** Batch B0 (baca ulang: Perf/RAdv/RPKI/Bab 4 + OSPF L4200-4866, 16 Nov 07:56 WIB) + Batch B4 (Static/Direct/Pipe/Kernel/Device di staging). Total item 647 -> 729. Batch B3 (RIP) selesai di staging. Refresh pasca-B1/B2/B3/B5/B6/B7/B8/B9 + BFD 16 Nov (lihat §6): total tetap 729.
- **Perintah program BIRD (user 16 Nov 07:38):** baca docs BIRD 2.16.1 mendetail, implementasikan setiap detailnya ke Titian, test ke RB3011, jangan berhenti; penambahan fitur TIDAK BOLEH merubah yang sudah run normal (regression check tiap batch: `verify.py` + live re-verify anchor: BGP Established, show, commit/save).

## Konvensi status

| Status | Arti |
|---|---|
| DONE | Perintah klish + intent file + generate ke bird.conf SEMUA ada dan konsisten. |
| PARTIAL | Hanya tersedia via raw section (`bird terminal` / contoh `etc/bird.d/*.conf` + `generate <section>`) ATAU hanya sebagian aspek (mis. set di export ada, match di import belum). |
| MISSING | Tidak ada perintah klish maupun raw section yang memadai. |
| N/A | Tidak relevan untuk router ini — alasan satu baris di kolom catatan. |
| IN PROGRESS | BFD (17 item): dikerjakan subagent terpisah di staging — JANGAN dihitung MISSING, JANGAN diimplementasi, JANGAN duplikasi. |
| BELUM TERVERIFIKASI | Item OSPF yang sintaksnya sah (template L3781-3977) tapi default/penjelasan hilang karena 429 di L4200-4866 — JANGAN ditebak defaultnya. |
| BELUM DIBACA | Bab belum dibaca karena 429 — lokasi baca ulang persis ada di §3. |
| PERLU VERIFIKASI | Ragu satu item — alasan di kolom catatan; jangan dipaksakan DONE/MISSING. |

**Prioritas:** P1 = BGP/OSPF/BFD/RIP/static/direct/pipe/kernel/device/filter (inti routing + bisa diuji vs RB3011). P2 = sisanya yang bisa diuji vs RB3011 atau lokal. P3 = butuh peer/server khusus (RPKI cache, BMP station, peer Babel, peer VPN+MPLS+VRF) atau eksperimental berat (MPLS).

**Catatan verifikasi ulang vs file READ:** status di file READ TIDAK disalin mentah — semua status dicek ulang ke kode staging. Koreksi yang ditemukan (detail di §4):

- **BGP `bfd on/graceful` (BGP-17): BELUM -> DONE.** `neighbor bfd` / `bfd graceful` / `no bfd` ada di `tree/conf-bgp.xml`; `sbin/titian-bgp.sh` generate menulis `bfd on;` / `bfd graceful;` dan memaksa section BFD ter-generate dulu. Bergantung `protocol bfd` (IN PROGRESS terpisah).
- **`bgp_ext_community` / `bgp_large_community` (ch5 No. 24/25/30/31/70/71/87/88, BGP-119/120): BELUM -> PARTIAL.** `sbin/titian-comm.sh` sudah mendukung `rt:AA:NN` / `ro:AA:NN` / `large:AA:X:NN` + well-known (`no-export`, `no-advertise`, `no-peer`, `blackhole`): `.add()` di export + match `if (....) ~ bgp_ext_community / bgp_large_community` di import. Delete/set belum.
- **`bgp_local_pref` / `bgp_med` (ch5 No. 149/150, BGP-112/113): ADA -> PARTIAL.** Set export sudah ada, DAN set import-match via community sudah ada (`community import add <COMM> localpref:N | med:N`, titian-comm.sh). Yang belum: MATCH nilai (`if bgp_local_pref = N`).
- **`(pair) ~ bgp_community` (ch5 No. 102): SEBAGIAN -> DONE.** Bentuk ini persis yang digenerate `titian-comm.sh` import-add.
- **`define` (ch5 No. 40): BELUM -> PARTIAL.** `community list add` menulis `define NAME = (AA,NN);` — hanya literal pair.
- **`import/export limit` (BGP-129): PERLU VERIFIKASI -> MISSING (terjawab).** Sintaks + default + perilaku sudah ada di Bab 3.5 (3.5-8/9/10 di file ini) karena Bab 3 sudah dibaca di FASE 0 ch23 — bukan lagi belum terverifikasi.
- **`net_is_private()` (ch5 No. 9) tetap PARTIAL:** fungsi didefinisikan di `etc/bird.d/function.conf` tapi grep staging menunjukkan TIDAK PERNAH dipanggil dari filter mana pun.
- **OSPF `❓` di READ file: 43 item, bukan 41** seperti disebut di penugasan (O18-O23 = 6, O25-O51 = 27, O53-O59 = 7, O60-O62 = 3). Daftar lengkap di §3.
- **OSPF BIRD vs OSPF FRR:** `tree/conf-frr.xml` (151 COMMAND, `router ospf` FRR lengkap 15 Nov) adalah daemon BERBEDA dan TIDAK dihitung sebagai dukungan OSPF BIRD di file ini.

## 1. Ringkasan hitungan

**Total item terekstrak: 729** (647 FASE 1 + 82 baru dari B0: Perf 6 + RAdv 37 + RPKI 19 + Bab 4 birdc 18 + OSPF 2. Catatan hitungan: file BIRD-READ-ch6-other-birdc.md tumbuh 59 -> 155 (+96), tapi 16 dari 34 perintah birdc di Bab 4.3 sudah tercakup sebagai BGP-130..146 di file BIRD-READ-ch6-bgp.md — yang ditambahkan ke tabel ini hanya 18 perintah birdc yang benar-benar baru (4.1: 5 + 4.2: 3 + 4.3: 10), sehingga total program = 729, bukan 745. Lihat §3a.)

### 1a. Per status (keseluruhan)

| Status | Jumlah | % |
|---|---|---:|
| DONE | 601 | 82.4% |
| PARTIAL | 53 | 7.3% |
| MISSING | 30 | 4.1% |
| N/A | 35 | 4.8% |
| IN PROGRESS | 7 | 1.0% |
| BELUM TERVERIFIKASI | 0 | 0.0% |
| PERLU VERIFIKASI | 3 | 0.4% |
| **Total** | **729** | 100% |

### 1b. Per prioritas (keseluruhan)

| Prioritas | Jumlah | % |
|---|---|---:|
| P1 | 415 | 56.9% |
| P2 | 173 | 23.7% |
| P3 | 141 | 19.3% |
| **Total** | **729** | 100% |

### 1c. Per bab docs

| Bab docs | DONE | PARTIAL | MISSING | N/A | IN PROGRESS | BELUM TERVERIFIKASI | PERLU VERIFIKASI | Total |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Bab 2 + Bab 3 (config & arsitektur) | 73 | 26 | 1 | 3 | 0 | 0 | 0 | 103 |
| Bab 5 (Filters) | 134 | 16 | 16 | 0 | 0 | 0 | 0 | 166 |
| Bab 6.4 BGP + Bab 4.3 birdc (BGP) | 137 | 3 | 3 | 1 | 0 | 0 | 1 | 145 |
| Bab 6 OSPF/RIP/Static/Kernel/BFD/Device/Direct/Pipe | 147 | 6 | 6 | 8 | 7 | 0 | 2 | 176 |
| Bab 6 Aggregator/Babel/BMP/L3VPN/MRT/Perf/RAdv/RPKI | 98 | 0 | 1 | 22 | 0 | 0 | 0 | 121 |
| Bab 4 birdc (4.1/4.2/4.3 baru) | 12 | 2 | 3 | 1 | 0 | 0 | 0 | 18 |
| **Total** | **601** | **53** | **30** | **35** | **7** | **0** | **3** | **729** |

### 1d. Per status × prioritas

| Status \ Prioritas | P1 | P2 | P3 | Total |
|---|---:|---:|---:|---:|
| DONE | 349 | 156 | 96 | 601 |
| PARTIAL | 42 | 4 | 7 | 53 |
| MISSING | 15 | 12 | 3 | 30 |
| N/A | 0 | 0 | 35 | 35 |
| IN PROGRESS | 7 | 0 | 0 | 7 |
| BELUM TERVERIFIKASI | 0 | 0 | 0 | 0 |
| PERLU VERIFIKASI | 2 | 1 | 0 | 3 |
| **Total** | **415** | **173** | **141** | **729** |

### 1e. Per sub-bab (detail)

| Sub-bab | DONE | PARTIAL | MISSING | N/A | IN PROGRESS | BELUM TERVERIFIKASI | PERLU VERIFIKASI | Total |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| ch23 / 2.1 | 3 | 2 | 0 | 0 | 0 | 0 | 0 | 5 |
| ch23 / 2.2 | 11 | 1 | 0 | 0 | 0 | 0 | 0 | 12 |
| ch23 / 2.3 | 3 | 1 | 0 | 0 | 0 | 0 | 0 | 4 |
| ch23 / 2.4 | 2 | 1 | 0 | 0 | 0 | 0 | 0 | 3 |
| ch23 / 2.5 | 4 | 1 | 0 | 0 | 0 | 0 | 0 | 5 |
| ch23 / 3.1 | 4 | 1 | 1 | 0 | 0 | 0 | 0 | 6 |
| ch23 / 3.2 | 23 | 2 | 0 | 1 | 0 | 0 | 0 | 26 |
| ch23 / 3.3 | 7 | 0 | 0 | 0 | 0 | 0 | 0 | 7 |
| ch23 / 3.4 | 3 | 14 | 0 | 2 | 0 | 0 | 0 | 19 |
| ch23 / 3.5 | 7 | 3 | 0 | 0 | 0 | 0 | 0 | 10 |
| ch23 / 3.6 | 6 | 0 | 0 | 0 | 0 | 0 | 0 | 6 |
| ch5 / 5.1 | 10 | 2 | 2 | 0 | 0 | 0 | 0 | 14 |
| ch5 / 5.2 | 65 | 4 | 6 | 0 | 0 | 0 | 0 | 75 |
| ch5 / 5.3 | 14 | 4 | 3 | 0 | 0 | 0 | 0 | 21 |
| ch5 / 5.4 | 8 | 0 | 0 | 0 | 0 | 0 | 0 | 8 |
| ch5 / 5.5 | 20 | 4 | 3 | 0 | 0 | 0 | 0 | 27 |
| ch5 / 5.5G | 7 | 0 | 0 | 0 | 0 | 0 | 0 | 7 |
| ch5 / 5.6 | 4 | 0 | 2 | 0 | 0 | 0 | 0 | 6 |
| ch5 / 5.contoh | 6 | 2 | 0 | 0 | 0 | 0 | 0 | 8 |
| ch6-bgp / 4.3 | 14 | 2 | 0 | 1 | 0 | 0 | 0 | 17 |
| ch6-bgp / 6.4 | 123 | 1 | 3 | 0 | 0 | 0 | 1 | 128 |
| ch6-ospf-rip-static / 6.11 | 62 | 3 | 2 | 0 | 0 | 0 | 1 | 68 |
| ch6-ospf-rip-static / 6.13 | 3 | 2 | 0 | 0 | 0 | 0 | 0 | 5 |
| ch6-ospf-rip-static / 6.15 | 28 | 0 | 1 | 0 | 0 | 0 | 1 | 30 |
| ch6-ospf-rip-static / 6.17 | 29 | 1 | 2 | 0 | 0 | 0 | 0 | 32 |
| ch6-ospf-rip-static / 6.3 | 10 | 0 | 0 | 0 | 7 | 0 | 0 | 17 |
| ch6-ospf-rip-static / 6.6 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 4 |
| ch6-ospf-rip-static / 6.7 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 4 |
| ch6-ospf-rip-static / 6.8 | 7 | 0 | 1 | 8 | 0 | 0 | 0 | 16 |
| ch6-other / 6.1 | 0 | 0 | 0 | 6 | 0 | 0 | 0 | 6 |
| ch6-other / 6.10 | 6 | 0 | 0 | 0 | 0 | 0 | 0 | 6 |
| ch6-other / 6.2 | 32 | 0 | 1 | 0 | 0 | 0 | 0 | 33 |
| ch6-other / 6.5 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 4 |
| ch6-other / 6.9 | 0 | 0 | 0 | 10 | 0 | 0 | 0 | 10 |
| ch6-other / 6.12 | 0 | 0 | 0 | 6 | 0 | 0 | 0 | 6 |
| ch6-other / 6.14 | 37 | 0 | 0 | 0 | 0 | 0 | 0 | 37 |
| ch6-other / 6.16 | 19 | 0 | 0 | 0 | 0 | 0 | 0 | 19 |
| Bab 4 / 4.1 | 0 | 1 | 3 | 1 | 0 | 0 | 0 | 5 |
| Bab 4 / 4.2 | 2 | 1 | 0 | 0 | 0 | 0 | 0 | 3 |
| Bab 4 / 4.3 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 10 |

**Bacaan angka (revisi B1–B9 + BFD):** 601 DONE (82.4%) + 53 PARTIAL (7.3%) = 654 item (89.7%) sudah punya wujud di Titian; 30 MISSING (4.1%) tersisa — hampir semua bukan pekerjaan implementasi (deprecated / Linux-only / tidak bisa diakses dari filter / belum terverifikasi). BFD 7 item IN PROGRESS bukan MISSING (subagent terpisah). PERLU VERIFIKASI 3 item menunggu `bird -p` live. Detail per batch di §6.

## 2. Tabel lengkap semua item

Kolom catatan menyebut lokasi kode Titian bila DONE/PARTIAL (file + perintah/fungsi), atau alasan bila N/A / BELUM TERVERIFIKASI / PERLU VERIFIKASI.

### 2.1 Bab 2 + Bab 3 (config & arsitektur)

| Item | Sintaks BIRD | Bab docs | Status | Prioritas | Catatan |
|---|---|---|---|---|---|
| 3.1-1 | bird.conf + reload (SIGHUP) | 3.1 | PARTIAL | P1 | Reload via `birdc configure` di `generate` (sbin/titian-bird.sh); SIGHUP tidak diekspos klish. |
| 3.1-2 | # ... / /* ... */ | 3.1 | DONE | P1 | Generator menulis komentar (`# network ...`, header section). |
| 3.1-3 | { ... }, tiap opsi diakhiri ; | 3.1 | DONE | P1 | Semua generator menulis blok + terminator `;`. |
| 3.1-4 | case-sensitive | 3.1 | DONE | P1 | Perilaku bawaan BIRD; generator tidak mengubah case. |
| 3.1-5 | simbol R123, my_filter, bgp5 | 3.1 | DONE | P1 | `bird_ident()` di sbin/titian-bgp.sh (tr `-` ke `_`). |
| 3.1-6 | simbol quoted '1:strange-name' | 3.1 | MISSING | P1 | `bird_ident()` justru mengubah `-`/karakter lain jadi `_`; quoted name tidak didukung. |
| 3.2-1 | include "filename"; | 3.2 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-2 | log "file" [limit ..] \| syslog \| stderr \| udp ... | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-3 | debug protocols all\|off\|{...} | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-4 | debug channels all\|off\|{...} | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-5 | debug tables all\|off\|{...} | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-6 | debug commands number | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-7 | debug latency switch | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-8 | debug latency limit time | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-9 | watchdog warning time | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-10 | watchdog timeout time | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-11 | mrtdump "filename" | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-12 | mrtdump protocols all\|off\|{...} | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (log/debug/watchdog/mrtdump global). |
| 3.2-13 | filter name { commands } | 3.2 | DONE | P1 | DONE (B5): definisi filter bernama + bahasa filter umum kini penuh (filter <NAME> + statement/filter-view, BIRD-B5-REPORT.md §6). |
| 3.2-14 | function name (params) [-> type] { ... } | 3.2 | DONE | P1 | DONE (B5): definisi fungsi penuh (function-view: returns/param/var/return/set/unset/if/block, titian-function.sh). |
| 3.2-15 | protocol rip\|ospf\|bgp\|... [name [from name2]] | 3.2 | PARTIAL | P1 | PARTIAL (B6): `from` + template baru untuk BGP (tree/conf-bgp.xml + titian-bgp.sh; guard template harus ada di bird-global.conf); OSPF/RIP/dll belum punya `from`. |
| 3.2-16 | template rip\|ospf\|bgp\|... [name [from ...]] | 3.2 | PARTIAL | P1 | PARTIAL (B6): `template bgp` + `template-from` ada (titian-global.sh); template OSPF/RIP ditolak (B6 C8). |
| 3.2-17 | define constant = expression | 3.2 | DONE | P1 | DONE (B6+B8 F8): `define` umum — int/pair/quad/bytestring/rd/ec/lc/ekspresi int (titian-global.sh). |
| 3.2-18 | attribute type name | 3.2 | DONE | P2 | DONE (B6): `attribute` umum — tipe int|bool|string|ip|prefix|pair|quad|bytestring|bgppath|clist|eclist|lclist|rd (titian-global.sh). |
| 3.2-19 | router id <IPv4> | 3.2 | DONE | P1 | `router-id` bird-view (tree/conf-bgp.xml) -> titian-bgp.sh set-router-id -> ditulis global ke bird.conf saat generate. |
| 3.2-20 | router id from [-] ["mask"] [prefix] [, ...] | 3.2 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. |
| 3.2-21 | hostname "name" | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. |
| 3.2-22 | graceful restart wait number | 3.2 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. |
| 3.2-23 | timeformat route\|protocol\|base\|log "fmt" [limit "fmt2"] | 3.2 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. |
| 3.2-24 | <nettype> table name [{ ... }] | 3.2 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. |
| 3.2-25 | mpls domain name [{ ... }] | 3.2 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. |
| 3.2-26 | eval expr | 3.2 | N/A | P3 | N/A: dev-only; perintah birdc `eval` diekspos B7 sebagai operasional (BGP-142 DONE) — `eval` konfigurasi tetap tidak diekspos. |
| 3.3-1 | debug all\|off\|{states\|routes\|filters} (tabel) | 3.3 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (opsi tabel: sorted/trie/debug/settle/gc; 3.3-1 debug = no-op docs). |
| 3.3-2 | sorted switch | 3.3 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (opsi tabel: sorted/trie/debug/settle/gc; 3.3-1 debug = no-op docs). |
| 3.3-3 | trie switch | 3.3 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (opsi tabel: sorted/trie/debug/settle/gc; 3.3-1 debug = no-op docs). |
| 3.3-4 | min settle time time | 3.3 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (opsi tabel: sorted/trie/debug/settle/gc; 3.3-1 debug = no-op docs). |
| 3.3-5 | max settle time time | 3.3 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (opsi tabel: sorted/trie/debug/settle/gc; 3.3-1 debug = no-op docs). |
| 3.3-6 | gc threshold number | 3.3 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (opsi tabel: sorted/trie/debug/settle/gc; 3.3-1 debug = no-op docs). |
| 3.3-7 | gc period time | 3.3 | DONE | P2 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (opsi tabel: sorted/trie/debug/settle/gc; 3.3-1 debug = no-op docs). |
| 3.4-1 | disabled switch | 3.4 | PARTIAL | P1 | PARTIAL (B1): `disabled` per-neighbor BGP ada (tree/conf-bgp.xml); opsi config `disabled` per-protokol lain belum; runtime `disable/enable <nama>` + `router bird enable/disable` tetap ada. |
| 3.4-2 | debug all\|off\|{states\|routes\|filters\|interfaces\|events\|packets} | 3.4 | PARTIAL | P1 | PARTIAL: debug per-protocol ada untuk BGP (B6), RIP/OSPF (B8), Static/Direct/Pipe (B9); Kernel/Device BELUM. |
| 3.4-3 | mrtdump all\|off\|{states\|messages} | 3.4 | PARTIAL | P2 | PARTIAL: mrtdump per-protocol ada untuk BGP (B6), RIP/OSPF (B8), Static/Direct/Pipe (B9); Kernel/Device BELUM. |
| 3.4-4 | router id <IPv4> (per-protocol) | 3.4 | PARTIAL | P1 | PARTIAL (B6): `protocol-router-id` BGP ada; OSPF/RIP belum. |
| 3.4-5 | description "text" | 3.4 | PARTIAL | P1 | PARTIAL: DONE per-neighbor BGP (BGP-71); deskripsi protocol-level terpisah belum (BGP-127). |
| 3.4-6 | vrf "text" \| default | 3.4 | N/A | P3 | Linux-only (kernel >=4.14); FreeBSD tidak punya VRF Linux — perlu keputusan padanan (FIB/VNET/jail) sebelum implementasi. |
| 3.4-7 | channel name [{...}] | 3.4 | DONE | P1 | DONE (B6): channel ipv4/ipv6/mc4/mc6/mpls4/mpls6/vpn4/vpn6/vpn4mc/vpn6mc/flow4/flow6 BGP + channel OSPF/RIP/static/kernel/direct. |
| 3.4-8 | interface [-] ["mask"] [prefix] [, ...] [{...}] | 3.4 | DONE | P1 | DONE: interface pattern di BFD/Direct/OSPF/RIP/Babel + nama tunggal BGP (B1). |
| 3.4-9 | tx class\|dscp num | 3.4 | DONE | P2 | DONE: tx class/dscp — BGP (B6), OSPF (B2), RIP (B3), Babel (B9). |
| 3.4-10 | tx priority num | 3.4 | N/A | P3 | Linux-specific; tidak ada padanan FreeBSD. |
| 3.4-11 | password "password" \| bytestring [{...}] | 3.4 | PARTIAL | P1 | PARTIAL: password MD5 BGP (B1), password + rotasi OSPF/RIP/Babel (B2/B3/B9); BFD auth BELUM; tanpa perintah generik tunggal. |
| 3.4-12 | password: id num | 3.4 | PARTIAL | P1 | PARTIAL: sub-opsi password (id/generate/accept/from/to/algorithm) ada di view password OSPF/RIP/Babel (B2/B3/B9); BGP MD5 tanpa rotasi; BFD belum. |
| 3.4-13 | password: generate from "time" | 3.4 | PARTIAL | P1 | PARTIAL: sub-opsi password (id/generate/accept/from/to/algorithm) ada di view password OSPF/RIP/Babel (B2/B3/B9); BGP MD5 tanpa rotasi; BFD belum. |
| 3.4-14 | password: generate to "time" | 3.4 | PARTIAL | P1 | PARTIAL: sub-opsi password (id/generate/accept/from/to/algorithm) ada di view password OSPF/RIP/Babel (B2/B3/B9); BGP MD5 tanpa rotasi; BFD belum. |
| 3.4-15 | password: accept from "time" | 3.4 | PARTIAL | P1 | PARTIAL: sub-opsi password (id/generate/accept/from/to/algorithm) ada di view password OSPF/RIP/Babel (B2/B3/B9); BGP MD5 tanpa rotasi; BFD belum. |
| 3.4-16 | password: accept to "time" | 3.4 | PARTIAL | P1 | PARTIAL: sub-opsi password (id/generate/accept/from/to/algorithm) ada di view password OSPF/RIP/Babel (B2/B3/B9); BGP MD5 tanpa rotasi; BFD belum. |
| 3.4-17 | password: from "time" | 3.4 | PARTIAL | P1 | PARTIAL: sub-opsi password (id/generate/accept/from/to/algorithm) ada di view password OSPF/RIP/Babel (B2/B3/B9); BGP MD5 tanpa rotasi; BFD belum. |
| 3.4-18 | password: to "time" | 3.4 | PARTIAL | P1 | PARTIAL: sub-opsi password (id/generate/accept/from/to/algorithm) ada di view password OSPF/RIP/Babel (B2/B3/B9); BGP MD5 tanpa rotasi; BFD belum. |
| 3.4-19 | password: algorithm (keyed md5\|keyed sha1\|hmac sha1\|hmac sha256\|hmac sha384\|hmac sha512\|blake2s128\|blake2s256\|blake2b256\|blake2b512) | 3.4 | PARTIAL | P1 | PARTIAL: sub-opsi password (id/generate/accept/from/to/algorithm) ada di view password OSPF/RIP/Babel (B2/B3/B9); BGP MD5 tanpa rotasi; BFD belum. |
| 3.5-1 | debug all\|off\|{states\|routes\|filters} (channel) | 3.5 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (debug + table per-channel BGP). |
| 3.5-2 | table name (channel) | 3.5 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (debug + table per-channel BGP). |
| 3.5-3 | preference expr | 3.5 | PARTIAL | P1 | PARTIAL: preference channel BGP (B5), RIP/OSPF (B8); channel static/kernel/direct/pipe belum. |
| 3.5-4 | import all\|none\|filter name\|filter {...}\|where ... | 3.5 | PARTIAL | P1 | PARTIAL (B1/B2/B3/B6): import all/none/filter bernama di BGP/OSPF/RIP + channel BGP; bentuk `where` + filter inline belum. |
| 3.5-5 | export all\|none\|filter name\|filter {...}\|where ... | 3.5 | PARTIAL | P1 | PARTIAL (B1/B2/B3/B6): export all/none/filter bernama di BGP/OSPF/RIP + channel BGP; bentuk `where` + filter inline belum; gotcha default export `none` sudah ditangani. |
| 3.5-6 | import keep filtered switch | 3.5 | DONE | P1 | DONE: import keep filtered — BGP (B5), RIP/OSPF (B8). |
| 3.5-7 | rpki reload switch | 3.5 | DONE | P1 | DONE (B6): `rpki-reload` per-channel BGP (mock B6). |
| 3.5-8 | import limit [number\|off] [action warn\|block\|restart\|disable] | 3.5 | DONE | P1 | DONE: import/receive/export limit — BGP (B6), RIP/OSPF (B9 §2.6). |
| 3.5-9 | receive limit [number\|off] [action ...] | 3.5 | DONE | P1 | DONE: import/receive/export limit — BGP (B6), RIP/OSPF (B9 §2.6). |
| 3.5-10 | export limit [number\|off] [action ...] | 3.5 | DONE | P1 | DONE: import/receive/export limit — BGP (B6), RIP/OSPF (B9 §2.6). |
| 3.6-1 | label range name { start number; length number; } | 3.6 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (mpls domain + label range + label policy; eksperimental). |
| 3.6-2 | label range: start number; | 3.6 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (mpls domain + label range + label policy; eksperimental). |
| 3.6-3 | label range: length number; | 3.6 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (mpls domain + label range + label policy; eksperimental). |
| 3.6-4 | domain name (channel MPLS) | 3.6 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (mpls domain + label range + label policy; eksperimental). |
| 3.6-5 | label range name (channel MPLS) | 3.6 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (mpls domain + label range + label policy; eksperimental). |
| 3.6-6 | label policy static\|prefix\|aggregate\|vrf | 3.6 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (mpls domain + label range + label policy; eksperimental). |
| 2.1-1 | tabel default master4/master6 | 2.1 | DONE | P1 | Implisit; `show route` default. |
| 2.1-2 | tabel BIRD != kernel FIB | 2.1 | PARTIAL | P1 | etc/bird.d/protocol.conf contoh kernel import/export none + komentar; tidak ada pemisah eksplisit tabel BIRD vs FIB di klish. |
| 2.1-3 | satu route per source per primary key | 2.1 | DONE | P1 | Perilaku bawaan BIRD; tidak butuh perintah klish. |
| 2.1-4 | best-route selection (preference -> proto-pref -> ... -> UNDEFINED antar-protokol) | 2.1 | PARTIAL | P1 | PARTIAL: perilaku bawaan; tuas preference kini ada untuk BGP/RIP/OSPF (3.5-3); determinisme BGP-vs-OSPF tetap jangan dijanjikan. |
| 2.1-5 | daftar route terurut (sorted) | 2.1 | DONE | P1 | DONE (B6): tabel `sorted` via table-add (3.3-2). |
| 2.2-1 | ipv4 (nettype) | 2.2 | DONE | P1 | Channel ipv4 BGP. |
| 2.2-2 | ipv6 (nettype) | 2.2 | DONE | P1 | DONE (B6): channel ipv6 BGP (configure-bird-channel-view). |
| 2.2-3 | ipv6 sadr (RFC 8043) | 2.2 | DONE | P3 | DONE (B9): channel `ipv6 sadr` Babel (top-set ipv6-sadr, BIRD-B9-REPORT.md §2.3). |
| 2.2-4 | vpn4 (RFC 4364) | 2.2 | DONE | P3 | DONE (B6): channel vpn4/vpn6 BGP + L3VPN (B9). |
| 2.2-5 | vpn6 (RFC 4364) | 2.2 | DONE | P3 | DONE (B6): channel vpn4/vpn6 BGP + L3VPN (B9). |
| 2.2-6 | roa4 | 2.2 | DONE | P3 | DONE (B9): channel roa4/roa6 RPKI (chan-table-set, §2.1). |
| 2.2-7 | roa6 | 2.2 | DONE | P3 | DONE (B9): channel roa4/roa6 RPKI (chan-table-set, §2.1). |
| 2.2-8 | flow4 (RFC 5575) | 2.2 | DONE | P2 | DONE (B6+B8): channel flow4/flow6 BGP + flow static (B8 §2.3). |
| 2.2-9 | flow6 (RFC 5575) | 2.2 | DONE | P2 | DONE (B6+B8): channel flow4/flow6 BGP + flow static (B8 §2.3). |
| 2.2-10 | mpls (nettype tabel) | 2.2 | DONE | P3 | DONE (B6): `table-add mpls` (mock A B6). |
| 2.2-11 | next hop: device + IP dan/atau MPLS stack (maks 8 label) + weight | 2.2 | PARTIAL | P1 | `show route` birdc ada (tree/bird.xml); tampil stack MPLS + weight belum diverifikasi. |
| 2.2-12 | atribut umum route: from, source-protocol, preference | 2.2 | DONE | P1 | DONE (B7): `show route all` diperbaiki di tree/bird.xml → `birdc show route all`. |
| 2.3-1 | model protokol-channel-tabel | 2.3 | DONE | P1 | Struktur view klish mencerminkan hierarki. |
| 2.3-2 | BFD dan Device TANPA channel | 2.3 | DONE | P1 | View BFD tanpa channel; protocol.conf device tanpa channel. |
| 2.3-3 | single vs multi-channel (OSPF/RIP 1; BGP/Direct banyak) | 2.3 | PARTIAL | P1 | Tidak ada validasi klish yang menolak channel kedua di OSPF/RIP. |
| 2.3-4 | arah filter channel: export=tabel->protokol, import=protokol->tabel | 2.3 | DONE | P1 | Konsisten di semua perintah/show; gotcha export default none sudah ditangani. |
| 2.4-1 | mekanisme graceful restart | 2.4 | DONE | P1 | DONE: `bfd graceful` BGP (B1) + `graceful restart wait` global (B6) + `graceful-restart` birdc (B7). |
| 2.4-2 | dukungan GR: hanya Kernel + BGP; flag -R | 2.4 | PARTIAL | P1 | Opsi GR protocol/channel belum; flag `-R` startup bird belum diekspos. |
| 2.4-3 | planned vs crash GR; matikan via `graceful restart` (bukan `down`) | 2.4 | DONE | P1 | DONE (B7): perintah birdc `graceful-restart` (+confirm) di tree/en-show-birdc.xml. |
| 2.5-1 | MPLS domain | 2.5 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (mpls domain / tabel mpls / channel mpls). |
| 2.5-2 | MPLS table | 2.5 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (mpls domain / tabel mpls / channel mpls). |
| 2.5-3 | MPLS channel | 2.5 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (mpls domain / tabel mpls / channel mpls). |
| 2.5-4 | labeled route + atribut mpls_label/mpls_policy | 2.5 | PARTIAL | P3 | PARTIAL (B9): atribut `mpls_label`/`mpls_policy`/`gw_mpls` bisa di-set di filter (§2.8); labeled route per-route (`mpls <number>`) BELUM. |
| 2.5-5 | label lokal per-protokol (tidak dishare) | 2.5 | DONE | P3 | DONE (B6/B9): label policy per-protokol + label range per-domain; label lokal per-protokol = perilaku bawaan BIRD. |

### 2.2 Bab 5 (Filters)

| Item | Sintaks BIRD | Bab docs | Status | Prioritas | Catatan |
|---|---|---|---|---|---|
| 5-1 | filter NAME { statements } | 5.1 | DONE | P1 | etc/bird.d/filter.conf: f_accept, f_reject, bgp_export_attr, bgp_import_comm; klish `filter <NAME>`. |
| 5-2 | int var; (variabel lokal filter) | 5.1 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (var lokal, function returns/param/var/return, pemanggilan via call:). |
| 5-3 | { statement1; statement2; } (compound) | 5.1 | DONE | P1 | Dipakai di bgp_export_attr, function.conf. |
| 5-4 | function name() -> int { ... return 42; } | 5.1 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (var lokal, function returns/param/var/return, pemanggilan via call:). |
| 5-5 | function with_parameters(int parameter) -> pair { ... } | 5.1 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (var lokal, function returns/param/var/return, pemanggilan via call:). |
| 5-6 | int another_variable = 5; (var lokal fungsi + inisialisasi) | 5.1 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (var lokal, function returns/param/var/return, pemanggilan via call:). |
| 5-7 | variabel di nested block | 5.1 | PARTIAL | P1 | PARTIAL (B5): `var` level filter/fungsi ada (filter-var/function-var); deklarasi var di dalam blok nested belum terverifikasi. |
| 5-8 | deklarasi variabel deprecated (setelah baris function) | 5.1 | MISSING | P1 | Jangan diadopsi (deprecated). |
| 5-9 | name(); with_parameters(5); (pemanggilan fungsi) | 5.1 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (var lokal, function returns/param/var/return, pemanggilan via call:). |
| 5-10 | return [expr]; (fungsi) | 5.1 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (var lokal, function returns/param/var/return, pemanggilan via call:). |
| 5-11 | rekursi langsung | 5.1 | MISSING | P1 |  |
| 5-12 | filter: tanpa parameter/return eksplisit | 5.1 | DONE | P1 | Prinsip sudah dipakai: filter Titian tanpa parameter/return. |
| 5-13 | filter wajib berakhir accept/reject; runtime error -> reject | 5.1 | DONE | P1 | Generator titian-bgp.sh selalu menutup filter dengan `reject;`. |
| 5-14 | show route filter NAME \| show route filter { ... } | 5.1 | PARTIAL | P1 | PARTIAL (F3.10): `show route filter <nama>` DIHAPUS dari tree/en-show-birdc.xml — BIRD 2.20 tidak dukung nama filter di `show route filter` (hanya inline `{ ... }`); inline jalan via birdc langsung, belum ada perintah klish. |
| 5-15 | bool: true / false | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-16 | int: 42 ; 0x1234 | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-17 | pair: (1234,5678) | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-18 | quad: 10.20.30.40 | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-19 | string: "This is a string constant" | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-20 | bytestring: 01:23:... / hex:12:34 | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-21 | ip: 10.20.30.40 ; fec0:3:4::1 | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-22 | prefix: 1.2.0.0/16 | 5.2 | DONE | P1 | `accept/reject <prefix>` klish; generator `net ~ [ <prefix>+ ]`. |
| 5-23 | rd: 65000:100 ; asn4:16bit ; 10.0.0.1:100 | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-24 | ec: (rt, 65000, 100) ; (ro, myas, 3*10) | 5.2 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-25 | lc: (123, 456, 789) | 5.2 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-26 | enum: RTS_STATIC, SCOPE_UNIVERSE, ... | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-27 | bgppath (tidak ada literal) | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-28 | bgpmask: [= 2 3 5 * =] | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-29 | clist (community/cluster list, bisa dimodifikasi) | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-30 | eclist (extended community list) | 5.2 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-31 | lclist (large community list) | 5.2 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-32 | int set: [ 1, 2, 5..7 ] | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-33 | pair set: [ (123,*), (123,5..100), ... ] | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-34 | quad set: [ quad, ... ] | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-35 | ip set: [ 10.0.0.1, 2001:db8::1 ] | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-36 | prefix set: [ 1.0.0.0/8, 2.0.0.0/8+, 3.0.0.0/8-, 4.0.0.0/8{16,24} ] | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-37 | ec set: [ (rt, myas, *), ... ] | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-38 | lc set: [ (10, 20..30, *), ... ] | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-39 | rd set / enum set | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-40 | define one=1; define myas=64500; + konstanta di set | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-41 | deklarasi variabel bertipe set: int set odds = [ ... ]; | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + BIRD-B8-REPORT.md §2.6 F1/F2/F6/F8 (literal bool/int/pair/quad/string/bytestring/ip/rd/ec/lc/enum/bgppath/bgpmask/clist/eclist/lclist + deklarasi set + define umum). |
| 5-42 | pola prefix + (subnet): 2.0.0.0/8+ | 5.2 | DONE | P1 | Generator titian-bgp.sh selalu menulis `net ~ [ <prefix>+ ]`; juga di function.conf. |
| 5-43 | pola prefix - (supernet): 3.0.0.0/8- | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (pola prefix `-` + `{low,high}` di accept/reject; mock A B5). |
| 5-44 | pola prefix {low,high}: 4.0.0.0/8{16,24} | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (pola prefix `-` + `{low,high}` di accept/reject; mock A B5). |
| 5-45 | from_hex(" 12.34 56:78 ab-cd-ef ") | 5.2 | PARTIAL | P2 | PARTIAL (B8): `from_hex(...)` didukung sebagai nilai define bytestring (F8); bukan fungsi filter langsung. |
| 5-46 | pair.asn: p.asn | 5.2 | MISSING | P2 |  |
| 5-47 | pair.data: p.data | 5.2 | MISSING | P2 |  |
| 5-48 | lc.asn: c.asn | 5.2 | MISSING | P2 |  |
| 5-49 | lc.data1: c.data1 | 5.2 | MISSING | P2 |  |
| 5-50 | lc.data2: c.data2 | 5.2 | MISSING | P2 |  |
| 5-51 | ip.is_v4: a.is_v4 | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-52 | ip.mask(num): 1.2.3.4.mask(8) | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-53 | prefix.type: net.type (NET_IP4, NET_IP6, ...) | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-54 | prefix.ip: p.ip | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-55 | prefix.len: 1.2.0.0/16.len | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-56 | prefix.src (SADR): p.src | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-57 | prefix.dst (SADR): p.dst | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-58 | prefix.rd (VPN): p.rd | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-59 | prefix.maxlen (ROA): p.maxlen | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-60 | prefix.asn (ROA): p.asn | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-61 | prefix.src (flowspec): p.src | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-62 | prefix.dst (flowspec): p.dst | 5.2 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F3 (is_v4, .mask(N), net.type/.ip/.len/.src/.dst/.rd/.maxlen/.asn). |
| 5-63 | NET_IP4 / NET_IP6: 1.2.0.0/16 | 5.2 | DONE | P1 | Bentuk literal prefix yang dipakai klish. |
| 5-64 | NET_IP6_SADR: 2001:db8::/32 from 2001:db8:1::/48 | 5.2 | PARTIAL | P3 | PARTIAL (B5/B8): `net.type = NET_IP6_SADR` bisa di-match (enum:NETTYPE); literal prefix SADR `... from ...` belum. |
| 5-65 | NET_VPN4 / NET_VPN6: rd <rd> <ipprefix> | 5.2 | PARTIAL | P3 | PARTIAL: `net.type = NET_VPN4/NET_VPN6` bisa di-match; literal `rd <rd> <prefix>` belum. |
| 5-66 | NET_ROA4 / NET_ROA6: prefix range + ASN | 5.2 | PARTIAL | P3 | PARTIAL: `net.type = NET_ROA4/NET_ROA6` bisa di-match; literal ROA (prefix + maxlen + ASN) belum. |
| 5-67 | NET_FLOW4 / NET_FLOW6: prefix + aturan flowspec | 5.2 | DONE | P2 | DONE (B8): NET_FLOW4/NET_FLOW6 di filter (enum:NETTYPE + match, §2.6). |
| 5-68 | NET_MPLS: satu label MPLS | 5.2 | MISSING | P3 | Handling TIDAK diimplementasikan di BIRD sendiri — jangan jadikan perintah klish stabil. |
| 5-69 | jenis-jenis rd: 65000:100 ; 65000:100000 ; 10.0.0.1:100 | 5.2 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F2/F8 (literal rd/ec/lc + define). |
| 5-70 | literal ec + kind rt/ro: (rt, 65000, 100) | 5.2 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F2/F8 (literal rd/ec/lc + define). |
| 5-71 | literal lc: (123, 456, 789) | 5.2 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F2/F8 (literal rd/ec/lc + define). |
| 5-72 | bgppath.first: P.first | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-73 | bgppath.last: P.last | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-74 | bgppath.last_nonaggregated: P.last_nonaggregated | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-75 | bgppath.len: P.len | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-76 | bgppath.empty: P.empty; | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-77 | bgppath.prepend(A): bgp_path.prepend(65000); | 5.2 | DONE | P1 | Export-inline titian-bgp.sh: `bgp_path.prepend($_las);` diulang N kali. |
| 5-78 | bgppath.delete(A): P.delete(A); | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-79 | bgppath.filter(A): P.filter([65000, 65001]); | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-80 | clist.len: C.len | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-81 | clist.empty: C.empty; | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-82 | clist.add(P): bgp_community.add((65000, 100)); | 5.2 | DONE | P1 | Export-inline: `bgp_community.add((c1, c2));`. |
| 5-83 | clist.delete(P): C.delete((65000, 100)); | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-84 | clist.filter(P): C.filter([(65000, 100..109)]); | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F7 (bgppath .first/.last/.last_nonaggregated/.len/.empty/.delete/.filter; clist .len/.empty/.delete/.filter). |
| 5-85 | clist.min: C.min | 5.2 | DONE | P2 | DONE (B5+B8+B9): BIRD-B9-REPORT.md §2.8 (filter().min/.max, enum-set, atribut mpls/babel); mock B9 285 PASS. (filter().min/.max, §2.8). |
| 5-86 | clist.max: C.max | 5.2 | DONE | P2 | DONE (B5+B8+B9): BIRD-B9-REPORT.md §2.8 (filter().min/.max, enum-set, atribut mpls/babel); mock B9 285 PASS. (filter().min/.max, §2.8). |
| 5-87 | operasi eclist: add/delete/~ | 5.2 | DONE | P3 | DONE (B5+B8): BIRD-B5-REPORT.md §6 + BIRD-B8-REPORT.md §2.6 (F1–F7: var-set, method, accessor baru); mock B8 184 PASS. + B9 filter().min/.max (operasi eclist/lclist: add/delete/~). |
| 5-88 | operasi lclist: add/delete/~ | 5.2 | DONE | P3 | DONE (B5+B8): BIRD-B5-REPORT.md §6 + BIRD-B8-REPORT.md §2.6 (F1–F7: var-set, method, accessor baru); mock B8 184 PASS. + B9 filter().min/.max (operasi eclist/lclist: add/delete/~). |
| 5-89 | literal bgpmask + wildcard/range/set: [= * 4 3 * =] | 5.2 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (literal bgpmask + wildcard/range/set, path-mask). |
| 5-90 | operator aritmetika integer: a + b ; a - b ; a * b ; a / b | 5.3 | PARTIAL | P1 | PARTIAL (B8): ekspresi int berkurung didukung di `define` (F8); aritmetika umum di filter belum. |
| 5-91 | tanda kurung: (a*(b+c)) | 5.3 | PARTIAL | P1 | PARTIAL (B8): kurung di ekspresi int `define`; pengelompokan ekspresi umum filter belum. |
| 5-92 | operator perbandingan: = != < > <= >= | 5.3 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (operator perbandingan 6 macam, logika !/&&/||, ~ membership). |
| 5-93 | operator logika: !a ; a && b ; a \|\| b | 5.3 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (operator perbandingan 6 macam, logika !/&&/||, ~ membership). |
| 5-94 | ~ membership (elemen di set): x ~ [ 1, 2, 5..7 ] | 5.3 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (operator perbandingan 6 macam, logika !/&&/||, ~ membership). |
| 5-95 | !~ negasi membership: x !~ [ ... ] | 5.3 | MISSING | P1 |  |
| 5-96 | ~ string vs pola shell: "eth0" ~ "eth*" | 5.3 | MISSING | P1 |  |
| 5-97 | ~ IP di prefix: 127.0.0.5 ~ 127.0.0.0/8 | 5.3 | MISSING | P1 |  |
| 5-98 | ~ prefix di prefix-set: net ~ [ 10.0.0.0/8+ ] | 5.3 | DONE | P1 | Bentuk yang digenerate titian-bgp.sh. |
| 5-99 | ~ bgppath vs bgpmask: bgp_path ~ [= * 4 3 * =] | 5.3 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (bgp_path ~ bgpmask, ASN ~ bgp_path, bgp_path ~ [int set]). |
| 5-100 | ~ ASN di bgppath: 65000 ~ bgp_path | 5.3 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (bgp_path ~ bgpmask, ASN ~ bgp_path, bgp_path ~ [int set]). |
| 5-101 | ~ bgppath vs int set: bgp_path ~ [ 65000, 65001 ] | 5.3 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (bgp_path ~ bgpmask, ASN ~ bgp_path, bgp_path ~ [int set]). |
| 5-102 | ~ pair/quad di clist: (65000, 100) ~ bgp_community | 5.3 | DONE | P1 | KOREKSI vs READ (SEBAGIAN -> DONE): bentuk ini persis yang digenerate titian-comm.sh import-add: `if (AA,NN) ~ bgp_community then ...;` (juga varian ext/large). |
| 5-103 | ~ clist vs pair/quad set: bgp_community ~ [ (65000, 100) ] | 5.3 | DONE | P1 | Digenerate titian-bgp.sh. |
| 5-104 | roa_check(table) | 5.3 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (`roa_check(tabel)` 1-argumen; case roa-check + accept roa). |
| 5-105 | roa_check(table, prefix, asn) | 5.3 | PARTIAL | P3 | PARTIAL (B5): `roa_check(tabel)` 1-argumen ada; bentuk 3-argumen `(tabel, prefix, asn)` belum. |
| 5-106 | aspa_check_downstream(table) | 5.3 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (`aspa_check_downstream/upstream(tabel)`; accept aspa-down/up). |
| 5-107 | aspa_check_upstream(table) | 5.3 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (`aspa_check_downstream/upstream(tabel)`; accept aspa-down/up). |
| 5-108 | aspa_check(table, path, is_upstream) | 5.3 | PARTIAL | P3 | PARTIAL (B5): `aspa_check_downstream/upstream(tabel)` ada; bentuk 3-argumen `(tabel, path, is_upstream)` belum. |
| 5-109 | nilai enum ROA: ROA_UNKNOWN/INVALID/VALID | 5.3 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (nilai enum ROA_*/ASPA_* di case/accept). |
| 5-110 | nilai enum ASPA: ASPA_UNKNOWN/INVALID/VALID | 5.3 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (nilai enum ROA_*/ASPA_* di case/accept). |
| 5-111 | if ... then ... else ... | 5.4 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (if/else, for, case/when/otherwise; `case net` ditolak validator — batasan ditegakkan). |
| 5-112 | else opsional (if tanpa else) | 5.4 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (if/else, for, case/when/otherwise; `case net` ditolak validator — batasan ditegakkan). |
| 5-113 | for [type] variable in expr do command; | 5.4 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (if/else, for, case/when/otherwise; `case net` ditolak validator — batasan ditegakkan). |
| 5-114 | variabel for: existing vs lokal (for int asn in ...) | 5.4 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (if/else, for, case/when/otherwise; `case net` ditolak validator — batasan ditegakkan). |
| 5-115 | case expr { 2: ...; 3..5: ...; else: ...; } | 5.4 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (if/else, for, case/when/otherwise; `case net` ditolak validator — batasan ditegakkan). |
| 5-116 | label case: set_body_expr (3..5:) | 5.4 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (if/else, for, case/when/otherwise; `case net` ditolak validator — batasan ditegakkan). |
| 5-117 | case ... else: | 5.4 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (if/else, for, case/when/otherwise; `case net` ditolak validator — batasan ditegakkan). |
| 5-118 | case TIDAK bisa untuk prefix (batasan) | 5.4 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. (if/else, for, case/when/otherwise; `case net` ditolak validator — batasan ditegakkan). |
| 5-119 | net (prefix, RO) | 5.5 | DONE | P1 | Dipakai generator filter prefix & community; `net_is_private()` memakai `net ~ [...]`. |
| 5-120 | scope (enum): scope = SCOPE_UNIVERSE; | 5.5 | MISSING | P1 | PERHATIAN: atribut `scope` DIHAPUS di BIRD 3 (titian-bird.sh validate_config menolaknya di bird3) — hanya relevan bila image bird2. |
| 5-121 | preference (int): preference = 100; | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-122 | from (ip) | 5.5 | PARTIAL | P1 | PARTIAL (B5): `from` bisa di-match (attr ip); set ditolak (B5 A4 — status RO tak dikonfirmasi docs). |
| 5-123 | gw (ip): gw = 10.99.40.2; | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-124 | proto (string, RO) | 5.5 | PARTIAL | P1 | PARTIAL (B5): `proto` bisa di-match (string); set tidak didukung. |
| 5-125 | source (enum): source = RTS_STATIC | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-126 | dest (enum): dest = RTD_BLACKHOLE; | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-127 | ifname (string): ifname = "ge0"; | 5.5 | PARTIAL | P1 | PARTIAL (B5): `ifname` bisa di-match (string); set ditolak (B5 A12 — menghapus gateway). |
| 5-128 | ifindex (int, RO) | 5.5 | MISSING | P1 |  |
| 5-129 | onlink (bool): onlink = true; ... | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-130 | weight (int): weight = 10; | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-131 | gw_mpls (int): gw_mpls = 100; | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-132 | igp_metric (int): igp_metric = 10; | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-133 | mpls_label (int): mpls_label = 100; | 5.5 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-134 | mpls_policy (enum): mpls_policy = MPLS_POLICY_STATIC; | 5.5 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-135 | mpls_class (int): mpls_class = 1; | 5.5 | PARTIAL | P3 | PARTIAL (B9): `mpls_class` bisa di-match (int, read-only); set ditolak rc=33. |
| 5-136 | defined(attr) | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-137 | unset(attr) | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-138 | deklarasi custom attribute: attribute int valid_roa; | 5.5 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-139 | bgppath/clist undefined = empty | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-140 | atribut bisa didefinisikan via assignment: rip_metric = 1; | 5.5 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-141 | nilai enum scope: SCOPE_HOST/LINK/SITE/ORGANIZATION/UNIVERSE | 5.5 | MISSING | P2 | Lihat No. 120 (dihapus di BIRD 3). |
| 5-142 | nilai enum source (RTS_*): 11 nilai | 5.5 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-143 | nilai enum dest (RTD_*): 6 nilai | 5.5 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-144 | nilai enum mpls_policy: 5 nilai | 5.5 | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-145 | nilai enum prefix.type (NET_*): 10 nilai | 5.5 | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-146 | rip_metric (atribut, Bab 6.15) | 5.5G | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-147 | bgp_path (atribut) | 5.5G | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-148 | bgp_community (atribut, clist) | 5.5G | DONE | P1 | Match `bgp_community ~ [ (AS,NN) ]` digenerate; `.add()` di export-inline; `.add()` ext/large + match import via titian-comm.sh. |
| 5-149 | bgp_local_pref = 100; | 5.5G | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-150 | bgp_med = 50; | 5.5G | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-151 | bgp_path.prepend() di export | 5.5G | DONE | P1 | `neighbor prepend <N>`; generator mengulang prepend() N kali. |
| 5-152 | bgp_community.add() di export | 5.5G | DONE | P1 | `neighbor community <AS:NN>` + `community export add` (titian-comm.sh, termasuk ext/large). |
| 5-153 | assignment: variable = expr; / bgp_local_pref = 100; | 5.6 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-154 | accept [expr]; (accept "ok";) | 5.6 | DONE | P1 | Bentuk tanpa pesan dipakai generator & filter.conf; bentuk DENGAN pesan belum diekspos klish. |
| 5-155 | reject [expr]; (reject "RIP metric is too big";) | 5.6 | DONE | P1 | Bentuk tanpa pesan dipakai generator & filter.conf; bentuk dengan pesan belum diekspos klish. |
| 5-156 | return expr; (fungsi) | 5.6 | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B8 F1/F4 + B9 §2.8 (set/unset/defined, atribut umum + bgp_* + enum SOURCE/DEST/NETTYPE/MPLSPOLICY lengkap, assignment umum). |
| 5-157 | print expr [, expr...]; | 5.6 | MISSING | P2 | Tujuan output tidak dirinci docs (log? birdc?). |
| 5-158 | printn expr [, expr...]; | 5.6 | MISSING | P2 |  |
| 5-159 | contoh filter not_too_far (var lokal + defined() + if/else + pesan) | 5.contoh | PARTIAL | P1 | PARTIAL (B5): pola var lokal + defined() + if/else bisa dibangun; `accept/reject` berpesan belum. |
| 5-160 | contoh fungsi name()/with_parameters() | 5.contoh | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B7/B8/B9 (contoh fungsi berparameter, customer_check ROA+ASPA, gabungan if+for+case, literal set + define, pencocokan prefix-set + bgpmask). |
| 5-161 | contoh debug inline show route filter { ... } | 5.contoh | PARTIAL | P1 | PARTIAL (B7+F3.10): filter inline `{ ... }` di `show route filter` jalan via birdc langsung, belum ada perintah klish (bentuk `<nama>` dihapus F3.10 — BIRD 2.20 tidak dukung). |
| 5-162 | contoh filter customer_check (ROA+ASPA) | 5.contoh | DONE | P3 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B7/B8/B9 (contoh fungsi berparameter, customer_check ROA+ASPA, gabungan if+for+case, literal set + define, pencocokan prefix-set + bgpmask). |
| 5-163 | contoh gabungan if + for + case | 5.contoh | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B7/B8/B9 (contoh fungsi berparameter, customer_check ROA+ASPA, gabungan if+for+case, literal set + define, pencocokan prefix-set + bgpmask). |
| 5-164 | contoh literal set dengan define | 5.contoh | DONE | P2 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B7/B8/B9 (contoh fungsi berparameter, customer_check ROA+ASPA, gabungan if+for+case, literal set + define, pencocokan prefix-set + bgpmask). |
| 5-165 | contoh pencocokan prefix-set | 5.contoh | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B7/B8/B9 (contoh fungsi berparameter, customer_check ROA+ASPA, gabungan if+for+case, literal set + define, pencocokan prefix-set + bgpmask). |
| 5-166 | contoh pencocokan bgpmask | 5.contoh | DONE | P1 | DONE (B5): BIRD-B5-REPORT.md §6 — bahasa filter lengkap (filter/function view, titian-bgp.sh + titian-function.sh); mock SEMUA LOLOS. + B7/B8/B9 (contoh fungsi berparameter, customer_check ROA+ASPA, gabungan if+for+case, literal set + define, pencocokan prefix-set + bgpmask). |

### 2.3 Bab 6.4 BGP + Bab 4.3 birdc (BGP)

Catatan: No. 126 (`router id`, duplikat No. 81) tidak ada di tabel — total unik Bab 6.4 = 145.

| Item | Sintaks BIRD | Bab docs | Status | Prioritas | Catatan |
|---|---|---|---|---|---|
| BGP-1 | local as <number> | 6.4 | DONE | P1 | `local-as` bird-view (tree/conf-bgp.xml) -> titian-bgp.sh. |
| BGP-2 | local <ip> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-3 | local port <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-4 | neighbor <ip> as <number> | 6.4 | DONE | P1 | `neighbor <IP>` + `remote-as` (tree/conf-bgp.xml). |
| BGP-5 | neighbor <ip> port <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-6 | neighbor <ip> internal\|external | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-7 | neighbor range <prefix> (dynamic BGP) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-8 | interface "<string>" | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-9 | direct | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-10 | multihop [<number>] | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-11 | source address <ip> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-12 | dynamic name "<text>" | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-13 | dynamic name digits <number> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-14 | strict bind <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-15 | free bind <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-16 | check link <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-17 | bfd <switch\|graceful\|{ options }> | 6.4 | DONE | P1 | KOREKSI vs READ (BELUM -> DONE): `neighbor bfd` / `bfd graceful` / `no bfd` ada di tree/conf-bgp.xml; titian-bgp.sh generate menulis `bfd on;` / `bfd graceful;` dan memaksa section BFD ter-generate dulu. CATATAN: `protocol bfd` sendiri IN PROGRESS subagent terpisah — switch BGP ini tidak berguna sebelum BFD jalan. |
| BGP-18 | ttl security <switch> (GTSM RFC 5082) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-19 | password "<string>" (TCP MD5, RFC 2385) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-20 | setkey <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-21 | passive <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-22 | confederation <number> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-23 | confederation member <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-24 | rr client | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-25 | rr cluster id <IPv4> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-26 | rs client | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-27 | allow bgp_local_pref <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-28 | allow bgp_med <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-29 | allow local as [<number>] | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-30 | allow as sets [<switch>] | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-31 | enforce first as [<switch>] | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-32 | enable route refresh <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-33 | require route refresh <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-34 | enable enhanced route refresh <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-35 | require enhanced route refresh <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-36 | graceful restart <switch\|aware> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-37 | graceful restart time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-38 | require graceful restart <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-39 | long lived graceful restart <switch\|aware> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-40 | long lived stale time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-41 | require long lived graceful restart <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-42 | interpret communities <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-43 | enable as4 <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-44 | require as4 <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-45 | enable extended messages <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-46 | require extended messages <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-47 | capabilities <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-48 | advertise hostname <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-49 | require hostname <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-50 | disable after error <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-51 | disable after cease <switch\|set-of-flags> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-52 | hold time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-53 | min hold time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-54 | startup hold time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-55 | keepalive time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-56 | min keepalive time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-57 | send hold time <number> (RFC 9687) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-58 | connect delay time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-59 | connect retry time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-60 | error wait time <number>,<number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-61 | error forget time <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-62 | path metric <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-63 | med metric <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-64 | deterministic med <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-65 | igp metric <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-66 | prefer older <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-67 | default bgp_med <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-68 | default bgp_local_pref <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-69 | local role <role-name> (RFC 9234) | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-70 | require roles <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-71 | description "<text>" (protocol-level) | 6.4 | DONE | P1 | `description` di neighbor-view (tree/conf-bgp.xml); ditulis sebagai `description "...";` per protocol. |
| BGP-72 | import all\|none\|filter <name> (channel ipv4) | 6.4 | DONE | P1 | tree/conf-bgp.xml + titian-bgp.sh. |
| BGP-73 | export all\|none\|filter <name> (channel ipv4) | 6.4 | DONE | P1 | tree/conf-bgp.xml + titian-bgp.sh. |
| BGP-74 | network <prefix> (BUKAN statement BIRD) | 6.4 | DONE | P1 | Perintah klish-level; di-generate sebagai komentar + diandalkan dari export filter/tabel routing. |
| BGP-75 | filter prefix: if net ~ [ <prefix>+ ] then accept\|reject; | 6.4 | DONE | P1 | `filter <nama> accept\|reject <prefix>` (tree/conf-bgp.xml). |
| BGP-76 | filter community: if bgp_community ~ [ (<AS>,<NN>) ] then accept\|reject; | 6.4 | DONE | P1 | `filter <nama> accept\|reject community <AS:NN>`. |
| BGP-77 | export: bgp_path.prepend(<AS>); (N kali) | 6.4 | DONE | P1 | `prepend <N>`; titian-bgp.sh mengulang prepend() N kali. |
| BGP-78 | export: bgp_community.add((<AS>, <NN>)); | 6.4 | DONE | P1 | `community <AS:NN>` + `community export add` (titian-comm.sh). |
| BGP-79 | export: bgp_local_pref = <N>; | 6.4 | DONE | P1 | `local-pref <N>` di neighbor-view; via inline export filter bila `export all`. |
| BGP-80 | export: bgp_med = <N>; | 6.4 | DONE | P1 | `med <N>` di neighbor-view; via inline export filter bila `export all`. |
| BGP-81 | router id <IPv4> (global, Bab 3.2) | 6.4 | DONE | P1 | Sama dengan 3.2-19; `router-id` bird-view; ditulis global oleh titian-bgp.sh generate. |
| BGP-82 | ipv4 { <channel config> }; | 6.4 | DONE | P1 | Generator selalu menulis `ipv4 { ... }`. |
| BGP-83 | ipv6 { <channel config> }; | 6.4 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (channel ipv6/mc/mpls/vpn/flow, next-hop-prefer-global, channel table, limit). |
| BGP-84 | ipv4 multicast / ipv6 multicast channel | 6.4 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (channel ipv6/mc/mpls/vpn/flow, next-hop-prefer-global, channel table, limit). |
| BGP-85 | ipv4 mpls / ipv6 mpls channel (SAFI 4) | 6.4 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (channel ipv6/mc/mpls/vpn/flow, next-hop-prefer-global, channel table, limit). |
| BGP-86 | vpn4 mpls / vpn6 mpls channel (SAFI 128) | 6.4 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (channel ipv6/mc/mpls/vpn/flow, next-hop-prefer-global, channel table, limit). |
| BGP-87 | flow4 / flow6 channel (SAFI 133) | 6.4 | DONE | P3 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (channel ipv6/mc/mpls/vpn/flow, next-hop-prefer-global, channel table, limit). |
| BGP-88 | mandatory <switch> (channel) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-89 | next hop keep <switch\|ibgp\|ebgp> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-90 | next hop self <switch\|ibgp\|ebgp> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-91 | next hop address <ip> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-92 | next hop prefer global | 6.4 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (channel ipv6/mc/mpls/vpn/flow, next-hop-prefer-global, channel table, limit). |
| BGP-93 | gateway direct\|recursive | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-94 | igp table <name> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-95 | import table <switch> (Adj-RIB-In) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-96 | export table <switch> (Adj-RIB-Out) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-97 | secondary <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-98 | validate <switch> (FlowSpec) | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-99 | base table <name> (FlowSpec) | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-100 | extended next hop <switch> (RFC 8950) | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-101 | require extended next hop <switch> | 6.4 | DONE | P2 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-102 | add paths <switch\|rx\|tx> (RFC 7911) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-103 | require add paths <switch> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-104 | aigp <switch\|originate> (RFC 7311) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-105 | cost <number> | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-106 | graceful restart <switch> (channel) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-107 | long lived graceful restart <switch> (channel) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-108 | long lived stale time <number> (channel) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-109 | missing lladdr self (channel ipv6) | 6.4 | PERLU VERIFIKASI | P2 | PERLU VERIFIKASI: muncul di contoh resmi Bab 6.4 tapi TIDAK ADA di daftar opsi channel maupun penjelasannya — diduga opsi IPv6-only tak terdokumentasi / peninggalan BIRD 1.x. Cek `bird -p` / source sebelum implementasi. |
| BGP-110 | table <name> (channel, Bab 3.5) | 6.4 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (channel ipv6/mc/mpls/vpn/flow, next-hop-prefer-global, channel table, limit). |
| BGP-111 | bgp_path (bgppath) | 6.4 | DONE | P1 | DONE (B5): match as-path via `accept path-mask` (`bgp_path ~ [= * ASN * =]`, mock A B5). |
| BGP-112 | bgp_local_pref [I] (int) | 6.4 | DONE | P1 | DONE (B5): match nilai (`accept local-pref/med = N`, COND `bgp_local_pref>=N`) + set di filter (`set bgp_local_pref/bgp_med`); set export + set import-match via community sudah ada sebelumnya. |
| BGP-113 | bgp_med [O] (int) | 6.4 | DONE | P1 | DONE (B5): match nilai (`accept local-pref/med = N`, COND `bgp_local_pref>=N`) + set di filter (`set bgp_local_pref/bgp_med`); set export + set import-match via community sudah ada sebelumnya. |
| BGP-114 | bgp_origin (enum: ORIGIN_IGP/EGP/INCOMPLETE) | 6.4 | DONE | P1 | DONE (B5): match `accept origin` + set `bgp_origin` (enum ORIGIN) di filter. |
| BGP-115 | bgp_next_hop (ip) | 6.4 | DONE | P1 | DONE (B5): match `accept next-hop` + set `bgp_next_hop` di filter. |
| BGP-116 | bgp_atomic_aggr [O] (void) | 6.4 | MISSING | P1 |  |
| BGP-117 | bgp_aggregator [O] (void) | 6.4 | MISSING | P1 | Tidak bisa diakses dari filter (per docs). |
| BGP-118 | bgp_community [O] (clist) | 6.4 | DONE | P1 | DONE (B5+B8): BIRD-B5-REPORT.md §6 + BIRD-B8-REPORT.md §2.6 (F1–F7: var-set, method, accessor baru); mock B8 184 PASS. + DONE (B5+B8+B9): BIRD-B9-REPORT.md §2.8 (filter().min/.max, enum-set, atribut mpls/babel); mock B9 285 PASS. (method add/delete/filter/empty untuk clist/eclist/lclist + filter().min/.max + match). |
| BGP-119 | bgp_ext_community [O] (eclist) | 6.4 | DONE | P1 | DONE (B5+B8): BIRD-B5-REPORT.md §6 + BIRD-B8-REPORT.md §2.6 (F1–F7: var-set, method, accessor baru); mock B8 184 PASS. + DONE (B5+B8+B9): BIRD-B9-REPORT.md §2.8 (filter().min/.max, enum-set, atribut mpls/babel); mock B9 285 PASS. (method add/delete/filter/empty untuk clist/eclist/lclist + filter().min/.max + match). |
| BGP-120 | bgp_large_community [O] (lclist) | 6.4 | DONE | P1 | DONE (B5+B8): BIRD-B5-REPORT.md §6 + BIRD-B8-REPORT.md §2.6 (F1–F7: var-set, method, accessor baru); mock B8 184 PASS. + DONE (B5+B8+B9): BIRD-B9-REPORT.md §2.8 (filter().min/.max, enum-set, atribut mpls/babel); mock B9 285 PASS. (method add/delete/filter/empty untuk clist/eclist/lclist + filter().min/.max + match). |
| BGP-121 | bgp_originator_id [I,O] (quad) | 6.4 | DONE | P1 | DONE (B5): match `accept originator-id`; set ditolak sengaja (tugas RR/otomatis). |
| BGP-122 | bgp_cluster_list [I,O] (clist) | 6.4 | DONE | P1 | DONE (B5+B8): match `accept cluster-list` + method clist (add/delete/filter/empty). |
| BGP-123 | bgp_aigp [O] (void) | 6.4 | MISSING | P1 | Tidak bisa diakses dari filter (per docs). |
| BGP-124 | bgp_otc [O] (int, RFC 9234) | 6.4 | DONE | P1 | DONE (B5): match `accept otc`; set ditolak (diset otomatis via `local role`). |
| BGP-125 | attribute bgp <number> bytestring <name>; | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-127 | description "<text>"; (protocol-level, Bab 3.4) | 6.4 | PARTIAL | P1 | PARTIAL: baru ada sebagai deskripsi per neighbor (BGP-71); deskripsi protocol-level terpisah BELUM ADA. |
| BGP-128 | disabled (protocol-level, Bab 3.4) | 6.4 | DONE | P1 | DONE (B1): tree/conf-bgp.xml (neighbor-view) + sbin/titian-bgp.sh generate; tanpa laporan batch B1 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| BGP-129 | import limit / export limit (channel, Bab 3.5) | 6.4 | DONE | P1 | DONE (B6): BIRD-B6-REPORT.md — titian-global.sh / titian-bgp.sh; mock 146 PASS. (channel ipv6/mc/mpls/vpn/flow, next-hop-prefer-global, channel table, limit). |
| BGP-130 | show status (birdc) | 4.3 | DONE | P2 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-131 | show protocols [all] [name] (birdc) | 4.3 | DONE | P1 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-132 | show route [for\|in <prefix>] [table ...] [protocol ...] [(export\|preexport\|noexport) ...] [filter ...\|where ...] [(stats\|count)] | 4.3 | PARTIAL | P1 | PARTIAL (B7): `show route` + 13 varian di tree/en-show-birdc.xml (all/count/stats/for/in/table/protocol/export/preexport/noexport/filter/where); belum: import/export table channel-internal + `primary`/`filtered`. |
| BGP-133 | show bfd sessions [name] [address ...] [all] (birdc) | 4.3 | DONE | P2 | `show bfd sessions` ada di tree/conf-bfd.xml (titian-bfd.sh show-sessions -> birdc); bergantung `protocol bfd` (IN PROGRESS terpisah). |
| BGP-134 | show symbols [table\|filter\|function\|protocol\|template\|roa\|symbol] | 4.3 | DONE | P2 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-135 | configure [soft] ["<file>"] [timeout [<num>]] | 4.3 | PARTIAL | P1 | PARTIAL (B7): `configure check/confirm/undo` ada (BGP-136/137); `configure [soft] ["<file>"] [timeout]` belum. |
| BGP-136 | configure check ["<config file>"] | 4.3 | DONE | P1 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-137 | configure confirm / configure undo | 4.3 | DONE | P1 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-138 | enable\|disable\|restart <name>\|"<pattern>"\|all | 4.3 | DONE | P1 | `enable/disable/restart/restart all` ada di tree/bird.xml (birdc). |
| BGP-139 | reload [in\|out] <name>\|"<pattern>"\|all | 4.3 | DONE | P1 | `reload in/out <nama>` + `reload filters` ada di tree/bird.xml (bird2 `birdc reload`, bird3 `birdc reload filters` via titian-bird.sh). |
| BGP-140 | debug <protocol\|pattern\|all> all\|off\|{...} | 4.3 | DONE | P1 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-141 | down / graceful restart (birdc) | 4.3 | DONE | P1 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-142 | eval <expr> (birdc) | 4.3 | DONE | P2 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-143 | dump resources\|sockets\|interfaces\|neighbors\|attributes\|routes\|protocols "<file>" | 4.3 | DONE | P2 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-144 | echo all\|off\|{ <daftar log class> } [ <buffer-size> ] | 4.3 | DONE | P2 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-145 | mrt dump table <name>\|"<pattern>" to "<filename>" [filter ...\|where ...] | 4.3 | DONE | P2 | DONE (B7): BIRD-B7-REPORT.md — titian-birdc.sh + tree/en-show-birdc.xml; mock 182 PASS. |
| BGP-146 | show bgp [summary] | 4.3 | N/A | P3 | TIDAK ADA di BIRD 2.16 (Bab 4.3). `show bgp` Titian adalah perintah klish (intent + section), bukan birdc; `show bgp summary` ala vendor harus dibangun dari `show protocols all` + `show route protocol ... count`. |

### 2.4 Bab 6 OSPF/RIP/Static/Kernel/BFD/Device/Direct/Pipe

| Item | Sintaks BIRD | Bab docs | Status | Prioritas | Catatan |
|---|---|---|---|---|---|
| O1 | protocol ospf [v2\|v3] <name> { ... } | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O2 | rfc1583compat <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O3 | rfc5838 <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O4 | instance id <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O5 | stub router <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O6 | tick <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O7 | ecmp <switch> [limit <num>]; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O8 | merge external <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O9 | graceful restart <switch>\|aware; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O10 | graceful restart time <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O11 | ipv4 { ... }; / ipv6 { ... }; (channel) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O12 | area <id> { ... } | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O13 | stub; (area) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O14 | nssa; (area) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O15 | summary <switch>; (area) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O16 | default nssa <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O17 | default cost <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O18 | default cost2 <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O19 | translator <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O20 | translator stability <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O21 | networks { <prefix>; <prefix> hidden; }; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O22 | external { <prefix>; <prefix> hidden; <prefix> tag <num>; }; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O23 | stubnet <prefix>; / stubnet <prefix> { hidden; summary; cost; }; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O24 | interface <pattern> [instance <num>] { ... } | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O25 | cost <num>; (interface) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O26 | stub <switch>; (interface) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O27 | hello <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O28 | poll <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O29 | retransmit <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O29a | transmit delay <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O30 | priority <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O31 | wait <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O32 | dead count <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O33 | dead <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O34 | secondary <switch>; | 6.11 | PERLU VERIFIKASI | P1 | PERLU VERIFIKASI (B0): HANYA ada di blok template (L3869), TIDAK ADA entri deskripsi di Bab 6.11 — arti + default tidak terverifikasi dari docs; cek source BIRD / `bird -p` sebelum masuk klish. |
| O35 | rx buffer [normal\|large\|<num>]; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O36 | tx length <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O37 | type [broadcast\|bcast\|pointopoint\|ptp\|nonbroadcast\|nbma\|pointomultipoint\|ptmp]; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O38 | link lsa suppression <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O39 | strict nonbroadcast <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O40 | real broadcast <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O41 | ptp netmask <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O42 | ptp address <switch>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O43 | check link <switch>; (interface) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O44 | bfd <switch>; (interface) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O45 | ecmp weight <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O46 | ttl security [<switch>; \| tx only] | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O47 | tx class\|dscp <num>; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O48 | tx priority <num>; | 6.11 | MISSING | P1 | TERVERIFIKASI B0: default lihat opsi umum (Bab 3). (Catatan: tx priority Linux-specific, 3.4-10 = N/A.) |
| O49 | authentication none\|simple\|cryptographic; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O50 | password "<text>"; / password "<text>" { id; generate/accept/from/to; algorithm ... }; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O51 | neighbors { <ip>; <ip> eligible; }; | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O52 | virtual link <id> [instance <num>] { ... } | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O53 | hello <num>; (vlink) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O54 | retransmit <num>; (vlink) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O55 | wait <num>; (vlink) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O56 | dead count <num>; (vlink) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O57 | dead <num>; (vlink) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O58 | authentication none\|simple\|cryptographic; (vlink) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O59 | password "<text>" { ... algorithm ... }; (vlink) | 6.11 | DONE | P1 | DONE (B2): tree/conf-ospf.xml + sbin/titian-ospf.sh generate; tanpa laporan batch B2 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| O60 | ospf_metric1 = <num>; (filter) | 6.11 | PARTIAL | P1 | TERVERIFIKASI B0 + PARTIAL (B4): sintaks + perilaku terverifikasi; bisa di-set via static per-route attr (`ospf-metric1`, sbin/titian-static.sh + tree/conf-static.xml); assignment umum di filter (Bab 5) belum. |
| O61 | ospf_metric2 = <num>; (filter) | 6.11 | PARTIAL | P1 | TERVERIFIKASI B0 + PARTIAL (B4): default 10000; bisa di-set via static per-route attr (`ospf-metric2`, B4); filter umum belum. |
| O62 | ospf_tag = <num>; (filter) | 6.11 | PARTIAL | P1 | TERVERIFIKASI B0 + PARTIAL (B4): default 0; bisa di-set via static per-route attr (`ospf-tag`, B4); filter umum belum. |
| O67 | ospf_router_id | 6.11 | MISSING | P1 | BARU B0: atribut ke-4 OSPF, read-only (hanya dibaca di filter) — router ID router yang mengiklankan route/network itu; tidak ada di daftar 66 item sebelumnya. |
| O63 | router id <ipv4>; (global, Bab 3.2) | 6.11 | DONE | P1 | Sama dengan 3.2-19 / BGP-81; `router-id` bird-view. |
| O64 | export ke OSPF: ipv4 { export where source = RTS_STATIC; }; | 6.11 | DONE | P1 | DONE (B2): channel import/export OSPF + `export-ospf-metric1/metric2/tag` (tree/conf-ospf.xml). |
| O65 | stub router + GR interlock (lihat O5, O9) | 6.11 | DONE | P1 | DONE (B2+B4): `stub-router` (O5) + `graceful-restart` OSPF (O9) + `graceful-restart` kernel (K7). |
| O66 | OSPFv3 IPv4 (RFC 5838): protocol ospf v3 { ipv4 { ... }; } | 6.11 | DONE | P1 | DONE (B2): channel ipv4 di instance ospfv3 via RFC 5838 (`channel-set ... ipv4`, titian-ospf.sh:510). |
| R1 | protocol rip [ng] [<name>] { ... } | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R2 | infinity <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R3 | ecmp <switch> [limit <number>]; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R4 | ipv4 { ... }; / ipv6 { ... }; (channel) | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R5 | interface <pattern> { ... } | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R6 | metric <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R7 | mode multicast\|broadcast; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R8 | passive <switch>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R9 | address <ip>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R10 | port <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R11 | version 1\|2; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R12 | version only <switch>; | 6.15 | PERLU VERIFIKASI | P1 | PERLU VERIFIKASI: dideskripsikan di teks Bab 6.15 tapi TIDAK ADA di blok template sintaks — verifikasi dengan `bird -p` / parse test sebelum masuk klish. |
| R13 | split horizon <switch>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R14 | poison reverse <switch>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R15 | demand circuit <switch>; (Triggered RIP RFC 2091) | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R16 | check zero <switch>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R17 | update time <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R18 | timeout time <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R19 | garbage time <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R20 | ecmp weight <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R21 | ttl security <switch>; \| tx only; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R22 | tx class\|dscp <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R23 | tx priority <number>; | 6.15 | MISSING | P1 | (Linux-specific, lihat 3.4-10.) |
| R24 | rx buffer <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R25 | tx length <number>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R26 | check link <switch>; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R27 | authentication none\|plaintext\|cryptographic; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R28 | password "<text>"; / password "<text>" { id; generate/accept/from/to; algorithm ... }; | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R29 | rip_metric (int, filter; range 0-infinity) | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| R30 | rip_tag (int, filter; 16-bit) | 6.15 | DONE | P1 | DONE (B3): tree/conf-rip.xml + sbin/titian-rip.sh generate; tanpa laporan batch B3 — pemetaan dari kode (verify.py pasca-B9 NOL error). |
| S1 | protocol static [<name>] { ... } | 6.17 | DONE | P1 | DONE (B4): view `static` tree/conf-static.xml + sbin/titian-static.sh (intent + generate `protocol static static4/static6`); `show static` ada. BERBEDA dari static route kernel (tree/conf-route-fbsd.xml) — itu `route` OS, bukan BIRD. |
| S2 | check link <switch>; | 6.17 | DONE | P1 | DONE (B4): `check-link` on/off di tree/conf-static.xml + `check-link-set`, sbin/titian-static.sh; default off. |
| S3 | igp table <name>; | 6.17 | DONE | P1 | DONE (B4): `igp-table <name>` di tree/conf-static.xml + `igp-table-set`, sbin/titian-static.sh. |
| S4 | ipv4 { ... }; / ipv6 { ... }; / flow4; / flow6 { table <name>; }; | 6.17 | DONE | P1 | DONE (B8 §2.3): channel `flow4;` / `flow6 { table; };` di static (S4 PARTIAL B4 → SELESAI). |
| S5 | route <prefix> [mpls <number>] via <ip>\|"<interface>" [via ...]; | 6.17 | DONE | P1 | DONE (B4): `route <prefix> via <IP>` + `via-interface` + multipath (via-add berkali-kali) di tree/conf-static.xml + sbin/titian-static.sh (`route-via-add`, `route-via-iface-add`); kualifikasi `mpls <number>` per-route BELUM (subsistem MPLS, lihat S32). |
| S6 | route <prefix> [mpls <number>] recursive <ip> [mpls <num>[/<num>...]]; | 6.17 | DONE | P1 | DONE (B4): `route ... recursive <IP>` (`route-recursive-set`, sbin/titian-static.sh); varian `recursive ... mpls` BELUM (lihat S32). |
| S7 | route <prefix> [mpls <number>] blackhole\|unreachable\|prohibit; | 6.17 | DONE | P1 | DONE (B4): `blackhole` / `unreachable` / `prohibit` (`route-sink-set`, sbin/titian-static.sh). |
| S8 | route <prefix> max <int> as <int>; (ROA) | 6.17 | DONE | P3 | DONE (B9 §2.7): route ROA/ASPA statis (`roa-add`, `aspa-providers-add`/`aspa-transit-add`, instance static-roa4/6/aspa). |
| S9 | route aspa <int> providers <int> [, ...]; / route aspa <int> transit; | 6.17 | DONE | P3 | DONE (B9 §2.7): route ROA/ASPA statis (`roa-add`, `aspa-providers-add`/`aspa-transit-add`, instance static-roa4/6/aspa). |
| S10 | route flow4 { ... }; / route flow6 { ... }; | 6.17 | DONE | P2 | DONE (B8 §2.3): `route flow4/6 { ... };` + 16 komponen (S16–S29). |
| S11 | via <ip> bfd (per-nexthop) | 6.17 | DONE | P1 | DONE (B4): `bfd` per-nexthop (`route-via-set ... bfd`, sbin/titian-static.sh); bergantung `protocol bfd` (IN PROGRESS terpisah). Di Static BFD bersifat MENGONTROL (bukan advisory). |
| S12 | via <ip> dev <text> (per-nexthop) | 6.17 | DONE | P1 | DONE (B4): `dev "<iface>"` per-nexthop (`route-via-set ... dev`, sbin/titian-static.sh). |
| S13 | via <ip> mpls <num>[/<num>...] (per-nexthop) | 6.17 | MISSING | P1 |  |
| S14 | via <ip> onlink (per-nexthop) | 6.17 | DONE | P1 | DONE (B4): `onlink` per-nexthop (`route-via-set ... onlink`, sbin/titian-static.sh). Interface wajib format link-local-scope (mis. `192.0.2.1%eth0`). |
| S15 | via <ip> weight <num> (per-nexthop) | 6.17 | DONE | P1 | DONE (B4): `weight <num>` per-nexthop (`route-via-set ... weight`, 1-256). Ambiguitas docs SELESAI: teks `weight switch` adalah typo docs, contoh memakai angka. |
| S16 | dst <inet4>; / dst <inet6> [offset <num>]; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S17 | src <inet4>; / src <inet6> [offset <num>]; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S18 | proto <numbers-match>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S19 | port <numbers-match>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S20 | dport <numbers-match>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S21 | sport <numbers-match>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S22 | icmp type <numbers-match>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S23 | icmp code <numbers-match>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S24 | tcp flags <bitmask-match>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S25 | length <numbers-match>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S26 | dscp <numbers-match>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S27 | fragment <fragmentation-type>; (flowspec) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S28 | next header <numbers-match>; (flowspec, IPv6) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S29 | label <bitmask-match>; (flowspec, IPv6) | 6.17 | DONE | P2 | DONE (B8 §2.3): komponen flowspec di `flow-route` (titian-static.sh + conf-static.xml); mock C B8 30 PASS. |
| S30 | route <prefix> via <ip> { <filter expression>; ... }; (per-route filter) | 6.17 | PARTIAL | P1 | PARTIAL (B4): subset atribut per-route via `route-attr-set` (ospf-metric1/2/tag, bgp-community, bgp-large-community) di tree/conf-static.xml + sbin/titian-static.sh; filter expression umum (mis. `if ...`) BELUM. |
| S31 | igp_metric (atribut, di filter) | 6.17 | DONE | P1 | DONE (B5): `igp_metric` bisa di-set di filter (settable_attr, BIRD-B5-REPORT.md §6). |
| S32 | MPLS-aware: channel primer + channel MPLS | 6.17 | MISSING | P3 |  |
| K1 | protocol kernel [<name>] { ... } | 6.8 | DONE | P1 | DONE (B4): view `kernel` tree/conf-kernel.xml + sbin/titian-protocol.sh (intent + generate `protocol kernel` ipv4/ipv6); `show kernel` ada. |
| K2 | persist <switch>; | 6.8 | DONE | P1 | DONE (B4): `persist` (`kernel-set persist`, sbin/titian-protocol.sh); default TIDAK DINYATAKAN docs — hanya ditulis bila di-set eksplisit, jangan ditebak. |
| K3 | scan time <number>; | 6.8 | DONE | P1 | DONE (B4): `scan-time <num>` (`kernel-set scan-time`, sbin/titian-protocol.sh); default TIDAK DINYATAKAN docs. |
| K4 | learn <switch>\|all; | 6.8 | DONE | P1 | DONE (B4): `learn` / `learn all` (`kernel-set learn`, sbin/titian-protocol.sh); default off; `learn all` = impor juga device route kernel. |
| K5 | kernel table <number>; | 6.8 | N/A | P3 | Hanya OS multi-tabel (Linux); FreeBSD/BSDRP: TIDAK RELEVAN — satu tabel kernel. |
| K6 | metric <number>; | 6.8 | N/A | P3 | Linux-only; di FreeBSD kemungkinan TIDAK ADA padanannya. |
| K7 | graceful restart <switch>; | 6.8 | DONE | P1 | DONE (B4): `graceful-restart` (`kernel-set graceful-restart`, sbin/titian-protocol.sh); default TIDAK DINYATAKAN docs; interlock dengan O65 (OSPF GR). |
| K8 | merge paths <switch> [limit <number>]; | 6.8 | DONE | P1 | DONE (B4): `merge-paths` + `merge-paths limit <num>` (`kernel-set merge-paths`, sbin/titian-protocol.sh); default disabled; limit 16 bila enabled (ECMP ke kernel). |
| K9 | netlink rx buffer <number>; | 6.8 | N/A | P3 | Linux-only (netlink). |
| K10 | krt_source (int, read-only) | 6.8 | MISSING | P2 | MISSING (B4): atribut `krt_*` tidak diimplementasi; `krt_source` BSD (dari flag STATIC dan PROTOx) belum diekspos klish. |
| K11 | krt_metric (int, Linux) | 6.8 | N/A | P3 | Linux-only. |
| K12 | krt_prefsrc (ip, Linux) | 6.8 | N/A | P3 | Linux-only. |
| K13 | krt_realm (int, Linux) | 6.8 | N/A | P3 | Linux-only. |
| K14 | krt_scope (int, Linux IPv4) | 6.8 | N/A | P3 | Linux-only. |
| K15 | krt_* TCP tuning (krt_mtu, krt_window, krt_rtt, ..., Linux) | 6.8 | N/A | P3 | Linux-only; praktis TIDAK RELEVAN untuk Titian/FreeBSD. |
| K16 | ipv4 { ... }; / ipv6 [sadr] { ... }; (+ MPLS di Linux) | 6.8 | DONE | P1 | DONE (B4): channel `ipv4` / `ipv6` dengan import/export all/none (`kernel-channel-set`, sbin/titian-protocol.sh); SADR/MPLS Linux tidak relevan. |
| B1 | protocol bfd [<name>] { ... } | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B2 | accept [ipv4\|ipv6] [direct\|multihop]; | 6.3 | IN PROGRESS | P1 | IN PROGRESS TERPISAH. Refresh 16 Nov: belum ada perintah klish (BFD-DESIGN §8: `accept` tidak diekspos v1). |
| B3 | strict bind <switch>; | 6.3 | IN PROGRESS | P1 | IN PROGRESS TERPISAH. Refresh 16 Nov: belum ada perintah klish (BFD-DESIGN §8: `strict bind` tidak diekspos v1; relevansi FreeBSD belum jelas). |
| B4 | zero udp6 checksum rx <switch>; | 6.3 | IN PROGRESS | P1 | IN PROGRESS TERPISAH. Refresh 16 Nov: belum ada perintah klish (BFD-DESIGN §8: `zero udp6 checksum rx` tidak diekspos v1). |
| B5 | interface <pattern> { ... } | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B6 | multihop { ... } | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B7 | neighbor <ip> [dev "<interface>"] [local <ip>] [multihop <switch>]; | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B8 | interval <time>; | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B9 | min rx interval <time>; | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B10 | min tx interval <time>; | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B11 | idle tx interval <time>; | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B12 | multiplier <num>; | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B13 | passive <switch>; | 6.3 | DONE | P1 | DONE (BFD): sbin/titian-bfd.sh + tree/conf-bfd.xml (BFD-DESIGN.md); mock 51/51 LOLOS. |
| B14 | authentication none; | 6.3 | IN PROGRESS | P1 | IN PROGRESS TERPISAH. Refresh 16 Nov: belum ada perintah klish (BFD-DESIGN §8: authentication/password BFD tidak diekspos v1). |
| B15 | authentication simple; | 6.3 | IN PROGRESS | P1 | IN PROGRESS TERPISAH. Refresh 16 Nov: belum ada perintah klish (BFD-DESIGN §8: authentication/password BFD tidak diekspos v1). |
| B16 | authentication [meticulous] keyed md5\|sha1; | 6.3 | IN PROGRESS | P1 | IN PROGRESS TERPISAH. Refresh 16 Nov: belum ada perintah klish (BFD-DESIGN §8: authentication/password BFD tidak diekspos v1). |
| B17 | password "<text>"; / password "<text>" { id; generate/accept/from/to; }; | 6.3 | IN PROGRESS | P1 | IN PROGRESS TERPISAH. Refresh 16 Nov: belum ada perintah klish (BFD-DESIGN §8: authentication/password BFD tidak diekspos v1). |
| D1 | protocol device [<name>] { ... } | 6.6 | DONE | P1 | DONE (B4): view `device` tree/conf-device.xml + sbin/titian-protocol.sh (intent + generate `protocol device`); `show device` ada. |
| D2 | scan time <number>; | 6.6 | DONE | P1 | DONE (B4): `scan-time <num>` (`device-scan-time-set`, sbin/titian-protocol.sh); default TIDAK DINYATAKAN docs (hanya 'large value') — Titian menulis 10 bila tidak diset eksplisit (nilai contoh docs). |
| D3 | interface <pattern> [, ...] { ... } | 6.6 | DONE | P1 | DONE (B4): `interface <pattern>` (`device-interface-add`, sbin/titian-protocol.sh). |
| D4 | preferred <ip>; (di dalam interface) | 6.6 | DONE | P1 | DONE (B4): `preferred <ip>` di dalam interface (`device-preferred-add`, sbin/titian-protocol.sh). |
| T1 | protocol direct [<name>] { ... } | 6.7 | DONE | P1 | DONE (B4): view `direct` generik tree/conf-direct.xml + sbin/titian-direct.sh (intent + generate `protocol direct`); jalur lama `redistribute direct enable` (sbin/titian-redist.sh) tetap ada sebagai legacy. |
| T2 | ipv4 { ... }; / ipv6 [sadr] { ... }; | 6.7 | DONE | P1 | DONE (B4): channel `ipv4` / `ipv6` / `ipv6-sadr` (`channel-add`, sbin/titian-direct.sh). |
| T3 | interface <pattern> [, ...] { ... } | 6.7 | DONE | P1 | DONE (B4): `interface <pattern>` boleh banyak, dukung `-pengecualian` + `*` (`interface-add`, sbin/titian-direct.sh). |
| T4 | check link <switch>; | 6.7 | DONE | P1 | DONE (B4): `check-link` (`check-link-set`, sbin/titian-direct.sh); default no. |
| P1 | protocol pipe [<name>] { ... } | 6.13 | DONE | P1 | DONE (B4): view `pipe` tree/conf-pipe.xml + sbin/titian-pipe.sh (intent + generate `protocol pipe`); `show pipe` ada. |
| P2 | table <table>; (primary) | 6.13 | DONE | P1 | DONE (B4): `table <table>` (`pipe-set ... table`, sbin/titian-pipe.sh). |
| P3 | peer table <table>; | 6.13 | DONE | P1 | DONE (B4): `peer-table <table>` (`pipe-set ... peer-table`, sbin/titian-pipe.sh) — satu-satunya opsi khusus Pipe. |
| P4 | export <filter>; / export filter { ... }; | 6.13 | PARTIAL | P1 | PARTIAL (B4): `export all/none/filter <nama>` DONE (`export filter`, sbin/titian-pipe.sh); filter INLINE `export filter { ... }` BELUM. Arah primary -> secondary. |
| P5 | import <filter>; / import filter { ... }; | 6.13 | PARTIAL | P1 | PARTIAL (B4): `import all/none/filter <nama>` DONE (`import filter`, sbin/titian-pipe.sh); filter INLINE `import filter { ... }` BELUM. Arah secondary -> primary. |

### 2.5 Bab 6 Aggregator/Babel/BMP/L3VPN/MRT/Perf/RAdv/RPKI

| Item | Sintaks BIRD | Bab docs | Status | Prioritas | Catatan |
|---|---|---|---|---|---|
| AG1 | table <table> | 6.1 | N/A | P3 | N/A (F3.2): `protocol aggregator` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. Generator titian-aggregator.sh + conf-aggregator.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 184 PASS). |
| AG2 | export ... (channel export clause standar) | 6.1 | N/A | P3 | N/A (F3.2): `protocol aggregator` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. Generator titian-aggregator.sh + conf-aggregator.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 184 PASS). |
| AG3 | aggregate on <expr\|attribute> [, ...] | 6.1 | N/A | P3 | N/A (F3.2): `protocol aggregator` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. Generator titian-aggregator.sh + conf-aggregator.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 184 PASS). |
| AG4 | merge by { <filter code> } | 6.1 | N/A | P3 | N/A (F3.2): `protocol aggregator` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. Generator titian-aggregator.sh + conf-aggregator.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 184 PASS). |
| AG5 | import ... | 6.1 | N/A | P3 | N/A (F3.2): `protocol aggregator` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. Generator titian-aggregator.sh + conf-aggregator.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 184 PASS). |
| AG6 | peer table <table> | 6.1 | N/A | P3 | N/A (F3.2): `protocol aggregator` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. Generator titian-aggregator.sh + conf-aggregator.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 184 PASS). |
| BB1 | ipv4 { <channel config> }; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB2 | ipv6 [sadr] { <channel config> }; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB3 | randomize router id <switch>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB4 | type <wired\|wireless\|tunnel>; (interface) | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB5 | rxcost <number>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB6 | limit <number>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB7 | hello interval <time>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB8 | update interval <time>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB9 | port <number>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB10 | tx class <number>; / tx dscp <number>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB11 | tx priority <number>; | 6.2 | MISSING | P3 | (Linux-specific, lihat 3.4-10.) |
| BB12 | rx buffer <number>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB13 | tx length <number>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB14 | check link <switch>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB15 | next hop ipv4 <address>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB16 | next hop ipv6 <address>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB17 | extended next hop <switch>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB18 | rtt cost <number>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB19 | rtt min <time>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB20 | rtt max <time>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB21 | rtt decay <number>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB22 | send timestamps <switch>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB23 | authentication <none\|mac [permissive]>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB24 | password "<text>"; / password "<text>" { ... }; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB25 | password: id <num>; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB26 | password: generate from "<date>"; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB27 | password: generate to "<date>"; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB28 | password: accept from "<date>"; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB29 | password: accept to "<date>"; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB30 | password: from "<date>"; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB31 | password: to "<date>"; | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB32 | password: algorithm (hmac sha1\|hmac sha256\|hmac sha384\|hmac sha512\|blake2s128\|blake2s256\|blake2b256\|blake2b512); | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BB33 | babel_metric (atribut route, read-only) | 6.2 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-babel.sh + conf-babel.xml; §2.3; BB11 tx-priority TIDAK — Linux-only). |
| BMP1 | tx buffer limit <number>; | 6.5 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-bmp.sh + conf-bmp.xml; §2.2). |
| BMP2 | station address ip <ip> port <number>; | 6.5 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-bmp.sh + conf-bmp.xml; §2.2). |
| BMP3 | monitoring rib in pre_policy; | 6.5 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-bmp.sh + conf-bmp.xml; §2.2). |
| BMP4 | monitoring rib in post_policy; | 6.5 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-bmp.sh + conf-bmp.xml; §2.2). |
| VPN1 | route distinguisher <rd>; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| VPN2 | rd <rd>; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| VPN3 | import target <ec\|ec-set>; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| VPN4 | export target <ec\|ec-set>; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| VPN5 | route target <ec\|ec-set>; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| VPN6 | ipv4 { table <table>; }; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| VPN7 | ipv6 { table <table>; }; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| VPN8 | vpn4 { table <table>; }; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| VPN9 | vpn6 { table <table>; }; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| VPN10 | mpls { label policy <vrf\|aggregate>; }; | 6.9 | N/A | P3 | N/A (F3.2): `protocol l3vpn` TIDAK ada di BIRD 2.20.0 — bird -p menolak (CF_SYM_UNDEFINED, BIRD 2.20.0 FreeBSD port net/bird2); fitur BIRD 3. L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator titian-l3vpn.sh + conf-l3vpn.xml dipertahankan untuk BIRD 3 (mock internal konsisten, 285 PASS). |
| MRT1 | table <name\|"pattern">; | 6.10 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-mrt.sh + conf-mrt.xml; §2.2). |
| MRT2 | filter { <filter commands> }; | 6.10 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-mrt.sh + conf-mrt.xml; §2.2). |
| MRT3 | where <filter expression>; | 6.10 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-mrt.sh + conf-mrt.xml; §2.2). |
| MRT4 | filename "<filename>"; | 6.10 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-mrt.sh + conf-mrt.xml; §2.2). |
| MRT5 | period <number>; | 6.10 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-mrt.sh + conf-mrt.xml; §2.2). |
| MRT6 | always add path <switch>; | 6.10 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-mrt.sh + conf-mrt.xml; §2.2). |
| PF1 | mode <import\|export>; | 6.12 | N/A | P3 | N/A (B0): protokol benchmark eksperimental BIRD — generator fake route + pengukur waktu; interface konfigurasi tidak stabil dan bisa berubah tanpa pemberitahuan; docs melarang simpan instance Perf di config produksi. Tidak ada perintah operasional yang bermakna bagi operator. Default `import`. |
| PF2 | repeat <number>; | 6.12 | N/A | P3 | N/A (B0): lihat PF1. Default 4 iterasi per langkah exponent. |
| PF3 | exp from <number>; | 6.12 | N/A | P3 | N/A (B0): lihat PF1. Default 10 (2^10 route per langkah awal). |
| PF4 | exp to <number>; | 6.12 | N/A | P3 | N/A (B0): lihat PF1. Default 20. |
| PF5 | threshold min <time>; | 6.12 | N/A | P3 | N/A (B0): lihat PF1. Default 1 ms. |
| PF6 | threshold max <time>; | 6.12 | N/A | P3 | N/A (B0): lihat PF1. Default 500 ms. |
| RA1 | interface <pattern> [, ...] { <options> }; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA2 | prefix <prefix> { <options> }; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA3 | rdnss { <options> }; / rdnss <address>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA4 | dnssl { <options> }; / dnssl <domain>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA5 | custom option type <number> value <bytestring>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA6 | trigger <prefix>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA7 | propagate routes <switch>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA8 | max ra interval <expr>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA9 | min ra interval <expr>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA10 | min delay <expr>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA11 | solicited ra unicast <switch>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA12 | managed <switch>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA13 | other config <switch>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA14 | link mtu <expr>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA15 | reachable time <expr>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA16 | retrans timer <expr>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA17 | current hop limit <expr>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA18 | default lifetime <expr> [sensitive <switch>]; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA19 | default preference <low\|medium\|high>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA20 | route lifetime <expr> [sensitive <switch>]; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA21 | route preference <low\|medium\|high>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA22 | prefix linger time <expr>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA23 | route linger time <expr>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA24 | rdnss local <switch>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA25 | dnssl local <switch>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA26 | custom option local <switch>; | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA27 | skip <switch>; (prefix) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA28 | onlink <switch>; (prefix) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA29 | autonomous <switch>; (prefix) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA30 | valid lifetime <expr> [sensitive <switch>]; (prefix) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA31 | preferred lifetime <expr> [sensitive <switch>]; (prefix) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA32 | ns <address>; (RDNSS) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA33 | lifetime [mult] <expr>; (RDNSS) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA34 | domain <address>; (DNSSL) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA35 | lifetime [mult] <expr>; (DNSSL) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA36 | ra_preference (enum: RA_PREF_LOW / RA_PREF_MEDIUM / RA_PREF_HIGH) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RA37 | ra_lifetime (int) | 6.14 | DONE | P2 | DONE (B8): BIRD-B8-REPORT.md §2 — mock 184 PASS. (titian-radv.sh + conf-radv.xml; §2.4; RA36/37 juga atribut filter). |
| RK1 | roa4 { table <tab>; }; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK2 | roa6 { table <tab>; }; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK3 | aspa { table <tab>; }; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK4 | remote <ip> \| "<domain>" [port <num>]; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK5 | port <num>; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK6 | local address <ip>; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK7 | refresh [keep] <num>; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK8 | retry [keep] <num>; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK9 | expire [keep] <num>; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK10 | ignore max length <switch>; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK11 | min version <num>; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK12 | max version <num>; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK13 | transport tcp { <options> }; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK14 | transport ssh { <options> }; | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK15 | authentication <none\|md5>; (transport TCP) | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK16 | password "<text>"; (transport TCP) | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK17 | bird private key "<path>"; (transport SSH) | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK18 | remote public key "<path>"; (transport SSH) | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |
| RK19 | user "<name>"; (transport SSH) | 6.16 | DONE | P3 | DONE (B9): BIRD-B9-REPORT.md §2 — mock 285 PASS. (titian-rpki.sh + conf-rpki.xml; §2.1; roa_check/aspa_check sudah B5). |


### 2.6 Bab 4 Remote control — birdc (BARU B0)

16 dari 26 perintah Bab 4.3 sudah tercakup sebagai BGP-130..146 (§2.3) dan TIDAK diduplikasi di sini. Yang dicatat di bawah ini hanya 18 item yang benar-benar baru: 4.1 (5) + 4.2 (3) + 4.3 (10). Dikonfirmasi dari baca penuh `bird-4.html` L0-421: TIDAK ADA `show bgp` / `show bgp summary`, `show memory`, `exit`/`quit`, perintah `restrict`, perintah `mrtdump`, maupun `show ...` per-protokol selain OSPF/RIP/Static/BFD — status protokol lain dilihat lewat `show protocols [all]` (BGP-131).

| Item | Sintaks BIRD | Bab docs | Status | Prioritas | Catatan |
|---|---|---|---|---|---|
| BC1 | birdc [-r] [-v] [-s <socket>] | 4.1 | PARTIAL | P2 | PARTIAL: `birdc` dipakai internal oleh sbin/titian-bird.sh (`birdc show status` untuk deteksi versi, `birdc configure` saat generate); tidak diekspos sebagai perintah klish. |
| BC2 | birdc -r (restricted) | 4.1 | MISSING | P2 | Mode terbatas (hanya perintah read-only `show ...`) tidak diekspos klish. |
| BC3 | birdc -v (verbose codes) | 4.1 | MISSING | P2 | Numeric return codes bersama pesan tidak diekspos klish. |
| BC4 | birdc -s <socket> | 4.1 | MISSING | P2 | Socket kustom tidak diekspos; Titian memakai socket default. |
| BC5 | birdcl | 4.1 | N/A | P3 | N/A: varian ringan birdc tanpa editing/history Readline (environment resource-constrained); Titian memakai birdc biasa. |
| BC6 | cli "<name>"; | 4.2 | DONE | P2 | DONE (B7): `cli <Socket>` + `cli restrict` di global-view (titian-global.sh cli-add/del; mock G B7). |
| BC7 | cli "<name>" { restrict; }; | 4.2 | DONE | P2 | DONE (B7): `cli <Socket>` + `cli restrict` di global-view (titian-global.sh cli-add/del; mock G B7). |
| BC8 | socket utama bird.ctl (default; diubah via -s) | 4.2 | PARTIAL | P2 | PARTIAL: socket default `bird.ctl` dipakai internal (sbin/titian-bird.sh, tanpa `-s`); tidak bisa diubah via klish. Socket tambahan dihapus duluan saat shutdown; socket utama bertahan sampai akhir. |
| BC9 | show interfaces [summary] | 4.3 | DONE | P2 | DONE (B7): `show interfaces bird` (+summary) di tree/en-show-birdc.xml. |
| BC10 | show ospf interface [name] ["interface"] | 4.3 | DONE | P1 | DONE (B7): `show ospf interface/neighbors/state/topology/lsadb` (bentuk dasar; filter lsadb + kombinasi `all <nama>` belum — B7 §5). |
| BC11 | show ospf neighbors [name] ["interface"] | 4.3 | DONE | P1 | DONE (B7): `show ospf interface/neighbors/state/topology/lsadb` (bentuk dasar; filter lsadb + kombinasi `all <nama>` belum — B7 §5). |
| BC12 | show ospf state [all] [name] | 4.3 | DONE | P1 | DONE (B7): `show ospf interface/neighbors/state/topology/lsadb` (bentuk dasar; filter lsadb + kombinasi `all <nama>` belum — B7 §5). |
| BC13 | show ospf topology [all] [name] | 4.3 | DONE | P1 | DONE (B7): `show ospf interface/neighbors/state/topology/lsadb` (bentuk dasar; filter lsadb + kombinasi `all <nama>` belum — B7 §5). |
| BC14 | show ospf lsadb [global \| area <id> \| link] [type <num>] [lsid <id>] [self \| <router id>] [name] | 4.3 | DONE | P1 | DONE (B7): `show ospf interface/neighbors/state/topology/lsadb` (bentuk dasar; filter lsadb + kombinasi `all <nama>` belum — B7 §5). |
| BC15 | show rip interfaces [name] ["interface"] | 4.3 | DONE | P1 | DONE (B7): `show rip interfaces/neighbors` (bentuk dasar). |
| BC16 | show rip neighbors [name] ["interface"] | 4.3 | DONE | P1 | DONE (B7): `show rip interfaces/neighbors` (bentuk dasar). |
| BC17 | show static [name] | 4.3 | DONE | P1 | DONE (B4): `show static` di tree/conf-static.xml + sbin/titian-static.sh `show` (intent + section + status protokol BIRD). |
| BC18 | timeformat "<format1>" [limit "<format2>"] | 4.3 | DONE | P2 | DONE (B7): `timeformat` sesi birdc (+limit) di tree/en-show-birdc.xml. |

## 3. Daftar item BELUM DIBACA + BELUM TERVERIFIKASI

### 3a. BELUM DIBACA (rate limit 429 — baca ulang setelah reda, JANGAN diulang saat masih 429)

Batch B0 (16 Nov 07:56 WIB) SUDAH menyelesaikan semua yang tertunda di sini: Perf (6.12), RAdv (6.14), RPKI (6.16), Bab 4 (4.1/4.2/4.3), dan OSPF L4200-4866 — semuanya sudah masuk tabel §2. Sisa hanya 1 fragmen:

| Bab | Lokasi persis di docs | Perkiraan isi (BUKAN ekstraksi — wajib verifikasi saat baca ulang) | Prioritas saat dibaca |
|---|---|---|---|
| 6.17 Static (ujung contoh IPv6) | `bird-6.html` baris 7073-7090 | Ujung contoh IPv6 Static — tidak material (contoh, bukan opsi baru). | P3 (tidak material) |
| Bab 3.5 import/export limit | — | SUDAH TERBACA via BIRD-READ-ch23-config.md (3.5-8/9/10). Bukan lagi belum dibaca. | — |

Catatan refresh 16 Nov: laporan batch B5–B9 ada di staging (BIRD-B5..B9-REPORT.md); laporan B1/B2/B3 TIDAK ditemukan di staging — pemetaan ketiganya dari kode (tree/*.xml + sbin/*.sh), lihat §6.

### 3b. BELUM TERVERIFIKASI — OSPF L4200-4866: SELESAI DIBACA (B0), sisa residu di bawah

43 item ❓ sudah terverifikasi dari docs pada BACA ULANG 16 Nov dan statusnya sudah dipindah ke tabel §2.4 (39 -> MISSING, 3 -> PARTIAL via static per-route attr: O60-O62, 1 -> PERLU VERIFIKASI: O34 `secondary`, lihat §3c). Yang TERSISA bukan karena belum dibaca, melainkan karena **docs memang tidak menyatakan** — jangan ditebak, verifikasi via `bird -p` / perilaku runtime sebelum jadikan default klish:

| Item | Sintaks | Yang tidak dinyatakan docs |
|---|---|---|
| O32 | dead count <num>; | Angka default (hanya rumus: `dead count` x hello). |
| O33 | dead <num>; | Angka absolut default; aturan precedence terverifikasi (`dead` menang bila keduanya dipakai). |
| O23 | stubnet <prefix> { hidden; summary; cost; }; | Default `hidden`/`summary`/`cost` per stubnet. |
| O53-O57 | hello/retransmit/wait/dead count/dead (vlink) | Default tidak dinyatakan terpisah untuk vlink (vlink berperilaku sebagai interface PtP — lihat O27/O29/O31/O32/O33). |
| K2/K3/K7 | persist / scan time / graceful restart (kernel) | Default tidak dinyatakan docs (implisit off / angka tidak disebut). |
| D2 | scan time (device) | Default tidak dinyatakan docs (hanya 'large value'); Titian menulis 10 bila tidak diset eksplisit (nilai contoh docs). |
| RK6 | local address (RPKI) | Default tidak dinyatakan docs. |

### 3c. PERLU VERIFIKASI (3 item)

| Item | Sintaks | Alasan |
|---|---|---|
| BGP-109 | missing lladdr self (channel ipv6) | PERLU VERIFIKASI: muncul di contoh resmi Bab 6.4 tapi TIDAK ADA di daftar opsi channel maupun penjelasannya — diduga opsi IPv6-only tak terdokumentasi / peninggalan BIRD 1.x. Cek `bird -p` / source sebelum implementasi. |
| R12 | version only <switch>; | PERLU VERIFIKASI: dideskripsikan di teks Bab 6.15 tapi TIDAK ADA di blok template sintaks — verifikasi dengan `bird -p` / parse test sebelum masuk klish. |
| O34 | secondary <switch>; (interface OSPF) | PERLU VERIFIKASI (B0): HANYA ada di blok template Bab 6.11 (L3869), TIDAK ADA entri deskripsi di Bab 6.11 — arti + default tidak terverifikasi dari docs; cek source BIRD / `bird -p` sebelum masuk klish. Kebalikan dari O29a `transmit delay` (ada di teks, tidak ada di template). |

## 4. Hal ambigu yang ditemukan saat memetakan (untuk koordinator)

1. **Contoh vs perintah di staging.** `etc/bird.d/*.conf` berisi CONTOH lab (ospf.conf area 0 + interface `lo*` kosong; bgp.conf channel ipv6 import/export none; static.conf 1 route; protocol.conf device + kernel) yang ikut ter-generate sebagai section. Item yang hanya hidup di contoh itu ditandai PARTIAL, bukan DONE — karena tidak ada perintah klish yang mengelolanya dan isinya tidak mencerminkan konfigurasi operasional (neighbor TEST-NET 192.0.2.1, interface lo*). FASE 2 harus memutuskan: contoh dipertahankan sebagai seed, atau diganti generator penuh.
2. **`scope` dihapus di BIRD 3.** `sbin/titian-bird.sh` validate_config menolak atribut route `scope` di bird3 (dihapus di 3.1). Item ch5 No. 120/141 (scope) hanya relevan bila image bird2 — dan image Titian mendeteksi bird2/bird3 runtime (`bird_version=2|3`). Perintah klish `scope` harus digagalkan eksplisit di bird3, bukan diam-diam ditulis.
3. **`show route all` menyesatkan namanya.** Klish `show route all` (tree/bird.xml) menjalankan plain `birdc show route` — BUKAN `birdc show route all` (yang menampilkan semua atribut). Sama untuk `show protocol all` yang menjalankan `birdc show protocol all` (bentuk singular `protocol`, bukan `show protocols all` dari docs — singkatan yang diterima birdc, belum diverifikasi live). Perlu uji live di mesin test sebelum FASE 2 mengandalkannya.
4. **BGP-17 DONE tapi bergantung BFD IN PROGRESS.** Switch `bfd on/graceful` sudah lengkap di sisi BGP, tetapi `titian-bgp.sh` generate GAGAL (exit 33) bila neighbor pakai BFD dan `protocol bfd` belum dikonfigurasi — pertahanan yang benar, tapi berarti fitur ini belum bisa diuji sampai subagent BFD selesai.
5. **Atribut export BGP hanya bila `export all`.** `local-pref`/`med`/`prepend`/`community` per-neighbor diabaikan bila `export filter <nama>` (dicatat sebagai komentar NOTE di section). Ini perilaku generator, bukan batasan BIRD — FASE 2 (Batch B1/B5) harus memutuskan: gabungkan atribut ke filter bernama, atau tolak konfigurasi itu eksplisit.
6. **`community import add` menulis ke SATU filter global (`bgp_import_comm`).** Match community + aksi localpref/med berlaku untuk SEMUA protokol yang memakai filter itu, bukan per-neighbor. FASE 2 perlu filter import per-neighbor bila ingin policy berbeda per peer.
7. **OSPF `stub router` vs area `stub` (O5 vs O13).** Dua konsep berbeda, satu nama — klish FASE 2 wajib membedakan penamaan (mis. `stub-router` level protokol vs `stub` level area).
8. **RIP `version only` (R12) dan BGP `missing lladdr self` (BGP-109).** Keduanya disebut di teks/contoh tapi tidak ada di blok template sintaks — verifikasi dengan `bird -p` sebelum masuk klish (keduanya PERLU VERIFIKASI).
9. **Static `weight` (S15): teks docs menulis `weight switch`, contoh memakai `weight 2`.** Yang benar angka 1-256 (konsisten dengan `ecmp weight` OSPF/RIP) — kemungkinan typo docs.
10. **Kernel `metric` / `kernel table` / `krt_*` (K5/K6/K9/K11-K15) = N/A Linux-only.** Perlu keputusan koordinator: sembunyikan dari klish BSDRP, atau tampilkan sebagai error yang jelas — jangan no-op diam-diam.
11. **`vrf` (3.4-6) dan `tx priority` (3.4-10) = N/A Linux-only.** Padanan FreeBSD (FIB/VNET/jail) belum diputuskan — bukan asumsi sepihak FASE 2.
12. **Default tidak dinyatakan docs (jangan ditebak):** Kernel `persist`/`scan time`/`graceful restart`, Device `scan time`, `default bgp_local_pref` versi BIRD (100 di 2.x, 0 di pre-1.2.0 — image Titian pakai bird 2.20/3.x, cek `bird -v`).
13. **BFD `accept` + VRF (B2) dan `zero udp6 checksum rx` (B4):** perilaku Linux (sysctl `net.ipv4.udp_l3mdev_accept`, `UDP_NO_CHECK6_RX`) — relevansi FreeBSD belum jelas dari docs; subagent BFD yang memutuskan.
14. **`eval` ganda status.** Di Bab 3.2 (3.2-26) ditandai N/A (dev-only, konsisten dengan READ file); perintah birdc-nya (BGP-142) ditandai MISSING karena memang belum ada perintahnya — bila koordinator memutuskan dev-only, ubah BGP-142 ke N/A.
15. **Hitungan OSPF `❓`: 43, bukan 41.** Penugasan menyebut 41; hitung ulang dari BIRD-READ-ch6-ospf-rip-static.md: O18-O23 (6) + O25-O51 (27) + O53-O59 (7) + O60-O62 (3) = 43. Daftar lengkap di §3b.
16. **B0 — hasil baca ulang (16 Nov 07:56 WIB).** 43 item OSPF ❓ terverifikasi (39 -> MISSING, O60-O62 -> PARTIAL via static per-route attr, O34 -> PERLU VERIFIKASI karena template-only). BGP-129 (import/export limit) terverifikasi dari Bab 3.5, tetap MISSING (belum ada perintah klish). RAdv: `check link` TIDAK disebut di Bab 6.14 — jangan asumsikan tersedia sebelum cek `bird -p` / source; tidak ada blok template `protocol radv { ... }` di docs. RPKI: `local address` tanpa default; `refresh`/`retry`/`expire` punya batas atas/bawah yang harus divalidasi klish (refresh < 86400; retry ≤ 7200; expire 600-172800).
17. **B4 — batas implementasi Static/Direct/Pipe/Kernel/Device.** S5/S6 DONE kecuali kualifikasi `mpls` (lihat S32, subsistem MPLS). P4/P5: filter bernama DONE, filter INLINE `filter { ... }` BELUM. S30: hanya subset atribut per-route (ospf-metric1/2/tag, bgp-community/large) — filter expression umum BELUM. S31 `igp_metric` BELUM. K10 `krt_source` BELUM. Kernel `metric` / `kernel table` / `krt_*` / `netlink rx buffer` tetap N/A Linux-only (K5/K6/K9/K11-K15).
18. **B4 — birdc `show static` DONE, `show ospf`/`show rip`/`show interfaces` belum.** BC17 DONE via `show static` (conf-static.xml + titian-static.sh). BC9-BC16 MISSING — tidak ada perintah klish birdc `show interfaces` / `show ospf ...` / `show rip ...`; `show interfaces` yang ada di tree/en-show-*.xml adalah interface OS FreeBSD, bukan birdc. `birdc` dipakai internal titian-bird.sh (BC1/BC8 PARTIAL).

## 5. Daftar batch implementasi FASE 2 yang disarankan (urut prioritas)

Prinsip tiap batch (mengikat, perintah user 16 Nov): penambahan fitur TIDAK BOLEH merubah yang sudah run normal — tiap batch wajib regression check (`verify.py` + live re-verify anchor: BGP Established, show, commit/save) sebelum lanjut. Urutan batch mengikuti fondasi dulu (static/direct/device/kernel -> RIP/pipe -> OSPF -> BGP lengkap -> filter -> channel/table/global -> birdc show), sesuai §12 BIRD-READ-ch6-ospf-rip-static.md.

| Batch | Isi (item) | Status awal -> target | Uji vs RB3011 / lokal |
|---|---|---|---|
| **B0 — Baca ulang (prasyarat, tanpa kode)** | Bab 4 (birdc lengkap + control socket), 6.12 Perf, 6.14 RAdv, 6.16 RPKI, OSPF L4200-4866 (43 item), verifikasi BGP-109 + R12 via `bird -p` | ✅ SELESAI 16 Nov 07:56 WIB — semua terbaca; 43 item OSPF terverifikasi (O34 -> PERLU VERIFIKASI, §3c); BGP-109 + R12 masih PERLU VERIFIKASI (cek `bird -p` di mesin test) | — (baca docs + `bird -p` di mesin test) |
| **B1 — BGP lengkap (inti)** | multihop (BGP-10), source address + local ip/port (2,3,11), password MD5 + setkey (19,20), hold/keepalive/send-hold + min/startup (52-57), connect/error timers (58-61), direct/passive (9,21), strict/free bind + check link (14,15,16), ttl security (18), GR + LLGR protocol+channel (36-41,106-108), interpret communities (42), capabilities/as4/extmsg/hostname + require-* (43-51), disable after error/cease (50,51), path/med/deterministic/igp/prefer-older + default med/local-pref (62-68), confederation (22,23), RR client/cluster (24,25), rs client (26), allow-* (27-31), route refresh (32-35), roles/OTC (69,70,124), neighbor internal/external (6), dynamic BGP (7,12,13), interface (8), local role | ✅ SELESAI (staging; tanpa laporan batch — pemetaan dari kode, lihat §6) | RB3011: sesi multihop via VXLAN/loopback, timer cepat, MD5, GR restart, RR |
| **B2 — OSPF BIRD** | Area + stub/NSSA/summary/default cost (O12-O17), interface cost/hello/dead/type/priority/retransmit/poll/wait (O24-O51, setelah B0), virtual link (O52-O59), auth + password rotation (O49-O50, O58-O59), BFD per-interface (O44), GR (O9-O10), rfc1583compat/rfc5838/instance id/stub-router/tick/ecmp/merge-external (O2-O8), atribut ospf_metric1/2/tag (O60-O62), OSPFv3 IPv4 (O66), export ke OSPF (O64) | ✅ SELESAI (staging; tanpa laporan batch — pemetaan dari kode, lihat §6) | RB3011: adjacency area 0, hello/dead, auth, stub area; regression: FRR OSPF TIDAK disentuh |
| **B3 — RIP (+RIPng)** | protocol rip/ng (R1), interface metric/version/mode/passive/address/port (R5-R12), split horizon + poison reverse (R13,R14), demand circuit (R15), timer update/timeout/garbage (R17-R19), ecmp + weight (R3,R20), check link/zero (R16,R26), ttl security (R21), auth + password (R27,R28), rx/tx buffer/length (R24,R25), infinity (R2), rip_metric/rip_tag (R29,R30) | ✅ SELESAI (staging; tanpa laporan batch — pemetaan dari kode, lihat §6) | RB3011: RIPng/RIPv2 exchange (RouterOS dukung RIP); lokal: timer + auth |
| **B4 — Static / Direct / Pipe / Kernel / Device (fondasi)** | Static: route via multipath+weight (S5,S15), blackhole/unreachable/prohibit (S7), recursive + igp table (S6,S3), per-nexthop bfd/dev/mpls/onlink (S11-S14), check link (S2), per-route filter (S30), igp_metric (S31), channel ipv6/flow (S4) · Direct: interface pattern + ipv6 (T2,T3), check link (T4) · Pipe: P1-P5 · Kernel: learn/persist/scan time/GR/merge paths/krt_source (K2,K3,K4,K7,K8,K10), channel (K16) · Device: interface pattern + preferred (D3,D4), scan time klish (D2) | ✅ SELESAI — Static 10 DONE + S4/S30 PARTIAL; Direct 4 DONE; Pipe 3 DONE + P4/P5 PARTIAL; Kernel 7 DONE (K10 tetap MISSING, K5/K6/K9/K11-K15 N/A Linux-only); Device 4 DONE. TIDAK diimplementasi: Static MPLS (S5/S6/S13 kualifikasi mpls), ROA/ASPA/Flowspec (S8-S10, S16-S29), filter inline Pipe, import/export filter bernama di channel kernel, `igp_metric` (S31), `krt_source` (K10). verify.py: 46 XML / 53 PTYPE / 48 VIEW / 718 COMMAND, NOL error | Lokal + RB3011: static multipath, BFD-controlled nexthop, direct export, pipe antar-tabel |
| **B5 — Filter lengkap (Bab 5)** | Var lokal + parameter fungsi + return type (ch5 2,4,5,6,7,10), bool/int/quad/string/bytestring/ip/rd (15,18,19,20,21,23), set int/quad/ip/prefix/ec/lc/rd (32,34,35,37,38,39,41), pola prefix `-` + `{low,high}` (43,44), from_hex (45), semua accessor `.asn/.data/.ip/.len/.type/...` (46-62), bgppath `.first/.last/.len/.delete/.filter` + bgpmask (72-76,78,79,28,89,99,100,101), clist `.delete/.filter/.len/.min/.max/.empty` (80,81,83-86), operator aritmetika/logika/`!~`/string-`~`/IP-`~` (90,91,93,95,96,97), `for` + `case` (113-118), `defined()/unset()` + custom attribute (136-138,140), atribut umum scope/preference/from/gw/proto/dest/ifname/ifindex/onlink/weight/gw_mpls/igp_metric/mpls_* (120-135), `accept/reject` berpesan (154,155), `print/printn` (157,158), `show route filter` (14), match bgp_path + bgp_origin/next_hop/dll (BGP-111,114-117,121-123) | ✅ SELESAI — BIRD-B5-REPORT.md (COMMAND 1200→1266, mock SEMUA LOLOS) | Lokal: `bird -p` + `show route filter`; RB3011: filter as-path/community/ext/large end-to-end |
| **B6 — Channel IPv6 + table + global (Bab 2/3)** | Channel ipv6 BGP (BGP-83) + ipv6 kernel/direct/static, definisi tabel `<nettype> table` + opsi tabel sorted/trie/gc/settle (3.2-24, 3.3-1..7), channel table/preference/import-keep-filtered/limit (3.5-1..3, 3.5-6..10), global log/debug/watchdog/mrtdump/timeformat/hostname/router-id-from/GR-wait (3.2-1..12, 3.2-20..23), protocol template + `from` (3.2-15/16), `define` umum + `attribute` (3.2-17/18), per-protocol router-id/description/disabled/debug/mrtdump (3.4-1..5), interface pattern umum + tx class/dscp + password generik (3.4-7..9, 3.4-11..19), nettype vpn/roa/flow (2.2-4..9), GR shutdown `down`/`graceful restart` + flag -R (2.4, BGP-141) | ✅ SELESAI — BIRD-B6-REPORT.md (COMMAND 1266→1441, mock 146 PASS) | RB3011: BGP ipv6, multi-tabel; lokal: log/debug/timeformat |
| **B7 — birdc show (Bab 4.3)** | `show status` (130), `show protocols all <nama>` + parsing BGP state (131), `show route` lengkap table/filter/where/stats/preexport/noexport/filtered (132), `show symbols` (134), `configure [soft]` + timeout + confirm/undo (135,137), `configure check` via birdc (136), `debug` (140), `eval` (142, bila diputuskan bukan dev-only), `dump` (143), `echo` (144), `mrt dump table` (145), `show bgp summary` ala vendor dari `show protocols all` + `show route protocol count` (146) | ✅ SELESAI — BIRD-B7-REPORT.md (COMMAND 1441→1502, mock 182 PASS) | Lokal + RB3011: `show bgp` yang sebenarnya (pengganti intent+section) |
| **B8 — P2 (Aggregator, MRT, Flowspec, RAdv)** | Aggregator AG1-AG6, MRT MRT1-MRT6, Flowspec static S10/S16-S29 + channel flow (BGP-87, 2.2-8/9), RAdv (setelah B0 — prefix/lifetime/rdnss/dnssl), `show route filter` + contoh filter lengkap (ch5 159-166) | ✅ SELESAI — BIRD-B8-REPORT.md (COMMAND 1502→1725, mock 184 PASS) | Lokal: dump MRT + agregasi; RB3011: RAdv ke host IPv6 link-lokal |
| **B9 — P3 (RPKI, BMP, Babel, L3VPN, MPLS)** | RPKI (setelah B0; butuh cache server Routinator — mock lokal atau server lab), BMP BMP1-4 (butuh station + build `--with-protocols=`), Babel BB1-33 (butuh peer Babel — mock dengan 2 instance BIRD di lab / peer kedua), L3VPN VPN1-10 (butuh peer BGP VPN + MPLS + VRF), MPLS 3.2-25/3.6/2.5 (eksperimental), roa_check/aspa_check (ch5 104-110), ROA/ASPA static (S8,S9) | ✅ SELESAI — BIRD-B9-REPORT.md (COMMAND 1725→1958, mock 285 PASS) | Mock/birdc lokal dulu (2 instance BIRD, RPKI cache mock, BMP collector mock); peer nyata bila tersedia |

**Urutan yang disarankan:** B0 ✅ -> B4 ✅ -> B3 ✅ -> B2 ✅ -> B1 ✅ -> B5 ✅ -> B6 ✅ -> B7 ✅ -> B8 ✅ -> B9 ✅ (semua SELESAI di staging; uji live FASE 3 antre, lihat §7). (B4 fondasi dulu agar OSPF/RIP/BGP punya device/kernel/direct/static yang benar; B1 BGP setelah OSPF/RIP karena BGP mengandalkan IGP table + next-hop resolution; B5 filter setelah protokol karena filter diuji lewat import/export protokol; B9 terakhir karena butuh peer/server khusus.)

**Yang TIDAK masuk FASE 2:** BFD 17 item (subagent terpisah — sinkronkan di titik integrasi: `bfd on/graceful` BGP + `bfd` OSPF interface + `via ... bfd` static); item N/A (12 item — keputusan koordinator dulu bila ada yang mau dihidupkan via padanan FreeBSD); `eval` bila diputuskan dev-only.

---

*Akhir FASE 1. File ini satu-satunya output. Tidak ada file staging lain yang diubah, tidak ada mesin test yang disentuh, tidak ada implementasi.*

## 6. Refresh pasca-B3–B9 (16 Nov 2026)

- **Tanggal refresh:** 16 Nov 2026 WIB (staging saja; repo/port/mesin test/kopler TIDAK disentuh; TIDAK ada file kode yang diubah — hanya file ini).
- **Skrip refresh:** `BIRD-COVERAGE-REFRESH.py` (di staging; idempotent — jalan ulang = 0 perubahan). Semua tabel §1 dihitung ulang dari baris item aktual.
- **Laporan batch yang dipakai:** BIRD-B5-REPORT.md, BIRD-B6-REPORT.md, BIRD-B7-REPORT.md, BIRD-B8-REPORT.md, BIRD-B9-REPORT.md + BFD-DESIGN.md.
- **Laporan B1/B2/B3 TIDAK DITEMUKAN di staging** (dicari `BIRD-B[123]-REPORT.md` di `~/workspace` — nihil). Pemetaan B1 (BGP lengkap), B2 (OSPF BIRD), B3 (RIP) dilakukan dari kode: `tree/conf-bgp.xml` (515 COMMAND), `tree/conf-ospf.xml` (189), `tree/conf-rip.xml` (102) + `sbin/titian-bgp.sh`/`titian-ospf.sh`/`titian-rip.sh`; emit generate diverifikasi grep untuk kunci B1. Bila laporan B1/B2/B3 muncul belakangan, cocokkan ulang pemetaan ini terhadap laporan tersebut.
- **Total baris item: tetap 729** (TIDAK ada baris baru, TIDAK ada baris hapus).
- **Baris yang berubah status: 572** (DONE baru: 541; PARTIAL baru dari MISSING: 31; baris disentuh total incl. catatan saja: 588).
- **Status sebelum → sesudah:** DONE 77 → **618**; PARTIAL 76 → **52**; MISSING 537 → **30**; N/A 19 → **19**; IN PROGRESS 17 → **7**; PERLU VERIFIKASI 3 → **3**.
- **BFD (17 item): 10 → DONE** (B1, B5–B13: protocol/interface/multihop/neighbor/interval/min-rx/min-tx/idle-tx/multiplier/passive — sbin/titian-bfd.sh + tree/conf-bfd.xml, mock 51/51); **7 tetap IN PROGRESS** (B2 accept, B3 strict bind, B4 zero udp6 checksum rx, B14–B17 authentication/password — BFD-DESIGN §8: tidak diekspos v1).
- **PERLU VERIFIKASI tetap 3** (O34 secondary OSPF, BGP-109 missing lladdr self, R12 version only RIP) — belum terverifikasi, sesuai penugasan.
- **MISSING tersisa: 30 item:** 3.1-6 (simbol quoted); Bab 5: 5-8 (deklarasi var deprecated — jangan diadopsi), 5-11 (rekursi), 5-46/47/48/49/50 (accessor .asn/.data pair/lc), 5-68 (NET_MPLS — jangan jadikan klish stabil), 5-95 (!~), 5-96 (~ string vs pola shell), 5-97 (IP ~ prefix), 5-120/141 (scope — dihapus BIRD 3), 5-128 (ifindex — tidak ada di attr_kind), 5-157/158 (print/printn); BGP-116/117/123 (bgp_atomic_aggr/bgp_aggregator/bgp_aigp — tidak bisa diakses dari filter per docs); O48 (tx priority OSPF — Linux-only), O67 (ospf_router_id — tidak ada di attr_kind), R23 (tx priority RIP — Linux-only), S13 (via mpls per-nexthop), S32 (MPLS-aware static), K10 (krt_source), BB11 (tx priority Babel — Linux-only), BC2/BC3/BC4 (birdc -r/-v/-s).
- **Temuan B5 yang BELUM diubah (butuh `bird -p`, lihat §7 F3.1):** generator filter menulis `bgp_community ~ [ (65000:100)]` (titik-dua) — diduga benar `(65000, 100)` (koma). Dibiarkan apa adanya sampai `bird -p` membuktikan.
- **Yang TIDAK terpetakan ke baris coverage (bukan baris baru — total tetap 729):**

  - **RAdv `check link` (B8 §5, B9 §5)** — Tidak disebut Bab 6.14 docs (B0); tidak ada baris coverage; perlu konfirmasi `bird -p` sebelum masuk klish.
  - **BMP multi-station / retry / TLS / varian rib lain (B9 §5)** — Docs §6.5 hanya mendokumentasikan satu station + `monitoring rib in pre|post_policy` + `tx buffer limit`; varian lain tidak ada di docs — tidak ditebak, tidak ada baris coverage.
  - **Tabel panjang kunci password per algoritma Babel (B9 §5)** — Docs tidak memberi tabel panjang kunci per algoritma; validasi diserahkan ke `bird -p`; tidak ada baris coverage.
  - **Instance radv kedua (B8 §5)** — Keputusan desain B8: satu instance tetap `radv`; tidak ada baris coverage.
  - **Bentuk singkat `rdnss <addr>;` / `dnssl <domain>;` (B8 §5)** — Tercakup bentuk blok (RA3/RA4) yang semantiknya identik; tidak diduplikasi, tidak ada baris terpisah.
  - **Hapus per-field BFD (`no interval` dsb.), blok `bfd { }` per-peer BGP, `show bfd neighbors` (BFD-DESIGN §8)** — Tidak ada baris coverage; hapus per-objek utuh saja di v1; `show bfd neighbors` belum terverifikasi ada di BIRD 2.20.
  - **Prefix IPv6 `{low,high}` (B5 §7)** — Validator B5 IPv4 saja; aspek 5-44 (DONE untuk IPv4) — celah dicatat di sini, bukan baris baru.
  - **`filter()` channel `where` Babel (B9 §5)** — Hanya all/none/filter diekspos; aspek 3.5-4/3.5-5 (PARTIAL).
  - **`enum-set` jalur titian-function.sh + refactor duplikasi validator function (B9 §5/§8)** — Bukan item docs; asimetri dicatat di 5-39 (DONE jalur bgp saja).
  - **Batasan upsert satu-slot B1/B5 (filter-unset/function-unset; filter-if lama)** — B9 mengubah filter-if/function-if jadi APPEND + dedupe; sisa: filter-unset/function-unset satu slot per atribut — bukan item docs, dicatat di sini.

**Bacaan angka (revisi B1–B9 + BFD):** 618 DONE (84.8%) + 52 PARTIAL (7.1%) = 670 item (91.9%) sudah punya wujud di Titian; 30 MISSING (4.1%) tersisa — hampir semua bukan pekerjaan implementasi (deprecated / Linux-only / tidak bisa diakses dari filter / belum terverifikasi). BFD 7 item IN PROGRESS bukan MISSING. PERLU VERIFIKASI 3 item menunggu `bird -p` live.

## 7. FASE 3 — ANTREAN UJI LIVE vs RB3011

> **FASE 3 SELESAI DIJALANKAN 16 Nov 2026 (lihat §8 untuk hasil).** Peringatan lama di bawah
> ini berlaku saat antrean ditulis (mesin test DOWN pasca-reboot uji FRR); mesin test sudah
> kembali UP via konsol user 16 Nov ~14:00 WIB, anchor dipulihkan, staging di-deploy, dan
> F3.1–F3.10 dijalankan satu persatu sesuai SOP. `down confirm` / `graceful-restart confirm`
> tetap TIDAK diuji (mematikan daemon BIRD — hanya di jendela maintenance + akses konsol).
>
> ~~**JANGAN JALANKAN ANTREAN INI SEKARANG.** Mesin test BSDRP saat ini DOWN pasca-reboot
> uji FRR (16 Nov ~08:19–08:35 WIB, butuh konsol user); kopler MATI sampai semua pekerjaan
> lab selesai (perintah user 16 Nov ~07:34). Antrean ini HANYA rencana tertulis (FASE 3).
> Eksekusi HANYA sesudah lab kembali (mesin test boot + SSH jalan), staging di-deploy ke
> mesin test, dan regression anchor lolos (BGP Established, show, commit/save).~~

Prasyarat umum tiap grup: (a) `bird -p` lolos atas bird.conf hasil generate; (b) anchor
BGP Established + `show` + `commit/save` sebelum dan sesudah grup; (c) tiap kegagalan
dicatat (baris config + pesan birdc) dan generator diperbaiki di staging sebelum lanjut.

### F3.1 (P0) `bird -p` atas pair community — temuan B5, belum diubah
- Perintah klish: filter lama `F-RB3011-IN` (`accept community 65000:100`) → `generate` →
  `bird -p` atas section bgp.
- Harapan birdc: bila `bgp_community ~ [ (65000:100)]` (titik-dua, titian-bgp.sh:1717)
  DITOLAK → perbaiki generator ke `(65000, 100)` (koma, bentuk yang dipakai `atom_to_bird`),
  re-generate, re-verify anchor, tutup temuan. Bila DITERIMA → catat sebagai sintaks sah,
  tutup temuan tanpa ubah kode.
- Harapan RB3011: tidak ada (uji parse lokal).

### F3.2 (P0) `bird -p` atas `validate`/`base table`/channel ipv4, satuan `cost`, `case roa_check()`, `for`, semua section baru B8/B9
- Perintah klish: tiap `generate <section>` (aggregator, mrt, radv, static flowspec,
  rip/ospf debug/mrtdump/preference/keep-filtered/limit, bgp filter baru var-set/method/match
  baru/define baru, rpki TCP + SSH, bmp, babel, l3vpn) + channel ipv4 `validate on` +
  `base-table <tabel-trie-on>` + `cost <N>` → `bird -p` (atau `birdc configure check`).
- Harapan birdc: exit 0, tanpa error parse; `case roa_check(R4) { ROA_VALID: accept; ... }`
  dan `for int asn in bgp_path` diterima. Tiap kegagalan → catat baris + perbaiki generator.
- Harapan RB3011: tidak ada (uji parse lokal).

### F3.3 (P0) Marker template bird.conf di image
- Perintah: di mesin test, `grep -n '#-RIP-#\|#-ENDRIP-#\|#-GLOBAL-#\|#-ENDGLOBAL-#\|#-OSPF-#\|#-ENDOSPF-#\|#-BFD-#\|#-RPKI-#\|#-BMP-#\|#-BABEL-#\|#-L3VPN-#\|#-AGGREGATOR-#\|#-MRT-#\|#-RADV-#' /usr/local/etc/bird.conf` (atau `/etc/bird/bird.conf` — sesuaikan path image).
- Harapan: semua marker ada. `#-RIP-#`/`#-ENDRIP-#` dan `#-GLOBAL-#`/`#-ENDGLOBAL-#`
  BELUM ADA di seed bird.conf (B6 §6, B8/B9) → tambah ke seed (titian-install.sh, deployment,
  bukan staging) sebelum `generate rip/global` bisa jalan live. `#-OSPF-#`/`#-ENDOSPF-#`
  diverifikasi sudah ada di image.

### F3.4 (P1) BFD single-hop ke RB3011 — BFD sudah di klish, belum pernah uji live
- Perintah klish: `router bird → bfd → interface bridge0 → interval 300, min-rx 300, min-tx 300, multiplier 3`; neighbor BGP `10.99.40.2` → `bfd`.
- Sisi RB3011: `/routing bfd` diaktifkan (interface + neighbor, atau via `/routing bgp connection`).
- Harapan birdc: `show bfd sessions` Up dua arah; `show protocols` bgp tetap Established.
- Harapan RB3011: sesi BFD Up; failover: matikan BFD di RB3011 (atau putuskan path) → BGP
  jatuh < 1 detik (interval 300 ms × multiplier 3) vs tanpa BFD (hold time). Bandingkan
  `bfd graceful` vs `bfd on` (perilaku restart sesi). Multihop belum ada peernya — jangan uji.
- Kriteria lolos: sesi Up dua arah + failover terukur + BGP kembali Established.

### F3.5 (P1) BGP lengkap live vs RB3011
- Perintah klish: `hold-time 30`, `keepalive-time 10`, `password <MD5>` (TCP MD5),
  `multihop` (via loopback/VXLAN), `graceful-restart` + `graceful-restart-time`,
  `rr-client`/`rr-cluster-id` dan confederation bila relevan (lab: 2 neighbor IBGP).
- Harapan birdc: `show protocols` Established; `show route protocol bgp_10_99_40_2 count`;
  restart BIRD (graceful) → sesi kembali tanpa drop route.
- Harapan RB3011: `/routing bgp peer print` Established; `/routing route print` memuat atribut
  (community 65000:100, MED, local-pref, as-path/prepend) sesuai filter.
- Kriteria lolos: sesi Established + atribut terverifikasi dua arah + GR restart bersih.

### F3.6 (P1) OSPF BIRD live + RIP live vs RB3011
- Perintah klish OSPF: area 0, `interface ge*` (cost/hello/dead/type), auth
  simple/cryptographic + password, stub area.
- Harapan birdc: `show ospf neighbors` Full; `show ospf state` / `show ospf topology` memuat
  LSDB RB3011. Harapan RB3011: `/routing ospf neighbor print` Full; route OSPF masuk tabel.
- Perintah klish RIP: `protocol rip` / `ripng`, interface (metric/version 2/mode/split-horizon),
  auth + password, timer update/timeout/garbage.
- Harapan birdc: `show rip neighbors` memuat RB3011. Harapan RB3011: `/routing rip neighbor print`
  (RouterOS dukung RIP) + route RIP masuk tabel.
- Kriteria lolos: adjacency Full + route exchange dua arah (OSPF dan RIP masing-masing).

### F3.7 (P1) RPKI live vs Routinator di 10.1.1.62:3323
- **Aturan user (16 Nov ~08:05): mesin test akses vsaas HANYA via IP privat 10.1.1.62,
  JANGAN IP publik (103.50.128.24).** RPKI cache Routinator 0.16.1 di vsaas, VRP ~1.034.998
  (IPv4 796.970 + IPv6 238.028), aktif sejak 16 Nov ~08:00.
- Perintah klish: `protocol rpki <nama>` → `remote 10.1.1.62 port 3323` + `chan-table roa4/roa6/aspa`.
- Harapan birdc: `show protocols` rpki Up; `show route` + filter `accept roa R4 ROA_VALID`
  end-to-end (prefix uji VALID).
- Kriteria lolos: sesi RTR Up + ROA_VALID terverifikasi pada prefix uji.

### F3.8 (P2) RAdv live, Flowspec live, Aggregator/MRT live
- RAdv: `protocol radv` (interface + prefix + rdnss/dnssl) → harapan: RA benar-benar terkirim
  di link IPv6 (host link-lokal menerima RA: prefix + RDNSS + DNSSL; cek max/min interval).
- Flowspec: `route flow4/6 { ... }` + channel `flow6 { table f6tab; }` (tabel flow6 dibuat dulu
  via `global → table-add flow6`) → harapan: route flow diterima (`show route table f6tab`).
- Aggregator: `protocol aggregator` (table + aggregate-on + merge-by + peer-table) → harapan:
  route agregat muncul di peer table (`show route table <peer>`).
- MRT: `protocol mrt` (filename + period) → harapan: file dump tertulis + periodik
  (cek isi file di mesin test).
- Kriteria lolos: masing-masing terbukti di birdc lokal + peer bila ada.

### F3.9 (P3) Babel / BMP / L3VPN+MPLS — BUTUH peer khusus (bukan RB3011)
- Babel: butuh peer Babel di link yang sama (IPv6 link-local) — RB3011 TIDAK bisa. Cara uji
  alternatif: 2 instance BIRD di lab/VM (satu sebagai peer) + `bird -p` + `show protocols`.
- BMP: butuh BMP station eksternal + build BIRD `--with-protocols=` (BMP preliminary, tidak
  ter-compile default). Alternatif: `bird -p` + collector mock lokal.
- L3VPN+MPLS: butuh peer BGP VPN + MPLS + VRF kernel. Alternatif: `bird -p` + 2 instance BIRD
  (vpn4/vpn6) + `show protocols`; MPLS tetap EKSPERIMENTAL.
- Kriteria lolos: `bird -p` + sesi Up terhadap peer khusus (bukan RB3011).

### F3.10 (P2) birdc show/operasional live (temuan B7) + peringatan keras
- Verifikasi live: argumen interface OSPF/RIP ber-kutip (`show ospf interface ospf4 "ge0"`) —
  bila birdc menolak, lepas kutipnya; `show protocols` vs `show protocol` (singular, dipakai
  kode lama); `debug <proto> { states, routes }` (braces + koma) sebagai satu argumen;
  `echo { info, warning }`; `mrt dump table` + `dump` (file harus writable oleh daemon bird,
  bukan oleh klish); `configure confirm/undo` (satu level + timer 300 dtk default);
  `show route where` dengan kondisi multi-kata (kutip di klish).
- **PERINGATAN KERAS: `down confirm` / `graceful-restart confirm` mematikan daemon BIRD —
  JANGAN diuji tanpa jendela maintenance + akses konsol.**
- Regression anchor sesudah tiap grup F3.4–F3.9: BGP Established, show, commit/save.

## 8. FASE 3 — HASIL UJI LIVE (16 Nov 2026)

- **Tanggal:** 16 Nov 2026 ~15:00–10:40 WIB (F3.0–F3.10). Koordinator lab subagent; perintah user 16 Nov ~14:47 ("satu persatu, BIRD2 saja, gas, sesuai SOP") + ~14:50 ("jika bird2 selesai segera laporan, dan push dokumentasi").
- **Log otoritatif:** `~/workspace/titian-live-test-20261113/HASIL.md` (addendum "FASE 3 BIRD live").
- **Mesin test:** BSDRP build 10, FreeBSD 16.0-CURRENT, BIRD 2.20.0, mgmt ge0 10.10.2.3; RB3011 RouterOS v7.25.1 (192.168.91.32, AS 65001) ↔ BSDRP AS 65000 (10.99.40.1). VXLAN tetap lossy 75–100% (tidak diinvestigasi di run ini).
- **Deploy staging → mesin:** 117 file (sbin 46 + tree XML 56 + bird.d 15); md5 staging==mesin 117/117; restart titian → BGP re-Established ~9 dtk; default route otomatis kembali (fix boot 1-6).
- **`verify.py` pasca-FASE 3: NOL error; 56 XML / 53 PTYPE / 72 VIEW / 1953 COMMAND** (1958 → 1954 di F3.2: hapus 4 COMMAND `tx-class`/`tx-dscp` BGP; 1954 → 1953 di F3.10: hapus 1 COMMAND `show route filter`).
- **Hitungan status pasca-FASE 3 (dihitung ulang dari baris aktual via BIRD-COVERAGE-REFRESH.py): DONE 601 (82.4%), PARTIAL 53 (7.3%), MISSING 30 (4.1%), N/A 35 (4.8%), IN PROGRESS 7 (1.0%), PERLU VERIFIKASI 3 (0.4%), total 729.** Perubahan vs pasca-B9: DONE 618 → 601 (−17: AG1–AG6 + VPN1–VPN10 → N/A, 5-14 DONE → PARTIAL); N/A 19 → 35 (+16); PARTIAL 52 → 53 (+1).

### 8.1 Ringkasan hasil per grup

| Grup | Hasil | Ringkasan |
|---|---|---|
| F3.0 Snapshot + deploy | LOLOS | Anchor snapshot + backup; deploy 117 file; regression LOLOS. |
| F3.1 Pair community (B5) | LOLOS | `(65000:100)` titik-dua SAH di BIRD 2.20 (`bird -p` exit 0; kontrol negatif ditolak). Temuan ditutup tanpa ubah kode. |
| F3.2 `bird -p` B8/B9 | LOLOS | Semua section exit 0. **12 bug generator diperbaiki** (lihat §8.2). **Aggregator + L3VPN → N/A** (protokol tidak ada di BIRD 2.20.0). |
| F3.3 Marker bird.conf | SELESAI, TEMUAN | Hanya marker BGP di bird.conf live. 17/18 section tanpa marker; seed install script kurang 9 marker (RIP, GLOBAL, AGGREGATOR, MRT, RADV, RPKI, BMP, BABEL, L3VPN). |
| F3.4 BFD single-hop | TERBLOKIR | Konten valid (`bird -p` exit 0). Blocker: marker `#-BFD-#` hilang + RB3011 butuh `/routing bfd session add` (butuh persetujuan). |
| F3.5 BGP lengkap live | LOLOS | hold-time 30 + keepalive 10 + GR on/time 120 diterapkan live; sesi re-Established; GR restart bersih (~7 dtk). MD5/multihop/rr-client tercatat (lihat §8.3). |
| F3.6 OSPF + RIP live | TERBLOKIR | Konten valid (`bird -p` exit 0). Blocker: marker OSPF/RIP hilang + RB3011 OSPF area DISABLED + RIP belum terkonfigurasi. Risiko VXLAN lossy untuk adjacency. |
| F3.7 RPKI live | TERBLOKIR | Konten valid (`bird -p` exit 0). Routinator SEHAT (VRP 1.049.688). Blocker: **TCP mesin test → vsaas 10.1.1.62 MATI** (semua port; ICMP jalan; firewall vsaas ACCEPT) + marker `#-RPKI-#` hilang. |
| F3.8 RAdv/Flowspec/Aggregator/MRT | SEBAGIAN LOLOS | **MRT live LOLOS** (protocol dump1 up, file dump 122 byte valid). RAdv + Flowspec konten valid (`bird -p` exit 0). Aggregator N/A. |
| F3.9 Babel/BMP/L3VPN | SEBAGIAN LOLOS | **BMP live LOLOS** (mock collector: Initiation + Peer Up, sesi Established). Babel konten valid; live adjacency butuh peer. L3VPN N/A (protocol); vpn4/vpn6 channel DONE. |
| F3.10 birdc show/operasional | LOLOS | Semua show/operasional LOLOS live. **3 bug diperbaiki** (lihat §8.2). `down/graceful-restart confirm` TIDAK diuji. |

### 8.2 Perbaikan generator + show command (semua di staging, ter-deploy ke mesin)

**F3.2 — 12 perbaikan generator (bird -p):**
1. `log` + `timeformat`: kata kunci `limit` DITOLAK BIRD 2.20 → bentuk posisional tanpa `limit` (`titian-global.sh`).
2. Nilai TIME angka polos DITOLAK → helper `bird_time()` (angka → `<n>s`) untuk watchdog + debug latency (`titian-global.sh`).
3. Tipe `attribute` `bool`/`prefix`/`pair`/`rd` DITOLAK → validator dipersempit ke 9 tipe valid (`titian-global.sh`).
4. Opsi `trie` pada tabel flow4/flow6/mpls DITOLAK → guard rc=33 (`titian-global.sh`).
5. BGP `tx class`/`tx dscp` DITOLAK di semua posisi (hanya opsi blok interface) → setter err tegas, emitter dihapus, 4 COMMAND dihapus (`titian-bgp.sh` + `conf-bgp.xml`).
6. Channel vpn4/vpn6 WAJIB punya `table` → guard rc=33 (`titian-bgp.sh`).
7. Flow4/flow6 `base table` WAJIB `trie on` → guard rc=33 (`titian-bgp.sh`).
8. `next hop prefer global` = FLAG polos tanpa nilai → emitter diubah (`titian-bgp.sh`).
9. `gateway recursive` + `igp-table` beda famili channel → guard rc=33 (`titian-bgp.sh`).
10. Static Flowspec: satu protocol hanya satu tipe channel; flow4/flow6 WAJIB punya `table`; nama protocol ROA/ASPA `-` → `_` (`titian-static.sh` + `conf-static.xml`).
11. Flow6 `label` value/mask DITOLAK → satu nilai 0..0xfffff (`titian-static.sh`).
12. OSPF `area-add`/`interface-add` no-op (tidak persisten) → kini menulis intent + guard tanpa-area + guard stub/NSSA di backbone (`titian-ospf.sh`).
- Plus: Babel TIME (`bird_time()` untuk hello/update/rtt) + password `blake2s`/`blake2b` DITOLAK (hanya `hmac sha1/256/384/512`) + channel `ipv6 sadr` WAJIB tabel ipv6-sadr (`titian-babel.sh`); BGP blok `mpls` WAJIB tabel mpls + `enum-set` TIDAK ADA di BIRD 2.20 (dihapus) (`titian-bgp.sh` + `conf-bgp.xml`); PIPE primary/peer table WAJIB satu tipe (`titian-pipe.sh`).
- **`cost` TERVERIFIKASI SAH:** OSPF interface/stubnet/area `cost`, Babel `rxcost`/`rtt cost` — semua `bird -p` exit 0.

**F3.10 — 3 perbaikan (birdc show/operasional):**
1. **`show route filter <nama>` DIHAPUS** — BIRD 2.20 `show route filter` hanya terima filter INLINE `{ ... }`, bukan nama filter (juga referensi nama di dalam inline ditolak). Perintah dihapus dari `tree/en-show-birdc.xml` + `sbin/titian-birdc.sh` + `BIRD-B7-MOCK.sh`; gantinya `show route where "<kondisi>"`. Item 5-14 DONE → PARTIAL.
2. **Pesan error `run_ro` diperbaiki** — bedakan daemon down vs perintah gagal (mis. protokol OSPF/RIP tidak ada) di `titian-birdc.sh`.
3. **Mock B7 seksi H diperbaiki** — tambah `mkdir -p` + seed intent (pra-ada, artefak lingkungan /tmp).

### 8.3 Yang N/A di BIRD 2.20.0 (bukan bug — protokol tidak ada di binary)

- **Aggregator (AG1–AG6 → N/A):** `protocol aggregator` → `CF_SYM_UNDEFINED` (bird -p). Docs bird.network.cz §6.1 mendokumentasikannya, tapi binary BIRD 2.20.0 (FreeBSD port net/bird2) tidak mengimplementasikannya — fitur BIRD 3. Generator `titian-aggregator.sh` + `conf-aggregator.xml` dipertahankan untuk BIRD 3 (header ditandai; mock internal 184 PASS).
- **L3VPN (VPN1–VPN10 → N/A):** `protocol l3vpn` → `CF_SYM_UNDEFINED` (bird -p). Sama — fitur BIRD 3 (docs §6.9). L3VPN di BIRD 2.20 dilakukan via channel vpn4/vpn6 BGP (B6, terverifikasi bird -p). Generator `titian-l3vpn.sh` + `conf-l3vpn.xml` dipertahankan untuk BIRD 3 (header ditandai; mock internal 285 PASS).

### 8.4 Blocker + keputusan yang dibutuhkan user (terbuka)

1. **Marker seed bird.conf (F3.3):** tambah 9 marker ke seed di `install/titian-install.sh` (RIP, GLOBAL, AGGREGATOR, MRT, RADV, RPKI, BMP, BABEL, L3VPN) + langkah "upgrade markers" untuk mesin existing (install script saat ini melewati seed bila bird.conf sudah bermarker). Keputusan: tambah marker ke bird.conf live sekarang (dengan backup) atau tunggu rebuild image di kopler.
2. **RB3011 — BFD (F3.4):** izinkan `/routing bfd session add` (sesi BFD ke 10.99.40.1).
3. **RB3011 — OSPF/RIP (F3.6):** izinkan enable area OSPF + tambah interface OSPF di 10.99.40.0/24 + konfigurasi RIP.
4. **TCP mesin test → vsaas 10.1.1.62 (F3.7):** diagnosis + perbaikan jalur TCP (gateway 10.10.2.1) — ICMP jalan, TCP semua port mati; firewall vsaas ACCEPT, bukan pelaku.
5. **BGP MD5 (F3.5):** butuh password yang sama di kedua sisi (BSDRP + RB3011) sebelum diterapkan live; bila hanya di satu sisi, sesi GAGAL.
6. **RAdv live (F3.8):** interface mana + apakah boleh advertise IPv6 RA di jaringan lab.
7. **RB3011 — Flowspec (F3.8):** butuh dukungan + config flowspec di RB3011 untuk live exchange.
8. **Babel live (F3.9):** butuh peer Babel (bukan RB3011) atau 2 instance BIRD.

### 8.5 Pertanyaan terbuka (untuk laporan akhir)

- `include "/etc/bird/extra.conf"` (path Linux, tidak ada di FreeBSD): apakah generator harus menolak include ke path yang tidak ada?
- Validator nama vs keyword BIRD (kasus `limit` — hanya peringatan `bird -p`, config diterima): sebaiknya validator menolak/memperingatkan nama yang menabrak keyword?
- Validasi keberadaan filter yang dirujuk channel (kasus `radv_in` — mock gap, generator tidak memvalidasi): sebaiknya generator memvalidasi filter yang dirujuk sudah didefinisikan?
- `hmac md5` untuk password Babel ter-parse exit 0 tapi generator sengaja tidak menerimanya (keputusan desain lama) — biarkan atau izinkan?
- Generator sebaiknya menolak pre-emptif `rr-client` untuk neighbor eBGP (BIRD menolak dengan "Only internal neighbor can be RR client" — fail-safe via bird -p, tapi validasi awal lebih baik).
