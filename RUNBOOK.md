# Change Recipes

Concrete steps for the things most likely to be asked. Read `CLAUDE.md` first
for the topology and the free address ranges.

**Before you start anything, capture normal:**

```bash
./tools/reach.py --health | tee /tmp/baseline.txt
```

---

## Decide first: config change or topology change?

| | Config change | Topology change |
| --- | --- | --- |
| What | new address, protocol, route, description on an **existing** device | a **new** router/switch/host, or a new **link** |
| Cost | ~20 seconds | ~4 minutes (full redeploy) |
| How | `render` → `reach.py --apply` | `render` → edit `rcn.clab.yaml` → `deploy.py` |

Getting this wrong costs you four minutes you didn't need to spend. If no new
container and no new cable is involved, you do **not** redeploy.

---

## Recipe 1 — Config change on an existing device (the fast path)

Say R3's link to R5 needs a new description and an MTU.

```bash
# 1. change the intent
#    edit nsot/data/R3.yml

# 2. render and sync
cd nsot && python3 scripts/render.py R3 && cd ..
cp nsot/configs/R3.cfg configs/

# 3. push only what changed, over eAPI
./tools/reach.py --apply \
    "interface Ethernet2" \
    "description L3_TO_R5_PRIMARY" \
    "mtu 9000" \
    --save R3

# 4. verify intent is live
./tools/reach.py --drift R3
```

`--apply` shows you the lines and asks before sending. Add `--yes` to skip
that once you trust it.

**If the change is urgent and the template can't express it yet**, push it
first with `--apply`, then add it to the YAML and template afterwards so the
source of truth catches up. Fixing the network beats purity; just don't forget
the second half, because `--drift` will keep flagging it.

---

## Recipe 2 — Add a router to the OSPF core

New R6 hanging off R3. Uses the next free p2p block.

**`nsot/data/R6.yml`:**

```yaml
hostname: R6
vendor: arista_eos
role: core_router
mgmt:
  snmp_host: 172.20.20.13
  syslog_host: 172.20.20.13
  community: public
loopback:
  ipv4: 10.255.0.6/32
  ipv6: 2001:db8:ffff::6/128
  ospf: true
interfaces:
  - name: Ethernet1
    description: L3_TO_R3
    routed: true
    ipv4: 10.20.0.34/30
    ipv6: 2001:db8:2000:9::2/64
    ospf: p2p
ospf:
  router_id: 10.255.0.6
```

**Add to `nsot/data/R3.yml`** under `interfaces:`

```yaml
  - name: Ethernet4
    description: L3_TO_R6
    routed: true
    ipv4: 10.20.0.33/30
    ipv6: 2001:db8:2000:9::1/64
    ospf: p2p
```

**Add to `rcn.clab.yaml`** — node and link:

```yaml
    R6:
      kind: arista_ceos
      image: ceos:4.36.2F
      startup-config: configs/R6.cfg
      enforce-startup-config: true
```
```yaml
    - endpoints: ["R3:eth4", "R6:eth1"]
```

**Then:**

```bash
cd nsot && python3 scripts/render.py && cd ..
cp nsot/configs/*.cfg configs/
python3 deploy.py
./tools/reach.py --health          # R6 should show OSPFv2 1, OSPFv3 1
```

**Don't forget the tool lists** — `R6` must be added to `ROUTERS` in
`tools/reach.py`, to the `for dev in ...` line in `generate_configs.sh`, and
to `ROUTERS` in `challenge_check.sh`. Three one-word edits; easy to miss and
they make the new device invisible to your own tooling.

---

## Recipe 3 — Add a router to the IS-IS access layer

Same shape as Recipe 2, but the IS-IS keys instead of OSPF. The NET address
encodes the loopback: `10.255.0.6` → `49.0001.0000.0000.0006.00`.

```yaml
loopback:
  ipv4: 10.255.0.6/32
  ipv6: 2001:db8:ffff::6/128
  isis: passive
interfaces:
  - name: Ethernet1
    description: L3_TO_S3
    routed: true
    ipv4: 10.20.0.34/30
    ipv6: 2001:db8:2000:9::2/64
    isis: p2p
isis:
  instance: LOWER
  net: 49.0001.0000.0000.0006.00
```

`isis: p2p` on an interface gives `isis network point-to-point`; anything else
gives `isis passive`. The instance name must be `LOWER` to match the others.

---

## Recipe 4 — Add a new VLAN / LAN behind an existing router

Say VLAN 40 on R1, `10.40.0.0/24` and `2001:db8:4000:40::/64`.

**`nsot/data/R1.yml`** — a subinterface on the trunk:

```yaml
  - name: Ethernet1.40
    description: VLAN40_GATEWAY
    vlan: 40
    ipv4: 10.40.0.1/24
    helper: 10.20.0.5
    ipv6: 2001:db8:4000:40::1/64
    isis: passive
```

