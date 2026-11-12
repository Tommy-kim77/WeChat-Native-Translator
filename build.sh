#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -ne 2 || ! -x "$1" ]]; then
    printf '%s\n' 'Usage: bash build.sh /path/to/verified/wx /absolute/path/to/output.zip' >&2
    exit 1
fi

build_dir=$(mktemp -d /private/tmp/wechat-native-translator.XXXXXX)
app="$build_dir/WeChat Native Translator.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto --norsrc "$1" "$app/Contents/MacOS/wx"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp -R Resources/*.lproj "$app/Contents/Resources/"
xcrun swiftc -module-cache-path /private/tmp/wechat-web-translator-swift-cache \
    -target arm64-apple-macos15.0 -parse-as-library -O Sources/*.swift \
    -framework AppKit -framework SwiftUI -framework Translation -framework NaturalLanguage -framework Security \
    -o "$app/Contents/MacOS/WeChatNativeTranslator"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.local.wechat.native-translator</string>
<key>CFBundleName</key><string>WeChat Native Translator</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleExecutable</key><string>WeChatNativeTranslator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>12</string>
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
ditto --norsrc -c -k --keepParent "$app" "$2"
printf '%s\n' "$app"
