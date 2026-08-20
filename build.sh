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
APP="$HOME/Applications/AeroPilot.app"
BIN="$APP/Contents/MacOS/AeroPilot"

command -v swiftc >/dev/null || { echo "swiftc fehlt — Xcode Command Line Tools?"; exit 1; }

echo "▸ App läuft schon? Dann beenden"
pkill -x AeroPilot 2>/dev/null && sleep 1 || true

echo "▸ Bundle anlegen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>AeroPilot</string>
  <key>CFBundleDisplayName</key>       <string>AeroPilot</string>
  <key>CFBundleIdentifier</key>        <string>de.donald.aeropilot</string>
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
swiftc -O \
  -target arm64-apple-macos14 \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -parse-as-library \
  -o "$BIN" \
  "$HERE/AeroPilot.swift"

echo "▸ Ad-hoc signieren"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  && echo "  signiert" || echo "  warn: codesign fehlgeschlagen (App läuft meist trotzdem)"

echo "▸ Fertig: $APP"
ls -lh "$BIN" | awk '{print "  Binary:", $5}'

if [ "${1:-}" != "--no-run" ]; then
  echo "▸ Starten"
  open "$APP"
  sleep 2
  pgrep -x AeroPilot >/dev/null && echo "  läuft — Icon in der Menüleiste (geteiltes Quadrat)" \
                                || echo "  warn: nicht gestartet, siehe Console.app"
fi
