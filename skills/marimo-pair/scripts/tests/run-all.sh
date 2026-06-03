#!/usr/bin/env bash
# Run every smoke test in scripts/tests/ in dependency order.
#
# Tests are split into two classes:
#   - Pure (no live marimo required) — always run. Failures hard-fail the
#     suite. These cover argument parsing, build-index recipe extraction,
#     and shell-syntax checks.
#   - Kernel (live marimo required) — skipped (exit 77) when no marimo
#     server is discoverable. When marimo IS running, they hit a single
#     well-known scratchpad cell to verify the round-trip works.
#
# Exit codes:
#   0   all run tests passed (skips do not fail the suite)
#   1   at least one test failed
#   2   bad CLI
#
# Run manually after deploying a new marimo-pair revision to confirm the
# helpers still talk to the kernel the way they expect. CI runs the Pure
# class only.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

verbose="false"
require_kernel="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)         verbose="true"; shift ;;
    --require-kernel)     require_kernel="true"; shift ;;
    -h|--help)            sed -n '2,18p' "$0" >&2; exit 0 ;;
    -*)                   echo "Unknown option: $1" >&2; exit 2 ;;
    *)                    echo "Unexpected arg: $1" >&2; exit 2 ;;
  esac
done

# Pure tests first — they have no external dependencies. If any one fails,
# the kernel tests are still useful to surface (they may diagnose the same
# bug from a different angle), but we record overall failure.
tests=(
  test_client_syntax.sh
  test_edit_and_run_syntax.sh
  test_recipe_extraction.sh
  test_interrupt_syntax.sh
  test_sql_scratch_syntax.sh
  test_client_ping.sh
  test_run_cell.sh
  test_edit_and_run.sh
  test_interrupt.sh
  test_sql_scratch_ro.sh
)

passed=0
failed=0
skipped=0
failed_tests=()

for t in "${tests[@]}"; do
  path="$TEST_DIR/$t"
  if [[ ! -x "$path" ]]; then
    echo "MISSING $t" >&2
    failed=$((failed + 1))
    failed_tests+=("$t")
    continue
  fi
  if [[ "$verbose" == "true" ]]; then
    bash "$path"
  else
    bash "$path" >/dev/null 2>&1
  fi
  rc=$?
  case $rc in
    0)
      echo "PASS  $t"
      passed=$((passed + 1))
      ;;
    77)
      if [[ "$require_kernel" == "true" ]]; then
        echo "FAIL  $t (skipped under --require-kernel)"
        failed=$((failed + 1))
        failed_tests+=("$t")
      else
        echo "SKIP  $t (no live marimo)"
        skipped=$((skipped + 1))
      fi
      ;;
    *)
      echo "FAIL  $t (exit $rc)"
      failed=$((failed + 1))
      failed_tests+=("$t")
      ;;
  esac
done

echo
echo "summary: ${passed} passed, ${failed} failed, ${skipped} skipped"
if (( failed > 0 )); then
  printf 'failures:\n'
  printf '  - %s\n' "${failed_tests[@]}"
  exit 1
fi
exit 0
