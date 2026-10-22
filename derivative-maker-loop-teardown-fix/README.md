# derivative-maker loop teardown fix: four generations, proven

The build-side counterpart to this repo's upstream evidence. It shows, deterministically,
how derivative-maker's `loop_teardown_verify()` behaves across four generations during a
build's loop + kpartx-partition-map teardown, and that the final version tears the loop down
on every case -- normal, kpartx false-positive, AND a persistent open count -- without ever
orphaning a live map.

## The bug (old code)

`help-steps/misc-helpers.bsh`, `loop_teardown_verify()`, tore down a build's loop + kpartx
partition maps with `kpartx -d` then an UNCONDITIONAL `losetup --detach`. Both failures were
swallowed. When `kpartx -d` loses the udev/blkid race and leaves a `/dev/mapper/loopNpM` map,
`losetup --detach` detaches the backing loop out from under it -- orphaning it: `Open count: 1`,
no holder, unremovable even by `dmsetup remove --force/--retry/--deferred`.

## Generation 2 -- the maps-before-detach gate (commit 2c98f7dcb)

Detach the loop only once no `${base}pN` map remains. No more orphan -- but it has NO way to
clear a map `kpartx -d` refused to remove, so it loops all 5 attempts and FAILS the build.

## Generation 3 -- retry recovery (commit 0f459d4c)

Adds `dmsetup remove --retry`, which consults the TRUE open count and so clears a kpartx FALSE
positive (open count 0). This handles the common Qubes/docker false positive -- but NOT a map
with a PERSISTENT open count > 0 (`--retry` cannot remove an open map), so it still fails there.

## The persistent case (the real OVH build failure)

On the OVH build host the image's GPT "Linux root x86-64" auto-discovery partition (type
`4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709`) gets a PERSISTENT device-mapper open count of 1 with NO
removable userspace holder (verified: empty `fuser`/`lsof`/proc-fd scan; not mounted; not LVM/md/
bcache). It does not clear on `udevadm settle` or over minutes. `dmsetup remove --retry/--deferred`
cannot remove an open map, so generation 3 loops 5x and fails `help-steps/unmount-raw`.

## Generation 4 -- the robust fix (`new_loop_teardown_verify.bsh`)

Adds `dmsetup remove --force` as a fallback. `--force` cannot DELETE an open map, but it loads
the `error` target (`dmsetup table` becomes `0 <size> error`), which DROPS the map's reference
to the loop device. The loop then detaches cleanly (`losetup --associated` goes to empty); the
lingering error-target node holds no loop reference and clears on last close / reboot. Per loop:

```bash
kpartx -d -s -v -- "${loop_devices_item}"
# 1. clear a kpartx false positive (open count 0)
dmsetup remove --retry "${map}"     # for each leftover ${base}pN
# 2. a map that still survives has a persistent open count -> load the error target
dmsetup remove --force "${map}"      # cannot delete it, but drops its loop reference
# 3. detach only once every map is gone OR error-target'd (no live table on the loop)
losetup --detach "${loop_devices_item}"
```

A surviving map with a LIVE (non-error) table is never detached under (no orphan): the gate
re-checks `dmsetup table` and leaves the loop attached to retry, failing loudly after 5 attempts.

## The proof

`prove.sh` runs the REAL function bodies of all four generations (`old_*`, `gate_only_*`,
`retry_only_*`, `new_*` -- verbatim copies) against PATH stubs modelling each condition:
`kpartx -d` leaving a map, `dmsetup remove --retry` honouring the true open count, `dmsetup
remove --force` loading the error target, `dmsetup table` reporting error-vs-live, and
`losetup --detach`. No root, loops, or device-mapper required.

"Orphan" = a LIVE (non-error) map still present with its backing loop already detached. A
lingering ERROR-target map with the loop freed is NOT an orphan.

```
$ ./prove.sh
=== Scenario A: PERSISTENT open count (no holder releases; kpartx -d never clears it) ===
  OLD          rc=0  YES-ORPHAN       GATE-ONLY  rc=1  both kept
  RETRY-ONLY   rc=1  both kept        NEW        rc=0  error-target lingers, loop freed
=== Scenario B: kpartx false positive (open count 0) ===  RETRY-ONLY + NEW rc=0 clean; OLD orphans
=== Scenario C: NO-ORPHAN backstop (--force cannot neutralize) ===  NEW rc=1, both kept (no orphan)
=== Scenario D: transient (kpartx -d wins after 2) ===  OLD orphans; NEW rc=0, loop freed
RESULT: 10 passed, 0 failed
```

`prove.sh` exits non-zero if any case regresses: it is RED against OLD (orphan), and scenario A
is RED against GATE-ONLY and RETRY-ONLY (the build failure). If `new_*` ever regressed to the
retry-only body, scenario A's NEW assertion flips to FAIL.

`recover-real.sh` validates the generation-4 LEVER on REAL device-mapper (needs root; run in the
sandbox): it holds a kpartx partition map open, shows `dmsetup remove --force` loads the error
target, and that `losetup --detach` then frees the loop (association 1 -> 0) with no orphan.

## Files

- `old_loop_teardown_verify.bsh` -- before any fix (orphans).
- `gate_only_loop_teardown_verify.bsh` -- commit 2c98f7dcb (no orphan, fails the build).
- `retry_only_loop_teardown_verify.bsh` -- commit 0f459d4c (clears false positive, fails persistent).
- `new_loop_teardown_verify.bsh` -- robust: `--force` error-target fallback, no orphan.
- `prove.sh` -- the deterministic four-generation harness (shellcheck-clean; no root).
- `recover-real.sh` -- real device-mapper validation of the error-target recovery (root; sandbox).

The fix is landed in derivative-maker `help-steps/misc-helpers.bsh`. The `.bsh` files here are
verbatim copies for a self-contained proof; keep them in sync if the upstream function changes.
