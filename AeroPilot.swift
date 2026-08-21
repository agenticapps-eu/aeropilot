// ══════════════════════════════════════════════════════════════════════
//  AeroPilot — Menüleisten-App für AeroSpace
//
//  Fünf Bereiche:
//    Fenster     alle Fenster live, float/tile umschalten, Workspace ändern
//    Workspaces  Übersicht mit Monitor, direkt hinspringen
//    Config      aerospace.toml bearbeiten, prüfen, speichern + neu laden
//    Aktionen    die env-Skripte und AeroSpace-Kommandos
//    App         Einstellungen der App selbst (Autostart, Anzeige, Backups)
//
//  Kein Xcode-Projekt: eine Datei, gebaut mit swiftc, gebündelt als
//  .app mit LSUIElement (kein Dock-Icon). Siehe build.sh.
//
//  Alles läuft über die aerospace-CLI mit --json. Die App hält keinen
//  eigenen Zustand — bei jedem Öffnen wird frisch gelesen. Damit kann sie
//  nicht aus dem Tritt kommen, wenn du parallel Hotkeys benutzt.
// ══════════════════════════════════════════════════════════════════════

import SwiftUI
import ServiceManagement
import CoreGraphics

// ── Einstellungen ─────────────────────────────────────────────────────
// Schlüssel an einer Stelle, damit Views und Model sich nicht widersprechen.
// Das Model ist eine Klasse und kann kein @AppStorage benutzen — es liest
// dieselben Schlüssel direkt aus UserDefaults.

enum Pref {
    static let startTab        = "startTab"
    static let showTitles      = "showTitles"
    static let showBundleIds   = "showBundleIds"
    static let hideEmptyWs     = "hideEmptyWorkspaces"
    static let panelHeight     = "panelHeight"
    static let notify          = "notifyOnAction"
    static let keepBackups     = "keepBackups"
    static let checkOrphans    = "checkOrphans"
    static let ignoredApps     = "ignoredApps"
    static let checkMisplaced  = "checkMisplaced"

    /// Erstwerte. UserDefaults liefert für unbekannte Schlüssel 0/false —
    /// deshalb müssen sinnvolle Vorgaben registriert werden, sonst startet
    /// die App mit Höhe 0 und ohne Fenstertitel.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            startTab: 0,
            showTitles: true,
            showBundleIds: false,
            hideEmptyWs: false,
            panelHeight: 380.0,
            notify: false,
            keepBackups: 10,
            checkOrphans: true,
            ignoredApps: [String](),
            checkMisplaced: true,
        ])
    }
}

// ── Autostart ─────────────────────────────────────────────────────────
// Zwei Wege, weil der schöne nicht immer funktioniert:
//
//  1. SMAppService (Apple-Weg) — die App erscheint in den Systemeinstellungen
//     unter „Anmeldeobjekte“. Braucht eine gültige Signatur; bei einer
//     ad-hoc signierten, selbst gebauten App kann `register()` scheitern
//     oder auf `requiresApproval` stehen bleiben.
//  2. LaunchAgent — eine plist in ~/Library/LaunchAgents, von launchd
//     geladen. Funktioniert ohne Signatur, taucht aber nicht in den
//     Systemeinstellungen auf.
//
// Beim Einschalten wird 1 versucht und bei Fehler automatisch auf 2
// zurückgefallen. Ausschalten räumt beides ab — sonst startet die App
// womöglich zweimal.

enum Autostart {
    enum Mode: String { case off, loginItem, launchAgent }

    static let label = "de.donald.aeropilot"
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    static var mode: Mode {
        if FileManager.default.fileExists(atPath: plistPath) { return .launchAgent }
        return SMAppService.mainApp.status == .enabled ? .loginItem : .off
    }

