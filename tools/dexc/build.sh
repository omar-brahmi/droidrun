#!/bin/bash
# build.sh <dexc.py output dir> <dylib dir> [ios|macos] -- compile what tools/dexc/dexc.py generated into one dylib per DEX file:
# <dylib dir>/dexc-v<VERSION>-<signature>.dylib. ios (default): for the app, signed later with it by the sideloader. macos: for the
# Mac harnesses (TL_DEXC_DIR). Needs Xcode's clang.
set -e
R="$(cd "$(dirname "$0")/../.." && pwd)"
GEN=$1; OUT=$2; PLAT=${3:-ios}
case $PLAT in
    ios) SDK=iphoneos; TARGET=arm64-apple-ios15.5 ;;
    macos) SDK=macosx; TARGET=arm64-apple-macos12 ;;
    *) echo "platform: ios or macos" >&2; exit 1 ;;
esac
SYSROOT=$(xcrun --sdk $SDK --show-sdk-path)
CFLAGS="-target $TARGET -isysroot $SYSROOT -O2 -fPIC -fvisibility=hidden -fno-strict-aliasing -I$R/src/translation-layer-next"
mkdir -p "$OUT"
for d in "$GEN"/*/; do
    [ -f "$d/name" ] || continue
    name=$(cat "$d/name")
    ls "$d"/*.c | xargs -P "$(sysctl -n hw.ncpu)" -I{} sh -c "clang $CFLAGS -c '{}' -o '{}.o'"
    clang -target $TARGET -isysroot $SYSROOT -dynamiclib -install_name "@rpath/$name" -o "$OUT/$name" "$d"/*.o
    [ "$PLAT" = macos ] && codesign -s - --force "$OUT/$name" >/dev/null 2>&1
    echo "$OUT/$name: $(ls "$d"/*.c | wc -l | tr -d ' ') files, $(stat -f %z "$OUT/$name") bytes"
done
