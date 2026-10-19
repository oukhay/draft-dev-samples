#!/bin/bash
# 02-snapshot.sh — pause the running microVM and take a full snapshot.
set -euo pipefail

SOCK="/tmp/fc-orig.socket"
CFG_DIR="$(cd "$(dirname "$0")/../configs" && pwd)"
mkdir -p ./snapshot

# Pause: freezes vCPUs and device emulation (prerequisite for snapshot)
sudo curl --fail -s --unix-socket "$SOCK" -X PATCH http://localhost/vm \
  -H 'Content-Type: application/json' -d '{"state": "Paused"}'
echo "microVM paused"

# Full snapshot: device state -> vm.state, guest RAM -> vm.mem
sudo curl --fail -s --unix-socket "$SOCK" -X PUT http://localhost/snapshot/create \
  -H 'Content-Type: application/json' -d "@$CFG_DIR/snapshot-create.json"
echo "snapshot written to ./snapshot/"

# The original VM can now be terminated; the snapshot files are self-contained
# (plus the disk image, which stays user-managed).
sudo pkill -f "firecracker --api-sock $SOCK" || true
echo "original Firecracker process stopped"
