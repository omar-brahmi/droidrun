"""Make DroidRun.ipa from the official Husk IPA, on any PC (no Mac needed).

    python pack.py <base.ipa> <dylibs folder or .zip> <out.ipa> [--app <folder>] [--exe <executable>] [--runtime <folder>]
                   [--name <name>]

--app: the app bundle built from this repository (the "app" artifact: DroidRun.app without the big resources). Its files
       (executable, Info.plist, Assets.car with the icons, translations) replace the base IPA's, and the bundle takes its
       name, executable and identifier: Payload/Husk.app becomes Payload/DroidRun.app, com.husk.app becomes
       com.droidrun.app (also inside embedded frameworks). The base's app extensions (the JIT helper and the downloads
       widget) are left out: their identifiers belong to Husk, and Play without JIT needs neither.
--exe: only replace the executable (without --app the bundle keeps the base's name and identifier).
--runtime: husk-framework.dex and husk-framework-core.dex from that folder replace the IPA's (java-runtime/).
--name: the name shown under the icon (CFBundleDisplayName and CFBundleName).

The dylibs come from the GitHub workflow. They go into <app>/Frameworks, the first folder "Play without JIT" searches
(JITLess.bundledDirectory). They are unsigned: the sideloader (Sideloadly, SideStore, AltStore) signs them together with
the app, with the same certificate, so iOS runs them without JIT.
"""
import copy
import os
import plistlib
import re
import sys
import zipfile

AOT_NAME = re.compile(r"^aot-v\d+-[0-9a-f]{16}-.+\.dylib$")
BASE_APP = "Payload/Husk.app/"
BASE_ID = "com.husk.app"
# never taken from the base when the bundle is rebuilt: signatures, provisioning and the extensions
DROP = re.compile(r"^(_CodeSignature/|embedded\.mobileprovision$|PlugIns/)")


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


def read_app(folder):
    """Files of a built .app, by path inside the bundle; signatures and extensions left out."""
    files = {}
    for root, _, names in os.walk(folder):
        for n in names:
            full = os.path.join(root, n)
            rel = os.path.relpath(full, folder).replace(os.sep, "/")
            if not DROP.match(rel):
                with open(full, "rb") as fh:
                    files[rel] = fh.read()
    return files


def take(args, flag):
    if flag not in args:
        return None
    i = args.index(flag)
    v = args[i + 1]
    del args[i:i + 2]
    return v


def rename_ids(obj, old, new):
    """Every string in a plist that is old or starts with old + '.' gets new instead."""
    if isinstance(obj, dict):
        return {k: rename_ids(v, old, new) for k, v in obj.items()}
    if isinstance(obj, list):
        return [rename_ids(v, old, new) for v in obj]
    if isinstance(obj, str) and (obj == old or obj.startswith(old + ".")):
        return new + obj[len(old):]
    return obj


def main():
    args = sys.argv[1:]
    app_dir, exe_path, runtime_dir, name = (take(args, f) for f in ("--app", "--exe", "--runtime", "--name"))
    if len(args) != 3:
        sys.exit(__doc__)
    ipa, src, out = args
    if os.path.abspath(ipa) == os.path.abspath(out):
        sys.exit("output must be a new file")
    dylibs = read_dylibs(src)
    if not dylibs:
        sys.exit(f"no aot-v*-<hash>-<lib>.dylib files in {src}")

    overlay, new_plist = {}, None
    if app_dir:
        overlay = read_app(app_dir)
        if "Info.plist" not in overlay:
            sys.exit(f"{app_dir} has no Info.plist: not an app bundle")
        new_plist = plistlib.loads(overlay.pop("Info.plist"))
    exe_name = new_plist["CFBundleExecutable"] if new_plist else "Husk"
    new_id = new_plist["CFBundleIdentifier"] if new_plist else BASE_ID
    app = f"Payload/{exe_name}.app/"
    if exe_path:
        with open(exe_path, "rb") as f:
            overlay[exe_name] = f.read()
    if exe_name in overlay and overlay[exe_name][:4] != b"\xcf\xfa\xed\xfe":
        sys.exit(f"the executable {exe_name} is not an arm64 Mach-O")
    if runtime_dir:
        for n in ("husk-framework.dex", "husk-framework-core.dex"):
            f = os.path.join(runtime_dir, n)
            if os.path.exists(f):
                with open(f, "rb") as fh:
                    overlay["java-runtime/" + n] = fh.read()
    for n, data in dylibs.items():
        overlay["Frameworks/" + n] = data

    with zipfile.ZipFile(ipa) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        if not any(n.startswith(BASE_APP + "Frameworks/") for n in zin.namelist()):
            sys.exit(f"{ipa} has no {BASE_APP}Frameworks: not a Husk IPA")
        dropped = 0
        for info in zin.infolist():
            if not info.filename.startswith(BASE_APP):
                zout.writestr(copy.copy(info), zin.read(info.filename))
                continue
            rel = info.filename[len(BASE_APP):]
            replaced_exe = rel == "Husk" and exe_name in overlay  # the base's executable, when one is supplied
            if rel in overlay or replaced_exe or (app_dir and DROP.match(rel)):
                dropped += rel.startswith("PlugIns/") and rel.endswith("/Info.plist")
                continue
            data = zin.read(info.filename)
            if rel == "Info.plist":
                plist = plistlib.loads(data)
                if new_plist:  # the build's plist wins; keys only the release has (its commit) stay
                    plist.update(new_plist)
                if name:
                    plist["CFBundleDisplayName"] = plist["CFBundleName"] = name
                data = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)
            elif rel.endswith("/Info.plist") and new_id != BASE_ID:  # embedded frameworks: StikJIT.framework
                plist = plistlib.loads(data)
                data = plistlib.dumps(rename_ids(plist, BASE_ID, new_id), fmt=plistlib.FMT_BINARY)
            out_info = copy.copy(info)
            out_info.filename = app + rel
            zout.writestr(out_info, data)
        for rel, data in sorted(overlay.items()):
            info = zipfile.ZipInfo(app + rel, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 if rel == exe_name or rel.endswith(".dylib") else 0o100644) << 16
            zout.writestr(info, data)

    with zipfile.ZipFile(out) as z:
        bad = z.testzip()
        if bad:
            sys.exit(f"written IPA is damaged at {bad}")
        plist = plistlib.loads(z.read(app + "Info.plist"))
        if exe_name not in [n[len(app):] for n in z.namelist() if n.startswith(app)]:
            sys.exit(f"the IPA has no executable {app}{exe_name}")
    print(f"{app[:-1]}: {plist['CFBundleDisplayName']} ({plist['CFBundleIdentifier']}), executable {exe_name}")
    print(f"{len(dylibs)} dylibs, {len(overlay) - len(dylibs)} files from the build, "
          f"{dropped} app extension(s) left out -> {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
