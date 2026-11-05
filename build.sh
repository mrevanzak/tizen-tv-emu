#!/bin/sh
# Build QEMU with the Tizen VIGS (display) and YaGL (OpenGL) devices into .build/.
# Re-running only rebuilds what changed.
set -eu

QEMU_VERSION=11.1.3
QEMU_SHA256=5a8289c7940dc77d3873c81a6c29ba3afe1446fc9d36e77fa1658cdbecb84b22

HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/.build"
SRC="$OUT/qemu-$QEMU_VERSION"
TARBALL="$OUT/qemu-$QEMU_VERSION.tar.xz"

DEPS_HINT="Run: brew install ninja pkg-config glib pixman libslirp"
for tool in ninja pkg-config patch python3; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. $DEPS_HINT" >&2; exit 1; }
done
for lib in glib-2.0 pixman-1 slirp; do
  pkg-config --exists "$lib" || { echo "Missing $lib. $DEPS_HINT" >&2; exit 1; }
done

mkdir -p "$OUT"
if [ ! -f "$TARBALL" ]; then
  curl -fL --progress-bar -o "$TARBALL.part" "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$QEMU_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch for $TARBALL; delete it and retry." >&2; exit 1; }

if [ ! -d "$SRC" ]; then
  # Unpack and patch in a temporary folder, so a failed patch never leaves a half-patched tree.
  rm -rf "$SRC.tmp" && mkdir "$SRC.tmp"
  tar xf "$TARBALL" -C "$SRC.tmp" --strip-components 1
  for patch in "$HERE"/patches/*.patch; do
    patch -s -p1 -d "$SRC.tmp" < "$patch"
  done
  mv "$SRC.tmp" "$SRC"
fi

# i386 for the 32-bit TV images (Tizen 9.0 and older): YaGL reads guest pointers at the target's width.
# Optional libraries are off, so the build only needs the Homebrew packages listed above.
CONFIGURE_ARGS="--target-list=x86_64-softmmu,i386-softmmu --enable-slirp --disable-docs --disable-werror --disable-sdl --disable-gtk --disable-capstone --disable-gnutls --disable-vnc-jpeg --disable-png --disable-libssh --disable-libusb --disable-zstd --disable-gcrypt --disable-nettle"
if [ "$(cat "$SRC/build/.configure-args" 2>/dev/null)" != "$CONFIGURE_ARGS" ]; then
  mkdir -p "$SRC/build"
  # shellcheck disable=SC2086 # CONFIGURE_ARGS is a list of flags
  (cd "$SRC/build" && ../configure $CONFIGURE_ARGS)
  echo "$CONFIGURE_ARGS" > "$SRC/build/.configure-args"
fi
ninja -C "$SRC/build" qemu-system-x86_64 qemu-system-i386 qemu-img

echo "Built QEMU in $SRC/build. Start the TV with ./run.sh"
