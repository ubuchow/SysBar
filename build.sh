#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/SysBar.app"
CONTENTS="$APP/Contents"
ARCH="$(uname -m)"
MIN_OS="13.0"
WORK="${TMPDIR:-/tmp}/sysbar-build-$$"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$WORK"

swiftc \
  -Osize \
  -whole-module-optimization \
  -target "${ARCH}-apple-macosx${MIN_OS}" \
  -module-cache-path "$WORK/mcp" \
  -framework AppKit \
  -framework CoreText \
  -framework IOKit \
  -framework SystemConfiguration \
  "$PROJECT_DIR/Sources/main.swift" \
  -o "$CONTENTS/MacOS/SysBar"

strip -x "$CONTENTS/MacOS/SysBar"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

# Finder / Applications 图标
ICON_SRC="$PROJECT_DIR/Resources/AppIcon-1024.png"
if [[ -f "$ICON_SRC" ]]; then
  mkdir -p "$WORK/icon.iconset"
  sips -z 16 16     "$ICON_SRC" --out "$WORK/icon.iconset/icon_16x16.png" >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$WORK/icon.iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$WORK/icon.iconset/icon_32x32.png" >/dev/null
  sips -z 64 64     "$ICON_SRC" --out "$WORK/icon.iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$ICON_SRC" --out "$WORK/icon.iconset/icon_128x128.png" >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$WORK/icon.iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$WORK/icon.iconset/icon_256x256.png" >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$WORK/icon.iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$WORK/icon.iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SRC" --out "$WORK/icon.iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$WORK/icon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"
fi

plutil -lint "$CONTENTS/Info.plist" >/dev/null
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none --identifier "app.local.sysbar" "$APP"

echo "── build ok ──"
echo "app: $APP"
du -sh "$APP"
echo -n "bin: "
wc -c < "$CONTENTS/MacOS/SysBar" | awk '{printf "%.1f KB\n", $1/1024}'
echo -n "icon: "
if [[ -f "$CONTENTS/Resources/AppIcon.icns" ]]; then
  wc -c < "$CONTENTS/Resources/AppIcon.icns" | awk '{printf "%.1f KB\n", $1/1024}'
else
  echo "(none)"
fi
