#!/bin/bash
# Deterministic proof of derivative-maker's loop_teardown_verify() across three
# generations, run as the REAL function bodies against PATH stubs:
#   old_loop_teardown_verify.bsh       -- pre-gate: kpartx -d then UNCONDITIONAL
#                                         losetup --detach (orphans a surviving map).
#   gate_only_loop_teardown_verify.bsh -- commit 2c98f7dcb: detach only once no
#                                         ${base}pN map remains (no orphan), but with
#                                         no way to clear a map kpartx -d refused to
#                                         remove -> loops and FAILS the build when
#                                         kpartx false-reports "in use" (open count 0).
#   new_loop_teardown_verify.bsh       -- commit 0f459d4c: same gate PLUS a direct
#                                         `dmsetup remove --retry`, which consults the
#                                         TRUE open count: it clears a kpartx false
#                                         positive (count 0) yet a genuinely-held map
#                                         (count > 0) survives -- fixing the build
#                                         failure WITHOUT reintroducing the orphan.
#
# The field failure is a race (kpartx -d loses to a udev/blkid probe, so a map
# survives) that is hard to trigger on demand. We make it deterministic with PATH
# stubs that model the exact conditions:
#   - kpartx -d fails (leaving the map) while $ST/kfail > 0, decrementing each call,
#     then succeeds and removes it (models kpartx's own retry eventually winning);
#   - dmsetup remove honors the map's TRUE open count in $ST/mapcount: count 0 ->
#     remove succeeds (the kpartx false positive); count > 0 -> remove fails, map
#     survives (a genuinely-held map), decrementing to model a later release;
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
# fail (leaving the map) while $ST/kfail > 0, decrementing each call; then succeed
# and remove the map (models kpartx's own retry winning the udev race).
n="$(cat "$ST/kfail" 2>/dev/null || echo 0)"
if [ "$n" -gt 0 ]; then echo "$((n-1))" > "$ST/kfail"; exit 1; fi
rm -f "$ST/map"; exit 0
EOF
   cat > "$b/dmsetup" <<'EOF'
#!/bin/bash
# `ls --noheadings`      -> list the partition map iff it still exists.
# `remove [--retry] MAP` -> honor the map's TRUE open count in $ST/mapcount:
#     count <= 0 : map genuinely free (kpartx false positive) -> remove it, succeed.
#     count >  0 : map really held -> refuse, leave it, decrement (later release).
case "$1" in
   ls)
      [ -e "$ST/map" ] && echo "loop9p1	(252:0)"
      exit 0
      ;;
   remove)
      c="$(cat "$ST/mapcount" 2>/dev/null || echo 0)"
      if [ "$c" -le 0 ]; then rm -f "$ST/map"; exit 0; fi
      echo "$((c-1))" > "$ST/mapcount"
      exit 1
      ;;
esac
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

run_case() {  # $1=label $2=function-file $3=kfail $4=mapcount -> prints result, sets pass/fail
   local label="$1" fn="$2" kfail="$3" mapcount="$4"
   local work rc orphan
   work="$(mktemp -d)"
   export ST="$work/state"
   mkdir -p "$ST" "$work/bin"
   : > "$ST/loop"            # a loop is attached
   : > "$ST/map"             # with one partition map present
   echo "$kfail" > "$ST/kfail"
   echo "$mapcount" > "$ST/mapcount"
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
   printf '  %-28s rc=%s  %s\n' "$label" "$rc" "$orphan" >&2   # visible line
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

echo "=== Scenario A: genuinely-held map (true open count > 0, never releases) ==="
a_old="$(run_case 'OLD loop_teardown_verify' "$here/old_loop_teardown_verify.bsh" 99 99 | tail -1)"
assert "OLD orphans the map and falsely returns 0" "$a_old" '^0|YES-ORPHAN'
a_gate="$(run_case 'GATE-ONLY (2c98f7dcb)' "$here/gate_only_loop_teardown_verify.bsh" 99 99 | tail -1)"
assert "GATE-ONLY keeps both and returns non-zero (loud, no orphan)" "$a_gate" '^1|no (loop+map'
a_new="$(run_case 'NEW (0f459d4c)' "$here/new_loop_teardown_verify.bsh" 99 99 | tail -1)"
assert "NEW keeps both and returns non-zero (no orphan reintroduced)" "$a_new" '^1|no (loop+map'

echo
echo "=== Scenario B: kpartx -d itself wins after 2 failed attempts (transient) ==="
b_old="$(run_case 'OLD loop_teardown_verify' "$here/old_loop_teardown_verify.bsh" 2 99 | tail -1)"
assert "OLD detaches too early -> orphans the map, returns 0" "$b_old" '^0|YES-ORPHAN'
b_new="$(run_case 'NEW (0f459d4c)' "$here/new_loop_teardown_verify.bsh" 2 99 | tail -1)"
assert "NEW waits, then cleanly tears down and returns 0" "$b_new" '^0|no (clean'

echo
echo "=== Scenario C: kpartx false positive -- map left though TRUE open count is 0 ==="
echo "    (the actual build failure: gate-only loops 5x and fails; new recovers)"
c_gate="$(run_case 'GATE-ONLY (2c98f7dcb)' "$here/gate_only_loop_teardown_verify.bsh" 99 0 | tail -1)"
assert "GATE-ONLY cannot clear it -> returns non-zero (reproduces build failure)" "$c_gate" '^1|no (loop+map'
c_new="$(run_case 'NEW (0f459d4c)' "$here/new_loop_teardown_verify.bsh" 99 0 | tail -1)"
assert "NEW clears it via dmsetup remove -> clean teardown, returns 0 (recovery)" "$c_new" '^0|no (clean'

echo
echo "===================================================================="
echo "RESULT: $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
   echo "PROVEN: OLD orphans the map; GATE-ONLY fails the build on a kpartx false"
   echo "positive; NEW recovers the false positive yet never orphans a held map."
else
   echo "PROOF FAILED"
fi
exit "$fail"
