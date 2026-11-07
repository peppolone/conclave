#!/bin/zsh
# Scarica il binario ufficiale di Node 24 (ultima versione) per l'architettura indicata,
# verificandolo con SHASUMS256.txt di nodejs.org. Serve alle versioni distribuite (DMG).
# Uso: scripts/fetch-node.sh arm64|x86_64|universal <file di destinazione>
set -euo pipefail

ARCH="$1"
OUT="$2"
case "$ARCH" in
  arm64) NODE_ARCHS=(arm64) ;;
  x86_64) NODE_ARCHS=(x64) ;;
  universal) NODE_ARCHS=(arm64 x64) ;;
  *) echo "architettura non valida: $ARCH"; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VERSION="${NODE_VERSION:-$(curl -fsSL https://nodejs.org/dist/index.json | node -e '
  let d = ""; process.stdin.on("data", c => d += c).on("end", () =>
    console.log(JSON.parse(d).find(r => r.version.startsWith("v24.")).version))')}"
curl -fsSL "https://nodejs.org/dist/$VERSION/SHASUMS256.txt" -o "$TMP/SHASUMS256.txt"

BINS=()
for NODE_ARCH in "${NODE_ARCHS[@]}"; do
  NAME="node-$VERSION-darwin-$NODE_ARCH"
  echo "→ Node $VERSION ($NODE_ARCH)"
  curl -fsSL "https://nodejs.org/dist/$VERSION/$NAME.tar.gz" -o "$TMP/$NAME.tar.gz"
  (cd "$TMP" && grep " $NAME.tar.gz\$" SHASUMS256.txt | shasum -a 256 -c - >/dev/null) \
    || { echo "checksum di $NAME.tar.gz non valido"; exit 1; }
  tar -xzf "$TMP/$NAME.tar.gz" -C "$TMP" "$NAME/bin/node"
  BINS+=("$TMP/$NAME/bin/node")
done
mkdir -p "${OUT:h}"
lipo -create "${BINS[@]}" -output "$OUT"
chmod 755 "$OUT"
