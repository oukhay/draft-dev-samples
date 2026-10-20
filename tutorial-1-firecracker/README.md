# Tutorial 1: Firecracker MicroVMs (Draft.dev writing sample)

**Status:** published. Tested end-to-end on a real KVM host on Oct 20, 2026 and published on dev.to: https://dev.to/oukhay/firecracker-microvms-run-untrusted-code-like-lambda-does-then-snapshot-it-2a6j

## What this is

Writing sample #1 for a Draft.dev technical-writer application. Target: a
~2,300-word hands-on tutorial with tested configuration. Topic chosen because
it sits at the intersection of DevOps, virtualization, and AI-agent
infrastructure, and because snapshot/restore is Firecracker's most important
(and least covered) feature.

- `TUTORIAL.md` — the post itself, dev.to-ready Markdown.
- `configs/` — every Firecracker API payload used in the tutorial, as
  separate JSON files so readers can inspect and reuse them.
- `scripts/` — the boot, snapshot, and restore sequences as shell scripts.
- `guest/untrusted.sh` — the "untrusted agent-generated script" run inside
  the guest to demonstrate isolation.

## Validation status (honest)

- All JSON configs: syntax-validated.
- All shell scripts: syntax-checked with `bash -n` and `shellcheck`.
- API payloads: written against Firecracker **v1.17.0** official docs
  (`docs/snapshotting/snapshot-support.md`, `docs/getting-started.md`,
  read October 2026).
- **Executed end-to-end on Oct 20, 2026**: the full boot, untrusted-script,
  snapshot and restore cycle ran on a Spot `c8i.xlarge` in us-east-1 with
  nested virtualization enabled (see `KVM-TEST-RUN.md` for the run record).
  Snapshot restore measured at 0.093s real time, and the real outputs are
  pasted into `TUTORIAL.md`. The run also caught four tutorial bugs (binary
  name, dead kernel and rootfs downloads, one wrong expected output), all
  fixed in the published text.

## Publishing plan

1. ~~Run on a KVM host, capture real outputs.~~ Done Oct 20, 2026.
2. ~~Publish on dev.to as writing sample #1.~~ Done Oct 20, 2026 (link above).
3. Link from the Draft.dev application (draft.dev/write) under samples. Pending, application planned mid-November 2026.
