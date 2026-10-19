# Firecracker MicroVMs: Run Untrusted Code Like Lambda Does, Then Snapshot It

Your AI agent just wrote a script. It looks reasonable. Now what? Run it on your laptop? In a container that shares your host kernel? Or wait 30 seconds for a full VM to boot?

AWS Lambda faced this exact problem at enormous scale: run millions of untrusted functions, keep them isolated from each other, start them fast. Their answer is **Firecracker**, an open-source microVM manager built on KVM. It boots a hardware-isolated virtual machine in about **125 milliseconds** with under **5 MiB** of memory overhead. It powers Lambda and Fargate, and Netlify recently migrated their edge functions to it, reporting roughly **2 ms p99** cold-start latency.

In this tutorial you will boot a Firecracker microVM, run an untrusted script inside it, **snapshot** the running VM, and **restore** it in a brand-new Firecracker process. Snapshot and restore is the killer feature here. It is the same mechanism behind Lambda SnapStart: boot once, snapshot at the ready state, restore in about a second whenever work arrives.

## Prerequisites

- A host with **KVM access**: bare metal or an EC2 bare-metal instance (for example `i3.metal`). Check with:

```bash
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK" || echo "KVM MISSING"
```

It will not work on a regular virtualized EC2 instance or a laptop without KVM. Nested virtualization is the reason, and there is no way around it.

- Firecracker **v1.17.0** (latest at the time of writing), `curl`, `iproute2`, `iptables`, `ssh`.

## Step 1: Download Firecracker, a kernel, and a root filesystem

```bash
ARCH=$(uname -m)
FC_VERSION=v1.17.0

# Firecracker binary
curl -L -o firecracker.tgz \
  https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-$(uname -m).tgz
tar -xzf firecracker.tgz
sudo mv release-${FC_VERSION}-$(uname -m)/firecracker /usr/local/bin/

# Kernel (v1.17.0 also boots bzImage, but the classic vmlinux works everywhere)
wget https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/${ARCH}/kernels/vmlinux.bin -O vmlinux

# Root filesystem: grab a ready-made Ubuntu image from the official
# getting-started guide (firecracker-microvm/firecracker, docs/getting-started.md)
# and its matching SSH key, then lock the key down:
chmod 400 ./ubuntu-*.id_rsa
```

## Step 2: Set up host networking

The guest gets its IP from its MAC address. We create a tap device on the host and let the guest talk through it:

```bash
sudo ip tuntap add dev tap0 mode tap
sudo ip addr add 172.16.0.1/30 dev tap0
sudo ip link set dev tap0 up
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev')
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
```

## Step 3: Boot the microVM through the Firecracker API

Firecracker is configured entirely through a REST API on a Unix socket. Start it in one terminal:

```bash
rm -f /tmp/fc-orig.socket
sudo firecracker --api-sock /tmp/fc-orig.socket
```

In a second terminal, configure and boot (the JSON files live in `configs/` in the accompanying repo):

```bash
SOCK=/tmp/fc-orig.socket

curl --unix-socket $SOCK -X PUT http://localhost/boot-source \
  -H 'Content-Type: application/json' -d @configs/boot-source.json

curl --unix-socket $SOCK -X PUT http://localhost/machine-config \
  -H 'Content-Type: application/json' -d @configs/machine-config.json

curl --unix-socket $SOCK -X PUT http://localhost/drives/rootfs \
  -H 'Content-Type: application/json' -d @configs/drive-rootfs.json

curl --unix-socket $SOCK -X PUT http://localhost/network-interfaces/net1 \
  -H 'Content-Type: application/json' -d @configs/network.json

# API calls are async: give the configuration a beat to land
sleep 0.5

curl --unix-socket $SOCK -X PUT http://localhost/actions \
  -H 'Content-Type: application/json' -d '{"action_type": "InstanceStart"}'

sleep 2
ssh -i ./ubuntu-24.04.id_rsa -o StrictHostKeyChecking=no root@172.16.0.2 \
  "ip route add default via 172.16.0.1 && echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
```

