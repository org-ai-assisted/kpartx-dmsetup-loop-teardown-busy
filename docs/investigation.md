# Investigation: stuck kpartx / device-mapper loop-partition teardown

## Symptom (as reported in the field)

A kpartx-created partition map (e.g. `dm-2` named `loop3p3`) wedged during an
image-build teardown:

- `dmsetup info` showed `Open count: 1`.
- No holder was found: `lsof` / `fuser` empty, `/proc/*/fd` empty,
  `/sys/block/dm-2/holders` empty; the backing loop was already detached.
- `dmsetup remove` and `--force` / `--retry` / `--deferred` all failed
  `Device or resource busy`.

The apparent conclusion -- an unremovable device with no holder -- reads as a
reboot-only kernel leak. The investigation shows it is not.

## The device-mapper semantics involved

`dmsetup remove` returning `EBUSY` is the kernel's intended
`dm_lock_for_deletion()` guard: a mapped device cannot be removed while its
`open_count > 0`. This is correct behavior, not a bug. The guard was added
deliberately (`dm: prevent removal if open`, Linux commit
`5c6bd75d06db512515a3781aa97e42df2faf0815`) precisely so a still-open device is
not yanked out from under its user.

Consequences that the tooling does not make visible:

- `remove --force` is documented to only replace the live table with the `error`
  target when the device is open; it does **not** drop the open reference, so the
  device remains present and open.
- `remove --deferred` arms removal for last-close; it cannot fire while
  `open_count > 0`.
- There is no ioctl to reset `open_count` from userspace. The only way the count
  drops is the opener closing the device.

So: if there is a genuine opener, the fix is to close it (no reboot). If there is
truly no opener and the count is stuck forever, only then is a reboot required --
and that would be a real kernel bug (see the exclusion doc; not observed here).

## Method and findings (tested)

Reproduced in a sandbox VM. Kernel 6.18.55 (also cross-checked against the field
host's 6.12.111); util-linux 2.41.5; multipath-tools 0.11.1; libdevmapper
1.02.205; loop `max_part = 0`.

1. **Holder detection is reliable.** A canary that holds a partition map open from
   a known process: `dmsetup remove` -> `EBUSY`, and an exhaustive hunt (lsof +
   fuser + every `/proc/[pid]/fd` and task fd matched by dm `major:minor` + mount
   scan across all namespaces + dm deps + nested loop) found the holder every
   time. So a real open reference is always findable with the right probe.

2. **The force matrix (core result).** With a genuine opener holding the map,
   every non-reboot method fails `EBUSY`: `remove`, `remove --retry` (same ioctl
   looped), `remove --force` (only reloads the `error` target; the device stays
   open), `remove --deferred` (armed, cannot fire), `wipe_table --force`,
   `suspend`+`resume`, `blockdev --flushbufs`. The instant the opener closed, the
   device was removable and a previously armed `--deferred` fired on last close.

3. **Not reproducible under normal teardown.** The build's exact
   `kpartx -d -s; losetup --detach` order over 40 iterations, and a single direct
   `dmsetup remove` immediately after `kpartx -a` over 200 (sync) + 150 (nosync)
   iterations, produced **0** stuck maps. `kpartx -s` sync mode waits for `udev` to
   settle before returning, closing the race window. The stuck state needs an
   aggravating factor (a loaded host stalling a `udev` worker; a host-specific
   auto-activation on the image's partition signatures) -- consistent with the
   stuck instance occurring on a busy multi-build host.

4. **Self-clears without reboot.** The field instance was gone on first inspection
   with the host uptime showing no reboot and no destructive command issued by
   anyone -- i.e. the transient holder had exited and the map was reaped.

## Conclusion

The `EBUSY` is correct; the defect is **diagnosability**: the tool hides the open
count and the `--force` limitation, so a transient hold is mistaken for a
reboot-only condition. Two upstream changes address the real gaps:

- `dmsetup`: report the open count (and the `--force` limitation) on a failed
  `remove`. (`device-mapper-dmsetup-open-count/`)
- `kpartx`: take the systemd block-device lock around partition add/delete to
  avoid racing `udev`, so downstreams can drop their `udevadm settle` retry
  wrappers. (`multipath-tools-kpartx-udev-lock/`)

## References

- Linux `dm: prevent removal if open` (open-count guard):
  commit `5c6bd75d06db512515a3781aa97e42df2faf0815`.
- Linux `loop: Fix a race between loop detach and loop open` (stale partitions
  after detach; merged 6.10): commit
  `18048c1af7836b8e31739d9eaefebc2bf76261f7`. Present on both kernels tested.
- multipath-tools `kpartx` udev retry (EBUSY on teardown):
  dm-devel, 2013, "multipath: Fix kpartx and udevd race".
- systemd block-device locking protocol (the `flock`/`udevadm lock` approach):
  used by Ubuntu `livecd-rootfs` to avoid the same udev race during image builds.
