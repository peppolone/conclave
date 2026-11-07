#!/bin/zsh
# Compila l'app nativa "Conclave.app" in dist/.
# Uso: npm run app            (solo build)
#      npm run app:install    (build + copia in /Applications)
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Conclave.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Pulizia"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/server"

echo "→ Compilazione Swift"
# Tutti i file Swift dell'app (render-icon.swift è uno strumento di build a parte).
SOURCES=("${(@f)$(ls "$ROOT"/macos/*.swift | grep -v render-icon.swift)}")
xcrun swiftc -O "${SOURCES[@]}" -o "$APP/Contents/MacOS/Conclave" \
  -framework AppKit

echo "→ Lingue dell'interfaccia"
# Le chiavi sono il testo italiano: it.lproj è vuoto ma dichiara l'italiano come lingua dell'app.
for lp in "$ROOT"/macos/l10n/*.lproj; do
  cp -R "$lp" "$APP/Contents/Resources/"
done

echo "→ Copia del motore"
cp -R "$ROOT/src" "$APP/Contents/Resources/server/"
cp "$ROOT/models.json" "$ROOT/.env.example" "$ROOT/package.json" "$APP/Contents/Resources/server/"

echo "→ Colore d'accento"
# AccentColor del marchio per i controlli di sistema (interruttori, pulsanti predefiniti): serve Xcode (actool).
xcrun actool "$ROOT/macos/Assets.xcassets" --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 26.0 --accent-color AccentColor \
  --output-partial-info-plist "$TMP/assets.plist" --output-format human-readable-text >/dev/null
[[ -f "$APP/Contents/Resources/Assets.car" ]] || { echo "compilazione Assets.xcassets fallita"; exit 1; }

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
  <key>CFBundleName</key><string>Conclave</string>
  <key>CFBundleDisplayName</key><string>Conclave</string>
  <key>CFBundleIdentifier</key><string>io.github.peppolone.conclave</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 peppolone — MIT License</string>
  <key>CFBundleExecutable</key><string>Conclave</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>it</string>
  <key>CFBundleLocalizations</key><array><string>it</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

echo "→ Firma locale"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

if [[ "${1:-}" == "--install" ]]; then
  echo "→ Installazione in /Applications"
  rm -rf "/Applications/Conclave.app"
  # L'app si chiamava "AI Council": la vecchia copia ripartirebbe all'accesso con una cartella dati vuota.
  rm -rf "/Applications/AI Council.app"
  cp -R "$APP" /Applications/
  echo "✓ Installata: /Applications/Conclave.app"
else
  echo "✓ Pronta: $APP"
fi