    /// `.requiresApproval` heisst: registriert, aber vom Nutzer in den
    /// Systemeinstellungen deaktiviert. Kein Fehler, aber auch kein Autostart.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func enable() -> String {
        do {
            try SMAppService.mainApp.register()
            if needsApproval {
                return "Registriert, aber noch nicht freigegeben — " +
                       "in den Systemeinstellungen einschalten."
            }
            return "Autostart über Anmeldeobjekte aktiv."
        } catch {
            let r = installLaunchAgent()
            return "Anmeldeobjekt fehlgeschlagen (\(error.localizedDescription)) — " +
                   "LaunchAgent stattdessen: \(r)"
        }
    }

    static func disable() -> String {
        var parts: [String] = []
        do { try SMAppService.mainApp.unregister() ; parts.append("Anmeldeobjekt entfernt") }
        catch { /* war nie registriert — nichts zu melden */ }
        if FileManager.default.fileExists(atPath: plistPath) {
            Aero.shell("/bin/launchctl bootout gui/$(id -u)/\(label) 2>/dev/null; " +
                       "rm -f '\(plistPath)'")
            parts.append("LaunchAgent entfernt")
        }
        return parts.isEmpty ? "Autostart war nicht aktiv." : parts.joined(separator: ", ") + "."
    }

    private static func installLaunchAgent() -> String {
        guard let exe = Bundle.main.executablePath else { return "Pfad unbekannt" }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(exe)</string></array>
          <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        do { try plist.write(toFile: plistPath, atomically: true, encoding: .utf8) }
        catch { return "plist nicht schreibbar" }
        let r = Aero.shell("/bin/launchctl bootstrap gui/$(id -u) '\(plistPath)'")
        return r.code == 0 ? "geladen" : "plist liegt, launchctl meldet: \(r.err)"
    }

    /// Direkt zum Anmeldeobjekte-Bereich der Systemeinstellungen.
    static func openSystemSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
    }
}

// ── CLI-Anbindung ─────────────────────────────────────────────────────

enum Aero {
    /// Erst PATH-Kandidaten durchprobieren. Eine .app erbt NICHT die
    /// Shell-Umgebung, deshalb reicht "aerospace" allein nicht.
    static let binary: String = {
        for p in ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/opt/homebrew/bin/aerospace"
    }()

    @discardableResult
    static func run(_ args: [String]) -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return ("", "Start fehlgeschlagen: \(error)", -1) }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: od, as: UTF8.self),
                String(decoding: ed, as: UTF8.self),
                p.terminationStatus)
    }

    @discardableResult
    static func shell(_ path: String) -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", path]
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return ("", "\(error)", -1) }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: od, as: UTF8.self),
                String(decoding: ed, as: UTF8.self),
                p.terminationStatus)
    }
}

// ── Datenmodell ───────────────────────────────────────────────────────

struct Win: Identifiable, Decodable {
    let windowId: Int
    let workspace: String
    let windowLayout: String
    let appName: String
    let appBundleId: String
    let windowTitle: String
    let monitorName: String
    let appPid: Int

    var id: Int { windowId }
    var isFloating: Bool { windowLayout == "floating" }

    enum CodingKeys: String, CodingKey {
        case windowId = "window-id"
        case workspace
        case windowLayout = "window-layout"
        case appName = "app-name"
        case appBundleId = "app-bundle-id"
        case windowTitle = "window-title"
        case monitorName = "monitor-name"
        case appPid = "app-pid"
    }
}

/// Eine App, die sichtbare Fenster auf dem Bildschirm hat, von denen
/// AeroSpace keines kennt.
///
/// WOZU: AeroSpace verliert gelegentlich ein Fenster — beobachtet am
/// 20.08.2026 bei Readwise Reader. Die Folge ist tückisch, weil sie nicht
/// nach einem Fehler aussieht: das Fenster bleibt liegen, wo es zuletzt
/// war, und weil AeroSpace fremde Workspaces durch Wegschieben ausblendet,
/// wandert ein Fenster, das es nicht kennt, eben nie weg. Es klebt über
/// allem. Gleichzeitig zieht sich der verbliebene Nachbar auf die volle
/// Spaltenbreite, weil er allein im Container steht.
///
/// Erkannt wird das durch Abgleich zweier Quellen: die Fensterliste von
/// macOS selbst (CoreGraphics) gegen die von AeroSpace, verglichen über
/// die Prozess-ID.
struct Orphan: Identifiable {
    let pid: pid_t
    let name: String
    let count: Int
    let bundleURL: URL?
    var id: pid_t { pid }
}

/// Ein Fenster, das nicht auf dem Workspace liegt, den env/layout.conf
/// vorsieht.
///
/// WOZU: `on-window-detected` greift nur, wenn ein Fenster erscheint —
/// nie rückwirkend. Ändert man eine Regel oder nummeriert Workspaces um,
/// bleibt jedes offene Fenster liegen, wo es war. Am 20.08.2026 lagen so
/// sieben Fenster einen Tag lang auf ihren alten Nummern, während die
/// Config längst stimmte. Von aussen sah es aus, als sei eine App
/// weggerutscht — dabei war sie die einzige, die richtig lag.
struct Misplaced: Identifiable {
    let windowId: Int
    let appName: String
    let title: String
    let current: String
    let target: String
    var id: Int { windowId }
}

/// Eine Zeile aus env/layout.conf: Bundle-ID, Ziel-Workspace, optionales
/// Titelmuster. Reihenfolge ist bedeutungstragend — erste Übereinstimmung
/// gewinnt, wie bei on-window-detected.
struct LayoutRule {
    let bundleId: String
    let workspace: String      // "-" heisst: nicht zuordnen
    let titlePattern: String?
}

