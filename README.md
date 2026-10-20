# kpartx-dmsetup-loop-teardown-busy
Minimal reproducers + fix evidence: device-mapper/kpartx loop-partition teardown reports an opaque Device-or-resource-busy that hides the open-count, making a transient hold look reboot-only.
