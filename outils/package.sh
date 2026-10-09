#!/bin/bash
# Build Cadastre.app — `make package` calls this (charter §5, §12).
#
#     outils/package.sh [path/to/Cadastre.app]     default: build/Cadastre.app
#
# The bundle wraps the same binary the terminal uses: double-clicked it opens
# the map, and Cadastre.app/Contents/MacOS/cadastre is still the full CLI. A
# bundle is also what lets macOS attach Full Disk Access and the folder-access
# prompts to a stable identity rather than to whichever terminal launched it.
#
# Everything the bundle carries comes from Resources/: Info.plist (the version
# lives there), AppIcon.icns, and every .lproj — the permission prompts are
# translated in <lang>.lproj/InfoPlist.strings, so the whole folder is copied.
#
# The signature here is ad hoc, without --deep: enough to run on this machine
# and to keep a stable identity for the privacy prompts. The Developer ID
# signature, the notarization and the .dmg are `make sign` and `make dmg`
# (Charte/outils/signer.sh and dmg.sh). The app uses no entitlement beyond the
# hardened runtime, which signer.sh adds.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-$PWD/build/Cadastre.app}"

echo "  build…"
swift build -c release >/dev/null
BINARY="$(swift build -c release --show-bin-path)/cadastre"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/cadastre"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lproj in Resources/*.lproj; do
  ditto "$lproj" "$APP/Contents/Resources/$(basename "$lproj")"
done

codesign --force --sign - --timestamp=none "$APP" >/dev/null

touch "$APP"
echo "  → ${APP#"$PWD"/}"