/// Ein Skript aus dem env-Verzeichnis, das sich per Kopfzeile angemeldet hat.
struct Script: Identifiable {
    let file: String
    let label: String
    let group: String
    let key: String?
    var id: String { file }
}

struct Ws: Identifiable, Decodable {
    let workspace: String
    let monitorName: String
    var id: String { workspace }
    enum CodingKeys: String, CodingKey {
        case workspace
        case monitorName = "monitor-name"
    }
}

// ── Zustand ───────────────────────────────────────────────────────────

@MainActor
final class Model: ObservableObject {
    @Published var windows: [Win] = []
    @Published var workspaces: [Ws] = []
    @Published var focused: String = ""
    @Published var version: String = ""
    @Published var status: String = ""
    @Published var statusIsError = false
    @Published var scripts: [Script] = []
    @Published var orphans: [Orphan] = []
    @Published var misplaced: [Misplaced] = []

    let configPath = NSHomeDirectory() + "/.config/aerospace/aerospace.toml"
    let envDir     = NSHomeDirectory() + "/.config/aerospace/env"

    func refresh() {
        let fields = "%{window-id}%{workspace}%{window-layout}%{app-name}" +
                     "%{app-bundle-id}%{window-title}%{monitor-name}%{app-pid}"
        let w = Aero.run(["list-windows", "--monitor", "all", "--json", "--format", fields])
        windows = (try? JSONDecoder().decode([Win].self,
                    from: Data(w.out.utf8)))?.sorted {
            ($0.workspace, $0.appName) < ($1.workspace, $1.appName)
        } ?? []

        let s = Aero.run(["list-workspaces", "--monitor", "all", "--json",
                          "--format", "%{workspace}%{monitor-name}"])
        workspaces = (try? JSONDecoder().decode([Ws].self, from: Data(s.out.utf8))) ?? []

        focused = Aero.run(["list-workspaces", "--focused"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if version.isEmpty {
            version = Aero.run(["--version"]).out
                .split(separator: "\n").first.map(String.init) ?? "?"
        }
        loadScripts()
        findOrphans()
        findMisplaced()
    }

    // ── Soll-Ist-Abgleich ─────────────────────────────────────────────

    /// Liest env/layout.conf — dieselbe Datei, die auch relayout.sh liest.
    /// Bewusst dieselbe: zwei Listen laufen auseinander, eine nicht.
    func layoutRules() -> [LayoutRule] {
        guard let text = try? String(contentsOfFile: envDir + "/layout.conf",
                                     encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { raw in
            let line = raw.split(separator: "#", maxSplits: 1,
                                 omittingEmptySubsequences: false)[0]
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            // Ein führendes `+` markiert Apps, die build-all.sh öffnet —
            // für die Zuordnung selbst spielt es keine Rolle.
            let bundle = parts[0].hasPrefix("+")
                ? String(parts[0].dropFirst()) : parts[0]
            return LayoutRule(bundleId: bundle, workspace: parts[1],
                              titlePattern: parts.count > 2
                                  ? parts[2...].joined(separator: " ") : nil)
        }
    }

    func findMisplaced() {
        guard UserDefaults.standard.bool(forKey: Pref.checkMisplaced) else {
            misplaced = []; return
        }
        let rules = layoutRules()
        guard !rules.isEmpty else { misplaced = []; return }

        misplaced = windows.compactMap { w in
            for r in rules where r.bundleId == w.appBundleId {
                if let p = r.titlePattern,
                   w.windowTitle.range(of: p, options: .regularExpression) == nil {
                    continue          // spezifischere Regel passt nicht — weitersuchen
                }
                guard r.workspace != "-", r.workspace != w.workspace else { return nil }
                return Misplaced(windowId: w.windowId, appName: w.appName,
                                 title: w.windowTitle, current: w.workspace,
                                 target: r.workspace)
            }
            return nil                // keine Regel für diese App
        }
    }

    /// Nur die abweichenden Fenster verschieben — kein flatten, kein
    /// balance. Wer das komplette Aufräumen will, nimmt relayout.sh.
    func fixMisplaced() {
        let todo = misplaced
        for m in todo {
            Aero.run(["move-node-to-workspace", "--window-id",
                      String(m.windowId), m.target])
        }
        say("\(todo.count) Fenster einsortiert.")
        refresh()
    }

    // ── Unverwaltete Fenster ──────────────────────────────────────────

    /// Vergleicht die Fensterliste von macOS mit der von AeroSpace.
    ///
    /// Die Filter sind da, um Fehlalarme zu vermeiden, nicht um vollständig
    /// zu sein — lieber eine Meldung zu wenig als eine falsche:
    ///   • nur Ebene 0: schliesst Menüleisten-Overlays, Tooltips und
    ///     Schnellstarter wie Raycast oder Alfred aus, die über allem liegen
    ///   • nur sichtbare Fenster: Fenster auf anderen macOS-Spaces und in
    ///     nativem Vollbild zählen nicht, die verwaltet AeroSpace ohnehin nie
    ///   • Mindestgrösse: Schatten, Hilfsfenster und Fortschrittsbalken raus
    ///   • eigene PID raus: das Popover dieser App ist selbst ein Fenster
    func findOrphans() {
        guard UserDefaults.standard.bool(forKey: Pref.checkOrphans) else {
            orphans = []; return
        }
        let ignored = Set(UserDefaults.standard.stringArray(forKey: Pref.ignoredApps) ?? [])
        let known = Set(windows.map { pid_t($0.appPid) })
        let mine = ProcessInfo.processInfo.processIdentifier

        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []

        var counts: [pid_t: Int] = [:]
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  pid != mine, !known.contains(pid),
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let width = b["Width"] as? Double, let height = b["Height"] as? Double,
                  width >= 300, height >= 200
            else { continue }
            counts[pid, default: 0] += 1
        }

        orphans = counts.compactMap { pid, n in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let name = app.localizedName,
                  !ignored.contains(name),
                  app.activationPolicy == .regular   // Hintergrunddienste raus
            else { return nil }
            return Orphan(pid: pid, name: name, count: n, bundleURL: app.bundleURL)
        }
        .sorted { $0.name < $1.name }
    }

    func ignore(_ o: Orphan) {
        var list = UserDefaults.standard.stringArray(forKey: Pref.ignoredApps) ?? []
        if !list.contains(o.name) { list.append(o.name) }
        UserDefaults.standard.set(list, forKey: Pref.ignoredApps)
        say("\(o.name) wird nicht mehr gemeldet.")
        findOrphans()
    }

    /// Beenden und neu öffnen. Das ist die einzige verlässliche Art, AeroSpace
    /// ein verlorenes Fenster zurückzugeben: es gibt kein Kommando, das die
    /// Fenstererfassung neu anstösst — nur ein neu erscheinendes Fenster wird
    /// erfasst.
    func restart(_ o: Orphan) {
        guard let app = NSRunningApplication(processIdentifier: o.pid),
              let url = o.bundleURL else {
            say("Kein App-Bundle zu \(o.name) gefunden.", error: true); return
        }
        say("\(o.name) wird neu gestartet …")
        app.terminate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !app.isTerminated {
                app.forceTerminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let cfg = NSWorkspace.OpenConfiguration()
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.refresh()
            self.say(self.orphans.contains { $0.name == o.name }
                     ? "\(o.name) neu gestartet, wird aber weiterhin nicht verwaltet."
                     : "\(o.name) neu gestartet und wieder verwaltet. Layout ggf. richten.")
        }
    }

    func say(_ text: String, error: Bool = false) {
        status = text; statusIsError = error
        guard UserDefaults.standard.bool(forKey: Pref.notify), !text.isEmpty else { return }
        // osascript statt UserNotifications: das Framework verlangt eine
        // richtig signierte App mit Bundle-Registrierung, ad-hoc genügt nicht.
        let one = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .prefix(180)
        Aero.shell("/usr/bin/osascript -e 'display notification \"\(one)\" " +
                   "with title \"AeroPilot\"'")
    }

    // ── Fensteraktionen ───────────────────────────────────────────────

    func toggleFloat(_ w: Win) {
        // `layout floating` / `layout tiling` setzt absolut, nicht toggelnd —
        // deshalb explizit je Richtung, sonst flippt es unkontrolliert.
        let target = w.isFloating ? "tiling" : "floating"
        let r = Aero.run(["layout", "--window-id", String(w.windowId), target])
        say(r.code == 0 ? "\(w.appName) → \(target)" : r.err, error: r.code != 0)
        refresh()
    }

    func move(_ w: Win, to ws: String) {
        let r = Aero.run(["move-node-to-workspace", "--window-id",
                          String(w.windowId), ws])
        say(r.code == 0 ? "\(w.appName) → Workspace \(ws)" : r.err, error: r.code != 0)
        refresh()
    }

    func focus(workspace: String) {
        Aero.run(["workspace", workspace])
        say("Workspace \(workspace)")
        refresh()
    }

    func balance(_ ws: String) {
        Aero.run(["flatten-workspace-tree", "--workspace", ws])
        Aero.run(["balance-sizes", "--workspace", ws])
        say("Workspace \(ws) gleichmässig verteilt")
        refresh()
    }

    // ── Config ────────────────────────────────────────────────────────

    func loadConfig() -> String {
        (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
    }

    /// Prüft die Config OHNE sie anzuwenden. Wichtig: `--dry-run` gibt auch
    /// bei Fehlern Exit-Code 0 zurück — man MUSS die Ausgabe lesen.
    func validate() -> (ok: Bool, message: String) {
        let r = Aero.run(["reload-config", "--dry-run"])
        let text = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return (true, "Keine Fehler, keine Warnungen.") }
        return (!text.contains("[ERROR]"), text)
    }

    /// Speichert und lädt neu. Vorher wird die alte Fassung weggesichert,
    /// und bei Fehlern in der neuen Config wird zurückgerollt.
    func saveAndReload(_ text: String) {
        let backup = configPath + ".autosave-" + Self.stamp()
        let previous = loadConfig()
        try? previous.write(toFile: backup, atomically: true, encoding: .utf8)

        do { try text.write(toFile: configPath, atomically: true, encoding: .utf8) }
        catch { say("Schreiben fehlgeschlagen: \(error)", error: true); return }

        let v = validate()
        if !v.ok {
            try? previous.write(toFile: configPath, atomically: true, encoding: .utf8)
            say("Fehler — zurückgerollt:\n" + v.message, error: true)
            return
        }
        let r = Aero.run(["reload-config"])
        let err = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        pruneBackups()
        say(err.isEmpty ? "Gespeichert und neu geladen. Backup: \(backup)"
                        : err,
            error: err.contains("[ERROR]"))
        refresh()
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // ── Backups ───────────────────────────────────────────────────────
    // Jedes Speichern legt eine Sicherung an. Ohne Aufräumen wächst
    // ~/.config/aerospace endlos zu.

    var backups: [String] {
        let dir = (configPath as NSString).deletingLastPathComponent
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return all.filter { $0.hasPrefix("aerospace.toml.autosave-") }
                  .sorted(by: >)                      // Zeitstempel sortiert sich lexikalisch
                  .map { dir + "/" + $0 }
    }

    /// Behält die neuesten `keepBackups` Sicherungen. 0 = alle behalten.
    @discardableResult
    func pruneBackups() -> Int {
        let keep = UserDefaults.standard.integer(forKey: Pref.keepBackups)
        guard keep > 0 else { return 0 }
        let doomed = backups.dropFirst(keep)
        for f in doomed { try? FileManager.default.removeItem(atPath: f) }
        return doomed.count
    }

    // ── Skripte ───────────────────────────────────────────────────────

    func runScript(_ name: String) {
        let r = Aero.shell("'\(envDir)/\(name)'")
        let out = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        say(out.isEmpty ? "\(name) durchgelaufen" : out, error: r.code != 0)
        refresh()
    }

    /// Die Skriptliste ist nicht einprogrammiert, sondern wird aus dem
    /// env-Verzeichnis gelesen. Ein Skript meldet sich selbst an, indem es
    /// in den ersten Zeilen Kopfzeilen trägt:
    ///
    ///     # @label: Alles aufbauen
    ///     # @group: Aufbauen        (optional, sonst „Skripte")
    ///     # @key:   alt-ctrl-a      (optional, nur Anzeige)
    ///
    /// Ohne `@label` taucht ein Skript nicht auf — so bleiben Hilfsdateien
    /// wie _lib.sh aussen vor. Trägt kein einziges Skript Kopfzeilen, werden
    /// ersatzweise alle .sh-Dateien mit ihrem Dateinamen gelistet.
    func loadScripts() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: envDir)) ?? [])
            .filter { $0.hasSuffix(".sh") }.sorted()

