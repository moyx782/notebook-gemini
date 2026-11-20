#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "未检测到 docker，请先安装 Docker Desktop / OrbStack / Docker Engine。" >&2
  exit 1
fi

TARGETS="${1:-all}"
mkdir -p "$ROOT_DIR/dist/linux"

build_arch() {
  local platform="$1"
  echo "==> Building Linux packages in Docker for $platform ..."
  docker buildx build \
    --platform "$platform" \
    -f "$ROOT_DIR/packaging/linux/Dockerfile" \
    --output "type=local,dest=$ROOT_DIR/dist/linux" \
    "$ROOT_DIR"
}

case "$TARGETS" in
  amd64|x86_64)
    build_arch "linux/amd64"
    ;;
  arm64|aarch64)
    build_arch "linux/arm64"
    ;;
  all)
    build_arch "linux/amd64"
    build_arch "linux/arm64"
    ;;
  *)
    echo "Usage: $0 [amd64|arm64|all]" >&2
    exit 1
    ;;
esac

echo "==> Output packages:"
ls -lh "$ROOT_DIR/dist/linux"
