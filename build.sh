#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/AceStream Mac Player.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
MODULE_CACHE_DIR="$ROOT_DIR/build/ModuleCache"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$MODULE_CACHE_DIR"

swiftc \
  -O \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "$ROOT_DIR/Sources/AceStreamMac/main.swift" \
  -o "$MACOS_DIR/AceStreamMac" \
  -framework SwiftUI \
  -framework AVKit \
  -framework AVFoundation \
  -framework AppKit \
  -framework Network

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/AceStreamMac"

echo "$APP_DIR"
