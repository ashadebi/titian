English translation of doc/panduan-cli.md (Indonesian). The Indonesian version is authoritative if the two differ.

# Complete Titian CLI Guide (klish)

This guide explains how to use the Titian CLI menu by menu, matching the
commands in the tree (`tree/`) of this repository. All examples use
TEST-NET addresses (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24,
2001:db8::/32) — replace them with your own network addresses.

The principle binding this entire guide: **single-engine**. The installed
klish binary is the only query/execution layer. Do not hand-edit
`bird.conf`, files in `/opt/titian`, or system configuration (systemd-networkd,
rc.conf, nftables, pf) — all changes go through CLI commands, then
`save`. Manually edited commands will be overwritten or become
inconsistent with Titian state.

## 0. Entering, modes, and conventions

### 0.1 Entering the CLI

```sh
sudo /usr/local/bin/titian
```

The CLI also accepts commands via stdin (for scripts/batches), but
interactive help (`?` and Tab) only works in an interactive session (PTY).

### 0.2 Modes and prompts

| Mode | How to enter | Prompt | How to exit |
|---|---|---|---|
| Exec (privileged) | start of session | `...#` | `logout` / `exit` |
| Configure | `configure terminal` | `cli-...(config)#` | `exit` or `end` |
| Interface | `interface <type> <name>` from configure | `...(config-if-<name>)#` | `exit` |
| Firewall | `firewall` from configure | `...(config-firewall)#` | `exit` |
| BIRD | `bird` or `bird terminal` from exec | `titian-...(birdc)#` | `exit` |
| SSH service | `service ssh` from configure | `...(config-system-...)#` | `exit` |
| Name-server | `system name-servers` from configure | `...(config-system-...)#` | `exit` |
| Options (tuning) | `options` from interface view | `...(config-if-<name>-options)#` | `exit` |

Mode notes:

- `configure` alone (without `terminal`) = incomplete command
  (Incompleted command). Always use `configure terminal`.
- `exit` goes back one level; `end` from configure mode returns directly
  to exec. In configure mode, `do <exec-command>` runs an exec command
  without leaving configure, e.g.: `do show interfaces terse`.
- `save` exists only in exec mode. Inside configure mode, `save` =
  Unknown command. The correct order: `end` first, then `save`.
- `?` shows the list of further syntax at the cursor position; Tab
  completes commands. Both only work in an interactive session.
- `no` negates a command (deletes a setting / restores the default).
  For the firewall, `no` uses the same full syntax as the creating
  command (a rule is identified by its CONTENT, not by an ID).
- Commands that change the live system (e.g. `ip address`) take effect
  immediately when executed; `save` is only about persistence (writing
  running-config to startup-config in `/etc/titian/startup-config`, mirrored to `/cfg/titian/startup-config`).
- `show running-config` shows the currently running configuration;
  `show startup-config` shows the contents of the startup-config file.
- `show history` shows the session command history.

### 0.3 Writing conventions in this guide

- `<iface>` = system interface name (see `show interfaces`).
- `<CIDR>` = address/prefix, e.g. `198.51.100.0/24`.
- `any` = all (firewall only).
- Commands in code blocks are written without a prompt, unless stated otherwise.
- `[Linux]` / `[FreeBSD]` = command exists only on that OS.

---

## 1. Exec mode — show commands and utilities

Exec mode is where you inspect state and run system-level actions. All
commands below are typed at the exec prompt.

### 1.1 Basic show

```
show                    # summary of running system information
show running-config     # currently running configuration
show startup-config     # contents of the startup-config file
show history            # command history
show pwd                # current working directory
```

### 1.2 Show interface

```
show interfaces              # all interfaces + their IP info
show interfaces terse        # all interfaces, one line per interface
                             # (admin/link status); DOWN interfaces show (D)
show interfaces all          # all interfaces, full detail
show interfaces ethernet <iface> [detail]
                             # status + configuration of one physical interface
show interfaces vlan <iface> [detail]
show interfaces vxlan [iface]
                             # VXLAN status + VNI + local/remote + FDB
show interfaces bonding <iface> [detail]   # [Linux]
show interfaces lagg <iface> [detail]      # [FreeBSD]
show interfaces tuning <iface>
                             # tuning values + meaning (mtu/qlen/speed/offload/coalesce)
```

`show interfaces` shows ALL interfaces detected by the system,
including ones that are DOWN or disabled — not only the ones configured
by Titian. DOWN interfaces are hidden by plain `ifconfig`, but still
show here (marked D); that is normal behavior, not a bug.

### 1.3 Show IP and routing

```
show ip route [ip-or-prefix]   # IPv4 routing table (optional: filter one prefix)
show ipv6 route [prefix]         # IPv6 routing table
show ip neighbor [iface]         # neighbor/ARP table (optional: per interface)
show ipv6                        # IPv6 information
```

### 1.4 Show system and hardware

```
show system              # system information summary
show system date         # system date/time
show system uptime       # how long the system has been up
show system process      # running processes
show system memory       # memory usage
show system storage      # filesystem usage
show system login        # login user info
show system connections  # active network connections
show system top          # top with pattern
show system sysctl       # sysctl values managed by Titian + meaning
show hardware            # system hardware detail
show hardware cpu        # CPU info
show hardware pci        # PCI bus detail
show hardware dmi        # DMI detail
```

### 1.5 Show service

```
show service summary          # service summary
show service status <name>    # init command for a specific service (Tab = list of rc services)
```

### 1.6 Ping and traceroute

```
ping <destination> [source <ip-or-iface>] [repeat <n>] [size <bytes>]
     [interval <seconds>] [resolve] [broadcast] [flood] [duplicate-detect]
ping ip <destination> ...     # explicit IPv4 (default)
ping ipv6 <destination> ...   # ICMPv6
ping arp <destination> ...    # ARP request to a neighbor
traceroute <destination> [source <ip>] [interface <iface>] [resolve]
traceroute ip <destination> ...
traceroute ipv6 <destination> ...
```

Examples:

```
ping 192.0.2.1 repeat 4
ping 2001:db8::1 source 2001:db8::2
traceroute 198.51.100.1
```

### 1.7 Other exec commands

```
configure terminal   # enter configure mode
bird                 # enter BIRD view
bird terminal        # enter BIRD terminal
save                 # save running-config to startup-config
logout               # exit the CLI
reboot               # NOTE: this command only prints text,
                     # it does NOT reboot the machine. Do not rely on it for rebooting.
help                 # Titian syntax overview
```

### 1.8 Pager — long output shown in stages (less)

The pager applies **globally to all show commands**: if the output
exceeds one screen, it is shown in stages through the `less` pager (not
dumped all at once). This covers `show interfaces`, `show ip route`,
`show bgp summary`, `show ospf neighbors`, `show running-config`,
`show startup-config`, and every other show command — including the
`birdc show ...` commands in the BIRD view. Inside the pager:
`SPACE` = next page, `ENTER` = next line, `q` = quit, `/text`
= search. If the output fits on one screen, the pager finishes immediately
with no pause. Status colours (green/red) are still shown inside the pager.

```
show interfaces              # in stages when longer than one screen
show running-config          # in stages (pager)
show running-config no-more  # no pager, dump everything at once
show startup-config no-more  # same for startup-config
show route help              # list of show route sub-commands, paged
show help                    # list of show sub-commands, paged
help all                     # list of all top-level commands, paged
terminal length 24           # pager active (default 24 lines)
terminal length 0            # pager off (all output dumped)
terminal no-more             # same as terminal length 0
terminal more                # pager active again (length 24)
```

Note: the pager is only active when output goes to an interactive terminal
(TTY). If output is piped or scripted (not a TTY), the pager is
automatically disabled and output is dumped in full — safe for automation.
Commands that are NOT paged (they must keep streaming live): `ping`,
`traceroute`, `show system top`, the live `monitoring` display, and
`factory-reset` (arm/confirm/restore) — as well as state-changing commands
(e.g. `reload`, `restart`, `disable`, `enable` in the BIRD view), whose
output is only a one- or two-line confirmation.

Known limit: `?` (inline help — the sub-command list shown when typing
e.g. `show route ?`) CANNOT be paged. That list is rendered by klish
itself inside the line editor, before any command executes — with no
ACTION involved — and klish 2.2.5 has no pager option or hook for it
(even `terminal length 0` does not change the `?` output). The paged
alternatives (read from the XML at runtime, so they always match the
command definitions; through the `less` pager when they exceed one
screen) are: `show route help` — the same sub-command list as
`show route ?`; `show help` — the same sub-command list as `show ?`
(36 entries); `help all` — the same list of all top-level commands as
`?` at the prompt (27 entries, including `!` for comments).
`show route help` also appears as the `help` option inside
`show route ?` itself, and `show help` appears as the `help` option
inside `show ?`. The builtin `help` command is NOT changed: it only
shows a 9-line summary (about `?` and hotkeys), not a command list,
and does not need a pager.

### Visible names + Tab auto-complete — checkpoint, filter, community, protocol, neighbor

Names of entities that already exist can be completed with Tab — no
need to type the full name from memory. Type a prefix, then press Tab:
if only one matches, the name is completed directly; if several match,
Tab shows the list of candidates. The list is read at runtime (dynamic,
not hardcoded), so it always matches the current state. If the typed
name is unknown, the command is rejected loudly (rc 33) naming the
available names — without changing anything.

```
rollback 2026-          # Tab -> rollback 2026-11-20 (completed when unique)
rollback                # Tab -> list/complete existing checkpoints
checkpoint delete       # Tab -> list/complete existing checkpoints
checkpoint list         # checkpoint list (name + date + * marker)
```

Entities completed by Tab (the same pattern for all):

- Checkpoint: `rollback <name>`, `checkpoint delete <name>` — list
  from the checkpoints dir (`.last-save` hidden).
- BGP filter: `import filter`, `export filter`, `filter` — already
  existed before (from the filter-name work); same pattern.
- Community list: `community list delete <name>` — list from the
  `define`s in `bird.d/filter.conf`. Community value: `community export
  delete <community>`, `community import delete <community>` — list
  from communities currently in use (export `bgp_community.add(...)`
  + import `bgp_*_community`), in CLI form (`64512:300`,
  `no-export`, `no-advertise`, `no-peer`, `blackhole`, `rt:AA:NN`,
  `large:AA:X:NN`).
- BGP protocol-name: `protocol-name <Name>` — list from protocol
  names already used in the `bgp.conf` intent (reuse convenience only;
  a new name can still be freely created).
- BGP neighbor: `neighbor <IP>`, `no neighbor <IP>` — list from
  neighbors present in the `bgp.conf` intent.
- Interface: already existed before (`Get_if_*`).

Deliberately NOT Tab-completed (a NEW name the user creates, where
completion is meaningless): `checkpoint save`, `community list add`
(name), `community export/import add` (value), new `filter` definitions.

Known limit: `?` only shows the static command structure (PARAM name
+ pattern), NOT the list of dynamic names. The dynamic list appears
only through Tab (and through list commands, e.g. `checkpoint list`).
This is a klish 2.2.5 limitation — `?` is rendered by the line editor
from static XML without running any completion command — the same as
`?` not being pageable above.

`show startup-config` reads the real startup-config file
(`/etc/titian/startup-config`); if the file does not exist yet, an empty
message is shown, not an error. `show running-config` reads the
running-config dump; if the dump does not exist yet, the file is created
first.

### 1.9 Date and time zone (show date)

```
show date                      # local date/time + time zone + UTC
```

`show date` output shows the local time (following the system time
zone), the zone name, and UTC time for comparison. The time zone is
set from configure mode:

```
configure terminal
system time-zone Asia/Jakarta  # WIB (UTC+7); other choices: Asia/Makassar (WITA), UTC
end
save
```

The time zone is stored as a `system time-zone ...` line in
startup-config (replayed at boot) and applied directly to
`/etc/localtime`. If the zone was never set, `show date` shows a
hint on how to set it (instead of guessing).

### 1.10 Package profiles — per-subscriber bandwidth limits (traffic-shape)

A *package profile* is a bandwidth-limit template for one service
package (e.g. 10M, 100M): *download* + *upload* speed and *burst*
per direction. One profile can serve many subscribers through
*bind*: to a whole interface/VLAN, or to one IP/CIDR on one
interface. Each *bind* automatically creates 2 derived *pipes* + 2
derived *rules* in dummynet (see §9e).

```
configure terminal
traffic-shape
enable
profile paket10
download 10Mbit/s
download-burst 1000000
upload 10Mbit/s
upload-burst 1000000
bind interface vlan100
end
configure terminal
commit
save
```

*Rate* format: integer + unit, e.g. `10Mbit/s`, `512Kbit/s`,
`1Gbit/s`. Profile name: max 12 characters, `[A-Za-z0-9_-]`,
first character a letter or digit.

Note: dummynet *burst* is NOT a sustained *burst-rate* like
MikroTik's. *Burst* is a BYTE allowance after *idle* — effectively
`MAX(burst, bw × idle_time)`. Example: 10M + `burst 1000000` = after
*idle*, up to 1,000,000 bytes (≈1 MB) pass at physical link speed,
then back to 10 Mbit/s. Do not sell *burst* as a sustained speed —
that is not its semantics.

Verification:

```
show traffic-shape profile paket10   # profile + bind + derived pipe/rule
show traffic-shape profile           # all profiles
show traffic-shape                   # traffic-shape configuration
show traffic-shape statistics        # dummynet state (ipfw) + MOVING counters: pf anchor + netstat per bound interface
```

Note: profile/*bind* changes are written to
`/usr/local/etc/traffic-shape.conf` immediately, but *pipes* only
enter the kernel on `commit` (the *traffic-shape* service restarts
when the config is dirty), at boot, or through an explicit *apply*
from the shell
(`/opt/titian/sbin/titian-traffic-shape.sh apply`). Without that,
`show` already displays the profile but the kernel limits nothing
yet. Full detail + *download*/*upload* direction per *bind* kind:
§9e.

Measured evidence (21 Nov 2026): profile `paket8` → 8.001 Mbit/s
(target 8); profile `paket14` → 14.004 Mbit/s (target 14). Measured
from the dummynet *pipe counter* with a *UDP flood* — not end-to-end
iperf3 (MikroTik does not run iperf3).

Notes: the 100M profile configuration on `vlan100` passes in the
*mock* only; a live 100 Mbit/s *throughput* test via `vlan100` has
NOT been measured yet (machine limitation, accepted 22 Nov 2026).

---

## 2. Configure mode — choosing what to configure

Enter first:

```
configure terminal
```

In configure mode, the following commands select an object or set a
global parameter. The `no <...>` command deletes the corresponding setting.

### 2.1 Choosing an interface

The command form differs per type and per OS. Valid interface names
follow the IFACE_SYS charset (max 15 characters, letters/digits/`_`/`-`/`.`);
interface existence is checked when the command runs — an interface
that does not exist on the system is rejected with a clear message.

```
# Ethernet (both OSes)
interface ethernet <iface>

# Loopback / dummy
interface loopback <name>

# VLAN — Linux: name is parent.VLAN-ID; FreeBSD: id + parent separate
interface vlan <parent>.<id>              # Linux, e.g.: interface vlan enp1s0.100
interface vlan <id> <parent>              # FreeBSD, e.g.: interface vlan 100 enp1s0

# VXLAN (both OSes)
interface vxlan <vxlanN>                  # e.g.: interface vxlan vxlan10

# Bonding / aggregation — Linux: bonding, FreeBSD: lagg
interface bonding <bondN>                 # Linux, e.g.: interface bonding bond0
interface lagg <laggN>                    # FreeBSD, e.g.: interface lagg lagg0
```

Deleting an interface object:

```
no interface ethernet <iface>     # (the no form follows the creating command)
no interface loopback <name>
no interface vlan <parent>.<id>   # Linux
no interface vlan <id>            # FreeBSD
no interface vxlan <vxlanN>
no interface bonding <bondN>      # Linux
no interface lagg <laggN>         # FreeBSD
```

Notes:

- Entering an interface view creates a persistent section in
  running-config. That section only disappears when startup-config is
  restored and the service is restarted, or the object is deleted with
  `no interface ...`.
- `no interface bonding` fails with `[slave lock]` if slaves are still
  attached — detach the slaves first (`no bond-group <bondN>` in the
  member interface view), then delete the bond.
- Bare `no bond-group` (without a bond name) = Incompleted command; the
  bond name must be written.
- VLAN creation on FreeBSD sometimes fails intermittently
  (`SIOCIFCREATE2`); if it happens, repeat the command — the create
  guard prevents corrupt configuration.
- `interface vlan` automatically brings up the parent + the VLAN itself
  (since 0.1.1); if the parent was DOWN, Titian prints a note.
  `disable` on a parent warns if active child VLANs go dark with it.
  `ip address` on an interface that is still DOWN prints a warning
  (without changing state — addressed pre-staging stays allowed).

### 2.2 Global route and gateway (configure mode)

```
ip default-gateway <ip>
no ip default-gateway
ip route <prefix> <next-hop-ip>
ip route <prefix> dev <iface>
no ip route <prefix>
ip route blackhole <ip>
no ip route blackhole <ip>

ipv6 default-gateway <ipv6>
no ipv6 default-gateway
ipv6 route <prefix> <next-hop-ipv6>
ipv6 route <prefix> dev <iface>
no ipv6 route <prefix>
ipv6 route blackhole <ipv6>
no ipv6 route blackhole <ipv6>
```

Examples:

```
ip route 198.51.100.0/24 192.0.2.1
ip route 203.0.113.0/24 dev enp1s0
ipv6 route 2001:db8:1::/48 2001:db8::1
```

### 2.3 System (configure mode)

```
system hostname <name>
system time-zone <zone>     # choices: WIB / WITA / UTC (and island aliases
                            # Java, Bali, Singapore, Malaysia — see ?)
system sysctl <key> <value>
                            # e.g.: system sysctl net.ipv4.ip_forward 1
                            # (Linux) / net.inet.ip.forwarding (FreeBSD)
                            # interval values use quotes:
                            # system sysctl net.ipv4.tcp_mem "4096 87380 16777216"
no system sysctl <key>
system domain-name <domain>
no system domain-name
system name-servers         # enter name-server view
```

In the name-server view:

```
nameserver <ip>
no nameserver <ip>
exit
```

The meaning of each sysctl key managed by Titian can be seen with
`show system sysctl` (exec mode).

### 2.4 SSH service (configure mode)

```
service ssh                 # enter SSH view
```

In the SSH view:

```
port <number>               # SSH service port
no port                     # reset SSH port to default (22)
allow-root                  # allow root login via SSH
no allow-root               # forbid root login via SSH
disable-host-validation     # do not validate remote hostname with DNS
no disable-host-validation  # validate remote hostname with DNS
exit
```

### 2.5 Firewall (configure mode)

```
firewall                    # enter firewall view (see §8)
no firewall                 # delete ALL firewall configuration (all rules)
```

---

## 3. Interface view — commands inside one interface

After `interface <type> <name>`, the prompt changes to
`...(config-if-<name>)#`. The following commands apply in all interface
view types, unless stated otherwise.

### 3.1 General interface view commands

```
ip address <CIDR-address> [peer <peer-ip>]
                            # IPv4 address; peer form = point-to-point link
                            # (PtP, /31 RFC 3021, local+peer free — see §3.2)
no ip address <CIDR-address> [peer <peer-ip>]
ipv6 address <CIDR-address> [peer <peer-ipv6>]
                            # FreeBSD (eth/vlan/lagg/loopback): no peer
no ipv6 address <CIDR-address> [peer <peer-ipv6>]
description <text>          # interface alias/description
mtu <68-9000>               # MTU, live + persistent (1500 default, 9000 jumbo)
no mtu                      # delete Titian MTU setting (back to pre-Titian value)
disable                     # shut down interface (admin down)
enable                      # bring up interface (admin up)
options                     # enter advanced tuning view (§3.4)
exit                        # back to configure mode
```

`ip address` takes effect live when executed; `save` (from exec) only
determines whether the setting survives a reboot.

`ip address` is additive: one interface may hold many IPv4 addresses at
once, with no limit — each command adds one address (alias) and never
replaces the existing ones. Remove them one by one with
`no ip address <CIDR-address>`; delete the interface itself with
`no interface <type> <name>`.

### 3.2 Point-to-point (PtP) addresses

Titian supports MikroTik/PPP-style PtP: local and peer addresses may be
arbitrary (they do not have to be in one subnet), e.g.:

