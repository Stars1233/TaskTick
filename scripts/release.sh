#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# TaskTick Release Script
# Builds arm64 + x86_64 DMGs and uploads to GitHub Release
# Usage: ./scripts/release.sh [version]
#   e.g. ./scripts/release.sh 1.2.0
# ─────────────────────────────────────────────

APP_NAME="TaskTick"
BUNDLE_ID="com.lifedever.TaskTick"
REPO="lifedever/TaskTick"
GITEE_REPO="lifedever/task-tick"
MIN_MACOS="14.0"

# ── Parse args ──
ASSUME_YES=false
VERSION=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    -*)
      echo "Unknown option: $arg"
      echo "Usage: $0 <version> [--yes]"
      exit 1
      ;;
    *)
      if [ -n "$VERSION" ]; then
        echo "Unexpected extra argument: $arg"
        exit 1
      fi
      VERSION="$arg"
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version> [--yes]"
  echo "  e.g. $0 1.2.0"
  echo "  --yes  skip the upload prompt (required when stdin is not a TTY)"
  exit 1
fi
TAG="v${VERSION}"
BUILD_NUMBER=$(date +%Y%m%d%H%M)

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.release"
ICON_PATH="${PROJECT_ROOT}/Sources/Resources/AppIcon.icns"

echo "══════════════════════════════════════════"
echo "  ${APP_NAME} Release ${TAG}"
echo "══════════════════════════════════════════"

# ── Clean ──
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# ── Build function ──
build_arch() {
  local ARCH="$1"
  echo ""
  echo "── Building for ${ARCH} ──"

  local ARCH_BUILD_DIR="${BUILD_DIR}/${ARCH}"
  local APP_BUNDLE="${ARCH_BUILD_DIR}/${APP_NAME}.app"

  # Build with SwiftPM
  swift build \
    --package-path "${PROJECT_ROOT}" \
    --configuration release \
    --arch "${ARCH}" \
    --build-path "${ARCH_BUILD_DIR}/build"

  # Locate binary (SPM target was renamed to TaskTickApp in Task 0.2 to dodge
  # case-insensitive APFS collision with the lowercase 'tasktick' CLI target;
  # we copy + rename to TaskTick during the cp into the .app below)
  local SPM_TARGET="TaskTickApp"
  local BIN_PATH
  BIN_PATH=$(find "${ARCH_BUILD_DIR}/build" -name "${SPM_TARGET}" -type f -perm +111 | grep -v '\.build\|\.dSYM\|\.bundle' | head -1)
  if [ -z "${BIN_PATH}" ]; then
    echo "Error: Could not find built binary for ${ARCH}"
    exit 1
  fi
  echo "  Binary: ${BIN_PATH}"

  # Create .app bundle structure
  mkdir -p "${APP_BUNDLE}/Contents/MacOS"
  mkdir -p "${APP_BUNDLE}/Contents/Resources"

  # Copy binary (rename TaskTickApp → TaskTick during cp; user-facing name)
  cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

  # Copy CLI binary to Contents/cli/ — NOT Contents/MacOS/.
  # macOS APFS is case-insensitive by default, so the GUI binary
  # 'TaskTick' and CLI binary 'tasktick' would collide in MacOS/,
  # with the second cp silently overwriting the first → app fails
  # to launch. Cask's `binary` field points here for $PATH symlink.
  local CLI_BIN_PATH
  CLI_BIN_PATH=$(find "${ARCH_BUILD_DIR}/build" -name "tasktick" -type f -perm +111 | grep -v '\.build\|\.dSYM\|\.bundle' | head -1)
  if [ -n "${CLI_BIN_PATH}" ]; then
    mkdir -p "${APP_BUNDLE}/Contents/cli"
    cp "${CLI_BIN_PATH}" "${APP_BUNDLE}/Contents/cli/tasktick"
    echo "  CLI: tasktick (Contents/cli/)"
  fi

  # Glob-copy ALL *.bundle (TaskTick_TaskTickCore.bundle and any future
  # SPM target bundle). Per CLAUDE.md global rule.
  echo "  Bundles:"
  for bundle in $(find "${ARCH_BUILD_DIR}/build" -name "*.bundle" -type d -not -path '*\.dSYM*'); do
    cp -R "${bundle}" "${APP_BUNDLE}/"
    echo "    $(basename "${bundle}")"
  done

  # Copy icon
  if [ -f "${ICON_PATH}" ]; then
    cp "${ICON_PATH}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  fi

  # Generate Info.plist
  cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
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
    <key>NSMainStoryboardFile</key>
    <string></string>
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
            <string>com.lifedever.TaskTick.urlscheme</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>tasktick</string>
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
  local SDK_VERSION
  SDK_VERSION=$(xcrun --show-sdk-version)
  vtool -set-build-version macos "${MIN_MACOS}" "${SDK_VERSION}" -replace \
    -output "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" >/dev/null
  echo "  SDK stamp: ${SDK_VERSION}"

  # Ad-hoc code sign (deep sign all nested binaries/frameworks)
  echo "  Signing..."
  codesign --force --deep --no-strict --sign - "${APP_BUNDLE}"
  echo "  Signed: $(codesign -dv "${APP_BUNDLE}" 2>&1 | grep 'Signature')"

  echo "  App bundle: ${APP_BUNDLE}"
}

