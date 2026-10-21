#!/bin/zsh
# A fast, cwd-independent stdio entry point for Codex and other MCP clients.
# Build during installation, never during the client's initialization timeout.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
case "$CONFIG" in
  debug|release) ;;
  *) print -u2 -- "Unsupported CONFIG: $CONFIG (use debug or release)"; exit 1 ;;
esac

if [[ ! -x ".build/$CONFIG/iphone-use" ]]; then
  print -u2 -- "iPhone Use is not built. Run: swift build --package-path \"$PWD\" -c $CONFIG"
  exit 1
fi

# stdout belongs exclusively to the MCP JSON-RPC stream.
exec ".build/$CONFIG/iphone-use" mcp
