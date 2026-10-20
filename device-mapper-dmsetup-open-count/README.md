# dmsetup: report the open count when `remove` is blocked by an open device

**Project:** lvm2 / device-mapper (`dmsetup`, `libdm/dm-tools/dmsetup.c`)
**Change argued for:** when `dmsetup remove` fails because the device is still
open, print the open count and how to clear it, and state that `--force` cannot
remove an open device.
**Status of evidence:** reproduced and **verified with a built, patched binary**
(before/after below). Tested on lvm2 git `2.03.44(2)-git`, libdevmapper
`1.02.218-git`, Linux `6.18.55`.

## The problem

`dmsetup remove <dev>` on a device that is still open fails with only:

```
device-mapper: remove ioctl on <dev>  failed: Device or resource busy
Command failed.
```

That is the kernel's correct `dm_lock_for_deletion()` guard (open count > 0), but
the tool surfaces **none** of the actionable detail it already has one subcommand
away (`dmsetup info -c -o open` shows the count). With no open count and no holder
in the error, `--force` and `--retry` still failing, and `--deferred` only
deferring the removal (not completing it while the device is open), the
operator's natural conclusion is "this device is wedged, reboot the host" -- when
in reality the open count is almost always a **transient** holder (a `udev`/`blkid`
worker, a `systemd` auto-activation, a probe in another mount namespace) that will
drop on its own.

Two specific traps the current output does not dispel:

- `remove --force` does **not** force removal of an open device. It only loads the
  `error` target; the device stays present and open (see `evidence/before-stock.txt`:
  table becomes `0 ... error`, `Open 1`).
- `remove --deferred` is accepted (it does not fail), but the removal only
  completes once the last opener closes -- so on its own it does not make the
  device go away now, and the bare EBUSY from a plain remove never points the
  operator at it.

## The reproducer

`reproduce.sh` (portable; needs only losetup, kpartx, dmsetup, sgdisk; run as
root; touches only a throwaway loop device). It sets up a loop + kpartx partition
map, holds the map open, and shows the opaque busy error, the `--force`
limitation, and that removal succeeds the moment the holder closes -- no reboot.

## The fix

`dmsetup-open-count.patch` (against lvm2 git). Only when the remove **fails**
(`!r`) and the device is still present and open, print the open count and point at
the holder. It reuses lvm2's own in-tree conventions rather than reinventing:

- resolves the device via `_set_task_device` (so it covers removal by name,
  `--uuid`, or `--major`+`--minor`) and reads the name back with
  `dm_task_get_name()` (as `_status` does);
- reports `info.open_count`, and -- mirroring `lv_check_not_in_use()` -- uses
  `dm_device_has_holders()` to distinguish a **stacked block-device** holder
  (nameable via `/sys/dev/block/M:m/holders`) from an opener with **no** block
  holder (a process fd, a mount in any namespace, or swap -- the field case),
  tailoring the guidance accordingly;
- gating on `!r` means a successful `remove --deferred` (which deliberately leaves
  the device present and open) is NOT mislabelled "blocked", and the extra
  `DM_DEVICE_INFO` ioctl runs only on the failure path.

(The lsof/fuser hint is the secondary human tip for the no-block-holder case;
util-linux dropped its own lsof/fuser `umount` hint in 2.23, so the primary signal
here is the structured open-count + holders, matching the modern dm idiom.)

## Evidence (built patched binary)

Before (stock) -- `evidence/before-stock.txt`:

```
$ dmsetup remove loop0p1
device-mapper: remove ioctl on loop0p1  failed: Device or resource busy
Command failed.
```

After (patched) -- `evidence/after-patched.txt`. No block-device holder (a process
fd holds it -- the field case):

```
$ dmsetup remove loop0p1
device-mapper: remove ioctl on loop0p1  failed: Device or resource busy
device-mapper: remove of loop0p1 is blocked: still open (open count 1). No stacked
block-device holder was found in /sys/dev/block/252:0/holders, so the opener is most
likely a process fd, a mount in any namespace, or swap -- close it (fuser/lsof the
node; scan /proc/*/fd and /proc/*/mountinfo across namespaces), then retry; or use
'remove --deferred' to remove on last close. 'remove --force' only loads the error
target and cannot remove an open device.
```

Stacked block-device holder (the holders branch):

```
$ dmsetup remove loop0p1
device-mapper: remove of loop0p1 is blocked: still open (open count 1) by a stacked
block device -- see /sys/dev/block/252:0/holders; remove the holder first.
```

The message fires on plain `remove` and `remove --force`, stays silent on a
successful `remove --deferred`, and `evidence/selfheal.txt` shows the device is
removable the instant the holder closes -- confirming the condition is transient,
not reboot-only. Exact versions are in `evidence/versions.txt`.

## Why upstream should take it

This single diagnostic converts the most common device-mapper support dead end
("busy, no holder, --force does nothing, reboot") into a self-service fix. It is
the reason downstream image-build tooling (e.g. Kicksecure / derivative-maker)
assumes a stuck map needs a reboot. The change is small, self-guarding, and adds
no output on the success path.