        var found: [Script] = []
        for f in files {
            guard let body = try? String(contentsOfFile: envDir + "/" + f, encoding: .utf8)
            else { continue }
            var label: String?, group = "Skripte", key: String?
            for line in body.split(separator: "\n", maxSplits: 24, omittingEmptySubsequences: false) {
                func value(_ tag: String) -> String? {
                    guard let r = line.range(of: "# @\(tag):") else { return nil }
                    return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                }
                if let v = value("label") { label = v }
                if let v = value("group") { group = v }
                if let v = value("key")   { key = v }
            }
            if let label { found.append(Script(file: f, label: label, group: group, key: key)) }
        }
        if found.isEmpty {
            found = files.filter { !$0.hasPrefix("_") }
                .map { Script(file: $0, label: $0, group: "Skripte", key: nil) }
        }
        scripts = found
    }

    /// Gruppen in der Reihenfolge ihres ersten Auftretens — alphabetisch
    /// sortieren würde „Aufbauen" hinter „AeroSpace" schieben und die
    /// gedachte Reihenfolge zerstören.
    var scriptGroups: [(String, [Script])] {
        var order: [String] = []
        for s in scripts where !order.contains(s.group) { order.append(s.group) }
        return order.map { g in (g, scripts.filter { $0.group == g }) }
    }
}

