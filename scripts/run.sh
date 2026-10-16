#!/bin/zsh
# Development runner: build and run without creating an .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
exec swift run -c "$CONFIG" iphone-use "$@"