```
interface ethernet enp1s0
ip address 192.0.2.10/31 peer 192.0.2.11
```

Special FreeBSD rule: PtP Ethernet broadcast does NOT use `dstaddr`
(ifconfig ignores it, ping loss 100%). The correct form on FreeBSD is
a `/32` local + host route to the peer via the interface — and that is
what Titian applies automatically; just use the same `peer` syntax,
per-OS behavior is handled behind the scenes.

### 3.3 Per-type special commands

```
# Ethernet Linux — in interface ethernet view:
qlen <method>               # transmit queue length (1000 for 1G, 10000 for 10G)
no qlen
speed <value> [duplex <full|half>]
                            # value in Mb/s: 10, 100, 1000, 2500, 5000, 10000,
                            # 25000, 40000, 50000, 100000 (Linux only, persistent)
no speed
bond-group <bondN>          # join this interface as slave of bondN
no bond-group <bondN>       # detach from bondN

# Bonding Linux — in interface bonding view:
mode <method>               # 802.3ad (LACP) or round-robin
hash-policy <layer>         # transmit hash policy (e.g. layer2/MAC)

# LAGG FreeBSD — in interface lagg view:
laggport <member>           # add member to lagg
no laggport <member>        # remove member from lagg
```

`speed` must be reported correctly by the driver for 802.3ad bonding on
top of virtual interfaces (virtio) — without it LACP does not negotiate
correctly.

### 3.4 Options view — advanced tuning (the `options` command)

From an interface view, `options` opens the tuning view. All settings here
are live + persistent (stored in netstate `.tuning` + *mirror*, re-applied
at boot via apply-all). `no <setting>` deletes the Titian setting and
restores the pre-Titian value.

Linux (complete):

```
tso <on|off>                # TCP segmentation offload
no tso
gro <on|off>                # generic receive offload
no gro
lro <on|off>                # large receive offload (hardware; default off)
no lro
gso <on|off>                # generic segmentation offload
no gso
rx <on|off>                 # RX checksumming
no rx
tx <on|off>                 # TX checksumming
no tx
sg <on|off>                 # scatter-gather (prerequisite for TSO/GSO)
no sg
rx-usecs <0-1000>           # receive interrupt delay, microseconds
                            # (large value = rarer interrupts, higher latency)
no rx-usecs
adaptive-rx <on|off>        # driver adjusts rx-usecs automatically with load
no adaptive-rx
smp_affinity <mask>         # CPU affinity mask (e.g.: 4, 0-3, 12-19)
smp_affinity_XPS <mask>     # XPS affinity enable
```

FreeBSD (subset, via ifconfig):

```
tso <on|off>                # ifconfig tso/-tso
no tso
lro <on|off>                # ifconfig lro/-lro
no lro
rx <on|off>                 # ifconfig rxcsum/-rxcsum
no rx
tx <on|off>                 # ifconfig txcsum/-txcsum
no tx
```

Checking tuning results:

```
show interfaces tuning <iface>   # exec mode
```

Read-only helper tool (outside the CLI, on the host): `titian-tune-recommend`
gives tuning recommendations without changing anything. Notes: live
coalesce success (rx-usecs) is not yet proven on the lab NIC; "dso" is
interpreted as the TSO/GSO family.

---

## 4. VXLAN view — L2 overlay over UDP/IP

```
interface vxlan <vxlanN>
```

In the VXLAN view (both OSes, unless stated otherwise):

```
vni <1-16777215>            # VXLAN Network Identifier
no vni                      # back to placeholder (Linux: id 1;
                            # FreeBSD: without vxlanid)
local <ipv4>                # local VTEP address (underlay, must be reachable by the peer)
no local
remote <ipv4>               # peer VTEP address (unicast); deletes group+dev if present
no remote
group <multicast> dev <iface>
                            # multicast variant + underlay device;
                            # deletes remote if present
no group                    # delete multicast group + dev
dstport <1-65535>           # VXLAN UDP dstport
no dstport                  # back to 4789
ip address <CIDR> [peer <ip-peer>]
no ip address <CIDR>
ipv6 address <CIDR> [peer <ipv6-peer>]   # Linux; FreeBSD without peer
no ipv6 address <CIDR>
description <text>
no description
mtu <value>                 # overlay MTU; useful limit 1450 for VXLAN
                            # overhead ~50 bytes (proven by DF test)
no mtu
disable / enable
options                     # [Linux] advanced tuning (§3.4)
exit
```

Important rules:

- **Unicast vs multicast are mutually exclusive.** Setting `remote` deletes
  `group`+`dev`, and vice versa. Pick one.
- **Changing the VNI = recreating the interface** (brief flap; MAC stable). Do not
  be surprised if the interface flickers when the VNI is changed.
- **dstport:** Linux REQUIRES 4789 (IANA); do not leave the historical Linux
  default 8472. FreeBSD stays at 4789 — other values are rejected.
- **Overlay MTU:** 1450 is the useful limit for VXLAN overhead; a smaller
  underlay MTU will fragment packets.
- VXLAN status: `show interfaces vxlan [iface]` (exec mode) shows
  status + VNI + local/remote + FDB.
- Test status: unicast guest-to-guest proven on both OSes; multicast
  end-to-end NOT proven (FreeBSD does not join the group) — do not rely on
  multicast before testing it in your environment.

Unicast pair example (two sides, same VNI, local/remote crossed):

```
# Side A
interface vxlan vxlan10
vni 10
local 192.0.2.10
remote 192.0.2.11
ip address 198.51.100.1/24
exit

# Side B
interface vxlan vxlan10
vni 10
local 192.0.2.11
remote 192.0.2.10
ip address 198.51.100.2/24
exit
```

### Multi-VXLAN (10 segments, proven 17 Nov 2026)

The pattern above scales to 10 VXLANs at once: `vxlan101`–`vxlan110`
(VNI 101–110) + `vlan101`–`vlan110` (VID 101–110, parent `ge3`) +
`bridge101`–`bridge110` (members `vxlan10x` + `vlan10x`, IP
`10.99.101.1`–`10.99.110.1/24`), local VTEP `10.10.2.3` ↔ remote
`192.168.91.32` (RB3011, same VNI, IP `10.99.101.2`–`10.99.110.2/24`
directly on the vxlan interface — no bridge on the RB3011 side, and a
static ARP `10.99.10x.1` → `bridge10x` MAC). Overlay ping 10/10 both
directions 0% loss; `tcpdump -i vxlan10x` proves traffic uses its own
segment (bridge10x FDB learns the RB3011 vxlan MAC). Note: RB3011
redistributes connected via BGP, so `10.99.101–110.0/24` also appear in
the BIRD table via `10.99.40.2` — but the kernel FIB uses the connected
routes (`bridge10x`), so they do not shadow. Never use `import all`
towards a peer that redistributes connected: an imported underlay
prefix (e.g. `192.168.91.0/24`, the VTEP network) creates a VXLAN loop
(happened during the 10-peer BGP build, 17 Nov 2026) — use
`import filter F-RB3011-IN`.

---

## 5. Bonding (Linux) and LAGG (FreeBSD)

### 5.1 Linux bonding

```
configure terminal
interface bonding bond0
mode 802.3ad
hash-policy layer2
ip address 198.51.100.1/24
exit
interface ethernet enp1s0
speed 1000 duplex full
bond-group bond0
exit
interface ethernet enp2s0
speed 1000 duplex full
bond-group bond0
exit
end
save
```

Correct order: create the bond first, set the mode, then attach slaves.
`speed` on slaves is required for LACP on virtual NICs. Detaching a
slave: `no bond-group bond0` in the member interface view. Deleting a
bond that still has slaves fails (`[slave lock]`) — detach all slaves
first. Status: `show interfaces bonding bond0 detail`.

### 5.2 FreeBSD lagg

```
configure terminal
interface lagg lagg0
laggport vtnet1
laggport vtnet2
ip address 198.51.100.1/24
exit
end
save
```

The member command on FreeBSD is `laggport <member>` / `no laggport
<member>` in the lagg interface view (not in the member view). Status:
`show interfaces lagg lagg0 detail`.

---

## 6. Routing — verification

Routes and gateways are set in configure mode (§2.2). Verify from exec:

```
show ip route                 # full IPv4 table
show ip route 198.51.100.0/24 # filter one prefix
show ipv6 route
show ip neighbor              # ARP/neighbor
```

Static routes created via the CLI are generated into BIRD (static
section) and can be redistributed to BGP from the BIRD view (§7.4).

---

## 7. BIRD view — dynamic routing

Enter from exec:

```
bird
bird terminal
```

The BIRD view manages the BIRD2 daemon: showing status, rendering and
applying configuration sections, managing BGP communities and
redistribution. Protocol definitions (BGP/OSPF/BFD/direct/pipe) live as
sections in `bird.d/` (example templates available in the repo) and are
applied with `generate` — this view does not create neighbors from
scratch, it manages sections, communities, and redistribution on top of
them.

### 7.1 Show BIRD

```
show configuration [function|filter|protocol|static|bgp|ospf]
                            # check configuration per section
show route                  # BIRD routes
show route ip <ip-or-prefix>
show route all              # count routes
show route count            # count routes
show route protocol [bgp|ospf] [prefix]
show route export <protocol>
show protocol               # protocol list
show protocol summary       # protocol summary
show protocol all           # detail of all protocols
show protocol neighbors <protocol>
```

### 7.2 Generate — render, check, apply

```
generate check <section>    # render + syntax-check one section WITHOUT applying
generate <section>          # render + syntax-check + backup + apply one section
```

Sections: `function`, `filter`, `protocol`, `static`, `bgp`, `ospf`,
`direct`, `bfd`, `pipe`. Correct flow: `generate check` first, if clean
then `generate`. `generate` cannot reproduce the bird.conf
*anchor* from scratch — to return to the initial state, restore a copy of
the bird.conf file + `birdc configure` (or rollback a checkpoint, §9).

### 7.3 BGP community

```
community list add <name> <value>     # define a named community list
community list delete <name>
community list show                   # list defined lists
community export add <value>          # set community on BGP export
community export delete <value>
community export show                 # BGP export filter
community import add <value> <action> # match community on import + action
                                      # (action: reject, localpref:N, med:N)
community import delete <value>
community import show                 # BGP import filter
```

Community values cover standard, well-known, extended, and large.
Examples:

```
community list add pelanggan 64512:100
community export add 64512:100
community import add 64512:100 localpref:200
community import show
```

### 7.4 Redistribution to BGP

```
redistribute static enable    # export static routes to BGP
redistribute static disable
redistribute direct enable    # export connected routes to BGP
redistribute direct disable
redistribute show             # redistribution status
```

### 7.5 Protocol control

```
reload <protocol>             # reload one protocol
reload in <protocol>          # reload inbound routes of a protocol
reload out <protocol>         # reload outbound routes of a protocol
restart <protocol>            # restart one protocol
restart all                   # restart all protocols
disable <protocol>            # disable a protocol
enable <protocol>             # enable a protocol
exit                          # exit the BIRD view
```

Special note on FreeBSD BGP: a BGP session over a PtP `/32` address that
is not directly-connected in the BIRD device protocol needs `multihop` +
a static peer route to become Established — that is BIRD behavior, not a
Titian bug. BFD-over-BGP single-hop over the management interface has
not been tested yet; BFD-over-BGP over the data path is PROVEN to fail
(the RB3011 never creates a BFD session — BGP↔BFD deadlock, F3.4).
BFD-over-OSPF was VERIFIED live on 17 Nov 2026 (B26): session Up in both
directions (300 ms × 3, hold 900 ms); the RB3011 side needs `use-bfd=yes`
on the OSPF interface-template (default empty = BFD stays silent).
Multihop BGP has been verified in the lab.

---

## 8. Firewall view — filter, SNAT, DNAT (IPv4 only)

Enter from configure:

```
firewall
```

Note: `show firewall` exists only in exec mode (showing the rule list in
priority order + live backend dump + forwarding status). Inside the
firewall view, `show firewall` = Unknown command — `exit` first.

Staging proof (23 Nov 2026): `titian-fw.sh apply` is mock-verified
(`FW-APPLY-MOCK.sh` 16/0 — correct pf anchors, parse-check before load,
missing-iface rules skipped, enable-no flush). Live test is still PENDING
(§14 row 12) — it needs a live wave on a non-mgmt interface (see §8.6–§8.7).

### 8.1 Basic semantics

- **Forward default DENY; input/output default ACCEPT.** Transit traffic
  not permitted by a forward filter will be dropped.
- **A rule is identified by its CONTENT, not by an ID.** Deleting a rule
  uses the same full syntax as the creating command.
- **DNAT and filter interact pre/post-NAT:** the filter evaluates the
  source before NAT and the destination after NAT. DNAT needs a forward
  filter permit to the translated destination address.
- Backend: nftables (table `inet titian`) on Linux, pf anchor on
  FreeBSD. Every load is checked first (`nft -c` / `pfctl -n`).
- Persistence: rules are stored in firewall netstate and replayed at
  boot (`titian-fw.sh apply-all`); checkpoints copy the netstate too.

### 8.2 Filter

```
filter <forward|input|output> <permit|deny> proto <tcp|udp|icmp|all>
       src <CIDR|any> dst <CIDR|any>
       sport <port|any> dport <port|any>
       in <iface|any> out <iface|any>
```

All fields are required; for `icmp`/`all`, ports are not used (fill in
`any`). Deleting: `no filter ...` with the same full syntax.

Example — allow transit HTTP from the LAN to the internet, drop the rest
(forward default is already DENY, so only permit what is allowed):

```
filter forward permit proto tcp src 198.51.100.0/24 dst any sport any dport 80 in enp1s0 out any
filter forward permit proto tcp src 198.51.100.0/24 dst any sport any dport 443 in enp1s0 out any
```

### 8.3 SNAT

```
snat <srcnet> to <address|masquerade> out <iface|any>
no snat <srcnet> to <address|masquerade> out <iface|any>
```

Examples:

```
snat 198.51.100.0/24 to masquerade out enp1s0
snat 198.51.100.0/24 to 203.0.113.10 out enp1s0
```

### 8.4 DNAT / port forwarding

```
dnat <tcp|udp> in <iface> dport <public-port> to <address> port <destination-port|same>
no dnat <tcp|udp> in <iface> dport <public-port> to <address> port <destination-port|same>
```

`in` is required — DNAT is always bound to an entry interface. Example
(complete with a forward filter to the translated destination):

```
dnat tcp in enp1s0 dport 8080 to 198.51.100.5 port 80
filter forward permit proto tcp src any dst 198.51.100.5 sport any dport 80 in enp1s0 out any
```

### 8.5 Delete all and FreeBSD (pf) limitations

```
no firewall     # from configure mode: delete ALL firewall configuration
```

pf limitations that are rejected outright (not silently changed):

- filter with `out` = interface (not `any`) → rejected;
- filter with `in` = `any` → rejected (iface required);
- snat without an `out` interface → rejected;
- forward default-deny on FreeBSD only applies to interfaces named
  by a filter-forward/dnat.

No IPv6, no redirect, no shaping/scrub in this version.

### 8.6 ipfw — allow SSH + ping REQUIRED before touching the firewall

Traffic-shape uses **ipfw + dummynet**. ipfw has a default rule 65535:

```
65535 deny ip from any to any
```

When ipfw is active without allow rules, **all traffic is denied** — including SSH
and ping (ge0 got an IP via `dhclient` but ping RTO, 13 Nov 2026). So,
install the SSH + ping allow rules **before** enabling ipfw or
touching the firewall:

```sh
ipfw add 100 allow tcp from any to any 22
ipfw add 110 allow tcp from any 22 to any
ipfw add 120 allow icmp from any to any
```

| Rule | Function |
|---|---|
| 100 | SSH in (TCP destination port 22) |
| 110 | SSH out / reply (TCP source port 22) |
| 120 | Ping / ICMP (both directions) |

Verify: `ipfw show` (all three rules present) + `sysctl net.inet.ip.fw.enable`
(1 = active, 0 = inactive). Emergency if locked out:

```sh
ipfw add 65535 allow ip from any to any   # change default deny → allow
service ipfw stop                          # or stop ipfw entirely
```

Note: ipfw rules are **not persistent** (lost on reboot) — re-install at
boot if needed. These rules only protect SSH + ping; when ipfw is active
with default deny, other traffic (BGP TCP 179, VXLAN UDP 4789, DNS, etc.)
is still denied unless it has an allow rule. The Titian firewall feature
(§8.1–8.5) uses **pf**, not ipfw — ipfw here is only an access safeguard.

### 8.7 protect-interface — anti-lockout guard + migration

`protect-interface` protects the management interface from firewall rules
(a rule may not use that interface as in/out). Default: **`ge0`** (mgmt since
the 12 Nov rename).

**Live config migration is NOT automatic.** After deploying the new script
(default ge0), the old config in `/usr/local/etc/firewall.conf` still says
`protected em0`. Migrate in this order:

```
protect-interface ge0       # add FIRST
no protect-interface em0    # then delete (deleting needs at least 2 entries)
commit
save
```

With ge0 protected, a filter on ge0 will be **rejected** at add time — that is
the guard working. Firewall tests on ge0 must use a non-management
interface, or deliberately unprotect ge0 first at your own risk.

**Incident 13 Nov 2026 (PROVEN):** a firewall commit (`filter input
deny dport 18081 + enable`) hung, then SSH died completely from ~17:55
WIB — **pf lockout** (6-hour machine uptime proves it was not a crash).
Access recovered 22:54 after `pfctl -d` at the console. **Cleaned up
14 Nov 00:04:** deny rule 18081 deleted, `enable` turned off, protected
`em0` → `ge0` (via klish + commit + save; verified `show firewall` = no rules,
protected ge0, pf not running). Do not repeat a firewall commit before the
ge0 guard is in place + the filter is tested on a non-management interface.

---

## 9. Checkpoint, rollback, and rename (exec mode)

### 9.1 Checkpoint — named save point

```
checkpoint save <name>     # save the current running-config as a named
                           # point (frozen; a normal save does not change it)
checkpoint list            # list points (name + WIB time;
                           # * = same as current running-config)
show checkpoints           # same as checkpoint list
checkpoint delete <name>   # delete one point
```

Point names: `[A-Za-z0-9_-]+`. A snapshot contains running-config +
startup-header + bird.conf + bird.d + intent + netstate + sysctl +
meta, in `/opt/titian/etc/checkpoints/<name>/`.

`factory-reset confirm` automatically creates a pre-reset point named
with the WIB date (`YYYY-MM-DD`, e.g. `2026-11-19`) before deleting
config — this point is PRESERVED during the wipe (other points are
deleted) and can be loaded back with `rollback <date>` (see §9.4).

### 9.2 Rollback

```
rollback <name>   # return to a named checkpoint point
rollback          # without a name = return to startup-config
                  # (discarding unsaved running changes)
```

Rollback is PERSISTENT and restarts the service. Safe order before a
risky change: `checkpoint save pre-change`, make the change, if it fails
`rollback pre-change`, if it succeeds `save`.

**Byte-identical (fix, 23 Nov 2026):** points created after this fix
store the startup-config stamp block in `startup-header`, so rollback
restores startup-config **byte-identical** (empty diff vs pre-test) in
**both** locations (`/etc/titian` and `/cfg/titian`). Staging proof:
`CHECKPOINT-HEADER-MOCK.sh` 14/0. **Old** points (created before
23 Nov 2026, no `startup-header`) keep the old behavior: the rolled-back
startup-config loses the 3 stamp header lines (`! version`,
` ! last commit`, `!`) + `/cfg` is not restored — run `save` after
rolling back to an old point to re-sync `/cfg`. Live verification
(save → change → rollback → empty diff) waits for the live wave after
the Part 6 recording.

### 9.3 Rename interface (persistent)

```
rename <old-name> <new-name>
```

**This command is in exec mode (enable-view), NOT in `configure terminal`.**
Run it from the `cli-...#` prompt, not from `(config)#`.

Example (Linux):

```
show interfaces terse
rename enp1s0 wan0
```

Example (FreeBSD, Junos style — ge for 1G, xe for 10G):

```
show interfaces terse
rename igb1 ge1
rename ixl3 xe3
```

