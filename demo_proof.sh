#!/bin/bash
# demo_proof.sh -- the multi-vendor dual-stack proof, in one command.
#
# Five checks, ~40 seconds, labelled output, PASS/FAIL summary at the end.
# Run from anywhere:  ./demo_proof.sh

LAB=clab-rcn-challenge

CYAN='\033[1;36m'; GREEN='\033[1;32m'; RED='\033[1;31m'; BOLD='\033[1m'; NC='\033[0m'

declare -a NAMES RESULTS

hdr() { echo; echo -e "${CYAN}======================================================${NC}"; \
        echo -e "${CYAN} $*${NC}"; \
        echo -e "${CYAN}======================================================${NC}"; }

record() {  # record <name> <exit-code>
    NAMES+=("$1")
    if [ "$2" -eq 0 ]; then RESULTS+=("PASS"); else RESULTS+=("FAIL"); fi
}

# ---------------------------------------------------------------- 1
hdr "1/5   IPv4 reachability   H1  ->  WebServer 10.30.0.10"
echo "      path: S1 -> R1 -> IS-IS -> S3 -> OSPF -> R3 -> eBGP -> R5 (SONiC)"
echo
docker exec ${LAB}-H1 ping -c 3 -W 2 10.30.0.10
record "IPv4 ping  H1 -> WebServer" $?

# ---------------------------------------------------------------- 2
hdr "2/5   IPv4 HTTP            H1  ->  WebServer"
echo
docker exec ${LAB}-H1 wget -qO- --timeout=5 http://10.30.0.10
record "IPv4 HTTP  H1 -> WebServer" $?

# ---------------------------------------------------------------- 3
hdr "3/5   IPv6 reachability   H4  ->  WebServer 2001:db8:3000:100::10"
echo "      H4 is on the IPv6-only VLAN 30 (DHCPv6, no IPv4 at all)"
echo
if docker exec ${LAB}-H4 ping6 -c 3 -W 2 2001:db8:3000:100::10; then
    record "IPv6 ping  H4 -> WebServer" 0
else
    docker exec ${LAB}-H4 ping -6 -c 3 -W 2 2001:db8:3000:100::10
    record "IPv6 ping  H4 -> WebServer" $?
fi

# ---------------------------------------------------------------- 4
hdr "4/5   IPv6 HTTP            H4  ->  WebServer"
echo
docker exec ${LAB}-H4 wget -qO- --timeout=5 "http://[2001:db8:3000:100::10]"
record "IPv6 HTTP  H4 -> WebServer" $?

# ---------------------------------------------------------------- 5
hdr "5/5   R5 edge router: BGP summary (IPv4 + IPv6)"
echo
docker exec ${LAB}-R5 Cli -p 15 -c "show ip bgp summary"
rc1=$?
echo
docker exec ${LAB}-R5 Cli -p 15 -c "show ipv6 bgp summary"
rc2=$?
if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]; then record "R5 BGP summary" 0; else record "R5 BGP summary" 1; fi

# ---------------------------------------------------------------- summary
echo
echo -e "${BOLD}======================================================${NC}"
echo -e "${BOLD} SUMMARY${NC}"
echo -e "${BOLD}======================================================${NC}"
FAILED=0
for i in "${!NAMES[@]}"; do
    if [ "${RESULTS[$i]}" = "PASS" ]; then
        echo -e "  ${GREEN}PASS${NC}  ${NAMES[$i]}"
    else
        echo -e "  ${RED}FAIL${NC}  ${NAMES[$i]}"
        FAILED=1
    fi
done
echo
if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}Dual-stack traffic crossed the Arista/SONiC boundary in both directions.${NC}"
else
    echo -e "  ${RED}One or more checks failed -- see above.${NC}"
fi
echo
exit $FAILED
