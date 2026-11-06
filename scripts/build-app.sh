#!/bin/zsh
# Compila l'app nativa "AI Council.app" in dist/.
# Uso: npm run app            (solo build)
#      npm run app:install    (build + copia in /Applications)
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/AI Council.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Pulizia"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/server"

echo "→ Compilazione Swift"
xcrun swiftc -O "$ROOT/macos/main.swift" "$ROOT/macos/Settings.swift" "$ROOT/macos/ModelsTab.swift" "$ROOT/macos/Sidebar.swift" -o "$APP/Contents/MacOS/AICouncil" \
  -framework AppKit -framework WebKit

echo "→ Copia del motore"
cp -R "$ROOT/src" "$ROOT/web" "$APP/Contents/Resources/server/"
cp "$ROOT/models.json" "$ROOT/.env.example" "$ROOT/package.json" "$APP/Contents/Resources/server/"

echo "→ Icona"
xcrun swiftc -O "$ROOT/macos/render-icon.swift" -o "$TMP/render-icon" -framework AppKit
SRC="$TMP/AppIcon.png"
"$TMP/render-icon" "$ROOT/macos/AppIcon.svg" "$SRC" 1024
[[ -f "$SRC" ]] || { echo "rendering icona fallito"; exit 1; }
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI Council</string>
  <key>CFBundleDisplayName</key><string>AI Council</string>
  <key>CFBundleIdentifier</key><string>local.peppe.aicouncil</string>
  <key>CFBundleExecutable</key><string>AICouncil</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>it</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Uso personale</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

echo "→ Firma locale"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

if [[ "${1:-}" == "--install" ]]; then
  echo "→ Installazione in /Applications"
  rm -rf "/Applications/AI Council.app"
  cp -R "$APP" /Applications/
  echo "✓ Installata: /Applications/AI Council.app"
else
  echo "✓ Pronta: $APP"
fi
