#!/bin/zsh
# Compila l'app nativa "Conclave.app" in dist/.
# Uso: npm run app            (solo build)
#      npm run app:install    (build + copia in /Applications)
# Variabili per le versioni distribuite (vedi .github/workflows/release.yml):
#   ARCHS="arm64 x86_64" architetture dell'eseguibile, più di una = app universale
#                       (predefinita: quella di questo Mac)
#   VERSION=1.2.3       versione dell'app (predefinita: quella di package.json)
#   NODE_BIN=<file>      binario di Node da includere, con le stesse architetture (scripts/fetch-node.sh)
#   SIGNING_P12=<file>   certificato di firma del progetto (predefinito ~/.config/conclave/signing.p12)
#   SIGNING_P12_PASSWORD password del .p12 (predefinita: ~/.config/conclave/signing.pass)
#                       Senza certificato la firma è ad-hoc (in CI è un errore, salvo ALLOW_ADHOC=1).
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

# Firma con il certificato autofirmato del progetto: l'identità resta la stessa tra le versioni,
# così il Portachiavi riconosce l'app aggiornata e non chiede la password (con la firma ad-hoc
# cambierebbe a ogni build). Il certificato sta in un portachiavi temporaneo, mai in quello di login.
SIGNING_P12="${SIGNING_P12:-$HOME/.config/conclave/signing.p12}"
if [[ -z "${SIGNING_P12_PASSWORD:-}" && -f "$HOME/.config/conclave/signing.pass" ]]; then
  SIGNING_P12_PASSWORD="$(<"$HOME/.config/conclave/signing.pass")"
fi
if [[ -f "$SIGNING_P12" && -n "${SIGNING_P12_PASSWORD:-}" ]]; then
  echo "→ Firma (certificato del progetto)"
  KC="$TMP/signing.keychain-db"
  KCPASS="$(openssl rand -hex 16)"
  # Una riga per portachiavi, tra virgolette e rientrata: si tolgono solo rientro e virgolette.
  OLD_KCS=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')}")
  trap 'security list-keychains -d user -s "${OLD_KCS[@]}"; rm -rf "$TMP"' EXIT
  security create-keychain -p "$KCPASS" "$KC"
  security set-keychain-settings "$KC"
  security unlock-keychain -p "$KCPASS" "$KC"
  security import "$SIGNING_P12" -k "$KC" -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
  security list-keychains -d user -s "$KC" "${OLD_KCS[@]}"
  # Il certificato non è "fidato" per il sistema: codesign lo accetta indicandolo per impronta.
  CERT_SHA1="$(security find-certificate -a -Z "$KC" | awk '/SHA-1/ {print $3; exit}')"
  [[ -f "$APP/Contents/MacOS/node" ]] && codesign --force --sign "$CERT_SHA1" --keychain "$KC" "$APP/Contents/MacOS/node"
  codesign --force --sign "$CERT_SHA1" --keychain "$KC" "$APP"
  codesign -d -r- "$APP" 2>&1 | grep -q "certificate root" || { echo "Firma senza certificato del progetto"; exit 1; }
else
  echo "→ Firma ad-hoc (certificato del progetto assente: il Portachiavi chiederà la password dopo ogni build)"
  # In CI una build da distribuire senza certificato è un errore; le PR (senza secrets) lo dichiarano.
  if [[ -n "${CI:-}" && -z "${ALLOW_ADHOC:-}" ]]; then
    echo "In CI serve il certificato (secrets SIGNING_P12_BASE64/SIGNING_P12_PASSWORD) o ALLOW_ADHOC=1"; exit 1
  fi
  codesign --force --deep --sign - "$APP"
fi

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
