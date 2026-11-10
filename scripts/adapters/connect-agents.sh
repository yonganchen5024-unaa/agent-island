#!/bin/bash
# Point the agents installed on this Mac at Agent Island: Claude Code, Codex, OpenCode and DSH.
# An agent that is not installed is skipped. Run install-app.sh first. No agent's permission
# mode is changed. --undo takes Claude, Codex and DSH off again and lists OpenCode's two files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="$HOME/Library/Application Support/Agent Island/bin"
PLUGINS="$HOME/.config/opencode/plugins"
PROFILES="$HOME/.dsh/profiles"
STAMP="$(date +%Y%m%d-%H%M%S)"
BEGIN="# >>> agent-island >>> remove this block to uninstall"
END="# <<< agent-island <<<"
DSH="$(command -v dsh || true)"; [[ -n "$DSH" ]] || DSH="$HOME/.local/bin/dsh"

has_codex() {
  [[ -x "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" || -x "/Applications/Codex.app/Contents/Resources/codex" ]] || command -v codex >/dev/null
}
has_opencode() { [[ -d "$HOME/.config/opencode" || -x "$HOME/.opencode/bin/opencode" ]] || command -v opencode >/dev/null; }

remove_block() {
  /usr/bin/python3 -I - "$1" "$BEGIN" "$END" <<'PY'
import sys
path, begin, end = sys.argv[1:]
out, inside = [], False
for line in open(path, encoding='utf-8').read().splitlines(True):
    if line.strip() == begin: inside = True
    elif line.strip() == end: inside = False
    elif not inside: out.append(line)
open(path, 'w', encoding='utf-8').write(''.join(out))
PY
}

if [[ "${1:-}" == "--undo" ]]; then
  /usr/bin/python3 -I "$ROOT/scripts/adapters/claude/install_claude_hooks.py" --undo
  if has_codex; then /usr/bin/python3 -I "$ROOT/scripts/adapters/codex/install_codex_hook.py" --undo; fi
  for profile in web desktop; do
    file="$PROFILES/$profile/cordis.patch.yml"
    if [[ -f "$file" ]] && grep -qF "$BEGIN" "$file"; then
      cp "$file" "$file.island-backup-$STAMP"
      remove_block "$file"
      echo "DSH $profile: removed"
    fi
  done
  if [[ -f "$PLUGINS/agent-island.js" ]]; then
    echo "OpenCode: delete these two files by hand, then restart OpenCode:"
    echo "  $PLUGINS/agent-island.js"
    echo "  $PLUGINS/agent-island-watch.py"
  fi
  exit 0
fi

[[ -f "$BIN/claude_approval_hook.py" ]] || { echo "Run scripts/install-app.sh first." >&2; exit 1; }

/usr/bin/python3 -I "$ROOT/scripts/adapters/claude/install_claude_hooks.py"

if has_codex; then
  /usr/bin/python3 -I "$ROOT/scripts/adapters/codex/install_codex_hook.py"
else
  echo "Codex: not installed, skipped"
fi

if has_opencode; then
  mkdir -p "$PLUGINS"
  /usr/bin/install -m 0644 "$ROOT/scripts/adapters/opencode/agent-island.js" "$ROOT/scripts/adapters/opencode/agent-island-watch.py" "$PLUGINS/"
  echo "OpenCode: plugin copied to $PLUGINS (restart OpenCode)"
else
  echo "OpenCode: not installed, skipped"
fi

if [[ -x "$DSH" && -d "$PROFILES" ]]; then
  for profile in web desktop; do
    file="$PROFILES/$profile/cordis.patch.yml"
    [[ -f "$file" ]] || { echo "DSH $profile: no $file, skipped"; continue; }
    if grep -qF "$BEGIN" "$file"; then echo "DSH $profile: already connected"; continue; fi
    cp "$file" "$file.island-backup-$STAMP"
    [[ -z "$(tail -c1 "$file")" ]] || echo >> "$file"
    {
      echo "$BEGIN"
      echo "- insert:"
      echo "    - id: agent-island"
      echo "      name: \"$BIN/agent-island-dsh.mjs\""
      echo "$END"
    } >> "$file"
    # A patch file that does not parse stops DSH from starting, so check it and put it back if so.
    if ! "$DSH" --profile "$profile" --dump-config 2>/dev/null | grep -q "agent-island"; then
      cp "$file.island-backup-$STAMP" "$file"
      echo "DSH $profile: check failed, file restored" >&2
      exit 1
    fi
    echo "DSH $profile: connected (restart DSH). Backup: $file.island-backup-$STAMP"
  done
else
  echo "DSH: not installed, skipped"
fi
echo "Done. Claude and Codex pick this up in new sessions."
