#!/bin/bash
# Deterministic proof of derivative-maker's loop_teardown_verify() across four
# generations, run as the REAL function bodies against PATH stubs:
#   old_loop_teardown_verify.bsh        -- pre-gate: kpartx -d then UNCONDITIONAL
#                                          losetup --detach (orphans a surviving map).
#   gate_only_loop_teardown_verify.bsh  -- commit 2c98f7dcb: detach only once no ${base}pN
#                                          map remains (no orphan), but no way to clear a
#                                          map kpartx -d refused to remove -> fails the build.
#   retry_only_loop_teardown_verify.bsh -- commit 0f459d4c: adds 'dmsetup remove --retry',
#                                          clearing a kpartx FALSE positive (open count 0);
#                                          still FAILS a PERSISTENT open count (--retry cannot
#                                          remove an open map).
#   new_loop_teardown_verify.bsh        -- robust: adds 'dmsetup remove --force' as a fallback.
#                                          --force cannot delete an open map but loads the
#                                          'error' target, dropping the map's loop reference, so
#                                          the loop detaches without orphaning. Detach is gated
#                                          on every map being gone OR error-target'd.
#
# The field failures are hard to trigger on demand, so PATH stubs model the exact conditions:
#   - kpartx -d fails (leaving the map) while $ST/kfail > 0, decrementing each call, then
#     succeeds and removes it (kpartx's own retry eventually winning);
#   - dmsetup remove --retry removes the map iff its TRUE open count ($ST/mapcount) is 0;
#   - dmsetup remove --force removes a free map, else loads the 'error' target (sets
#     $ST/map_error) UNLESS $ST/forcefail is set (models force failing to neutralize);
#   - dmsetup table reports 'error' once the map is neutralized, else 'linear' (live);
#   - losetup --detach frees the loop.
# No root, loops, or device-mapper needed -- pure logic proof.
#
# Orphan == a LIVE (non-error) partition map still present with its backing loop already
# detached (the stuck "Open count:1" dm node). A lingering ERROR-target map with the loop
# freed is NOT an orphan (it holds no loop reference and clears on last close / reboot). A
# clean teardown leaves neither map nor loop; an honest failure keeps BOTH and returns non-zero.
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
# and remove the map (kpartx's own retry winning the udev race).
n="$(cat "$ST/kfail" 2>/dev/null || echo 0)"
if [ "$n" -gt 0 ]; then echo "$((n-1))" > "$ST/kfail"; exit 1; fi
rm -f "$ST/map" "$ST/map_error"; exit 0
EOF
   cat > "$b/dmsetup" <<'EOF'
#!/bin/bash
# ls      -> list the map iff its node exists (lingers after --force too); exit non-zero
#            if $ST/lsfail (models a failed/unreadable listing -> caller must fail closed).
# table   -> 'error' once neutralized, else 'linear ...' (a live table on the loop).
# remove --retry -> remove iff the TRUE open count is 0; else fail, leave it.
# remove --force -> remove a free map; for an open map load the error target (neutralize)
#                   unless $ST/forcefail, returning non-zero either way (busy).
c="$(cat "$ST/mapcount" 2>/dev/null || echo 0)"
case "$1" in
   ls)    [ -e "$ST/lsfail" ] && exit 1; [ -e "$ST/map" ] && echo "loop9p1	(252:0)" ; exit 0 ;;
   deps)
      # 'dmsetup deps --noheadings -o blkdevname <map>' -> the "N dependencies : (<dev>)" format
      # (the prefix is printed even with --noheadings). $ST/deps_mode selects the backing:
      #   owned (default) = (loop9) our loop; foreign = (sda1) a different named device;
      #   numeric = (7, 0) name unresolvable; empty = no output (deps unreadable).
      if [ -e "$ST/map" ]; then
         case "$(cat "$ST/deps_mode" 2>/dev/null || echo owned)" in
            foreign) echo "1 dependencies  : (sda1)" ;;
            numeric) echo "1 dependencies  : (7, 0)" ;;
            empty)   : ;;
            *)       echo "1 dependencies  : (loop9)" ;;
         esac
      fi
      exit 0 ;;
   table)
      if   [ -e "$ST/map_error" ]; then echo "0 16384 error"
      elif [ -e "$ST/map" ];       then echo "0 16384 linear 7:9 2048"
      fi
      exit 0 ;;
   remove)
      case "$2" in
         --retry)
            if [ "$c" -le 0 ]; then rm -f "$ST/map" "$ST/map_error"; exit 0; fi
            exit 1 ;;
         --force)
            if [ "$c" -le 0 ]; then rm -f "$ST/map" "$ST/map_error"; exit 0; fi
            [ -e "$ST/forcefail" ] && exit 1
            : > "$ST/map_error"; exit 1 ;;
      esac
      exit 0 ;;
