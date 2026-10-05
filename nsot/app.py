#!/usr/bin/env python3
"""
app.py -- Network Source of Truth web GUI.

A deliberately small Flask app over the NSOT repo:
  * lists devices held in data/*.yml
  * shows the rendered config for any device
  * adds a new device from a form (writes YAML, renders config)
  * renders all devices and saves timestamped golden snapshots
  * embeds the Grafana dashboard from the monitoring lab

Run:  python3 app.py     then open http://localhost:5000
"""
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import yaml
from flask import Flask, render_template_string, request, redirect, url_for, flash

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
CONFIGS = ROOT / "configs"
GOLDEN = ROOT / "golden"
SCRIPTS = ROOT / "scripts"

# Change this if Grafana runs elsewhere. The dashboard UID comes from
# rcn-dashboard.json in the monitoring lab.
GRAFANA_URL = "http://localhost:3000/d/rcn-net/rcn-network-monitoring?kiosk"

app = Flask(__name__)
app.secret_key = "rcn-nsot"

PAGE = """
<!doctype html>
<title>RCN Network Source of Truth</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 0; background: #111; color: #eee; }
  header { background: #1a1a2e; padding: 14px 24px; border-bottom: 2px solid #0f3460; }
  header h1 { margin: 0; font-size: 19px; }
  nav a { color: #7cc; margin-right: 18px; text-decoration: none; font-size: 14px; }
  main { padding: 20px 24px; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #333; font-size: 14px; }
  th { color: #7cc; }
  pre { background: #0a0a0a; padding: 14px; overflow-x: auto; font-size: 12px;
        border: 1px solid #333; max-height: 520px; }
  form { background: #1a1a2e; padding: 16px; border: 1px solid #0f3460; max-width: 520px; }
  label { display: block; margin: 9px 0 3px; font-size: 13px; color: #aaa; }
  input, select { width: 100%; padding: 6px; background: #0a0a0a; color: #eee;
                  border: 1px solid #444; font-size: 13px; }
  button { margin-top: 14px; padding: 8px 18px; background: #0f3460; color: #eee;
           border: none; cursor: pointer; font-size: 14px; }
  button:hover { background: #16508f; }
  .msg { background: #14361e; border-left: 3px solid #3a3; padding: 9px 12px;
         margin-bottom: 16px; font-size: 14px; }
  .muted { color: #888; font-size: 13px; }
  iframe { width: 100%; height: 780px; border: 1px solid #333; }
</style>
<header>
  <h1>RCN &mdash; Network Source of Truth</h1>
  <nav>
    <a href="{{ url_for('index') }}">Devices</a>
    <a href="{{ url_for('add') }}">Add device</a>
    <a href="{{ url_for('golden_view') }}">Golden configs</a>
    <a href="{{ url_for('monitoring') }}">Monitoring</a>
  </nav>
</header>
<main>
{% with messages = get_flashed_messages() %}
  {% for m in messages %}<div class="msg">{{ m }}</div>{% endfor %}
{% endwith %}
{{ body|safe }}
</main>
"""


def page(body):
    return render_template_string(PAGE, body=body)


def load_devices():
    devices = []
    for f in sorted(DATA.glob("*.yml")):
        d = yaml.safe_load(f.read_text())
        devices.append(d)
    return devices


def run_script(name, *args):
    """Run a helper script and return its combined output."""
    result = subprocess.run(
        [sys.executable, str(SCRIPTS / name), *args],
        capture_output=True, text=True, cwd=str(ROOT)
    )
    return (result.stdout + result.stderr).strip()


@app.route("/")
def index():
    devices = load_devices()
    rows = "".join(
        f"<tr><td><a href='{url_for('show', hostname=d['hostname'])}' "
        f"style='color:#7cc'>{d['hostname']}</a></td>"
        f"<td>{d.get('vendor','')}</td><td>{d.get('role','')}</td>"
        f"<td class='muted'>{len(d.get('interfaces', []))} interfaces</td></tr>"
        for d in devices
    )
    body = f"""
    <p class="muted">{len(devices)} devices defined in <code>data/</code>.
       Each YAML file is the single source of truth for that device.</p>
    <table>
      <tr><th>Device</th><th>Vendor</th><th>Role</th><th></th></tr>
      {rows}
    </table>
    <form method="post" action="{url_for('render_all')}">
      <button type="submit">Render all configs</button>
      <span class="muted" style="margin-left:12px">
        Regenerates <code>configs/*.cfg</code> from YAML via Jinja2</span>
    </form>
    """
    return page(body)


@app.route("/device/<hostname>")
def show(hostname):
    yml = DATA / f"{hostname}.yml"
    cfg = CONFIGS / f"{hostname}.cfg"
    if not yml.exists():
        flash(f"No such device: {hostname}")
        return redirect(url_for("index"))
    rendered = cfg.read_text() if cfg.exists() else "(not rendered yet)"
    body = f"""
    <h2>{hostname}</h2>
    <h3 class="muted">Source of truth &mdash; data/{hostname}.yml</h3>
    <pre>{yml.read_text()}</pre>
    <h3 class="muted">Rendered config &mdash; configs/{hostname}.cfg</h3>
    <pre>{rendered}</pre>
    """
    return page(body)


