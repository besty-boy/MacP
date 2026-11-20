#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-Release}"
DERIVED_DATA="${ROOT_DIR}/.build/xcode"

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "Building MacP (${CONFIG})..."
xcodebuild \
  -project "${ROOT_DIR}/MacP.xcodeproj" \
  -scheme MacP \
  -configuration "${CONFIG}" \
  -derivedDataPath "${DERIVED_DATA}" \
  build

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}/MacP.app"
echo ""
echo "Build succeeded: ${APP_PATH}"
echo "Binary path for Claude Desktop / Cursor:"
echo "  ${APP_PATH}/Contents/MacOS/MacP --stdio"
