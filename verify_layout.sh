#!/bin/bash
# verify_layout.sh -- prove the files landed correctly BEFORE deploying.
#
# Checks: every file present, every checksum matching, no Windows line
# endings, scripts executable, topology values correct, and the NSOT
# still rendering the deployed configs.
#
# Run from inside the lab directory:   ./verify_layout.sh

G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; D='\033[2m'; N='\033[0m'
PASS=0; FAIL=0; WARN=0
ok()   { echo -e "  ${G}OK${N}    $*"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${R}BAD${N}   $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${Y}WARN${N}  $*"; WARN=$((WARN+1)); }
sec()  { echo; echo -e "${C}--- $* ---${N}"; }

sec "1. Are we in the right directory?"
if [ -f rcn.clab.yaml ] && [ -d nsot ] && [ -d configs ]; then
    ok "running in $(pwd)"
else
    echo -e "  ${R}Not a lab directory.${N} cd into ~/rcn-challenge first."
    exit 1
fi

sec "2. Every file present and uncorrupted"
if [ ! -f MANIFEST.sha256 ]; then
    bad "MANIFEST.sha256 missing -- the archive did not extract fully"
else
    MISSING=0; CHANGED=0
    while read -r sum path; do
        [ -z "$path" ] && continue
        if [ ! -f "$path" ]; then
            echo -e "       ${R}missing:${N} $path"; MISSING=$((MISSING+1)); continue
        fi
        actual=$(sha256sum "$path" | awk '{print $1}')
        if [ "$actual" != "$sum" ]; then
            echo -e "       ${R}corrupt/modified:${N} $path"; CHANGED=$((CHANGED+1))
        fi
    done < MANIFEST.sha256
    TOTAL=$(grep -c . MANIFEST.sha256)
    if [ "$MISSING" -eq 0 ] && [ "$CHANGED" -eq 0 ]; then
        ok "all $TOTAL files present with matching checksums"
    else
        [ "$MISSING" -gt 0 ] && bad "$MISSING file(s) missing"
        [ "$CHANGED" -gt 0 ] && bad "$CHANGED file(s) corrupt or edited"
        echo -e "       ${D}if files are corrupt, re-transfer the .tar.gz in BINARY mode${N}"
    fi
fi

sec "3. Line endings (WinSCP text mode breaks these)"
# Only our own files -- a virtualenv, git objects and __pycache__ legitimately
# contain CRLF (pip RECORD files, Activate.ps1) and are not ours to police.
CRLF=$(grep -rlI --exclude=MANIFEST.sha256 \
        --exclude-dir=.venv --exclude-dir=venv --exclude-dir=.git \
        --exclude-dir=__pycache__ --exclude-dir=clab-rcn-challenge \
        "$(printf '\r')" . 2>/dev/null)
if [ -z "$CRLF" ]; then
    ok "no Windows line endings in lab files"
else
    bad "CRLF line endings found in:"
    echo "$CRLF" | sed 's/^/       /'
    echo -e "       ${D}fix with:  dos2unix <each file listed above>${N}"
fi

sec "4. Scripts executable"
for f in deploy.py check_ready.sh verify_layout.sh generate_configs.sh \
         demo_proof.sh demo_failure.sh tools/reach.py; do
    if [ ! -f "$f" ]; then bad "$f missing"
    elif [ -x "$f" ]; then ok "$f"
    else warn "$f not executable -- run: chmod +x $f"
    fi
done

sec "5. Topology values"
python3 - <<'PY'
import sys, yaml
G,R,N = "\033[1;32m","\033[1;31m","\033[0m"
def ok(m):  print(f"  {G}OK{N}    {m}")
def bad(m): print(f"  {R}BAD{N}   {m}"); sys.exit(9)
d = yaml.safe_load(open("rcn.clab.yaml"))
n = d["topology"]["nodes"]
ok(f"YAML parses: {len(n)} nodes, {len(d['topology']['links'])} links") if len(n)==18 else bad(f"expected 18 nodes, found {len(n)}")
d.get("name")=="rcn-challenge" or bad(f"lab name is '{d.get('name')}', expected rcn-challenge")
ok("lab name is rcn-challenge")
n["R5"]["kind"]=="arista_ceos" or bad(f"R5 kind is {n['R5']['kind']}, expected arista_ceos")
ok("R5 is arista_ceos (not sonic-vm)")
n["R5"].get("startup-config")=="configs/R5.cfg" or bad("R5 has no startup-config")
ok("R5 loads configs/R5.cfg at boot")
n["NMAS"].get("mgmt-ipv4")=="172.20.20.13" or bad("NMAS management address not pinned to 172.20.20.13")
ok("NMAS pinned to 172.20.20.13")
for h in ("H1","H2","H3","H4"):
    "iputils" in " ".join(n[h]["exec"]) or bad(f"{h} does not install iputils")
ok("H1-H4 all install iputils (real ping)")
n["Grafana"]["env"].get("GF_SECURITY_ALLOW_EMBEDDING")=="true" or bad("Grafana embedding not enabled")
ok("Grafana embedding enabled")
kinds = sorted(set(v["kind"] for v in n.values()))
kinds==["arista_ceos","linux"] or bad(f"unexpected node kinds: {kinds}")
ok("only arista_ceos and linux kinds in use")
PY
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

sec "6. Device configs present"
for d in R1 R2 R3 R4 R5 S1 S2 S3 S4; do
    [ -f "configs/$d.cfg" ] || bad "configs/$d.cfg missing"
done
[ "$(ls configs/*.cfg 2>/dev/null | wc -l)" -eq 9 ] && ok "all 9 deployed configs present" || bad "expected 9 configs in configs/"
[ "$(ls nsot/data/*.yml 2>/dev/null | wc -l)" -eq 9 ] && ok "all 9 NSOT data files present" || bad "expected 9 YAML files in nsot/data/"

sec "7. NSOT renders the deployed configs exactly"
if python3 -c "import yaml, jinja2" 2>/dev/null; then
    ( cd nsot && python3 scripts/render.py >/dev/null 2>&1 )
    DRIFT=0
    for d in R1 R2 R3 R4 R5 S1 S2 S3 S4; do
        if ! diff -q "nsot/configs/$d.cfg" "configs/$d.cfg" >/dev/null 2>&1; then
            echo -e "       ${R}drift:${N} $d"; DRIFT=$((DRIFT+1))
        fi
    done
    [ "$DRIFT" -eq 0 ] && ok "all 9 render byte-for-byte identical to deployed" \
                       || bad "$DRIFT device(s) differ between nsot/configs and configs"
else
    warn "pyyaml/jinja2 not installed -- skipped. Install: pip3 install -r nsot/requirements.txt"
fi

sec "8. Python dependencies"
python3 -c "import yaml"     2>/dev/null && ok "pyyaml"   || bad "pyyaml missing  -> pip3 install pyyaml"
python3 -c "import jinja2"   2>/dev/null && ok "jinja2"   || bad "jinja2 missing  -> pip3 install jinja2"
python3 -c "import requests" 2>/dev/null && ok "requests" || bad "requests missing -> pip3 install requests"
python3 -c "import flask"    2>/dev/null && ok "flask"    || warn "flask missing (only needed for the NSOT GUI) -> pip3 install flask"

echo
echo -e "${C}==============================================================${N}"
echo -e "   ${G}ok $PASS${N}    ${R}bad $FAIL${N}    ${Y}warn $WARN${N}"
echo -e "${C}==============================================================${N}"
if [ "$FAIL" -eq 0 ]; then
    echo -e "   ${G}Layout verified. Safe to run:  time python3 deploy.py${N}"
else
    echo -e "   ${R}Fix the items above before deploying.${N}"
fi
echo
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
