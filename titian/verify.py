#!/usr/bin/env python3
"""Verifikasi tree klish BSDRP (~/workspace/titian-bsdRP-xml/tree).

Cek:
  1. setiap XML well-formed (xml.etree; pengganti xmllint --noout —
     xmllint tidak terpasang di VM ini)
  2. NOL Duplicate COMMAND dalam satu VIEW yang sama (nama COMMAND yang
     sama di dua file tapi VIEW berbeda = legal klish; yang gagal adalah
     nama sama dalam VIEW sama — terbukti 30 Okt 2026)
  3. setiap ptype="X" yang dipakai terdefinisi di tree (atau builtin
     klish: SUBCOMMAND)
  4. setiap view="X" / NAMESPACE ref="X" merujuk VIEW yang terdefinisi
  5. setiap ${RT_SBIN}/xxx.sh yang dirujuk ACTION ada di sbin/
  6. sh -n semua sbin/*.sh + etc/rc.d/*

Jalankan: python3 verify.py  (exit 0 = semua lolos)
"""
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

BASE = os.path.dirname(os.path.abspath(__file__))
TREE = os.path.join(BASE, "tree")
SBIN = os.path.join(BASE, "sbin")
NS = {"c": "http://clish.sourceforge.net/XMLSchema"}
# types.xml memakai xmlns /opt/titian/XMLSchema — tangani keduanya.
NS2 = {"c": "/opt/titian/XMLSchema"}

errors = []
warnings = []

xml_files = sorted(f for f in os.listdir(TREE) if f.endswith(".xml"))
print(f"XML files: {len(xml_files)}")

defined_ptypes = set()
defined_views = set()
cmd_by_view = defaultdict(list)   # (view, command) -> [files]
ptype_used = defaultdict(list)    # ptype -> [files]
view_refs = []                    # (kind, name, file)
sbin_refs = defaultdict(list)     # script -> [files]

for fname in xml_files:
    path = os.path.join(TREE, fname)
    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        errors.append(f"{fname}: XML tidak well-formed: {e}")
        continue
    root = tree.getroot()
    # tag lokal tanpa namespace
    def local(tag):
        return tag.rsplit("}", 1)[-1]
    for el in root.iter():
        tag = local(el.tag)
        if tag == "PTYPE":
            defined_ptypes.add(el.get("name"))
        elif tag == "VIEW":
            defined_views.add(el.get("name"))
            for cmd in el:
                if local(cmd.tag) != "COMMAND":
                    continue
                name = cmd.get("name")
                if name:
                    cmd_by_view[(el.get("name"), name)].append(fname)
                # ACTION backend refs + view= refs di dalam COMMAND
                for sub in cmd.iter():
                    stag = local(sub.tag)
                    if stag == "ACTION":
                        for m in re.findall(r"\$\{RT_SBIN\}/([A-Za-z0-9_.-]+\.sh)", sub.text or ""):
                            sbin_refs[m].append(fname)
                    if stag == "COMMAND" and sub.get("view"):
                        view_refs.append(("view", sub.get("view"), fname))
        elif tag == "NAMESPACE":
            view_refs.append(("namespace", el.get("ref"), fname))
        elif tag == "VAR":
            # VAR dinamis (Get_checkpoints, Get_services, ...) juga
            # merujuk backend ${RT_SBIN}/*.sh — cek keberadaannya juga
            # (23 Nov 2026: sebelumnya lolos dari cek ini).
            for sub in el.iter():
                if local(sub.tag) == "ACTION":
                    for m in re.findall(r"\$\{RT_SBIN\}/([A-Za-z0-9_.-]+\.sh)", sub.text or ""):
                        sbin_refs[m].append(fname)
        elif tag == "PARAM":
            pt = el.get("ptype")
            if pt:
                ptype_used[pt].append(fname)

# 1b. Bare-parent rule (konvensi tree ini, terbukti di lab clish):
# setiap perintah multi-kata "A B ..." butuh tiap prefiks progresif
# ("A", "A B", ...) sebagai COMMAND di view yang sama (atau view yang
# terhubung via NAMESPACE, dua arah satu hop — mis. perintah `show ...`
# di syshw-view memakai induk `show` dari enable-view yang mengimpornya).
# Tanpa induk, klish lab menolak cabang itu ("Unknown command" / ACTION
# tidak jalan). Bentuk `no X` dikecualikan: `no` adalah negasi klish,
# yang dicek adalah bentuk positif X-nya.
view_cmds = defaultdict(set)      # view -> {command names}
view_ns = defaultdict(list)       # view -> [referenced views]
for (view, name), files in cmd_by_view.items():
    view_cmds[view].add(name)