// ── Oberfläche ────────────────────────────────────────────────────────

struct RootView: View {
    @StateObject var m = Model()
    @State private var tab = 0
    @AppStorage(Pref.startTab)    private var startTab = 0
    @AppStorage(Pref.panelHeight) private var panelHeight = 380.0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Fenster").tag(0)
                Text("Workspaces").tag(1)
                Text("Config").tag(2)
                Text("Aktionen").tag(3)
                Text("App").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider()

            Group {
                switch tab {
                case 0: WindowsView(m: m)
                case 1: WorkspacesView(m: m)
                case 2: ConfigView(m: m)
                case 3: ActionsView(m: m)
                default: SettingsView(m: m)
                }
            }
            .frame(height: panelHeight)

            Divider()
            StatusBar(m: m)
        }
        .frame(width: 560)
        .onAppear { tab = startTab; m.refresh() }
    }
}

struct WindowsView: View {
    @ObservedObject var m: Model

    var grouped: [(String, [Win])] {
        Dictionary(grouping: m.windows, by: \.workspace)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !m.orphans.isEmpty { OrphanBanner(m: m) }
                if !m.misplaced.isEmpty { MisplacedBanner(m: m) }
                ForEach(grouped, id: \.0) { ws, wins in
                    HStack(spacing: 6) {
                        Text("Workspace \(ws)").font(.caption).bold()
                        if ws == m.focused {
                            Text("aktiv").font(.caption2)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Button("ausgleichen") { m.balance(ws) }
                            .buttonStyle(.link).font(.caption2)
                    }
                    .padding(.horizontal, 10).padding(.top, 8)

                    ForEach(wins) { w in WindowRow(m: m, w: w) }
                }
            }
            .padding(.bottom, 8)
        }
    }
}

