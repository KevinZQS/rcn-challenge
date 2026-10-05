#!/bin/bash
# challenge_check.sh -- walks the CSCI 5840 Pre-Class Checklist line by line.
#
# Every numbered item below maps to a checkbox in the PDF. Items that cannot
# be tested by a script (window layout, scrollback) are asked, not assumed.
#
#   ./challenge_check.sh                 full run, including the live failure test
#   ./challenge_check.sh --skip-failure  skip the ~45s link-break test
#   ./challenge_check.sh --yes           auto-answer the manual prompts as "yes"
#
# The failure test briefly shuts H1's access port on S1 and restores it.
# It is safe and self-restoring, but do not run it while someone is watching
# your dashboard and drawing conclusions.

LAB=clab-rcn-challenge
ROUTERS="R1 R2 R3 R4 R5 S1 S2 S3 S4"
WEB4=10.30.0.10
WEB6=2001:db8:3000:100::10
FAIL_DEV=S1
FAIL_IFACE=Ethernet3      # S1:eth3 <-> H1:eth1, H1's access port
INFLUX_TOKEN=rcn-telemetry-token
INFLUX_ORG=rcn

SKIP_FAILURE=0; AUTO_YES=0
for a in "$@"; do
    [ "$a" = "--skip-failure" ] && SKIP_FAILURE=1
    [ "$a" = "--yes" ] && AUTO_YES=1
done

G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; B='\033[1m'; D='\033[2m'; N='\033[0m'
PASS=0; FAIL=0; WARN=0
declare -a FAILED_ITEMS

sec()  { echo; echo -e "${C}==============================================================${N}";
         echo -e "${C} $*${N}";
         echo -e "${C}==============================================================${N}"; }
item() { echo -e "\n${B}[$1]${N} $2"; }
ok()   { echo -e "   ${G}PASS${N}  $*"; PASS=$((PASS+1)); }
bad()  { echo -e "   ${R}FAIL${N}  $*"; FAIL=$((FAIL+1)); FAILED_ITEMS+=("$CURRENT: $*"); }
warn() { echo -e "   ${Y}WARN${N}  $*"; WARN=$((WARN+1)); }
note() { echo -e "         ${D}$*${N}"; }

ask() {   # ask "<question>"  -> pass/fail from the operator
    if [ "$AUTO_YES" = "1" ]; then ok "$1 (auto-answered)"; return; fi
    echo -ne "   ${Y}?${N}     $1 [y/N] "
    read -r a </dev/tty
    case "$a" in y|Y|yes|YES) ok "confirmed by operator";; *) bad "not confirmed";; esac
}

v6addr() { docker exec ${LAB}-$1 ip -6 -o addr show dev eth1 2>/dev/null \
           | grep -oE 'inet6 [0-9a-f:]+' | awk '{print $2}' | grep -v '^fe80' | head -1; }
v4addr() { docker exec ${LAB}-$1 ip -4 -o addr show dev eth1 2>/dev/null \
           | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1; }
influx() { docker exec ${LAB}-InfluxDB influx query "$1" --org $INFLUX_ORG --token $INFLUX_TOKEN 2>/dev/null; }

restore_iface() {
    docker exec -i ${LAB}-$FAIL_DEV Cli -p 15 >/dev/null 2>&1 <<EOF
configure terminal
interface $FAIL_IFACE
no shutdown
end
EOF
}
trap 'echo; echo "interrupted -- restoring $FAIL_DEV $FAIL_IFACE"; restore_iface; exit 130' INT TERM

echo -e "${B}CSCI 5840 -- Pre-Class Checklist${N}"
echo -e "${D}$(date)${N}"

