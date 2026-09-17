#!/usr/bin/env bash
#
# Build the MoonBit half of the native shell, and leave behind everything the host links against.
#
# The output is one static archive in `macos/vendor/`, so that the Swift side names a single
# library instead of reproducing the sequence below. That sequence is what `moon build` does for an
# executable, minus the executable: because this package is a `foreign_library`, the host program
# supplies `main`, so the platform's own link step is not run here — only made unnecessary.
#
#     moonc build-package   the package's own units            -> .core
#     moonc link-core       those plus the whole dependency tree -> .o
#     cc/libtool            that .o, the MoonBit runtime, the async stubs -> an executable
#
# Usage: macos/build-moonbit.sh [debug|release]     (default: release)

set -euo pipefail

PROFILE="${1:-release}"
case "$PROFILE" in
  debug | release) ;;
  *)
    echo "unknown profile '$PROFILE': expected debug or release" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# `moon build` finishes the job the host is supposed to finish: it links the package into an
# executable and fails with an undefined `main`. Everything before that step is exactly what is
# wanted, so the failure is expected and the archive below is the real check that it worked.
moon build macos/appffi --target native --"$PROFILE" >/dev/null 2>&1 || true

MOON="${MOON_HOME:-$HOME/.moon}"
BUILD="_build/native/$PROFILE/build"
PKG="$BUILD/macos/appffi"
# `link-core`'s output differs by profile, and both are wanted: a debug build gets an object file
# directly, while a release build is handed the whole program as C and compiled with everything
# else in one command. Here the C gets its own compilation instead.
LINKED="$PKG/__moonbit_link_core__/appffi.o"
if [ ! -f "$LINKED" ] && [ -f "$PKG/appffi.c" ]; then
  LINKED="$PKG/appffi.o"
  # The flags are the toolchain's own, from `moon build --dry-run`, minus the link.
  cc -c -o "$LINKED" "-I$MOON/include" -fwrapv -fno-strict-aliasing -Wno-unused-value -O2 \
    -DMOONBIT_ALLOCATOR=MOONBIT_ALLOCATOR_MIMALLOC "$PKG/appffi.c"
fi

if [ ! -f "$LINKED" ]; then
  echo "nothing to link in $PKG — run 'moon build macos/appffi --target native --$PROFILE' and read the error" >&2
  exit 1
fi

# Every package's native stubs, in one list: MoonBit's core, `moonbitlang/async`'s IO, and the one
# this package brings (the command inbox).
STUBS=()
while IFS= read -r archive; do
  STUBS+=("$archive")
done < <(find "$BUILD" -name 'lib*.a' | sort)

VENDOR="$ROOT/macos/vendor"
mkdir -p "$VENDOR"

# `libmoonbitrun.o` is the allocator the runtime was compiled against, and `libbacktrace.a` is the
# stack unwinder it reports panics with. Neither is a MoonBit package, which is why they come from
# the toolchain rather than from `_build`.
xcrun libtool -static -o "$VENDOR/libwei.a" \
  "$LINKED" \
  "${STUBS[@]}" \
  "$MOON/lib/libmoonbitrun.o" \
  "$MOON/lib/libbacktrace.a"

echo "$VENDOR/libwei.a"
