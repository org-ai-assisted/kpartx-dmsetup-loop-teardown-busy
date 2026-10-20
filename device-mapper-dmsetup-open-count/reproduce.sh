#!/bin/bash
# Reproduce: `dmsetup remove` on a device-mapper device that is still open fails
# with a bare "Device or resource busy" that hides the open count and the holder,
# so a TRANSIENT opener looks like a device that needs a reboot. Also shows that
# `remove --force` only loads the error target -- it cannot remove an open device.
#
# Portable: needs only util-linux (losetup), multipath-tools (kpartx) and
# device-mapper (dmsetup). Run as root. Self-cleaning. Touches only a loop device
# backed by a throwaway image under a mktemp dir -- no existing device is affected.
#
# Exit 0 = the issue reproduced (remove failed busy while the device was open).
set -u

fail() { printf 'reproduce: %s\n' "$*" >&2; exit 2; }
for t in losetup kpartx dmsetup sgdisk; do
	command -v "$t" >/dev/null || fail "missing required tool: $t"
done
[ "$(id -u)" -eq 0 ] || fail "run as root (loop + device-mapper setup needs it)"

work="$(mktemp -d)"
img="$work/disk.img"
loop=""
holder=""

cleanup() {
	[ -n "$holder" ] && kill "$holder" 2>/dev/null
	if [ -n "$loop" ]; then
		kpartx -d -s -- "$loop" 2>/dev/null
		losetup --detach "$loop" 2>/dev/null
	fi
	rm -rf "$work"
}
trap cleanup EXIT

# Minimal GPT image with two partitions (two kpartx maps, like a real disk image).
truncate -s 128M "$img"
sgdisk --new=1:2048:+8M --typecode=1:8300 \
       --new=2:0:0      --typecode=2:8300 "$img" >/dev/null 2>&1

loop="$(losetup --find --show "$img")"
kpartx -a -s -- "$loop" >/dev/null 2>&1
udevadm settle --timeout 5 2>/dev/null || true

# Scope the match to OUR loop ("loopN" -> "loopNp1"); a bare ^loop[0-9]+p1$
# could pick a foreign build's map on a busy host and destroy it below.
part="$(basename "$loop")p1"
dmsetup info "$part" >/dev/null 2>&1 || fail "kpartx created no map $part (check loop/kpartx)"
node="/dev/mapper/$part"

# Hold the partition map open from a background process. This stands in for the
# REAL transient holder seen in the field (a udev/blkid worker, a systemd
# auto-activation, a probe in another mount namespace) -- the point is only that
# open count > 0 at teardown time.
# shellcheck disable=SC2217  # the redirect exists to HOLD $node open for sleep's
# lifetime (open count +1); sleep is only the timer, it is not meant to read it.
sleep 600 < "$node" &
holder=$!
sleep 0.3

echo "========================================================================"
echo "1) The open count IS available to the tool (one subcommand away):"
echo "   \$ dmsetup info -c -o name,open $part"
dmsetup info -c -o name,open "$part"
echo
echo "2) But \`dmsetup remove\` hides it -- a bare, non-actionable EBUSY:"
echo "   \$ dmsetup remove $part"
dmsetup remove "$part"; rc=$?
echo "   (exit $rc)"
echo
echo "3) \`dmsetup remove --force\` does NOT force-remove an open device --"
echo "   it only swaps in the error target, leaving it present AND still open:"
echo "   \$ dmsetup remove --force $part"
dmsetup remove --force "$part"; rcf=$?
echo "   (exit $rcf)"
echo "   table now:   $(dmsetup table "$part" 2>/dev/null)"
echo "   still here:  $(dmsetup info -c -o name,open,segments "$part" 2>/dev/null | tail -1)"
echo
echo "4) No reboot is needed: once the holder closes, remove succeeds."
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""
sleep 0.3
echo "   \$ dmsetup remove $part"
if dmsetup remove "$part"; then
	echo "   -> removed cleanly (open count reached 0, no reboot)"
else
	echo "   -> unexpected: still failed (investigate a genuine leak)"
fi
echo "========================================================================"
echo "REPRODUCED: the busy error gave no open count and no holder; --force could"
echo "not remove the open device; release came from the opener closing, not a reboot."