# ==================================================================== 0
sec "0   Lab is running"
CURRENT="0"
RUNNING=$(docker ps --format '{{.Names}}' | grep -c "^${LAB}-")
item "0.1" "All 18 nodes up"
if [ "$RUNNING" -eq 18 ]; then ok "18/18 containers running"
else bad "only $RUNNING/18 running -- deploy first: python3 deploy.py"; fi
MISSING=""
for d in $ROUTERS H1 H2 H3 H4 WebServer NMAS InfluxDB Telegraf Grafana; do
    docker ps --format '{{.Names}}' | grep -q "^${LAB}-${d}$" || MISSING="$MISSING $d"
done
[ -n "$MISSING" ] && bad "not running:$MISSING"

# ==================================================================== 1
sec "1   Connectivity"
CURRENT="1"

item "1.1" "Every host (H1-H4) can ping the web server; H4 over IPv6"
for h in H1 H2 H3; do
    docker exec ${LAB}-$h ping -c2 -W2 $WEB4 >/dev/null 2>&1 \
        && ok "$h -> web server (IPv4)" || bad "$h -> web server (IPv4)"
done
docker exec ${LAB}-H4 ping -6 -c2 -W2 $WEB6 >/dev/null 2>&1 \
    && ok "H4 -> web server (IPv6, host has no IPv4 at all)" || bad "H4 -> web server (IPv6)"
docker exec ${LAB}-H1 wget -qO- --timeout=5 http://$WEB4 >/dev/null 2>&1 \
    && ok "H1 HTTP fetch succeeded (real TCP, not just ICMP)" || bad "H1 HTTP over IPv4"
docker exec ${LAB}-H4 wget -qO- --timeout=5 "http://[$WEB6]" >/dev/null 2>&1 \
    && ok "H4 HTTP fetch succeeded over IPv6" || bad "H4 HTTP over IPv6"

item "1.2" "All four hosts reach each other after a fresh start"
H1_4=$(v4addr H1); H2_4=$(v4addr H2); H3_4=$(v4addr H3)
H1_6=$(v6addr H1); H2_6=$(v6addr H2); H3_6=$(v6addr H3); H4_6=$(v6addr H4)
note "H1 $H1_4 / $H1_6"
note "H2 $H2_4 / $H2_6"
note "H3 $H3_4 / $H3_6"
note "H4 (no IPv4) / $H4_6"
for p in "H1 $H2_4 H2" "H1 $H3_4 H3" "H2 $H3_4 H3"; do
    set -- $p
    [ -z "$2" ] && { bad "$1 -> $3 : no IPv4 address found"; continue; }
    docker exec ${LAB}-$1 ping -c2 -W2 $2 >/dev/null 2>&1 \
        && ok "$1 <-> $3 (IPv4)" || bad "$1 -> $3 (IPv4)"
done
for p in "H4 $H1_6 H1" "H4 $H2_6 H2" "H4 $H3_6 H3"; do
    set -- $p
    [ -z "$2" ] && { bad "$1 -> $3 : no IPv6 address found"; continue; }
    docker exec ${LAB}-$1 ping -6 -c2 -W2 $2 >/dev/null 2>&1 \
        && ok "$1 <-> $3 (IPv6 -- crosses VLAN30->R2->IS-IS->R1->VLAN10/20)" \
        || bad "$1 -> $3 (IPv6)"
done

item "1.3" "Address leases are being held, not just obtained once"
note "a one-shot DHCP client gets an address and exits; the lease then"
note "expires mid-session with nothing left running to renew it."
for h in H1 H2 H3; do
    A=$(v4addr $h)
    [ -n "$A" ] && ok "$h holds an IPv4 address ($A)" \
                || bad "$h has NO IPv4 address -- its DHCP lease expired"
done
H4A=$(v6addr H4)
if [ -n "$H4A" ]; then ok "H4 holds a global IPv6 address ($H4A)"
else
    bad "H4 has NO global IPv6 address -- only link-local"
    note "VLAN30 is advertised no-autoconfig, so DHCPv6 is H4's only source."
    note "recover now: docker exec -d ${LAB}-H4 dhcpcd -b -6 eth1"