esac
exit 0
EOF
   cat > "$b/findmnt" <<'EOF'
#!/bin/bash
# Two call shapes drive dm_map_mounted's FAIL-CLOSED probe:
#   BARE 'findmnt --noheadings' (no --source) = the whole-table READABILITY probe. The table is
#   readable here -> exit 0, UNLESS $ST/findmnt_unreadable models an unreadable/missing table
#   (binary gone, /proc unreadable) -> exit 1, which makes dm_map_mounted fail closed (treat the
#   map as mounted, refuse --force).
#   'findmnt --source <map>' = exit 0 iff $ST/mounted (map has a live fs), else exit 1 (a
#   readable no-match: the map is simply not mounted).
[ -e "$ST/findmnt_unreadable" ] && exit 1
for a in "$@"; do [ "$a" = "--source" ] && { [ -e "$ST/mounted" ] && exit 0; exit 1; }; done
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

run_case() {  # $1=label $2=fn $3=kfail $4=mapcount $5=forcefail $6=lsfail $7=mounted $8=deps_mode(owned|foreign|numeric|empty) $9=findmnt_unreadable(yes/no)
   local label="$1" fn="$2" kfail="$3" mapcount="$4" forcefail="$5" lsfail="${6:-no}" mounted="${7:-no}" deps_mode="${8:-owned}" findmnt_unreadable="${9:-no}"
   local work rc orphan map_live
   work="$(mktemp -d)"
   export ST="$work/state"
   mkdir -p "$ST" "$work/bin"
   : > "$ST/loop"            # a loop is attached
   : > "$ST/map"             # with one partition map present
   echo "$kfail" > "$ST/kfail"
   echo "$mapcount" > "$ST/mapcount"
   [ "$forcefail" = "yes" ] && : > "$ST/forcefail"
   [ "$lsfail" = "yes" ] && : > "$ST/lsfail"
   [ "$mounted" = "yes" ] && : > "$ST/mounted"
   printf '%s' "$deps_mode" > "$ST/deps_mode"
   [ "$deps_mode" = "foreign" ] && : > "$ST/foreign"   # a map backed by a DIFFERENT device, spared
   [ "$findmnt_unreadable" = "yes" ] && : > "$ST/findmnt_unreadable"
   make_stubs "$work/bin"

   (
      export PATH="$work/bin:$PATH"
      export SUDO_TO_ROOT=""
      # shellcheck disable=SC1090
      source "$fn"
      loop_teardown_verify "/var/tmp/fake-image.raw"
   )
   rc=$?

   map_live="no"
   if [ -e "$ST/map" ] && [ ! -e "$ST/map_error" ]; then map_live="yes"; fi
   if [ -e "$ST/loop" ]; then
      if [ -e "$ST/map" ]; then orphan="no (loop+map both kept -- honest, torn down by neither)"
      else orphan="no (map gone, loop kept)"; fi
   else
      if [ -e "$ST/foreign" ] && [ -e "$ST/map" ]; then orphan="no (foreign map spared, loop detached -- correct)"
      elif [ "$map_live" = "yes" ]; then orphan="YES-ORPHAN(live map present, loop detached)"
      elif [ -e "$ST/map" ]; then orphan="no (error-target map lingers, loop freed -- harmless)"
      else orphan="no (clean teardown -- map and loop both gone)"; fi
   fi
   printf '  %-30s rc=%s  %s\n' "$label" "$rc" "$orphan" >&2
   rm -rf "$work"
   printf '%s|%s' "$rc" "$orphan"
}

assert() {  # $1=desc $2=actual $3=expected-substring
   if printf '%s' "$2" | grep -q -- "$3"; then
      echo "    PASS: $1"; pass=$((pass+1))
   else
      echo "    FAIL: $1 (got: $2)"; fail=$((fail+1))
   fi
}

OLD="$here/old_loop_teardown_verify.bsh"
GATE="$here/gate_only_loop_teardown_verify.bsh"
RETRY="$here/retry_only_loop_teardown_verify.bsh"
NEW="$here/new_loop_teardown_verify.bsh"

