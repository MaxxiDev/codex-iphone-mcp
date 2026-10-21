#!/bin/zsh
# Build once and register this checkout as a local Codex stdio MCP server.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/install-codex-mcp.sh [--name NAME] [--skip-build]

Build iPhone Use and register its MCP server with the local Codex CLI.
  --name NAME    Server name (default: iphone-use); replaces an existing entry.
  --skip-build   Use an existing build.
  -h, --help     Show this help.

Environment: CONFIG=release|debug (default release), IPHONE_USE_PORT=7390.
Optional IPHONE_USE_STATE_DIR: absolute directory for shared locks/recovery logs.
The app must be started separately with ./scripts/run.sh.
EOF
}

server_name="iphone-use"
skip_build=0
while (( $# )); do
  case "$1" in
    --name)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
        print -u2 -- "--name requires a server name"
        exit 1
      fi
      server_name="$2"
      shift 2
      ;;
    --skip-build) skip_build=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -- "Unknown argument: $1"; usage >&2; exit 1 ;;
  esac
done

if [[ "$(uname -s)" != Darwin ]]; then
  print -u2 -- "iPhone Use requires macOS 14 or later."
  exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
  print -u2 -- "Codex CLI was not found in PATH. Install it, then run this script again."
  exit 1
fi

cd "$(dirname "$0")/.."
repo_dir="$PWD"
CONFIG="${CONFIG:-release}"
case "$CONFIG" in
  debug|release) ;;
  *) print -u2 -- "Unsupported CONFIG: $CONFIG (use debug or release)"; exit 1 ;;
esac
api_port="${IPHONE_USE_PORT:-7390}"
if [[ "$api_port" != <1-65535> ]]; then
  print -u2 -- "IPHONE_USE_PORT must be an integer from 1 to 65535."
  exit 1
fi
if [[ -n "${IPHONE_USE_STATE_DIR+x}" && "${IPHONE_USE_STATE_DIR:-}" != /* ]]; then
  print -u2 -- "IPHONE_USE_STATE_DIR must be an absolute path shared by all clients."
  exit 1
fi

if (( ! skip_build )); then
  swift build -c "$CONFIG"
fi
if [[ ! -x ".build/$CONFIG/iphone-use" ]]; then
  print -u2 -- "Missing .build/$CONFIG/iphone-use; run this script without --skip-build."
  exit 1
fi

# Let Codex edit its configuration; do not rewrite unrelated servers or settings.
mcp_env=(--env "CONFIG=$CONFIG" --env "IPHONE_USE_PORT=$api_port")
if [[ -n "${IPHONE_USE_STATE_DIR:-}" ]]; then
  mcp_env+=(--env "IPHONE_USE_STATE_DIR=$IPHONE_USE_STATE_DIR")
fi
codex mcp add "$server_name" "${mcp_env[@]}" -- "$repo_dir/scripts/mcp.sh"
codex mcp get "$server_name"
print -- ""
print -- "Start the app: IPHONE_USE_PORT=$api_port \"$repo_dir/scripts/run.sh\""
print -- "Then restart Codex or open a new chat to load the MCP tools."
