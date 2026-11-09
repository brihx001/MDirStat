#!/bin/bash
# Construit MDirStat.app (bundle signe ad-hoc, sans sandbox : un analyseur de disque
# doit lire tout le disque, ce que le sandbox interdit).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="MDirStat.app"
BIN=".build/${CONFIG}/MDirStat"

# Toolchain sans Xcode selectionne (macOS 27 / Swift 6.4) : systeme de
# compilation natif, et greffon des macros SwiftUI pris dans Xcode.app.
BUILD_ARGS=()
if swift build --build-system native --help >/dev/null 2>&1; then
  BUILD_ARGS+=(--build-system native)
fi

MACRO_PLUGINS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
if [ -f "${MACRO_PLUGINS}/libSwiftUIMacros.dylib" ]; then
  BUILD_ARGS+=(-Xswiftc -plugin-path -Xswiftc "${MACRO_PLUGINS}")
elif ! [ -f "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
  echo "WARNING: SwiftUI macro plugin not found." >&2
fi

echo "==> swift build (${CONFIG})"
swift build -c "${CONFIG}" "${BUILD_ARGS[@]}"

echo "==> assembling the bundle"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/MDirStat"
cp Packaging/Info.plist "${APP}/Contents/Info.plist"
[ -f Packaging/AppIcon.icns ] && cp Packaging/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Date de construction, lue par le panneau « A propos ». Posee sur le bundle et
# non sur Packaging/Info.plist, pour que le fichier du depot ne change pas.
BUILD_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
/usr/libexec/PlistBuddy -c "Add :MDirStatBuildDate string ${BUILD_DATE}" "${APP}/Contents/Info.plist"

echo "==> ad-hoc signing"
codesign --force --sign - --options runtime --timestamp=none "${APP}"
codesign --verify --verbose=2 "${APP}" 2>&1 | sed 's/^/    /'
echo "==> OK: $(pwd)/${APP}"