# ── Create DMG function ──
create_dmg() {
  local ARCH="$1"
  local APP_BUNDLE="${BUILD_DIR}/${ARCH}/${APP_NAME}.app"
  local DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
  local DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
  local DMG_STAGING="${BUILD_DIR}/dmg-staging-${ARCH}"

  echo ""
  echo "── Creating DMG: ${DMG_NAME} ──"

  # Create staging directory with app and Applications symlink
  rm -rf "${DMG_STAGING}"
  mkdir -p "${DMG_STAGING}"
  cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
  ln -s /Applications "${DMG_STAGING}/Applications"

  # Create DMG
  hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" \
    -quiet

  rm -rf "${DMG_STAGING}"
  echo "  DMG: ${DMG_PATH}"
  echo "  Size: $(du -h "${DMG_PATH}" | cut -f1)"
}

# ── Build both architectures ──
build_arch "arm64"
build_arch "x86_64"

# ── Create DMGs ──
create_dmg "arm64"
create_dmg "x86_64"

# ── Summary ──
echo ""
echo "══════════════════════════════════════════"
echo "  Build complete!"
echo "══════════════════════════════════════════"
echo ""
echo "  ${BUILD_DIR}/${APP_NAME}-${VERSION}-arm64.dmg"
echo "  ${BUILD_DIR}/${APP_NAME}-${VERSION}-x86_64.dmg"
echo ""

# ── Upload to GitHub Release ──
#
# The prompt used to be a bare `read`. With no TTY (CI, or an agent driving
# the script) `read` returns empty instantly, the [y/N] default said "no",
# and the script exited 0 having built DMGs but published nothing — a
# successful-looking run that shipped no release. Non-interactive callers
# must now pass --yes explicitly; anything else is a hard failure.
if [ "$ASSUME_YES" = true ]; then
  DO_UPLOAD=true
elif [ -t 0 ]; then
  read -p "Upload to GitHub Release ${TAG}? [y/N] " -n 1 -r
  echo ""
  [[ $REPLY =~ ^[Yy]$ ]] && DO_UPLOAD=true || DO_UPLOAD=false
else
  echo ""
  echo "  ERROR: stdin is not a TTY, so the upload prompt cannot be answered."
  echo "  DMGs were built but NOTHING was published — no tag, no release."
  echo "  Re-run with --yes to publish non-interactively:"
  echo "    $0 ${VERSION} --yes"
  exit 1
fi