The configs are small and readable. `boot-source.json` points at the kernel, `machine-config.json` asks for 2 vCPUs and 1 GiB of RAM, `drive-rootfs.json` attaches the Ubuntu image as the root device, and `network.json` wires the tap device to the guest MAC `06:00:AC:10:00:02`, which the guest maps to `172.16.0.2`.

## Step 4: Run the untrusted script

`guest/untrusted.sh` stands in for code an AI agent just generated. We have not audited it. That is the entire point: it executes inside a hardware-isolated microVM, not on our host.

```bash
ssh -i ./ubuntu-24.04.id_rsa root@172.16.0.2 'bash -s' < guest/untrusted.sh
```

Expected output (abridged):

```
== whoami / hostname ==
root
localhost
== init process (should be the guest's, not the host's) ==
    PID COMMAND
      1 systemd
== trying to see the host (should fail) ==
ls: cannot access '/host': No such file or directory
== kernel cmdline (microVM kernel) ==
console=ttyS0 reboot=k panic=1
== done. The host never saw any of this. ==
```

The guest has its own PID 1, its own kernel command line, and no path to the host. A container gives you namespaces and cgroups. This gives you a virtual hardware boundary.

## Step 5: Snapshot the running microVM

Snapshotting is a two-phase dance. First pause the VM, freezing all vCPUs and device emulation:

```bash
curl --unix-socket $SOCK -X PATCH http://localhost/vm \
  -H 'Content-Type: application/json' -d '{"state": "Paused"}'
```

Then create a **full** snapshot:

```bash
curl --unix-socket $SOCK -X PUT http://localhost/snapshot/create \
  -H 'Content-Type: application/json' -d @configs/snapshot-create.json
```

where `snapshot-create.json` is:

```json
{
    "snapshot_type": "Full",
    "snapshot_path": "./snapshot/vm.state",
    "mem_file_path": "./snapshot/vm.mem"
}
```

This produces three artifacts: the **state file** (device and emulation state), the **memory file** (a full copy of guest RAM), and your **disk files**, which Firecracker leaves for you to manage. It drains and `fsync`s the block devices during creation, and `fsync`s the snapshot files by default, so the result is durable.

## Step 6: Restore it in a new process, and time it

Kill the original Firecracker process. The snapshot is now just files on disk. Start a fresh process on a new socket, then load:

```bash
rm -f /tmp/fc-restore.socket
sudo firecracker --api-sock /tmp/fc-restore.socket &
sleep 0.5

time curl --unix-socket /tmp/fc-restore.socket -X PUT http://localhost/snapshot/load \
  -H 'Content-Type: application/json' -d @configs/snapshot-load.json
```

with `snapshot-load.json`:

```json
{
    "snapshot_path": "./snapshot/vm.state",
    "mem_backend": {
        "backend_path": "./snapshot/vm.mem",
        "backend_type": "File"
    },
    "resume_vm": true
}
```

A few things worth noticing:

- **Load is only allowed before the VM is configured.** The only things you may set up beforehand are logging and metrics.
- The memory file is **memory-mapped** (`MAP_PRIVATE`), so pages load on demand instead of all up front. That is why restore lands in about a second even for larger guests. (There is also a `Uffd` backend if you want a userspace process to serve page faults.)
- `resume_vm: true` skips the separate resume call. Without it, the loaded VM sits in `Paused` and you resume it with `PATCH /vm {"state": "Resumed"}`.
- The TAP device and disk files must exist at the **same relative paths** for the new process.
- Treat the memory file as **immutable** after loading. It backs guest memory through the page cache; modifying it corrupts the guest.

Verify the restored guest is alive and identical:

```bash
ssh -i ./ubuntu-24.04.id_rsa root@172.16.0.2 "uptime; ls /tmp"
```

