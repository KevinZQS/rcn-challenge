# RCN Challenge Lab

Containerlab topology for CSCI 5840. Nine Arista cEOS routers/switches, four
hosts, a web server, and a monitoring stack. Device configuration is generated
from YAML through Jinja2 — **the YAML is the source of truth, not the device.**

---

## Topology

```
          H1  H2                H3  H4(v6-only)
           \  /                  \  /
            S1 ────────────────── S2          ← pure L2, 802.1Q trunk, VLANs 10/20/30
            │                      │
            R1                     R2          ← VLAN gateways; R2 runs DHCP
            │                      │
            S3 ────────────────── S4          ← IS-IS ↔ OSPF redistribution boundary
            │                      │
            R3 ────────────────── R4          ← OSPF core
             \                    /
              \                  /
                     R5                        ← eBGP PE (AS 65100)
                      │
                  WebServer
```

| Link | IPv4 | IPv6 |
| --- | --- | --- |
| R1–S3 | 10.20.0.0/30 | 2001:db8:2000:1::/64 |
| R2–S4 | 10.20.0.4/30 | 2001:db8:2000:2::/64 |
| S3–S4 | 10.20.0.8/30 | 2001:db8:2000:3::/64 |
| S3–R3 | 10.20.0.12/30 | 2001:db8:2000:4::/64 |
| S4–R4 | 10.20.0.16/30 | 2001:db8:2000:5::/64 |
| R3–R5 | 10.20.0.20/30 | 2001:db8:2000:6::/64 |
| R4–R5 | 10.20.0.24/30 | 2001:db8:2000:7::/64 |
| R3–R4 | 10.20.0.28/30 | 2001:db8:2000:8::/64 |

On every p2p link the **lower-numbered / switch side takes `.1` (or `::1`)**.

| LAN | VLAN | IPv4 | IPv6 | Gateway |
| --- | --- | --- | --- | --- |
| Users A | 10 | 10.10.10.0/24 | 2001:db8:1000:10::/64 | R1 |
| Users B | 20 | 10.10.20.0/24 | 2001:db8:1000:20::/64 | R1 |
| Users C | 30 | *(none — IPv6 only)* | 2001:db8:1000:30::/64 | R2 |
| Web | — | 10.30.0.0/24 | 2001:db8:3000:100::/64 | R5 |
| Management | — | 172.20.20.0/24 | — | containerlab |

Loopbacks: `10.255.0.<n>/32` and `2001:db8:ffff::<n>/128`, where n = 1–5 for
R1–R5, 13 for S3, 14 for S4. S1 and S2 have none.

## Routing design

| Layer | Protocol | Devices |
| --- | --- | --- |
| Access | IS-IS, **level-2 only**, both address families | R1, R2, S3, S4 |
| Core | OSPFv2 (IPv4) + OSPFv3 (IPv6), area 0 | S3, S4, R3, R4 |
| Edge | eBGP, AS 65000 ↔ AS 65100, both families | R3/R4 ↔ R5 |

**S3 and S4 are the redistribution boundaries.** IS-IS ↔ OSPF both ways, using
route tags **110** and **115** to prevent loops: routes learned from one
protocol are tagged, and the tag is denied on the way back.

S3 and S4 also carry `distance ospf external 120` under `ipv6 router ospf 1`.
Without it, an OSPFv3 external (AD 110) beats the device's own IS-IS route
(AD 115) and IPv6 traffic loops. **Do not remove this.**

R3 and R4 originate a default into the IGP from BGP; R5 advertises
`10.30.0.0/24` and `2001:db8:3000:100::/64`.

## DHCP

