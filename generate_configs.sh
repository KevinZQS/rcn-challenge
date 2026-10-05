#!/bin/bash
# Generates Telegraf + Grafana datasource configs with CURRENT device IPs.
# Container IPs change on every containerlab deploy, so run this after
# each deploy, then restart Telegraf and Grafana.

IP() { docker inspect clab-rcn-challenge-$1 --format '{{.NetworkSettings.Networks.clab.IPAddress}}' 2>/dev/null; }

INFLUX=$(IP InfluxDB)
if [ -z "$INFLUX" ]; then
  echo "!! InfluxDB not found -- is the lab deployed?"
  exit 1
fi
echo "[gen] InfluxDB at $INFLUX"

mkdir -p configs/grafana/datasources configs/grafana/dashboards

# ----------------------------------------------------------------
# 1. Telegraf
#    One [[inputs.gnmi]] block per device so each can carry a
#    "device" tag with the real hostname. A single flat address
#    list tags metrics by IP instead, which changes every deploy
#    and breaks saved dashboards.
# ----------------------------------------------------------------
OUT=configs/telegraf.conf
cat > $OUT << EOF
[agent]
  debug = true
  interval = "10s"
  flush_interval = "10s"

[[outputs.influxdb_v2]]
  urls = ["http://${INFLUX}:8086"]
  token = "rcn-telemetry-token"
  organization = "rcn"
  bucket = "telemetry"
EOF

for dev in R1 R2 R3 R4 R5 S1 S2 S3 S4; do
  ip=$(IP $dev)
  echo "[gen]   $dev -> $ip"
  cat >> $OUT << EOF

[[inputs.gnmi]]
  addresses = ["${ip}:6030"]
  username = "admin"
  password = "admin"
  encoding = "json_ietf"
  redial = "10s"
  [inputs.gnmi.tags]
    device = "${dev}"
  [[inputs.gnmi.subscription]]
    name = "cpu"
    origin = "openconfig"
    path = "/system/cpus/cpu/state/total/instant"
    subscription_mode = "sample"
    sample_interval = "10s"
  [[inputs.gnmi.subscription]]
    name = "interfaces"
    origin = "openconfig"
    path = "/interfaces/interface/state/counters"
    subscription_mode = "sample"
    sample_interval = "10s"
  [[inputs.gnmi.subscription]]
    name = "oper_status"
    origin = "openconfig"
    path = "/interfaces/interface/state/oper-status"
    subscription_mode = "sample"
    sample_interval = "10s"
EOF
done
echo "[gen] wrote $OUT"

# ----------------------------------------------------------------
# 2. Grafana datasource (provisioned -- no clicking required)
# ----------------------------------------------------------------
cat > configs/grafana/datasources/influxdb.yml << EOF
apiVersion: 1
datasources:
  - name: influxdb
    type: influxdb
    access: proxy
    uid: rcn-influx
    url: http://${INFLUX}:8086
    isDefault: true
    jsonData:
      version: Flux
      organization: rcn
      defaultBucket: telemetry
      tlsSkipVerify: true
    secureJsonData:
      token: rcn-telemetry-token
EOF
echo "[gen] wrote configs/grafana/datasources/influxdb.yml"

# ----------------------------------------------------------------
# 3. Grafana dashboard provider (points Grafana at the JSON below)
# ----------------------------------------------------------------
cat > configs/grafana/dashboards/provider.yml << 'EOF'
apiVersion: 1
providers:
  - name: rcn
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF
echo "[gen] wrote configs/grafana/dashboards/provider.yml"
echo "[gen] done -- restart Telegraf and Grafana to pick these up"
