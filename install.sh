#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"

DEST_DIR="$HOME/Applications"
APP_SRC="$ROOT/build/SysBar.app"
APP_DST="$DEST_DIR/SysBar.app"
LABEL="app.local.sysbar"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

pkill -x SysBar 2>/dev/null || true
sleep 0.2

mkdir -p "$DEST_DIR" "$HOME/Library/LaunchAgents"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
xattr -cr "$APP_DST" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${APP_DST}/Contents/MacOS/SysBar</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true

sleep 0.3
if ! pgrep -x SysBar >/dev/null 2>&1; then
  open -a "$APP_DST"
fi

echo "✓ 已安装: $APP_DST"
echo "✓ 登录自启"