Runs on **R2** for all three VLANs. R1 owns the VLAN 10 and 20 gateways, so it
**relays** with `ip helper-address 10.20.0.5` (R2's Ethernet2). VLAN 30 is
served directly because R2 owns that gateway.

IPv4 gateways come from the DHCP `default-gateway` option. **IPv6 gateways
always come from Router Advertisements — DHCPv6 never hands out a gateway.**
VLAN 30 sets `ipv6 nd managed-config-flag` and advertises the prefix
`no-autoconfig`, so H4 gets its *address* from DHCPv6 and its *default route*
from R2's RA. SLAAC is off on that VLAN, so if DHCPv6 fails H4 has no global
address at all.

---

## Free address space — use these for anything new

| Resource | Next free |
| --- | --- |
| p2p IPv4 | `10.20.0.32/30`, then .36, .40, … |
| p2p IPv6 | `2001:db8:2000:9::/64`, then `:a::`, `:b::`, … |
| Loopback IPv4 | `10.255.0.6`–`.12`, `.15`+ |
| Loopback IPv6 | `2001:db8:ffff::6`–`::12`, `::15`+ |
| New LAN IPv4 | `10.40.0.0/16` (unused) |
| New LAN IPv6 | `2001:db8:4000::/36` (unused) |
| VLAN IDs | 40, 50, 60 … |
| BGP ASN | 65200+ |

Do not invent addresses outside these ranges — everything else is in use.

---

## File layout

```
rcn.clab.yaml            the topology: nodes, images, links        SOURCE
nsot/data/<DEV>.yml      per-device intent                         SOURCE  ← edit here
nsot/templates/*.j2      Jinja2, one per vendor                    SOURCE
nsot/scripts/render.py   YAML + template -> nsot/configs/
nsot/configs/<DEV>.cfg   rendered output                           GENERATED
configs/<DEV>.cfg        what containerlab loads at boot           COPY of the above
configs/telegraf.conf    written by generate_configs.sh            GENERATED, gitignored
configs/grafana/         datasources + provider written at deploy   GENERATED, gitignored
tools/reach.py           eAPI: read, apply, pull, drift-check
deploy.py                full fresh start, one command
challenge_check.sh       walks the whole pre-class checklist
verify_layout.sh         file integrity, before deploying
```

**`nsot/configs/` and `configs/` must both be updated.** `render.py` writes the
first; containerlab reads the second. After rendering, copy across:
`cp nsot/configs/*.cfg configs/`

Never hand-edit anything marked GENERATED — change the YAML and re-render, or
the source of truth stops being true.

---

## The two workflows — pick the right one

### Config change on an existing device — SECONDS

No redeploy. Edit intent, render, push, verify:

```bash
# 1. edit nsot/data/R3.yml
cd nsot && python3 scripts/render.py R3 && cd ..
cp nsot/configs/R3.cfg configs/

# 2. push just the changed lines over eAPI (no CLI)
./tools/reach.py --apply "interface Ethernet2" "description NEW_DESC" --save R3

# 3. verify
./tools/reach.py --drift R3
```

### Topology change — new node or new link — ~4 MINUTES

Needs a full redeploy because containerlab has to create containers and veths:

```bash
# 1. nsot/data/R6.yml          new device intent
# 2. cd nsot && python3 scripts/render.py && cd .. && cp nsot/configs/*.cfg configs/
# 3. rcn.clab.yaml             add the node AND its links
# 4. python3 deploy.py         ~3m45s
# 5. ./tools/reach.py --health
```

---

## Verification

```bash
./tools/reach.py                # can I reach all 9 programmatically?
./tools/reach.py --health       # adjacencies, routes, CPU — one table
./tools/reach.py --drift        # is my intent still live on every device?
./challenge_check.sh            # the full pre-class checklist
./demo_proof.sh                 # dual-stack end-to-end, H1 and H4
```

`--health` is the one to run **before** anything breaks, so you know what
normal looks like. Expected baseline:

| | BGPv4 | BGPv6 | OSPFv2 | OSPFv3 | IS-IS |
| --- | --- | --- | --- | --- | --- |
| R1, R2 | - | - | - | - | 1 |
| S1, S2 | - | - | - | - | - |
| S3, S4 | - | - | 2 | 2 | 2 |
| R3, R4 | 1 | 1 | 2 | 2 | - |
| R5 | 2 | 2 | - | - | - |

A `0` in an OSPF column means "configured but no adjacency". A `-` means
"not configured". They look similar and mean very different things.

---

## Gotchas — all of these cost real time to rediscover

**Recovery takes ~21–30 seconds after a link is restored.** That's spanning-tree
listening + learning on an access port. Do not conclude a fix failed until 30
seconds have passed.

**Container IPs change on every deploy.** Never hardcode them. `reach.py` and
`generate_configs.sh` both discover them via `docker inspect`. NMAS is the one
exception — it is pinned to `172.20.20.13` in the topology, because every
device config hardcodes that as its SNMP and syslog target.

**On cEOS, chained `Cli -c` loses config-mode context.** Use a heredoc:
`docker exec -i clab-rcn-challenge-R1 Cli -p 15 << 'EOF'`. But prefer
`reach.py --apply`, which is programmatic and is what the challenge asks for.

**`show running-config` needs `-p 15`** (privileged), or eAPI with `enable`
first. `reach.py` handles this.

**H4 is IPv6-only and its DHCPv6 client must stay running.** `dhcpcd -1` exits
after one lease and the address expires ~2 hours later with nothing to renew
it. The topology uses `dhcpcd -b -6 eth1` for this reason.

**S1 and S2 are pure layer 2.** No routing, no loopback, 2–3 routes each. That
is correct, not a fault.

**`configs/telegraf.conf` is regenerated on every deploy** and is gitignored.
If `git status` shows it, something re-added it.

---

## Credentials (lab only, nothing real)

Devices `admin`/`admin` · InfluxDB token `rcn-telemetry-token` ·
Grafana `admin`/`admin`. All ephemeral, all rebuilt from scratch every deploy.

## Conventions

- Lab name is `rcn-challenge`; containers are `clab-rcn-challenge-<NODE>`.
- Interface descriptions: `L3_TO_<PEER>`, `ACCESS_TO_<HOST>_VLAN<n>`, `TRUNK_TO_<PEER>`.
- One template covers every device; role differences live in the data, not the code.
- Device roles: `access_router`, `access_switch`, `boundary_switch`,
  `core_router`, `pe_router`.
