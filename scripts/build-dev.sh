#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# TaskTick Dev Build Script
# Builds a dev version that can coexist with the release version
# Usage: ./scripts/build-dev.sh
# ─────────────────────────────────────────────

APP_NAME="TaskTick"
SPM_TARGET="TaskTickApp"  # SPM target name (renamed in Task 0.2 to dodge case collision with lowercase 'tasktick')
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

# Locate binary (SPM target is TaskTickApp; we copy + rename to TaskTick during cp into bundle)
BIN_PATH=$(find "${BUILD_DIR}/build" -name "${SPM_TARGET}" -type f -perm +111 | grep -v '\.build\|\.dSYM\|\.bundle' | head -1)
if [ -z "${BIN_PATH}" ]; then
  echo "Error: Could not find built binary"
  exit 1
fi

# Create .app bundle
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${DEV_APP_NAME}"

# Copy CLI binary alongside the GUI binary. Same `swift build` produces both.
CLI_BIN_PATH=$(find "${BUILD_DIR}/build" -name "tasktick" -type f -perm +111 | grep -v '\.build\|\.dSYM\|\.bundle' | head -1)
if [ -n "${CLI_BIN_PATH}" ]; then
  cp "${CLI_BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/tasktick-dev"
  echo "  CLI: ${CLI_BIN_PATH} → tasktick-dev"
else
  echo "  Warning: tasktick CLI binary not found"
fi

# Glob-copy ALL SPM-generated *.bundle directories. Per CLAUDE.md global
# rule: hardcoding bundle names breaks when new SPM dependencies / library
# targets land. Bundle.module fatalErrors if its target's bundle isn't
# found at runtime, so a missing bundle = SIGTRAP crash.
echo "  Bundles:"
for bundle in $(find "${BUILD_DIR}/build" -name "*.bundle" -type d -not -path '*\.dSYM*'); do
  cp -R "${bundle}" "${APP_BUNDLE}/"
  echo "    $(basename "${bundle}")"
done

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
    <!-- macOS 14+ 的 ATS 默认拦截纯 IP 地址的 http 连接；自建 Bark 服务器
         （http://192.168.x.x / http://nas / http://xxx.local）需要此豁免。
         带完整域名的 http 仍被拦（应使用 https），不放开 NSAllowsArbitraryLoads。 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
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
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.lifedever.TaskTick.dev.urlscheme</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>tasktick-dev</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Restamp the SDK version in LC_BUILD_VERSION.
#
# SwiftPM writes the *deployment target* (14.0) into the load command's sdk
# field, not the SDK it actually compiled against. macOS reads that field to
# pick which design generation to draw the app in, so a 14.0 stamp silently
# opts the whole app out of the current look — toolbars, sidebar and controls
# all fall back to the pre-Liquid-Glass compatibility rendering.
#
# Must run before codesign: vtool rewrites the binary and invalidates any
# signature already on it.
SDK_VERSION=$(xcrun --show-sdk-version)
vtool -set-build-version macos "${MIN_MACOS}" "${SDK_VERSION}" -replace \
  -output "${APP_BUNDLE}/Contents/MacOS/${DEV_APP_NAME}" \
  "${APP_BUNDLE}/Contents/MacOS/${DEV_APP_NAME}" >/dev/null
echo "  SDK stamp: ${SDK_VERSION}"

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
