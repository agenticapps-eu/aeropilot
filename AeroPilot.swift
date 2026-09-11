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
    static let relayoutAfterRestart = "relayoutAfterRestart"
    static let watch           = "watchInBackground"
    static let watchInterval   = "watchIntervalSeconds"

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
            relayoutAfterRestart: true,
            watch: true,
            watchInterval: 60,
        ])
    }
}

// ── Autostart ─────────────────────────────────────────────────────────
// Nur noch LaunchAgent. Das war früher der Notnagel; seit dem 28.08.2026
// ist es der einzige Weg.
//
// **Warum SMAppService rausgeflogen ist.** Apples Weg trägt die App in die
// Background-Task-Datenbank ein. Wird eine App währenddessen hart beendet —
// etwa durch ein `pkill` mitten im Start —, bleibt dort ein kaputter Eintrag
// zurück, der die Bundle-ID *dauerhaft* blockiert: Die App startet, launchd
// meldet „Successfully spawned“, und eine Sekunde später ist sie wieder weg.
// Das überlebt Neubauen, Neusignieren, `lsregister -u` und einen Pfadwechsel.
// Genau das ist AeroPilot am 27.08.2026 passiert; nur die neue Kennung
// `de.donald.aeropilot2` hat geholfen.
//
// Ein LaunchAgent ist dagegen eine Datei. Man kann sie anlegen, ansehen und
// löschen, und niemand muss raten, was das System sich gemerkt hat.
//
// **Und warum `open -a` statt des Binaries direkt:** Eine Menubar-App, die
// nicht über LaunchServices gestartet wird, beendet sich sofort wieder —
// ihr fehlt der GUI-Kontext. Der alte Notnagel trug den Binärpfad ein und
// hätte deshalb vermutlich nie funktioniert. `open` nimmt den richtigen Weg.
//
// Preis: Der Eintrag steht in den Systemeinstellungen unter „Anmeldeobjekte
// & Erweiterungen“ im unteren Abschnitt, nicht als schöner App-Eintrag oben.
// Dafür funktioniert er.

enum Autostart {
    enum Mode: String { case off, launchAgent }

