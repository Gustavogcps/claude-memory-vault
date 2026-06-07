#!/bin/bash
# Tiny assertion helpers for run-tests.sh. Each assert prints PASS/FAIL and tracks counts.
PASS=0
FAIL=0
FAILED_NAMES=""

_result() {  # $1 = 0/1 (ok?), $2 = name
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  ✓ $2"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
    ✗ $2"; echo "  ✗ FAIL: $2"
  fi
}

assert_eq()           { [ "$1" = "$2" ]; _result $? "$3 (got '$1', want '$2')"; }
assert_exit()         { [ "$1" -eq "$2" ]; _result $? "$3 (exit $1, want $2)"; }
assert_file_exists()  { [ -f "$1" ]; _result $? "$2"; }
assert_file_absent()  { [ ! -e "$1" ]; _result $? "$2"; }
assert_dir_exists()   { [ -d "$1" ]; _result $? "$2"; }
assert_contains()     { printf '%s' "$1" | /usr/bin/grep -q "$2"; _result $? "$3"; }
assert_not_contains() { ! printf '%s' "$1" | /usr/bin/grep -q "$2"; _result $? "$3"; }
assert_log_contains() { /usr/bin/grep -q "$2" "$1" 2>/dev/null; _result $? "$3"; }
assert_log_missing()  { ! /usr/bin/grep -q "$2" "$1" 2>/dev/null; _result $? "$3"; }

summary() {
  echo ""
  echo "════════════════════════════════════"
  echo "  $PASS passed, $FAIL failed"
  [ "$FAIL" -gt 0 ] && echo "$FAILED_NAMES"
  echo "════════════════════════════════════"
  [ "$FAIL" -eq 0 ]
}
