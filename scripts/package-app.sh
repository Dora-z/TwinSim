#!/bin/bash
# Assembles dist/TwinSim.app (Apple Silicon) from the frontend package in App/ and the backend
# payload produced by scripts/package-backend.sh, signs it, and builds dist/TwinSim.dmg.
#
# Environment:
#   DEVELOPER_DIR             Full Xcode used for the build (optional).
#   TWINSIM_SIGN_IDENTITY     "Developer ID Application: …" to sign for distribution. Without it the
#                             bundle is signed ad hoc for local use.
#   TWINSIM_NOTARY_PROFILE    notarytool keychain profile. With a Developer ID identity, the DMG is
#                             notarized and stapled.
#   TWINSIM_BACKEND_PAYLOAD   Backend payload directory (default .build/backend-payload).
#   TWINSIM_REBUILD_BACKEND=1 Rebuild the backend payload first.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
payload=${TWINSIM_BACKEND_PAYLOAD:-$root/.build/backend-payload}
dist=$root/dist
app=$dist/TwinSim.app
version=${TWINSIM_VERSION:-0.1.0}
build=${TWINSIM_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
identity=${TWINSIM_SIGN_IDENTITY:-}

if [[ ${TWINSIM_REBUILD_BACKEND:-0} == 1 || ! -x $payload/Contents/Helpers/twinsimd ]]; then
    bash scripts/package-backend.sh "$payload"
fi
[[ -x $payload/Contents/Helpers/twinsimd ]] || { echo "Missing backend payload at $payload" >&2; exit 1; }

echo "==> Building frontend (release, arm64)"
swift build --package-path App --configuration release --arch arm64 --product TwinSim
swift build --package-path App --configuration release --arch arm64 --product twinsimctl
bindir=$(swift build --package-path App --configuration release --arch arm64 --show-bin-path)
bin=$bindir/TwinSim

echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
install -m 755 "$bin" "$app/Contents/MacOS/TwinSim"
install -m 755 "$payload/Contents/Helpers/twinsimd" "$app/Contents/Helpers/twinsimd"
[[ -x $payload/Contents/Helpers/jidr ]] && install -m 755 "$payload/Contents/Helpers/jidr" "$app/Contents/Helpers/jidr"
# AI integration: MCP server / CLI, Claude Code skill and agent instructions.
install -m 755 "$bindir/twinsimctl" "$app/Contents/Helpers/twinsim"
mkdir -p "$app/Contents/Resources/AI"
cp -R ai/skills "$app/Contents/Resources/AI/skills"
install -m 644 ai/AGENTS.md "$app/Contents/Resources/AI/AGENTS.md"
cp -R "$payload/Contents/Resources/BackendNotices" "$app/Contents/Resources/BackendNotices"
printf 'APPL????' > "$app/Contents/PkgInfo"

iconset=$(mktemp -d "${TMPDIR:-/tmp}/twinsim-icon.XXXXXX")/AppIcon.iconset
swift scripts/make-icon.swift "$iconset"
iconutil --convert icns --output "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -rf "$(dirname "$iconset")"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>TwinSim</string>
    <key>CFBundleExecutable</key><string>TwinSim</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.twinsim.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>TwinSim</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>TwinSim. Third-party notices in Contents/Resources/BackendNotices.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Android Package</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.android.package-archive</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>iOS App Archive</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.apple.itunes.ipa</string></array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.android.package-archive</string>
            <key>UTTypeDescription</key><string>Android Package</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.zip-archive</string></array>
            <key>UTTypeTagSpecification</key><dict>
                <key>public.filename-extension</key><array><string>apk</string></array>
                <key>public.mime-type</key><array><string>application/vnd.android.package-archive</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>com.apple.itunes.ipa</string>
            <key>UTTypeDescription</key><string>iOS App Archive</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.zip-archive</string></array>
            <key>UTTypeTagSpecification</key><dict>
                <key>public.filename-extension</key><array><string>ipa</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

echo "==> Signing"
if [[ -n $identity ]]; then
    sign=(codesign --force --options runtime --timestamp --sign "$identity")
else
    sign=(codesign --force --options runtime --sign -)
fi
for helper in "$app/Contents/Helpers/"*; do
    "${sign[@]}" "$helper"
done
"${sign[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

echo "==> Building DMG"
staging=$(mktemp -d "${TMPDIR:-/tmp}/twinsim-dmg.XXXXXX")
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dist/TwinSim.dmg"
hdiutil create -quiet -volname TwinSim -srcfolder "$staging" -fs APFS -format UDZO "$dist/TwinSim.dmg"
rm -rf "$staging"

if [[ -n $identity ]]; then
    codesign --force --timestamp --sign "$identity" "$dist/TwinSim.dmg"
    if [[ -n ${TWINSIM_NOTARY_PROFILE:-} ]]; then
        echo "==> Notarizing"
        xcrun notarytool submit "$dist/TwinSim.dmg" --keychain-profile "$TWINSIM_NOTARY_PROFILE" --wait
        xcrun stapler staple "$dist/TwinSim.dmg"
        xcrun stapler staple "$app"
        spctl --assess --type execute --verbose "$app"
    else
        echo "Signed with Developer ID; set TWINSIM_NOTARY_PROFILE to notarize." >&2
    fi
else
    echo "Signed ad hoc for local use (no Developer ID identity). Gatekeeper will not accept it on other Macs." >&2
fi

codesign -dv "$app" 2>&1 | grep -E 'Identifier|Signature|Runtime|flags' || true
echo "$app"
echo "$dist/TwinSim.dmg"
