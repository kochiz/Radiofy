#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo "dev")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist 2>/dev/null || echo "0")
TAG="v${VER}"
ARCHIVE_DIR="../releases"
ARCHIVE_NAME="Radiofy-${VER}-b${BUILD}.app"

rm -rf Radiofy.app
mkdir -p Radiofy.app/Contents/MacOS Radiofy.app/Contents/Resources/ui
clang -arch x86_64 -fobjc-arc -O2 -mmacosx-version-min=10.15 -Wall -framework Cocoa -framework WebKit main.m -o Radiofy.app/Contents/MacOS/Radiofy
cp ui/* Radiofy.app/Contents/Resources/ui/
if [[ -f AppIcon.icns ]]; then
  cp AppIcon.icns Radiofy.app/Contents/Resources/AppIcon.icns
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Radiofy" Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName Radiofy" Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Radiofy" Info.plist 2>/dev/null || true
cp Info.plist Radiofy.app/Contents/Info.plist
xattr -cr Radiofy.app
codesign --force --deep --sign - Radiofy.app
codesign -v Radiofy.app && echo signed
file Radiofy.app/Contents/MacOS/Radiofy

# Archivo por versión (no pisa releases anteriores)
mkdir -p "$ARCHIVE_DIR"
rm -rf "${ARCHIVE_DIR}/${ARCHIVE_NAME}"
cp -R Radiofy.app "${ARCHIVE_DIR}/${ARCHIVE_NAME}"
echo "archived ${ARCHIVE_DIR}/${ARCHIVE_NAME} (${TAG})"
echo "TIP: git tag ${TAG} && git commit por esta versión antes de seguir"
