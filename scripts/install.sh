#!/bin/zsh
# Compila, instala em /Applications e garante que o macOS use só essa cópia do widget
# (o Xcode registra a cópia de build/ como widget também, e o sistema pode escolher ela).
set -euo pipefail
cd "$(dirname "$0")/.."

LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUILT="$PWD/build/Build/Products/Release/Disco.app"

xcodegen generate >/dev/null
xcodebuild -project Disco.xcodeproj -scheme Disco -configuration Release -derivedDataPath build build | grep -E "error|BUILD" || true

pkill -x Disco || true
pkill -f DiscoWidgetExtension || true
rm -rf /Applications/Disco.app
cp -R "$BUILT" /Applications/

pluginkit -r "$BUILT/Contents/PlugIns/DiscoWidgetExtension.appex" 2>/dev/null || true
"$LS" -u "$BUILT"
"$LS" -f /Applications/Disco.app
pluginkit -a /Applications/Disco.app/Contents/PlugIns/DiscoWidgetExtension.appex

open /Applications/Disco.app
