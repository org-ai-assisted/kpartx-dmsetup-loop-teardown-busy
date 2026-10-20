#!/bin/bash
# Deterministic proof that the OLD derivative-maker loop_teardown_verify() orphans
# a partition map while the NEW one does not.
#
# The field failure is a race (kpartx -d loses to a udev/blkid probe, so a map
# survives) that is hard to trigger on demand. We make it deterministic by
# running the REAL old and new function bodies against PATH stubs that model the
# exact failing condition the field hit:
#   - kpartx -d fails while a partition map is still present (optionally for a
#     bounded number of attempts, modelling the transient holder releasing);
#   - losetup --detach succeeds (the loop really goes away).
# No root, loops, or device-mapper needed -- pure logic proof.
#
# Orphan == a partition map still present with its backing loop already detached
# (the stuck "Open count:1" dm node). A clean teardown leaves neither; an honest
# failure leaves BOTH (loop kept, map kept) and returns non-zero.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
pass=0 fail=0

make_stubs() {  # $1 = bin dir
   local b="$1"
   cat > "$b/losetup" <<'EOF'
#!/bin/bash
case "$1" in
   --associated) [ -e "$ST/loop" ] && echo "/dev/loop9" ; exit 0 ;;
   --detach)     rm -f "$ST/loop" ; exit 0 ;;
esac
exit 0
EOF
   cat > "$b/kpartx" <<'EOF'
#!/bin/bash
# fail (leaving the map) while $ST/kfail > 0, decrementing each call; then succeed.
n="$(cat "$ST/kfail" 2>/dev/null || echo 0)"
if [ "$n" -gt 0 ]; then echo "$((n-1))" > "$ST/kfail"; exit 1; fi
rm -f "$ST/map"; exit 0
EOF
   cat > "$b/dmsetup" <<'EOF'
#!/bin/bash
# only `ls --noheadings` is used; list the partition map iff it still exists.
[ "$1" = "ls" ] && [ -e "$ST/map" ] && echo "loop9p1	(252:0)"
exit 0
EOF
   cat > "$b/udevadm" <<'EOF'
#!/bin/bash
exit 0
EOF
   cat > "$b/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
   chmod +x "$b"/*
}

run_case() {  # $1=label $2=function-file $3=kfail  -> prints result, sets pass/fail
   local label="$1" fn="$2" kfail="$3"
   local work rc orphan
   work="$(mktemp -d)"
   export ST="$work/state"
   mkdir -p "$ST" "$work/bin"
   : > "$ST/loop"            # a loop is attached
   : > "$ST/map"             # with one partition map present
   echo "$kfail" > "$ST/kfail"
   make_stubs "$work/bin"

   # run the function under test with ONLY the stubs on PATH for the mocked tools
   (
      export PATH="$work/bin:$PATH"
      export SUDO_TO_ROOT=""
      # shellcheck disable=SC1090
      source "$fn"
      loop_teardown_verify "/var/tmp/fake-image.raw"
   )
   rc=$?

   if [ -e "$ST/map" ] && [ ! -e "$ST/loop" ]; then
      orphan="YES-ORPHAN(map present, loop detached)"
   elif [ -e "$ST/map" ] && [ -e "$ST/loop" ]; then
      orphan="no (loop+map both kept -- honest, torn down by neither)"
   elif [ ! -e "$ST/map" ] && [ ! -e "$ST/loop" ]; then
      orphan="no (clean teardown -- map and loop both gone)"
   else
      orphan="no (map gone, loop kept)"
   fi
   printf '  %-26s rc=%s  %s\n' "$label" "$rc" "$orphan" >&2   # visible line
   rm -rf "$work"
   printf '%s|%s' "$rc" "$orphan"   # machine result on stdout (captured by caller)
}

assert() {  # $1=desc $2=actual $3=expected-substring
   if printf '%s' "$2" | grep -q -- "$3"; then
      echo "    PASS: $1"; pass=$((pass+1))
   else
      echo "    FAIL: $1 (got: $2)"; fail=$((fail+1))
   fi
}

echo "=== Scenario A: the opener never releases (kpartx -d keeps failing) ==="
o="$(run_case 'OLD loop_teardown_verify' "$here/old_loop_teardown_verify.bsh" 99 | tail -1)"
assert "OLD orphans the map and falsely returns 0" "$o" '^0|YES-ORPHAN'
n="$(run_case 'NEW loop_teardown_verify' "$here/new_loop_teardown_verify.bsh" 99 | tail -1)"
assert "NEW does not orphan and returns non-zero (loud)" "$n" '^1|no '

echo
echo "=== Scenario B: the opener releases after 2 failed attempts ==="
o2="$(run_case 'OLD loop_teardown_verify' "$here/old_loop_teardown_verify.bsh" 2 | tail -1)"
assert "OLD detaches too early -> orphans the map, returns 0" "$o2" '^0|YES-ORPHAN'
n2="$(run_case 'NEW loop_teardown_verify' "$here/new_loop_teardown_verify.bsh" 2 | tail -1)"
assert "NEW waits, then cleanly tears down and returns 0" "$n2" '^0|no (clean'

echo
echo "===================================================================="
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "PROVEN: OLD orphans the dm map; NEW never does." || echo "PROOF FAILED"
exit "$fail"
