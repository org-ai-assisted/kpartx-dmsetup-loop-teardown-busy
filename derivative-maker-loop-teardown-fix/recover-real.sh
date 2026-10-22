#!/bin/bash
# Validate the ROBUST loop_teardown_verify() on REAL device-mapper by DRIVING the real
# function body (new_loop_teardown_verify.bsh, a verbatim copy of the derivative-maker
# function) against an image whose partition map is held open.
#
# A partition map with an open count > 0 that `dmsetup remove --retry` cannot clear is the
# field condition (the GPT root-auto partition auto-opened with no removable holder). The
# holder-less persistent open is not reproducible in isolation, so a process holding the
# partition node open stands in for it -- the teardown LEVER (`--force` loads the error
# target, dropping the loop reference, so the loop detaches) is what we validate on real dm.
#
# Needs losetup, kpartx, dmsetup, sgdisk. Run as root. Self-cleaning; throwaway loop only.
# Exit 0 = the real function tore the loop down (returned 0, loop freed) with no live-map orphan.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
fail() { printf 'recover-real: %s\n' "$*" >&2; exit 2; }
for t in losetup kpartx dmsetup sgdisk; do
	command -v "$t" >/dev/null || fail "missing required tool: $t"
done
[ "$(id -u)" -eq 0 ] || fail "run as root (loop + device-mapper setup needs it)"

work="$(mktemp -d)" || fail "mktemp -d failed"
img="$work/disk.img"
loop=""
holder=""

cleanup() {
	[ -n "$holder" ] && kill "$holder" 2>/dev/null
	if [ -n "$loop" ]; then
		for m in $(dmsetup ls --noheadings 2>/dev/null | awk '{print $1}' \
		           | grep -E "^$(basename "$loop")p[0-9]+$"); do
			dmsetup remove --force "$m" 2>/dev/null
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
base="$(basename "$loop")"
kpartx -a -s -- "$loop" >/dev/null 2>&1
udevadm settle --timeout 5 2>/dev/null || true

part="${base}p1"
node="/dev/mapper/${part}"
dmsetup info "$part" >/dev/null 2>&1 || fail "kpartx created no map $part"
dmsetup deps -o devname "$part" 2>/dev/null | grep -qw "(${base})" \
	|| fail "map $part is not backed by $loop -- refusing to touch it"

# Hold the partition map open (open count > 0), standing in for the field's holder-less hold.
# shellcheck disable=SC2217  # the redirect HOLDS $node open for sleep's lifetime (open count
# +1); sleep is only the timer, it is not meant to read the node.
sleep 600 < "$node" &
holder=$!
sleep 0.3
echo "setup: ${part} open count before teardown: $(dmsetup info -c --noheadings -o open "$part" 2>/dev/null)"

# Drive the REAL function. We are root, so SUDO_TO_ROOT is empty.
# shellcheck source=new_loop_teardown_verify.bsh disable=SC1091
source "${here}/new_loop_teardown_verify.bsh"
# shellcheck disable=SC2034  # read by the sourced loop_teardown_verify, not directly here
SUDO_TO_ROOT=""
echo "========================================================================"
rc=0
loop_teardown_verify "$img" || rc=$?
echo "========================================================================"
echo "loop_teardown_verify returned: $rc"

assoc_after="$(losetup --associated "$img" --noheadings --output NAME 2>/dev/null || true)"
echo "loop still associated with image: [${assoc_after:-<none>}]"

# Any ${base}pN map still carrying a LIVE (non-error) table would be an orphan if the loop
# were detached. Confirm none remain.
live_orphan="no"
for m in $(dmsetup ls --noheadings 2>/dev/null | awk '{print $1}' | grep -E "^${base}p[0-9]+$"); do
	t="$(dmsetup table "$m" 2>/dev/null | awk '{print $3; exit}')"
	if [ -n "$t" ] && [ "$t" != "error" ]; then live_orphan="yes ($m -> $t)"; fi
done
echo "live (non-error) map still present: ${live_orphan}"

if [ "$rc" -eq 0 ] && [ -z "${assoc_after:-}" ] && [ "$live_orphan" = "no" ]; then
	echo "RECOVERED: the real loop_teardown_verify freed the loop (open map neutralized via the"
	echo "error target, no live-map orphan) and returned 0."
else
	echo "NOT RECOVERED (rc=$rc, assoc_after=[${assoc_after:-none}], live_orphan=${live_orphan})."
	exit 1
fi