@app.route("/add", methods=["GET", "POST"])
def add():
    if request.method == "POST":
        hostname = request.form["hostname"].strip()
        if not hostname:
            flash("Hostname is required")
            return redirect(url_for("add"))
        if (DATA / f"{hostname}.yml").exists():
            flash(f"{hostname} already exists")
            return redirect(url_for("add"))

        device = {
            "hostname": hostname,
            "vendor": request.form["vendor"],
            "role": request.form["role"],
            "mgmt": {
                "snmp_host": request.form["snmp_host"],
                "syslog_host": request.form["snmp_host"],
                "community": "public",
            },
            "interfaces": [{
                "name": "Ethernet1",
                "description": "WAN_UPLINK",
                "routed": True,
                "ipv4": request.form["wan_ip"],
            }],
        }

        protocol = request.form["protocol"]
        if protocol == "isis":
            device["isis"] = {
                "instance": "LOWER",
                "net": request.form.get("isis_net") or "49.0001.0000.0000.0099.00",
            }
            device["interfaces"][0]["isis"] = "p2p"
        elif protocol == "ospf":
            device["ospf"] = {"router_id": request.form.get("router_id") or "10.255.0.99"}
            device["interfaces"][0]["ospf"] = "p2p"
        elif protocol == "bgp":
            device["bgp"] = {
                "asn": int(request.form.get("bgp_asn") or 65000),
                "neighbors": [],
            }

        (DATA / f"{hostname}.yml").write_text(
            yaml.safe_dump(device, sort_keys=False, default_flow_style=False)
        )
        out = run_script("render.py", hostname)
        flash(f"Added {hostname}. {out}")
        return redirect(url_for("show", hostname=hostname))

    body = """
    <h2>Add a device</h2>
    <p class="muted">Writes a new YAML file to <code>data/</code> and renders its
       config. Commit the result to record the change.</p>
    <form method="post">
      <label>Hostname</label>
      <input name="hostname" placeholder="R6" required>

      <label>Vendor / template</label>
      <select name="vendor">
        <option value="arista_eos">arista_eos (arista_eos.j2)</option>
      </select>

      <label>Role</label>
      <select name="role">
        <option value="access_router">access_router</option>
        <option value="core_router">core_router</option>
        <option value="access_switch">access_switch</option>
        <option value="boundary_switch">boundary_switch</option>
      </select>

      <label>WAN IP (Ethernet1)</label>
      <input name="wan_ip" placeholder="10.20.0.33/30" required>

      <label>Routing protocol</label>
      <select name="protocol">
        <option value="isis">IS-IS</option>
        <option value="ospf">OSPF</option>
        <option value="bgp">BGP</option>
        <option value="none">None</option>
      </select>

      <label>IS-IS NET (if IS-IS)</label>
      <input name="isis_net" placeholder="49.0001.0000.0000.0099.00">

      <label>Router ID (if OSPF)</label>
      <input name="router_id" placeholder="10.255.0.99">

      <label>BGP ASN (if BGP)</label>
      <input name="bgp_asn" placeholder="65000">

      <label>SNMP / Syslog collector</label>
      <input name="snmp_host" value="172.20.20.13">

      <button type="submit">Create device</button>
    </form>
    """
    return page(body)


@app.route("/render-all", methods=["POST"])
def render_all():
    flash(run_script("render.py"))
    return redirect(url_for("index"))


@app.route("/golden", methods=["GET", "POST"])
def golden_view():
    if request.method == "POST":
        flash(run_script("golden.py"))
        return redirect(url_for("golden_view"))

    snaps = sorted(
        (d for d in GOLDEN.iterdir() if d.is_dir()), reverse=True
    ) if GOLDEN.exists() else []
    rows = "".join(
        f"<tr><td>{s.name}</td><td class='muted'>{len(list(s.glob('*.cfg')))} configs</td></tr>"
        for s in snaps
    ) or "<tr><td class='muted' colspan=2>No snapshots yet</td></tr>"

    body = f"""
    <h2>Golden configurations</h2>
    <p class="muted">Each snapshot is a timestamped copy of <code>configs/</code>,
       kept so any known-good state can be restored or diffed.</p>
    <form method="post"><button type="submit">Save golden snapshot</button></form>
    <br>
    <table><tr><th>Timestamp</th><th></th></tr>{rows}</table>
    """
    return page(body)


@app.route("/monitoring")
def monitoring():
    body = f"""
    <h2>Network monitoring</h2>
    <p class="muted">Live Grafana dashboard from the monitoring lab &mdash;
       gNMI streaming telemetry via Telegraf into InfluxDB.
       If the frame is blank, open <a href="{GRAFANA_URL}" style="color:#7cc">
       the dashboard directly</a>.</p>
    <iframe src="{GRAFANA_URL}"></iframe>
    """
    return page(body)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
