# KVM test run for tutorial 1: options and runbook

Draft. Status: research done Oct 6, 2026. The tutorial says you need bare metal
or an EC2 bare metal instance for /dev/kvm. That requirement is outdated now.
AWS added nested virtualization on regular virtual EC2 instances in Feb 2026,
so you can run KVM (and Firecracker) on a cheap virtual instance. Costs below
are estimates, verify in the console before launching.

## Option A: EC2 virtual instance with nested virtualization (recommended)

- Instance: c8i.xlarge (4 vCPU, 8 GB), us-east-1
- Launch flag: nested virtualization ON. Console: EC2 launch wizard, Advanced
  details, Nested virtualization, Enable. CLI:

```bash
aws ec2 run-instances \
  --image-id ami-xxxxxxxxxxxxxxxxx \
  --instance-type c8i.xlarge \
  --key-name your-key \
  --cpu-options "NestedVirtualization=enabled" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=firecracker-test}]'
```

- Supported types include c8i, m8i, r8i and some 7th gen families (c7i, m7i, r7i,
  i7i). It is off by default and can only be changed while the instance is
  stopped.
- Cost estimate: about $0.20/hr on demand, about $0.06/hr on spot. A two hour
  test session is well under a dollar. Terminate when done.

## Option B: Google Cloud nested virtualization

- Firecracker's own dev setup docs use this path. Command:

```bash
gcloud compute instances create firecracker-vm \
  --enable-nested-virtualization \
  --zone=us-east1-b \
  --min-cpu-platform="Intel Haswell" \
  --machine-type=n2-standard-2
```

- Verify: `grep -cw vmx /proc/cpuinfo` should return non-zero, then
  `sudo setfacl -m u:${USER}:rw /dev/kvm`.
- E2 and N2D machine types do not support nested virt. N2 works.
- Cost: cents per hour. Delete the VM when done.

## Option C: bare metal (fallback only)

- i3.metal in us-east-1, about $4.99/hr on demand. Use only if snapshot/restore
  misbehaves on nested KVM (see the caveat below). Two hours is about $10.

## Runbook once the host is up

1. Confirm KVM: `[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK"`.
2. Clone or copy the tutorial directory onto the host
   (`~/workspace/draft-dev-samples/tutorial-1-firecracker/`).
3. Run the three scripts in order: 01-boot.sh, 02-snapshot.sh (name may differ,
   check scripts/), 03-restore.sh.
4. Verify: the microVM boots in about 125 ms, the untrusted script runs, the
   snapshot is created, and the restore comes back in about a second.
5. Note any output differences from what TUTORIAL.md claims, then update the
   tutorial text to match what actually happened.
6. Terminate the instance or delete the VM. Do not leave it running.

## Caveat: snapshot/restore on nested KVM

One project (vanpelt/sparky, measured Sep 2026) found Firecracker's pause and
snapshot breaking on nested KVM: the snapshot wrote fine but the restored guest
hit a host kernel BUG at arch/x86/kvm/x86.c:511. That was their own host
kernel, not Nitro or GCE, so it may not apply here. Try Option A first. If
snapshot/restore fails on the nested host, the bare metal fallback (Option C)
is the faithful environment and what the tutorial claims.

## Why this matters now

The KVM test run is the last blocker before tutorial 1 can be published on
dev.to. It is the Draft.dev phase 1 foundation work meant to land before the
Tunisia trip on Oct 12. The whole session takes about an hour of wall time.

## Sources

- AWS nested virtualization launch (Feb 2026):
  https://aws.amazon.com/about-aws/whats-new/2026/02/amazon-ec2-nested-virtualization-on-virtual/
- AWS re:Post steps (console and CLI):
  https://repost.aws/articles/ARowyP4itvSfSZEmflfvtbUA/nested-virtualization-on-virtual-amazon-ec2-instances
- Firecracker dev machine setup on GCP (official project docs):
  https://github.com/firecracker-microvm/firecracker/blob/HEAD/docs/dev-machine-setup.md
- i3.metal pricing (Vantage, from AWS published rates):
  https://instances.vantage.sh/aws/ec2/i3.metal