fi
if docker exec ${LAB}-H4 sh -c 'pgrep dhcpcd >/dev/null' 2>/dev/null; then
    ok "H4's DHCPv6 client is still running (lease will renew)"
else
    bad "H4 has NO dhcpcd process -- its lease will expire and never renew"
    note "permanent fix is in the topology: dhcpcd -b -6 eth1, not dhcpcd -1 -6 eth1"
    note "recover now:  docker exec -d ${LAB}-H4 dhcpcd -b -6 eth1"
fi

# ==================================================================== 2
sec "2   Continuous ping that shows failures"
CURRENT="2"

item "2.1" "A continuous ping can run on every host"
for h in H1 H2 H3; do
    docker exec ${LAB}-$h ping -O -D -i 1 -c 2 $WEB4 >/dev/null 2>&1 \
        && ok "$h accepts  ping -O -D -i 1" \
        || { bad "$h rejects -O/-D (busybox ping -- losses would be invisible)"
             note "fix: docker exec ${LAB}-$h apk add --no-cache iputils-ping"; }
done
docker exec ${LAB}-H4 ping -6 -O -D -i 1 -c 2 $WEB6 >/dev/null 2>&1 \
    && ok "H4 accepts  ping -6 -O -D -i 1" || bad "H4 rejects -6/-O/-D"

item "2.2" "It visibly shows a failed packet -- break a link, watch, restore"
if [ "$SKIP_FAILURE" = "1" ]; then
    warn "skipped (--skip-failure). This is a REQUIRED checklist item."
else
    note "running a live ping on H1, shutting $FAIL_DEV $FAIL_IFACE (H1's access"
    note "port), then restoring it. Takes about 45 seconds."
    docker exec ${LAB}-H1 sh -c 'rm -f /tmp/pingtest.log' 2>/dev/null
    docker exec -d ${LAB}-H1 sh -c "ping -O -D -i 1 $WEB4 > /tmp/pingtest.log 2>&1"
    sleep 6                                    # baseline replies
    echo -ne "         ${D}breaking the link ...${N}\r"
    docker exec -i ${LAB}-$FAIL_DEV Cli -p 15 >/dev/null 2>&1 <<EOF
configure terminal
interface $FAIL_IFACE
shutdown
end
EOF
    sleep 16                                   # observe the outage
    BEFORE=$(docker exec ${LAB}-H1 grep -c "bytes from" /tmp/pingtest.log 2>/dev/null)
    echo -ne "         ${D}restoring the link ...${N}                 \r"
    restore_iface

    # Poll for recovery rather than guessing. A cEOS access port runs
    # spanning-tree: listening + learning is ~30s with default timers, so a
    # fixed 15-20s wait reports a false failure on a perfectly healthy network.
    RECOVERED=0; WAITED=0
    while [ "$WAITED" -lt 75 ]; do
        sleep 3; WAITED=$((WAITED+3))
        NOW=$(docker exec ${LAB}-H1 grep -c "bytes from" /tmp/pingtest.log 2>/dev/null)
        echo -ne "         ${D}waiting for recovery ... ${WAITED}s${N}        \r"
        if [ "${NOW:-0}" -gt "${BEFORE:-0}" ]; then RECOVERED=$WAITED; break; fi
    done
    sleep 3
    docker exec ${LAB}-H1 sh -c 'pkill -f "ping -O" || killall ping' >/dev/null 2>&1
    LOG=$(docker exec ${LAB}-H1 cat /tmp/pingtest.log 2>/dev/null)
    echo -ne "                                                        \r"

    LOST=$(echo "$LOG" | grep -ci "no answer yet")
    TAIL_OK=$([ "$RECOVERED" -gt 0 ] && echo 1 || echo 0)

    if [ "$BEFORE" -gt 0 ]; then ok "ping was replying before the break ($BEFORE replies)"
    else bad "no replies at all -- the ping never worked"; fi

    if [ "$LOST" -gt 0 ]; then
        ok "failure was VISIBLE in the window ($LOST 'no answer yet' lines)"
        echo "$LOG" | grep -i "no answer yet" | head -3 | sed 's/^/         /'
    else
        bad "no 'no answer yet' lines -- a failure would be invisible"
    fi

    if [ "$TAIL_OK" -gt 0 ]; then
        ok "ping RECOVERED ${RECOVERED}s after the link was restored"
        note "that delay is spanning-tree on the access port (listening +"
        note "learning, ~30s with default timers). Remember it during the"
        note "challenge: wait 30s before deciding a fix did not work."
    else
        bad "ping did not recover within 75s -- check $FAIL_DEV $FAIL_IFACE"
        note "docker exec ${LAB}-$FAIL_DEV Cli -p 15 -c 'show interfaces $FAIL_IFACE status'"
    fi