for fname in xml_files:
    root2 = ET.parse(os.path.join(TREE, fname)).getroot()
    for el in root2.iter():
        if el.tag.rsplit("}", 1)[-1] == "VIEW":
            for ch in el:
                if ch.tag.rsplit("}", 1)[-1] == "NAMESPACE":
                    view_ns[el.get("name")].append(ch.get("ref"))
# closure satu hop dua arah lewat NAMESPACE
neighbours = defaultdict(set)
for v, refs in view_ns.items():
    for r in refs:
        neighbours[v].add(r)
        neighbours[r].add(v)
effective = {}
for v in view_cmds:
    eff = set(view_cmds[v])
    for nb in neighbours.get(v, set()):
        eff |= view_cmds.get(nb, set())
    effective[v] = eff
for (view, name), files in sorted(cmd_by_view.items()):
    toks = name.split(" ")
    if len(toks) < 2:
        continue
    if name.startswith("no "):
        # bentuk `no A B C`: prefiks "no", "no A", "no A B", ... harus ada
        # (sama seperti perintah biasa) + bentuk positif "A B C" harus ada.
        base = name[3:]
        if base and base not in effective[view]:
            errors.append(f"`no` tanpa bentuk positif: \"{name}\" di VIEW \"{view}\" (\"{base}\" tidak ada; lihat {sorted(set(files))})")
        for i in range(1, len(toks)):
            prefix = " ".join(toks[:i])
            if prefix not in effective[view]:
                errors.append(f"Perintah tanpa induk telanjang: \"{name}\" di VIEW \"{view}\" (prefiks \"{prefix}\" tidak didefinisikan; lihat {sorted(set(files))})")
        continue
    for i in range(1, len(toks)):
        prefix = " ".join(toks[:i])
        if prefix not in effective[view]:
            errors.append(f"Perintah tanpa induk telanjang: \"{name}\" di VIEW \"{view}\" (prefiks \"{prefix}\" tidak didefinisikan; lihat {sorted(set(files))})")

# 2. Duplicate COMMAND per view
for (view, name), files in sorted(cmd_by_view.items()):
    if len(files) > 1:
        errors.append(f'Duplicate COMMAND name="{name}" dalam VIEW "{view}": {files}')

# 3. PTYPE refs
builtin = {"SUBCOMMAND"}
for pt, files in sorted(ptype_used.items()):
    if pt not in defined_ptypes and pt not in builtin:
        errors.append(f"PTYPE tidak terdefinisi: {pt} (dipakai di {sorted(set(files))})")

# 4. VIEW refs
for kind, name, fname in view_refs:
    if name not in defined_views:
        errors.append(f"{kind} merujuk VIEW tidak ada: {name} (di {fname})")

# 5. sbin refs
for script, files in sorted(sbin_refs.items()):
    if not os.path.isfile(os.path.join(SBIN, script)):
        errors.append(f"Backend tidak ada di sbin/: {script} (dirujuk {sorted(set(files))})")

# 6. sh -n (shell) / py_compile (Python helper, mis. titian-radius-check.py)
for d in (SBIN, os.path.join(BASE, "etc", "rc.d")):
    if not os.path.isdir(d):
        continue
    for fname in sorted(os.listdir(d)):
        path = os.path.join(d, fname)
        if not os.path.isfile(path):
            continue
        if fname.endswith(".py"):
            r = subprocess.run(["python3", "-m", "py_compile", path], capture_output=True, text=True)
            if r.returncode != 0:
                errors.append(f"py_compile gagal: {path}: {r.stderr.strip()}")
            continue
        r = subprocess.run(["sh", "-n", path], capture_output=True, text=True)
        if r.returncode != 0:
            errors.append(f"sh -n gagal: {path}: {r.stderr.strip()}")

print(f"PTYPE terdefinisi: {len(defined_ptypes)}")
print(f"VIEW terdefinisi: {len(defined_views)}")
print(f"COMMAND unik (view+nama): {len(cmd_by_view)}")
print(f"Backend dirujuk: {len(sbin_refs)}")
if warnings:
    print("WARNINGS:")
    for w in warnings:
        print(f"  {w}")
if errors:
    print(f"ERRORS ({len(errors)}):")
    for e in errors:
        print(f"  {e}")
    sys.exit(1)
print("VERIFIKASI OK: NOL error")
