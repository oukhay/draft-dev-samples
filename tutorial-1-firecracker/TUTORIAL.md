# Firecracker MicroVMs: Run Untrusted Code Like Lambda Does, Then Snapshot It

Your AI agent just wrote a script. It looks reasonable. Now what? Run it on your laptop? In a container that shares your host kernel? Or wait 30 seconds for a full VM to boot?

AWS Lambda faced this exact problem at enormous scale: run millions of untrusted functions, keep them isolated from each other, start them fast. Their answer is **Firecracker**, an open-source microVM manager built on KVM. It boots a hardware-isolated virtual machine in about **125 milliseconds** with under **5 MiB** of memory overhead. It powers Lambda and Fargate, and Netlify recently migrated their edge functions to it, reporting roughly **2 ms p99** cold-start latency.

In this tutorial you will boot a Firecracker microVM, run an untrusted script inside it, **snapshot** the running VM, and **restore** it in a brand-new Firecracker process. Snapshot and restore is the killer feature here. It is the same mechanism behind Lambda SnapStart: boot once, snapshot at the ready state, restore in about a second whenever work arrives.

## Prerequisites

- A host with **KVM access**: a physical machine with virtualization enabled in the BIOS, or an EC2 virtual instance with nested virtualization turned on (for example `c8i.xlarge` with `--cpu-options "NestedVirtualization=enabled"`; supported on the c8i, m8i and r8i families, off by default, enable at launch). Bare metal (for example `i3.metal`) still works but is only a fallback now. Check with:

```bash
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK" || echo "KVM MISSING"
```

It will not work on a regular virtualized EC2 instance with nested virtualization off, or on a laptop without KVM. See `KVM-TEST-RUN.md` for the full host options and costs.

- Firecracker **v1.17.0** (latest at the time of writing), `curl`, `wget`, `iproute2`, `iptables`, `ssh`, plus `squashfs-tools` and `e2fsprogs` (Step 1 builds the root filesystem with `unsquashfs` and `mkfs.ext4`).

## Step 1: Download Firecracker, a kernel, and a root filesystem

```bash
ARCH=$(uname -m)
FC_VERSION=v1.17.0
S3="https://s3.amazonaws.com/spec.ccfc.min"

# Firecracker binary (the binary inside the tarball carries a version suffix)
curl -L -o firecracker.tgz \
  https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz
tar -xzf firecracker.tgz
sudo install -m 755 release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH} \
  /usr/local/bin/firecracker

# The kernel and root filesystem come from the Firecracker CI artifacts, the
# same source the official getting-started guide uses. Find the latest build:
CI_ARTIFACTS_PREFIX=$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
  | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" | sort | tail -1)

# Kernel: grab the newest vmlinux-* and save it as ./vmlinux
latest_kernel_key=$(curl -fsSL "$S3?list-type=2&prefix=${CI_ARTIFACTS_PREFIX}${ARCH}/vmlinux-" \
  | grep -oP "(?<=<Key>)(${CI_ARTIFACTS_PREFIX}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
  | sort -V | tail -1)
wget "$S3/${latest_kernel_key}" -O vmlinux

# Root filesystem: the CI image is a squashfs with no SSH key baked in, so
# generate one, patch the public key into the image, and build an ext4 from it
latest_ubuntu_key=$(curl -fsSL "$S3?list-type=2&prefix=${CI_ARTIFACTS_PREFIX}${ARCH}/ubuntu-" \
  | grep -oP "(?<=<Key>)(${CI_ARTIFACTS_PREFIX}${ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
  | sort -V | tail -1)
ubuntu_version=$(basename $latest_ubuntu_key .squashfs | grep -oE '[0-9]+\.[0-9]+')
wget -O ubuntu-$ubuntu_version.squashfs.upstream "$S3/$latest_ubuntu_key"
unsquashfs ubuntu-$ubuntu_version.squashfs.upstream
ssh-keygen -f id_rsa -N ""
mkdir -p squashfs-root/root/.ssh
cp id_rsa.pub squashfs-root/root/.ssh/authorized_keys
mv id_rsa ./ubuntu-$ubuntu_version.id_rsa
sudo chown -R root:root squashfs-root
truncate -s 1G ubuntu-$ubuntu_version.ext4
sudo mkfs.ext4 -d squashfs-root -F ubuntu-$ubuntu_version.ext4
chmod 400 ./ubuntu-$ubuntu_version.id_rsa
```

Two traps this step avoids, both verified the hard way. First, the old
quickstart kernel still floating around (`vmlinux.bin`, kernel 4.14) boots,
but Ubuntu 24.04's systemd warns it is below its 4.15 baseline and the
guest's sshd stalls for many minutes waiting on entropy, so every SSH step
below looks broken. The CI kernel (6.18 in the verified run) is the matched
pair for the CI rootfs and boots to SSH in about a minute. Second, there is
no prebuilt `ubuntu-24.04.ext4` to download anymore; the squashfs build
above is the current official flow.

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
ubuntu-fc-uvm
== init process (should be the guest's, not the host's) ==
    PID
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

Measured on the c8i.xlarge test host (nested virtualization), that `time`
came back at **0.093s** real, and Firecracker's own log put the load request
at 4.1 ms. The restored guest answered SSH immediately, with its uptime
continuing from the original boot, because the guest clock is part of the
snapshot.

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
