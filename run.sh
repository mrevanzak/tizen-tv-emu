#!/bin/sh
# Start the Tizen TV emulator and open the TV screen + remote at http://127.0.0.1:8765.
# Ctrl+C (or closing this terminal) stops the TV. Extra arguments go to QEMU.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
QEMU_SRC="$HERE/.build/qemu-11.1.3"
QEMU_IMG="$QEMU_SRC/build/qemu-img"
STUDIO="${TIZEN_STUDIO:-$HOME/tizen-studio}"
# macOS caps Unix socket paths at 104 bytes, so the monitor socket can't live next to the disks.
MONITOR="/tmp/tizen-tv-emu-$(id -u).sock"

[ -x "$QEMU_IMG" ] || { echo "QEMU isn't built yet. Run ./build.sh first." >&2; exit 1; }

# TIZEN_TV_VERSION picks a platform (e.g. 6.0); the default is the newest installed one,
# e.g. ~/tizen-studio/platforms/tizen-10.0/tv-samsung
if [ -n "${TIZEN_TV_VERSION:-}" ]; then
  PLATFORM="$STUDIO/platforms/tizen-$TIZEN_TV_VERSION/tv-samsung"
else
  PLATFORM=$(ls -d "$STUDIO"/platforms/tizen-*/tv-samsung 2>/dev/null | sort -V | tail -1)
fi
IMAGE=$(ls "$PLATFORM"/emulator-images/*/emulimg-* 2>/dev/null | head -1)
SWAP_TEMPLATE="$STUDIO/tools/emulator/storages/swap/swap.img"
if [ -z "$PLATFORM" ] || [ -z "$IMAGE" ] || [ ! -f "$SWAP_TEMPLATE" ]; then
  echo "No TV emulator image found in ${PLATFORM:-$STUDIO/platforms}. In Tizen Studio's Package Manager" >&2
  echo "install 'Emulator' and 'TV-SAMSUNG-Public-Emulator', or set TIZEN_STUDIO to your install." >&2
  exit 1
fi
VERSION=$(basename "$(dirname "$PLATFORM")" | sed 's/^tizen-//')

# Tizen 10.0 images are 64-bit; older ones are 32-bit and need the i386 QEMU.
ARCH=$(sed -n 's/^cpu=//p' "$(dirname "$IMAGE")/info.ini" | tr -d '\r')
case "$ARCH" in
  x86_64) QEMU="$QEMU_SRC/build/qemu-system-x86_64" ;;
  x86) QEMU="$QEMU_SRC/build/qemu-system-i386" ;;
  *) echo "Unsupported image CPU '$ARCH' in $(dirname "$IMAGE")/info.ini" >&2; exit 1 ;;
esac
KERNEL="$PLATFORM/emulator/data/kernel/bzImage.$ARCH"
[ -x "$QEMU" ] || { echo "$QEMU isn't built. Run ./build.sh again." >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "Kernel $KERNEL is missing." >&2; exit 1; }
SKIN=$(ls -d "$PLATFORM"/emulator-resources/skins/*/controller/"Smart(2016)" "$PLATFORM"/emulator-resources/skins/*/controller/* 2>/dev/null | head -1)

# One folder per TV version, so each keeps its own disk and installed apps.
VM="${TIZEN_TV_EMU_HOME:-$HOME/.tizen-tv-emu/$VERSION}"

# The disks are thin overlays on Samsung's images, so the TV keeps its installed apps.
mkdir -p "$VM"
[ -f "$VM/root.qcow2" ] || "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$IMAGE" "$VM/root.qcow2"
BACKING=$("$QEMU_IMG" info --output=json "$VM/root.qcow2" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("backing-filename", ""))')
[ "$BACKING" = "$IMAGE" ] || { echo "$VM/root.qcow2 was made from $BACKING, not $IMAGE. Use another TIZEN_TV_EMU_HOME." >&2; exit 1; }
[ -f "$VM/swap.qcow2" ] || "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$SWAP_TEMPLATE" "$VM/swap.qcow2"

TIZEN_TV_EMU_MONITOR="$MONITOR" \
TIZEN_TV_EMU_SKIN="$SKIN" \
TIZEN_TV_EMU_KEYMAPS="$QEMU_SRC/subprojects/keycodemapdb/data/keymaps.csv" \
  python3 "$HERE/remote.py" &
REMOTE=$!
trap 'kill $REMOTE 2>/dev/null' EXIT
(sleep 2; open http://127.0.0.1:8765) &

echo "Booting Tizen TV $VERSION (about 90 s to the home screen). Guest log: $VM/klog.txt"
# Software-emulated x86 (TCG): Apple Silicon can't virtualize x86. no_timer_check avoids
# a false "IO-APIC + timer doesn't work" panic when the emulated CPU is slow to start.
# nosmap: Samsung's lwipc driver in older images (e.g. 6.0) reads user memory directly,
# which -cpu max's SMAP turns into a kernel panic at boot.
"$QEMU" -M pc -accel tcg,thread=multi -cpu max -smp 4 -m 2048 \
  -kernel "$KERNEL" \
  -append "vm_name=T-samsung-$VERSION-$ARCH video=LVDS-1:1920x1080-32@60 dpi=72 clocksource=hpet consoleblank=0 no_timer_check nosmap host_ip=10.0.2.2 console=ttyS0 model=4ksero sdb_port=26100, vm_resolution=1920x1080" \
  -drive file="$VM/root.qcow2",if=none,id=drive,cache.no-flush=on -device virtio-blk-pci,drive=drive \
  -drive file="$VM/swap.qcow2",if=none,id=swap -device virtio-blk-pci,drive=swap \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:26101-:26101 -device virtio-net-pci,netdev=n0 \
  -device virtio-serial -serial file:"$VM/klog.txt" -vga none \
  -device vigs,backend=gl,wsi=vigs_wsi,vblank_emulation=on -device yagl,wsi=vigs_wsi \
  -display none -vnc 127.0.0.1:0,websocket=127.0.0.1:5700 \
  -monitor unix:"$MONITOR",server,nowait -rtc base=utc "$@"
