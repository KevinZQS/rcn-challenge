#!/bin/bash
# check_ready.sh -- walks the CSCI 5840 pre-class checklist against the live lab.
#
# Read-only. Changes nothing. Run it after deploy.py and after routing
# has had a minute or two to converge.
#
#   ./check_ready.sh

LAB=clab-rcn-challenge
ROUTERS="R1 R2 R3 R4 R5 S1 S2 S3 S4"
WEB4=10.30.0.10
WEB6=2001:db8:3000:100::10

G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; D='\033[2m'; N='\033[0m'
PASS=0; FAIL=0; WARN=0

sec()  { echo; echo -e "${C}==============================================================${N}";
         echo -e "${C} $*${N}";
         echo -e "${C}==============================================================${N}"; }
ok()   { echo -e "  ${G}PASS${N}  $*"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${R}FAIL${N}  $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${Y}WARN${N}  $*"; WARN=$((WARN+1)); }
note() { echo -e "        ${D}$*${N}"; }

v4() { docker exec ${LAB}-$1 ip -4 -o addr show dev eth1 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1; }
v6() { docker exec ${LAB}-$1 ip -6 -o addr show dev eth1 2>/dev/null | grep -oE 'inet6 [0-9a-f:]+' | awk '{print $2}' | grep -v '^fe80' | head -1; }

# ============================================================ 0
sec "0   Lab is up"
RUNNING=$(docker ps --format '{{.Names}}' | grep -c "^${LAB}-")
echo "  containers running: $RUNNING (expect 18)"
[ "$RUNNING" -ge 18 ] && ok "all nodes running" || bad "only $RUNNING nodes running"
for d in $ROUTERS; do
    docker ps --format '{{.Names}}' | grep -q "^${LAB}-${d}$" || bad "$d is not running"
done

# ============================================================ 1
sec "1   Connectivity -- every host reaches the web server"
for h in H1 H2 H3; do
    if docker exec ${LAB}-$h ping -c2 -W2 $WEB4 >/dev/null 2>&1; then
        ok "$h -> web server over IPv4"
    else
        bad "$h -> web server over IPv4"
    fi
done
if docker exec ${LAB}-H4 ping -6 -c2 -W2 $WEB6 >/dev/null 2>&1; then
    ok "H4 -> web server over IPv6 (IPv6-only host)"
else
    bad "H4 -> web server over IPv6"
fi
echo
echo "  HTTP (proves a real TCP session, not just ICMP):"
docker exec ${LAB}-H1 wget -qO- --timeout=5 http://$WEB4 >/dev/null 2>&1 \
    && ok "H1 fetched the page over IPv4" || bad "H1 HTTP over IPv4"
docker exec ${LAB}-H4 wget -qO- --timeout=5 "http://[$WEB6]" >/dev/null 2>&1 \
    && ok "H4 fetched the page over IPv6" || bad "H4 HTTP over IPv6"

# ============================================================ 1b
sec "1b  Connectivity -- hosts reach each other"
note "H4 is IPv6-only, so anything involving H4 must go over IPv6."
H1_4=$(v4 H1); H2_4=$(v4 H2); H3_4=$(v4 H3)
H1_6=$(v6 H1); H2_6=$(v6 H2); H3_6=$(v6 H3); H4_6=$(v6 H4)
echo "  H1 $H1_4 / $H1_6"
echo "  H2 $H2_4 / $H2_6"
echo "  H3 $H3_4 / $H3_6"
echo "  H4      (none) / $H4_6"
echo
for pair in "H1 $H2_4 H2" "H1 $H3_4 H3" "H2 $H3_4 H3"; do
    set -- $pair
    [ -z "$2" ] && { warn "$1 -> $3 : no address found"; continue; }
    docker exec ${LAB}-$1 ping -c2 -W2 $2 >/dev/null 2>&1 \
        && ok "$1 -> $3 over IPv4" || bad "$1 -> $3 over IPv4"
done
for pair in "H4 $H1_6 H1" "H4 $H2_6 H2" "H4 $H3_6 H3"; do
    set -- $pair
    [ -z "$2" ] && { warn "$1 -> $3 : no IPv6 address found"; continue; }
    docker exec ${LAB}-$1 ping -6 -c2 -W2 $2 >/dev/null 2>&1 \
        && ok "$1 -> $3 over IPv6" || bad "$1 -> $3 over IPv6"
done

# ============================================================ 2
sec "2   Continuous ping that shows failures"
note "testing the FLAGS, not the binary path -- Alpine may resolve ping"
note "to /bin/ping and still have iputils behind it."
for h in H1 H2 H3; do
    if docker exec ${LAB}-$h ping -O -D -i 1 -c 2 $WEB4 >/dev/null 2>&1; then
        ok "$h accepts ping -O -D (failures will be visible)"
    else
        bad "$h rejects -O/-D -- iputils did not install, lost packets stay invisible"
        note "fix: docker exec ${LAB}-$h apk add --no-cache iputils-ping"
    fi
done
if docker exec ${LAB}-H4 ping -6 -O -D -i 1 -c 2 $WEB6 >/dev/null 2>&1; then
    ok "H4 accepts ping -6 -O -D"
else
    bad "H4 rejects -6/-O/-D"
fi

echo
echo "  does a dropped packet actually print a line? (the whole point)"
OUT=$(docker exec ${LAB}-H1 ping -O -D -i 1 -c 3 -W 1 192.0.2.254 2>&1)
if echo "$OUT" | grep -qi "no answer yet"; then
    ok "lost packets print 'no answer yet for icmp_seq=...'"
    echo "$OUT" | grep -i "no answer yet" | head -2 | sed 's/^/        /'
else
    warn "could not confirm the dropped-packet line -- check by hand"
fi

echo
note "during the challenge, one window per host:"
note "  docker exec -it ${LAB}-H1 ping -O -D -i 1 $WEB4"
note "  docker exec -it ${LAB}-H2 ping -O -D -i 1 $WEB4"
note "  docker exec -it ${LAB}-H3 ping -O -D -i 1 $WEB4"
note "  docker exec -it ${LAB}-H4 ping -6 -O -D -i 1 $WEB6"

# ============================================================ 3
sec "3   Your tools"
NMAS_IP=$(docker inspect ${LAB}-NMAS --format '{{.NetworkSettings.Networks.clab.IPAddress}}' 2>/dev/null)
echo "  NMAS at $NMAS_IP"
[ "$NMAS_IP" = "172.20.20.13" ] \
    && ok "NMAS is on its pinned address (matches every device's snmp/syslog target)" \
    || bad "NMAS is at $NMAS_IP but the configs point at 172.20.20.13"

INFLUX=$(docker inspect ${LAB}-InfluxDB --format '{{.NetworkSettings.Networks.clab.IPAddress}}' 2>/dev/null)
if docker exec ${LAB}-InfluxDB influx ping >/dev/null 2>&1; then ok "InfluxDB responding"; else bad "InfluxDB not responding"; fi

echo
echo "  telemetry actually arriving (last 5 min, per device):"
Q='from(bucket:"telemetry") |> range(start:-5m) |> keep(columns:["device"]) |> group(columns:["device"]) |> distinct(column:"device")'
SEEN=$(docker exec ${LAB}-InfluxDB influx query "$Q" --org rcn --token rcn-telemetry-token 2>/dev/null | grep -oE '\b(R[1-5]|S[1-4])\b' | sort -u | tr '\n' ' ')
echo "  devices reporting: ${SEEN:-none}"
for d in $ROUTERS; do
    echo "$SEEN" | grep -qw "$d" && ok "$d sending telemetry" || warn "$d not seen in the last 5 min"
done

echo
echo "  programmatic reach (eAPI over HTTPS in the MGMT VRF, no CLI):"
if [ -f tools/reach.py ]; then
    python3 tools/reach.py --quiet && ok "all routers reachable programmatically" \
                                   || bad "one or more routers unreachable programmatically"
else
    warn "tools/reach.py not present yet -- this is the one checklist item still to build"
fi

curl -s -o /dev/null -w '' http://localhost:3000/api/health 2>/dev/null \
    && ok "Grafana answering on :3000" || warn "Grafana not answering on :3000"
curl -s -o /dev/null http://localhost:5000/ 2>/dev/null \
    && ok "NSOT GUI answering on :5000" || warn "NSOT GUI not running (start it with: cd nsot && python3 app.py)"

echo
echo "  NSOT is current (rendered output == deployed config):"
( cd nsot && python3 scripts/render.py >/dev/null 2>&1 )
for d in $ROUTERS; do
    if diff -q nsot/configs/$d.cfg configs/$d.cfg >/dev/null 2>&1; then
        ok "$d config matches the source of truth"
    else
        bad "$d DRIFT between nsot/configs and configs"
    fi
done

# ============================================================ summary
echo
echo -e "${C}==============================================================${N}"
echo -e "${C} SUMMARY${N}"
echo -e "${C}==============================================================${N}"
echo -e "   ${G}pass $PASS${N}    ${R}fail $FAIL${N}    ${Y}warn $WARN${N}"
echo
if [ "$FAIL" -eq 0 ]; then
    echo -e "   ${G}No failures. Review any warnings above.${N}"
else
    echo -e "   ${R}$FAIL check(s) failed -- fix before class.${N}"
fi
echo
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
