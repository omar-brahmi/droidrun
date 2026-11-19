# DroidRun packager

Builds DroidRun.ipa, which runs Android apps on an iPhone **without JIT**: no StikDebug, no pairing file, no LocalDevVPN.

Android native libraries (`.so`) are converted to iOS dylibs on a GitHub macOS runner before install. The dylibs go into
`Husk.app/Frameworks`, so the sideloader signs them together with the app and iOS accepts them.

## Use

1. Put the APK into `packager/input/` and push.
2. On GitHub: **Actions > Build DroidRun IPA > Run workflow**. It takes about 25 minutes.
3. Download the `DroidRun-ipa` artifact from the run page, or on the PC:
   ```
   gh run download -n DroidRun-ipa
   ```
4. Install `DroidRun.ipa` with Sideloadly.
5. On the iPhone: Settings > JIT & Sideload > turn **Play without JIT** on. Import the APK and start it.

## Files

| Path | What |
|---|---|
| `input/` | APKs whose native libraries are converted. `AvTest.apk` is the video bench app (`testapp/`). |
| `runtime/` | The Java framework built from `src/java-framework` (`husk-framework.dex`, `husk-framework-core.dex`). |
| `collect.py` | Gathers the `.so` files from the base IPA and the APKs for the converter. |
| `pack.py` | Puts the executable, the dylibs, the framework and the app name into the IPA. Runs on any PC. |

Pack by hand on the PC, with artifacts from the workflow:

```
python pack.py Husk.ipa dylibs DroidRun.ipa --app DroidRun.app --runtime runtime
```

## Limits

- The base is the official Husk 3.4 IPA (commit `29abb51`). The dylib names carry the converter's version and each
  library's hash, so a mismatch is ignored, not loaded.
- Code generated while the app runs (LuaJIT, Mono JIT) still needs JIT.
- The app is `DroidRun.app` with the identifier `com.droidrun.app`, so it installs next to Husk, not over it. The
  base's app extensions (JIT helper, downloads widget) are left out.
- Free Apple ID: the app expires after 7 days. Re-sign with Sideloadly.
