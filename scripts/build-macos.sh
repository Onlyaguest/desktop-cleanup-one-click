#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build/macos"
APP_PATH="${BUILD_DIR}/一键整理桌面文件.app"
SOURCE="${PROJECT_DIR}/macos/Sources/main.swift"
DEPLOYMENT_TARGET="12.0"

rm -rf "${BUILD_DIR}"
mkdir -p "${APP_PATH}/Contents/MacOS"

xcrun swiftc -parse-as-library \
  -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
  -framework AppKit "${SOURCE}" \
  -o "${BUILD_DIR}/DesktopCleanup-arm64"

xcrun swiftc -parse-as-library \
  -target "x86_64-apple-macosx${DEPLOYMENT_TARGET}" \
  -framework AppKit "${SOURCE}" \
  -o "${BUILD_DIR}/DesktopCleanup-x86_64"

lipo -create \
  "${BUILD_DIR}/DesktopCleanup-arm64" \
  "${BUILD_DIR}/DesktopCleanup-x86_64" \
  -output "${APP_PATH}/Contents/MacOS/DesktopCleanup"

cp "${PROJECT_DIR}/macos/Info.plist" "${APP_PATH}/Contents/Info.plist"
chmod 755 "${APP_PATH}/Contents/MacOS/DesktopCleanup"
codesign --force --deep --sign - "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

rm -f "${BUILD_DIR}/一键整理桌面文件-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent \
  "${APP_PATH}" \
  "${BUILD_DIR}/一键整理桌面文件-macOS-universal.zip"

echo "${BUILD_DIR}/一键整理桌面文件-macOS-universal.zip"
