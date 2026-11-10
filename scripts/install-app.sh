#!/bin/bash
# Install Agent Island to /Applications and start it at login. Rerun to update; "remove" undoes it.
# Exit status 0 from the menu's 退出 leaves it stopped until the next login; a crash restarts it.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TARGET="/Applications/Agent Island.app"
LABEL="local.agentisland.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
stop_running() {
  /bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  /usr/bin/pkill -f "/Contents/MacOS/IslandReplica" 2>/dev/null || true
  sleep 1
}
if [[ "${1:-}" == "remove" ]]; then
  stop_running
  rm -f "$PLIST"
  rm -rf "$TARGET"
  echo "已移除登录项和 ${TARGET}"
  exit 0
fi
STAGE="$(mktemp -d)/Agent Island.app"
SWIFT_BUILD_FLAGS="${SWIFT_BUILD_FLAGS:-}" "$PROJECT_ROOT/scripts/build-app.sh" "$STAGE" >/dev/null
stop_running
rm -rf "$TARGET"
/usr/bin/ditto "$STAGE" "$TARGET"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$TARGET/Contents/MacOS/IslandReplica</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>10</integer>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLISTEOF
/usr/bin/plutil -lint "$PLIST" >/dev/null
# Agent hooks point at this copy, so app updates and moves cannot leave them dangling.
HOOK_DIR="$HOME/Library/Application Support/Agent Island/bin"
mkdir -p "$HOOK_DIR"
chmod 700 "$HOOK_DIR"
/usr/bin/install -m 0600 "$PROJECT_ROOT/scripts/claude_approval_hook.py" "$HOOK_DIR/claude_approval_hook.py"
/usr/bin/install -m 0644 "$PROJECT_ROOT/scripts/adapters/dsh/agent-island-dsh.mjs" "$HOOK_DIR/agent-island-dsh.mjs"
/usr/bin/install -m 0600 "$PROJECT_ROOT/scripts/claude_spool_hook.py" "$HOOK_DIR/claude_spool_hook.py"
# OpenCode loads its plugin from its own directory. Only refresh a copy that connect-agents.sh put there.
OPENCODE_PLUGINS="$HOME/.config/opencode/plugins"
if [[ -f "$OPENCODE_PLUGINS/agent-island.js" ]]; then
  /usr/bin/install -m 0644 "$PROJECT_ROOT/scripts/adapters/opencode/agent-island.js" "$PROJECT_ROOT/scripts/adapters/opencode/agent-island-watch.py" "$OPENCODE_PLUGINS/"
fi
echo "已安装：${TARGET}；登录项：${PLIST}；Hook：${HOOK_DIR}"
if /bin/launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
  echo "登录项已生效，崩溃后会自动重启。"
else
  # launchctl can be refused inside a sandbox (for example an agent's). If the login item is already loaded,
  # launchd restarts the new binary within its throttle window, which keeps crash restart working.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    /usr/bin/pgrep -f "/Contents/MacOS/IslandReplica" >/dev/null && break
    sleep 1
  done
  if /usr/bin/pgrep -f "/Contents/MacOS/IslandReplica" >/dev/null; then
    echo "登录项已在运行，launchd 已启动新版本。"
  else
    /usr/bin/open "$TARGET"
    echo "已直接启动。登录项下次登录生效；要立刻生效，在普通终端运行："
    echo "  pkill -f '/Contents/MacOS/IslandReplica'; launchctl bootstrap $DOMAIN '$PLIST'"
  fi
fi
