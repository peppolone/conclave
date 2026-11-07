#!/bin/zsh
# Crea un DMG con l'app e il collegamento ad Applicazioni (trascina per installare).
# Uso: scripts/make-dmg.sh <percorso/Conclave.app> <file .dmg>
set -euo pipefail

APP="$1"
OUT="$2"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Conclave" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
echo "✓ DMG: $OUT"
