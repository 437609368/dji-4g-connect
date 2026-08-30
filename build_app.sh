#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/dist/DJI 4G Connect.app"
LIBUSB_VERSION="1.0.30"
LIBUSB_PREFIX="/tmp/dji4g-connect-libusb-${LIBUSB_VERSION}"
LIBUSB_LIBRARY="$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib"

if [[ ! -f "$LIBUSB_LIBRARY" ]]; then
  VENDOR_DIR="$ROOT/.build/vendor"
  ARCHIVE="$VENDOR_DIR/libusb-${LIBUSB_VERSION}.tar.bz2"
  SOURCE_DIR="$VENDOR_DIR/libusb-${LIBUSB_VERSION}"
  mkdir -p "$VENDOR_DIR"
  if [[ ! -f "$ARCHIVE" ]]; then
    curl -fsSL "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VERSION}/libusb-${LIBUSB_VERSION}.tar.bz2" -o "$ARCHIVE"
  fi
  if [[ ! -d "$SOURCE_DIR" ]]; then
    tar -xjf "$ARCHIVE" -C "$VENDOR_DIR"
  fi
  rm -rf "$LIBUSB_PREFIX"
  cd "$SOURCE_DIR"
  ./configure --prefix="$LIBUSB_PREFIX" --disable-static --enable-shared --disable-udev >/dev/null
  make -j"$(sysctl -n hw.ncpu)" >/dev/null
  make install >/dev/null
  cd "$ROOT"
fi

swift build -c release --package-path "$ROOT"
rm -rf "$ROOT/dist"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BUILD_DIR/DJI4GConnect" "$APP_DIR/Contents/MacOS/DJI4GConnect"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$LIBUSB_LIBRARY" "$APP_DIR/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$APP_DIR/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/DJI4GConnect"

ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$ROOT/AppIcon.svg" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -s format png -z "$doubled" "$doubled" "$ROOT/AppIcon.svg" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --deep --sign - "$APP_DIR"
echo "Built $APP_DIR"
