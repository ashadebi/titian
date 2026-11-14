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
  running-config to startup-config in `/opt/titian/etc/startup-config`).
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
show service status <name>    # init command for a specific service
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

Long output (`show running-config`, `show startup-config`) is shown in
stages through the `less` pager (not dumped all at once). Inside the pager:
`SPACE` = next page, `ENTER` = next line, `q` = quit, `/text`
= search. If the output fits on one screen, the pager finishes immediately
with no pause.

```
show running-config          # in stages (pager)
show running-config no-more  # no pager, dump everything at once
show startup-config no-more  # same for startup-config
terminal length 24           # pager active (default 24 lines)
terminal length 0            # pager off (all output dumped)
terminal no-more             # same as terminal length 0
terminal more                # pager active again (length 24)
```

Note: the pager is only active when output goes to an interactive terminal
(TTY). If output is piped or scripted (not a TTY), the pager is
automatically disabled and output is dumped in full — safe for automation.

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
not been tested yet; BFD direct (OSPF) and multihop-BGP have been verified
in the lab.

---

## 8. Firewall view — filter, SNAT, DNAT (IPv4 only)

Enter from configure:

```
firewall
```

Note: `show firewall` exists only in exec mode (showing the rule list in
priority order + live backend dump + forwarding status). Inside the
firewall view, `show firewall` = Unknown command — `exit` first.

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

Point names: `[A-Za-z0-9_-]+`. A snapshot contains running-config + bird.conf
+ bird.d + netstate + sysctl + meta, in
`/opt/titian/etc/checkpoints/<name>/`.

### 9.2 Rollback

```
rollback <name>   # return to a named checkpoint point
rollback          # without a name = return to startup-config
                  # (discarding unsaved running changes)
```

Rollback is PERSISTENT and restarts the service. Safe order before a
risky change: `checkpoint save pre-change`, make the change, if it fails
`rollback pre-change`, if it succeeds `save`.

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

---

## 9a. IPoE — DHCP client & server

**Important note:** mpd5 does NOT support IPoE. mpd5 is a PPP daemon
(PPPoE/PPTP/L2TP). IPoE is plain IP over Ethernet, i.e. DHCP —
no PPP session, no username/password. Titian implements IPoE
via DHCP: `dhclient` (client) and `isc-dhcpd` (server), both already
present in the image.

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
| `accept <prefix>` | Accept this prefix |
| `reject <prefix>` | Reject this prefix |
| `accept community <AS:NN>` | Accept routes with this community |
| `reject community <AS:NN>` | Reject routes with this community |

A filter always ends with `reject;` (default-deny). A filter name may
contain `-` in the CLI, but it is generated as `_` in bird.conf
(BIRD rejects `-` in identifier names).

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
| Basic config (router-id, log) | Yes (`router-id`, via bird.conf) | Yes — directly via `vtysh` + `write memory` |
| Show status/version | Yes (`show bird`, `show route`) | Yes (`show frr`, `show frr version`) |

FRR routing protocol configuration (BGP neighbor, route-map,
prefix-list, community, local-pref, MED, AS-path prepend) is done
**directly in `vtysh`** (the `cli` command in Titian enters vtysh),
not via klish. Native FRR model: config via vtysh applies
immediately (running) + `write memory` to persist it to
`/usr/local/etc/frr/frr.conf`. The FRR daemon itself supports all
those features (route-map, prefix-list, standard/large community,
local-pref, MED, prepend) — only the path is vtysh, not klish.

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

### 9c.2 Basic config via klish (direct vtysh + write memory)

```
configure terminal
router frr
router-id 10.99.40.1
log syslog
write-memory
exit
end
```

| Command | Meaning |
|---|---|
| `router-id <IPv4>` | FRR router ID (used by OSPF/BGP) — directly via vtysh + `write memory` |
| `no router-id` | Delete router-id |
| `log syslog` / `no log syslog` | Log FRR to syslog / turn off |
| `write-memory` | Write FRR running-config to `/usr/local/etc/frr/frr.conf` (persistent) |

These commands apply **immediately** (they do not wait for `commit`) —
only enable/disable waits for `commit`.

### 9c.3 Show

```
show frr
show frr version
```

`show frr` shows version, intent, `frr_enable` in rc.conf,
service status, and the `zebra` pid if running. `show frr version`
shows version + `vtysh show version` output.

### 9c.4 BGP via vtysh — example (not klish)

