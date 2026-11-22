#!/bin/sh
# TITIAN — daftar nama checkpoint untuk completion klish (VAR Get_checkpoints).
# Sumber: direktori $STATE_ROOT/checkpoints/ — satu nama per baris, unik, terurut.
# Titik tersembunyi (diawali '.', mis. .last-save) TIDAK dicantumkan
# (tidak bisa di-rollback lewat nama).
# Dipakai PARAM completion="${Get_checkpoints}" (rollback, checkpoint delete).
# Keluar kosong (rc 0) bila belum ada checkpoint / dir belum ada.
# POSIX sh.
STATE_ROOT="${TITIAN_STATE_ROOT:-/etc/titian}"
CKPT_DIR="$STATE_ROOT/checkpoints"
[ -d "$CKPT_DIR" ] || exit 0
for d in "$CKPT_DIR/"*/; do
    [ -d "$d" ] || continue
    name=${d%/}; name=${name##*/}
    case "$name" in .*) continue ;; esac
    printf '%s\n' "$name"
done | sort -u
