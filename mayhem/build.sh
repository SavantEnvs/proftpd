#!/usr/bin/env bash
#
# mayhem/build.sh — build ProFTPD's libFuzzer JSON harness (+ standalone reproducer) and the upstream
# API test runner. Runs in the commit image as `mayhem` in /mayhem; re-runnable and offline.
#
# ProFTPD builds in-tree (./configure && make), so the two builds run one after the other in the same
# tree, each from a `make distclean`: first the upstream API tests (tests/api, check-based) with the
# project's NORMAL flags -> mayhem/build-tests/api-tests, then the sanitized fuzz build -> /mayhem/json_fuzzer.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
TESTS_OUT="$SRC/mayhem/build-tests"
FUZZ_OUT="$SRC/mayhem/build-fuzz"

reset_tree() { make distclean >/dev/null 2>&1 || true; }

# 1) Upstream API tests, NORMAL flags (independent of the sanitized build below).
reset_tree
# (Debian's static libcheck needs -lm -lsubunit -lrt -pthread at configure time.)
env -u CFLAGS -u LDFLAGS ./configure CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" LIBS="-lsubunit -lrt -lm -pthread" --enable-ctrls --enable-tests=nonetwork
make -j"$MAYHEM_JOBS"
# `make api-tests` links the runner and then runs it once; tests/ is a scratch cwd for its log file.
# test.sh runs the suite for real, so a failure here is not the build's to report.
make -C tests api-tests || true
[ -x tests/api-tests ] || { echo "tests/api-tests was not built" >&2; exit 1; }
rm -rf "$TESTS_OUT"; mkdir -p "$TESTS_OUT"
cp tests/api-tests "$TESTS_OUT/api-tests"

# 2) Sanitized + coverage-instrumented project for the fuzz harness.
reset_tree
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
./configure CC="$CC" CFLAGS="$FUZZ_CFLAGS" LDFLAGS="$SANITIZER_FLAGS" --enable-ctrls
make -j"$MAYHEM_JOBS"

rm -rf "$FUZZ_OUT"; mkdir -p "$FUZZ_OUT"
# The harness only needs the library objects: rebuild main.c with main() renamed (what OSS-Fuzz does with
# sed, here without touching the tracked file), and drop ftpdctl.o which has its own main().
$CC $FUZZ_CFLAGS -DHAVE_CONFIG_H -DLINUX -Dmain=main2 -I. -I./include -c src/main.c -o "$FUZZ_OUT/main.o"
find . -name '*.o' -not -path "./mayhem/*" -not -name main.o -not -name ftpdctl.o -print0 \
  | xargs -0 -n 200 ar rcs "$FUZZ_OUT/libproftpd_fuzz.a"
ar rcs "$FUZZ_OUT/libproftpd_fuzz.a" "$FUZZ_OUT/main.o"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_OUT/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_OUT/standalone_main.o"
$CC $FUZZ_CFLAGS -DHAVE_CONFIG_H -DLINUX -I. -I./include -c tests/fuzzing/json_fuzzer.c -o "$FUZZ_OUT/json_fuzzer.o"

LIBS="src/scoreboard.o lib/prbase.a $FUZZ_OUT/libproftpd_fuzz.a -lcrypt -pthread"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$FUZZ_OUT/json_fuzzer.o" "$FUZZ_OUT/lsan_off.o" $LIBS \
    -o "$SRC/json_fuzzer"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$FUZZ_OUT/json_fuzzer.o" "$FUZZ_OUT/lsan_off.o" "$FUZZ_OUT/standalone_main.o" $LIBS \
    -o "$SRC/json_fuzzer-standalone"
