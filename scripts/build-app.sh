#!/bin/zsh
# Compila l'app nativa "Conclave.app" in dist/.
# Uso: npm run app            (solo build)
#      npm run app:install    (build + copia in /Applications)
# Variabili per le versioni distribuite (vedi .github/workflows/release.yml):
#   ARCHS="arm64 x86_64" architetture dell'eseguibile, più di una = app universale
#                       (predefinita: quella di questo Mac)
#   VERSION=1.2.3       versione dell'app (predefinita: quella di package.json)
#   NODE_BIN=<file>      binario di Node da includere, con le stesse architetture (scripts/fetch-node.sh)
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Conclave.app"
ARCHS=(${=ARCHS:-$(uname -m)})
VERSION="${VERSION:-$(node -p 'require(process.argv[1]).version' "$ROOT/package.json")}"
BUILD="${BUILD_NUMBER:-1}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Pulizia"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/server"

echo "→ Compilazione Swift (${ARCHS[*]})"
# Tutti i file Swift dell'app.
SOURCES=("${(@f)$(ls "$ROOT"/macos/*.swift)}")
SLICES=()
for a in "${ARCHS[@]}"; do
  xcrun swiftc -O -target "$a-apple-macos26.0" "${SOURCES[@]}" -o "$TMP/Conclave-$a" -framework AppKit
  SLICES+=("$TMP/Conclave-$a")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Conclave"

if [[ -n "${NODE_BIN:-}" ]]; then
  echo "→ Node incluso"
  cp "$NODE_BIN" "$APP/Contents/MacOS/node"
  for a in "${ARCHS[@]}"; do
    [[ " $(lipo -archs "$APP/Contents/MacOS/node") " == *" $a "* ]] || { echo "Node senza $a"; exit 1; }
  done
fi

echo "→ Lingue dell'interfaccia"
# Le chiavi sono il testo italiano: it.lproj è vuoto ma dichiara l'italiano come lingua dell'app.
for lp in "$ROOT"/macos/l10n/*.lproj; do
  cp -R "$lp" "$APP/Contents/Resources/"
done

echo "→ Copia del motore"
cp -R "$ROOT/src" "$APP/Contents/Resources/server/"
cp "$ROOT/models.json" "$ROOT/.env.example" "$ROOT/package.json" "$APP/Contents/Resources/server/"

echo "→ Icona e colore d'accento"
# Icona nel formato di macOS 26 (AppIcon.icon, Icon Composer): il sistema aggiunge vetro, riflessi e
# le varianti scura e tinta. actool la compila in Assets.car insieme all'AccentColor del marchio
# (interruttori, pulsanti predefiniti) e produce AppIcon.icns per chi legge solo CFBundleIconFile.
xcrun actool "$ROOT/macos/AppIcon.icon" "$ROOT/macos/Assets.xcassets" --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon --accent-color AccentColor \
  --output-partial-info-plist "$TMP/assets.plist" --output-format human-readable-text >/dev/null
[[ -f "$APP/Contents/Resources/Assets.car" && -f "$APP/Contents/Resources/AppIcon.icns" ]] \
  || { echo "compilazione di icona e Assets.xcassets fallita"; exit 1; }

echo "→ Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
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
codesign --force --deep --sign - "$APP"

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
