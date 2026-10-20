# derivative-maker loop teardown fix: old vs new, proven

The build-side counterpart to this repo's upstream evidence. It shows, deterministically,
that derivative-maker's **old** `loop_teardown_verify()` orphans a device-mapper partition
map during teardown, and that the **new** version does not.

## The bug (old code)

`help-steps/misc-helpers.bsh`, `loop_teardown_verify()`, tears down a build's loop +
kpartx partition maps:

```bash
${SUDO_TO_ROOT} kpartx -d -s -v -- "${loop_devices_item}" || true "INFO: kpartx non-zero exit code."
${SUDO_TO_ROOT} losetup --detach "${loop_devices_item}" || true "INFO: losetup non-zero exit code."
```

Both failures are swallowed. When `kpartx -d` loses the udev/blkid race (it fails to remove
a partition map), control falls straight through to `losetup --detach`, which detaches the
backing loop out from under the surviving `/dev/mapper/loopNpM` map -- leaving it orphaned:
`Open count: 1`, no holder, and `dmsetup remove` (even `--force`/`--retry`/`--deferred`)
cannot remove it. That stuck dm node is what this repository's upstream modules document.

## The fix (new code)

Detach the loop only once **no** partition map for it remains, and settle udev before
`kpartx -d` so it is not racing a probe:

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

If the maps never clear across the 5 attempts, the loop is never detached, so the
function's final check returns non-zero and the build fails **loudly** -- instead of
returning "success" while leaving a wedged map.

## The proof

The field failure is a race (`kpartx -d` losing to a transient udev/blkid open), which is
hard to trigger on demand. `prove.sh` makes it **deterministic** by running the REAL old
and new function bodies (`old_loop_teardown_verify.bsh`, `new_loop_teardown_verify.bsh` --
verbatim copies) against PATH stubs that model the exact failing condition: `kpartx -d`
fails while a partition map is still present, and `losetup --detach` succeeds. No root,
loop devices, or device-mapper required.

"Orphan" = a partition map still present with its backing loop already detached.

```
$ ./prove.sh
=== Scenario A: the opener never releases (kpartx -d keeps failing) ===
  OLD loop_teardown_verify   rc=0  YES-ORPHAN(map present, loop detached)
    PASS: OLD orphans the map and falsely returns 0
  NEW loop_teardown_verify   rc=1  no (loop+map both kept -- honest, torn down by neither)
    PASS: NEW does not orphan and returns non-zero (loud)

=== Scenario B: the opener releases after 2 failed attempts ===
  OLD loop_teardown_verify   rc=0  YES-ORPHAN(map present, loop detached)
    PASS: OLD detaches too early -> orphans the map, returns 0
  NEW loop_teardown_verify   rc=0  no (clean teardown -- map and loop both gone)
    PASS: NEW waits, then cleanly tears down and returns 0

RESULT: 4 passed, 0 failed
PROVEN: OLD orphans the dm map; NEW never does.
```

`prove.sh` exits non-zero if any case regresses, so it doubles as a regression test and is
RED against the old code.

## Files

- `old_loop_teardown_verify.bsh` -- the function before the fix (orphans).
- `new_loop_teardown_verify.bsh` -- the function after the fix.
- `prove.sh` -- the deterministic old-vs-new harness (shellcheck-clean; no root).

The fix is landed in derivative-maker:
`help-steps/misc-helpers.bsh`, commit `2c98f7dcb`, PR
https://github.com/org-ai-assisted/derivative-maker/pull/87 . The two `.bsh` files here are
verbatim copies for a self-contained proof; keep them in sync if the upstream function changes.