if [ "$DO_UPLOAD" = true ]; then
  echo ""
  echo "── Creating GitHub Release ──"

  # Check if tag exists
  if git rev-parse "${TAG}" >/dev/null 2>&1; then
    TAG_COMMIT=$(git rev-list -n 1 "${TAG}")
    HEAD_COMMIT=$(git rev-parse HEAD)
    if [ "${TAG_COMMIT}" != "${HEAD_COMMIT}" ]; then
      echo "  ERROR: Tag ${TAG} exists but points to ${TAG_COMMIT:0:7}, not HEAD (${HEAD_COMMIT:0:7})."
      echo "  Delete the old tag first:  git tag -d ${TAG} && git push origin :refs/tags/${TAG}"
      exit 1
    fi
    echo "  Tag ${TAG} already exists and points to HEAD."
  else
    echo "  Creating tag ${TAG}..."
    git tag -a "${TAG}" -m "Release ${TAG}"
    git push origin "${TAG}"
  fi

  # Create release (or upload to existing)
  if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    echo "  Release ${TAG} already exists, uploading assets..."
    gh release upload "${TAG}" \
      "${BUILD_DIR}/${APP_NAME}-${VERSION}-arm64.dmg" \
      "${BUILD_DIR}/${APP_NAME}-${VERSION}-x86_64.dmg" \
      --repo "${REPO}" \
      --clobber
  else
    gh release create "${TAG}" \
      "${BUILD_DIR}/${APP_NAME}-${VERSION}-arm64.dmg" \
      "${BUILD_DIR}/${APP_NAME}-${VERSION}-x86_64.dmg" \
      --repo "${REPO}" \
      --title "TaskTick ${TAG}" \
      --generate-notes
  fi

  echo ""
  echo "  Release uploaded: https://github.com/${REPO}/releases/tag/${TAG}"
fi

# ── Upload to Gitee Release ──
echo ""
echo "── Publishing to Gitee ${GITEE_REPO} ──"
if [ -n "${GITEE_TOKEN:-}" ]; then
  # Push tag to Gitee
  if git remote get-url gitee >/dev/null 2>&1; then
    git push gitee "${TAG}" 2>/dev/null || echo "  Tag already exists on Gitee"
  fi

  # Create Gitee release
  GITEE_RELEASE_RESP=$(curl -s -X POST \
    "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases" \
    -H "Content-Type: application/json" \
    -d "{
      \"access_token\": \"${GITEE_TOKEN}\",
      \"tag_name\": \"${TAG}\",
      \"name\": \"TaskTick ${TAG}\",
      \"body\": \"## TaskTick ${TAG}\n\n### Download\n- **Apple Silicon (M1/M2/M3/M4)**: TaskTick-${VERSION}-arm64.dmg\n- **Intel**: TaskTick-${VERSION}-x86_64.dmg\",
      \"target_commitish\": \"main\"
    }")

  GITEE_RELEASE_ID=$(echo "$GITEE_RELEASE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

  if [ -n "$GITEE_RELEASE_ID" ] && [ "$GITEE_RELEASE_ID" != "None" ]; then
    for ARCH in arm64 x86_64; do
      DMG_FILE="${BUILD_DIR}/${APP_NAME}-${VERSION}-${ARCH}.dmg"
      echo "  Uploading ${APP_NAME}-${VERSION}-${ARCH}.dmg..."
      curl -s -X POST \
        "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases/${GITEE_RELEASE_ID}/attach_files" \
        -H "Content-Type: multipart/form-data" \
        -F "access_token=${GITEE_TOKEN}" \
        -F "file=@${DMG_FILE}" > /dev/null
      echo "  Uploaded."
    done
    echo "  Gitee release: https://gitee.com/${GITEE_REPO}/releases/tag/${TAG}"
  else
    echo "  Warning: Failed to create Gitee release"
    echo "  Response: ${GITEE_RELEASE_RESP}"
  fi
else
  echo "  Skipped (no GITEE_TOKEN env var)"
  echo "  To enable: export GITEE_TOKEN=your_gitee_personal_access_token"
fi

echo ""
echo "Done."
