# kpartx: take the whole-disk block-device lock around partition add/delete

**Project:** multipath-tools (`kpartx`, `kpartx/kpartx.c`)
**Change argued for:** hold `flock(fd, LOCK_EX)` on the whole-disk device while
adding/removing partition maps, per the systemd block-device locking protocol, so
`udev` defers its probe instead of racing kpartx.
**Status of evidence:** gap reproduced against stock kpartx; fix **verified with a
built, patched binary** via a lock-contention test (below). Tested on
multipath-tools git `0.15.1` (stock distro `0.11.1` behaves the same); Linux
`6.18.55`.

## The problem

kpartx creates/removes device-mapper partition maps over a block device but takes
**no lock** on that device (`grep -rn flock kpartx/` finds nothing). The systemd
block-device locking protocol says a tool modifying a block device should hold a
BSD `flock` on the whole-disk device; `udev` takes a *shared* lock before probing
and skips/defers while an exclusive lock is held. Because kpartx does not
participate, a `udev`/`blkid` worker can open a freshly created partition map while
kpartx is still working -- and during teardown that transient open is exactly what
makes `dmsetup remove` / `kpartx -d` fail `Device or resource busy` and can leave a
map orphaned (the symptom in this repo's root README and `docs/investigation.md`).

This is why downstreams wrap kpartx in `udevadm settle` + retry loops (e.g.
Kicksecure / derivative-maker `loop_teardown_verify`, and the Ubuntu
`livecd-rootfs` `flock` workaround). Taking the lock in kpartx lets them drop that.

## The reproducer

`reproduce.sh` (portable; run as root; touches only a throwaway loop device). It
holds an exclusive whole-disk lock and shows stock kpartx creates partition maps
anyway -- proving it does not honor the protocol.

## The fix

`kpartx-udev-lock.patch` (against multipath-tools git). After kpartx opens the
whole-disk device, take `flock(fd, LOCK_EX)` for `add`/`delete`/`update` (not for
read-only `list`). The lock releases when the fd closes at the end of the run.
Best-effort: a backend that cannot lock only warns, never fails.

## Evidence (built patched binary)

`evidence/lock-contention.txt` -- with a conflicting exclusive lock held on the
whole-disk device:

- **patched** kpartx `-a` **blocks** on the lock (`timeout 3` -> exit 124, creates
  no maps); once the lock is released it completes and creates the maps.
- **baseline** (unpatched, same version) kpartx `-a` **ignores** the lock -> exit 0,
  creates the maps while the disk is locked (the race).

So the patched kpartx waits for the whole-disk lock -- which is precisely how it
would defer to, and no longer race, a udev probe. Versions in `evidence/versions.txt`.

## Honesty / scope

- The lock-taking and lock-respecting behavior is **tested** (built binary,
  before/after). That `udev` then defers is the documented protocol consequence
  (udev honors the shared/exclusive BSD lock on the whole-disk device), labelled
  as **expected**, not separately reproduced here.
- This is a weaker-to-trigger race than module A's deterministic diagnostic gap;
  the value is eliminating the race class so downstreams can drop their
  `udevadm settle` retry workarounds.
