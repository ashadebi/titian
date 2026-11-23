#!/usr/local/bin/python3
# titian-help-lang.py -- Bahasa help Titian (English default + Indonesian).
#
# Latar: help (`show help` / `help all` / `show route help`, via
# titian-help.sh + titian-show-route-help.sh) DAN tanda `?` (inline help
# klish/libtinyrl) sama-sama membaca atribut help="..." dari XML clish
# yang dimuat klish. Jadi satu setting bahasa harus mengubah KEDUAnya.
#
# Mekanisme (satu sumber kebenaran = tree XML):
#   * tree/*.xml menyimpan DUA bahasa per perintah/param:
#       help="..."     = bahasa Inggris (kanonik, default)
#       help-id="..."  = bahasa Indonesia (hanya bila ada teks ID-nya;
#                         bila tidak ada, bahasa Indonesia memakai help)
#   * Generator ini (sub-perintah `generate`) membaca tree dan menulis
#     direktori flat yang dibaca klish (ROOT/etc/clish-en) dengan
#     help="..." diisi teks bahasa yang dipilih; help-id dihapus dari
#     hasil (flat selalu satu bahasa). Selain nilai help, isi file
#     dipertahankan byte-identik (komentar, spasi, urutan atribut).
#   * `system help-language <english|indonesian>` (configure-view,
#     CONFIG-persisten) memanggil `set`: tulis setting ke state file,
#     regenerate flat dir, dan beri tahu bahwa `?` ikut pada login
#     berikutnya (klish memuat XML saat sesi dimulai; `help` langsung
#     ikut karena dibaca dari flat dir saat runtime).
#   * Karena setting CONFIG-persisten, replay boot menjalankan ACTION
#     ini lagi -> flat dir selalu cocok dengan setting (self-healing
#     sesudah re-deploy / reboot).
#
# Penggunaan:
#   titian-help-lang.py generate <english|indonesian> <srcdir> <destdir>
#   titian-help-lang.py set <english|indonesian>
#   titian-help-lang.py get
#
# Env override (mock / hermetik, pola yang sama seperti TITIAN_STATE_ROOT):
#   TITIAN_ROOT        (default /opt/titian): tree di $ROOT/etc/clish-en/tree,
#                      flat di $ROOT/etc/clish-en
#   TITIAN_STATE_ROOT  (default /etc/titian): state file help-language
#   TITIAN_HELP_TREE   (default $TITIAN_ROOT/etc/clish-en/tree)
#   TITIAN_HELP_FLAT   (default $TITIAN_ROOT/etc/clish-en)
#   TITIAN_HELP_NOREMOUNT=1 : jangan coba remount (untuk mock)
#
# Flat dir di / adalah read-only (UFD boot): bila tulis gagal karena
# read-only, generator remount rw (`mount -u -o rw /`), tulis, lalu
# kembalikan ro. Gagal -> rc 33 + pesan jelas (bukan fatal diam-diam).
# POSIX: Python 3 stdlib saja. Dibuat 2026-11-21 (fitur help-language).
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

LANGS = ("english", "indonesian")
HELP_RE = re.compile(r'(?<![\w-])help="([^"]*)"')
HELPID_RE = re.compile(r'(?<![\w-])help-id="([^"]*)"')


def _tokenize(text):
    """Pecah teks menjadi segmen ('comment'|'tag'|'text', isi).

    Tag dipindai dengan state machine yang menghormati nilai atribut
    ber-quoted (karakter '>' di dalam "..." TIDAK menutup tag — ada
    help yang berisi '->'). Komentar <!--...--> tidak disentuh.
    """
    segs = []
    i, n = 0, len(text)
    buf_start = 0
    while i < n:
        if text.startswith("<!--", i):
            if i > buf_start:
                segs.append(("text", text[buf_start:i]))
            j = text.find("-->", i + 4)
            if j == -1:
                segs.append(("comment", text[i:]))
                return segs
            j += 3
            segs.append(("comment", text[i:j]))
            i = j
            buf_start = i
            continue
        if text[i] == "<":
            if i > buf_start:
                segs.append(("text", text[buf_start:i]))
            # pindai tag: hormati "..." quoted
            j = i + 1
            in_q = False
            while j < n:
                c = text[j]
                if c == '"':
                    in_q = not in_q
                elif c == ">" and not in_q:
                    break
                j += 1
            if j >= n:
                segs.append(("text", text[i:]))
                return segs
            segs.append(("tag", text[i:j + 1]))
            i = j + 1
            buf_start = i
            continue
        i += 1
    if buf_start < n:
        segs.append(("text", text[buf_start:]))
    return segs