/// Warnung über der Fensterliste. Bewusst kein Dialog: sie soll auffallen,
/// wenn man ohnehin hinschaut, und nicht die Arbeit unterbrechen.
struct OrphanBanner: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("AeroSpace verwaltet diese Fenster nicht")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Sie bleiben beim Workspace-Wechsel liegen und überlagern alles. "
                 + "Ein Neustart der App gibt AeroSpace das Fenster zurück.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(m.orphans) { o in
                HStack(spacing: 8) {
                    Text(o.name).font(.system(size: 12, weight: .medium))
                    Text(o.count == 1 ? "1 Fenster" : "\(o.count) Fenster")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("neu starten") { m.restart(o) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("ignorieren") { m.ignore(o) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10).padding(.top, 8)
    }
}

/// Hinweis auf Fenster, die nicht dort liegen, wo env/layout.conf sie
/// vorsieht. Blau statt orange: kein Defekt, nur Unordnung.
struct MisplacedBanner: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right.square")
                    .foregroundStyle(.blue)
                Text("Fenster auf dem falschen Workspace")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("alle einsortieren") { m.fixMisplaced() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Text("Regeln greifen nur, wenn ein Fenster erscheint — nie rückwirkend. "
                 + "Soll-Zustand steht in env/layout.conf.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(m.misplaced) { p in
                HStack(spacing: 8) {
                    Text(p.appName).font(.system(size: 12, weight: .medium))
                    Text("\(p.current) → \(p.target)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.blue)
                    Text(p.title).font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10).padding(.top, 8)
    }
}

struct WindowRow: View {
    @ObservedObject var m: Model
    let w: Win
    @AppStorage(Pref.showTitles)    private var showTitles = true
    @AppStorage(Pref.showBundleIds) private var showBundleIds = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                m.toggleFloat(w)
            } label: {
                Image(systemName: w.isFloating
                      ? "rectangle.dashed" : "rectangle.split.3x1")
                    .foregroundStyle(w.isFloating ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(w.isFloating ? "floatend — klicken für gekachelt"
                               : "gekachelt — klicken für floatend")

            VStack(alignment: .leading, spacing: 0) {
                Text(w.appName).font(.system(size: 12, weight: .medium))
                if showTitles {
                    Text(w.windowTitle).font(.system(size: 10))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                if showBundleIds {
                    Text(w.appBundleId)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer()

            Picker("", selection: Binding(
                get: { w.workspace },
                set: { if $0 != w.workspace { m.move(w, to: $0) } })) {
                ForEach(m.workspaces) { ws in Text(ws.workspace).tag(ws.workspace) }
            }
            .labelsHidden().frame(width: 58)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
    }
}

struct WorkspacesView: View {
    @ObservedObject var m: Model
    @AppStorage(Pref.hideEmptyWs) private var hideEmpty = false

    var shown: [Ws] {
        hideEmpty
            ? m.workspaces.filter { ws in m.windows.contains { $0.workspace == ws.workspace } }
            : m.workspaces
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shown) { ws in
                    let n = m.windows.filter { $0.workspace == ws.workspace }.count
                    HStack {
                        Button("Workspace \(ws.workspace)") {
                            m.focus(workspace: ws.workspace)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12,
                              weight: ws.workspace == m.focused ? .bold : .regular))
                        Text(ws.monitorName).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(n) Fenster").font(.caption).foregroundStyle(.secondary)
                        Button("ausgleichen") { m.balance(ws.workspace) }
                            .buttonStyle(.link).font(.caption2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    Divider()
                }
            }
            .padding(.top, 8)
        }
    }
}

struct ConfigView: View {
    @ObservedObject var m: Model
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
                .padding(.horizontal, 8)

            HStack {
                Button("Neu laden aus Datei") { text = m.loadConfig() }
                Button("Prüfen") {
                    let v = m.validate()
                    m.say(v.message, error: !v.ok)
                }
                Spacer()
                Button("Speichern + anwenden") { m.saveAndReload(text) }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
        }
        .onAppear { if !loaded { text = m.loadConfig(); loaded = true } }
    }
}

struct ActionsView: View {
    @ObservedObject var m: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(m.scriptGroups, id: \.0) { group, scripts in
                    section(group) {
                        ForEach(scripts) { s in
                            row(s.label, s.key) { m.runScript(s.file) }
                        }
                    }
                }
                if m.scripts.isEmpty {
                    Text("Keine Skripte in \(m.envDir)")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                section("AeroSpace") {
                    row("Config neu laden", nil) {
                        let r = Aero.run(["reload-config"])
                        let t = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                        m.say(t.isEmpty ? "Config neu geladen" : t,
                              error: t.contains("[ERROR]"))
                    }
                    row("Tiling AUS (Notbremse)", nil) {
                        Aero.run(["enable", "off"]); m.say("Tiling aus")
                    }
                    row("Tiling EIN", nil) {
                        Aero.run(["enable", "on"]); m.say("Tiling ein"); m.refresh()
                    }
                }
                Text(m.version).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            .padding(.vertical, 10)
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).bold()
                .foregroundStyle(.secondary).padding(.horizontal, 12)
            c()
        }
    }

    func row(_ label: String, _ key: String?, _ action: @escaping () -> Void) -> some View {
        HStack {
            Button(label, action: action).buttonStyle(.link).font(.system(size: 12))
            Spacer()
            if let key { Text(key).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 1)
    }
}

