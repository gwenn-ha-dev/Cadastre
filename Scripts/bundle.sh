#!/bin/bash
# Build Cadastre.app.
#
# The bundle wraps the same binary the terminal uses: double-clicked it opens
# the map, and Cadastre.app/Contents/MacOS/cadastre is still the full CLI. A
# bundle is also what lets macOS attach Full Disk Access and the folder-access
# prompts to a stable identity rather than to whichever terminal launched it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-$PWD/Cadastre.app}"
VERSION="0.2"

echo "  build…"
swift build -c release >/dev/null
BINARY="$PWD/.build/release/cadastre"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/fr.lproj"
cp "$BINARY" "$APP/Contents/MacOS/cadastre"

echo "  icon…"
ICONSET="$(mktemp -d)/Cadastre.iconset"
"$BINARY" --make-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Cadastre.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>Cadastre</string>
  <key>CFBundleDisplayName</key>           <string>Cadastre</string>
  <key>CFBundleIdentifier</key>            <string>local.cadastre</string>
  <key>CFBundleExecutable</key>            <string>cadastre</string>
  <key>CFBundleIconFile</key>              <string>Cadastre</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
  <key>CFBundleVersion</key>               <string>2</string>
  <key>CFBundleDevelopmentRegion</key>     <string>en</string>
  <key>CFBundleLocalizations</key>         <array><string>en</string><string>fr</string></array>
  <key>LSMinimumSystemVersion</key>        <string>14.0</string>
  <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>NSHumanReadableCopyright</key>      <string>Cadastre</string>

  <!-- Folders can be dropped on the Dock icon and opened with "Open With". -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>          <string>Folder</string>
      <key>CFBundleTypeRole</key>          <string>Viewer</string>
      <key>LSHandlerRank</key>             <string>None</string>
      <key>LSItemContentTypes</key>        <array><string>public.folder</string></array>
    </dict>
  </array>

  <!-- Shown in the permission prompts. Without them macOS asks with no reason
       given, or refuses outright. The wording is localised in InfoPlist.strings. -->
  <key>NSDesktopFolderUsageDescription</key>
  <string>To measure the space taken by the Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>To measure the space taken by your documents.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>To measure the space taken by your downloads.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>To measure the space taken on an external volume.</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
NSDesktopFolderUsageDescription = "To measure the space taken by the Desktop.";
NSDocumentsFolderUsageDescription = "To measure the space taken by your documents.";
NSDownloadsFolderUsageDescription = "To measure the space taken by your downloads.";
NSRemovableVolumesUsageDescription = "To measure the space taken on an external volume.";
STRINGS

cat > "$APP/Contents/Resources/fr.lproj/InfoPlist.strings" <<'STRINGS'
NSDesktopFolderUsageDescription = "Pour mesurer l'espace occupé par le bureau.";
NSDocumentsFolderUsageDescription = "Pour mesurer l'espace occupé par les documents.";
NSDownloadsFolderUsageDescription = "Pour mesurer l'espace occupé par les téléchargements.";
NSRemovableVolumesUsageDescription = "Pour mesurer l'espace occupé sur un volume externe.";
STRINGS

# Ad-hoc signature: enough for the app to run on this machine and to keep a
# stable identity for the privacy prompts. Not a distributable signature.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "  (ad-hoc signature failed — the app will still run)"

touch "$APP"
echo "  → $APP"
echo "     double-click for the map, or $APP/Contents/MacOS/cadastre on the command line"