fi

item "2.3" "Four ping windows open and readable at once"
note "start them in four terminals now:"
note "  docker exec -it ${LAB}-H1 ping -O -D -i 1 $WEB4"
note "  docker exec -it ${LAB}-H2 ping -O -D -i 1 $WEB4"
note "  docker exec -it ${LAB}-H3 ping -O -D -i 1 $WEB4"
note "  docker exec -it ${LAB}-H4 ping -6 -O -D -i 1 $WEB6"
ask "Are all four ping windows open and readable side by side?"

item "2.4" "Scrollback large enough for several minutes of output"
note "at 1 ping/second, 5 minutes x 4 windows is ~1200 lines. Set scrollback"
note "to at least 5000 lines in your terminal preferences."
ask "Is your terminal scrollback set to several thousand lines?"

# ==================================================================== 3
sec "3   Your tools"
CURRENT="3"

item "3.1" "NMAS is up and receiving telemetry from your routers"
NMAS_IP=$(docker inspect ${LAB}-NMAS --format '{{.NetworkSettings.Networks.clab.IPAddress}}' 2>/dev/null)
[ "$NMAS_IP" = "172.20.20.13" ] \
    && ok "NMAS on its pinned address $NMAS_IP (matches every device's snmp/syslog target)" \
    || bad "NMAS at ${NMAS_IP:-unknown}, but configs point at 172.20.20.13"
docker exec ${LAB}-InfluxDB influx ping >/dev/null 2>&1 \
    && ok "InfluxDB responding" || bad "InfluxDB not responding"
SEEN=$(influx 'from(bucket:"telemetry") |> range(start:-5m) |> keep(columns:["device"]) |> group(columns:["device"]) |> distinct(column:"device")' \
       | grep -oE '\b(R[1-5]|S[1-4])\b' | sort -u | tr '\n' ' ')
note "devices reporting in the last 5 min: ${SEEN:-none}"
for d in $ROUTERS; do
    echo "$SEEN" | grep -qw "$d" && ok "$d sending telemetry" || bad "$d NOT sending telemetry"
done

item "3.2" "NSOT is reachable and current"
curl -s -o /dev/null --max-time 5 http://localhost:5000/ 2>/dev/null \
    && ok "NSOT GUI answering on :5000" \
    || { bad "NSOT GUI not reachable"; note "start it: cd nsot && python3 app.py"; }
( cd nsot && python3 scripts/render.py >/dev/null 2>&1 )
DRIFT=0
for d in $ROUTERS; do
    diff -q nsot/configs/$d.cfg configs/$d.cfg >/dev/null 2>&1 || { DRIFT=$((DRIFT+1)); echo "         drift: $d"; }
done
[ "$DRIFT" -eq 0 ] && ok "all 9 devices: rendered output == deployed config" \
                   || bad "$DRIFT device(s) drifted from the source of truth"

item "3.3" "Automation framework reaches every router programmatically (no CLI)"
if [ -f tools/reach.py ]; then
    if python3 tools/reach.py --quiet; then ok "all 9 routers answered over eAPI (HTTPS, MGMT VRF)"
    else bad "one or more routers unreachable over eAPI"
         note "detail: python3 tools/reach.py"; fi
