#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${PORT:-8787}"
HOST="${HOST:-0.0.0.0}"
REBUILD_WEB=false

for arg in "$@"; do
  case "$arg" in
    --rebuild)
      REBUILD_WEB=true
      ;;
  esac
done

DART_BIN="dart"
if ! command -v dart >/dev/null 2>&1; then
  if [ -x "/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart" ]; then
    DART_BIN="/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart"
  fi
fi

if [ "$REBUILD_WEB" = true ] || [ ! -f "$SCRIPT_DIR/build/web/index.html" ]; then
  echo "正在构建 Flutter Web 端静态资源 (build/web)..."
  flutter build web
fi

if [ ! -f "$SCRIPT_DIR/packages/notebook_core/.dart_tool/package_config.json" ]; then
  echo "正在解析 notebook_core 依赖..."
  "$DART_BIN" --suppress-analytics pub get -C "$SCRIPT_DIR/packages/notebook_core"
fi

if [ ! -f "$SCRIPT_DIR/server/.dart_tool/package_config.json" ]; then
  echo "正在解析 server 依赖..."
  "$DART_BIN" --suppress-analytics pub get -C "$SCRIPT_DIR/server"
fi

echo "正在启动 SyncCanvas 三端实时同步服务..."
exec "$DART_BIN" --suppress-analytics run "$SCRIPT_DIR/server/bin/server.dart" \
  --host "$HOST" \
  --port "$PORT" \
  --data-dir "$SCRIPT_DIR/server/data" \
  --web-dir "$SCRIPT_DIR/build/web" \
  --apk-path "$SCRIPT_DIR/build/app/outputs/flutter-apk/app-release.apk"
