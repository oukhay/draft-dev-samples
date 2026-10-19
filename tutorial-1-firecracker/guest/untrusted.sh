#!/bin/bash
# untrusted.sh — stands in for "code an AI agent just generated".
# We have not audited it. That is the entire point: it runs inside a
# hardware-isolated microVM, never on the host.
set -euo pipefail

echo "== whoami / hostname =="
whoami
hostname

echo "== init process (should be the guest's, not the host's) =="
ps -p 1 -o pid,comm=

echo "== trying to see the host (should fail) =="
ls /host 2>&1 | head -2 || true

echo "== kernel cmdline (this is the microVM kernel) =="
cat /proc/cmdline

echo "== done. The host never saw any of this. =="
