#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
project_dir=$(pwd -P)
version=0.2.7
engine=${1:-"$project_dir/Dependencies/wx"}
output=${2:-"$project_dir/Releases/WeChat-Native-Translator-v$version-macOS.zip"}
if [[ $# -gt 2 || ! -x "$engine" ]]; then
    printf '%s\n' 'Usage: bash build.sh [/path/to/verified/wx] [/absolute/path/to/output.zip]' >&2
    exit 1
fi

build_dir=$(mktemp -d /private/tmp/wechat-native-translator.XXXXXX)
display_name="WeChat Native Translator v$version"
app="$build_dir/$display_name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto --norsrc "$engine" "$app/Contents/MacOS/wx"
if ! codesign --verify --strict "$app/Contents/MacOS/wx" 2>/dev/null; then
    codesign --force --sign - "$app/Contents/MacOS/wx"
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp -R Resources/*.lproj "$app/Contents/Resources/"
xcrun swiftc -module-cache-path /private/tmp/wechat-web-translator-swift-cache \
    -target arm64-apple-macos15.0 -parse-as-library -O Sources/*.swift \
    -framework AppKit -framework SwiftUI -framework Translation -framework NaturalLanguage -framework Security \
    -o "$app/Contents/MacOS/WeChatNativeTranslator"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.local.wechat.native-translator</string>
<key>CFBundleName</key><string>WeChat Native Translator</string>
<key>CFBundleDisplayName</key><string>$display_name</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleExecutable</key><string>WeChatNativeTranslator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>18</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string><string>zh-Hans</string></array>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST

if [[ -f "$(dirname "$0")/AGENT-WECHAT-LICENSE" ]]; then
    cp AGENT-WECHAT-LICENSE "$app/Contents/Resources/"
fi
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mkdir -p "$(dirname "$output")"
ditto --norsrc -c -k --keepParent "$app" "$output"
printf '%s\n' "$app"
