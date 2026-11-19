"""Put JIT-less dylibs into a Husk IPA, on any PC (no Mac needed).

    python pack.py <Husk.ipa> <dylibs folder or .zip> <out.ipa> [--exe <Husk executable>] [--runtime <folder>] [--name <name>]

--runtime: husk-framework.dex and husk-framework-core.dex from that folder replace the IPA's (Payload/Husk.app/java-runtime).
--name: the name shown under the icon on the home screen (CFBundleDisplayName and CFBundleName). The bundle identifier
        stays com.husk.app, so the app replaces an installed Husk and keeps its data.

The dylibs come from the GitHub workflow (artifact "aot-dylibs"). They go into Payload/Husk.app/Frameworks, the first folder
Husk's "Play without JIT" mode searches (JITLess.bundledDirectory). They are unsigned: the sideloader (Sideloadly, SideStore,
AltStore) signs them together with the app, with the same certificate, so iOS runs them without JIT.
"""
import copy
import io
import os
import plistlib
import re
import sys
import zipfile

AOT_NAME = re.compile(r"^aot-v\d+-[0-9a-f]{16}-.+\.dylib$")
FRAMEWORKS = "Payload/Husk.app/Frameworks/"


def read_dylibs(src):
    found = {}
    if os.path.isdir(src):
        for root, _, files in os.walk(src):
            for f in files:
                if AOT_NAME.match(f):
                    with open(os.path.join(root, f), "rb") as fh:
                        found[f] = fh.read()
    else:
        with zipfile.ZipFile(src) as z:
            for e in z.namelist():
                f = os.path.basename(e)
                if AOT_NAME.match(f):
                    found[f] = z.read(e)
    return found


def main():
    args = sys.argv[1:]
    exe = None
    if "--exe" in args:  # a Husk executable from the "Build Husk executable" workflow replaces Payload/Husk.app/Husk
        i = args.index("--exe")
        with open(args[i + 1], "rb") as f:
            exe = f.read()
        if exe[:4] != b"\xcf\xfa\xed\xfe":
            sys.exit(f"{args[i + 1]} is not an arm64 Mach-O executable")
        del args[i:i + 2]
    runtime = {}
    if "--runtime" in args:
        i = args.index("--runtime")
        for n in ("husk-framework.dex", "husk-framework-core.dex"):
            f = os.path.join(args[i + 1], n)
            if os.path.exists(f):
                with open(f, "rb") as fh:
                    runtime["Payload/Husk.app/java-runtime/" + n] = fh.read()
        del args[i:i + 2]
    name = None
    if "--name" in args:
        i = args.index("--name")
        name = args[i + 1]
        del args[i:i + 2]
    if len(args) != 3:
        sys.exit(__doc__)
    ipa, src, out = args
    dylibs = read_dylibs(src)
    if not dylibs:
        sys.exit(f"no aot-v*-<hash>-<lib>.dylib files in {src}")
    if os.path.abspath(ipa) == os.path.abspath(out):
        sys.exit("output must be a new file")

    with zipfile.ZipFile(ipa) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        names = zin.namelist()
        if FRAMEWORKS not in names and not any(n.startswith(FRAMEWORKS) for n in names):
            sys.exit(f"{ipa} has no {FRAMEWORKS}: not a Husk IPA")
        replaced = 0
        for info in zin.infolist():
            if os.path.basename(info.filename) in dylibs and info.filename.startswith(FRAMEWORKS):
                replaced += 1
                continue  # an older copy: the new one is written below
            data = zin.read(info.filename)
            if exe is not None and info.filename == "Payload/Husk.app/Husk":
                data = exe
                print(f"  ~ Husk executable replaced ({len(exe)} bytes)")
            if info.filename in runtime:
                data = runtime[info.filename]
                print(f"  ~ {info.filename.rsplit('/', 1)[1]} replaced ({len(data)} bytes)")
            if name is not None and info.filename == "Payload/Husk.app/Info.plist":
                plist = plistlib.loads(data)
                plist["CFBundleDisplayName"] = plist["CFBundleName"] = name
                data = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)
                print(f"  ~ app name: {name}")
            zout.writestr(copy.copy(info), data)
        for name, data in sorted(dylibs.items()):
            info = zipfile.ZipInfo(FRAMEWORKS + name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 << 16)
            zout.writestr(info, data)
            print(f"  + Frameworks/{name} ({len(data)} bytes)")

    with zipfile.ZipFile(out) as z:
        bad = z.testzip()
        if bad:
            sys.exit(f"written IPA is damaged at {bad}")
    print(f"{len(dylibs)} dylibs added ({replaced} replaced) -> {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
