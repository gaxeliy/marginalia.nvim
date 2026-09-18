#!/usr/bin/env bash
# Run all marginalia.nvim test suites headlessly.
#
#   core       — always runs (plugin only)
#   telescope  — runs when telescope.nvim+plenary are installed, else WARNING + skip
#   diffview   — runs when diffview.nvim is installed, else WARNING + skip
#
# A suite FAILS if its output lacks "PASSED" (assert errors surface in stderr).
set -u
cd "$(dirname "$0")/.."

fail=0
for suite in core fuzz telescope diffview; do
  out="$(timeout 120 nvim --headless -u NONE -n -c "luafile tests/test_${suite}.lua" 2>&1 || true)"
  clean="$(printf '%s' "$out" | sed 's/-- ВСТАВКА --//g')"
  suite_up="$(printf '%s' "$suite" | tr '[:lower:]' '[:upper:]')"
  if printf '%s' "$clean" | grep -q "${suite_up} TESTS PASSED"; then
    echo "PASS  $suite"
  elif printf '%s' "$clean" | grep -q "WARNING.*skipping"; then
    echo "SKIP  $suite  ($(printf '%s' "$clean" | grep WARNING | head -1))"
  else
    echo "FAIL  $suite"
    printf '%s\n' "$clean" | grep -E "FAILED|E5113|E475|error" | head -5
    fail=1
  fi
done
exit "$fail"
