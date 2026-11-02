# Titian

Titian is a Cisco/Junos-style CLI for routers, built on klish 2.2.5 and BIRD 2,
for Debian and FreeBSD. A web dashboard above the same CLI engine is planned;
the installed klish binary is the single query/execution layer (the single-engine
principle: web queries and executions run as batch clish, never as a bypass).

## Layout

- `tree/` — klish command-tree XML (the CLI definition; adapted from a
  working rtcli-conf tree, not rebuilt from scratch).
- `tree-nonroot/` — non-root view XML (info-mode, overview, ping, startup).
- `sbin/` — POSIX helper scripts backing the tree's ACTIONs
  (interfaces, bonding/LAGG, VLAN, VXLAN, tuning, firewall/NAT,
  checkpoint/rollback, BIRD interaction, system settings).
- `install/` — `titian-install.sh` plus log-rotation configs
  (logrotate for Linux, newsyslog for FreeBSD).
- `bird.d/` — BIRD configuration templates (bgp, ospf, static, filter,
  function, protocol).

## Features (lab-tested on Debian 13 and FreeBSD 15.0)

- Interfaces: full system interface listing (up/down/disabled), ethernet,
  loopback, VLAN, VXLAN, bonding/LACP (Linux) and lagg (FreeBSD).
- Per-OS unified interface type plus `rename <old> <new>` with persistent
  rename (systemd `.link` on Linux, rc.conf rename block on FreeBSD) and
  Titian state migration (netstate, mirrors, running-config references).
- Tuning: `system sysctl`, persistent mtu/qlen/offload/coalesce, and the
  read-only `titian-tune-recommend` tool.
- Speed: `speed <value> [duplex <full|half>]` on Linux ethernet (persistent).
- Firewall/NAT: unified CLI over nftables (Linux) and pf (FreeBSD) — filter,
  srcnat, dstnat/port forwarding. IPv4 only; forward default-deny.
- Checkpoint/rollback: named checkpoints (`checkpoint save/list/delete`,
  `rollback <name>`, bare `rollback` to startup-config), persistent across
  reboot, including bird.conf, netstate and sysctl state.
- Routing via BIRD: BGP (including communities, multihop, IPv6 sessions),
  OSPF, BFD, RPKI validation against a local trust anchor in the lab.

## Install

On the router machine, as root:

```sh
./install/titian-install.sh
```

The installer places the tree under `/opt/titian` (both OSes) and wires the
`titian` command. Native `.deb`/`.pkg` packaging of this tree is maintained
separately; this repository holds the source the packages are built from.

## Notes

- Interface naming uses the Roman speed-name model for physical names
  (xe = 10G, xxve = 25G, xle = 40G, le = 50G, ce = 100G, cce = 200G,
  cde = 400G) in completion and documentation.
- Renaming Titian objects themselves (bond/vxlan/lagg/dummy) is not
  supported — delete and recreate them instead.
- OpenBGPd is intentionally not used; BIRD is the only routing engine.
