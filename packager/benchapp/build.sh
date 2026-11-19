#!/bin/bash
# build.sh -- packager/input/DroidRunBench.apk from this folder: javac, d8, aapt2, apksigner.
#   ANDROID_CP      jar with the android.* classes to compile against (an SDK's android.jar, or Husk's framework classes)
#   FRAMEWORK_RES   framework-res.apk (from the Husk IPA's java-runtime) for aapt2
#   BUILD_TOOLS     an Android SDK build-tools folder (aapt2, lib/d8.jar, apksigner)
#   KEYSTORE        a keystore to sign with (default: the SDK's debug keystore, password "android")
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../input/DroidRunBench.apk"
KEYSTORE="${KEYSTORE:-$HOME/.android/debug.keystore}"
T="$(mktemp -d)"
mkdir -p "$T/cls" "$T/dex"
win() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
ext() { if [ -f "$BUILD_TOOLS/$1.exe" ]; then echo "$BUILD_TOOLS/$1.exe"; elif [ -f "$BUILD_TOOLS/$1.bat" ]; then echo "$BUILD_TOOLS/$1.bat"; else echo "$BUILD_TOOLS/$1"; fi; }
"$(ext aapt2)" link -o "$T/base.apk" --manifest "$HERE/AndroidManifest.xml" -I "$FRAMEWORK_RES"
(cd "$HERE" && javac -nowarn --release 8 -cp "$ANDROID_CP" -d "$T/cls" $(find src -name '*.java'))
(cd "$T/cls" && jar cf ../bench.jar .)
java -cp "$(win "$BUILD_TOOLS/lib/d8.jar")" com.android.tools.r8.D8 --min-api 26 --output "$(win "$T/dex")" "$(win "$T/bench.jar")"
cp "$T/base.apk" "$T/unsigned.apk"
(cd "$T/dex" && python -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'a'); z.write('classes.dex','classes.dex'); z.close()" "$(win "$T/unsigned.apk")")
"$(ext zipalign)" -f 4 "$T/unsigned.apk" "$T/aligned.apk"
"$(ext apksigner)" sign --ks "$(win "$KEYSTORE")" --ks-pass pass:android --out "$(win "$OUT")" "$(win "$T/aligned.apk")"
rm -rf "$T"
echo "built $OUT"
