#!/bin/sh
# TITIAN — daftar nama service rc untuk completion klish (VAR Get_services).
# Dipakai PARAM completion="${Get_services}" (`show service status`).
# Sumber (read-only, yang pertama berhasil; tiap perintah jalan sekali):
#   FreeBSD: `service -l` (semua rc script, satu path per baris) -> basename.
#   Linux:   `service --status-all` (`[ + ]  nama`) -> kolom nama.
#   Fallback: daftar statis service yang dikenal image Titian/BSDRP.
# Satu nama per baris, unik, terurut. Keluar kosong (rc 0) bila tidak ada
# sumber yang berhasil. POSIX sh.
if command -v service >/dev/null 2>&1; then
    _out=$(service -l 2>/dev/null)
    if [ -n "$_out" ]; then
        printf '%s\n' "$_out" | while IFS= read -r _l; do
            [ -n "$_l" ] || continue
            _b=${_l##*/}
            [ -n "$_b" ] && printf '%s\n' "$_b"
        done | sort -u
        exit 0
    fi
    _out=$(service --status-all 2>/dev/null)
    if [ -n "$_out" ]; then
        printf '%s\n' "$_out" | awk '{print $NF}' | sort -u
        exit 0
    fi
fi
# Fallback statis (image Titian/BSDRP, 23 Nov 2026).
printf '%s\n' bird dhcpd frr mpd5 nfacctd sshd titian | sort -u
