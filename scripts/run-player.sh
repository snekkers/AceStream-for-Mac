#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/build/AceStream Mac Player.app"

"$ROOT_DIR/scripts/start-engine.sh"

if [ ! -d "$APP_PATH" ]; then
  "$ROOT_DIR/build.sh"
fi

open "$APP_PATH"
