#!/bin/bash
# 03-restore.sh — load the snapshot in a fresh Firecracker process and resume it.
set -euo pipefail

SOCK="/tmp/fc-restore.socket"
CFG_DIR="$(cd "$(dirname "$0")/../configs" && pwd)"

[ -f ./snapshot/vm.state ] || { echo "no snapshot found, run 02-snapshot.sh first"; exit 1; }

# The tap device and disk image must exist at the same relative paths
sudo ip link show tap0 >/dev/null 2>&1 || {
  sudo ip tuntap add dev tap0 mode tap
  sudo ip addr add 172.16.0.1/30 dev tap0
  sudo ip link set dev tap0 up
}

rm -f "$SOCK"
sudo firecracker --api-sock "$SOCK" &
sleep 0.5

# Load must happen before any VM configuration; resume_vm brings it straight up
time sudo curl --fail -s --unix-socket "$SOCK" -X PUT http://localhost/snapshot/load \
  -H 'Content-Type: application/json' -d "@$CFG_DIR/snapshot-load.json"
echo "microVM restored and resumed"

KEY=(./ubuntu-*.id_rsa)
ssh -i "${KEY[0]}" -o StrictHostKeyChecking=no root@172.16.0.2 "uptime"
