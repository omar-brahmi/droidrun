"""Collect the arm64 Android libraries Husk loads, so the workflow can convert them.

    python3 collect.py <Husk.ipa> <input dir> <out dir>

From the IPA: every .so under Payload/Husk.app/java-runtime (libjavacore, libopenjdk, ICU, conscrypt...).
From each APK in <input dir>: lib/arm64-v8a/*.so.
Each library goes in its own folder, keeping its file name: the dylib's name is built from the library's name and bytes,
and two sources may both carry a library with the same name (libc++.so).
"""
import os
import sys
import zipfile


def save(out_dir, group, name, data):
    d = os.path.join(out_dir, group)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)
    print(f"  {group}/{name} ({len(data)} bytes)")


def main():
    ipa, input_dir, out_dir = sys.argv[1:4]
    n = 0
    with zipfile.ZipFile(ipa) as z:
        for e in z.namelist():
            if "/java-runtime/" in e and e.endswith(".so"):
                save(out_dir, f"runtime{n}", os.path.basename(e), z.read(e))
                n += 1
    if os.path.isdir(input_dir):
        for apk in sorted(os.listdir(input_dir)):
            if not apk.lower().endswith(".apk"):
                continue
            with zipfile.ZipFile(os.path.join(input_dir, apk)) as z:
                for e in z.namelist():
                    if e.startswith("lib/arm64-v8a/") and e.endswith(".so"):
                        save(out_dir, f"app{n}", os.path.basename(e), z.read(e))
                        n += 1
    print(f"{n} libraries")
    if n == 0:
        sys.exit("no libraries found")


if __name__ == "__main__":
    main()