Rename migrates netstate + startup-config + *mirror* + references
(laggport, FreeBSD VLAN parent) and persists across reboots: Linux
uses systemd `.link` (MACAddress), FreeBSD uses the
`#-TITIAN-RENAME-#` block in rc.conf. This command restarts the service
and has a pre-restart fail-rollback.

**Warning:** rename restarts the titian service, and a service restart
empties running-config. After renaming, run
`show running-config` — if it is empty or sections are missing (e.g. the
newly renamed interface or a VLAN whose parent was renamed), rebuild those
sections via the CLI, then `commit` + `save`. (Real example: renaming
`ixl3`→`xe3` made `interface ethernet xe3` + `interface vlan 99 ge3`
disappear from running-config; both had to be recreated manually.)

Limitations:

- The new name uses the IFACE_SYS charset (max 15 characters), must not
  already be used by the system, and must not be a Titian object name
  (bond/vxlan/lagg/vlan/loopback — those objects CANNOT be renamed;
  delete and recreate them).
- Loud validation: if there are unsaved running changes touching that
  interface, the command asks you to save first (live-only heuristic) —
  run `save`, then repeat `rename`.
- Rename does NOT change interface names inside raw bird.conf; what is
  migrated is Titian state and its references.

### 9.4 Factory reset — start from scratch

```
factory-reset          # ONLY shows a summary + confirmation (deletes nothing)
factory-reset confirm  # EXECUTE: automatic backup, delete all configuration, restore defaults, restart service
```

**This command is in exec mode (enable-view), NOT in `configure terminal`.**
Run it from the `cli-...#` prompt, not from `(config)#`.

`factory-reset` deletes ALL Titian configuration and restores factory
defaults (empty). This command is IRREVERSIBLE and uses two steps
(following the birdc `down` / `graceful-restart` pattern): the first step
ONLY shows a summary — without `factory-reset confirm`, NOTHING is deleted.

The `factory-reset` summary is shown through the `less` pager (like
`show`) when output goes to an interactive terminal — `SPACE` = next
page, `q` = quit (see §1.8). When output is piped/scripted (not a TTY)
or `terminal length 0`, the summary is dumped directly without paging.
`factory-reset confirm` is deliberately NOT paged so its progress
(backup, delete, restart) stays visible live.

`factory-reset confirm` also destroys Titian-created live interfaces
(Finding 3): vlan, vxlan, bridge, lagg, cloned loopbacks lo1.., and
IPs on non-management physical interfaces — after birdc configure
(BIRD routes already withdrawn) and before the service restart. What
is preserved: the management interface (from the default route,
fallback ge0) + lo0 + the default route, so SSH stays up. NOT touched
by confirm (separate follow-up): live pf rules (inert once the
interfaces are gone), live sysctl values, the mpd5 daemon, and kernel
routes added manually outside BIRD.

Before deleting anything, `confirm` creates a **pre-reset checkpoint**
(Finding 4): a point named with the WIB date (`YYYY-MM-DD`, e.g.
`2026-11-19`) holding the pre-reset config, which is **PRESERVED**
during the wipe (other checkpoints are deleted). Load it back with
`rollback <date>` (see §9.1–§9.2); list points with `checkpoint
list`. If the date name already exists, `YYYY-MM-DD-HHMM` is used
(then `YYYY-MM-DD-HHMMSS`). If checkpoint creation fails, confirm
still proceeds (loud warning) — the automatic tarball backup remains
the primary safety net.

What is deleted (if present): `startup-config`, intent `*.conf`,
`netstate/`, `bird.d/`, `bird-backup/`, `checkpoints/` (including
`.last-save`; EXCEPT the pre-reset point just created — see below),
`bird.conf` (live + `/etc/local` + `/cfg/local` — restored from `*.sample`
if present, deleted if no sample exists), live `frr.conf` (same), and the
`#-TITIAN-#` / `#-TITIAN-L2-#` / `#-TITIAN-RENAME-#` blocks in
`/etc/rc.conf` + `/cfg/rc.conf` (other rc.conf content is untouched).

What is NEVER deleted: Titian binaries + XML (`/opt/titian`),
the `/cfg` + `/etc` directory structures, `firewall.conf`, `rc.local`
(+newsyslog hook), `sshd_config`, the root password, other disks/partitions.
The klish `write-memory` command stays deleted (decision of 18 Nov 2026)
and is NOT revived by this feature.

Before deleting, `factory-reset confirm` makes an automatic backup
(a tarball in `/cfg`, `titian-factory-reset-bak-<WIB>.tgz`) — a failed
backup aborts the reset, nothing is deleted. After deleting, the command
restores defaults, stops FRR, runs `birdc configure`, then restarts the
titian service (replaying the now-empty `startup-config` → clean
running-config). Verify afterwards: `show startup-config` (must be empty)
+ `show bird` + `bird.conf` equal to the sample.

Restoring from a backup (via the shell, not klish — there is no klish
`restore` command yet): run the script directly, then restart the
service:

```sh
sh /opt/titian/sbin/titian-factory-reset.sh restore <backup.tgz>
service titian restart
```

The tarball can come from the automatic backup
(`/cfg/titian-factory-reset-bak-<WIB>.tgz`) or any pre-test backup.
Restore works in two phases: extract all entries except
`usr/local/etc/*` directly, then copy the `usr/local/etc/*` entries
file by file following the `/usr/local/etc -> /etc/local` symlink (so
live `frr.conf` comes back with mode 600 + owner `frr:frr`, and live
`bird.conf` stays one inode with `/etc/local/bird.conf`). Final
verification: every file entry in the backup MUST exist at its
destination — if any is missing, restore FAILS LOUDLY (rc 33 + the
list of missing entries; a symlink whose target dangles still counts
as restored if the symlink itself comes back). After restoring,
verify the anchor (startup-config, bird.conf, BGP). A restore that
needs ANY manual step afterwards = FAILED.

**Warning — /cfg label collision:** if `/cfg` is mounted from a DIFFERENT
disk than root (two disks have a partition labelled `cfg`), the reset
deletes the OTHER disk's configuration. The `factory-reset` step shows a
loud warning when the `/cfg` device and the root device are on different
disks — read that warning before typing `confirm`. For a truly clean UFD
test: disable/unplug the internal disk temporarily (or relabel the
internal `cfg`), then boot the UFD.

### 9.5 Titian update — check + install releases from GitHub

```
update check           # READ-ONLY: latest release vs installed version
update install         # ONLY shows the new version + summary (no download/install)
update install confirm # EXECUTE: download -> verify sha256 -> pkg add -f -> restart -> verify
```

**This command is in exec mode (enable-view), NOT in `configure terminal`.**
Run it from the `cli-...#` prompt, not from `(config)#`.

`update check` reads the latest release of the `ashadebi/titian` repo
on GitHub Releases (public API, no auth) and compares it with the
installed version (`pkg info titian`). Report: UPDATE AVAILABLE /
ALREADY UP TO DATE / UNREACHABLE. This command is read-only — it
changes nothing.

`update install` only shows the plan (new version, asset size,
checksum source, execution flow). `update install confirm` executes
it: downloads `titian-bsdrp-<version>.pkg` to a temp directory,
verifies its sha256, installs it with `pkg add -f`, restarts the
titian service, then verifies the config. Without confirmation,
NOTHING changes.

Update safety rules:

- The .pkg file's sha256 MUST match the checksum published by the
  release (release body or the `.pkg.sha256` asset). If it is not
  published or does not match → LOUD FAILURE, do not install, the old
  version stays intact.
- Install refuses when already up to date, when titian is not
  installed via pkg, when the release tag does not match
  `titian-bsdrp-<version>`, or when free space in the temp directory
  is insufficient (checked with `df` first; remember /var is a 32M
  tmpfs, the .pkg is ~2.6MB).
- Temp files are deleted when done (success or failure).
- After the restart, binding verification: startup-config vs /cfg,
  bird.conf md5 (must be UNCHANGED from before the update — the
  package owns no config), BGP Established count (must return to the
  pre-update count). A failure at any step → loud failure.
- Configuration in /cfg is NEVER touched. There is NO cron
  auto-apply — check + install run only on command.

Release-process requirements (so `update` can work — see
UPDATE-LIVE-PLAN.md): every release MUST bump PORTVERSION, the tag
must match `titian-bsdrp-<version>`, the asset must be named
`titian-bsdrp-<version>.pkg`, and the sha256 must be published in the
release body or as a `.pkg.sha256` asset.

---

## 9a. IPoE — DHCP client & server

**Important note:** mpd5 does NOT support IPoE. mpd5 is a PPP daemon
(PPPoE/PPTP/L2TP). IPoE is plain IP over Ethernet, i.e. DHCP —
no PPP session, no username/password. Titian implements IPoE
via DHCP: `dhclient` (client) and `isc-dhcpd` (server), both already
present in the image.

Detailed BRAS service documentation (PPPoE + IPoE + RADIUS as one
subscriber access service — architecture, flows, live test evidence,
operations): see **§9d**.

### 9a.1 IPoE client — WAN via DHCP

```
configure terminal
interface ethernet ge1
ip address dhcp
commit
save
```

The interface gets an IP + gateway + DNS from the DHCP server at the other
end. To stop:

```
configure terminal
interface ethernet ge1
no ip address dhcp
commit
```

### 9a.2 IPoE server — DHCP for subscribers

```
configure terminal
ipoe-server
interface bridge0
pool 10.99.40.0/24 10.99.40.100 10.99.40.200 10.99.40.1 8.8.8.8
enable
end
configure terminal
commit
save
```

Pool format: `pool <subnet>/<prefix> <start> <end> <gateway> <dns>
[lease-seconds]`. Default lease 86400 seconds (1 day). `commit` generates
`/usr/local/etc/dhcpd.conf` and runs `dhcpd` on the chosen interface.
Requirement: the interface must have an IP in the same subnet as the pool
(e.g. pool 10.99.40.0/24 needs an interface with a 10.99.40.x IP) — otherwise
`dhcpd` refuses to start.

Delete the entire IPoE server configuration:

```
configure terminal
no ipoe-server
commit
```

### 9a.3 IPoE server + RADIUS MAC-auth

IPoE has no username/password, so auth is MAC-based (MAB — MAC
Authentication Bypass). isc-dhcpd has NO native RADIUS support, and
the `on commit` + `execute()` hook CANNOT veto a lease (the lease is
already committed when the hook runs). The mechanism used (native
isc-dhcpd): class `radius-allowed` + one subclass per RADIUS-approved
MAC + pool `allow members of "radius-allowed";` + `deny
unknown-clients;`. RADIUS is the authority: at `commit`, every MAC
declared in klish is verified against RADIUS (PAP, User-Name = MAC,
User-Password = MAC); only Accepted MACs enter the allowlist. A MAC
that RADIUS rejects / cannot verify (RADIUS unreachable) is EXCLUDED +
a warning (fail-closed). If MAC-auth is on but ZERO MACs pass, generate
FAILS loudly (rc 33) and the old config is kept.

```
configure terminal
ipoe-server
radius-server 103.50.129.84
radius-secret <secret>
radius-mac 02:00:00:00:00:01
radius-mac-auth
enable
end
configure terminal
commit
save
```

Turn off RADIUS MAC-auth (back to open DHCP):

```
configure terminal
ipoe-server
no radius-mac-auth
no radius-server
no radius-secret
no radius-mac 02:00:00:00:00:01
end
configure terminal
commit
save
```

Notes:
- `radius-server` / `radius-secret` follow the PPPoE pattern (see
  §9d.2). The secret is stored in `/etc/titian/ipoe.conf`
  (mode 600) AND is also saved to startup-config via `<CONFIG/>` +
  `save` (correction 19 Nov 2026 — see §9d.4). The klish
  `radius-secret` command line IS echoed by klish — never show its
  value in logs/reports.
- Real-time per-request auth (a RADIUS check on every DHCPDISCOVER)
  is NOT possible with isc-dhcpd. The correct architecture for that is
  FreeRADIUS `rlm_dhcp` (FreeRADIUS as the DHCP server) — needs a new
  package + an architecture decision (FreeRADIUS cannot be installed on
  the test machine, pkg repo 404).
- RADIUS verification happens at generate/commit time, not per request.
  A MAC removed from RADIUS after a commit keeps getting a lease until
  the next commit (allowlist regeneration).
- The end-to-end DHCP client test (DORA) is NOT proven live
  (same-machine broadcast does not reach dhcpd — a platform
  limitation, not RADIUS). Detail + evidence: §9d.3.

---

## 9b. BGP — neighbor, filter, attributes (BIRD)

BGP is configured through the `router bird` view (configure-view). Intent
is stored in `/etc/titian/bgp.conf` (persisted to `/cfg/titian/`
by `save`), generated into the BIRD section
`/etc/titian/bird.d/bgp.conf`, then applied to `bird.conf` via the
`#-BGP-#` … `#-ENDBGP-#` marker by `titian-bird.sh generate bgp`
at `commit`. BIRD does **not** need a restart — `birdc configure`
is enough (commit already calls it).

### 9b.1 Basic flow — one eBGP neighbor

```
configure terminal
router bird
router-id 10.99.40.1
local-as 65000
neighbor 10.99.40.2
remote-as 65001
description RB3011-TEST
local-pref 100
med 50
prepend 2
community 65000:100
exit
network 10.99.40.0/24
end
configure terminal
commit
save
```

Commands inside the `neighbor` view (prompt
`(config-bird-neighbor-<IP>)#`):

| Command | Meaning |
|---|---|
| `remote-as <AS>` | Neighbor AS (required — a new neighbor is created here, import/export default `all`) |
| `description <text>` | Description (one word; shown in bird.conf) |
| `import all` / `import none` | Accept all / no routes |
| `import filter <NAME>` | Accept only routes passing filter NAME |
| `export all` / `export none` | Send all / no routes |
| `export filter <NAME>` | Send only routes passing filter NAME |
| `local-pref <N>` | Default local-preference for routes from this neighbor |
| `med <N>` | MED sent to this neighbor |
| `prepend <N>` | Number of AS-path prepends on export (calls `bgp_path.prepend()` N times) |
| `community <AS:NN>` | Community added on export |
| `protocol-name <NAME>` | Custom BIRD protocol name (default `bgp_<IP>`; example `protocol-name bgp_AS1194`) |

Filter names in `import filter` / `export filter` are completed
automatically with TAB (source: filters already created; type `import
filter <TAB>` to list them). Referring to a filter that does not exist
fails with a clear message when the command runs — create the filter
first. `protocol-name` must be a BIRD identifier
(`[A-Za-z_][A-Za-z0-9_]*`, not starting with a digit) and must not
collide with another protocol name (another neighbor — including their
default `bgp_<IP>` names, a template, or another protocol);
`no protocol-name` returns to the default `bgp_<IP>`.

### 9b.2 Filter

```
configure terminal
router bird
filter F-RB3011-IN
accept 10.0.0.0/8
reject 192.168.0.0/16
exit
neighbor 10.99.40.2
import filter F-RB3011-IN
exit
end
configure terminal
commit
```

Commands inside the `filter` view (prompt
`(config-bird-filter-<NAME>)#`):

| Command | Meaning |
|---|---|
| `accept <prefix>` | Accept this prefix — a `{low,high}` pattern is allowed, e.g. `accept 103.50.128.0/22{22,24}` |
| `reject <prefix>` | Reject this prefix — a `{low,high}` pattern is allowed |
| `accept community <AS:NN>` | Accept routes with this community |
| `reject community <AS:NN>` | Reject routes with this community |

A filter always ends with `reject;` (default-deny). A filter name may
contain `-` in the CLI, but it is generated as `_` in bird.conf
(BIRD rejects `-` in identifier names).

A `{low,high}` pattern limits the prefix lengths that match (e.g.
`103.50.128.0/22{22,24}` = /22 to /24 prefixes inside
103.50.128.0/22). The `+` suffix (this prefix and more specific ones)
and `-` (only this prefix) are also supported. `accept prefix-pattern
<pattern>` is an older alias for the same form. Filter names in this
view are also completed automatically with TAB (`filter <TAB>`).

### 9b.3 Advertised networks

```
router bird
network 10.99.40.0/24
```

The prefix must exist in the routing table (connected / kernel / static)
and pass the export filter. With `export all`, all routes in the table
are advertised; with `export filter`, make sure the filter accepts that
prefix.

### 9b.4 Verification

```
show bgp                    # bgp.conf intent + bird.d/bgp.conf section
show protocol               # BIRD protocol status (birdc)
show protocol bgp           # BGP session detail
birdc show route protocol bgp_10_99_40_2
```

BGP session status in `show protocol`: `Active` = BIRD is trying to
connect to the peer (not yet Established — peer not configured / not
listening on port 179). `Established` = session running, routes exchanged.
`Socket: Connection refused` = peer reachable but nothing is listening on
port 179 (BGP not configured on the peer side).

**RPKI `lab` after reboot (fix 20 Nov 2026):** BIRD comes up before
the default route exists (dhclient runs later in rc.local), so the
RPKI protocol `lab` (remote 10.1.1.62:3323) used to stick at
`Connecting` (18 Nov: 11 Established, lab Connecting 10+ min). Now
`titian-boot.sh` launches a background waiter at boot: it waits for
the default route to appear (max ~120 s), then runs `birdc restart
lab` if `lab` is not yet `Established` (log:
`/var/log/titian-rpki-boot.log`). Proven in the 20 Nov 2026 reboot
test: the waiter restarted `lab`, `lab` Established (~1 min after
boot), BGP stayed at 12 Established.

### 9b.5 Gotchas (found during live testing, 13 Nov 2026)

- **import/export MUST be inside an `ipv4 { }` channel.** BIRD 2.20.0
  rejects `import all;` directly inside `protocol bgp`
  (`syntax error, unexpected IMPORT`). The generator always writes
  an `ipv4 { }` channel.
- **`router id` is a GLOBAL setting**, not per-protocol.
  The generator writes it to bird.conf outside the BGP section.
- **`bgp_path.prepend()` takes only 1 argument (AS).**
  For N prepends, the generator calls it N times.
- **Filter/protocol names must not contain `-`** in BIRD.
  The generator changes `-` to `_` (consistent in definitions
  and references).
- **Prefix sets in filters MUST use the `+` suffix.**
  `if net ~ [ 10.0.0.0/8 ]` (without `+`) does NOT match more
  specific prefixes (e.g. 10.99.98.0/24) — the filter rejects all routes.
  The correct form: `if net ~ [ 10.0.0.0/8+ ]` (this prefix or more
  specific). Same for communities: `bgp_community ~ [ (65000,100) ]`.
- **`network` in Titian only records intent (a comment in bird.conf),
  not a BIRD route.** A new prefix is advertised when it exists in the BIRD
  routing table (via kernel/direct/static) AND passes the export filter.
  Note: the stock bird.conf `kernel` protocol does NOT have `learn;` — kernel
  static routes (e.g. `route add`) do NOT enter the BIRD table. To
  advertise a new prefix, define it via the `static` protocol in
  bird.conf (`route <prefix> via <nexthop>;`).
- **`router bird` (entering the view) vs `router bird enable`.**
  `router bird` alone enters `(config-bird)#`; `router bird
  enable` is still a command in configure-view (enabling BIRD).
- **The BGP section marker** `#-BGP-#` … `#-ENDBGP-#` must exist in
  bird.conf (added once at deploy; stock bird.conf does not have it).

### 9b.6 Delete

```
configure terminal
router bird
no neighbor 10.99.40.2
no network 10.99.40.0/24
no filter F-RB3011-IN
end
configure terminal
commit
save
```

---

### 9b.7 TCP MD5 authentication (RFC 2385) — lab testing only

> **CLOSED BY B25 (17 Nov 2026) — BGP MD5 PROVEN NON-FUNCTIONAL on this platform.**
> All four live test variants (password only; explicit `authentication md5;`;
> `setkey on`; `setkey off`) FAILED with `connect()` ENOENT — see §9b.8.
> The procedure below is kept as a REPRODUCTION ARCHIVE (how to install
> + remove MD5 + how to verify the digest), NOT for enabling MD5 in the
> lab. DO NOT enable MD5 on this lab BGP session.

> **Note:** the BGP MD5 password here is ONLY for lab testing.
> Not a production credential. The test password used in the lab
> is recorded in `HASIL.md` (FASE 3 follow-up) — not in this
> guide — because this guide is a general procedure, while the
> password is specific to each test session.

TCP MD5 signs every TCP segment of the BGP session with a shared
secret. Both sides MUST use the EXACT same password — a single
character difference = the session FAILS completely (no fallback
to no-MD5).