def _rewrite_tag(tag, lang):
    """Tukar nilai help= pada satu tag sesuai bahasa. Kembalikan tag baru.

    english:    help tetap, help-id dihapus.
    indonesian: help = help-id bila ada (kalau tidak, help tetap),
                help-id dihapus.
    """
    m_help = HELP_RE.search(tag)
    m_id = HELPID_RE.search(tag)
    if m_help is None and m_id is None:
        return tag
    help_val = m_help.group(1) if m_help else None
    id_val = m_id.group(1) if m_id else None
    if lang == "indonesian" and id_val is not None:
        new_help = id_val
    else:
        new_help = help_val
    # Hapus help-id (bila ada) tanpa merusak indentasi / spasi tag:
    # - bila help-id di baris sendiri: hapus baris itu utuh (newline +
    #   indent + atribut) sehingga baris lain tetap rapi;
    # - bila sebaris: hapus satu spasi di depannya + atribut.
    out = re.sub(r'\n[ \t]*help-id="[^"]*"', '', tag)
    out = re.sub(r' help-id="[^"]*"', '', out)
    if m_help is not None:
        out = HELP_RE.sub(lambda _m: 'help="%s"' % new_help, out, count=1)
    elif new_help is not None:
        # Tag punya help-id tapi tanpa help: sisipkan help sesudah nama tag.
        out = re.sub(r'^(<\w+)', lambda _m: '%s help="%s"' % (_m.group(1), new_help),
                     out, count=1)
    return out


def generate(lang, srcdir, destdir):
    """Generate flat dir dari tree. Kembalikan (ok, pesan, statistik)."""
    if lang not in LANGS:
        return False, "bahasa harus 'english' atau 'indonesian'", {}
    if not os.path.isdir(srcdir):
        return False, "direktori XML sumber tidak ditemukan: %s" % srcdir, {}
    files = sorted(f for f in os.listdir(srcdir) if f.endswith(".xml"))
    if not files:
        return False, "tidak ada XML di %s" % srcdir, {}
    os.makedirs(destdir, exist_ok=True)
    stats = {"files": 0, "help_swapped": 0, "help_id_seen": 0}
    for fname in files:
        src = os.path.join(srcdir, fname)
        with open(src, "r", encoding="utf-8") as fh:
            text = fh.read()
        segs = _tokenize(text)
        out_parts = []
        for kind, chunk in segs:
            if kind == "tag":
                if HELPID_RE.search(chunk):
                    stats["help_id_seen"] += 1
                new = _rewrite_tag(chunk, lang)
                if new != chunk:
                    stats["help_swapped"] += 1
                out_parts.append(new)
            else:
                out_parts.append(chunk)
        out_text = "".join(out_parts)
        # Validasi: hasil harus well-formed + tidak ada help-id tersisa.
        try:
            ET.fromstring(out_text)
        except ET.ParseError as e:
            return False, "%s: hasil generate tidak well-formed: %s" % (fname, e), stats
        if "help-id=" in out_text:
            return False, "%s: help-id tersisa sesudah generate" % fname, stats
        dest = os.path.join(destdir, fname)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(out_text)
        stats["files"] += 1
    return True, "generate %s: %d file, %d help ditukar" % (
        lang, stats["files"], stats["help_swapped"]), stats


def _paths():
    root = os.environ.get("TITIAN_ROOT", "/opt/titian")
    state = os.environ.get("TITIAN_STATE_ROOT", "/etc/titian")
    tree = os.environ.get("TITIAN_HELP_TREE",
                          os.path.join(root, "etc", "clish-en", "tree"))
    flat = os.environ.get("TITIAN_HELP_FLAT",
                          os.path.join(root, "etc", "clish-en"))
    return root, state, tree, flat


