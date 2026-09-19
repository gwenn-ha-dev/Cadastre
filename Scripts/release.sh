#!/bin/bash
# Build a distributable Cadastre: the app, signed and notarised when the
# credentials are there, and the bare command-line binary, both zipped into
# dist/.
#
#   CODESIGN_IDENTITY="Developer ID Application: …"   the signing identity;
#                                                     ad hoc when unset
#   NOTARY_PROFILE=cadastre                           a notarytool keychain
#                                                     profile (xcrun notarytool
#                                                     store-credentials); the
#                                                     notarisation is skipped
#                                                     when unset
#
# Without either variable this produces exactly what bundle.sh produces, in a
# zip: fine for this machine, not for someone else's — Gatekeeper wants both.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' Scripts/bundle.sh)"
DIST="$PWD/dist"
APP="$DIST/Cadastre.app"
IDENTITY="${CODESIGN_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-}"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "  bundle ${VERSION}…"
./Scripts/bundle.sh "$APP" >/dev/null

if [ -n "$IDENTITY" ]; then
  echo "  signing with $IDENTITY…"
  # Hardened runtime is what notarisation requires; the app uses no
  # entitlement beyond it.
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "  (no CODESIGN_IDENTITY: ad hoc signature, not distributable)"
fi

ZIP="$DIST/Cadastre-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$IDENTITY" ] && [ -n "$PROFILE" ]; then
  echo "  notarising…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  # The stapled ticket lives in the bundle; zip again so the archive has it.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
elif [ -n "$IDENTITY" ]; then
  echo "  (no NOTARY_PROFILE: signed but not notarised)"
fi

echo "  command-line binary…"
CLI="$DIST/cadastre-$VERSION-cli"
mkdir -p "$CLI"
cp "$APP/Contents/MacOS/cadastre" "$CLI/cadastre"
cp README.md README.fr.md "$CLI/"
tar -C "$DIST" -czf "$DIST/cadastre-$VERSION-cli.tar.gz" "$(basename "$CLI")"
rm -rf "$CLI"

echo "  → $ZIP"
echo "  → $DIST/cadastre-$VERSION-cli.tar.gz"
