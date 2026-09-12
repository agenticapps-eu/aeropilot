#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# AeroPilot bauen — eine Swift-Datei → fertige .app
#
#   ./build.sh          baut nach ~/Applications/AeroPilot.app und startet
#   ./build.sh --no-run nur bauen
#
# Kein Xcode-Projekt nötig: swiftc kompiliert die einzelne Datei, drumherum
# wird ein minimales App-Bundle von Hand gebaut. Wichtig ist LSUIElement=1
# in der Info.plist — sonst hätte die App ein Dock-Icon, und MenuBarExtra
# will genau das nicht.
#
# Ad-hoc-Signatur (codesign -s -) statt unsigniert: sonst meckert macOS
# bei jedem Start. Für eine lokal gebaute App reicht das.
# ══════════════════════════════════════════════════════════════════════
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Applications/AeroPilot.app"
mkdir -p "$HOME/Applications"
STAGE="$(mktemp -d "$HOME/Applications/.aeropilot-build.XXXXXX")"
APP="$STAGE/AeroPilot.app"
BIN="$APP/Contents/MacOS/AeroPilot"
BACKUP="$HOME/Applications/AeroPilot.previous.app"
swapped=0
recover() {
  code=$?
  if [ "$code" -ne 0 ] && [ "$swapped" -eq 1 ]; then
    rm -rf "$DEST"
    if [ -d "$BACKUP" ]; then mv "$BACKUP" "$DEST"; open "$DEST" || true; fi
  fi
  rm -rf "$STAGE"
  exit "$code"
}
trap recover EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>AeroPilot</string>
  <key>CFBundleDisplayName</key>       <string>AeroPilot</string>
  <key>CFBundleIdentifier</key>        <string>de.donald.aeropilot2</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key>        <string>AeroPilot</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <!-- Menüleisten-App ohne Dock-Icon -->
  <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

echo "▸ Kompilieren"
xcrun swiftc -O \
  -target arm64-apple-macos14 \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -parse-as-library \
  -o "$BIN" \
  "$HERE/AeroPilot.swift"

echo "▸ Ad-hoc signieren"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"

if [ "${1:-}" = "--build-only" ]; then
  mkdir -p "$HERE/build"
  rm -rf "$HERE/build/AeroPilot.app"
  mv "$APP" "$HERE/build/AeroPilot.app"
  echo "Build geprüft: $HERE/build/AeroPilot.app (laufende App unverändert)"
  exit 0
fi

# Compilation and signature validation completed before touching the running app.
pkill -x AeroPilot 2>/dev/null || true
for _ in {1..30}; do
  pgrep -x AeroPilot >/dev/null || break
  sleep 0.1
done
if pgrep -x AeroPilot >/dev/null; then
  echo "AeroPilot läuft noch; Installation abgebrochen." >&2
  exit 1
fi
rm -rf "$BACKUP"
if [ -d "$DEST" ]; then mv "$DEST" "$BACKUP"; fi
swapped=1
mv "$APP" "$DEST"
if [ "${1:-}" != "--no-run" ]; then
  open "$DEST"
  sleep 2
  pgrep -x AeroPilot >/dev/null || { echo "Start fehlgeschlagen — vorherige App wiederherstellen." >&2; exit 1; }
fi
swapped=0
echo "Installiert und geprüft: $DEST"