**`nsot/data/S1.yml` and `S2.yml`** — declare the VLAN and allow it on the trunk:

```yaml
vlans:
  - id: 40
    name: USERS_D
```
...and extend `allowed_vlans` on the trunk interface to include 40.

**`nsot/data/R2.yml`** — a DHCP pool, since R2 is the DHCP server:

```yaml
  - subnet: 10.40.0.0/24
    range: 10.40.0.50 10.40.0.199
    gateway: 10.40.0.1
```

No new container, but the hosts need a port, so if you're attaching a new host
this is a topology change. If you're only adding the VLAN to existing kit, it's
a config change — use Recipe 1's fast path on R1, S1, S2 and R2.

**Verify:** the new subnet should appear in IS-IS and propagate to the core.

```bash
./tools/reach.py --cmd "show ip route 10.40.0.0" --text R3
```

---

## Recipe 5 — Reach a network outside your topology

Typical ask: "H1 must reach 192.168.50.0/24, which lives beyond R5."

R5 is your edge, so the route enters there and has to be carried back through
BGP → OSPF → IS-IS. Fastest correct path:

```bash
# static route on R5 toward whatever next-hop you're given
./tools/reach.py --apply \
    "ip route 192.168.50.0/24 10.30.0.254" \
    R5

# advertise it into BGP so the core learns it
./tools/reach.py --apply \
    "router bgp 65100" \
    "address-family ipv4" \
    "network 192.168.50.0/24" \
    --save R5
```

R3 and R4 already redistribute BGP into OSPF via the `BGP_TO_OSPF_V4`
route-map, and that route-map matches the `WEB_V4` prefix-list — **which only
permits `10.30.0.0/24`**. A new prefix will not propagate until you add it:

```bash
./tools/reach.py --apply \
    "ip prefix-list WEB_V4 seq 20 permit 192.168.50.0/24" \
    --save R3 R4
```

That prefix-list is the single most likely thing to trip you up on this task.
Then S3/S4 carry it into IS-IS automatically via `OSPF_TO_ISIS`.

**Verify end to end:**

```bash
./tools/reach.py --cmd "show ip route 192.168.50.0" --text R3 R1
docker exec clab-rcn-challenge-H1 ping -c3 192.168.50.1
```

Afterwards, put the same lines into `nsot/data/R5.yml`, `R3.yml`, `R4.yml` so
the model matches reality, and re-render.

---

## Recipe 6 — Add another routing protocol and redistribute

The pattern already exists twice in your topology — copy it rather than
inventing one. S3/S4 show how: redistribute both directions, tag what you
inject, and deny your own tag coming back.

```
route-map NEW_TO_OSPF deny 10
   match tag 110
route-map NEW_TO_OSPF permit 20
   set tag 120
```

Then `redistribute <protocol> route-map NEW_TO_OSPF` under the receiving
process. Pick a tag not already in use — **110 and 115 are taken**; use 120+.

**Watch administrative distance.** This is what bit the original design: an
OSPF external (110) beat the device's own IS-IS route (115) and IPv6 looped.
If the new protocol's AD is lower than an existing path's, set
`distance <protocol> external <higher>` as S3/S4 do for OSPFv3.

---

## Recipe 7 — Something broke, diagnose fast

```bash
./tools/reach.py --health            # which row moved from baseline?
./tools/reach.py --drift             # did my config stop being present?
git diff                             # did I change something I forgot?
./demo_proof.sh                      # is the data plane actually broken?
```

Read them in that order. `--health` localises it to a device and a protocol,
`--drift` tells you whether configuration went missing, `git diff` catches
your own edits, `demo_proof.sh` distinguishes "control plane unhappy" from
"traffic actually stopped".

**Before concluding a fix failed, wait 30 seconds.** Spanning-tree on an
access port takes ~21–30s to forward again.

---

## Recipe 8 — Full rebuild from scratch

```bash
cd ~/rcn-challenge
python3 deploy.py          # ~3m45s, destroys and recreates everything
./challenge_check.sh
```

If the VM itself is gone:

```bash
git clone https://github.com/KevinZQS/rcn-challenge.git
cd rcn-challenge && pip install -r nsot/requirements.txt && pip install requests
python3 deploy.py
```

---

## Things that are easy to forget

- `render.py` writes `nsot/configs/` — **copy to `configs/`** or containerlab
  boots the old config.
- A new device must be added to `ROUTERS` in `tools/reach.py` and
  `challenge_check.sh`, and to the device list in `generate_configs.sh`.
- A new device needs its loopback **and** its `router_id`; they're separate
  fields that happen to share a value.
- IPv6 gateways come from RAs, never from DHCPv6.
- `--apply` changes the device but **not** the YAML. Update the YAML after, or
  the next redeploy silently reverts your change.