Enter vtysh via the `cli` command in Titian, then configure
BGP as usual in FRR (eBGP example to RB3011, AS 65001 — exact
equivalent of the BIRD configuration in §9b.1):

```
! in vtysh (via `cli`)
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

### 9c.5 Test status (honest)

- FRR CLI (enable, router-id, log, write-memory, show) **exists** and
  mutual exclusion vs BIRD **has been tested** (fails rc=33 both ways).
- Package `frr10-10.7.1_1` is installed in the image, the `frr` rc script exists.
- **FRR as a routing daemon has NEVER run live** (13 Nov
  2026): no `zebra`/`bgpd`/`ospfd` processes, no
  `frr.conf`, `frr_enable` not in rc.conf. All E2E BGP tests to
  RB3011 so far used BIRD, not FRR.
- Open FRR live tests: enable FRR (BIRD off first,
  §9c.1) → BGP via vtysh to RB3011 (§9c.4) → verify session
  Established + route exchange + attributes (like the BIRD test §9b) +
  verify `show ip route` contains kernel routes (quirk §9c.4).

**References:**
- FreeBSD port `net/frr10`, official rc script: https://raw.githubusercontent.com/freebsd/freebsd-ports/main/net/frr10/files/frr.in
- BSDRP User Guide (choose Bird or FRRouting): https://bsdrp.net/documentation/end-users_docs
- BSDRP lab (BGP/OSPF/RIP/ISIS/BABEL with FRR): https://bsdrp.net/documentation/examples/simple-bgp-rip-ospf-lab/
- BSDRP lab (route-reflector + confederation Bird 3 + FRR 10): https://bsdrp.net/documentation/examples/bgp-route-reflector-and-confederation-using-frr-and-bird/
- Official FRR 10.0 docs (BGP): https://docs.frrouting.org/en/stable-10.0/bgp.html
- Official FRR 10.0 docs (route-map): https://docs.frrouting.org/en/stable-10.0/routemap.html
- FRR issue #17113 (`show ip route` does not show kernel routes on FreeBSD): https://github.com/FRRouting/frr/issues/17113

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
| 13 | Traffic-shape / dummynet limiter | traffic-shape.xml | 🟡 PARTIAL | Function-test (staged, full masks); live E2E test BLOCKED by proxy outage 13 Nov 14:33 |
| 14 | PPPoE server (mpd5, pool, user, RADIUS) | conf-pppoe.xml | ❌ FAILED | **FAILED 13 Nov**: LCP + auth OK, but mpd5 sends PADT terminate before IPCP (root cause not found, needs verbose logging). `!` escaping bug + `no user` **fixed in repo**, retest pending proxy |
| 15 | IPoE server (DHCP) | conf-ipoe.xml | ✅ LIVE | **PASSED 13 Nov**: RB3011 (DHCP client) bound 10.99.41.100/24, gw 10.99.41.1, DNS 8.8.8.8, ping 3/3. Initial failure root cause: empty RB3011 VTEP (broadcast broken) — v7 syntax fix `/interface vxlan vteps add interface=vxlan100 remote-ip=10.10.2.3` |
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

**Most open (next test priorities):** FRR live (daemon +
BGP via vtysh, §9c.5) · PPPoE (FAILED — terminate root cause not found,
needs verbose mpd5 logging) · WireGuard · firewall/NAT ·
traffic-shape · static route `forward` (fix in repo, not
yet retested live) · rename CLI · SSH service. All BLOCKED by VM SSH
proxy outage since 13 Nov 14:33 (still down 14:57).

> **Count update (13 Nov ~15:00, after live tests 1–10):**
> of the 27 rows above, ✅ LIVE = **19**, 🟡 PARTIAL =
> **5** (FRR, static route, traffic-shape, SSH, rename), ❌
> NOT YET/FAILED = **3** (firewall/NAT, PPPoE FAILED, WireGuard).
> Before testing: 11/7/9. Test details: `~/workspace/
> titian-live-test-20261113/HASIL.md` (on the VM, not in the repo).

---

## Closing

This document describes the CLI surface matching the tree in this
repository (`tree/` + `tree-nonroot/`). If a command in an interactive
session is not here, `?` at that position is the source of truth —
the tree is the CLI definition, this document is its summary.

Related documents in the repo: `PANDUAN.md` (installation from release
packages + basic usage), `README-panjang.md` (project overview + layout +
features). Installation from packages: see Releases.
