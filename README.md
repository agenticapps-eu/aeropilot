# AeroPilot

Eine Menüleisten-App für [AeroSpace](https://github.com/nikitabobko/AeroSpace).
Eine einzige Swift-Datei, gebaut mit `swiftc` — kein Xcode-Projekt, keine
Abhängigkeiten.

> **English:** A macOS menu bar companion for the AeroSpace tiling window
> manager: live window list with float/tile toggles, workspace assignment,
> a validating config editor with automatic rollback, and a runner for your
> own layout scripts. Single Swift file, no Xcode project, no dependencies.
> The interface and code comments are in German.

## Was sie tut

**Fenster** — alle offenen Fenster, nach Workspace gruppiert. Pro Zeile ein
Klick, um zwischen *gekachelt* und *floatend* zu wechseln, und ein Dropdown,
um das Fenster in einen anderen Workspace zu schieben. Optional zeigt jede
Zeile die Bundle-ID zum Kopieren — praktisch, wenn man gerade eine
`on-window-detected`-Regel schreibt und nicht raten will.

**Workspaces** — Übersicht mit Monitor und Fensterzahl, Klick springt hin,
`flatten` + `balance-sizes` pro Workspace.

**Config** — `aerospace.toml` im Editor. *Prüfen* validiert, ohne anzuwenden.
*Speichern + anwenden* legt eine Sicherung an, validiert, und **rollt bei
einem Fehler automatisch zurück**. Das ist der Punkt, an dem die App mehr
kann als ein Texteditor: `aerospace reload-config --dry-run` liefert auch bei
Fehlern Exit-Code 0, man muss die Ausgabe lesen. Genau das passiert hier.

**Aktionen** — deine eigenen Skripte (siehe unten) plus Config-Reload und
`enable off`/`on` als Notbremse.

**App** — Autostart, Anzeigeoptionen, Aufräumen der Config-Sicherungen, Pfade.

Die App hält **keinen eigenen Zustand**. Bei jedem Öffnen wird frisch aus
`aerospace … --json` gelesen, sie kann also nicht aus dem Tritt kommen, wenn
man parallel mit Hotkeys arbeitet.

## Bauen

```bash
./build.sh            # baut nach ~/Applications/AeroPilot.app und startet
./build.sh --no-run   # nur bauen
```

Voraussetzungen: macOS 14+, Xcode Command Line Tools (`swiftc`), AeroSpace
0.21+ unter `/opt/homebrew/bin/aerospace` oder `/usr/local/bin/aerospace`.

`build.sh` legt das App-Bundle von Hand an (`LSUIElement`, damit kein
Dock-Icon erscheint) und signiert ad-hoc — ohne Signatur beanstandet macOS
jeden Start.

## Eigene Skripte einbinden

Der Bereich *Aktionen* listet ausführbare Skripte aus
`~/.config/aerospace/env/`. Ein Skript meldet sich selbst an, indem es in den
ersten Zeilen Kopfzeilen trägt:

```bash
#!/usr/bin/env bash
# @group: Aufbauen          # optional, sonst „Skripte"
# @label: Alles aufbauen    # Pflicht — ohne @label taucht es nicht auf
# @key:   alt-ctrl-a        # optional, nur Anzeige
```

Ohne `@label` bleibt eine Datei unsichtbar, sodass Hilfsdateien wie `_lib.sh`
aussen vor bleiben. Trägt kein einziges Skript Kopfzeilen, werden ersatzweise
alle `.sh`-Dateien mit ihrem Dateinamen gelistet.

Eine passende Skriptsammlung liegt in
[agenticapps-eu/aerospace-setup](https://github.com/agenticapps-eu/aerospace-setup).

## Autostart

Der Schalter im Bereich *App* versucht zuerst den Apple-Weg
(`SMAppService`, erscheint in *Systemeinstellungen → Anmeldeobjekte`). Wenn
das scheitert — die ad-hoc-Signatur genügt nicht überall —, fällt die App auf
einen LaunchAgent in `~/Library/LaunchAgents` zurück und sagt es. Ausschalten
räumt beide Wege ab, sonst startet die App womöglich zweimal.

Nach einem Rebuild kann macOS den Eintrag als geändert einstufen und
deaktivieren; dann einmal im Bereich *App* nachschauen.

## Grenzen

- Legt **keine** `on-window-detected`-Regeln per Klick an. Das hiesse
  TOML generieren, und generiertes TOML zerstört Kommentare. Regeln
  schreibt man im Editor.
- Mitteilungen laufen über `osascript`, nicht über `UserNotifications` —
  dieses Framework verlangt eine ordentlich signierte App.
- Nur getestet auf Apple Silicon, macOS 26.

## Lizenz

MIT