**Absolute requirement:** IDENTICAL password on BSDRP and on RB3011.
If MD5 is installed on only one side, the session NEVER becomes
Established — the side without MD5 rejects MD5-signed SYNs, the
side with MD5 rejects unsigned SYNs. Symptoms in
`show protocol`: the session sticks at `Active` / `Connect` with
`Socket: Connection closed` or `Connection refused`, and in
`tcpdump` you see repeated SYNs (retransmits) without SYN-ACK.
That is NOT a link problem — that is MD5 mismatch / one-sided.

**1. Generate a password (host-side, on the BSDRP machine)**

A strong random password, 20 alphanumeric characters (no spaces —
klish rejects spaces). Generate it on the machine, DO NOT write it
in chat:

```
PW=$(LC_ALL=C tr -dc "A-Za-z0-9" < /dev/urandom | head -c 20)
echo "$PW" > /tmp/bgpmd5-test-pw.txt; chmod 600 /tmp/bgpmd5-test-pw.txt
```

(`LC_ALL=C` is mandatory — FreeBSD `tr` without it fails with
`Illegal byte sequence` on random bytes. Check the length = 20
before using it.)

**2. BSDRP side (klish) — install the password on the neighbor**

The klish command lives in the `neighbor` view (`password <text>`),
or via the backend `titian-bgp.sh`:

```
configure terminal
router bird
neighbor 10.99.40.2
password <PASSWORD-TEST>
exit
end
configure terminal
commit
save
```

Or via the backend (same result — the intent written is identical):

```
/opt/titian/sbin/titian-bgp.sh neighbor-set 10.99.40.2 password <PASSWORD-TEST>
/opt/titian/sbin/titian-bgp.sh generate
```

Result in bird.conf (section `bgp_10_99_40_2`):

```
protocol bgp bgp_10_99_40_2 {
    ...
    neighbor 10.99.40.2 as 65001;
    password "<PASSWORD-TEST>";
    ...
}
```

**3. RB3011 side (RouterOS 7) — install the SAME key**

Read the password from the file on the BSDRP machine (do not retype
it manually — one typo character = failed session):

```
PW=$(cat /tmp/bgpmd5-test-pw.txt)
ssh -i /root/.ssh/rb3011_key agoes@192.168.91.32 \
  "/routing/bgp/connection/set [find name=bgp-bsdRP] tcp-md5-key=$PW"
```

Or directly in the RB3011 terminal:

```
/routing/bgp/connection/set [find name=bgp-bsdRP] tcp-md5-key=<PASSWORD-TEST>
```

RouterOS 7.25.1 gotchas:

- `tcp-md5-key` is a **connection** property, NOT a template one.
  Setting it on a template is REJECTED: `bad parameter tcp-md5-key`.
- `print` (including `print detail`) does NOT display
  `tcp-md5-key` — RouterOS hides the key value.
  Not showing in print does NOT mean it is not installed.
  A `set` that succeeds (exit 0, no error) = installed.
  Real verification = session Established + valid MD5 digest
  (see the verification section below).

**4. Verification — session back to Established with MD5 active**

The session will drop when MD5 is installed on one side, then
re-Establish once both sides match. Wait until
`show protocol` shows `Established` (on a lossy link this can take
a few minutes — TCP retransmits need a low-loss window; that is a
link problem, not MD5):

```
show protocol bgp           # must be Established
birdc show route protocol bgp_10_99_40_2
```

Proof MD5 is active (from the BSDRP machine) — capture SYNs on
port 179, check the MD5 option on the packets:

```
tcpdump -n -v -i bridge0 "tcp port 179 and tcp[tcpflags] & tcp-syn != 0"
```

A SYN from a peer using MD5 shows
`options [..., md5 ..., mss ...]`. To verify the digest matches
the password in use, give the password to tcpdump via `-M`:

```
PW=$(cat /tmp/bgpmd5-test-pw.txt)
tcpdump -n -v -M "$PW" -i bridge0 "tcp port 179 and tcp[tcpflags] & tcp-syn != 0"
```

Correct result: `options [nop,nop,md5 valid,mss ...]`.
`md5 valid` = digest matches = both sides use the same password.
If the digest is wrong, tcpdump reports MD5 failure —
meaning the two sides' passwords do NOT match; sync them again.

**5. Removing MD5 (back to no password)**

```
configure terminal
router bird
neighbor 10.99.40.2
no password
exit
end
configure terminal
commit
save
```

And on the RB3011:

```
/routing/bgp/connection/set [find name=bgp-bsdRP] tcp-md5-key=""
```

Remove on BOTH sides — if only one side is removed, the session
fails with the same symptoms as above (one side with MD5, one
without).

---

### 9b.8 WARNING — TCP MD5 breaks BIRD connect() on this platform (found 16 Nov 2026; PROVEN BY B25, 17 Nov 2026)

On BIRD 2.20.0 + FreeBSD 16.0-CURRENT, enabling TCP MD5 on a BGP session breaks `connect()` with `Socket error: connect: No such file or directory` (ENOENT) — the session sticks at `Active`, never Established, and restarting the daemon does NOT fix it. This is NOT a password mismatch: `tcpdump -M` proves the digest matches on both sides, and MD5 SYNs from the RB3011 are silently discarded without SYN-ACK/RST (the BIRD listen socket does not apply the MD5 key).

**B25 results (17 Nov 2026, report `BIRD-B25-REPORT.md`):** all four live test variants FAILED with ENOENT deterministically, using the same single-use test key on both sides (`tcpdump -M` digest = "md5 valid"):

1. **Password only** (current Titian emit) — Active + ENOENT (reproduction of the 16 Nov incident).
2. **Explicit `authentication md5;` + password** — Active + ENOENT, even after `birdc restart` of the protocol (fresh socket). The "missing explicit auth option" hypothesis is PROVEN FALSE.
3. **Password + `setkey on`** (kernel SADB path) — Active + ENOENT. The `tcp-md5` SA WAS installed in the SADB (`setkey -D`, state=mature) — the path works, the connection still fails.
4. **Password + `setkey off`** (setsockopt `TCP_MD5SIG` path) — Active + ENOENT. SADB empty; `setsockopt TCP_MD5SIG` accepted by the kernel — the path works, the connection still fails.

Control: MD5 OFF on both sides → Established in under 1 minute, stable. The kernel supports `TCP_MD5SIG` (setsockopt OK) and has MD5 code (`tcpmd5`); what is broken is BIRD 2.20.0's MD5 socket handling on this platform (BIRD never sends a SYN while MD5 is active; `connect()` fails before any packet leaves).

**Status:** MD5 **DISABLED** in the lab (both sides), BGP runs without MD5 on this private lab link. **DO NOT enable MD5 again on this lab BGP session.** If MD5 is ever needed in the future, the paths are: a BIRD upgrade (hypothesis, UNTESTED — no newer BIRD exists in this image) or a different platform — that is a separate design decision, not a Titian emit fix (no emit variant fixes it).

---

## 9c. FRR — alternative routing suite (not BIRD)

FRR (`net/frr10`, version 10.7.1 in the image) is an alternative
routing suite replacing BIRD. BIRD and FRR **cannot run together**
— hard mutual exclusion both ways (exit 33): `router bird enable` +
`router frr enable` together is rejected, checked from three sources
(`bird_enable`/`frr_enable` in rc.conf, service status, running
`bird`/`zebra` processes, and pending intent in
`/etc/titian/netstate/routing.intent`).

**Important difference vs BIRD — the features are NOT the same at the klish layer:**

| Aspect | BIRD (klish) | FRR (klish) |
|---|---|---|
| BGP neighbor, filter, network | Yes — complete via `router bird` (§9b) | No — no neighbor/filter commands in klish |
| Attributes (local-pref, MED, prepend, community) | Yes — per-neighbor | No — not in klish |
| Enable/disable + `commit` | Yes | Yes (`router frr enable`) |
| Enter the native CLI (vtysh) | — | Yes — `vtysh` in the `router frr` view (§9c.2) |
| Show status/version | Yes (`show bird`, `show route`) | Yes (`show frr`, `show frr version`, `show frr bgp summary`, `show frr ospf neighbor`) |

FRR routing protocol configuration (BGP neighbor, route-map,
prefix-list, community, local-pref, MED, AS-path prepend) is done
**directly in `vtysh`** (§9c.2), not via klish. Native FRR model:
config via vtysh applies immediately (running) + `write memory` to
persist it to `/usr/local/etc/frr/frr.conf`. The FRR daemon itself
supports all those features (route-map, prefix-list, standard/large
community, local-pref, MED, prepend) — only the path is vtysh, not
klish.

> **Design change 17 Nov 2026 (user decision):** the klish FRR
> config commands (`router-id`, `log syslog`, `write-memory`,
> `router bgp`, `router ospf`, `route-map`, `ip prefix-list`,
> `ip community-list`) are **REMOVED**. The full klish coverage
> program for FRR is cancelled; all config now goes through the
> `vtysh` handoff. Migration notes are in §9c.7. The old intent file
> `/etc/titian/frr.conf` is no longer used and must never be installed
> as the live `frr.conf`.

### 9c.1 Enable — BIRD must die first (two separate commits)

Exclusion is checked against services/processes that are **still running**,
not just intent. So disable BIRD + `commit` first, then enable FRR:

```
! Step 1 — disable BIRD
configure terminal
no router bird enable
end
configure terminal
commit
save
! Step 2 — only then enable FRR
configure terminal
router frr enable
end
configure terminal
commit
save
```

The step-2 `commit` runs `titian-frr.sh frr-apply`:
`sysrc frr_enable="YES"` + `service frr start` (the `zebra` daemon comes
up first; `bgpd`/`ospfd` come up if configured in `frr.conf`).
Disable FRR: `no router frr enable` + `commit` + `save`
(`service frr onestop` + `frr_enable="NO"`).

**Behind the scenes (FreeBSD `net/frr10`, official `frr.in` rc script):**
`service frr start` → `watchfrr` → restarts all daemons in
`frr_daemons` → `vtysh -b` loads the boot config. Relevant rc.conf
variables (defaults from `frr.in`):

```
frr_enable="YES"
frr_daemons="mgmtd zebra staticd bgpd"   # minimum for BGP; default = all daemons
frr_vtysh_boot="YES"                     # default; integrated config (frr.conf)
watchfrr_enable="YES"                    # default; watchfrr watches & restarts daemons
frr_default_profile="traditional"        # alternative: "datacenter"
zebra_flags="-A 127.0.0.1"               # default
```

The `frr_daemons` order matters — `mgmtd` first, then `zebra`. When
starting with `frr_vtysh_boot=YES`, the rc script automatically creates
`/usr/local/etc/frr/vtysh.conf` (`service integrated-vtysh-config`)
and `/usr/local/etc/frr/frr.conf` (`log syslog informational`) if
they do not exist yet (owner `frr:frr`). Integrated config in
`/usr/local/etc/frr/frr.conf` (usual header: `frr version 10.x` +
`frr defaults traditional` + `hostname <name>`). Daemon sockets/PIDs:
`/var/run/frr/`. Reload without restart: `service frr reload` (needs
the `frr10-pythontools` package).

**BSDRP (official documentation):** BSDRP ships BOTH daemons —
*"For a routing protocol daemon, you can choose between Bird and
FRRouting."* How to enable in BSDRP (User Guide, Quick start):
`sysrc frr_enable=yes` → `service frr start` → `cli` (enter the FRR
CLI) → `wr` (save) → `exit` → `config save` (persist `/etc` +
`/usr/local/etc`, both on BSDRP RAM disks). There is an `autosave`
service (`sysrc autosave_enable=yes`) so `config save` runs
automatically on every change. BSDRP 2.0 = bird 2.17 + frr 10.4.1;
the latest lab mentions Bird 3 + FRRouting 10.

