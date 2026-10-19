#!/bin/bash
# 01-boot.sh — set up host networking, start Firecracker, configure and boot one microVM.
set -euo pipefail

SOCK="/tmp/fc-orig.socket"
CFG_DIR="$(cd "$(dirname "$0")/../configs" && pwd)"

[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK" || { echo "KVM missing, aborting"; exit 1; }

# Host networking: tap device for the guest
sudo ip link del tap0 2>/dev/null || true
sudo ip tuntap add dev tap0 mode tap
sudo ip addr add 172.16.0.1/30 dev tap0
sudo ip link set dev tap0 up
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev')
sudo iptables -t nat -C POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE

# Start Firecracker (run this in its own terminal in practice)
rm -f "$SOCK"
sudo firecracker --api-sock "$SOCK" &
FC_PID=$!
sleep 0.5

api() { sudo curl --fail -s --unix-socket "$SOCK" -X PUT "http://localhost$1" \
  -H 'Content-Type: application/json' -d "@$2"; }

api /boot-source "$CFG_DIR/boot-source.json"
api /machine-config "$CFG_DIR/machine-config.json"
api /drives/rootfs "$CFG_DIR/drive-rootfs.json"
api /network-interfaces/net1 "$CFG_DIR/network.json"

sleep 0.5
sudo curl --fail -s --unix-socket "$SOCK" -X PUT http://localhost/actions \
  -H 'Content-Type: application/json' -d '{"action_type": "InstanceStart"}'
echo "microVM booting (firecracker pid $FC_PID)"

sleep 2
KEY=(./ubuntu-*.id_rsa)
ssh -i "${KEY[0]}" -o StrictHostKeyChecking=no root@172.16.0.2 \
  "ip route add default via 172.16.0.1 && echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
echo "guest reachable at 172.16.0.2"
