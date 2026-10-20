#!/bin/bash
# Builds Proof.app from the Swift package, ad-hoc signed and ready to run locally.
#
#   Scripts/build-app.sh            # build/Proof.app
#   Scripts/build-app.sh --dist     # plus a .dmg and .zip for a release
#
# The version comes from Sources/ProofCore/AppVersion.swift so the bundle, the
# update check and the release tag cannot drift apart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Proof"
BUNDLE_ID="com.taufanzamzami.compilerpro"   # unchanged: keeps the user's settings and recents
VERSION="$(sed -n 's/.*static let fallback = "\(.*\)".*/\1/p' Sources/ProofCore/AppVersion.swift | head -1)"

if [ -z "$VERSION" ]; then
    echo "error: could not read the version from Sources/ProofCore/AppVersion.swift" >&2
    exit 1
fi

DIST=0
[ "${1:-}" = "--dist" ] && DIST=1

BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"

echo "Building $APP_NAME $VERSION (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN" ]; then
    echo "error: no executable at $BIN" >&2
    exit 1
fi
RESOURCES="$(dirname "$BIN")/${APP_NAME}_${APP_NAME}.bundle"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp -R "$RESOURCES" "$APP/Contents/Resources/"
cp "$ROOT/Sources/$APP_NAME/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>LaTeX document</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Default</string>
			<key>CFBundleTypeExtensions</key>
			<array><string>tex</string><string>ltx</string></array>
		</dict>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Markdown document</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Default</string>
			<key>CFBundleTypeExtensions</key>
			<array><string>md</string><string>markdown</string></array>
		</dict>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Mermaid diagram</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Default</string>
			<key>CFBundleTypeExtensions</key>
			<array><string>mmd</string><string>mermaid</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

# Ad-hoc: the app runs locally and keeps its resources sealed. Replace with a
# Developer ID identity before distributing to other machines.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$DIST" = "1" ]; then
    rm -rf "$BUILD/dmg"
    mkdir -p "$BUILD/dmg"
    cp -R "$APP" "$BUILD/dmg/"
    ln -s /Applications "$BUILD/dmg/Applications"

    DMG="$BUILD/$APP_NAME-$VERSION.dmg"
    rm -f "$DMG"
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$BUILD/dmg" -ov -format UDZO "$DMG"

    ZIP="$BUILD/$APP_NAME-$VERSION-macos-arm64.zip"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    echo "Wrote $DMG"
    echo "Wrote $ZIP"
fi