echo "=== Scenario A: PERSISTENT open count (no holder releases; kpartx -d never clears it) ==="
echo "    the real OVH build failure -- GPT root-auto partition auto-opened, never freed"
assert "OLD orphans the map, falsely returns 0"               "$(run_case 'OLD'        "$OLD"   99 99 no | tail -1)" '^0|YES-ORPHAN'
assert "GATE-ONLY cannot clear it -> non-zero (build fails)"  "$(run_case 'GATE-ONLY'  "$GATE"  99 99 no | tail -1)" '^1|no (loop+map'
assert "RETRY-ONLY (0f459d4c) still fails -> non-zero"        "$(run_case 'RETRY-ONLY' "$RETRY" 99 99 no | tail -1)" '^1|no (loop+map'
assert "NEW forces the error target, detaches -> 0, no orphan" "$(run_case 'NEW'       "$NEW"   99 99 no | tail -1)" '^0|no (error-target'

echo
echo "=== Scenario B: kpartx false positive (map left behind though TRUE open count is 0) ==="
assert "OLD orphans the map, falsely returns 0"               "$(run_case 'OLD'        "$OLD"   99 0 no | tail -1)" '^0|YES-ORPHAN'
assert "RETRY-ONLY clears it via --retry -> 0, clean"         "$(run_case 'RETRY-ONLY' "$RETRY" 99 0 no | tail -1)" '^0|no (clean'
assert "NEW clears it via --retry (no force needed) -> 0, clean" "$(run_case 'NEW'     "$NEW"   99 0 no | tail -1)" '^0|no (clean'

echo
echo "=== Scenario C: NO-ORPHAN backstop -- persistent open AND --force cannot neutralize ==="
echo "    (defensive: if --force fails to load the error target, NEW must NOT orphan)"
assert "NEW refuses to detach a live map -> non-zero, both kept" "$(run_case 'NEW'     "$NEW"   99 99 yes | tail -1)" '^1|no (loop+map'

echo
echo "=== Scenario D: transient (kpartx -d itself wins after 2 attempts) ==="
assert "OLD detaches too early -> orphans the map, returns 0"  "$(run_case 'OLD'        "$OLD"   2 99 no | tail -1)" '^0|YES-ORPHAN'
assert "NEW tears down and returns 0 (loop freed, error node lingers, no orphan)" "$(run_case 'NEW' "$NEW" 2 99 no | tail -1)" '^0|no (error-target'

echo
echo "=== Scenario E: FAIL-CLOSED -- 'dmsetup ls' fails while a live map is present ==="
echo "    (a failed listing must NEVER be read as 'no maps' and trigger a detach)"
assert "RETRY-ONLY fails open: detaches on the empty listing -> orphan, returns 0" "$(run_case 'RETRY-ONLY' "$RETRY" 99 0 no yes no | tail -1)" '^0|YES-ORPHAN'
assert "NEW fails closed: never detaches on an unreadable listing -> non-zero" "$(run_case 'NEW' "$NEW" 99 0 no yes no | tail -1)" '^1|no (loop+map'

echo
echo "=== Scenario F: REFUSE --force on a MOUNTED map (error target would corrupt the fs) ==="
assert "NEW refuses to force a mounted map, never detaches -> non-zero, no orphan" "$(run_case 'NEW' "$NEW" 99 99 no no yes | tail -1)" '^1|no (loop+map'

echo
echo
echo "=== Scenario G: OWNERSHIP -- a coincidentally-named FOREIGN map is spared + excluded ==="
echo "    (a map named loop9p1 but backed by /dev/sda1: never removed, never gates our detach)"
assert "NEW spares the foreign map and still detaches the loop -> 0, no orphan" "$(run_case 'NEW' "$NEW" 99 0 no no no foreign | tail -1)" '^0|no (foreign map spared'

echo
echo "=== Scenario H: UNKNOWN deps (numeric, unresolvable) -- GATED, never dropped/forced ==="
echo "    numeric deps -> cannot confirm owner -> gate the detach (no orphan) but never --force it"
assert "NEW gates an unknown map: non-zero, loop+map kept (not dropped, not destroyed)" "$(run_case 'NEW' "$NEW" 99 99 no no no numeric | tail -1)" '^1|no (loop+map'

echo
echo "=== Scenario I: FAIL-CLOSED -- findmnt table unreadable -> dm_map_mounted refuses --force ==="
assert "NEW refuses --force on an unreadable mount table -> non-zero, no orphan" "$(run_case 'NEW' "$NEW" 99 99 no no no owned yes | tail -1)" '^1|no (loop+map'

echo
echo "===================================================================="
echo "RESULT: $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
   echo "PROVEN: OLD orphans; GATE-ONLY and RETRY-ONLY both fail the build on a PERSISTENT"
   echo "open count; NEW clears it with the error-target fallback and never orphans a live map."
else
   echo "PROOF FAILED"
fi
exit "$fail"