else
    bad "tools/reach.py missing"
fi

item "3.4" "You can see live interface counters for devices"
MEAS=$(influx 'import "influxdata/influxdb/schema" schema.measurements(bucket: "telemetry")' \
       | grep -oE '\b[a-z_]+\b' | sort -u | tr '\n' ' ')
note "measurements in the bucket: ${MEAS:-none}"
CNT=$(influx 'from(bucket:"telemetry") |> range(start:-5m) |> filter(fn:(r) => r._measurement == "interfaces") |> keep(columns:["device"]) |> group(columns:["device"]) |> distinct(column:"device")' \
      | grep -cE '\b(R[1-5]|S[1-4])\b')
if [ "$CNT" -gt 0 ]; then
    ok "interface counters arriving from $CNT device(s) in the last 5 min"
else
    bad "no interface-counter data in the last 5 min"
    note "check Telegraf: docker logs ${LAB}-Telegraf --tail 30"
fi
curl -s -o /dev/null --max-time 5 http://localhost:3000/api/health 2>/dev/null \
    && ok "Grafana answering on :3000" || bad "Grafana not answering on :3000"
note "open http://localhost:3000 and confirm the interface panels are DRAWING,"
note "not empty -- the checklist says you must be able to SEE the counters."
ask "Are the Grafana interface panels showing live data?"

# ==================================================================== 4
sec "4   Know your own network  (recall -- no script can test this)"
CURRENT="4"
cat <<'EOF'

  [4.1] Routing protocols, access side and core, IPv4 and IPv6
        Access  : IS-IS, level-2 only, carrying BOTH address families
                  (R1, R2, S3, S4)
        Core    : OSPFv2 for IPv4 and OSPFv3 for IPv6  (S3, S4, R3, R4)
        Edge    : eBGP, AS 65000 <-> AS 65100, both address families
                  (R3/R4 <-> R5)
        S3 and S4 are the redistribution boundaries between IS-IS and OSPF,
        using route tags 110 and 115 to prevent loops.

  [4.2] Where DHCP runs
        On R2, for all three VLANs:
          VLAN 10  10.10.10.50-199        (IPv4)
          VLAN 20  10.10.20.50-199        (IPv4)
          VLAN 30  2001:db8:1000:30::100-1ff   (DHCPv6)
        R1 owns the VLAN 10 and 20 gateways, so it RELAYS their requests to
        R2 with  ip helper-address 10.20.0.5.  VLAN 30 is served directly,
        because R2 owns that gateway.

  [4.3] How hosts get their default gateway
        IPv4 : from the DHCP default-gateway option -- 10.10.10.1 and
               10.10.20.1, both subinterfaces on R1.
        IPv6 : from Router Advertisements, on every VLAN. VLAN 30 sets
               ipv6 nd managed-config-flag, so H4 takes its ADDRESS from
               DHCPv6 but its DEFAULT ROUTE from R2's RA.
               DHCPv6 never hands out a gateway; only RAs do.

EOF
ask "Can you explain all three of the above without reading them?"

# ==================================================================== summary
echo
echo -e "${C}==============================================================${N}"
echo -e "${C} SUMMARY${N}"
echo -e "${C}==============================================================${N}"
echo -e "   ${G}pass $PASS${N}    ${R}fail $FAIL${N}    ${Y}warn $WARN${N}"
if [ "$FAIL" -gt 0 ]; then
    echo
    echo -e "   ${R}Outstanding:${N}"
    for f in "${FAILED_ITEMS[@]}"; do echo "     - $f"; done
fi
echo
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "   ${G}Every checklist item confirmed. You are ready.${N}"
elif [ "$FAIL" -eq 0 ]; then
    echo -e "   ${G}No failures.${N} ${Y}Review the warnings above.${N}"
else
    echo -e "   ${R}$FAIL item(s) not satisfied -- fix before class.${N}"
fi
echo
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
