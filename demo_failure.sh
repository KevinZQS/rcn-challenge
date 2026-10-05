#!/bin/bash
# Live failure demo for the Grafana dashboard.
# Shuts an interface, waits, then restores it -- so the dashboard
# shows a real link-down event appearing and clearing in real time.
#
# Run this with the Grafana dashboard visible on screen.
# Usage: ./demo_failure.sh [device] [interface] [seconds_down]

DEV=${1:-R1}
IFACE=${2:-Ethernet2}
DOWN=${3:-60}

echo "=============================================="
echo " Failure demo: $DEV $IFACE"
echo " Watch the 'Interface Operational Status' panel"
echo "=============================================="
echo
echo "Telemetry samples every 10s, so allow ~10-20s"
echo "for the dashboard to reflect each change."
echo
read -p "Press Enter to bring $DEV $IFACE DOWN..."

docker exec -i clab-rcn-challenge-$DEV Cli -p 15 << EOF
configure terminal
interface $IFACE
shutdown
end
EOF

echo
echo ">>> $IFACE is now DOWN. Watch the panel turn red."
echo ">>> Holding for ${DOWN}s..."
for i in $(seq $DOWN -10 10); do
  echo "    ${i}s remaining"
  sleep 10
done

echo
read -p "Press Enter to bring $DEV $IFACE back UP..."

docker exec -i clab-rcn-challenge-$DEV Cli -p 15 << EOF
configure terminal
interface $IFACE
no shutdown
end
EOF

echo
echo ">>> $IFACE restored. Panel should return to green within ~20s."
echo
echo "Current state on the device:"
sleep 5
docker exec clab-rcn-challenge-$DEV Cli -c "show interfaces $IFACE status"