    static let label = "de.donald.aeropilot2"
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    /// Die Kennung von früher. Wird beim Ein- und Ausschalten mit abgeräumt,
    /// damit nicht eine vergessene plist die App ein zweites Mal startet.
    private static let altesLabel = "de.donald.aeropilot"
    private static var alterPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(altesLabel).plist"
    }

    static var mode: Mode {
        FileManager.default.fileExists(atPath: plistPath) ? .launchAgent : .off
    }

    /// Bleibt bestehen, damit die Oberfläche unverändert baut — bei einem
    /// LaunchAgent gibt es aber nichts freizugeben.
    static var needsApproval: Bool { false }

    static func enable() -> String {
        let app = Bundle.main.bundleURL.path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>-a</string>
            <string>\(app)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
        </dict>
        </plist>
        """
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        do { try plist.write(toFile: plistPath, atomically: true, encoding: .utf8) }
        catch { return "plist nicht schreibbar — Autostart nicht aktiv." }
        raeumeAltesAuf()
        let r = Aero.shell("/bin/launchctl bootout gui/$(id -u)/\(label) 2>/dev/null; " +
                           "/bin/launchctl bootstrap gui/$(id -u) '\(plistPath)'")
        return r.code == 0
            ? "Autostart aktiv (LaunchAgent)."
            : "plist liegt, launchctl meldet: \(r.err)"
    }

    static func disable() -> String {
        var teile: [String] = []
        if FileManager.default.fileExists(atPath: plistPath) {
            Aero.shell("/bin/launchctl bootout gui/$(id -u)/\(label) 2>/dev/null; " +
                       "rm -f '\(plistPath)'")
            teile.append("LaunchAgent entfernt")
        }
        if FileManager.default.fileExists(atPath: alterPlistPath) {
            raeumeAltesAuf()
            teile.append("alte plist mit entfernt")
        }
        // Falls aus einer früheren Version noch eine SMAppService-Registrierung
        // herumliegt: einmal still abmelden.
        try? SMAppService.mainApp.unregister()
        return teile.isEmpty ? "Autostart war nicht aktiv." : teile.joined(separator: ", ") + "."
    }

    private static func raeumeAltesAuf() {
        guard FileManager.default.fileExists(atPath: alterPlistPath) else { return }
        Aero.shell("/bin/launchctl bootout gui/$(id -u)/\(altesLabel) 2>/dev/null; " +
                   "rm -f '\(alterPlistPath)'")
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
    /// Ein einziges Model, früh erzeugt. Nicht aus Bequemlichkeit: mit
    /// `.menuBarExtraStyle(.window)` baut SwiftUI die Ansicht erst beim
    /// ersten Öffnen des Popovers. Läge das Model dort als @StateObject,
    /// liefe die Hintergrundprüfung erst, nachdem man einmal hingeschaut
    /// hat — also genau dann nicht, wenn sie gebraucht wird.
    static let shared = Model()

    @Published var windows: [Win] = []
    @Published var workspaces: [Ws] = []
    @Published var focused: String = ""
    @Published var version: String = ""
    @Published var status: String = ""
    @Published var statusIsError = false
    @Published var scripts: [Script] = []
    @Published var orphans: [Orphan] = []
    @Published var misplaced: [Misplaced] = []
    /// Bundle-IDs mit dauerhafter Float-Regel. Bei jedem refresh() frisch
    /// aus der Config gelesen — die Datei ist die Wahrheit, nicht die App.
    @Published var floats: Set<String> = []

    let configPath = NSHomeDirectory() + "/.config/aerospace/aerospace.toml"
    let envDir     = NSHomeDirectory() + "/.config/aerospace/env"

    // ── Hintergrundprüfung ────────────────────────────────────────────
    // Ein verlorenes Fenster meldet sich nicht. Man merkt es erst, wenn
    // es beim Workspace-Wechsel liegenbleibt — oft Stunden später. Also
    // regelmässig nachsehen und einmal Bescheid geben.
    private var watchTimer: Timer?
    private var announced: Set<pid_t> = []

    func startWatch() {
        watchTimer?.invalidate(); watchTimer = nil
        guard UserDefaults.standard.bool(forKey: Pref.watch) else { return }
        // 60 s ist ein Kompromiss: die Prüfung kostet ein paar CLI-Aufrufe,
        // und schneller als „innerhalb einer Minute" muss die Meldung nicht
        // sein — der Schaden entsteht erst beim nächsten Workspace-Wechsel.
        // Über den Schlüssel watchIntervalSeconds änderbar, auch um beim
        // Nachprüfen nicht minutenlang warten zu müssen:
        //   defaults write de.donald.aeropilot watchIntervalSeconds -int 5
        let secs = max(2.0, UserDefaults.standard.double(forKey: Pref.watchInterval))
        watchTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: true) { _ in
            Task { @MainActor in Model.shared.watchTick() }
        }
        refresh()
        announced = Set(orphans.map(\.pid))   // beim Start nicht nachträglich meckern
        watchTicks = 0
    }

    /// Zähler, damit von aussen prüfbar ist, ob der Timer wirklich läuft.
    private(set) var watchTicks = 0

    private func watchTick() {
        watchTicks += 1
        UserDefaults.standard.set(watchTicks, forKey: "watchTicks")
        refresh()
        let now = Set(orphans.map(\.pid))
        let fresh = orphans.filter { !announced.contains($0.pid) }
        announced = now                       // auch Verschwundene vergessen
        guard !fresh.isEmpty else { return }
        let names = fresh.map(\.name).joined(separator: ", ")
        Aero.shell("/usr/bin/osascript -e 'display notification " +
                   "\"\(names) — AeroSpace verwaltet das Fenster nicht mehr\" " +
                   "with title \"AeroPilot\"'")
    }

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
        floats = persistentFloats()
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
            if self.orphans.contains(where: { $0.name == o.name }) {
                self.say("\(o.name) neu gestartet, wird aber weiterhin nicht verwaltet.")
                return
            }
            // Das neue Fenster hängt sich neben das zuletzt benutzte Fenster
            // in dessen Container — nicht dorthin, wo das alte lag. Nach dem
            // Neustart von Readwise Reader stand es deshalb als vierte
            // Spalte neben Raindrop statt mit ihr in einer geteilten. Ohne
            // Nacharbeit ist ein Neustart also immer eine halbe Reparatur.
            if UserDefaults.standard.bool(forKey: Pref.relayoutAfterRestart) {
                self.say("\(o.name) neu gestartet — Layout wird gerichtet …")
                self.runScript("relayout.sh")
            } else {
                self.say("\(o.name) neu gestartet und wieder verwaltet. Layout ggf. richten.")
            }
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

    // ── Dauerhaft floaten ─────────────────────────────────────────────
    //
    // `aerospace layout floating` gilt nur für das laufende Fenster. Beim
    // nächsten Start der App ist das Fenster ein neues und wird wieder
    // gekachelt — es gibt in AeroSpace keinen Zustand, der das überdauert.
    // Dauerhaft wird es nur durch eine Regel in `on-window-detected`.
    //
    // Deshalb verwaltet die App einen abgegrenzten Block in der
    // aerospace.toml. Nicht die ganze Datei neu schreiben: der Rest ist
    // handgeschrieben und voller Kommentare, die eine Neuerzeugung
    // vernichten würde. Nur der Bereich zwischen den beiden Markierungen
    // gehört der App.

    static let floatBegin = "# ╔═ AeroPilot ═══ automatisch verwaltet ═══"
    static let floatEnd   = "# ╚═ Ende AeroPilot ═══════════════════════"

    /// Bundle-IDs, für die eine dauerhafte Float-Regel existiert.
    func persistentFloats() -> Set<String> {
        let lines = loadConfig().split(separator: "\n", omittingEmptySubsequences: false)
        guard let from = lines.firstIndex(where: { $0.contains(Self.floatBegin) }),
              let to = lines.firstIndex(where: { $0.contains(Self.floatEnd) }), from < to
        else { return [] }
        var out = Set<String>()
        for line in lines[from...to] {
            guard let r = line.range(of: "app-bundle-id} = ") else { continue }
            let rest = line[r.upperBound...]
            let id = rest.prefix { !$0.isWhitespace && $0 != "'" && $0 != "," }
            if !id.isEmpty { out.insert(String(id)) }
        }
        return out
    }

    func setPersistentFloat(_ bundleId: String, _ on: Bool) {
        var ids = persistentFloats()
        if on { ids.insert(bundleId) } else { ids.remove(bundleId) }

        var lines = loadConfig().split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // alten Block entfernen
        if let from = lines.firstIndex(where: { $0.contains(Self.floatBegin) }),
           let to = lines.firstIndex(where: { $0.contains(Self.floatEnd) }), from <= to {
            lines.removeSubrange(from...to)
        }

        if !ids.isEmpty {
            guard let anchor = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("on-window-detected = [")
            }) else {
                say("`on-window-detected = [` nicht gefunden — nichts geändert.", error: true)
                return
            }
            var block = [
                "  " + Self.floatBegin,
                "  # In AeroPilot gesetzt: Fenster dieser Apps floaten immer.",
                "  # Von Hand hier nichts ändern — die App ersetzt den Block ganz.",
                "  #",
                "  # check-further-callbacks: floaten UND die Regeln darunter",
                "  # weiterhin durchlaufen. Ohne das gewönne diese Regel als erste",
                "  # passende, und die Workspace-Zuordnung fiele aus.",
            ]
            for id in ids.sorted() {
                block.append("  { if = 'test %{app-bundle-id} = \(id)', " +
                             "check-further-callbacks = true, run = 'layout floating' },")
            }
            block.append("  " + Self.floatEnd)
            block.append("")
            lines.insert(contentsOf: block, at: anchor + 1)
        }

        // Über saveAndReload: sichert, prüft und rollt bei Fehlern zurück.
        saveAndReload(lines.joined(separator: "\n"))
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

// ── Aussehen ──────────────────────────────────────────────────────────
// Eine Menüleisten-App wird im Vorbeigehen benutzt. Farbe und Symbol
// sind deshalb kein Zierrat: sie sind der schnellste Weg, eine Zeile zu
// erkennen, ohne sie zu lesen. Gleiche Gruppe = gleiche Farbe, immer.

enum Look {
    /// Symbol und Farbe je Skriptgruppe. Unbekannte Gruppen bekommen
    /// bewusst ein neutrales Grau statt einer zufälligen Farbe — sonst
    /// verliert die Zuordnung ihre Aussage.
    static func group(_ name: String) -> (icon: String, tint: Color) {
        switch name {
        case "Aufbauen":          return ("hammer.fill",            .orange)
        case "Ghostty":           return ("terminal.fill",          .green)
        case "Workspace starten": return ("square.grid.2x2.fill",   .blue)
        case "AeroSpace":         return ("gearshape.fill",         .purple)
        default:                  return ("chevron.right.circle",   .gray)
        }
    }

    /// Symbol je Eintrag, geraten aus dem Text. Trifft es nicht, gilt
    /// das Gruppensymbol — nie ein falsches.
    static func script(_ label: String, group: String) -> String {
        let l = label.lowercased()
        if l.contains("laptop")        { return "laptopcomputer" }
        if l.contains("monitorwechsel"){ return "display.2" }
        if l.contains("alles")         { return "square.stack.3d.up.fill" }
        if l.contains("layouts")       { return "arrow.up.left.and.arrow.down.right" }
        if l.contains("herdr")         { return "chevron.left.forwardslash.chevron.right" }
        if l.contains("hermes") || l.contains("homelab") { return "network" }
        if l.contains("terminal")      { return "terminal" }
        if l.hasPrefix("1 ")           { return "1.square.fill" }
        if l.hasPrefix("2 ")           { return "2.square.fill" }
        if l.hasPrefix("3 ")           { return "3.square.fill" }
        if l.hasPrefix("4 ")           { return "4.square.fill" }
        if l.hasPrefix("5 ")           { return "5.square.fill" }
        if l.hasPrefix("6 ")           { return "6.square.fill" }
        if l.hasPrefix("7 ")           { return "7.square.fill" }
        return Look.group(group).icon
    }
}

/// Eine anklickbare Zeile mit Symbolplakette, Titel und optionaler
/// Tastenkappe. Hebt sich beim Überfahren hervor — ohne das wirkt eine
/// Liste aus Text tot, weil nichts zurückmeldet, dass sie anfassbar ist.
struct ActionRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    var key: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(hovering ? 0.28 : 0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let key, !key.isEmpty { Keycap(text: key) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Tastenkürzel als Kappe statt als Fliesstext — so liest man sie als
/// Taste und nicht als Teil des Satzes.
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text.replacingOccurrences(of: "alt-", with: "⌥")
                 .replacingOccurrences(of: "ctrl-", with: "⌃")
                 .replacingOccurrences(of: "shift-", with: "⇧")
                 .replacingOccurrences(of: "cmd-", with: "⌘"))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
            )
    }
}

/// Kleine Statusmarke für die Kopfzeile.
struct Pill: View {
    let icon: String
    let text: String
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(
            Capsule().fill(tint.opacity(0.13))
        )
    }
}

// ── Oberfläche ────────────────────────────────────────────────────────

struct RootView: View {
    @ObservedObject var m = Model.shared
    @State private var tab = 0
    @AppStorage(Pref.startTab)    private var startTab = 0
    @AppStorage(Pref.panelHeight) private var panelHeight = 380.0

    private let tabs: [(String, String)] = [
        ("Fenster",    "macwindow"),
        ("Workspaces", "square.grid.2x2"),
        ("Config",     "doc.text"),
        ("Aktionen",   "bolt.fill"),
        ("App",        "gearshape"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar

            Divider().opacity(0.5)

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

            Divider().opacity(0.5)
            StatusBar(m: m)
        }
        .frame(width: 560)
        .background(.ultraThinMaterial)
        .onAppear { tab = startTab; m.refresh() }
    }

    /// Kopfzeile: wer bin ich, und wie steht es gerade. Die Marken rechts
    /// beantworten die zwei Fragen, wegen derer man das Menü überhaupt
    /// aufklappt — wie viele Monitore sieht AeroSpace, und stimmt etwas
    /// nicht.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.split.2x2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            Text("AeroPilot")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            if !m.orphans.isEmpty {
                Pill(icon: "exclamationmark.triangle.fill",
                     text: "\(m.orphans.count)", tint: .orange)
            }
            if !m.misplaced.isEmpty {
                Pill(icon: "arrow.left.arrow.right",
                     text: "\(m.misplaced.count)", tint: .blue)
            }
            Pill(icon: "macwindow", text: "\(m.windows.count)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Eigene Reiterleiste statt Segmented Control: Symbole sind auf
    /// einen Blick unterscheidbar, fünf Textschnipsel nicht.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                TabButton(title: t.0, icon: t.1, selected: tab == i) {
                    tab = i
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.15)
                                   : Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

    /// Gilt pro App, nicht pro Fenster: die Regel in der Config trifft über
    /// die Bundle-ID, also alle Fenster dieser App.
    var pinned: Bool { m.floats.contains(w.appBundleId) }

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

            // Merken. `layout floating` überlebt keinen App-Neustart —
            // dauerhaft wird es erst durch eine Regel in der Config.
            Button {
                m.setPersistentFloat(w.appBundleId, !pinned)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.borderless)
            .help(pinned
                  ? "\(w.appName) floatet dauerhaft — klicken zum Aufheben"
                  : "floatend merken: Regel in die Config schreiben, gilt für alle Fenster von \(w.appName)")

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
            VStack(alignment: .leading, spacing: 14) {
                ForEach(m.scriptGroups, id: \.0) { group, scripts in
                    section(group) {
                        ForEach(scripts) { s in
                            ActionRow(icon: Look.script(s.label, group: group),
                                      tint: Look.group(group).tint,
                                      title: s.label,
                                      key: s.key) { m.runScript(s.file) }
                        }
                    }
                }
                if m.scripts.isEmpty {
                    Text("Keine Skripte in \(m.envDir)")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }
                section("AeroSpace") {
                    ActionRow(icon: "arrow.clockwise", tint: .purple,
                              title: "Config neu laden",
                              subtitle: "nach jedem Monitorwechsel") {
                        let r = Aero.run(["reload-config"])
                        let t = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                        m.say(t.isEmpty ? "Config neu geladen" : t,
                              error: t.contains("[ERROR]"))
                    }
                    ActionRow(icon: "pause.circle.fill", tint: .red,
                              title: "Tiling AUS", subtitle: "Notbremse") {
                        Aero.run(["enable", "off"]); m.say("Tiling aus")
                    }
                    ActionRow(icon: "play.circle.fill", tint: .green,
                              title: "Tiling EIN") {
                        Aero.run(["enable", "on"]); m.say("Tiling ein"); m.refresh()
                    }
                }
                Text(m.version).font(.caption2).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
            }
            .padding(.vertical, 12)
        }
    }

    /// Gruppenkopf mit Symbol und Farbe. Die Farbe wiederholt sich in
    /// jeder Zeile der Gruppe — dadurch liest man die Zugehörigkeit,
    /// ohne die Überschrift zu suchen.
    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        let look = Look.group(title)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: look.icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(look.tint)
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .kerning(0.6)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 1)
            VStack(spacing: 1) { c() }.padding(.horizontal, 6)
        }
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
    @AppStorage(Pref.watch)          private var watch = true
    @AppStorage(Pref.relayoutAfterRestart) private var relayoutAfterRestart = true

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
                        if mode != .off {
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
                    Toggle("Im Hintergrund prüfen und einmalig melden", isOn: $watch)
                        .onChange(of: watch) { m.startWatch() }
                    Text("Alle 60 s. Ohne das merkt man ein verlorenes Fenster erst, "
                         + "wenn es beim Workspace-Wechsel liegenbleibt.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Nach einem Neustart das Layout richten (relayout.sh)",
                           isOn: $relayoutAfterRestart)
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
        case .launchAgent: return "über LaunchAgent aktiv — in den Systemeinstellungen " +
                                  "unter „Anmeldeobjekte & Erweiterungen“ im unteren Abschnitt"
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
            IconButton(icon: "arrow.clockwise", help: "Neu einlesen") {
                m.refresh(); m.say("")
            }
            IconButton(icon: "power", help: "AeroPilot beenden", tint: .red) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Runder Symbolknopf für die Fusszeile. `.borderless` wirkt auf
/// dunklem Material wie totes Bild — ein eigener Hover-Hintergrund
/// zeigt, dass da etwas anklickbar ist.
struct IconButton: View {
    let icon: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? tint : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(tint.opacity(hovering ? 0.15 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// ── App ───────────────────────────────────────────────────────────────

@main
struct AeroPilotApp: App {
    init() {
        Pref.registerDefaults()
        // Nicht im View starten: mit .menuBarExtraStyle(.window) entsteht
        // die Ansicht erst beim ersten Öffnen des Popovers.
        DispatchQueue.main.async { Model.shared.startWatch() }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
        } label: {
            Image(systemName: "square.split.2x2")
        }
        .menuBarExtraStyle(.window)
    }
}
