#!/bin/sh
# titian-replay-prep.sh — preprocess startup-config sebelum replay klish.
# Batch B20 program BIRD (17 Nov 2026): generalisasi aturan B19 ke SEMUA view.
#
# MASALAH (akar TERBUKTI, B20 — rantai sebab-akibat dari sumber klish 2.2.5):
# replay (`clish -w configure-view <startup-config>`) TIDAK mengeluarkan
# (pop) view saat indentasi berkas berkurang. Perintah yang diwarisi via
# NAMESPACE dari view induk langsung resolve di view anak — dengan ctx
# (viewid) yang SALAH. ACTION backend gagal (ctx tidak lengkap / instance
# kosong) -> hook CONFIG klish TIDAK jalan (hanya jalan bila ACTION sukses,
# `clish/shell/shell_execute.c`: `if (!result) clish_shell_exec_config(...)`)
# -> baris TIDAK terekam di store konfd -> `save` (dump store) MENGHILANGKAN
# baris itu. Bukti eksperimen 1 (17 Nov ~00:08 UTC): save pasca-restart
# menghasilkan dump 143 baris vs anchor 164 — hilang 21 baris view bersarang
# (9 leaf neighbor BGP, 3 child channel flow6, 2 leaf RIP, 7 leaf OSPF).
# Bukti log: viewid channel flow6 = `:flow6` (IP neighbor kosong);
# `Error(titian-bgp): ctx channel BGP tidak lengkap::flow6` (3x);
# `Error(titian-bgp): neighbor-set butuh IP field [value]` (7x);
# `Error(titian-rip): instance harus rip|ripng: ` (kosong, 2x);
# `Error(titian-ospf): ctx vlink OSPF harus <INST>:<AREA>:<ROUTER-ID>: `
# (kosong), `ctx area OSPF harus <INST>:<AREA>: `, `instance harus
# ospf|ospf6: ` (7x). Akarnya SATU: navigasi replay, bukan backend.
# (B19 hanya menambal RAdv; B20 menutup semua view. Cakupan B21 —
# "replay OSPF/RIP gagal LOUD" — TERSERAP fix ini: akar yang sama,
# diperbaiki di titik yang sama.)
#
# PERBAIKAN: sisipkan `exit` eksplisit (builtin `clish_nested_up`,
# deterministik, tidak bergantung indentasi) supaya tiap baris dieksekusi
# di view yang diimplikasikan indentasinya. Model depth (dari sumber klish):
#   - pwd = baris masuk view; depth view = atribut XML `depth`
#     (default 0 bila tidak ada); perintah di view depth d muncul di
#     startup-config dengan indent d (konfd mencetak node depth > top_depth
#     dengan indent depth - top_depth - 1; top_depth = pwdc - 1).
#   - Jadi: baris indent k dieksekusi di / masuk dari view depth k.
#     SEBELUM baris: bila depth saat ini > k, emit (depth - k) baris `exit`.
#     SESUDAH baris: bila view-enter -> depth = k + 1; bila leaf -> depth = k.
#   - Baris indent 0: pop ke 0. Baris `!` (komentar/stamp) + baris kosong:
#     diabaikan tracker. `exit` di input: pop 1. `end`: reset ke 0.
# Pola yang sama dengan perbaikan bridge 12 Nov 2026 + B19 — kini umum.
#
# TABEL VIEW-ENTER (pola, indent): diturunkan dari XML staging
# (60 nama view-enter; tiap COMMAND dengan atribut `view=`). Aturan
# memakai (pola, indent) + stack view saat ini untuk pola ambigu:
# Koreksi B20 dari audit XML lengkap (108 COMMAND view-enter):
# aggregator/l3vpn/mrt/wireguard punya PARAM Name (bentuk `<nama> X`,
# pola mengizinkan tanpa param juga); virtual-link 1 param (bukan 2);
# prefix/rdnss/dnssl ada di DUA indent (global @2 di radv view DAN
# iface @3 di radv-iface view). virtual-link @3 (area view, 1 param).
# `pipe` ada di DUA indent (bird pipe view @1 DAN pipe-detail view @2).
# Perintah navigasi enable-view (`configure terminal`, `bird terminal`)
# BUKAN baris startup-config — tidak ada di tabel (helper menolaknya
# sebagai leaf; mock B20 mengecualikannya).
#   - `interface`: view-enter @2 HANYA bila view saat ini salah satu dari
#     {radv, rip, ripng, bfd, babel, device} (whitelist — leaf `interface`
#     ada di neighbor BGP view, bfd-neighbor view, direct view,
#     ipoe/pppoe view, ts-rule view); @3 bila view saat ini = area OSPF.
#   - `channel`: view-enter bila view saat ini = neighbor BGP view
#     (stack[2] = `neighbor ...`); leaf `channel` di kernel/device
#     tidak ada (dicek B20) — kondisi ini menjaga bila muncul nanti.
#   - `multihop` bare @2: view-enter HANYA bila view saat ini = bfd
#     (leaf `multihop` bare ada di neighbor BGP view).
#   - `pipe` @2: view-enter (bird pipe-detail view) HANYA bila top =
#     `router bird` (leaf `pipe` ada di ts-queue/ts-rule view).
#   - `password` @3: view-enter bila seksi = bfd/rip (stack[2] = `bfd`
#     / `rip`); LEAF bila seksi = babel (stack[2] = `babel`).
#     `password` @4 = view-enter OSPF (tanpa ambiguitas).
#   - `filter <NAME>` @1: view-enter bila top = `router bird`
#     (leaf `filter <chain> <action> ...` di firewall view punya
#     3+ kata — tidak cocok pola 2 kata ini).
#   - `neighbor` @1 (bird) / @2 (frr-bgp, bfd) = view-enter;
#     `neighbor` @4 = LEAF OSPF (bukan view-enter).
#   - `bfd` bare @1 = view-enter; bare @2/@4 = LEAF (neighbor/OSPF).
#   - `multihop` bare @2 = view-enter (bfd view); bare @3 = LEAF
#     (bfd-neighbor view).
#   - `direct` bare @1 = view-enter (bird view); bare @2 = LEAF
#     (neighbor view).
#   - `route-map <N> permit|deny <N>` @1 = view-enter (frr);
#     `route-map <N> in|out` @3 = LEAF (frr-bgp-neighbor).
#   - `pipe`/`queue`/`sched` @1 = view-enter (bird/ts view);
#     @2 = LEAF (ts-pipe/queue/rule view).
#   - `via <IP>` @3 = view-enter static-nexthop view.
#   - `options` bare @1 = view-enter (if view).
# Mock B20 WAJIB memverifikasi tabel ini terhadap XML (tiap view-enter
# di XML harus ada di tabel dengan indent benar; tiap entri tabel harus
# berkorespondensi dengan view-enter nyata) supaya penambahan view-enter
# di XML di masa depan gagal LOUD di mock, bukan diam-diam.
#
# PERBEDAAN disengaja vs B19 (helper lama): aturan umum mem-pop SEBELUM
# `rpki lab` (indent 1) sesudah seksi radv (depth 3) -> 2 exit; B19
# mengandalkan NAMESPACE di titik itu (0 exit, terbukti bekerja).
# Keduanya benar secara perilaku, tapi pop eksplisit lebih aman karena
# perintah berikut bisa bergantung viewid parent. Mock B19 diperbarui
# di B20 (asersi "tanpa exit sebelum rpki lab" -> "2 exit", dengan
# komentar alasan ini). Aturan bridge B19 + RAdv B19 TERGANTIKAN oleh
# aturan umum (bukan ditumpuk) — keluarannya identik di titik-titik itu.
#
# Lead B19 (1) TERJELASKAN (bukan bug baru): pesan "The error while
# request to the config daemon." = konfd TIDAK menjawab karena pwd tidak
# ditemukan di tree ("Unknown path.", `bin/konfd.c` process_query return
# NULL). Terjadi saat perintah dieksekusi di view yang SALAH (pwd
# menunjuk node yang tidak ada — mis. `dnssl` di bawah `radv`, padahal
# node itu ada di bawah `interface bridge0`). Sesudah navigasi benar,
# pesan ini hilang dari replay log.
#
# Lead B19 (2) TERJELASKAN (bukan bug, kosmetik): baris telanjang
# `prefix-touch` tidak bertahan di intent live karena `cmd_prefix_touch`
# di `sbin/titian-radv.sh` SENGAJA tidak menambah baris telanjang bila
# baris field prefix itu sudah ada (grep `^<pre> ` cocok dengan baris
# field). Saat replay, intent sudah berisi baris field dari state
# sebelumnya -> bare line tidak pernah ditambahkan. Section hasil SAMA
# (mock B19 C2). Daemon TIDAK pernah menulis intent; backend yang
# disengaja. Tidak perlu fix.
#
# Idempotensi helper: `exit` di input mem-pop 1 level; guard
# prep(prep(x)) == prep(x) dipertahankan (exit yang disisipkan akan
# dihitung sebagai pop oleh pass kedua, bukan ditambah lagi).
#
# Penggunaan: titian-replay-prep.sh [startup-config]
#   tanpa argumen: baca stdin. Output: prep file ke stdout.
#   Dipanggil titian-boot.sh; JANGAN jalankan berantai pada file yang
#   sudah di-prep di luar guard di atas (tetap aman karena guard, tapi
#   tidak ada gunanya).
# POSIX sh + awk POSIX (jalan di FreeBSD awk maupun gawk).
[ $# -gt 1 ] && { echo "Usage: $0 [startup-config]" >&2; exit 2; }
_input="${1:-/dev/stdin}"
[ -e "$_input" ] || { echo "titian-replay-prep.sh: file tidak ada: $_input" >&2; exit 2; }
awk '
function is_viewenter(t, ind) {
    # t = baris tanpa indent; ind = indent (spasi). stack[d] = baris
    # view-enter yang masuk ke depth d (stack[1] = view-enter indent 0).
    if (ind == 0) {
        if (t ~ /^router bird$/) return 1
        if (t ~ /^router frr$/) return 1
        if (t ~ /^service ssh$/) return 1
        if (t ~ /^traffic-shape$/) return 1
        if (t ~ /^firewall$/) return 1
        if (t ~ /^pppoe-server$/) return 1
        if (t ~ /^monitoring$/) return 1
        if (t ~ /^wireguard( [^ ]+)?$/) return 1
        if (t ~ /^ipoe-server$/) return 1
        if (t ~ /^system name-servers$/) return 1
        if (t ~ /^interface (bridge|ethernet|lagg|loopback|vlan|vxlan) /) return 1
        return 0
    }
    if (ind == 1) {
        if (t ~ /^neighbor [^ ]+$/) return 1
        if (t ~ /^filter [^ ]+$/) return (stack[1] ~ /^router bird$/) ? 1 : 0
        if (t ~ /^bfd$/) return 1
        if (t ~ /^global$/) return 1
        if (t ~ /^static$/) return 1
        if (t ~ /^direct$/) return 1
        if (t ~ /^pipe( [^ ]+)?$/) return 1
        if (t ~ /^kernel$/) return 1
        if (t ~ /^device$/) return 1
        if (t ~ /^rip$/) return 1
        if (t ~ /^ripng$/) return 1
        if (t ~ /^ospf$/) return 1
        if (t ~ /^ospfv3$/) return 1
        if (t ~ /^aggregator( [^ ]+)?$/) return 1
        if (t ~ /^mrt( [^ ]+)?$/) return 1
        if (t ~ /^radv$/) return 1
        if (t ~ /^rpki [^ ]+$/) return 1
        if (t ~ /^bmp$/) return 1
        if (t ~ /^babel$/) return 1
        if (t ~ /^l3vpn( [^ ]+)?$/) return 1
        if (t ~ /^function [^ ]+$/) return 1
        if (t ~ /^router bgp [0-9]+$/) return 1
        if (t ~ /^router ospf$/) return 1
        if (t ~ /^route-map [^ ]+ (permit|deny) [0-9]+$/) return 1
        if (t ~ /^user [^ ]+$/) return 1
        if (t ~ /^peer [^ ]+$/) return 1
        if (t ~ /^options$/) return 1
        if (t ~ /^queue [^ ]+$/) return 1
        if (t ~ /^sched [^ ]+$/) return 1
        if (t ~ /^rule [^ ]+$/) return 1
        return 0
    }
    if (ind == 2) {
        if (t ~ /^neighbor [^ ]+$/) return 1
        if (t ~ /^channel [^ ]+$/) return (stack[2] ~ /^neighbor /) ? 1 : 0
        if (t ~ /^interface [^ ]+$/) return (stack[2] ~ /^(radv|rip|ripng|bfd|babel|device)$/) ? 1 : 0
        if (t ~ /^area [^ ]+$/) return 1
        if (t ~ /^route [^ ]+$/) return 1
        if (t ~ /^route6 [^ ]+$/) return 1
        if (t ~ /^flow-route [^ ]+ [^ ]+$/) return 1
        if (t ~ /^ipv4$/) return 1
        if (t ~ /^ipv6$/) return 1
        if (t ~ /^multihop$/) return (stack[2] ~ /^bfd$/) ? 1 : 0
        if (t ~ /^pipe( [^ ]+)?$/) return (stack[1] ~ /^router bird$/) ? 1 : 0
        if (t ~ /^prefix [^ ]+$/) return 1
        if (t ~ /^rdnss$/) return 1
        if (t ~ /^dnssl$/) return 1
        return 0
    }
    if (ind == 3) {
        if (t ~ /^interface [^ ]+$/) return (stack[3] ~ /^area /) ? 1 : 0
        if (t ~ /^password .+$/) return (stack[2] ~ /^(bfd|rip)$/) ? 1 : 0
        if (t ~ /^prefix [^ ]+$/) return 1
        if (t ~ /^rdnss$/) return 1
        if (t ~ /^dnssl$/) return 1
        if (t ~ /^via [^ ]+$/) return 1
        if (t ~ /^virtual-link [^ ]+$/) return 1
        return 0
    }
    if (ind == 4) {
        if (t ~ /^password .+$/) return 1
        return 0
    }
    return 0
}
{
    line = $0
    tmp = line
    sub(/^ +/, "", tmp)
    ind = length(line) - length(tmp)

    # Baris `!` + kosong: diabaikan tracker, di-emit apa adanya.
    if (tmp == "" || substr(tmp, 1, 1) == "!") { print line; next }

    # `exit` di input (hasil prep sebelumnya): pop 1 level.
    if (tmp == "exit") {
        print line
        if (depth > 0) { delete stack[depth]; depth-- }
        next
    }
    # `end`: reset ke configure-view.
    if (tmp == "end") {
        print line
        depth = 0
        for (i in stack) delete stack[i]
        next
    }

    # Pop ke depth yang diimplikasikan indentasi.
    target = (ind == 0) ? 0 : ind
    while (depth > target) {
        print "exit"
        delete stack[depth]
        depth--
    }
    print line
    if (is_viewenter(tmp, ind)) {
        depth = ind + 1
        stack[depth] = tmp
    } else {
        depth = target
    }
}
' "$_input"