def _remount_rw():
    """Remount / rw bila read-only. Kembalikan True bila perlu dikembalikan ro."""
    if os.environ.get("TITIAN_HELP_NOREMOUNT") == "1":
        return False
    try:
        out = subprocess.run(["mount"], capture_output=True, text=True).stdout
    except Exception:
        return False
    for line in out.splitlines():
        parts = line.split()
        # Format FreeBSD/Linux: "<dev> on / (<fstype>, ..., read-only, ...)"
        if len(parts) >= 3 and parts[1] == "on" and parts[2] == "/":
            if "read-only" in line:
                r = subprocess.run(["mount", "-u", "-o", "rw", "/"],
                                   capture_output=True, text=True)
                return r.returncode == 0
            return False
    return False


def _remount_ro():
    if os.environ.get("TITIAN_HELP_NOREMOUNT") == "1":
        return
    subprocess.run(["mount", "-u", "-o", "ro", "/"],
                   capture_output=True, text=True)


def _write_state(state_dir, lang):
    os.makedirs(state_dir, exist_ok=True)
    with open(os.path.join(state_dir, "help-language"), "w") as fh:
        fh.write(lang + "\n")


def get_lang(state_dir):
    try:
        with open(os.path.join(state_dir, "help-language")) as fh:
            v = fh.read().strip()
        if v in LANGS:
            return v
    except OSError:
        pass
    return "english"


def cmd_set(lang):
    if lang not in LANGS:
        print("Error(titian-help-lang): bahasa harus 'english' atau "
              "'indonesian'.", file=sys.stderr)
        return 33
    _root, state_dir, tree, flat = _paths()
    if not os.path.isdir(tree):
        print("Error(titian-help-lang): tree XML tidak ditemukan: %s"
              % tree, file=sys.stderr)
        return 33
    # Tulis state dulu (supaya get + deploy berikut tahu bahasa aktif).
    try:
        _write_state(state_dir, lang)
    except OSError as e:
        print("Error(titian-help-lang): tidak bisa tulis state: %s"
              % e, file=sys.stderr)
        return 33
    # / bisa read-only (boot UFD): remount rw DULU, sebelum membuat
    # direktori sementara — temp dir ada di /opt (di / read-only),
    # bukan di /etc (tmpfs, selalu writable). Tanpa ini, generate()
    # crash OSError EROFS sebelum sempat remount (temuan live 21 Nov).
    restored_ro = _remount_rw()
    # Generate ke direktori sementara dulu (validasi penuh sebelum sentuh flat).
    tmp = flat + ".tmp-help-lang"
    try:
        if os.path.isdir(tmp):
            shutil.rmtree(tmp)
        ok, msg, _st = generate(lang, tree, tmp)
        if not ok:
            print("Error(titian-help-lang): %s" % msg, file=sys.stderr)
            return 33
        # Pindahkan hasil ke flat dir.
        for fname in os.listdir(tmp):
            dest = os.path.join(flat, fname)
            shutil.copyfile(os.path.join(tmp, fname), dest)
    except OSError as e:
        print("Error(titian-help-lang): tidak bisa tulis flat dir %s: %s"
              % (flat, e), file=sys.stderr)
        return 33
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        if restored_ro:
            _remount_ro()
    print("Help language: %s" % lang)
    if lang == "english":
        print("Help dan '?' kini berbahasa Inggris (teknis).")
    else:
        print("Help dan '?' kini berbahasa Indonesia.")
    print("Perintah 'help' langsung ikut; '?' ikut pada login CLI berikutnya.")
    return 0


def main(argv):
    if len(argv) < 2:
        print("Usage: titian-help-lang.py {generate <lang> <srcdir> "
              "<destdir>|set <lang>|get}", file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "generate":
        if len(argv) != 5:
            print("Usage: titian-help-lang.py generate <lang> <srcdir> "
                  "<destdir>", file=sys.stderr)
            return 2
        ok, msg, _st = generate(argv[2], argv[3], argv[4])
        print(msg)
        return 0 if ok else 33
    if cmd == "set":
        if len(argv) != 3:
            print("Usage: titian-help-lang.py set <english|indonesian>",
                  file=sys.stderr)
            return 2
        return cmd_set(argv[2])
    if cmd == "get":
        _root, state_dir, _tree, _flat = _paths()
        print(get_lang(state_dir))
        return 0
    print("Usage: titian-help-lang.py {generate|set|get}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
