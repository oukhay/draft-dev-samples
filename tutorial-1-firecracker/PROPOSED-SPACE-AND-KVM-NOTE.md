# Proposed addition: production proof from Perplexity SPACE + cheaper KVM host options (Oct 18, 2026)

Status: DRAFT for Hamed's approval. Nothing inserted into TUTORIAL.md yet.

---

## Part 1: production proof paragraph

Suggested placement: at the end of the pre-warmed sandbox use-case section, right before "## Gotchas worth knowing before production".

Copy-pasteable text:

> This is not just a tutorial pattern. Perplexity open-sourced SPACE (Sandboxed Platform for Agentic Code Execution) on October 15, 2026 under Apache 2.0, the exact platform that has run every session of its Perplexity Computer agent since July 2026. Each agent task gets its own Firecracker microVM: a template supplies the starting filesystem, a sandbox is one instance of it with its own VM and writable disk, and the control plane creates, pauses, resumes, and clones sandboxes over HTTP. SPACE stores file-snapshot diffs instead of copying whole environments, which is what makes pause, resume, and branching cheap. Perplexity claims millions of sandbox creations per day with median create latency of 60 ms. In other words: boot once, snapshot, restore per task is the same trick this tutorial teaches, now validated at production scale.

Caveats to keep in the text (do not drop these):

- SPACE is a full Rust control plane with an HTTP API and server-sent events, not the raw Firecracker API flow this tutorial teaches. It is proof the pattern scales, not a replacement for the steps above.
- All scale and latency numbers are Perplexity's claims, no independent verification.
- SPACE's own security testing found the isolation boundary held (0 of 108 VM-to-host escapes across 9 frontier models) but agents bypassed egress policy in 11 of 54 partial-network runs before fixes. That maps to the existing gotcha: the microVM is not the whole security story, egress filtering and the `jailer` matter.

Sources:
- https://www.marktechpost.com/2026/10/16/perplexity-open-sources-space-firecracker-microvm-sandbox-ai-agents/
- https://dev.to/clydaralab/perplexity-open-sourced-space-the-vm-held-the-network-rules-did-not-58j8
- https://www.unite.ai/perplexity-open-sources-space-its-in-house-agent-sandbox-platform/

---

## Part 2: cheaper KVM host options for the test run

The Prerequisites section currently says "bare metal or an EC2 bare-metal instance (for example `i3.metal`)". An i3.metal is about 4.50 USD/hour, roughly 100+ USD for a weekend of testing. For a one-evening script test run, propose this replacement text instead:

> - A host with **KVM access**: you need `/dev/kvm` on real hardware. Check with:
>
> ```bash
> [ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK" || echo "KVM MISSING"
> ```
>
> Regular cloud VMs (EC2, Hetzner Cloud, etc.) do not expose `/dev/kvm`. For a cheap one-evening test, two realistic options: a Vultr bare-metal instance with hourly billing (spin it up, run the scripts, destroy it the same night) or a netcup Root Server (dedicated physical cores with nested KVM support, month-to-month, cancel after the month). An EC2 bare-metal instance like `i3.metal` also works but costs far more per hour. It will not work on a laptop without KVM, and there is no way around that.

Notes for the decision (not for the tutorial):
- Hetzner dedicated AX42 is the cheapest legitimate bare metal at EUR 57.30/month (verified Oct 2026), but it is monthly-only billing, so it only wins if the box will be reused for more than a few weeks.
- Prices change; verify the exact hourly/monthly rate at checkout before choosing.
- The test run still gates publishing: run the three scripts end to end on the host and paste the real outputs into the tutorial before the dev.to post.
