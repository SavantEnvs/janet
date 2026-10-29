#!/usr/bin/env bash
#
# mayhem/build.sh — build janet's fuzz harnesses (sanitized) and its functional test runner (normal flags).
# Runs in the commit image as `mayhem` in /mayhem; re-runnable and needs no network.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

HARNESSES="fuzz_asm fuzz_compile fuzz_dobytes fuzz_dostring fuzz_fiber fuzz_peg fuzz_unmarshal"
FUZZ_DIR="$SRC/builddir/fuzz"       # `builddir/` is gitignored upstream, so `git clean -ffdX` removes it
TEST_DIR="$SRC/builddir/test"

rm -rf builddir
mkdir -p "$FUZZ_DIR" "$TEST_DIR"

# 1) Test runner: the project's NORMAL flags (no sanitizers, upstream defaults), stashed outside build/.
make clean
make -j"$MAYHEM_JOBS" build/janet CFLAGS="$COVERAGE_FLAGS -O2 -g"
cp build/janet "$TEST_DIR/janet"

# 2) The project itself, sanitized + DWARF<=3, with coverage hooks (fuzzer-no-link) so harnesses see its edges.
make clean
FUZZ_LINK_FLAGS=""
case "$LIB_FUZZING_ENGINE" in *fuzzer*) FUZZ_LINK_FLAGS="-fsanitize=fuzzer-no-link" ;; esac
make -j"$MAYHEM_JOBS" build/libjanet.a CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_LINK_FLAGS -O1"
cp build/libjanet.a "$FUZZ_DIR/libjanet.a"

# 3) Harnesses: libFuzzer binary + standalone reproducer, each linked with the sanitized lib.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o "$FUZZ_DIR/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_DIR/standalone_main.o"
LIBS="-lm -lpthread -lrt -ldl"
for h in $HARNESSES; do
  src="test/fuzzers/$h.c"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c99 -Isrc/include -Isrc/conf -fPIC -c "$src" -o "$FUZZ_DIR/$h.o"
  extra=""
  grep -q __lsan_is_turned_off "$src" || extra="$FUZZ_DIR/lsan_off.o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$FUZZ_DIR/$h.o" $extra "$FUZZ_DIR/libjanet.a" $LIBS -rdynamic -o "$FUZZ_DIR/$h"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "$FUZZ_DIR/standalone_main.o" "$FUZZ_DIR/$h.o" $extra "$FUZZ_DIR/libjanet.a" $LIBS -rdynamic -o "$FUZZ_DIR/$h-standalone"
done
make clean