// ── Einstellungen der App selbst ──────────────────────────────────────

struct SettingsView: View {
    @ObservedObject var m: Model

    @AppStorage(Pref.startTab)      private var startTab = 0
    @AppStorage(Pref.showTitles)    private var showTitles = true
    @AppStorage(Pref.showBundleIds) private var showBundleIds = false
    @AppStorage(Pref.hideEmptyWs)   private var hideEmpty = false
    @AppStorage(Pref.panelHeight)   private var panelHeight = 380.0
    @AppStorage(Pref.notify)        private var notify = false
    @AppStorage(Pref.keepBackups)   private var keepBackups = 10
    @AppStorage(Pref.checkOrphans)  private var checkOrphans = true
    @AppStorage(Pref.checkMisplaced) private var checkMisplaced = true

    /// @AppStorage kann kein [String] — deshalb beim Öffnen aus den
    /// UserDefaults nachladen.
    @State private var ignoredApps: [String] = []

    /// Autostart lebt nicht in UserDefaults, sondern im System. Deshalb bei
    /// jedem Öffnen frisch abfragen statt einen Schalterzustand zu speichern —
    /// sonst zeigt die App „ein“, während launchd nichts davon weiss.
    @State private var mode = Autostart.mode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                group("Start") {
                    Toggle("Beim Anmelden starten", isOn: Binding(
                        get: { mode != .off },
                        set: { on in
                            m.say(on ? Autostart.enable() : Autostart.disable())
                            mode = Autostart.mode
                        }))
                    HStack(spacing: 6) {
                        Text(modeText).font(.caption).foregroundStyle(.secondary)
                        if mode == .loginItem || Autostart.needsApproval {
                            Button("Systemeinstellungen") { Autostart.openSystemSettings() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                    Picker("Beim Öffnen zeigen", selection: $startTab) {
                        Text("Fenster").tag(0);     Text("Workspaces").tag(1)
                        Text("Config").tag(2);      Text("Aktionen").tag(3)
                        Text("App").tag(4)
                    }
                    .frame(width: 300)
                }

                group("Anzeige") {
                    Toggle("Fenstertitel anzeigen", isOn: $showTitles)
                    Toggle("Bundle-ID anzeigen (zum Kopieren für Config-Regeln)",
                           isOn: $showBundleIds)
                    Toggle("Leere Workspaces ausblenden", isOn: $hideEmpty)
                    HStack {
                        Text("Höhe").font(.system(size: 12))
                        Slider(value: $panelHeight, in: 260...620, step: 20)
                            .frame(width: 200)
                        Text("\(Int(panelHeight)) px")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                group("Rückmeldung") {
                    Toggle("Meldungen auch als macOS-Mitteilung", isOn: $notify)
                    Text("Nützlich, wenn ein Skript läuft und das Popover zuklappt.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                group("Ordnung") {
                    Toggle("Melden, wenn ein Fenster vom Soll-Workspace abweicht",
                           isOn: $checkMisplaced)
                    Text("Soll-Zustand: \(m.envDir)/layout.conf — dieselbe Datei, "
                         + "die auch relayout.sh liest. \(m.layoutRules().count) Regeln geladen.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("Unverwaltete Fenster") {
                    Toggle("Melden, wenn AeroSpace ein sichtbares Fenster nicht kennt",
                           isOn: $checkOrphans)
                    Text("Verglichen wird die Fensterliste von macOS mit der von "
                         + "AeroSpace. Gemeldet wird nur, was sichtbar, gross genug "
                         + "und auf der normalen Fensterebene liegt.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !ignoredApps.isEmpty {
                        HStack(spacing: 8) {
                            Text("ignoriert: " + ignoredApps.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Button("zurücksetzen") {
                                UserDefaults.standard.set([String](), forKey: Pref.ignoredApps)
                                ignoredApps = []
                                m.findOrphans()
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                    }
                }

                group("Config-Backups") {
                    HStack {
                        Text("Sicherungen behalten").font(.system(size: 12))
                        Stepper(value: $keepBackups, in: 0...50) {
                            Text(keepBackups == 0 ? "alle" : "\(keepBackups)")
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .frame(width: 110)
                    }
                    HStack(spacing: 8) {
                        Text("aktuell \(m.backups.count) Dateien")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("jetzt aufräumen") {
                            let n = m.pruneBackups()
                            m.say(n == 0 ? "Nichts zu löschen." : "\(n) Sicherungen gelöscht.")
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }

                group("Pfade") {
                    path("CLI", Aero.binary)
                    path("Config", m.configPath)
                    path("Skripte", m.envDir)
                    path("App", Bundle.main.bundlePath)
                    Text(m.version).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .onAppear {
            mode = Autostart.mode
            ignoredApps = UserDefaults.standard.stringArray(forKey: Pref.ignoredApps) ?? []
        }
    }

    var modeText: String {
        switch mode {
        case .off:         return "nicht eingerichtet"
        case .loginItem:   return Autostart.needsApproval
                                  ? "als Anmeldeobjekt registriert, aber deaktiviert"
                                  : "als Anmeldeobjekt aktiv"
        case .launchAgent: return "über LaunchAgent aktiv (nicht in den Systemeinstellungen sichtbar)"
        }
    }

    func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            c()
        }
    }

    func path(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 11)).frame(width: 52, alignment: .leading)
            Text(value).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(1).truncationMode(.head)
        }
    }
}

struct StatusBar: View {
    @ObservedObject var m: Model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !m.status.isEmpty {
                Text(m.status)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(m.statusIsError ? .red : .secondary)
                    .lineLimit(4).textSelection(.enabled)
            } else {
                HStack(spacing: 6) {
                    Text("\(m.windows.count) Fenster · \(m.workspaces.count) Workspaces")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    // Auch sichtbar, wenn man gerade in einem anderen Bereich ist
                    if !m.orphans.isEmpty {
                        Label("\(m.orphans.count) unverwaltet",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    if !m.misplaced.isEmpty {
                        Label("\(m.misplaced.count) falsch einsortiert",
                              systemImage: "arrow.left.arrow.right.square")
                            .font(.system(size: 10)).foregroundStyle(.blue)
                    }
                }
            }
            Spacer()
            Button { m.refresh(); m.say("") } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            Button("Beenden") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link).font(.system(size: 10))
        }
        .padding(8)
    }
}

// ── App ───────────────────────────────────────────────────────────────

@main
struct AeroPilotApp: App {
    init() { Pref.registerDefaults() }

    var body: some Scene {
        MenuBarExtra {
            RootView()
        } label: {
            Image(systemName: "square.split.2x2")
        }
        .menuBarExtraStyle(.window)
    }
}
