#!/usr/bin/env bash
#
# mayhem/build.sh — builds pspg (normal + sanitized), the table-parser harness and the test oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

OUT="$SRC/mayhem/build"
mkdir -p "$OUT"

# The project builds in tree (objects land in the repo root, all gitignored by upstream).
clean_tree() { make clean >/dev/null 2>&1 || true; rm -f config.make config.status config.log; }

# The pspg objects' preprocessor/feature flags (the PACKAGE_* strings are unused and don't survive word splitting).
project_flags() {
  printf 'include config.make\nshow:\n\t@echo $(CPPFLAGS) $(CFLAGS)\n' | make -s -f - show \
    | sed -E 's/ -DPACKAGE_[A-Z]+="[^"]*"//g; s/ -MD//; s/ -O[0-3s]//'
}

# 3) The project with its NORMAL flags: the oracle binary and a table-parser selftest for mayhem/test.sh.
clean_tree
env -u CFLAGS -u LDFLAGS -u CPPFLAGS ./configure CC="$CC" CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
make -j"$MAYHEM_JOBS" pspg
cp pspg "$OUT/pspg"
PFLAGS_TEST="$(project_flags)"
$CC $PFLAGS_TEST -O1 $COVERAGE_FLAGS mayhem/selftest_table.c \
    $(ls *.o | grep -v '^pspg\.o$') -lm -lreadline -lpanelw -lncursesw -ltinfo \
    -o "$OUT/selftest_table"

# 1) The project with sanitizers + SanCov (fuzzer-no-link) + DWARF 3: the real pspg binary is the
#    file-input fuzz target, and its objects are linked into the in-process table harness.
clean_tree
./configure CC="$CC" CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    LDFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
make -j"$MAYHEM_JOBS" pspg
PFLAGS_FUZZ="$(project_flags)"

# 2) Harness: engine build + standalone reproducer.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OUT/lsan_off.o"
LIBS="-lm -lreadline -lpanelw -lncursesw -ltinfo"
OBJS="$(ls *.o | grep -v '^pspg\.o$')"
$CC $PFLAGS_FUZZ -fsanitize=fuzzer-no-link $LIB_FUZZING_ENGINE mayhem/harness_table.c \
    $OBJS "$OUT/lsan_off.o" $LIBS -o /mayhem/pspg_table
$CC $PFLAGS_FUZZ -fsanitize=fuzzer-no-link "$STANDALONE_FUZZ_MAIN" mayhem/harness_table.c \
    $OBJS "$OUT/lsan_off.o" $LIBS -o /mayhem/pspg_table-standalone

# The real binary is the file-input target; relink it with the LSan hook (outside the tree path that `make clean` wipes).
$CC $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $(ls *.o) "$OUT/lsan_off.o" $LIBS -o /mayhem/pspg_asan

clean_tree
