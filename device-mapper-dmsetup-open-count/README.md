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
in the error, and with `--force` / `--retry` / `--deferred` all still failing, the
operator's natural conclusion is "this device is wedged, reboot the host" -- when
in reality the open count is almost always a **transient** holder (a `udev`/`blkid`
worker, a `systemd` auto-activation, a probe in another mount namespace) that will
drop on its own.

Two specific traps the current output does not dispel:

- `remove --force` does **not** force removal of an open device. It only loads the
  `error` target; the device stays present and open (see `evidence/before-stock.txt`:
  table becomes `0 ... error`, `Open 1`).
- `remove --deferred` cannot fire while the device is open.

## The reproducer

`reproduce.sh` (portable; needs only losetup, kpartx, dmsetup, sgdisk; run as
root; touches only a throwaway loop device). It sets up a loop + kpartx partition
map, holds the map open, and shows the opaque busy error, the `--force`
limitation, and that removal succeeds the moment the holder closes -- no reboot.

## The fix

`dmsetup-open-count.patch` (against lvm2 git). Only when the remove **fails**
(`!r`), and the device is still present and open, print the open count plus
guidance. Gating on the failure path means a successful `remove --deferred` (which
deliberately leaves the device present and open) is NOT mislabelled "blocked", and
the extra `DM_DEVICE_INFO` ioctl runs only on failure.

## Evidence (built patched binary)

Before (stock) -- `evidence/before-stock.txt`:

```
$ dmsetup remove loop0p1
device-mapper: remove ioctl on loop0p1  failed: Device or resource busy
Command failed.
```

After (patched) -- `evidence/after-patched.txt`:

```
$ dmsetup remove loop0p1
device-mapper: remove ioctl on loop0p1  failed: Device or resource busy
device-mapper: remove of loop0p1 is blocked: device is still open (open count 1).
Find and close the holder (lsof/fuser /dev/mapper/loop0p1; check mounts in every
mount namespace, a nested loop/dm device, and swap), then retry. 'remove --force'
only replaces the table with the error target and cannot remove an open device;
'remove --deferred' removes it automatically once the last opener closes.
Command failed.
```

The patched message fires on plain `remove` and on `remove --force`
(`evidence/after-patched.txt`), and `evidence/selfheal.txt` shows the device is
removable the instant the holder closes -- confirming the condition is transient,
not reboot-only. Exact versions are in `evidence/versions.txt`.

## Why upstream should take it

This single diagnostic converts the most common device-mapper support dead end
("busy, no holder, --force does nothing, reboot") into a self-service fix. It is
the reason downstream image-build tooling (e.g. Kicksecure / derivative-maker)
assumes a stuck map needs a reboot. The change is small, self-guarding, and adds
no output on the success path.
