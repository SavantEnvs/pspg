#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer checks of pspg's CSV/TSV and tabular-text parsers (binaries built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
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

# pspg output depends on locale and on ~/.pspgconf.
export LC_ALL=C
HOME="$(mktemp -d)"; export HOME

PSPG="$SRC/mayhem/build/pspg"
SELFTEST="$SRC/mayhem/build/selftest_table"
GOLDEN="$SRC/mayhem/golden"
TESTS="$SRC/tests"
CSVSEEDS="$SRC/mayhem/pspg_csv/testsuite"
TSVSEEDS="$SRC/mayhem/pspg_tsv/testsuite"

for b in "$PSPG" "$SELFTEST"; do
  [ -x "$b" ] || { echo "missing $b: mayhem/build.sh should have built it" >&2; emit_ctrf "pspg-golden" 0 1 0; exit 1; }
done

passed=0; failed=0
check() {  # check <name> <command...>: the command's stdout must equal golden/<name>.out
  local name="$1"; shift
  local got
  got="$("$@" 2>&1)"
  if [ -f "$GOLDEN/$name.out" ] && [ "$got" == "$(cat "$GOLDEN/$name.out")" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $name" >&2
    diff <(printf '%s\n' "$got") "$GOLDEN/$name.out" | head -10 >&2
  fi
}
# Plain-text rendering assertions on top of the goldens (the golden files could be regenerated blindly).
expect_line() {  # expect_line <name> <exact line> <command...>
  local name="$1" line="$2"; shift 2
  if "$@" 2>&1 | grep -qxF -- "$line"; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $name (missing line: $line)" >&2; fi
}

cases() {
  echo "csv_test2 $PSPG --csv --ni $TESTS/test2.csv"
  echo "csv_test3 $PSPG --csv --ni $TESTS/test3.csv"
  echo "csv_test11_multiline $PSPG --csv --ni $TESTS/test11.csv"
  echo "csv_test12_border1 $PSPG --csv --ni --border 1 $TESTS/test12.csv"
  echo "csv_test14_border0 $PSPG --csv --ni --border 0 $TESTS/test14.csv"
  echo "csv_quoted $PSPG --csv --ni $CSVSEEDS/quoted.csv"
  echo "csv_semicolon $PSPG --csv --ni --csv-separator ; $CSVSEEDS/semicolon.csv"
  echo "csv_noheader $PSPG --csv --ni --csv-header off $TESTS/test13.csv"
  echo "csv_trim_rows $PSPG --csv --ni --csv-trim-rows 2 $TESTS/test2.csv"
  echo "tsv_fruit $PSPG --tsv --ni $TSVSEEDS/fruit.tsv"
  for t in small multiline-u pg_class2 mysql double nu tables oracle monet-def; do
    echo "table_$t $SELFTEST $TESTS/$t.txt 1"
  done
  echo "table_small_ascii $SELFTEST $TESTS/small.txt 0"
  echo "table_mysql_ascii $SELFTEST $TESTS/mysql-ascii.txt 0"
}

while read -r name cmd; do
  # shellcheck disable=SC2086
  check "$name" $cmd
done < <(cases)

# Known answers that do not depend on a golden file.
expect_line csv_header_cell '|      s1       | s2  |  s3   |    s4     | s5 |    |' "$PSPG" --csv --ni "$TESTS/test2.csv"
expect_line csv_first_row   '| 1             |   2 | 3     | 4         |  5 |    |' "$PSPG" --csv --ni "$TESTS/test2.csv"
expect_line table_columns   'columns=3 border=2 linestyle=u expanded=0' "$SELFTEST" "$TESTS/small.txt" 1
expect_line table_headline  'headline_transl=LdddddddddddddIdddddddIdddddddR' "$SELFTEST" "$TESTS/small.txt" 1
expect_line table_multiline 'multilines=1' "$SELFTEST" "$TESTS/multiline-u.txt" 1

emit_ctrf "pspg-golden" "$passed" "$failed" 0
