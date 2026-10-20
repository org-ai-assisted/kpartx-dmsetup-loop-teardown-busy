# Excluded: a kernel open_count leak (reboot-only)

A tempting reading of the field symptom ("Open count: 1" with no findable holder,
every `remove` failing) is a genuine **kernel reference leak**: `open_count`
incremented and never decremented, no opener in existence, no userspace remedy,
reboot the only release. That would be a real kernel bug.

We **exclude** it, and do not file or imply it, because we could not reproduce it
and the direct evidence points the other way:

- **Not reproduced.** 0 stuck maps across 390 teardown attempts on current kernels
  (40 build-order `kpartx -d; losetup --detach`; 200 sync + 150 nosync direct
  `dmsetup remove` immediately after `kpartx -a`).
- **Holder detection is reliable.** When a map is open, the holder is always
  findable by probing `/proc/[pid]/fd` by dm `major:minor` (plus lsof/fuser, mount
  namespaces, dm deps, nested loop). A reported "no holder" is far more likely a
  holder that exited between the `EBUSY` and the `lsof`, or a holder class the
  check did not cover at that instant (swap, another mount namespace), than a
  nonexistent one.
- **The field instance self-cleared.** It was gone on first inspection with no
  reboot (host uptime continuous) and no destructive command issued. A genuine
  permanent leak would not self-clear.

What would change this verdict: a capture showing `open_count >= 1` **stable over
minutes**, with the exhaustive holder hunt (see `docs/investigation.md`) returning
nothing **at the same instant**, and the map never self-clearing. Instrument the
affected host to snapshot the full holder hunt at the `EBUSY` moment, not later. If
such a capture appears, it belongs in a separate kernel bug report with that
evidence -- not inferred from the diagnosability gap this repository documents.