## The pattern: pre-warmed sandboxes for agent code

This is the use case that makes the feature matter. Instead of booting a sandbox per task:

1. Boot one template microVM with your toolchain baked into the rootfs.
2. Warm it to the ready state (agent runtime listening, dependencies loaded).
3. Snapshot it. Terminate the original.
4. For every task: load the snapshot in a fresh Firecracker process, hand the task to the agent, destroy the VM when done.

Every task gets a pristine, hardware-isolated environment in about a second, and nothing persists between tasks. Boot cost is paid once, amortized over thousands of restores. This is Lambda SnapStart's trick, and it is exactly what Netlify now does at the edge: snapshot when the runtime is listening, scale to zero, restore from the memory-mapped snapshot on the next request.

## Gotchas worth knowing before production

- **Vsock resets on snapshot.** Open vsock connections close; listen sockets in the guest survive and accept new connections after resume.
- **Network is not guaranteed across restore.** Plan to re-establish connectivity rather than assuming it survives.
- **Snapshot files are only CRC-checked.** Firecracker trusts the host and the files. If snapshots cross a trust boundary, encrypt and authenticate them yourself.
- **Never resume the same snapshot twice** in production. Identifiers, entropy pools, and tokens would be duplicated. If guests must detect restores, expose the VMGenID device.
- **The guest clock freezes** at snapshot time. Update it after restore, or pass `clock_realtime: true` on load (needs host kernel 5.16+).
- **Snapshot after the kernel has booted**, not during early boot, or the restore may crash.
- **Diff snapshots are still developer preview.** Full snapshots are the stable path.
- In production, run Firecracker under the **`jailer`** for an extra containment layer.

## Reality check: your microVM is the security boundary, and boundaries get breached

This tutorial treats the Firecracker microVM as a hardware-isolated sandbox for untrusted agent code. On October 3, 2026, security researcher Paulos Yibelo demonstrated that the isolation boundary itself is not bulletproof: he reported a full KVM guest-to-host escape, code running inside a guest VM obtaining root access on the host, through Vercel's Sandbox bug bounty program. Vercel confirmed it was a KVM zero-day and paid him the program's maximum $50,000 bounty.

Why this matters for you: Vercel Sandbox runs untrusted AI workloads, including AI agent code, inside Firecracker microVMs on bare-metal EC2 hosts, and Vercel identifies the microVM, not the container, as its primary security boundary. The exact boundary this tutorial builds on. Yibelo's finding crosses exactly that line.

Important caveats before you reuse this:

- The exploit chain, affected KVM/kernel versions, and CVE identifier are still undisclosed. Vercel CEO Guillermo Rauch said a technical write-up is coming. No customer data theft or widespread exploitation has been established.
- So treat this as a threat-model lesson, not a patch instruction: snapshot and restore is a deployment optimization, not a security control. Your actual containment stack is the `jailer`, cgroup limits, host egress filtering, and keeping the host kernel patched.
- Assume breach: log and monitor the host side too, because the boundary you trust the most deserves the most suspicion.

Sources:
- https://cybersecuritynews.com/kvm-zero-day-vm-escape/
- https://aws.amazon.com/security/security-bulletins/2026-124-aws/ (related: AWS patched its own agent-platform auth bypass the same week)

<!-- TODO before publishing: confirm the technical write-up and CVE status of the Yibelo KVM zero-day (still undisclosed as of Oct 19, 2026) and update this section if they land. -->

## Wrapping up

You booted a hardware-isolated microVM in a fraction of a second, ran untrusted code inside it, froze it to disk, and brought it back to life in a new process. That loop, boot, snapshot, restore, is the core mechanic behind serverless cold starts done right.

Natural next steps: the `jailer` for production hardening, vsock for host-to-guest communication without networking, and if you manage fleets of these, the Terraform provider for Firecracker to keep the host pools declarative.
