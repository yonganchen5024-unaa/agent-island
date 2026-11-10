#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_PATH="${1:-$PROJECT_ROOT/build/Agent Island.app}"
if [[ "$APP_PATH" != /* ]]; then
  echo "Pass an absolute output path." >&2
  exit 2
fi
if [[ "$APP_PATH" != *.app ]]; then
  echo "Output path must end in .app." >&2
  exit 2
fi
if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
  echo "Output already exists: $APP_PATH. Choose a new path." >&2
  exit 1
fi
# SWIFT_BUILD_FLAGS lets a caller add options. Where nested sandboxes are not allowed (for example
# when building from inside a sandboxed agent), use: SWIFT_BUILD_FLAGS="--disable-sandbox --scratch-path DIR".
read -r -a EXTRA_FLAGS <<< "${SWIFT_BUILD_FLAGS:-}"
swift build --package-path "$PROJECT_ROOT" -c release --product IslandReplica ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}
BIN_DIR="$(swift build --package-path "$PROJECT_ROOT" -c release --show-bin-path ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"})"
test -x "$BIN_DIR/IslandReplica"
mkdir -p "$(dirname "$APP_PATH")"
STAGE="$(mktemp -d "$(dirname "$APP_PATH")/.island-stage.XXXXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Agent Island.app/Contents/MacOS" "$STAGE/Agent Island.app/Contents/Resources"
cp "$BIN_DIR/IslandReplica" "$STAGE/Agent Island.app/Contents/MacOS/IslandReplica"
cp "$PROJECT_ROOT/scripts/claude_approval_broker.py" "$PROJECT_ROOT/scripts/claude_approval_hook.py" "$STAGE/Agent Island.app/Contents/Resources/"
cp "$PROJECT_ROOT/scripts/claude_observe_broker.py" "$PROJECT_ROOT/scripts/claude_observe_hook.py" "$PROJECT_ROOT/scripts/claude_observe_config.py" "$STAGE/Agent Island.app/Contents/Resources/"
cat > "$STAGE/Agent Island.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleExecutable</key><string>IslandReplica</string>
<key>CFBundleIdentifier</key><string>local.islandreplica.app</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Agent Island</string>
<key>CFBundleDisplayName</key><string>Agent Island</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>点击会话时切换到对应的终端标签页。只选择标签页，不会输入任何内容。</string>
</dict></plist>
PLIST
plutil -lint "$STAGE/Agent Island.app/Contents/Info.plist"
codesign --force --sign - "$STAGE/Agent Island.app"
# Never overwrite another bundle, even if one appears during compilation.
if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
  echo "Output appeared during build: $APP_PATH" >&2
  exit 1
fi
mv "$STAGE/Agent Island.app" "$APP_PATH"
echo "Built: $APP_PATH"
