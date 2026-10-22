# derivative-maker loop teardown fix: three generations, proven

The build-side counterpart to this repo's upstream evidence. It shows,
deterministically, how derivative-maker's `loop_teardown_verify()` behaves across
three generations during a build's loop + kpartx-partition-map teardown, and that the
final version both fixes the field build failure and never orphans a device-mapper map.

## The bug (old code)

`help-steps/misc-helpers.bsh`, `loop_teardown_verify()`, tore down a build's loop +
kpartx partition maps:

```bash
${SUDO_TO_ROOT} kpartx -d -s -v -- "${loop_devices_item}" || true "INFO: kpartx non-zero exit code."
${SUDO_TO_ROOT} losetup --detach "${loop_devices_item}" || true "INFO: losetup non-zero exit code."
```

Both failures are swallowed. When `kpartx -d` loses the udev/blkid race (it fails to
remove a partition map), control falls straight through to `losetup --detach`, which
detaches the backing loop out from under the surviving `/dev/mapper/loopNpM` map --
leaving it orphaned: `Open count: 1`, no holder, and `dmsetup remove` (even
`--force`/`--retry`/`--deferred`) cannot remove it. That stuck dm node is what this
repository's upstream modules document.

## The gate-only step (commit 2c98f7dcb) and the build failure it caused

Settle udev before `kpartx -d`, and detach the loop only once **no** partition map for
it remains, so a `kpartx -d` that loses the race can no longer orphan a map:

```bash
${SUDO_TO_ROOT} udevadm settle --timeout 5 || true
...
base="${loop_devices_item##*/}"
${SUDO_TO_ROOT} kpartx -d -s -v -- "${loop_devices_item}" || true "INFO: kpartx non-zero exit code."
maps="$(${SUDO_TO_ROOT} dmsetup ls --noheadings 2>/dev/null | awk '{ print $1 }' | grep -E "^${base}p[0-9]+$" || true)"
if [ "${maps:-}" = "" ]; then
   ${SUDO_TO_ROOT} losetup --detach "${loop_devices_item}" || true "INFO: losetup non-zero exit code."
else
   true "INFO: ${base} partition maps still present; leaving loop attached, will retry."
fi
```

No more orphan -- but this version has **no way to clear a map `kpartx -d` refused to
remove**. In a Qubes/Xen build VM (and in docker) `kpartx -d` RACES a udev/systemd
probe of the image partition signatures and false-reports a map `in use. Not removing`
even though the map's TRUE device-mapper open count is 0 (verified live on the OVH
host). The gate saw the leftover map, never detached, looped all 5 attempts and FAILED
the build at `help-steps/unmount-raw`.

## The fix (new code, commit 0f459d4c)

Keep the gate, and after `kpartx -d` remove any leftover `${base}pN` map **directly**
with `dmsetup remove --retry`, which consults the TRUE open count:

```bash
maps="$(${SUDO_TO_ROOT} dmsetup ls --noheadings 2>/dev/null | awk '{ print $1 }' | grep -E "^${base}p[0-9]+$" || true)"
if [ -n "${maps:-}" ]; then
   while read -r map_item ; do
      [ -n "${map_item:-}" ] || continue
      ${SUDO_TO_ROOT} dmsetup remove --retry "${map_item}" || true "INFO: dmsetup remove non-zero exit code."
   done <<< "${maps}"
   maps="$(${SUDO_TO_ROOT} dmsetup ls --noheadings 2>/dev/null | awk '{ print $1 }' | grep -E "^${base}p[0-9]+$" || true)"
fi
if [ "${maps:-}" = "" ]; then
   ${SUDO_TO_ROOT} losetup --detach "${loop_devices_item}" || true "INFO: losetup non-zero exit code."
else
   true "INFO: ${base} partition maps still present; leaving loop attached, will retry."
fi
```

`dmsetup remove` clears a kpartx false positive (open count 0) yet a genuinely-held map
(open count > 0) survives for the next attempt. So the build failure is fixed WITHOUT
reintroducing the orphan: the loop is still detached only once no map remains, and if
the maps never clear across the 5 attempts the function returns non-zero and the build
fails **loudly** -- never "success" over a wedged map.

## The proof

The field failure is a race (`kpartx -d` losing to a transient udev/blkid open), which
is hard to trigger on demand. `prove.sh` makes it **deterministic** by running the REAL
function bodies of all three generations (`old_loop_teardown_verify.bsh`,
`gate_only_loop_teardown_verify.bsh`, `new_loop_teardown_verify.bsh` -- verbatim copies)
against PATH stubs that model the exact conditions: `kpartx -d` fails while a map is
present (optionally until its own retry wins), `dmsetup remove` honors the map's TRUE
open count, and `losetup --detach` succeeds. No root, loop devices, or device-mapper
required.

"Orphan" = a partition map still present with its backing loop already detached.

```
$ ./prove.sh
=== Scenario A: genuinely-held map (true open count > 0, never releases) ===
  OLD loop_teardown_verify     rc=0  YES-ORPHAN(map present, loop detached)
    PASS: OLD orphans the map and falsely returns 0
  GATE-ONLY (2c98f7dcb)        rc=1  no (loop+map both kept -- honest, torn down by neither)
    PASS: GATE-ONLY keeps both and returns non-zero (loud, no orphan)
  NEW (0f459d4c)               rc=1  no (loop+map both kept -- honest, torn down by neither)
    PASS: NEW keeps both and returns non-zero (no orphan reintroduced)

=== Scenario B: kpartx -d itself wins after 2 failed attempts (transient) ===
  OLD loop_teardown_verify     rc=0  YES-ORPHAN(map present, loop detached)
    PASS: OLD detaches too early -> orphans the map, returns 0
  NEW (0f459d4c)               rc=0  no (clean teardown -- map and loop both gone)
    PASS: NEW waits, then cleanly tears down and returns 0

=== Scenario C: kpartx false positive -- map left though TRUE open count is 0 ===
    (the actual build failure: gate-only loops 5x and fails; new recovers)
  GATE-ONLY (2c98f7dcb)        rc=1  no (loop+map both kept -- honest, torn down by neither)
    PASS: GATE-ONLY cannot clear it -> returns non-zero (reproduces build failure)
  NEW (0f459d4c)               rc=0  no (clean teardown -- map and loop both gone)
    PASS: NEW clears it via dmsetup remove -> clean teardown, returns 0 (recovery)

RESULT: 7 passed, 0 failed
PROVEN: OLD orphans the map; GATE-ONLY fails the build on a kpartx false
positive; NEW recovers the false positive yet never orphans a held map.
```

`prove.sh` exits non-zero if any case regresses, so it doubles as a regression test: it
is RED against the old code (orphan), and scenario C is RED against the gate-only code
(the build failure). If `new_loop_teardown_verify.bsh` ever regressed to the gate-only
body, scenario C's NEW assertion flips to FAIL.

## Files

- `old_loop_teardown_verify.bsh` -- the function before any fix (orphans).
- `gate_only_loop_teardown_verify.bsh` -- commit 2c98f7dcb (no orphan, but fails the
  build on a kpartx false positive).
- `new_loop_teardown_verify.bsh` -- commit 0f459d4c (recovers the false positive, no orphan).
- `prove.sh` -- the deterministic three-generation harness (shellcheck-clean; no root).

The fix is landed in derivative-maker: `help-steps/misc-helpers.bsh`, commit
`0f459d4c` (on top of `2c98f7dcb`). The `.bsh` files here are verbatim copies for a
self-contained proof; keep them in sync if the upstream function changes.
