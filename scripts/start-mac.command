#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v node >/dev/null || ! command -v codex >/dev/null; then
  echo 'Install Node.js 22+ and the Codex CLI before starting RayBridge.'
  exit 1
fi
if [ ! -d node_modules ]; then npm ci --omit=dev; fi
open http://127.0.0.1:8844
exec node bridge/server.mjs
