# Tizen TV emulator for Apple Silicon (unofficial)

Runs the Samsung Tizen TV emulator image from Tizen Studio on Apple Silicon Macs, with the TV screen and a Samsung Smart Remote side by side in your browser. You can install, run and debug TV web apps with Tizen Studio's usual `sdb` and `tizen` commands.

Not affiliated with or supported by Samsung. Tested with Tizen Studio 6.5's **TV 10.0** image on macOS (arm64).

## Why this exists

Samsung's TV emulator is x86-only and needs Intel hardware virtualization, so on Apple Silicon it refuses to start. Under Rosetta its old QEMU boots the kernel, but then many guest processes crash.

This project builds a current QEMU natively for arm64, emulates the x86 TV in software (TCG), and adds Samsung's two emulator-only devices that the TV image needs. They are ported from Samsung's GPL QEMU fork:

- **VIGS**, the virtual GPU. The TV image has no other display driver.
- **YaGL**, which forwards the TV's OpenGL ES calls to macOS OpenGL. The home screen and the web runtime need it.

## Requirements

- An Apple Silicon Mac with Xcode command line tools (`xcode-select --install`) and Homebrew.
- `brew install ninja pkg-config glib pixman libslirp`
- [Tizen Studio](https://developer.tizen.org/development/tizen-studio/download) with the TV extensions, plus these packages from its Package Manager:

  ```sh
  ~/tizen-studio/package-manager/package-manager-cli.bin install Emulator TV-SAMSUNG-Public-Emulator
  ```

  `TV-SAMSUNG-Public-Emulator` provides the TV image, kernel and remote skin; `Emulator` provides the swap disk template. Read Samsung's license when the Package Manager shows it. Nothing from Samsung is included in this repository.

## Install and run

```sh
git clone <this repo> tizen-tv-emu && cd tizen-tv-emu
./build.sh   # downloads QEMU 11.1.3 (checksum-verified), applies patches/, builds into .build/ (a few minutes)
./run.sh     # boots the TV and opens http://127.0.0.1:8765
```

The Smart Hub home screen appears after about 90 seconds. Press Ctrl+C in the terminal to stop the TV.

The TV's disks live in `~/.tizen-tv-emu`. To keep them somewhere else, set `TIZEN_TV_EMU_HOME`; if Tizen Studio isn't in `~/tizen-studio`, set `TIZEN_STUDIO`. The disks are thin overlays on Samsung's images, so installed apps persist. Delete the folder to start over with a fresh TV.

## Controlling the TV

- **Remote:** click the buttons on the remote next to the screen.
- **Keyboard:** click the TV screen first, then use arrows, Enter (OK), Esc (Return) and F5 (Smart Hub).
- Extra, Play/Pause and long-press Exit don't work, because the emulated keyboard can't send their key codes. Color keys aren't on this remote.

## Installing your app

The TV only installs apps signed with a **Samsung** certificate that lists its device ID (DUID). A plain Tizen certificate is rejected.

1. Wait for the home screen: `sdb` connects earlier, but installs fail until the TV has finished starting. `~/tizen-studio/tools/sdb devices` then shows `emulator-26101`.
2. Get its DUID: `~/tizen-studio/tools/sdb -s emulator-26101 shell 0 getduid`. It doesn't come from the disk: a brand-new TV folder got the same DUID as an old one, so a certificate keeps working when you start over.
3. In Tizen Studio's Certificate Manager, create a Samsung TV certificate (or a new distributor certificate for an existing profile) and add that DUID, plus the DUIDs of any real TVs you use.
4. Package and install:

   ```sh
   tizen package -t wgt -s <profile> -- <built app folder>
   tizen install -n <app>.wgt -s emulator-26101 -- <built app folder>
   tizen run -p <app id> -s emulator-26101
   ```

The TV image has `sdb shell` disabled; `sdb shell 0 <command>` (for example `getduid`, `applist`, `kill <pkg id>`) works.

## Debugging a web app

```sh
sdb -s emulator-26101 shell 0 kill <package id>           # it must not be running
sdb -s emulator-26101 shell 0 debug <app id>              # prints "... port: NNNNN"
sdb -s emulator-26101 forward tcp:9333 tcp:NNNNN
```

Then open `http://127.0.0.1:9333/json` and use the `devtoolsFrontendUrl`, or any Chrome DevTools Protocol client.

## Limits

- **Slow.** Every x86 instruction is emulated in software. Use it to check that an app installs, starts and behaves on a real TV runtime, not to judge performance.
- Only the TV's default 1920×1080 resolution is set up.
- macOS only: the GL backends for Linux (GLX) and Windows (WGL) from Samsung's fork were not ported.
- Samsung's other emulator devices (sensors, tuner, camera, the remote-key device) are not included.
- Always cold-boot. A warm reset can trip a guest timer check.

## How it works

`patches/` holds two patches on top of upstream QEMU 11.1.3:

1. `hw/vigs`: Samsung's VIGS device, moved to the QEMU 11 device and console APIs. It always draws into QEMU's console surface, which QEMU then serves over VNC.
2. `hw/yagl`: Samsung's YaGL device. A small compatibility header maps the QEMU 2.8 memory helpers it used onto QEMU 11's APIs.

`run.sh` starts QEMU with a standard `pc` machine and both devices, and serves the screen over a local-only VNC websocket. `remote.py` serves the page that shows that screen (via noVNC) next to Samsung's remote skin, and sends each button's key code from Samsung's `layout.xml` to the TV through QEMU's monitor.

The VIGS and YaGL sources come from the `tizen_studio_6.5_p10.0` branch of Samsung's Tizen QEMU fork. At the time of porting, `git.tizen.org` was unreachable, so they were taken from the GitHub mirror `CrazyBoy2014/tizen-qemu`.

## License

GPL-2.0, like QEMU (see `LICENSE`). The VIGS and YaGL sources keep Samsung's copyright headers (GPL-2.0-or-later).
