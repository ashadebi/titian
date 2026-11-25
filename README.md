# Titian

CLI bergaya vendor (Cisco/Junos) di atas klish + BIRD untuk router —
jalan di **Debian (Linux)** maupun **FreeBSD/BSDRP**.

- **Branch `bsdrp`**: Titian normal untuk image BSDRP resmi (FreeBSD),
  paket `titian` 0.1.1 (rilis 24 Nov 2026), **tanpa API**.
  Baca `README.md` di branch itu.
- **Branch `titian-api`**: versi lanjutan `bsdrp` dengan API HTTP+JSON
  (94 endpoint v1) + web UI operator untuk BRAS di-enable.
  Calon rilis 0.1.2, belum dirilis.
- Branch `main` ini berisi dokumen lab — kerja aktif Titian ada di
  `bsdrp` dan `titian-api`.
