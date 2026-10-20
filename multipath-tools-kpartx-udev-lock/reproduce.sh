#!/bin/bash
# Reproduce the gap: kpartx takes NO lock on the whole-disk device while it
# creates or removes partition maps, so it races udev (which, per the systemd
# block-device locking protocol, takes a shared BSD lock before probing a
# device). We demonstrate it by holding a conflicting exclusive lock on the
# whole-disk device and showing stock kpartx proceeds anyway.
#
# Portable: needs losetup, kpartx, dmsetup, sgdisk, flock, util-linux timeout.
# Run as root. Self-cleaning. Touches only a throwaway loop device.
#
# Exit 0 = the gap reproduced (kpartx ignored a held whole-disk lock).
set -u

fail() { printf 'reproduce: %s\n' "$*" >&2; exit 2; }
for t in losetup kpartx dmsetup sgdisk flock timeout; do
	command -v "$t" >/dev/null || fail "missing required tool: $t"
done
[ "$(id -u)" -eq 0 ] || fail "run as root"

work="$(mktemp -d)"
img="$work/disk.img"
loop=""
obs=""

cleanup() {
	[ -n "$obs" ] && kill "$obs" 2>/dev/null
	if [ -n "$loop" ]; then
		for m in $(dmsetup ls --noheadings 2>/dev/null | awk '{print $1}' \
		           | grep -E "^$(basename "$loop")p[0-9]+$"); do
			dmsetup remove -f "$m" 2>/dev/null
		done
		kpartx -d -s -- "$loop" 2>/dev/null
		losetup --detach "$loop" 2>/dev/null
	fi
	rm -rf "$work"
}
trap cleanup EXIT

truncate -s 128M "$img"
sgdisk --new=1:2048:+8M --typecode=1:8300 \
       --new=2:0:0      --typecode=2:8300 "$img" >/dev/null 2>&1
loop="$(losetup --find --show "$img")"
maps() { dmsetup ls 2>/dev/null | awk '{print $1}' | grep -E "^$(basename "$loop")p[0-9]+$" | tr '\n' ' '; }

echo "whole-disk device under test: $loop"
echo "kpartx: $(kpartx 2>&1 | head -1)"
echo

# Hold an exclusive BSD lock on the whole-disk device (this is what udev's
# shared lock would conflict with).
flock -x "$loop" -c 'sleep 10' &
obs=$!
sleep 0.4
if flock -n -x "$loop" -c true 2>/dev/null; then
	fail "could not establish the observer lock; test invalid"
fi
echo "An exclusive whole-disk lock is held on $loop."
echo "A correct partition tool would wait for it (systemd block-device locking)."
echo
echo "\$ timeout 3 kpartx -a -s $loop"
timeout 3 kpartx -a -s -- "$loop" >/dev/null 2>&1
rc=$?
echo "  exit: $rc"
echo "  maps created while the whole-disk lock was held: [$(maps)]"
echo
if [ "$rc" = 0 ] && [ -n "$(maps)" ]; then
	echo "REPRODUCED: kpartx created partition maps despite the held whole-disk lock"
	echo "-- it takes no lock and races udev. (A tool honoring the protocol would have"
	echo "blocked until the lock was released.)"
else
	echo "NOTE: kpartx did not create maps under the lock on this system (exit $rc);"
	echo "if it blocked, this kpartx already takes the lock."
fi
