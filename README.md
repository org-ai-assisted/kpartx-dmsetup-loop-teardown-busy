# kpartx / device-mapper loop-partition teardown: opaque "busy" hides a transient open count

Minimal reproducers and fix evidence for a usability defect that repeatedly makes
operators (and build tools) believe a wedged loop/partition device-mapper map
needs a reboot, when it does not.

## The short version

When a disk-image build tears down its loop + kpartx partition maps, a partition
map (`/dev/mapper/loopNpM`) can briefly still be open by a transient holder (a
`udev`/`blkid` worker, a `systemd` auto-activation on the image's partition
signatures, or a probe in another mount namespace). During that window:

- `dmsetup remove loopNpM` fails with a bare **`Device or resource busy`** -- no
  open count, no holder. The operator cannot tell *why* it is busy or *who* holds
  it.
- `dmsetup remove --force` does **not** force the removal of an open device; it
  only loads the `error` target. The device stays present and still open.
- `dmsetup remove --retry` / `--deferred` also cannot remove it while it is open.

With no visible holder and every `remove` variant failing, the device looks
permanently stuck, and the usual conclusion is "reboot the host". In reality the
open count is almost always **transient**: the moment the holder closes, the
device is removable (and an armed `--deferred` fires on last close). We verified a
field instance that cleared itself with **no reboot** and no command.

This repository does three things, per module:

1. a **minimal reproducer** anyone can run on a stock system,
2. it **reproduces** the opaque-busy behavior, and
3. it provides **evidence that a small upstream code change fixes it** (a built,
   patched binary with before/after output where feasible, plus the source patch).

## Modules

| dir | upstream project | the change argued for |
|---|---|---|
| [`device-mapper-dmsetup-open-count/`](device-mapper-dmsetup-open-count/) | lvm2 / device-mapper (`dmsetup`) | On a `remove` that fails because the device is open, report the open count and that `--force` cannot remove an open device. Turns a reboot-or-give-up dead end into an actionable one. **Built patched `dmsetup`, before/after included.** |
| [`multipath-tools-kpartx-udev-lock/`](multipath-tools-kpartx-udev-lock/) | multipath-tools (`kpartx`) | Take the systemd block-device lock (`udevadm lock` / `flock`) around partition add/delete so the teardown does not race `udev`, which is why downstreams wrap `kpartx` in `udevadm settle` retry loops. |

See [`docs/investigation.md`](docs/investigation.md) for the full method, the
device-mapper semantics involved (`dm_lock_for_deletion`), and the environments
tested.

## What this is NOT

A claimed **kernel open_count leak** -- open count stuck > 0 with genuinely no
holder, never self-clearing, truly reboot-only -- is **out of scope and excluded**:
we could not reproduce it (0 occurrences across 390 teardown attempts on current
kernels; the field instance self-cleared without a reboot). See
[`docs/excluded-kernel-open-count-leak.md`](docs/excluded-kernel-open-count-leak.md).
We do not file or imply a bug we cannot reproduce.

## Honesty

Every claim here is labelled tested or expected. The "before/after" transcripts
are captured from real runs of stock and patched binaries; the exact versions are
recorded alongside. The reproducers are self-contained and touch only a throwaway
loop device.

## Origin

Distilled from a Kicksecure / derivative-maker image-build teardown problem, where
the build carries workaround code (`udevadm settle` retry loops; a historical
`kpartx` double-remove) precisely because of the behaviors reproduced here. The
upstream changes argued for would let such downstreams drop those workarounds.
