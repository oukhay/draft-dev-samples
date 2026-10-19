# Tutorial 1: Firecracker MicroVMs (Draft.dev writing sample)

**Status:** draft, ready for a test run on a KVM host before publishing.

## What this is

Writing sample #1 for a Draft.dev technical-writer application. Target: a
~1,500-word hands-on tutorial with tested configuration. Topic chosen because
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
- **Not yet executed end-to-end**: this sandbox has no `/dev/kvm`, so the
  boot/snapshot/restore cycle has not been run here. Before publishing, run
  `scripts/01-boot.sh`, `02-snapshot.sh`, `03-restore.sh` on a KVM-capable
  host (bare metal or an EC2 `metal` instance) and paste the real outputs
  into `TUTORIAL.md` where marked.

## Publishing plan

1. Run on a KVM host, capture real outputs.
2. Publish on dev.to as writing sample #1.
3. Link from the Draft.dev application (draft.dev/write) under samples.
