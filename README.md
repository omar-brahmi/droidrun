# DroidRun

DroidRun runs Android apps on an iPhone without JIT. It is a fork of [Husk](https://github.com/Leviidev/Husk) by Leviidev,
licensed under the GNU GPL v2 (see `LICENSE`), forked at commit `29abb51` (Husk 3.4, build 149).

Changes in this fork:

- Android native libraries are converted to iOS dylibs before install, so no JIT is needed (`packager/`).
- A garbage collector for the Dalvik VM (`src/translation-layer-next/husk-tl-gc.c`).
- Video from ExoPlayer, MediaPlayer and VideoView plays through iOS AVPlayer, including MPEG-TS, DASH and
  ClearKey-encrypted DASH (`husk-tl-dvm-avplayer.m`, `husk-tl-dvm-avstream.m`, `src/java-framework/src/husk/AvPlayer.java`).

Build the IPA: see [packager/README.md](packager/README.md). The upstream README follows.

---

<p align="center">
  <img src="src/app/Husk/Assets.xcassets/AppIcon.appiconset/Icon-Default.png" width="120" height="120" alt="Husk">
</p>

<h1 align="center">Husk</h1>

<p align="center">Android apps and games on your iPhone.</p>

<p align="center">
  <a href="https://itslevii.dev/docs/install">Install</a>
  ·
  <a href="https://itslevii.dev/husk">Compatibility</a>
  ·
  <a href="https://itslevii.dev">Website</a>
  ·
  <a href="https://github.com/Leviidev/Husk/releases">Releases</a>
</p>

<p align="center">
  <a href="https://github.com/Leviidev/Husk/releases"><img src="https://img.shields.io/github/downloads/Leviidev/Husk/total?style=flat-square&color=5B49EB&labelColor=111111" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Leviidev/Husk?style=flat-square&color=5B49EB&labelColor=111111" alt="GPL-2.0-or-later"></a>
</p>

Add an APK, tap it, and it opens full-screen.

- **Translation layer** — the game’s own 64-bit Android code runs on the iPhone. Husk stands in for Android around it (C library, Java, GL, Vulkan, audio, input). No Android boot; a game starts in seconds.
- **Emulation** — a full LineageOS guest under QEMU, for apps the translation layer cannot run yet.
- **PS4** — fake packages and game folders on iOS 17.4+.

## Install

Sideload with SideStore, AltStore, or TrollStore. iOS 15.5 or later.

**Guide:** [itslevii.dev/docs/install](https://itslevii.dev/docs/install)

Add this source in SideStore or AltStore (Sources › +). It also lists AetherPS4, Utsuro, Podium and Fathom:

```
https://itslevii.dev/repo.json
```

Or download `Husk.ipa` from [Releases](https://github.com/Leviidev/Husk/releases).

Games need [JIT](https://itslevii.dev/docs/jit), or they can run from [Play without JIT](https://itslevii.dev/docs/play-without-jit) after you import the certificate that installed Husk.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="Screenshots/gta-san-andreas.jpeg" alt="GTA: San Andreas"><br><sub>GTA: San Andreas</sub></td>
    <td align="center"><img src="Screenshots/minecraft-dungeons.jpeg" alt="Minecraft Dungeons"><br><sub>Minecraft Dungeons</sub></td>
  </tr>
  <tr>
    <td align="center" width="33%"><img src="Screenshots/library.png" alt="Library"><br><sub>Library</sub></td>
    <td align="center" width="33%"><img src="Screenshots/game-settings.png" alt="Game Settings"><br><sub>Game Settings</sub></td>
    <td align="center" width="33%"><img src="Screenshots/settings.png" alt="Settings"><br><sub>Settings</sub></td>
  </tr>
</table>

## Building

On a Mac with Xcode, plus `meson`, `ninja`, `pkg-config`, `python3`, `xcodegen`, `qemu-img`, and a Rust toolchain with `aarch64-apple-ios`:

```sh
./scripts/ci_build.sh
```

That produces `build/Husk.ipa`. Later app-only rebuilds: `./scripts/package_ipa.sh` → `~/Desktop/Husk.ipa`.

## Licence

GPL-2.0-or-later. Husk links QEMU (GPLv2), so the shipped binary is a combined GPLv2 work. It cannot go on the App Store. See [docs/01-licensing.md](docs/01-licensing.md).
