#!/usr/bin/env bash
#
# mayhem/test.sh — RUN ProFTPD's own API test suite (tests/api, `check`-based; built by mayhem/build.sh).
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/mayhem/build-tests/api-tests"
[ -x "$RUNNER" ] || { echo "missing $RUNNER (mayhem/build.sh builds it)" >&2; exit 2; }

# Some suites stat "./api-tests", so run from its directory; the runner's api-tests.log lands there
# (gitignored). Keep the output capture outside the tree.
cd "$(dirname "$RUNNER")"
OUT="$(mktemp "${TMPDIR:-/tmp}/proftpd-tests.XXXXXX")"
trap 'rm -f "$OUT"' EXIT
./api-tests >"$OUT" 2>&1
cat "$OUT"

# check's summary: "100%: Checks: 1234, Failures: 0, Errors: 0". No summary => the suite never ran
# (a neutered runner prints nothing), which must count as a failure.
SUMMARY="$(grep -E '^[0-9]+%: Checks: [0-9]+, Failures: [0-9]+, Errors: [0-9]+' "$OUT" | tail -1 || true)"
if [ -z "$SUMMARY" ]; then
  echo "no check summary line in api-tests output" >&2
  emit_ctrf "check" 0 1 0
  exit 1
fi
TOTAL="$(sed -E 's/.*Checks: ([0-9]+),.*/\1/' <<<"$SUMMARY")"
FAILS="$(sed -E 's/.*Failures: ([0-9]+),.*/\1/' <<<"$SUMMARY")"
ERRS="$(sed -E 's/.*Errors: ([0-9]+).*/\1/' <<<"$SUMMARY")"
BAD=$(( FAILS + ERRS ))
[ "$TOTAL" -gt 0 ] || { echo "api-tests ran zero checks" >&2; emit_ctrf "check" 0 1 0; exit 1; }
emit_ctrf "check" $(( TOTAL - BAD )) "$BAD" 0