**Why they cannot run together:** BIRD (bgp protocol) and FRR
`bgpd` both listen on TCP 179 for incoming BGP sessions — two processes
cannot bind the same port. BSDRP treats them as **alternatives** ("choose
between"), not to be run together. BIRD↔FRR interop is proven at the
protocol level (BSDRP lab route-reflector + confederation mixing Bird 3
and FRR 10 as BGP peers) — but that is on **different routers**, not one host.

### 9c.2 Entering vtysh from klish (handoff)

```
configure terminal
router frr
vtysh
! ... now in the native FRR CLI (vtysh prompt) — configure as usual ...
exit
! back in klish (config-frr); the running-config is auto-synced to /cfg
exit
end
```

| Item | Meaning |
|---|---|
| `vtysh` in the `router frr` view | Enter the native FRR CLI as a klish child — `exit` in vtysh returns to klish |
| Requirement | FRR must already be running (`router frr enable` + `commit`); this command needs an interactive session (TTY) — from a pipe/script it fails LOUD (rc=33), it never hangs silently |
| After exiting | The wrapper runs `write memory`, then copies the live frr.conf to `/cfg/titian/frr.conf` (best-effort, §9c.6) |
| `save` | Runs the same sync (hook in `titian-cfg.sh`) |

Outside klish, the BSDRP shell `cli` command still enters vtysh
as before. The klish command is named `vtysh`, not `cli` — `cli`
is already used by the BIRD CLI-socket command in klish
(conf-bgp.xml), so `cli` inside klish would be ambiguous.

### 9c.3 Show

```
show frr
show frr version
show frr bgp summary
show frr ospf neighbor
show ip bgp
show ip bgp summary
show ip ospf
show ip ospf neighbor
show frr route
```

`show frr` shows version, enable intent, `frr_enable` in rc.conf,
service status, and the `zebra` pid if running. `show frr version`
shows version + `vtysh show version` output.
`show frr bgp summary` and `show frr ospf neighbor` are the
FRR-namespaced counterparts of `show ip bgp summary` and `show ip
ospf neighbor` (the same `vtysh -c` passthrough). `show frr
route` shows the FRR/zebra route table (`vtysh show ip route`;
the plain `show ip route` is the kernel table).

### 9c.4 BGP via vtysh — example (not klish)

Enter vtysh via the §9c.2 handoff, then configure
BGP as usual in FRR (eBGP example to RB3011, AS 65001 — exact
equivalent of the BIRD configuration in §9b.1):

> **Route-map MANDATORY:** FRR 10.x rejects eBGP without an in AND
> out route-map (log: `EBGP outbound policy not properly setup`; without
> a route-map, `show ip bgp summary` shows PfxRcd/PfxSnt = 0,
> and the summary on the RB3011 shows `(Policy)`). Proven in test 14 —
> session Established but 0 prefixes until the route-map was installed.

```
! in vtysh (via the §9c.2 handoff)
configure terminal
router bgp 65000
 bgp router-id 10.99.40.1
 bgp default local-preference 100
 neighbor 10.99.40.2 remote-as 65001
 neighbor 10.99.40.2 description RB3011-TEST
 neighbor 10.99.40.2 send-community
 neighbor 10.99.40.2 route-map F-RB3011-IN in
 neighbor 10.99.40.2 route-map EXPORT-OUT out
 network 10.99.40.0/24
exit
ip prefix-list F-RB3011-IN seq 5 permit 10.0.0.0/8 le 32
ip prefix-list F-RB3011-IN seq 10 deny 192.168.0.0/16 le 32
ip prefix-list F-RB3011-IN seq 20 deny any
ip prefix-list EXPORT-NET seq 5 permit 10.99.40.0/24
route-map F-RB3011-IN permit 10
 match ip address prefix-list F-RB3011-IN
 set local-preference 100
route-map F-RB3011-IN deny 20
route-map EXPORT-OUT permit 10
 match ip address prefix-list EXPORT-NET
 set community 65000:100
 set metric 50
 set as-path prepend 65000 65000
end
write memory
```

BGP FRR is **deliberately vtysh-only by design**: the FRR klish only
manages enable/disable + the `vtysh` handoff + show. Adding full
route-map/policy commands to klish makes no sense — FRR BGP itself is
already vtysh-only (see §9c.2), and a route-map is a one-off
per-neighbor configuration, not state that needs klish replay.
Working pattern: express the enable intent in klish → `commit` →
daemon comes up → configure BGP (neighbor + route-map) in vtysh →
`write memory` (or exit vtysh / `save` — sync is automatic, §9c.6).

BIRD → FRR attribute equivalents: `local-pref` = `set
local-preference` (or `bgp default local-preference`),
`med` = `set metric`, `prepend N` = `set as-path prepend`
(many ASNs at once), `community` = `set community`
(+ `neighbor X send-community` so it is sent to the peer), import/export
filter = `route-map ... in/out` + `prefix-list` (+
`match community` if needed). FRR route-map + prefix-list are
**more expressive** than BIRD filters because they can match
community/AS-path/metric, not just prefixes. What has no 1:1
equivalent in FRR: the BIRD filter language (`if ... then` in
`bird.conf`) — in FRR all policy goes through route-map/prefix-list/
community-list.

**Communities — standard, large, well-known:**
- Standard: `set community 65000:100`; send: `neighbor X
  send-community`.
- Large (RFC 8092, format `ASN:V1:V2`): `set large-community
  65000:100:999` + `neighbor X send-community large` (`both` =
  standard+large, `all` = +extended).
- Match: `ip community-list standard NAME permit 65000:100`
  then `match community NAME` in the route-map.
- Well-known: `no-export` = 65535:65281 (do not advertise outside
  the confederation); `no-advertise` = 65535:65282 (do not
  advertise to any peer); `local-AS` = 65535:65283;
  `no-peer` = 65535:65284; `blackhole` = 65535:666 (RFC 7999).
  In a route-map: `set community no-export`. Add without
  overwriting: `set community ... additive`.

**Verification (vtysh):**

```
show ip bgp summary
show ip bgp neighbors 10.99.40.2 advertised-routes
show ip bgp neighbors 10.99.40.2 received-routes
show ip bgp community 65000:100
show ip route
```

**FreeBSD quirk (known):** FRR 9.x–10.1.1 on FreeBSD 14
does not show the default gateway & kernel static routes in
`show ip route` (issue #17113). In 10.7.1 it is probably
already fixed, but during the FRR test you **must verify `show ip
route` contains kernel routes** (default/static), not only BGP
routes.

### 9c.5 Test status (honest) — updated 17 Nov 2026

FRR has **run live** on the test machine (test 14, 15 Nov 2026):
daemon up via klish (`router frr enable` + `commit`), router-id/log/
write-memory sub-commands PASSED, two-way mutual exclusion PASSED,
BGP eBGP via FRR to the RB3011 **Established + two-way route exchange**
(PfxRcd/PfxSnt = 2/2) after the vtysh route-map (§9c.4), then back to
clean BIRD + BGP re-Established. Details:
`~/workspace/titian-live-test-20261113/HASIL.md` (test 14).

- The FRR CLI (enable, router-id, log, write-memory, show) **exists** and
  mutual exclusion vs BIRD **has been tested** (fails rc=33 both ways).
- Package `frr10-10.7.1_1` is installed in the image, the `frr` rc script exists.

**Test 14 findings already fixed in the repo (this push):**
- `service frr stop` only killed watchfrr — now the stop path kills
  ALL daemons (watchfrr, zebra, bgpd, ospfd, ripd, staticd, mgmtd)
  with a grace period, then forcefully if needed.
- A misleading commit message was fixed (it no longer prints
  "bird disabled + stopped" when enabling FRR; `birdc configure`
  is skipped when bird is not running; the "BIRD unknown" label was
  replaced with the correct version label).

**New design 17 Nov 2026 — live-tested (17 Nov 2026, 17:30–17:59 WIB, PASSED):**
- The `vtysh` handoff (§9c.2), frr.conf ↔ /cfg persistence + boot
  reconcile (§9c.6), deprecation of the klish config commands (§9c.7),
  and bounded backend calls (`service frr start` 60 s,
  `vtysh -c` 30 s — anti-hang for `router frr enable`+`commit`, see
  the diagnosis below) — deploy 5/5 md5 match, `router frr enable` +
  commit in 8 seconds with NO hang (vs >4 minutes twice on 16 Nov),
  enter vtysh + `exit` back to klish, BGP via FRR Established both
  ways to the RB3011 (PfxRcd 21/23, as-path 65000×3, community
  65000:100, MED 50), `show frr bgp summary` works, frr.conf
  live==/cfg `ff589198…` (native), reboot: FRR up + BGP back, then
  back to the BIRD anchor + BGP 12 Established. Mock
  `FRR-HANDOFF-MOCK.sh` 65 PASS/0 FAIL (staging) + the live evidence
  above.
- The klish `router-id` / `log syslog` / `write-memory` commands
  have been REMOVED (not merely untested) — their equivalents are
  now the same-named vtysh commands inside a `vtysh` session (§9c.7).

**Diagnosis of the `router frr enable`+`commit` hang (>4 minutes, 2×, 16 Nov 2026):**
from the CODE, three unbounded calls on the commit path — (1)
`service frr start` (waiting on daemons that never come up, e.g.
because the live frr.conf was missing/stale); (2) `vtysh -c "show
running-config"` and `vtysh -f` in the old intent reconciliation
(waiting on an unresponsive mgmtd — the readiness wait loop was
bounded at 10 s, but the calls after it were not); (3) `service frr
onestop`/`stop` on the disable path. Staging fix: every one-shot
backend call now goes through the `run_bounded` watchdog (vtysh 30 s,
service start 60 s, stop 30 s); the interactive `vtysh` session is
NEVER wrapped in a timeout. **Live verification 17 Nov 2026: FRR enable+commit 8 s, FRR disable 2 s, BIRD enable 8 s — the hang did not recur in any commit of this run (nor in the later fixes run, enable ~6–8 s).**

**Limitations that still apply:**
- FRR BGP/OSPF = vtysh-only (see §9c.4 — in+out route-map mandatory).
- FreeBSD quirk (§9c.4): `show ip route` in FRR 9.x–10.1.1 does not
  show the default gateway & kernel static routes (issue #17113) —
  in 10.7.1 it is probably already fixed, **must verify `show ip
  route` contains kernel routes** at the next FRR test, not only BGP
  routes.

**Fixes for the 5 live-test findings (17 Nov 2026, ~18:30–19:07 WIB, PASSED live):**
(1) frr.conf boot race — `frr-boot-reconcile` restarts FRR after
the restore (only when a snapshot was actually installed + zebra is
running); proven in the reboot test: FRR came up with the FULL
config and no manual restart (BGP Established, frr.conf live==/cfg
`ff589198…`); (2) L2 not restored at boot — the `#-TITIAN-L2-#`
block (`cloned_interfaces` + ifconfig + bridge members) is written
to `/etc/rc.conf` + `/cfg/rc.conf` on every `save`/`restore`
(`sync-rc-l2`); proven in the reboot test: 33 clone interfaces +
VXLAN 11 UP + overlay ping 0% loss with no manual recovery;
(3) replay silently stopping on the old FRR intent — the 19-line
intent block was removed from startup-config (NEW content-without-
stamp anchor `48bd81b083cf8b466783d9d86812aa6f`, 407 lines; bird.conf
still `bb21986089d77002e227315a216ea4be`); replay runs fully + `save`
is safe; (4) `.last-save/bird.conf` checkpoint holding the default
— `mirror_bird_conf()` mirrors the generated bird.conf to
`/cfg/local/bird.conf` + a snapshot guard rejects bird.conf without
the `#-GLOBAL-#` marker; (5) orphaned FRR daemons after disable —
the stop list now has 14 names + a sweep of `/usr/local/lib/frr/*`;
proven live: `ps` shows 0 FRR processes after disable (7 orphans
in the previous run). Mocks after the fixes: `FRR-HANDOFF-MOCK.sh`
72 PASS/0 FAIL, `BOOT-PERSIST-MOCK.sh` (new) 38 PASS/0 FAIL;
`verify.py` zero errors (2117 COMMAND).

**References:**
- FreeBSD port `net/frr10`, official rc script: https://raw.githubusercontent.com/freebsd/freebsd-ports/main/net/frr10/files/frr.in
- BSDRP User Guide (choose Bird or FRRouting): https://bsdrp.net/documentation/end-users_docs
- BSDRP lab (BGP/OSPF/RIP/ISIS/BABEL with FRR): https://bsdrp.net/documentation/examples/simple-bgp-rip-ospf-lab/
- BSDRP lab (route-reflector + confederation Bird 3 + FRR 10): https://bsdrp.net/documentation/examples/bgp-route-reflector-and-confederation-using-frr-and-bird/
- Official FRR 10.0 docs (BGP): https://docs.frrouting.org/en/stable-10.0/bgp.html
- Official FRR 10.0 docs (route-map): https://docs.frrouting.org/en/stable-10.0/routemap.html
- FRR issue #17113 (`show ip route` does not show kernel routes on FreeBSD): https://github.com/FRRouting/frr/issues/17113

### 9c.6 frr.conf ↔ /cfg persistence + boot

`/usr/local/etc/frr/frr.conf` lives on a BSDRP RAM disk (gone after a
reboot) — it used to never be persisted (bug a: frr.conf lost after
reboot). Now:

| Moment | What happens |
|---|---|
| Exiting `vtysh` (§9c.2) | `write memory`, then copy the live frr.conf → `/cfg/titian/frr.conf` (best-effort) |
| `save` | The same hook via `titian-cfg.sh` (sync, after the startup-config dump lands) |
| Boot | `titian-cfg.sh restore` installs the `/cfg/titian/frr.conf` snapshot → the live location; **but FRR has ALREADY come up** (rcorder places `frr` before `titian`) with a minimal config from the empty RAM disk — installing the file alone does not make the daemons use that config. `frr-boot-reconcile` then **restarts FRR** after the restore (only when a snapshot was actually installed + zebra is running) so the restored config is really loaded (Finding 1, live test 17 Nov 2026 — the old claim "restore BEFORE FRR comes up" is WRONG under the current rcorder). If FRR is not running yet at boot, no restart is needed: `apply-all` later starts it with the already-restored file. `frr-boot-reconcile` also aligns `bird_enable`/`frr_enable` in rc.conf from `routing.intent` + stops the wrong daemon if it already came up (closes bug b: boot restoring BIRD despite FRR intent — root cause: `sysrc` only writes tmpfs `/etc/rc.conf`, while the stale `/cfg/rc.conf` (`bird_enable=YES`) is restored at boot and rc starts BIRD; now the flags are mirrored to `/cfg/rc.conf` on every commit + reconciled on every boot) |

Safe to re-run: running `save`/boot twice gives the same result (the copy
is skipped when the content is identical). A snapshot in the old klish
intent format (lines `bgp ...`/`route-map ...`, header "intent klish")
is **REJECTED** at restore — it is not native FRR config; installing it
would make the daemons fail to parse. Such a snapshot is left alone;
the next `save` overwrites it with native config.

### 9c.7 Migration notes — old klish commands → vtysh

Every command below was REMOVED from klish on 17 Nov 2026. Its vtysh
equivalent is typed inside a `vtysh` session (§9c.2):

| Old klish command (removed) | vtysh equivalent |
|---|---|
| `router frr` → `router-id <IP>` | `configure terminal` → `router-id <IP>` → `end` → `write memory` |
| `router frr` → `no router-id` | `configure terminal` → `no router-id` → `end` → `write memory` |
| `router frr` → `log syslog` / `no log syslog` | `configure terminal` → `log syslog` / `no log syslog` → `end` → `write memory` |
| `router frr` → `write-memory` | `write memory` (in vtysh) — or exit `vtysh` / `save` (automatic sync, §9c.6) |
| `router bgp <AS>` + `neighbor <IP>` + `remote-as` / `description` / `route-map` / `prefix-list` / `send-community` / `timers` + `network` | `configure terminal` → `router bgp <AS>` → `neighbor <IP> remote-as ...` etc. (full example §9c.4) |
| `router ospf` + `network ... area ...` / `redistribute ...` | `configure terminal` → `router ospf` → `network ... area ...` / `redistribute ...` |
| `route-map <NAME> <permit\|deny> <SEQ>` + `match ...` / `set ...` | `route-map <NAME> <permit\|deny> <SEQ>` + `match ...` / `set ...` (example §9c.4) |
| `ip prefix-list ...` | `ip prefix-list ...` (example §9c.4) |
| `ip community-list standard <NAME> <VALUE>` | `bgp community-list standard <NAME> permit <VALUE>` (FRR 10.7.1 syntax; the daemons reject `ip community-list`) |

Note: config previously written as klish intent in
`/etc/titian/frr.conf` is NOT migrated automatically — that file
is no longer used. Reconfigure once via `vtysh`, then `write memory` /
exit `vtysh` / `save` to persist it (§9c.6).

---

## 9d. BRAS — Broadband Remote Access Server (PPPoE + IPoE + RADIUS)

BRAS is Titian's subscriber access service: one service that unites
the PPPoE server (mpd5), the IPoE server (isc-dhcpd), and RADIUS
authentication (FreeRADIUS — in this lab, myRadDASH host 84).
Subscribers connect via PPPoE or IPoE; both use the same RADIUS as
the authentication authority, and both hand out IPs from pools
managed by Titian. This chapter is the detailed service
documentation — architecture, flows, live test evidence, and
operations. Concise per-component commands are in §9a.2 (IPoE
server), §9a.3 (IPoE + RADIUS), and rows 14–15 of the table in §14
(PPPoE).

### 9d.1 Overview — architecture and subscriber flows

Components:

- **PPPoE server — mpd5 5.9.** Serves PPP sessions over Ethernet
  (discovery → LCP → CHAP/PAP auth → IPCP). Hands out IPs from a
  pool.
- **IPoE server — isc-dhcpd 4.4.3P1.** Serves plain IP over Ethernet
  (DHCP DISCOVER → OFFER → REQUEST → ACK). No PPP session, no
  username/password — MAC-based auth.
- **RADIUS — FreeRADIUS 3 (myRadDASH host 84, 103.50.129.84:1812).**
  The authentication authority for PPPoE (username/password) and
  IPoE (MAC). Database: MariaDB (`radcheck`, `nas`, `clients`).
- **IP pools.** PPPoE: 10.99.42.100–110 (pool1), server 10.254.254.1.
  IPoE: 10.99.50.100–110 (subnet 10.99.50.0/24, gateway 10.99.50.1,
  DNS 8.8.8.8).

PPPoE subscriber flow:

1. The client sends PADI (discovery) → the server replies PADO →
   PADR → PADS (session established).
2. LCP negotiates → CHAP (or PAP) auth.
3. mpd5 sends an Access-Request to RADIUS (when RADIUS is active)
   or checks the local user (when it is not).
4. RADIUS replies Access-Accept (or Reject). On Accept → IPCP
   assigns an IP from the pool → the session is UP. On Reject →
   the session fails and the client gets NO IP.
5. When RADIUS is active, RADIUS is the authority — not a local
   fallback.

IPoE subscriber flow:

1. The client sends DHCPDISCOVER (broadcast) → the server replies
   OFFER → REQUEST → ACK (DORA).
2. The server does NOT check RADIUS per request. Instead, at
   `commit`, every MAC declared in klish is verified against
   RADIUS (PAP, User-Name = MAC, User-Password = MAC). MACs that
   pass enter the allowlist (`radius-allowed`); MACs that fail are
   excluded.
3. dhcpd only offers IPs to MACs in the allowlist (pool
   `allow members of "radius-allowed"` + `deny unknown-clients`).
   A MAC outside the allowlist gets no OFFER.
4. A MAC removed from RADIUS after a commit keeps getting a lease
   until the next commit (allowlist regeneration).

When to use PPPoE vs IPoE:

- **PPPoE** — when subscribers need a username/password (one
  account per customer), sessions that can be monitored/terminated,
  and per-session auth. Suits residential broadband.
- **IPoE** — when the subscriber device does not support PPP, or
  device-based (MAC) access is enough (e.g. devices registered by
  MAC). No session, no password — simpler, but auth is only
  MAC-based (which can be spoofed).
- Both can run at the same time (different pools, different
  interfaces) on the same machine.

### 9d.2 PPPoE (mpd5) — detail

Commands (view `pppoe-server`, configure mode):

```
configure terminal
pppoe-server
interface bridge0
pool 10.99.42.100 10.99.42.110
enable
end
configure terminal
commit
save
```

`commit` generates `/usr/local/etc/mpd5/mpd.conf` and starts `mpd5`.
Pool: `pool <start> <end>` (the IP range for clients). The server
uses IP 10.254.254.1 (the IPCP end), MTU/MRU 1492, acfcomp/protocomp
on. The PPPoE interface in the lab is `bridge0` (subscribers connect
via bridge0 / vxlan100).

Local users (no RADIUS): CHAP/PAP accounts are defined in the mpd5
configuration (chap/pap secrets). Live test 15 Nov 2026 (local
auth): the RB3011 as client — discovery/LCP/CHAP/IPCP PASSED, the
client got 10.99.42.100 from pool1, ping both ways 5/5 0% loss.
PPPoE over VXLAN also PASSED 16 Nov.

RADIUS (commands in the `pppoe-server` view):

```
configure terminal
pppoe-server
radius-server 103.50.129.84
radius-secret <secret>
enable
end
configure terminal
commit
save
```

Three things you must know (found during testing, 19 Nov 2026):

- **The RADIUS backend is enabled via `set auth enable
  radius-auth`.** The command `set auth enable radius` is **INVALID**
  on mpd5 5.9 (log: `option "radius" ambiguous`) — do not use it.
- **`set radius server` alone does NOT enable the RADIUS backend.**
  Without `radius-auth`, mpd5 only tries INTERNAL and then "ran out
  of backends" — RADIUS is never tried. The correct command is
  `set auth enable radius-auth` (source:
  `/usr/local/etc/mpd5/mpd.conf.sample`, label `radius:`).
- **The RADIUS branch must emit `set link enable chap` + `set link
  accept chap pap`.** Without them, the backend is selected with no
  link protocol → the client cannot authenticate. (This bug was found
  and fixed 19 Nov; mock PPPOE-MOCK 77/0, including console 20 Nov.)
- Generate: `set radius server <ip> <secret> 1812 1813`, retries 3,
  timeout 3. **`radius-acct` — the klish command is `radius-acct`
  (no argument) + `radius-nas-ip <ip>`.** `radius-acct yes` is
  **WRONG** (`Syntax error ... Illegal command line`) — the `yes`
  argument belongs to the backend script, not klish. `radius-acct`
  emits `set auth enable radius-acct` only when `radius-server` is
  set. Turn off: `no radius-acct`. **Live test 20 Nov 2026 —
  PASSED:** Start recorded in `radacct` (`acctsessionid 5130773-L-1`,
  `titian-test`, `10.99.42.100`, `acctstoptime NULL`) + visible in
  `GET /v0/sessions` (`active`, `source: radius`); Stop after the
  client disconnected (`acctstoptime` set, `acctsessiontime 130`,
  session gone from the API `[]`). PPPoE session monitoring via
  RADIUS Accounting is **DONE**. Details + evidence: report
  `PPPOE-MONITORING-20261119.md` §1.

Live test evidence (19 Nov 2026, myRadDASH host 84):

- **radtest 4/4 PASSED** — PAP correct → Access-Accept, PAP wrong →
  Access-Reject, CHAP correct → Access-Accept, CHAP wrong →
  Access-Reject; Response Authenticator OK.
- **PPPoE E2E via RADIUS PASSED** — the local `ppp` client (user
  `titian-test`): mpd5 log `RADIUS: Authenticating user
  'titian-test'` → `Rec'd RAD_ACCESS_ACCEPT` → `CHAP: sending
  SUCCESS`; `tun0` UP, IP **10.99.42.100** from pool1.
- **Negative test PASSED** — wrong password → `RAD_ACCESS_REJECT`,
  `tun0` got NO IP. RADIUS is the auth authority, not a local
  fallback.

Notes:

- **Ping from the client to 10.254.254.1 FAILED (100% loss) for the
  local client.** Not a RADIUS failure. Cause: a same-machine route
  conflict — the client and the mpd5 server are on the SAME machine;
  the route to the client IP 10.99.42.100 points to `lo0`, so the
  server's ICMP replies do not return through the tunnel. LCP/IPCP
  (which assign the IP) work. In the 15 Nov test (the RB3011 as a
  separate client), ping both ways was 5/5 PASSED.
- **The RB3011 as a client — POSSIBLE via the API, NOT via SSH
  password.** The RB3011 SSH key is rejected after the RouterOS
  v7.25.1 upgrade, and SSH password auth ALSO DOES NOT WORK (the
  server only offers `publickey` — RouterOS
  `always-allow-password-login=no` disables password auth when the
  user has a key configured; the user's password is NOT wrong).
  However, the **RouterOS API port 8728 WORKS** (password login OK)
  and is used to configure the RB3011 — DORA via the RB3011 PASSED
  20 Nov 2026 (see §9d.3). The SSH key still needs to be re-added
  via Winbox/API before interactive SSH can be used. The RB3011 is
  reachable only from the test machine (the Muse VM cannot reach
  the private IP 192.168.91.32).
- **FreeRADIUS CANNOT be installed on the test machine** (pkg repo
  `data.tzst` 404) — the reason for the pivot to myRadDASH.

Turn RADIUS off (back to local auth) and stop the server:

```
configure terminal
pppoe-server
no radius-server
no radius-secret
no enable
end
configure terminal
commit
save
```

The mpd5 console (permanent feature, 20 Nov 2026):

```
configure terminal
pppoe-server
console
end
configure terminal
commit
save
```

The console listens on `127.0.0.1:5005` (loopback only, not exposed
to the network). User `titian-console`, a 16-hex-char auto-generated
password — stored mode 600 in `/etc/titian/mpd-console.pw` +
`/cfg/titian/mpd-console.pw`, **NEVER printed** (`show pppoe-server`
only shows "set/unset", never the value). Rotate the password with
`console password` (generates a new one, then `commit`). Turn it off
with `no console` (the state and the password files are deleted too).

Three things you must know (found during the 19 Nov 2026 test):

- **The correct console syntax is `set console self 127.0.0.1
  5005`.** The form `set console ip 127.0.0.1 5005` is **WRONG** —
  mpd5 5.9 rejects it as "Unknown command" (source:
  `/usr/local/etc/mpd5/mpd.conf.sample`). The generator emits
  `set user titian-console <pw> admin` + `set console self
  127.0.0.1 5005` + `set console open` in the `startup:` section of
  mpd.conf.
- **The password MUST be 16 hex chars.** A 32-hex-char password
  **FAILS to log in** (even though the file hash matches the hash in
  mpd.conf) — the effective limit of mpd5 `set user` is 16 chars.
  The generator always uses 16 hex.
- **An mpd5 restart must wait for the old process to die.**
  `pkill` + an immediate start can fail with "already running as
  process <old pid>" — the generator now does stop → poll `pgrep`
  until empty (max ~10 seconds) → start.

The console is ONLY for mpd5 management (checking status) — do NOT
use it to view/close PPPoE sessions. Session termination from
myRadDASH still goes via SSH (`titian-remote-kick.sh`, §9d.7).

Restore note: the factory-reset auto-backup does NOT contain
`pppoe.conf` / `mpd.conf` (mpd5 runtime files). After a restore,
`mpd.conf` can still contain RADIUS (stale) because `cmd_apply`
deliberately returns early when PPPoE is disabled (it does not
regenerate mpd.conf) — but mpd5 stops with it. The same applies to
the console lines (`set user titian-console` + `set console ...`) —
stale in mpd.conf after a disable, but mpd5 is stopped so the console
does not listen; clean up with `no console` + commit if needed.
Clean up explicitly: `no radius-server` + `no radius-secret` + `no
enable` via klish → commit; then regenerate mpd.conf via an
enable→commit→disable→commit cycle; `service mpd5 onestop`. End
state: `pppoe.conf` = `enable no`, no radius; `mpd.conf` clean;
mpd5 stopped.

### 9d.3 IPoE (isc-dhcpd) — detail

Commands (view `ipoe-server`, configure mode):

```
configure terminal
ipoe-server
interface lagg0
pool 10.99.50.0/24 10.99.50.100 10.99.50.110 10.99.50.1 8.8.8.8 3600
enable
end
configure terminal
commit
save
```

Pool format: `pool <subnet>/<prefix> <start> <end> <gateway> <dns>
[lease-seconds]`. Default lease 86400 seconds (1 day). `commit`
generates `/usr/local/etc/dhcpd.conf` and starts `dhcpd` on the
chosen interface. Requirement: the interface must have an IP in
the same subnet as the pool (e.g. pool 10.99.50.0/24 needs an
interface with a 10.99.50.x IP) — otherwise `dhcpd` refuses to
start. Full commands and examples are in §9a.2.

mpd5 does NOT support IPoE. IPoE is plain IP over Ethernet, i.e.
DHCP — no PPP session, no username/password.

RADIUS MAC-auth (MAB — MAC Authentication Bypass):

IPoE has no username/password, so auth is MAC-based. isc-dhcpd has
NO native RADIUS support, and the `on commit` + `execute()` hook
CANNOT veto a lease (the lease is already committed when the hook
runs). The mechanism used (native isc-dhcpd): class
`radius-allowed` + one subclass per RADIUS-approved MAC + pool
`allow members of "radius-allowed";` + `deny unknown-clients;`.
RADIUS is the authority: at `commit`, every MAC declared in klish
is verified against RADIUS (PAP, User-Name = MAC, User-Password =
MAC). A MAC that RADIUS rejects / cannot verify (RADIUS
unreachable) is EXCLUDED + a warning (fail-closed). If MAC-auth is
on but ZERO MACs pass, generate FAILS loudly (rc 33) and the old
config is kept. Full commands are in §9a.3.

```
configure terminal
ipoe-server
radius-server 103.50.129.84
radius-secret <secret>
radius-mac 02:00:00:00:00:01
radius-mac-auth
enable
end
configure terminal
commit
save
```

`radius-mac` accepts a MAC address (lowercase is normalized,
idempotent — adding the same MAC twice still returns rc 0 with no
duplicate). `radius-secret` is never echoed by the backend (but the
klish command line IS echoed by klish — see §9d.4). Turn RADIUS
MAC-auth off (back to open DHCP): `no radius-mac-auth` +
`no radius-server` + `no radius-secret` + `no radius-mac <MAC>` →
commit → save (§9a.3).

Live test evidence:

- **13 Nov 2026 (open DHCP, no RADIUS): PASSED.** The RB3011 (DHCP
  client) bound 10.99.41.100/24, gw 10.99.41.1, DNS 8.8.8.8, ping
  3/3. Initial failure root cause: empty RB3011 VTEP (broadcast
  broken) — v7 syntax fix `/interface vxlan vteps add
  interface=vxlan100 remote-ip=10.10.2.3`.
- **19 Nov 2026 (RADIUS MAC-auth via myRadDASH): RADIUS
  verification at generate PASSED live.** Commit printed the warning
  `radius-mac 02:00:00:00:00:03 DITOLAK / tidak terverifikasi RADIUS
  (103.50.129.84) — dikeluarkan dari allowlist` (in Indonesian in
  the output) + `ipoe: RADIUS MAC-auth aktif (103.50.129.84): 1 MAC
  lolos, 1 ditolak/tak-terjangkau` + `dhcpd.conf generated` +
  `IPoE server (dhcpd) started on: lagg0`. That means: MAC `:01`
  got **Access-Accept** from myRadDASH (the secret matched — the
  response authenticator verified), MAC `:03` got **Reject** (no
  entry) and was excluded from the allowlist. The generated
  `dhcpd.conf` is CORRECT: class `"radius-allowed"` contains only
  `subclass "radius-allowed" 1:02:00:00:00:00:01;` (only `:01`),
  pool `allow members of "radius-allowed"` + range 10.99.50.100–110
  + routers 10.99.50.1 + DNS 8.8.8.8 + lease 3600, `deny
  unknown-clients`, subnet 10.99.50.0/24 on lagg0. **dhcpd
  RUNNING.**
- **Mock: IPOE-RADIUS-MOCK 33/0** (run on the FreeBSD test machine;
  UDP loopback in the Muse VM is blocked by the sandbox). PHASE A
  (MAC-auth OFF, backward compat), B (Accept MAC enters the
  allowlist, Reject MAC is excluded + warning), C (no radius-server
  → loud failure), D (RADIUS down → ZERO MACs → loud failure + old
  config kept), E (MAC/secret/IP validation, idempotent), F (helper
  Accept/Reject/wrong secret→rc 2/timeout→rc 2), G (`dhcpd -t`
  fails → loud failure + old config safe), H (`sh -n` +
  `py_compile`).

DHCP client test (DORA) — **PASSED 20 Nov 2026 via the RB3011**:

DORA (DISCOVER→OFFER→REQUEST→ACK) is **proven live** from a separate
host. The RB3011 as a DHCP client on `bond1` (the lagg0 subnet
10.99.50.0/24) via the RouterOS API 8728 — DHCP client `client3`
(`add-default-route=no`, `use-peer-dns=no`, so the RB3011 management
routing/DNS is not disturbed) — **bound 10.99.50.100/24**, gateway
10.99.50.1, DNS 8.8.8.8, `dhcp-server=10.99.50.1`,
`expires-after=59m58s`. Server side: the lease is recorded in
`/var/db/dhcpd.leases` (`binding state active`, MAC
`6c:3b:6b:ff:d7:95`, hostname `TEST`); ping from the test machine to
10.99.50.100 is **3/3, 0% loss**; ARP is `10.99.50.100 at
6c:3b:6b:ff:d7:95 on lagg0`. The full DORA cycle + a recorded lease +
a usable IP — **IPoE DORA is DONE**. The DHCP client was removed
after the test (the RB3011 is back to its pre-test state). Details:
report `PPPOE-MONITORING-20261119.md` §2.

Note — the same-machine limitation (19 Nov 2026, still valid for
local tests): broadcasts sent from the test machine itself do NOT
reach dhcpd on the same machine. Evidence: the raw-UDP client
(`dhcp-raw-client.py`, DISCOVER with a spoofed chaddr, no option 61,
bound to 10.99.50.1:68) sends without error, but tcpdump on
lagg0/ge1/ge2/lo0 captures nothing; a broadcast ping to
10.99.50.255 is also transmitted but appears on no interface (100%
loss); a unicast DISCOVER to 10.99.50.1:67 also gets no OFFER
(dhcpd serves lagg0 broadcasts). Two socket bugs were found and
fixed first (binding `0.0.0.0:68` → `Network is unreachable`;
limited broadcast 255.255.255.255 → `No route to host` — replaced
with the subnet broadcast 10.99.50.255, which has a route via
lagg0), but the root cause is a same-machine limitation: a broadcast
from the host itself does not return to a daemon on the same host.
This is a platform/test-harness limitation, NOT a failure of RADIUS
or the allowlist — both are proven live. To prove DORA, the client
must run on a SEPARATE host on the lagg0 subnet (10.99.50.0/24) —
the RB3011 via the API is the path (SSH password does not work,
see §9d.2). The client script (`dhcp-raw-client.py`: must bind
10.99.50.1:68, destination subnet broadcast 10.99.50.255, exit
0=OFFER+ACK, 1=no OFFER, 2=error) is documented here for that test;
the file was deleted after the restore (rewrite it if needed).

Limitations:

- Real-time per-request auth (a RADIUS check on every DHCPDISCOVER)
  is NOT possible with isc-dhcpd. The correct architecture for that
  is FreeRADIUS `rlm_dhcp` (FreeRADIUS as the DHCP server) — needs a
  new package + an architecture decision (FreeRADIUS cannot be
  installed on the test machine, pkg repo 404).
- RADIUS verification happens at generate/commit time, not per
  request. A MAC removed from RADIUS after a commit keeps getting a
  lease until the next commit (allowlist regeneration).
- dhcpd logging: `log-facility local7` in `dhcpd.conf`, but
  `/etc/syslog.conf` has NO rule for `local7` — so dhcpd logs
  (DISCOVER/OFFER) are not recorded anywhere. If you need DHCP logs,
  add a syslog rule for local7 first.

### 9d.4 RADIUS (myRadDASH) — detail

Server: myRadDASH host 84 (103.50.129.84), FreeRADIUS 3 in the
`myradash-freeradius` container, UDP port 1812 (auth) / 1813 (acct).
Database: MariaDB (`myradash-db`), tables `nas`, `radcheck`,
`radreply`, `radusergroup`, `clients`, `mitras`. The FreeRADIUS SQL
queries are STOCK; authorize only queries
radcheck/radreply/radusergroup — it does NOT join the `clients`
table. RADIUS auth only needs `nas` + `radcheck`; `clients` rows
are only for dashboard consistency.

NAS — `nasname` MUST be the source IP FreeRADIUS sees:

UDP packets from the test machine to 103.50.129.84:1812 arrive with
source IP **`103.50.128.18`** (MikroTik NAT from mgmt 10.10.2.3 — NOT
10.10.2.3, NOT 103.50.128.6). So the test NAS `titian-test` (id 26)
uses nasname `103.50.128.18`, shortname `titian-test`, platform
`generic`, auth_mode `radius`, mitra 7 (`Mitra Tes SSTP`). If the
nasname is wrong → FreeRADIUS rejects with `Ignoring request ...
from unknown client` + radtest TIMEOUT.

A new NAS needs a FreeRADIUS container restart:

`read_clients` is only read at STARTUP. SIGHUP is ineffective
(`HUP - No files changed. Ignoring`); touch + HUP reloads modules/
config files, NOT SQL clients. Cause: `dynamic-clients` is NOT
enabled. Fix: restart the `myradash-freeradius` container (`docker
restart`, ~1–5 seconds). Impact: a window of a few seconds, new
FNSNET logins may fail/delay (the NAS retries); sessions already
running are NOT affected. No production config change — the restart
only reloads the DB entries that were added.

`radcheck` op MUST be `:=`, not `==`:

All 55 working FNSNET rows use op `:=`. With `==`, rlm_sql treats
`Cleartext-Password` as a check item to match during authorize —
but the `User-Password` in the request is still ENCRYPTED at that
point (PAP has not decrypted it yet), so the check fails → the
password is not loaded into the control list → PAP has no "known
good password" → `No Auth-Type found: rejecting the user`. With
`:=`, rlm_sql SETS `Cleartext-Password` into the control list, PAP
compares it after decryption → match → Accept. Symptom when wrong:
the CORRECT password still gets Access-Reject, and the FreeRADIUS
debug log shows `sql: User found in radcheck table` +
`WARNING: check items do not match` + `No "known good" password
found`.

Test entries (mitra 7, LEFT — the user decides keep/delete):

- **NAS id 26** — nasname `103.50.128.18`, shortname `titian-test`,
  platform `generic`, auth_mode `radius`, mitra 7.
- **PPPoE user** — radcheck id 124: username `titian-test`,
  attribute `Cleartext-Password`, op `:=`, mitra 7. clients:
  username `titian-test`, mitra 7, service_type `pppoe`, status
  `active`, package_id NULL.
- **IPoE MAC** — radcheck id 125: username `02:00:00:00:00:01`,
  attribute `Cleartext-Password`, op `:=`, mitra 7. clients:
  username `02:00:00:00:00:01`, mitra 7, service_type `client`,
  status `active`. (MAB: User-Name = MAC, User-Password = MAC —
  the password value is the MAC itself, lowercase, colon-separated.)
  There is NO entry for `02:00:00:00:00:03` (deliberate — negative
  test).
- **FNSNET (mitra 6) NOT touched** — radcheck 55, nas 2, intact.

Secret — IMPORTANT CORRECTION (verified 19 Nov 2026):

- The RADIUS secret is stored in `/etc/titian/ipoe.conf` (mode 600)
  **AND is also saved to startup-config** via `<CONFIG/>` + `save`
  (verified: `grep -c "radius-secret" /etc/titian/startup-config`
  = 1 while RADIUS is active). The earlier claim that it is "not
  written to startup-config" was WRONG. Consequence: the secret is
  included in startup-config backups (and in the factory-reset
  auto-backup). When restoring/cleaning up, verify the count is 0.
- **The klish `radius-secret` command line IS echoed by klish to
  the output** (the prompt + command appear in tool output). So the
  secret value can appear in output/runtime logs — never copy that
  value into reports, files, or MEMORY. (The `titian-dhcp.sh` /
  `titian-pppoe.sh` backends themselves never echo the secret; it
  is klish that echoes it.)
- For PPPoE, the same secret is also in `mpd.conf` (an mpd5 runtime
  file) — clean it via `no radius-secret` + commit + regeneration
  (see §9d.2, restore note).

`commit` vs `save`:

- **`commit`** regenerates the service configs + reloads the daemons,
  but does NOT write startup-config. (Evidence: after `commit`
  alone, startup-config is unchanged.)
- **`save`** (from enable view) writes the running-config to
  startup-config + schedules the persist to `/cfg/titian`.
- So after changing RADIUS config: `commit` then `save`, then
  verify startup-config (md5 + the `radius-secret` count).

### 9d.5 Operations — backup, restore, verification, troubleshooting

Pre-test backup (before changing anything):

- IPoE: `ipoe.conf`, `dhcpd.conf`, `startup-config` (19 Nov backup:
  `~/workspace/titian-backups-machine/ipoe-radius-20261119/`).
- PPPoE: `pppoe.conf`, `mpd.conf`, `startup-config`, `resolv.conf`
  (19 Nov backup:
  `~/workspace/titian-backups-machine/pppoe-radius-20261119/`).

Restore the anchor (after testing):

1. Via klish, remove all RADIUS config + `enable` (IPoE:
   `no radius-mac-auth` → `no radius-mac <MAC>` → `no radius-secret`
   → `no radius-server` → `no enable`; PPPoE: `no radius-server` →
   `no radius-secret` → `no enable`) → `commit` → `end` → `save`.
2. If the startup-config without-stamp ≠ `48bd81b0…`, restore it
   from the backup `startup-config.orig` to
   `/etc/titian/startup-config` + `/cfg/titian/startup-config`
   (mount rw → cp → remount ro). The common cause of the difference:
   after a klish restore, `commit` writes an empty `ipoe-server`
   section (2 lines: `ipoe-server` + `!`) that is not in the anchor
   — the backup restore removes it.
3. Delete test files (`/tmp/dhcp-raw-client.py`, `/tmp/ipoe-secret`,
   and similar) on the test machine + the VM.

Anchor verification (the numbers that must match):

- startup-config with-stamp `c8a081c9…` / without-stamp
  `48bd81b0…` (both locations `/etc/titian` + `/cfg/titian`, in
  sync).
- `radius-` in startup-config = 0; `ipoe-server` in startup-config
  = 0 (when IPoE is not enabled).
- bird.conf x3 `b1d64147…`; frr.conf `ff589198…`.
- BGP **12 Established**; VXLAN **11/11 UP**; ping 10.99.40.2
  0% loss.
- dhcpd **stopped**; mpd5 **stopped**; `/` **read-only**.
- ipoe.conf = `interface lagg0` + pool only; pppoe.conf =
  `enable no`, no radius.

Troubleshooting:

| Symptom | Root cause (verified) | Fix |
|---|---|---|
| radtest TIMEOUT + log `Ignoring request ... from unknown client` | NAS not yet loaded by FreeRADIUS (`read_clients` only at startup) | Restart the `myradash-freeradius` container (§9d.4) |
| radtest Reject + `resp-auth WRONG` (Response Authenticator mismatch) | Secret mismatch (three copies differ — e.g. a quoted heredoc `<< "EOF"` made `$(openssl rand...)` literal) | Regenerate the secret as a literal value, make DB + machine match, restart FreeRADIUS, verify via MD5 (the hash only, not the value) |
| CORRECT password still Access-Reject + log `No Auth-Type found` | `radcheck` op `==` (not `:=`) | `UPDATE radcheck SET op=':=' WHERE username='...'` (§9d.4) |
| mpd5 log `option "radius" ambiguous` | `set auth enable radius` is INVALID on mpd5 5.9 | Remove it; use `set auth enable radius-auth` (§9d.2) |
| mpd5 `ran out of backends`, RADIUS never tried | `set radius server` alone does not enable the backend | Add `set auth enable radius-auth` (§9d.2) |
| PPPoE client cannot authenticate (CHAP/PAP not working) | The RADIUS branch did not emit `set link enable chap` + `set link accept chap pap` | Fix the generate (already fixed in staging `31f30f49…`) |
| IPoE `commit`: all MACs excluded + warning, generate fails rc 33 | ZERO MACs pass RADIUS (RADIUS down / wrong secret / no entries) | Check RADIUS is up, the secret matches, the MAC entries exist (fail-closed — deliberate) |
| MAC is in klish but gets no OFFER | The MAC was Rejected by RADIUS (no entry) → excluded from the allowlist at commit | Create the radcheck + clients entry for that MAC, then commit again |
| dhcpd does not start | The interface has no IP in the pool subnet | The interface must have an IP in the same subnet as the pool (§9d.3) |
| DORA: DISCOVER sent but no OFFER (all MACs) | Same-machine broadcast does not reach dhcpd (platform limitation, §9d.3) — local tests only; **DORA via the RB3011 PASSED 20 Nov 2026** (separate host, API 8728) | Test from a SEPARATE host on the lagg0 subnet (RB3011 via the API); do not conclude RADIUS failed from a same-machine test |
| mpd5 running even though PPPoE is not enabled (after a titian restart) | The restart replay added an `enable` line under `pppoe-server` in startup-config | `no enable` + `commit` + `save` (check `pppoe.conf` + `pgrep mpd5`) |
| No dhcpd logs anywhere | `log-facility local7` but `/etc/syslog.conf` has no local7 rule | Add a syslog rule for local7 if you need DHCP logs |
### 9d.6 Monitoring IPoE sessions — RADIUS Accounting to myRadDASH (19 Nov 2026)

isc-dhcpd sends no RADIUS accounting, so IPoE (DHCP) sessions do not
appear in myRadDASH automatically. Titian pushes them itself: the
`titian-ipoe-acct.py` script reads active leases (`/var/db/dhcpd.leases`,
last block per IP) and sends Accounting-Request (Start when a lease is
granted, Stop when a lease ends/disappears) to FreeRADIUS at host 84:1813
as NAS `titian-test`. FreeRADIUS writes `radacct` → the session appears
in myRadDASH (`GET /v0/sessions`). No myRadDASH code change is needed.

Commands:

```
show ipoe sessions       # active leases + reported sessions
ipoe push-sessions       # send Start/Stop now (idempotent)
```

Attributes sent: User-Name = MAC, NAS-Identifier = `titian-test`,
NAS-IP-Address = `nas-ip` (from ipoe.conf; falls back to the UDP source
IP), Acct-Session-Id = `ipoe-<mac-without-colons>-<starts-epoch>`,
Framed-IP-Address = lease IP, Calling-Station-Id = MAC,
Acct-Status-Type Start(1)/Stop(2), Acct-Terminate-Cause User-Request(1)
for Stop. Session state lives in `/etc/titian/ipoe-acct-state.json`
(mode 600): one Start per lease, one Stop when the lease disappears or
expires.

Configuration (in `configure-ipoe-server`):

```
radius-server 103.50.129.84
radius-secret <titian-test-NAS-secret>   # from the secret column of nas id 26
nas-ip 103.50.128.18                     # NAS IP (nasname in myRadDASH)
```

Prerequisite: the test machine's DNS must resolve the API domain
(`/etc/resolv.conf` + `/cfg/resolv.conf` containing nameservers 8.8.8.8 +
1.1.1.1 — fixed 19 Nov 2026). Titian service account for the API:
` titian-service@myradash.local` (id 21, role `mitra_admin`, mitra 7);
credentials ONLY in `/etc/titian/myraddash-credentials` +
`/cfg/titian/myraddash-credentials` (mode 600) — never print them.
API login: `POST /v0/auth/login` → body `{"ok": true}` + cookie
`myradash_token` (the guard prefers the cookie, also accepts
`Authorization: Bearer`). **Note:** Cloudflare blocks Python-urllib's
default User-Agent (HTTP 403, error 1010) — Python components MUST set
a proper User-Agent (e.g. `Titian/1.0`).

Proven live 19 Nov 2026: synthetic lease MAC `:01` / IP `.101` →
`ipoe push-sessions` → Start ACKed → the session appeared in `GET
/v0/sessions` (username `:01`, NAS `titian-test`, IP `.101`,
`client_status: active`, source `radius`). After a kick → push again →
Stop ACKed → `GET /v0/sessions` empty (`[]`).

### 9d.7 Kick / disconnect — via SSH with a dedicated key (user decision 19:30 + 19:31)

**CoA is NOT used.** mpd5 does not listen for CoA on port 3799, and
building a CoA listener adds a component; SSH is simpler and more
robust. User decision 19:30: "kalo gak ada coa nya pake via ssh aja"
(if there is no CoA, just use SSH). The kick/disconnect path is:
myRadDASH SSHes into the Titian machine, then runs the local disconnect
command there. (The CoA listener `titian-coa.py` was built + mocked
14/0 as a prototype, but it is NOT the path used — do not deploy it as
the active path.)

**SSH uses a DEDICATED key, not a password** (user decision 19:31).
Passwords are NOT used (the BSDRP image root password is empty, and
password auth cannot be automated safely). A key pair dedicated to
myRadDASH → Titian (not the user's main key):

- Private key: `/root/.ssh/myraddash-titian-kick` on the myRadDASH host
  (84), mode 600. **Never print or share it.**
- Public key: installed in the Titian machine's
  `/root/.ssh/authorized_keys` with a forced `command=` + restrictions,
  so that key can ONLY run kick/disconnect/status commands, not a free
  shell.
- Generate: `ssh-keygen -t ed25519 -f /root/.ssh/myraddash-titian-kick -N "" -C "myradash-titian-kick"` (on host 84; no passphrase so myRadDASH
  can use it non-interactively).
- Install the public key on Titian (one line in `authorized_keys`):
  `command="/opt/titian/sbin/titian-remote-kick.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty <public-key>`
- Titian `known_hosts` on host 84: `/root/.ssh/known_hosts_titian`
  (filled via `ssh-keyscan -p <port> -t ed25519 <titian-ip>`).

The wrapper `titian-remote-kick.sh` (forced command) reads
`SSH_ORIGINAL_COMMAND`, validates strictly (MAC / IPv4 / username),
then dispatches to the backend — it NEVER `eval`s. Allowed commands:
`kick <mac>` · `unblock <mac>` · `disconnect-pppoe <user>
<framed-ip>` · `status` · `leases` · `blocked` · `pppoe-sessions`.
Anything else is REJECTED (including an empty command = an interactive
shell attempt, and injection with `;`, `$(...)`, backticks, `|`, `&&`).

The exact SSH command myRadDASH uses (example, test machine via NAT
port 9393):

```
ssh -i /root/.ssh/myraddash-titian-kick -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/root/.ssh/known_hosts_titian \
  -o ConnectTimeout=10 -p 9393 root@103.50.128.6 "kick 02:00:00:00:00:01"
```

**IPoE kick** (`kick <mac>`): free the DHCP lease via OMAPI (set
state=1 free) + block the MAC (`blocked-mac`, `deny booting` in
dhcpd.conf, which wins over the RADIUS allowlist) + regenerate +
restart dhcpd if running. Same command in klish: `ipoe kick <mac>`;
unblock: `ipoe unblock <mac>` (or via SSH `unblock <mac>`).

**PPPoE disconnect** (`disconnect-pppoe <user> <framed-ip>`) — via
the **mpd5 console (Option A, user decision 20 Nov 12:26)**.
Implementation (`titian-pppoe.sh` `cmd_disconnect` + `mpd_console`):
verify the session exists and the Framed-IP matches via
`show sessions user <user>` → select the link via `authname <user>`
→ `close` (default layer link = LCP, graceful: mpd5 sends an LCP
Terminate-Request, the client brings `tun0` DOWN) → verify the session
is gone via `show sessions user <user>`. Console on `127.0.0.1:5005`,
user `titian-console`, 16-hex password read from a mode-600 file (by
the script, NEVER printed); transport `nc`. Same command in klish:
`pppoe-server disconnect <user> <ip>`. The user is NOT removed from
the config — so the user cannot log in again, myRadDASH must also
isolate the user (status `isolated` in the DB) so the next RADIUS auth
is rejected. Mock: PPPOE-MOCK PHASE I 14/0 (positive + negatives:
no session / IP mismatch / auth failure / session still present /
console OFF / no nc). Live negative test confirmed 20 Nov: with no
active session it fails gracefully with "session not found" (rc=1),
via the script and via klish. **Live positive test PROVEN 20 Nov**: a real `titian-test` session via a vnet jail (IP 10.99.42.100, RADIUS auth + accounting Start) → `pppoe-server disconnect titian-test 10.99.42.100` → rc=0 "disconnected via mpd5 console (close LCP)" → the session disappeared from `show sessions`, a RADIUS Stop was recorded (`acctterminatecause Admin-Reset`), mpd5 kept running, NO black hole (the client immediately redialed and got a new session — proof that connectivity was intact). **PADI note (investigation 20 Nov): the PPPoE server is HEALTHY — PADI from a vnet jail / the RB3011 IS answered (PADO + PADR + PADS + LCP + CHAP). PADI sent from the host ITSELF via bridge0 is NEVER answered — not a server/Titian bug, but a same-host L2 limitation: an outgoing packet from bridge0 never traverses the netgraph `orphans` hook where mpd5 listens; only INCOMING packets from bridge members (jail epair / RB3011 vxlan) reach the listener. So PPPoE tests MUST use a separate client (vnet jail / RB3011), NEVER the host via bridge0. A stale pppoe netgraph node left behind after mpd5 stops is HARMLESS — the next mpd5 reuses it; it is not the cause of unanswered PADI.**

**The server-side (ng0/interface) approach is DECLARED NOT VIABLE
(live test 20 Nov 2026, 6 mechanisms, live vnet-jail session):**
`ifconfig ng0 destroy` → `Invalid argument` (a netgraph interface
cannot be destroyed via ifconfig). `ngctl shutdown ng0:` → the
interface is gone but the bundle stays and the client's `tun0` stays
UP (**black hole**: PPP is up, IP is dead, the client does not know).
`ngctl shutdown <bundle>:` → the bundle is gone but `ng0`/`tun0`
stay UP, and **mpd5 DIES** when the client later disconnects (the
link cleanup crashes into the externally destroyed bundle).
`ngctl shutdown ng0:` + `<bundle>:` → the server is clean but `tun0`
stays UP + **mpd5 DIES**. `ngctl shutdown <link-template>:` → no
effect (it is a template, not the session link). `ifconfig ng0 down`
→ a black hole like `shutdown ng0:`. Root cause: mpd5 owns the session
state; a clean termination (the client bringing `tun0` DOWN) only
happens when mpd5 itself sends an LCP Terminate-Request — and that is
only triggered via mpd5's own control (the console) or by the client
disconnecting. Manipulating netgraph nodes from outside either does
not terminate cleanly (black hole) or crashes mpd5. **Do not implement
a disconnect via ng0/interface.** Details + table: report
`PPPOE-MONITORING-20261119.md` §3.

The correct paths (user decision 20 Nov 12:26): **Option A — the
mpd5 console** (mpd5 itself terminates + sends the LCP
Terminate-Request) — **ALREADY IMPLEMENTED + LIVE POSITIVE TEST PROVEN 20 Nov** (see the PPPoE disconnect paragraph above: mock 14/0, deploy staging == machine, live negative test passed, live positive test passed — the session was disconnected via the console, Admin-Reset, RADIUS Stop recorded, mpd5 alive, no black hole). **Option B — the user closes it via the console themselves**
(the assistant gives the exact commands, the user runs them, the
assistant verifies + restores) — a fallback if Option A has problems.
**Option C — leave it for now** — not chosen (Option A was decided +
implemented).

Proven live 19 Nov 2026 (from host 84 to the test machine): `status`,
`unblock`, `kick` (lease freed via OMAPI + MAC blocked), then
`push-sessions` → Stop ACKed → the session disappeared from myRadDASH
(`[]`). Security rejections proven live: `rm -rf /`, `bash`, SSH with
no command, and injection `kick ...; id` — all rejected (rc=1, no
shell).

### 9d.8 Troubleshooting — monitoring & kick (added 19 Nov 2026)

| Symptom | Cause | Fix |
|---|---|---|
| `show ipoe leases` empty although the lease is in the file | The old lease parser used the unanchored pattern `/binding state /` — the line `next binding state free;` also matched and overwrote the state with `state` (live bug 19 Nov 2026) | Update `titian-dhcp.sh` (anchor the pattern `^[[:space:]]*binding state /`); the mock fixtures now include `next binding state free;` |
| `show ipoe blocked` empty although the block list is empty | `grep -c ... \|\| echo 0` produces `0\n0` (grep -c prints 0 AND exits 1) | Update `titian-dhcp.sh` (use `grep -q` + `wc -l`); see §9d.6 |
| `ipoe push-sessions` fails: `network: [Errno 1] Operation not permitted` | UDP is blocked in the VM sandbox (mock on the VM) | Run the push/mock on the test machine (UDP works there) |
| API login via Python urllib → HTTP 403 (error 1010) | Cloudflare blocks Python-urllib's default User-Agent | Set a proper User-Agent (e.g. `Titian/1.0`); curl is allowed |
| `commit` → `Syntax error ... "commit": Unknown command` | `commit` was sent after `end` (already in enable view) | Correct order: `configure terminal` → (change) → `commit` → `end` → `save` |
| `commit` → `Error: dhcpd failed to start` (but the old dhcpd is still running) | dhcpd restart race: the old instance still holds the port | Stop first (`pkill -x dhcpd`) then `server-start`; or ignore it if the running dhcpd already uses the new config |
| A service restart re-enables IPoE that was already stopped | `/cfg/titian/ipoe.conf` (persistent) still holds the IPoE config from an earlier test, while `/etc/titian/ipoe.conf` is interface+pool only — the service restores from `/cfg` | Align `/cfg/titian/ipoe.conf` to the anchor (interface+pool) so the restore is stable; or remove the IPoE config from startup-config if it is not used |
| SSH kick rejected with `command not allowed` | The command is outside the wrapper allowlist, or SSH was sent with no command | Use one of the 7 allowlist commands (§9d.7); make sure the SSH call carries a command argument |
| `disconnect-pppoe` → `session not found` | No `tun` interface holds that Framed-IP (session not active / wrong IP) | Check the Framed-IP from myRadDASH `radacct`; make sure mpd5 is running + the session is active |

---

## 9e. Dummynet package profiles — per-subscriber bandwidth limits (traffic-shape)

A *package profile* is how BRAS limits bandwidth per subscriber
without writing dummynet *pipes*/*rules* one by one. One profile
(template: *download* + *upload* + *burst* per direction) is *bound*
to an interface or an IP, and Titian derives the dummynet *pipes* +
*rules* automatically. The raw layer (manual *pipe*/*sched*/*queue* /
*rule*, 8 Nov 2026) still exists in the same view; profiles sit on
top of it.

### 9e.1 Concept — profile, bind, materialization

Config file: `/usr/local/etc/traffic-shape.conf` (written by klish,
do not edit by hand). Profile and *bind* lines:

```
profile <name> download <rate> burst <n> upload <rate> burst <n>
bind <profile> interface <if>
bind <profile> ip <addr> on <if> side <uplink|customer>
```

- Profile name: max 12 characters, `[A-Za-z0-9_-]`, first character
  a letter or digit. Longer names are rejected.
- *Rate*: integer + unit — `10Mbit/s`, `512Kbit/s`, `1Gbit/s`
  (no decimals, no bare numbers).
- A profile must be complete (*download* + *upload* set) before it
  can be *bound*. *Bind* needs an existing profile + an existing
  interface.
- Every profile/*bind* change immediately creates/updates the
  derived *pipes* + *rules* in the config (automatic sync).
  Derived objects use deterministic names, max 32 characters:
  *pipe* `<profile>-<slug>-d` (*download*) / `-u` (*upload*);
  *rule* `<profile>-<slug>-down` / `-up`. *Slug*: interface = the
  interface name as-is; IP/CIDR = `.` `:` `/` replaced with `-`
  (e.g. `10.99.42.100/32` → `10-99-42-100-32`). Derived *pipes*
  use the defaults `queue 50 delay 0 plr 0`.
- One profile may have many *binds* (one *bind* = one pair of
  *pipes* + one pair of *rules*). Changing a profile's *rate* /
  *burst* updates all its derived *pipes*. *Unbind* or deleting a
  profile deletes its derived objects too.
- `enable` in the `traffic-shape` view is the master gate: if
  `enable` is not `yes`, *apply* flushes all objects and nothing is
  limited.

### 9e.2 Commands

Enter the `traffic-shape` view from configure mode:

```
configure terminal
traffic-shape            # prompt: (config-traffic-shape)#
```

| Command | Function |
|---|---|
| `enable` / `no enable` | Enable / disable traffic shaping |
| `profile <name>` | Enter the profile view (create if missing) |
| `no profile <name>` | Delete a profile + all its *binds* + derived objects |
| `download <rate>` | Profile *download* limit (in the profile view) |
| `download-burst <bytes>` | *Download burst* in bytes (in the profile view) |
| `upload <rate>` | Profile *upload* limit (in the profile view) |
| `upload-burst <bytes>` | *Upload burst* in bytes (in the profile view) |
| `bind interface <if>` | Apply the profile to one interface/VLAN |
| `bind ip <addr> <if> [side]` | Apply the profile to one IP/CIDR (`side` defaults to `uplink`) |
| `no bind interface <if>` | Remove an interface *bind* (+ its derived objects) |
| `no bind ip <addr> <if>` | Remove an IP *bind* (+ its derived objects) |

*Show* commands (exec mode):

```
show traffic-shape                 # enable + pipe/sched/queue/rule/profile/bind
show traffic-shape profile [name]  # all profiles, or one profile + bind + derived objects
show traffic-shape pipe            # raw pipes (including profile-derived ones)
show traffic-shape rule            # raw rules (including profile-derived ones)
show traffic-shape statistics      # dummynet state (ipfw) + MOVING counters: pf anchor + netstat (ipfw BKT does NOT move — quirk, see §1.10)
```

### 9e.3 Download/upload direction — depends on the bind kind

*Download* = from the internet to the subscriber; *upload* = from
the subscriber to the internet. The derived *rule* direction follows
which side the interface faces:

| Bind | *Download* rule | *Upload* rule |
|---|---|---|
| `bind interface <if>` (interface faces the subscriber) | `out` on `<if>` | `in` on `<if>` |
| `bind ip <addr> <if> side uplink` (default; interface faces *upstream*) | `in` on `<if>`, `dst <addr>` | `out` on `<if>`, `src <addr>` |
| `bind ip <addr> <if> side customer` (interface faces the subscriber) | `out` on `<if>`, `dst <addr>` | `in` on `<if>`, `src <addr>` |

A wrong `side` reverses the direction: the subscriber's *download*
gets limited by the *upload* rate and vice versa. If unsure, check
`show traffic-shape profile <name>` — the derived *rules* print in
full, with direction + `src`/`dst`.

### 9e.4 Burst — honest dummynet semantics

Dummynet *burst* is a BYTE allowance after *idle*, not an extra
sustained speed:

- Effective: `MAX(burst, bw × idle_time)`. After *idle*, up to
  `burst` bytes may bypass the *scheduler* at once (at physical
  link speed); once the allowance is spent, back to the profile
  *rate*.
- Example: 10M + `burst 1000000` = after *idle*, up to 1,000,000
  bytes (≈1 MB) pass at physical link speed, then back to
  10 Mbit/s.
- `burst 0` = no *burst*. *Burst* does not raise the long-term
  average *rate* — do not sell it as a MikroTik-style "burst
  speed"; that is not its semantics.
- *Burst* is counted per *pipe* (per direction, per *bind*), not
  per profile as a whole.

### 9e.5 When pipes enter the kernel — commit, boot, explicit apply

Profile/*bind* changes only rewrite the config file. *Pipes* enter
the kernel when *apply* runs — three paths:

1. **`commit`** (the normal path). Every change marks the config
   dirty; `commit` runs the hook that restarts the *traffic-shape*
   service when the config is dirty (and `enable yes`). If `enable`
   is not `yes`, `commit` flushes all objects instead.
2. **Boot.** The *traffic-shape* service (*rc script*) runs *apply*
   on the config at boot.
3. **Explicit *apply* from the shell** (without `commit`) — to test
   directly or apply without committing:
   ```
   /opt/titian/sbin/titian-traffic-shape.sh apply
   ```
   This is idempotent (safe to repeat); `apply --flush` clears all
   objects + the *anchor*.

Note: the generated pf rules always use `no state` — a plain TCP
`pass` is *stateful* (only the SYN matches the rule; bulk data
follows the *state* and bypasses *dnpipe*). Proven live 13 Nov
2026 (test 11): a *stateful* rule shaped 0, while `no state`
shaped a 10 Mbit/s *pipe* to ~9.5 Mbit/s.

Requirement for traffic to actually be diverted: `/etc/pf.conf`
must reference the `"traffic-shape"` *anchor* (after *scrub*,
before the filter rules). *Apply* warns if the *anchor* is missing,
or if pf is off (then *pipes* are still created but no traffic is
diverted). The ipfw firewall itself is deliberately disabled
(`net.inet.ip.fw.enable=0`) — ipfw only hosts the dummynet *pipes*
here; *filtering* stays with pf (lesson from the 16 Nov 2026
lockout: ipfw enabled with *default-deny* and no rules blocks all
traffic).

### 9e.6 Full examples

Subscriber A — PPPoE 10M, IP `10.99.42.100/32` on `ge0` (uplink),
*burst* 500000:

```
configure terminal
traffic-shape
enable
profile pppoe10
download 10Mbit/s
download-burst 500000
upload 10Mbit/s
upload-burst 500000
bind ip 10.99.42.100/32 ge0
end
configure terminal
commit
save
```

Result in the config (derived automatically):

```
profile pppoe10 download 10Mbit/s burst 500000 upload 10Mbit/s burst 500000
bind pppoe10 ip 10.99.42.100/32 on ge0 side uplink
pipe pppoe10-10-99-42-100-32-d bw 10Mbit/s queue 50 delay 0 plr 0 burst 500000
pipe pppoe10-10-99-42-100-32-u bw 10Mbit/s queue 50 delay 0 plr 0 burst 500000
rule pppoe10-10-99-42-100-32-down in on ge0 pipe pppoe10-10-99-42-100-32-d dst 10.99.42.100/32
rule pppoe10-10-99-42-100-32-up out on ge0 pipe pppoe10-10-99-42-100-32-u src 10.99.42.100/32
```

Subscriber B — 100M for the whole subscriber VLAN `vlan100`:

```
configure terminal
traffic-shape
profile paket100
download 100Mbit/s
upload 100Mbit/s
bind interface vlan100
end
configure terminal
commit
save
```

Derived: *pipes* `paket100-vlan100-d` / `-u` + *rules*
`paket100-vlan100-down` (`out` on `vlan100`) /
`-up` (`in` on `vlan100`).

Removing:

```
configure terminal
traffic-shape
no bind ip 10.99.42.100/32 ge0   # remove one bind (+ its derived objects)
no profile pppoe10               # delete profile + all binds + derived objects
end
configure terminal
commit
save
```

### 9e.7 Verification + measured evidence

```
show traffic-shape profile pppoe10   # profile + bind + derived pipe/rule
show traffic-shape statistics        # moving counters: pf anchor + netstat grow (ipfw BKT does NOT move — quirk)
```

`show traffic-shape statistics` calls `ipfw pipe show` (and
*sched*/*queue*) for dummynet state, plus the counters that move:
pf anchor `traffic-shape` rules and netstat per bound interface.
**Correction (23 Nov 2026):** the BKT Tot_pkt/bytes columns in
`ipfw pipe show` do **NOT** move (stuck at 1 pkt / ~124 bytes even
with 134 thousand packets through the pipe — dummynet display quirk,
proven live 22 Nov 2026). Do not measure throughput from them; if the
pf/netstat counters do not move while traffic exceeds the *rate*, the
*pipe* is not applied yet (see §9e.5) or the *rule* points the wrong
way (see §9e.3).

Measured evidence (21 Nov 2026, dummynet throughput test): profile
`paket8` → **8.001 Mbit/s** (target 8); profile `paket14` →
**14.004 Mbit/s** (target 14) — dummynet works precisely. Method:
Python *UDP flood* (~3.3 Gbit/s *offered*, 1400 B packets) to one
IP *bind* on `ge0` (*burst* 500000); results computed from the
pf anchor rule counters + netstat ge0 (Opkts/Obytes), NOT from the
ipfw BKT columns. Not end-to-end iperf3 (MikroTik does not run
iperf3) — do not claim it as an iperf3 result.

Note: the 100M profile configuration on `vlan100` passes in the
*mock*, but a live 100 Mbit/s *throughput* test through `vlan100`
has NOT been measured — accepted as a machine limitation
(22 Nov 2026); the 100M figure on a VLAN is not measured live.
Mocks: `TRAFFIC-SHAPE-PROFILE-MOCK.sh` 80/0;
`TRAFFIC-SHAPE-MOCK.sh` (raw layer) 20/0.

### 9e.8 Gotchas — troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `bind interface` / `bind ip` rejected: profile incomplete | *Download* or *upload* not set yet | Set `download` + `upload` first, then `bind` |
| `bind` rejected: profile not found | Profile not created yet | Create it first: `profile <name>`, then set the *rates* |
| `bind` rejected: interface not found | Interface name wrong / does not exist | Check `show interfaces terse` |
| `bind ip` rejected: needs an address/CIDR | `bind ip any ...` is not allowed | Use an explicit address or CIDR (e.g. `10.99.42.100/32`) |
| `bind ip` rejected: derived name >32 characters | A 12-character profile + a long IP → the *slug* exceeds 32 | Use a shorter profile name |
| `show traffic-shape profile` shows the profile, but the kernel limits nothing | Not `commit`ted / not *applied* yet (see §9e.5) | `commit` (then `save`), or an explicit *apply* from the shell |
| Committed but still no limiting | `enable` is not `yes` → *apply* flushes instead | `traffic-shape` → `enable` → `commit` |
| Committed + enabled, still no limiting | The `"traffic-shape"` *anchor* is missing from `/etc/pf.conf`, or pf is off | Add `anchor "traffic-shape"` to `/etc/pf.conf` (after *scrub*); make sure pf is active |
| A subscriber's *download* is limited by the *upload* rate (or vice versa) | `side` reversed on `bind ip` | Check the derived *rules* in `show traffic-shape profile <name>`; *rebind* with the correct `side` (`uplink` vs `customer`, see §9e.3) |
| `ipfw pipe <n> show` prints nothing | The object really does not exist — this command returns rc 0 EVEN for objects that do not exist | Check existence from the OUTPUT, not from the rc |
| Kernel log `do_config invalid delete type 3` during *apply* | Used to be: *flush* deleted objects that did not exist (bug, before 19 Nov 2026) | Already fixed — *flush* only deletes objects that exist (checked from OUTPUT). If it still appears, report it |

---

## 10. System, DNS, and SSH — usage flows

### 10.1 Identity and time

```
configure terminal
system hostname router-01
system time-zone WIB
end
save
```

Zone choices from the tree: WIB, WITA, UTC (plus island aliases Java, Bali,
Singapore, Malaysia — type `system time-zone ?` for the full list).
Project rule: host and application container time zone = GMT+7
(Asia/Jakarta/WIB) for servers/applications.

### 10.2 Sysctl

```
configure terminal
system sysctl net.ipv4.ip_forward 1
end
save
show system sysctl     # exec: values + meaning of each key managed by Titian
```

Deleting: `no system sysctl net.ipv4.ip_forward` (the live value returns to
the value before Titian set it, or stays per the key's behavior).

### 10.3 DNS

```
configure terminal
system domain-name example.net
system name-servers
nameserver 192.0.2.53
nameserver 198.51.100.53
exit
end
save
```

Deleting: `no system domain-name`, `no nameserver <ip>` (in the
name-server view).

### 10.4 SSH service

```
configure terminal
service ssh
port 2222
no allow-root
exit
end
save
```

### 10.5 Non-root view (info-mode)

For users without privileged rights, a limited view is available: `ping`,
`traceroute`, overview, and startup. This view deliberately contains no
configuration commands — it only reads and tests connectivity.

### 10.6 Console log (syslog) — disabled in the image

FreeBSD by default sends `*.err`, `kern.warning`, `auth.notice` to
`/dev/console` (`/etc/syslog.conf` line 7). As a result, konfd logs after a
restart, kernel messages (`bridge0: promiscuous mode`, etc.), and other
daemon errors appear on the monitor/terminal and disturb work at the console.

In the Titian/BSDRP image that line is **removed** — the console is clean,
logs still go to files (`/var/log/messages`, `/var/log/daemon.log`, etc.).
The file: `files/BSDRP/Files/etc/syslog.conf` (image overlay; copied to
`/etc/syslog.conf` at build). Emergency messages (`*.emerg`) are still
announced to all logged-in users (the `*.emerg *` line is kept).

On a machine that is already running, the fix is: copy the file above to
`/etc/syslog.conf` then `service syslogd reload`. To survive a
reboot (because `/etc` = tmpfs), save a copy at `/cfg/syslog.conf`
and add a hook in `/cfg/rc.local`:

```
if [ -f /cfg/syslog.conf ]; then cp /cfg/syslog.conf /etc/syslog.conf; service syslogd reload; fi
```

---

## 11. Tuning — brief usage

All tuning commands live in the interface view (`options`, §3.4) plus
three direct commands in the interface view: `mtu`, `qlen` [Linux],
`speed` [Linux]. Checking: `show interfaces tuning <iface>`.

Suggested flow:

```
show interfaces tuning enp1s0     # see current values + meanings
configure terminal
interface ethernet enp1s0
mtu 9000
options
tso on
gro on
rx-usecs 125
exit
exit
end
save
```

The `titian-tune-recommend` tool (host, read-only) gives recommendations
before changing anything. `no <setting>` always restores the
pre-Titian value; the live value persists until reboot for `speed` because
the driver does not restore the old value.

---

## 12. Per-OS differences and known limitations

| Item | Linux (Debian) | FreeBSD |
|---|---|---|
| Ethernet interface | `enp*`, `eth*`, `enx*` | `vtnet*`, `em*`, `igb*`, etc. |
| VLAN | `interface vlan <parent>.<id>` | `interface vlan <id> <parent>` |
| Aggregation | bonding (`bond0`, mode 802.3ad/round-robin) | lagg (`lagg0`, `laggport`) |
| Tuning | mtu/qlen/speed + full options | mtu + options subset (tso/lro/rx/tx) |
| IPv6 peer on eth/vlan/lagg/loopback | supported | no (without peer) |
| VXLAN dstport | required 4789 | stays 4789, other values rejected |
| Firewall backend | nftables | pf anchor (limitations §8.5) |
| Persistent rename | systemd `.link` | `#-TITIAN-RENAME-#` block in rc.conf |
| Sysctl persistence | `sysctl.d/99-titian.conf` | `#-TITIAN-#` block in sysctl.conf |

Known limitations (Notes: not promises):

- PTY Tab/`?` not yet verified on all real SSH terminals.
- FreeBSD VLAN creation intermittently fails (`SIOCIFCREATE2`, root cause not
  yet isolated) — repeat the command if it happens.
- `route-dev` and `vxlan-group-dev` rewrites via rename only tested at
  script level, not end-to-end via CLI.
- BFD-over-BGP single-hop over the management interface not tested.
- VXLAN multicast end-to-end not proven (FreeBSD does not join the group).
- Live coalesce (`rx-usecs`) not proven on the lab NIC.
- `reboot` in the CLI only prints text, it does not reboot the machine.
- `show firewall` inside the firewall view = Unknown (must `exit` first).
- `save` inside configure view = Unknown (must `end` first).
- Bare `configure` = Incompleted (use `configure terminal`).
- Entering an interface view creates a persistent section (see §2.1).

---

## 13. End-to-end example flows

### 13.1 PtP interface + static route + save + checkpoint

```
sudo /usr/local/bin/titian
show interfaces terse
configure terminal
interface ethernet enp1s0
description "uplink ke ISP"
ip address 192.0.2.10/31 peer 192.0.2.11
mtu 1500
exit
ip route 198.51.100.0/24 192.0.2.11
end
save
checkpoint save pra-ubah
show running-config
```

### 13.2 VLAN + address + verification

```
configure terminal
interface vlan enp1s0.100
description "VLAN pelanggan"
ip address 198.51.100.1/24
ipv6 address 2001:db8:100::1/64
exit
end
save
show interfaces vlan enp1s0.100 detail
ping 198.51.100.2 repeat 4
```

### 13.3 Risky change with a safety net

```
checkpoint save sebelum-firewall
configure terminal
firewall
filter forward permit proto tcp src 198.51.100.0/24 dst any sport any dport 443 in enp1s0 out any
snat 198.51.100.0/24 to masquerade out enp1s0
exit
end
save
show firewall
```

If something goes wrong: `rollback sebelum-firewall` (then `save` if
you want that state to be the permanent one).

---

## 14. Titian feature inventory + test status (13 Nov 2026)

One-by-one list of features already built (40 XML, 29 `sbin/`
scripts), with test status. Legend: ✅ = PASSED LIVE (verified
end-to-end on the test machine); 🟡 = PARTIAL (exists but not fully
— e.g. function-test only, via script not CLI, or some
sub-features not yet); ❌ = NOT YET (command exists, not tested live).

| # | Feature | File | Status | Notes |
|---|---|---|---|---|
| 1 | BGP — neighbor, filter, attributes (BIRD) | conf-bgp.xml, titian-bgp.sh, bird.xml | ✅ LIVE | E2E to RB3011 PASSED 13 Nov ~02:35: Established, route exchange, prepend 2, MED 50, local-pref 100, community 65000:100, filter F-RB3011-IN |
| 2 | BIRD — show route/protocol, reload | bird.xml, titian-bird.sh | ✅ LIVE | Sweep 13 Nov ~00:11, 0 syntax errors |
| 3 | FRR — enable, router-id, log, show | conf-frr.xml, titian-frr.sh | 🟡 PARTIAL | CLI + mutual exclusion vs BIRD tested (rc=33 both ways). Daemon NEVER ran live; BGP via FRR (vtysh) NOT tested — see §9c |
| 4 | Ethernet interface (IP/IPv6, desc, dhcp) | conf-if-eth-fbsd.xml | ✅ LIVE | xe3 (SFP, 10.99.31.1/24 + IPv6), ge0-3 after rename |
| 5 | VLAN interface | conf-if-vlan-fbsd.xml | ✅ LIVE | vlan 99 ge3 |
| 6 | VXLAN interface | conf-if-vxlan-fbsd.xml | ✅ LIVE | vxlan100, ping 0% loss both directions |
| 7 | L2 bridge interface | conf-if-bridge-fbsd.xml | ✅ LIVE | bridge0 (vxlan100 + vlan99) |
| 8 | LAGG / LACP interface | conf-if-lagg-fbsd.xml | ✅ LIVE | LACP E2E + IPv4/IPv6 PASSED 12 Nov |
| 9 | Loopback interface | conf-if-lo-fbsd.xml | ✅ LIVE | PASSED 13 Nov ~14:20 (lo1 10.99.88.1/32 shows in show + ifconfig; `no interface loopback lo1` clean) |
| 10 | Interface options (tso/lro/rx/tx) | conf-if-opt-fbsd.xml | ✅ LIVE | PASSED 13 Nov ~14:20 (xe3: `rx off` changed options 4e100bb→4c100ba, `rx on` back; `tso off` accepted, ixl NIC does not expose TSO) |
| 11 | Static route / gateway (v4 + v6) | conf-route-fbsd.xml, conf-route6.xml | 🟡 PARTIAL | `ip route ... dev bridge0` PASSED 13 Nov (shows in show + netstat, delete PASSED). `forward` FAILED — param bug (IP_ADDR, not SUBCOMMAND) — **fixed in repo** (forward became a subcommand + `gateway`), not yet retested live |
| 12 | Firewall / NAT (pf) | conf-fw.xml | ❌ NOT YET | pf.ko EXISTS + LOADED on the test machine (not "not in the image" — old claim was wrong). Live test BLOCKED by proxy outage 13 Nov 14:33 |
| 13 | Traffic-shape / dummynet limiter + package profiles | traffic-shape.xml | ✅ LIVE | Function-test (staged, full masks); profile mock 80/0, raw-layer mock 20/0. **Package profile model DONE 20 Nov 2026** (profile + bind + automatic derived objects). **Live throughput test PASSED 21 Nov 2026**: profile `paket8` → 8.001 Mbit/s (target 8), `paket14` → 14.004 Mbit/s (target 14), measured from the dummynet *pipe counter* (UDP flood). Detail: §1.10 + §9e. Honest limitation: 100M throughput through `vlan100` NOT yet measured live (mock only). |
| 14 | PPPoE server (mpd5, pool, user, RADIUS) | conf-pppoe.xml | ✅ LIVE | **PASSED 15 Nov (local auth)**: E2E RB3011, CHAP, client got 10.99.42.100, ping 5/5. **PASSED 19 Nov (RADIUS via myRadDASH)**: mpd5 → FreeRADIUS host 84, CHAP, Access-Accept, IP 10.99.42.100; wrong password → Access-Reject (no IP). Key: RADIUS backend enabled via `set auth enable radius-auth` (not `set auth enable radius` — INVALID on mpd5 5.9; `set radius server` alone does not enable the backend); myRadDASH radcheck uses op `:=` (not `==`). Note: ping to 10.254.254.1 from the local client fails (same-machine route conflict, not RADIUS); RB3011-as-client test pending (RB3011 SSH key rejected after v7.25.1 upgrade). BRAS detail: §9d.2. |
| 15 | IPoE server (DHCP) | conf-ipoe.xml | ✅ LIVE | **PASSED 13 Nov**: RB3011 (DHCP client) bound 10.99.41.100/24, gw 10.99.41.1, DNS 8.8.8.8, ping 3/3. Initial failure root cause: empty RB3011 VTEP (broadcast broken) — v7 syntax fix `/interface vxlan vteps add interface=vxlan100 remote-ip=10.10.2.3`. **PASSED 19 Nov (RADIUS MAC-auth via myRadDASH)**: RADIUS verification at generate — MAC `02:00:00:00:00:01` Access-Accept, `:03` Reject + excluded from the allowlist; dhcpd.conf contains only subclass `:01`, pool allow, deny unknown-clients; dhcpd running. Mock IPOE-RADIUS 33/0. The end-to-end DHCP client test (DORA) is NOT proven — same-machine broadcast does not reach dhcpd (a platform limitation, not RADIUS). BRAS detail: §9d.3. |
| 16 | WireGuard | conf-wireguard.xml | ❌ NOT YET | `ifconfig wg` not tested live yet |
| 17 | Monitoring (SNMP, node/bird-exporter, nfacctd) | conf-monitoring.xml | ✅ LIVE | **PASSED 13 Nov**: `snmp enable` + test community + `commit` → snmpd pid 46802, listening 161/udp, snmpget sysDescr OK; `no snmp enable` + community back to bsdrp-ro, snmpd stopped |
| 18 | System (hostname, timezone, sysctl) | conf-sys.xml | ✅ LIVE | **PASSED 13 Nov**: hostname/time-zone/sysctl `net.inet.tcp.delayed_ack` 1→0→1 verified; localtime deleted again |
| 19 | DNS (domain-name, name-servers) | conf-sys-dns.xml | ✅ LIVE | **PASSED 13 Nov**: nameserver 8.8.8.8 in resolv.conf; `no nameserver` back to baseline |
| 20 | SSH service (port, allow-root) | conf-serv-ssh.xml | 🟡 PARTIAL | SSH running (OS-level, port 9393 via NAT); klish `service ssh` command not yet verified live (BLOCKED by proxy outage 13 Nov 14:33) |
| 21 | Checkpoint / rollback | en-checkpoint.xml | ✅ LIVE | **PASSED 13 Nov**: `checkpoint save` + change xe3 description + `rollback` restored + `checkpoint delete`; BGP bounced briefly then re-Established |
| 22 | Rename interface | en-rename.xml | 🟡 PARTIAL | Rename igb→ge / ixl→xe PASSED live via script (SSH); CLI `rename` command FAILED via CLI (BLOCKED by proxy outage 13 Nov 14:33) |
| 23 | Terminal / pager (length, no-more) | en-terminal.xml | ✅ LIVE | Pager `less`, sweep 13 Nov 0 syntax errors |
| 24 | Show (basic, interface, routing, system, hardware) | en-show.xml, en-show-hw.xml, en-show-routing.xml, en-show-if-*.xml | ✅ LIVE | Sweep 13 Nov ~00:11, all show commands work, 0 syntax errors |
| 25 | Ping / traceroute | ping.xml | ✅ LIVE | **PASSED 13 Nov**: ping 10.99.40.2 5/5 0% loss ~0.3 ms; ping 8.8.8.8 5/5 ~28 ms; traceroute 1 hop. Cosmetic bug "expr: syntax error" 2x **fixed in repo** (dropped `expr substr`, using direct conditional) |
| 26 | Commit / commit check / save | conf-commit.xml, enable-mode.xml | ✅ LIVE | Commit + save extensively tested (including the 13 Nov 13:55 save that synchronized bgp.conf) |
| 27 | Boot replay / startup-config | startup.xml, titian-boot.sh, titian-cfg.sh | ✅ LIVE | Boot replay PASSED (5th reboot); /cfg persistence PASSED |
| 28 | Factory reset | en-factory-reset.xml | ⏳ STAGING | Hermetic mock 19 Nov: 41 PASS / 0 FAIL (arm deletes nothing, confirm deletes exactly + restores from sample + backup restores, write-memory still absent); not yet tested live — needs a backup-first test plan |
| 29 | Titian update | en-update.xml | ⏳ STAGING | Hermetic mock 19 Nov: 41 PASS / 0 FAIL (check 3 statuses + fetch fallback + numeric comparison 0.10.0>0.9.0; arm changes nothing; install-confirm succeeds via 2 checksum sources + refuses 8 failure conditions; config verification detected); not yet tested live — needs a backup-first test plan |

**Most open (next test priorities):** FRR live (daemon +
BGP via vtysh, §9c.5) · WireGuard · firewall/NAT ·
traffic-shape · static route `forward` (fix in repo, not
yet retested live) · rename CLI · SSH service. All BLOCKED by VM SSH
proxy outage since 13 Nov 14:33 (still down 14:57). PPPoE (row 14)
already PASSED 15 Nov (local) + 19 Nov (RADIUS via myRadDASH).

> **Count update (13 Nov ~15:00, after live tests 1–10):**
> of the 27 rows above, ✅ LIVE = **19**, 🟡 PARTIAL =
> **5** (FRR, static route, traffic-shape, SSH, rename), ❌
> NOT YET/FAILED = **3** (firewall/NAT, PPPoE FAILED, WireGuard).
> Before testing: 11/7/9. Test details: `~/workspace/
> titian-live-test-20261113/HASIL.md` (on the VM, not in the repo).
>
> **Correction 19 Nov (PPPoE + RADIUS PASSED):** PPPoE row 14 is now
> ✅ LIVE (local 15 Nov + RADIUS 19 Nov) — counts are now ✅ LIVE =
> **20**, ❌ NOT YET/FAILED = **2** (firewall/NAT, WireGuard).
>
> **Correction 23 Nov 2026 (repo batch, no deploy — live verification
> deferred until after the Part 6 recording):**
> - Row 12 (firewall/NAT): repo integration is already complete (XML +
>   apply backend + commit/boot hooks + guide §8); only proof + live
>   test were missing. New staging proof: `FW-APPLY-MOCK.sh` 16/0.
>   Live test (filter permit/deny + SNAT masquerade + DNAT on a
>   non-mgmt interface, guards §8.6–§8.7) still needs a live wave.
> - Row 13 (traffic-shape): `show traffic-shape statistics` now shows
>   the MOVING counters (pf anchor + netstat); the ipfw BKT column is
>   declared a quirk (does not move, proven live 22 Nov).
>   `TRAFFIC-SHAPE-STATS-MOCK.sh` 10/0. Live shaped test deferred.
> - Row 20 (SSH service): syntax completed — `no port` (reset to 22)
>   + Tab-completion of service names in `show service status`.
>   `SERVICE-MOCK.sh` 15/0. Live `service ssh` test still NOT YET.
> - Row 21 (checkpoint/rollback): rollback from NEW points is now
>   byte-identical (startup-header + /cfg mirror).
>   `CHECKPOINT-HEADER-MOCK.sh` 14/0. Live verification (save →
>   change → rollback → empty diff) deferred until after the Part 6
>   recording.

---

## Closing

This document describes the CLI surface matching the tree in this
repository (`tree/` + `tree-nonroot/`). If a command in an interactive
session is not here, `?` at that position is the source of truth —
the tree is the CLI definition, this document is its summary.

Related documents in the repo: `PANDUAN.md` (installation from release
packages + basic usage), `README-panjang.md` (project overview + layout +
features). Installation from packages: see Releases.
