#!/bin/sh
# Start the Tizen TV emulator and open the TV screen + remote at http://127.0.0.1:8765.
# Ctrl+C (or closing this terminal) stops the TV. Extra arguments go to QEMU.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
QEMU_SRC="$HERE/.build/qemu-11.1.3"
QEMU="$QEMU_SRC/build/qemu-system-x86_64"
QEMU_IMG="$QEMU_SRC/build/qemu-img"
STUDIO="${TIZEN_STUDIO:-$HOME/tizen-studio}"
VM="${TIZEN_TV_EMU_HOME:-$HOME/.tizen-tv-emu}"

[ -x "$QEMU" ] || { echo "QEMU isn't built yet. Run ./build.sh first." >&2; exit 1; }

# Newest installed TV platform, e.g. ~/tizen-studio/platforms/tizen-10.0/tv-samsung
PLATFORM=$(ls -d "$STUDIO"/platforms/tizen-*/tv-samsung 2>/dev/null | sort -V | tail -1)
IMAGE=$(ls "$PLATFORM"/emulator-images/*/emulimg-* 2>/dev/null | head -1)
KERNEL="$PLATFORM/emulator/data/kernel/bzImage.x86_64"
SWAP_TEMPLATE="$STUDIO/tools/emulator/storages/swap/swap.img"
if [ -z "$PLATFORM" ] || [ -z "$IMAGE" ] || [ ! -f "$KERNEL" ] || [ ! -f "$SWAP_TEMPLATE" ]; then
  echo "No TV emulator image found in $STUDIO. In Tizen Studio's Package Manager install" >&2
  echo "'Emulator' and 'TV-SAMSUNG-Public-Emulator', or set TIZEN_STUDIO to your install." >&2
  exit 1
fi
VERSION=$(basename "$(dirname "$PLATFORM")" | sed 's/^tizen-//')

# The disks are thin overlays on Samsung's images, so the TV keeps installed apps (and its DUID).
mkdir -p "$VM"
[ -f "$VM/root.qcow2" ] || "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$IMAGE" "$VM/root.qcow2"
[ -f "$VM/swap.qcow2" ] || "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$SWAP_TEMPLATE" "$VM/swap.qcow2"

TIZEN_TV_EMU_MONITOR="$VM/mon.sock" \
TIZEN_TV_EMU_SKIN="$PLATFORM/emulator-resources/skins/tv-1920x1080/controller/Smart(2016)" \
TIZEN_TV_EMU_KEYMAPS="$QEMU_SRC/subprojects/keycodemapdb/data/keymaps.csv" \
  python3 "$HERE/remote.py" &
REMOTE=$!
trap 'kill $REMOTE 2>/dev/null' EXIT
(sleep 2; open http://127.0.0.1:8765) &

echo "Booting Tizen TV $VERSION (about 90 s to the home screen). Guest log: $VM/klog.txt"
# Software-emulated x86 (TCG): Apple Silicon can't virtualize x86. no_timer_check avoids
# a false "IO-APIC + timer doesn't work" panic when the emulated CPU is slow to start.
"$QEMU" -M pc -accel tcg,thread=multi -cpu max -smp 4 -m 2048 \
  -kernel "$KERNEL" \
  -append "vm_name=T-samsung-$VERSION-x86_64 video=LVDS-1:1920x1080-32@60 dpi=72 clocksource=hpet consoleblank=0 no_timer_check host_ip=10.0.2.2 console=ttyS0 model=4ksero sdb_port=26100, vm_resolution=1920x1080" \
  -drive file="$VM/root.qcow2",if=none,id=drive,cache.no-flush=on -device virtio-blk-pci,drive=drive \
  -drive file="$VM/swap.qcow2",if=none,id=swap -device virtio-blk-pci,drive=swap \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:26101-:26101 -device virtio-net-pci,netdev=n0 \
  -device virtio-serial -serial file:"$VM/klog.txt" -vga none \
  -device vigs,backend=gl,wsi=vigs_wsi,vblank_emulation=on -device yagl,wsi=vigs_wsi \
  -display none -vnc 127.0.0.1:0,websocket=127.0.0.1:5700 \
  -monitor unix:"$VM/mon.sock",server,nowait -rtc base=utc "$@"
