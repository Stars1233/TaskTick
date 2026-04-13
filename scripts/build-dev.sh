#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# TaskTick Dev Build Script
# Builds a dev version that can coexist with the release version
# Usage: ./scripts/build-dev.sh
# ─────────────────────────────────────────────

APP_NAME="TaskTick"
DEV_APP_NAME="TaskTick Dev"
BUNDLE_ID="com.lifedever.TaskTick.dev"
MIN_MACOS="14.0"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.dev-build"
ICON_PATH="${PROJECT_ROOT}/Sources/Resources/AppIcon.icns"
APP_BUNDLE="${BUILD_DIR}/${DEV_APP_NAME}.app"

echo "── Building ${DEV_APP_NAME} ──"

# Build
swift build \
  --package-path "${PROJECT_ROOT}" \
  --configuration debug \
  --build-path "${BUILD_DIR}/build"

# Locate binary
BIN_PATH=$(find "${BUILD_DIR}/build" -name "${APP_NAME}" -type f -perm +111 | grep -v '\.build\|\.dSYM\|\.bundle' | head -1)
if [ -z "${BIN_PATH}" ]; then
  echo "Error: Could not find built binary"
  exit 1
fi

# Locate resource bundle
RESOURCE_BUNDLE=$(find "${BUILD_DIR}/build" -name "${APP_NAME}_${APP_NAME}.bundle" -type d | head -1)

# Create .app bundle
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${DEV_APP_NAME}"

if [ -n "${RESOURCE_BUNDLE}" ]; then
  cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/"
fi

if [ -f "${ICON_PATH}" ]; then
  cp "${ICON_PATH}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  echo "  Icon: copied"
fi

# Info.plist with dev bundle ID
cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${DEV_APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DEV_APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>dev.$(date +%Y%m%d%H%M)</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0-dev</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${DEV_APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>LSUIElement</key>
    <false/>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
</dict>
</plist>
PLIST

# Sign (--no-strict to allow resource bundle at app root for SPM Bundle.module)
codesign --force --deep --no-strict --sign - "${APP_BUNDLE}"

echo ""
echo "── Done ──"
echo "  ${APP_BUNDLE}"
echo ""

# Install to /Applications and launch
INSTALL_PATH="/Applications/${DEV_APP_NAME}.app"
pkill -f "${DEV_APP_NAME}" 2>/dev/null && sleep 0.5
rm -rf "${INSTALL_PATH}"
cp -R "${APP_BUNDLE}" "${INSTALL_PATH}"
open "${INSTALL_PATH}"
