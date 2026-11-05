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

if [ ! -f "$SRC/build/build.ninja" ]; then
  mkdir -p "$SRC/build"
  (cd "$SRC/build" && ../configure --target-list=x86_64-softmmu --enable-slirp \
    --disable-docs --disable-werror --disable-sdl --disable-gtk)
fi
ninja -C "$SRC/build" qemu-system-x86_64 qemu-img

echo "Built $SRC/build/qemu-system-x86_64. Start the TV with ./run.sh"
