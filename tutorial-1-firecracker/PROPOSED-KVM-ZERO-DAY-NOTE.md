# Proposed addition: threat-model reality check (Oct 5, 2026)

Status: APPROVED and inserted into TUTORIAL.md on Oct 19, 2026. Outstanding: confirm the Yibelo technical write-up and CVE status before publishing (tracked as an HTML comment in TUTORIAL.md).

---

## Reality check: your microVM is the security boundary, and boundaries get breached

This tutorial treats the Firecracker microVM as a hardware-isolated sandbox for untrusted agent code. On October 3, 2026, security researcher Paulos Yibelo demonstrated that the isolation boundary itself is not bulletproof: he reported a full KVM guest-to-host escape, code running inside a guest VM obtaining root access on the host, through Vercel's Sandbox bug bounty program. Vercel confirmed it was a KVM zero-day and paid him the program's maximum $50,000 bounty.

Why this matters for you: Vercel Sandbox runs untrusted AI workloads, including AI agent code, inside Firecracker microVMs on bare-metal EC2 hosts, and Vercel identifies the microVM, not the container, as its primary security boundary. The exact boundary this tutorial builds on. Yibelo's finding crosses exactly that line.

Important caveats before you reuse this:

- The exploit chain, affected KVM/kernel versions, and CVE identifier are still undisclosed. Vercel CEO Guillermo Rauch said a technical write-up is coming. No customer data theft or widespread exploitation has been established.
- So treat this as a threat-model lesson, not a patch instruction: snapshot and restore is a deployment optimization, not a security control. Your actual containment stack is the `jailer`, cgroup limits, host egress filtering, and keeping the host kernel patched.
- Assume breach: log and monitor the host side too, because the boundary you trust the most deserves the most suspicion.

This is a timely hook for the tutorial's intro or conclusion. The story was first reported October 3-4, 2026; confirm the technical write-up and CVE status before publishing.

Sources:
- https://cybersecuritynews.com/kvm-zero-day-vm-escape/
- https://aws.amazon.com/security/security-bulletins/2026-124-aws/ (related: AWS patched its own agent-platform auth bypass the same week)
