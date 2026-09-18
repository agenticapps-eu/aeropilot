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

// BEGIN ConfigFile
/// Resolve the live symlink once; atomically replace its target, retaining all text.
enum ConfigFile {
    enum Failure: Error { case invalidConfiguration }
    static func save(_ text: String, path: String, validate: () -> Bool) throws {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let previous = try String(contentsOf: target, encoding: .utf8)
        try text.write(to: target, atomically: true, encoding: .utf8)
        guard validate() else {
            try previous.write(to: target, atomically: true, encoding: .utf8)
            throw Failure.invalidConfiguration
        }
    }
}
// END ConfigFile

// BEGIN MonitorChangeObserver
/// Display notifications arrive in bursts while a dock negotiates displays.
/// Reload once after they settle; never rebuild workspaces or terminal windows.
@MainActor
final class MonitorChangeObserver {
    private let center: NotificationCenter
    private let delay: TimeInterval
    private let signature: () -> String
    private let reload: () -> Void
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var observed = ""

    init(center: NotificationCenter = .default, delay: TimeInterval = 2,
         signature: @escaping () -> String, reload: @escaping () -> Void) {
        self.center = center
        self.delay = delay
        self.signature = signature
        self.reload = reload
    }

    func start() {
        guard observer == nil else { return }
        observed = signature()
        observer = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    private func changed() {
        let next = signature()
        guard next != observed else { return }
        observed = next
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            // A changed signature without a delivered notification also gets
            // a settling period. A transient empty display set is not actionable.
            guard signature() == observed else { changed(); return }
            guard !observed.isEmpty else { return }
            reload()
        }
    }
}
// END MonitorChangeObserver

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

    // ── Workspace-Namen ───────────────────────────────────────────────
    //
    // AeroSpace kennt keine Namen: ein Workspace IST seine Kennung. Ihn
    // umzubenennen hiesse, die Kennung ueberall mitzuziehen — Config,
    // Tasten, layout.conf, Skriptnamen. Die Namen stehen deshalb daneben
    // in env/workspaces.conf, rein zur Anzeige, und werden auch von den
    // ws-*.sh fuer ihre Beschriftung gelesen.
    @Published var wsNames: [String: String] = [:]

    var workspacesConf: String { envDir + "/workspaces.conf" }

    func loadWorkspaceNames() {
        guard let text = try? String(contentsOfFile: workspacesConf, encoding: .utf8)
        else { wsNames = [:]; return }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: "#", maxSplits: 1,
                                 omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            out[String(parts[0])] = parts.dropFirst().joined(separator: " ")
        }
        wsNames = out
    }

    func name(of ws: String) -> String { wsNames[ws] ?? "" }

    /// Schreibt EINEN Namen zurueck. Zeilenweise ersetzen statt die Datei
    /// neu zu erzeugen — der Kopf erklaert, warum es die Datei gibt, und
    /// eine Neuerzeugung wuerde ihn wegwerfen.
    func setWorkspaceName(_ ws: String, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var lines = (try? String(contentsOfFile: workspacesConf, encoding: .utf8))?
            .components(separatedBy: "\n") else {
            say("workspaces.conf nicht lesbar.", error: true); return
        }
        var replaced = false
        for (i, raw) in lines.enumerated() {
            let code = raw.split(separator: "#", maxSplits: 1,
                                 omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let first = code.split(whereSeparator: \.isWhitespace).first,
                  String(first) == ws else { continue }
            lines[i] = clean.isEmpty ? "\(ws)" : "\(ws)  \(clean)"
            replaced = true
            break
        }
        if !replaced { lines.append("\(ws)  \(clean)") }
        do {
            try lines.joined(separator: "\n").write(toFile: workspacesConf,
                                                    atomically: true, encoding: .utf8)
            loadWorkspaceNames()
            say("Workspace \(ws) heisst jetzt \(clean.isEmpty ? "(ohne Namen)" : clean).")
        } catch {
            say("Schreiben fehlgeschlagen: \(error)", error: true)
        }
    }

    private lazy var monitorChanges = MonitorChangeObserver(signature: {
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return "\(id?.uint32Value ?? 0):\(NSStringFromRect(screen.frame)):\(screen.backingScaleFactor):\(CGMainDisplayID())"
        }.sorted().joined(separator: "|")
    }, reload: { [weak self] in
        self?.reconcileMonitors()
    })

    func reconcileMonitors() {
        let path = envDir + "/monitorwechsel.sh"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = FileManager.default.fileExists(atPath: path)
                ? Aero.shell(path) : Aero.run(["reload-config"])
            let message = result.code == 0
                ? "Monitorprofil abgeglichen. " + result.out.trimmingCharacters(in: .whitespacesAndNewlines)
                : "Monitorabgleich fehlgeschlagen: " + result.err
            NSLog("%@", message)
            DispatchQueue.main.async {
                UserDefaults.standard.set(message, forKey: "lastMonitorReloadResult")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastMonitorReloadAt")
                self?.say(message, error: result.code != 0)
                self?.refresh()
            }
        }
    }

    func startMonitorWatch() {
        monitorChanges.start()
        reconcileMonitors()
    }

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
        loadWorkspaceNames()
    }

    // ── Soll-Ist-Abgleich ─────────────────────────────────────────────

    /// Liest env/layout.conf — dieselbe Datei, die auch relayout.sh liest.
    /// Bewusst dieselbe: zwei Listen laufen auseinander, eine nicht.
    func layoutRules() -> [LayoutRule] {
        let statePath = NSHomeDirectory() + "/.local/state/aerospace/profile.json"
        let state = (try? Data(contentsOf: URL(fileURLWithPath: statePath)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let laptop = state?["version"] as? Int == 1 && state?["profile"] as? String == "laptop"
        guard let text = try? String(contentsOfFile: envDir + (laptop ? "/layout.laptop.conf" : "/layout.conf"),
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
            for r in rules where r.bundleId == w.appBundleId || r.bundleId == "*" {
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
        if text.isEmpty && r.code == 0 { return (true, "Keine Fehler, keine Warnungen.") }
        return (r.code == 0 && !text.contains("[ERROR]"), text)
    }

    /// Speichert und lädt neu. Vorher wird die alte Fassung weggesichert,
    /// und bei Fehlern in der neuen Config wird zurückgerollt.
    func saveAndReload(_ text: String) {
        let backup = configPath + ".autosave-" + Self.stamp()
        let previous = loadConfig()
        try? previous.write(toFile: backup, atomically: true, encoding: .utf8)

        do {
            try ConfigFile.save(text, path: configPath) { self.validate().ok }
        } catch {
            say("Speichern abgebrochen, vorherige Konfiguration erhalten: \(error)", error: true)
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

// ── Fremde Konfigurationsdateien ──────────────────────────────────────
// Ghostty und herdr bringen eigene Configs mit. AeroPilot fasst sie an,
// aber nur zeilenweise.
//
// WARUM NICHT PARSEN UND NEU SCHREIBEN:
// Beide Dateien bestehen zur Hälfte aus Kommentaren, und die tragen das
// Warum — welche Taste wem gehört, welche Kollision wo lauert, was am
// 02.09. rausgeflogen ist und weshalb. Ein TOML-Round-Trip wirft das
// alles weg. Deshalb wird genau die eine Zeile ersetzt, die sich ändert,
// und der Rest bleibt Byte für Byte stehen.

enum AppConfig {
    static let ghostty = NSHomeDirectory() + "/.config/ghostty/config"
    static let herdr   = NSHomeDirectory() + "/.config/herdr/config.toml"
    static let ghosttyBin = "/Applications/Ghostty.app/Contents/MacOS/ghostty"

    static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Vor jedem Schreiben eine datierte Kopie. Kostet nichts und hat
    /// schon zweimal einen Abend gerettet.
    private static func backup(_ path: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        try? FileManager.default.copyItem(atPath: path,
            toPath: path + ".bak." + f.string(from: Date()))
    }

    private static func write(_ path: String, _ text: String) -> Bool {
        backup(path)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    /// Ghostty-Format: `schlüssel = wert`, eine Zeile je Eintrag.
    /// Fehlt der Schlüssel, wird er hinten angehängt.
    @discardableResult
    static func setGhostty(_ key: String, _ value: String) -> Bool {
        var lines = read(ghostty).components(separatedBy: "\n")
        let neu = "\(key) = \(value)"
        var gefunden = false
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + " =") || t.hasPrefix(key + "=") {
                lines[i] = neu; gefunden = true; break
            }
        }
        if !gefunden {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("# von AeroPilot gesetzt")
            lines.append(neu)
        }
        return write(ghostty, lines.joined(separator: "\n"))
    }

    static func getGhostty(_ key: String) -> String {
        for l in read(ghostty).components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#") else { continue }
            if t.hasPrefix(key + " =") || t.hasPrefix(key + "=") {
                return t.drop(while: { $0 != "=" }).dropFirst()
                        .trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// TOML: Schlüssel INNERHALB eines Abschnitts ersetzen. Ohne die
    /// Abschnittsgrenze würde `name` unter [theme] und ein `name`
    /// woanders verwechselt.
    @discardableResult
    static func setToml(_ path: String, section: String, key: String, value: String) -> Bool {
        var lines = read(path).components(separatedBy: "\n")
        var drin = section.isEmpty
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                drin = (t == "[\(section)]")
                continue
            }
            guard drin, !t.hasPrefix("#") else { continue }
            if t.hasPrefix(key + " =") || t.hasPrefix(key + "=") {
                lines[i] = "\(key) = \(value)"
                return write(path, lines.joined(separator: "\n"))
            }
        }
        return false
    }

    static func getToml(_ path: String, section: String, key: String) -> String {
        var drin = section.isEmpty
        for l in read(path).components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { drin = (t == "[\(section)]"); continue }
            guard drin, !t.hasPrefix("#") else { continue }
            if t.hasPrefix(key + " =") || t.hasPrefix(key + "=") {
                return t.drop(while: { $0 != "=" }).dropFirst()
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return ""
    }

    /// Themes und Fonts kommen aus Ghostty selbst — eine gepflegte Liste
    /// im Code wäre am Tag des nächsten Ghostty-Updates falsch.
    static func ghosttyThemes() -> [String] {
        let r = Aero.shell("'\(ghosttyBin)' +list-themes 2>/dev/null")
        return r.out.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: " (resources)", with: "")
                     .replacingOccurrences(of: " (user)", with: "")
                     .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func ghosttyFonts() -> [String] {
        let r = Aero.shell("'\(ghosttyBin)' +list-fonts 2>/dev/null")
        // Ghostty listet Familie und darunter eingerückt die Schnitte.
        // Uns interessiert nur die Familie: die nicht eingerückten Zeilen.
        return r.out.components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix(" ") && !$0.hasPrefix("\t") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// ── Tastenkürzel aller drei Werkzeuge ─────────────────────────────────

enum Tool: String, CaseIterable {
    case aerospace = "AeroSpace"
    case ghostty   = "Ghostty"
    case herdr     = "herdr"

    var tint: Color {
        switch self {
        case .aerospace: return .blue
        case .ghostty:   return .green
        // Pink statt Orange: Orange gehört den Aktionen, und im
        // Cheatsheet stehen herdr-Kürzel direkt neben Aktionsfarben.
        case .herdr:     return .pink
        }
    }
    var icon: String {
        switch self {
        case .aerospace: return "square.grid.2x2.fill"
        case .ghostty:   return "terminal.fill"
        case .herdr:     return "rectangle.split.3x1.fill"
        }
    }
}

struct Shortcut: Identifiable {
    let id = UUID()
    let keys: String
    let what: String
    let tool: Tool
    let wichtig: Bool
}

enum Shortcuts {
    /// Was „wichtig" heisst, ist eine Entscheidung, keine Messung: es
    /// sind die Kürzel, die man im Alltag tatsächlich drückt. Alles
    /// andere ist vollständig, aber steht hinter „mehr …" — eine Liste
    /// aus 100 Zeilen liest niemand.
    private static let wichtigAero: Set<String> = [
        "alt-1","alt-2","alt-3","alt-4","alt-5","alt-6","alt-7","alt-tab",
        "alt-ctrl-a","alt-ctrl-m","alt-ctrl-w","alt-ctrl-r",
        "ctrl-left","ctrl-right","alt-left","alt-right","alt-up","alt-down",
    ]
    private static let wichtigHerdr: Set<String> = [
        "prefix","new_workspace","next_workspace","previous_workspace",
        "next_tab","previous_tab","new_tab","split_vertical",
        "split_horizontal","zoom","close_pane",
    ]

    static func all() -> [Shortcut] { aerospace() + ghostty() + herdr() }

    // AeroSpace: aus [mode.main.binding], Zeilen `taste = 'befehl'`
    static func aerospace() -> [Shortcut] {
        let text = AppConfig.read(NSHomeDirectory() + "/.config/aerospace/aerospace.toml")
        var out: [Shortcut] = []
        var drin = false
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { drin = t.hasPrefix("[mode.main.binding]"); continue }
            guard drin, !t.hasPrefix("#"), t.contains(" = ") else { continue }
            let teile = t.components(separatedBy: " = ")
            guard teile.count >= 2 else { continue }
            let taste = teile[0].trimmingCharacters(in: .whitespaces)
            var was = teile.dropFirst().joined(separator: " = ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            was = was.replacingOccurrences(of: "exec-and-forget ", with: "")
            if let r = was.range(of: "/", options: .backwards) { was = String(was[r.upperBound...]) }
            out.append(Shortcut(keys: taste, what: was, tool: .aerospace,
                                wichtig: wichtigAero.contains(taste)))
        }
        return out
    }

    // Ghostty: `keybind = kombination=aktion`. `=unbind` ist kein Kürzel,
    // sondern das Abschalten eines mitgelieferten — raus damit.
    static func ghostty() -> [Shortcut] {
        var out: [Shortcut] = []
        for raw in AppConfig.read(AppConfig.ghostty).components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("keybind"), let eq = t.firstIndex(of: "=") else { continue }
            let rest = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard let sep = rest.firstIndex(of: "="), !rest.hasSuffix("=unbind") else { continue }
            let kombi = String(rest[..<sep]).trimmingCharacters(in: .whitespaces)
            var aktion = String(rest[rest.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            // `text:\x02h` ist die an herdr getippte Prefix-Sequenz.
            if aktion.hasPrefix("text:") { aktion = "an herdr: " + aktion.replacingOccurrences(of: "text:", with: "") }
            out.append(Shortcut(keys: kombi, what: aktion, tool: .ghostty,
                                wichtig: kombi.contains("ctrl+alt+shift+super")))
        }
        return out
    }

    // herdr: [keys]-Abschnitt, Wert ist String oder Liste.
    static func herdr() -> [Shortcut] {
        var out: [Shortcut] = []
        var drin = false
        for raw in AppConfig.read(AppConfig.herdr).components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { drin = (t == "[keys]"); continue }
            guard drin, !t.hasPrefix("#"), t.contains("=") else { continue }
            let teile = t.components(separatedBy: "=")
            let name = teile[0].trimmingCharacters(in: .whitespaces)
            var wert = teile.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            wert = wert.replacingOccurrences(of: "[", with: "")
                       .replacingOccurrences(of: "]", with: "")
                       .replacingOccurrences(of: "\"", with: "")
            let kombis = wert.components(separatedBy: ",")
                             .map { $0.trimmingCharacters(in: .whitespaces) }
                             .filter { !$0.isEmpty }
            guard !kombis.isEmpty else { continue }
            out.append(Shortcut(keys: kombis.joined(separator: "  ·  "),
                                what: name.replacingOccurrences(of: "_", with: " "),
                                tool: .herdr, wichtig: wichtigHerdr.contains(name)))
        }
        return out
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
    /// Farbe des Werkzeugs, zu dem das Kürzel gehört. Graue Kappen über
    /// drei Werkzeuge hinweg sehen aus wie eine einzige lange Liste —
    /// die Farbe sagt auf einen Blick, wer die Taste abfängt.
    var tint: Color = .secondary
    var body: some View {
        Text(text.replacingOccurrences(of: "alt-", with: "⌥")
                 .replacingOccurrences(of: "ctrl-", with: "⌃")
                 .replacingOccurrences(of: "shift-", with: "⇧")
                 .replacingOccurrences(of: "cmd-", with: "⌘"))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint.opacity(0.18))
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

    /// Acht Bereiche passen in keine Reiterleiste — fünf Textschnipsel
    /// waren schon eng. Deshalb eine Leiste an der Seite: sie wächst
    /// nach unten statt in die Breite, und jeder Bereich behält seine
    /// eigene Farbe, die sich im Seitenkopf wiederholt.
    /// Acht eigene Farben, keine doppelt. Zwei Seiten in derselben Farbe
    /// heben die Farbcodierung auf — dann ist Farbe nur noch Dekoration
    /// und sagt nicht mehr, wo man ist.
    private let tabs: [(String, String, Color)] = [
        ("Fenster",    "macwindow",                  .blue),
        ("Workspaces", "square.grid.2x2.fill",       .cyan),
        ("Aktionen",   "bolt.fill",                  .orange),
        ("Kürzel",     "keyboard.fill",              .purple),
        ("Ghostty",    "terminal.fill",              .green),
        ("herdr",      "rectangle.split.3x1.fill",   .pink),
        ("AeroSpace",  "doc.text.fill",              .indigo),
        ("App",        "gearshape.fill",             .brown),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            HStack(spacing: 0) {
                rail
                Divider().opacity(0.4)
                Group {
                    switch tab {
                    case 0: WindowsView(m: m)
                    case 1: WorkspacesView(m: m)
                    case 2: ActionsView(m: m)
                    case 3: CheatsheetView(m: m)
                    case 4: GhosttyView(m: m)
                    case 5: HerdrView(m: m)
                    case 6: ConfigView(m: m)
                    default: SettingsView(m: m)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: panelHeight)

            Divider().opacity(0.5)
            StatusBar(m: m)
        }
        .frame(width: 660)
        .background(.ultraThinMaterial)
        .onAppear { tab = min(startTab, tabs.count - 1); m.refresh() }
    }

    private var rail: some View {
        VStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                RailButton(title: t.0, icon: t.1, tint: t.2, selected: tab == i) {
                    tab = i
                }
            }
            Spacer()
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .frame(width: 104)
    }

    /// Kopfzeile: wer bin ich, und wie steht es gerade. Die Marken rechts
    /// beantworten die zwei Fragen, wegen derer man das Menü überhaupt
    /// aufklappt — wie viele Monitore sieht AeroSpace, und stimmt etwas
    /// nicht.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.split.2x2.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [.blue, .purple],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                )
            Text("AeroPilot")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple],
                                   startPoint: .leading, endPoint: .trailing))
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

}

/// Eintrag der Seitenleiste. Der aktive bekommt Farbe UND einen Balken
/// links — Farbe allein ist zu schwach, wenn direkt daneben eine zweite
/// Farbe steht, und ein Balken funktioniert auch bei Farbenblindheit.
struct RailButton: View {
    let title: String
    let icon: String
    let tint: Color
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Das Symbol trägt die Farbe immer, auch unausgewählt —
                // dadurch ist die Leiste als Ganzes farbig und man findet
                // eine Seite am Farbton wieder, nicht erst am Text.
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(selected ? AnyShapeStyle(.white)
                                              : AnyShapeStyle(tint))
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? AnyShapeStyle(
                                    LinearGradient(colors: [tint,
                                                            tint.opacity(0.72)],
                                                   startPoint: .top,
                                                   endPoint: .bottom))
                                  : AnyShapeStyle(tint.opacity(0.16)))
                    )
                Text(title)
                    .font(.system(size: 11,
                                  weight: selected ? .bold : .medium,
                                  design: .rounded))
                    .foregroundStyle(selected ? AnyShapeStyle(tint)
                                              : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.leading, 5).padding(.trailing, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? tint.opacity(0.16)
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
        VStack(spacing: 0) {
            PageHeader(icon: "macwindow", title: "Fenster",
                       subtitle: m.windows.count == 1
                           ? "1 offen" : "\(m.windows.count) offen",
                       tint: .blue)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !m.orphans.isEmpty { OrphanBanner(m: m) }
                    if !m.misplaced.isEmpty { MisplacedBanner(m: m) }
                    ForEach(grouped, id: \.0) { ws, wins in
                        // Name dazu, wenn einer in workspaces.conf steht —
                        // „Workspace 5 · HOMELAB" liest sich schneller als
                        // eine blosse Nummer.
                        GroupHeader(title: m.name(of: ws).isEmpty
                                        ? "Workspace \(ws)"
                                        : "Workspace \(ws) · \(m.name(of: ws))",
                                    count: wins.count,
                                    active: ws == m.focused,
                                    action: ("ausgleichen", { m.balance(ws) }))
                        ForEach(wins) { w in WindowRow(m: m, w: w) }
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }
}

/// Zwischenüberschrift in der Liste: klein, gesperrt, versalisiert, mit
/// einer Linie bis zum Rand. Sie soll die Liste gliedern, ohne sich wie
/// ein weiterer Eintrag zu lesen — deshalb kleiner als die Einträge
/// darunter, nicht grösser.
struct GroupHeader: View {
    let title: String
    var count: Int? = nil
    var active: Bool = false
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(active ? AnyShapeStyle(Color.blue)
                                        : AnyShapeStyle(.secondary))
                .kerning(0.6)
            if active {
                Circle().fill(Color.blue).frame(width: 5, height: 5)
            }
            if let count {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 3)
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
        VStack(spacing: 0) {
            PageHeader(icon: "square.grid.2x2.fill", title: "Workspaces",
                       subtitle: "aktiv: \(m.focused)", tint: .cyan)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { ws in
                        let n = m.windows.filter { $0.workspace == ws.workspace }.count
                        let aktiv = ws.workspace == m.focused
                        // FRÜHER war die ganze Zeile ein Button. Das geht
                        // nicht mehr: ein TextField in einem Button bekommt
                        // auf macOS keine Klicks — der Button schluckt sie.
                        // Jetzt ist die Scheibe der Knopf zum Hinspringen,
                        // der Name ein Feld, und die Unterzeile reagiert per
                        // Tippgeste.
                        HStack(spacing: 10) {
                                // Nummer als gefüllte Scheibe — sie ist die
                                // Kennung des Workspace und soll wie eine
                                // Marke aussehen, nicht wie Fliesstext.
                                Button { m.focus(workspace: ws.workspace) } label: {
                                    Text(ws.workspace)
                                        .font(.system(size: 13, weight: .heavy,
                                                      design: .rounded))
                                        .foregroundStyle(aktiv ? AnyShapeStyle(.white)
                                                               : AnyShapeStyle(Color.cyan))
                                        .frame(width: 26, height: 26)
                                        .background(
                                            Circle().fill(aktiv
                                                ? AnyShapeStyle(LinearGradient(
                                                    colors: [.cyan, .blue],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing))
                                                : AnyShapeStyle(Color.cyan.opacity(0.18)))
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Workspace \(ws.workspace) anzeigen")
                                VStack(alignment: .leading, spacing: 1) {
                                    // Name aus env/workspaces.conf, direkt
                                    // hier aenderbar. Ein TextField statt
                                    // Text, damit man nicht erst in einen
                                    // Bearbeitungsmodus klicken muss.
                                    WorkspaceNameField(m: m, ws: ws.workspace)
                                    Text("\(ws.monitorName) · "
                                         + (n == 1 ? "1 Fenster" : "\(n) Fenster"))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if n > 1 {
                                    Button("ausgleichen") { m.balance(ws.workspace) }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10, weight: .semibold,
                                                      design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(aktiv
                                        ? AnyShapeStyle(LinearGradient(
                                            colors: [Color.cyan.opacity(0.26),
                                                     Color.blue.opacity(0.12)],
                                            startPoint: .leading,
                                            endPoint: .trailing))
                                        : AnyShapeStyle(Color.cyan.opacity(0.07)))
                            )
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }
}

/// Der Workspace-Name als Eingabefeld.
///
/// Eigener View, weil jede Zeile ihren eigenen Bearbeitungsstand braucht.
/// Lokal gehalten und erst bei Enter oder beim Verlassen geschrieben —
/// bei jedem Tastendruck in die Datei zu schreiben hiesse, dass ein
/// halbgetippter Name durch refresh() wieder zurueckspringt.
struct WorkspaceNameField: View {
    @ObservedObject var m: Model
    let ws: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("ohne Namen", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { if !focused { commit() } }
            .onAppear { text = m.name(of: ws) }
            // Von aussen geaenderte Datei uebernehmen, aber nur solange
            // gerade niemand in diesem Feld tippt.
            .onChange(of: m.wsNames) { if !focused { text = m.name(of: ws) } }
    }

    private func commit() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != m.name(of: ws) else { return }
        m.setWorkspaceName(ws, clean)
    }
}

struct ConfigView: View {
    @ObservedObject var m: Model
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 8) {
            PageHeader(icon: "doc.text.fill", title: "AeroSpace",
                       subtitle: "aerospace.toml", tint: .indigo)
            // Weiche Fläche statt Rahmen — derselbe Griff wie bei Card.
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.indigo.opacity(0.08))
                )
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Button("Neu laden") { text = m.loadConfig() }
                Button("Prüfen") {
                    let v = m.validate()
                    m.say(v.message, error: !v.ok)
                }
                Spacer()
                Button("Speichern + anwenden") { m.saveAndReload(text) }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
        .onAppear { if !loaded { text = m.loadConfig(); loaded = true } }
    }
}

struct ActionsView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(spacing: 0) {
        PageHeader(icon: "bolt.fill", title: "Aktionen",
                   subtitle: m.scripts.isEmpty
                       ? "keine Skripte" : "\(m.scripts.count) Skripte",
                   tint: .orange)
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
            .padding(.bottom, 12)
        }
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

// ── Bausteine für die Seiten ──────────────────────────────────────────

/// Seitenkopf im Stil einer Zeitschriftenüberschrift: gross, fett, und
/// der erklärende Teil daneben in Grau. Ein Titel, der in derselben
/// Grösse wie der Inhalt steht, ist keine Überschrift, sondern nur eine
/// weitere Zeile.
struct PageHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Die Überschrift selbst trägt die Farbe, im Verlauf von
            // kräftig nach weich. Ein schwarzer Titel mit farbiger
            // Beizeile wirkt wie ein Formular; ein farbiger Titel setzt
            // den Ton für die ganze Seite.
            Text(title)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [tint, tint.opacity(0.62)],
                                   startPoint: .leading, endPoint: .trailing))
            Text(subtitle)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint.opacity(0.85))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.16)))
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
        // Farbe läuft nach unten aus, statt an einer Linie abzubrechen.
        .background(
            LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.0)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

/// Weich gefüllter Block ohne Rahmen. Dünne Linien zerhacken eine
/// kleine Fläche in Kästchen; eine flächige Füllung gruppiert genauso
/// zuverlässig und bleibt ruhig.
struct Card<C: View>: View {
    var tint: Color = .secondary
    @ViewBuilder let content: () -> C
    var body: some View {
        HStack(spacing: 0) {
            // Farbiger Streifen an der Kante: er gibt dem Block eine
            // kräftige Farbe, ohne dass die ganze Fläche laut wird und
            // der Text darauf schlechter lesbar würde.
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(
            LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/// Suchfeld im Stil der Kalender-App: nur Lupe und Linie, kein Kasten.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// Beschriftung links, Bedienelement rechts.
struct FieldRow<C: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder let control: () -> C
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .medium))
                if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .frame(width: 150, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }
}

// ── Ghostty ───────────────────────────────────────────────────────────

struct GhosttyView: View {
    @ObservedObject var m: Model
    @State private var font = ""
    @State private var size = ""
    @State private var theme = ""
    @State private var themes: [String] = []
    @State private var fonts: [String] = []
    @State private var geladen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(icon: "terminal.fill", title: "Ghostty",
                           subtitle: "~/.config/ghostty/config", tint: Tool.ghostty.tint)

                Card(tint: Tool.ghostty.tint) {
                    FieldRow(label: "Schriftfamilie",
                             hint: fonts.isEmpty ? nil : "\(fonts.count) verfügbar") {
                        Picker("", selection: $font) {
                            Text("— Ghostty-Standard —").tag("")
                            ForEach(fonts, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 230)
                    }
                    FieldRow(label: "Schriftgrösse") {
                        TextField("z. B. 13", text: $size)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    FieldRow(label: "Theme",
                             hint: themes.isEmpty ? nil : "\(themes.count) verfügbar") {
                        Picker("", selection: $theme) {
                            Text("— Ghostty-Standard —").tag("")
                            ForEach(themes, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 230)
                    }
                    HStack {
                        Spacer()
                        Button("Speichern") { speichern() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }

                Text("""
                     Ghostty liest die Datei bei jedem Start neu. Offene \
                     Fenster übernehmen Änderungen erst nach einem Neustart \
                     der App. Vor jedem Speichern legt AeroPilot eine \
                     datierte Kopie an.
                     """)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14)

                Text("Tastenkürzel stehen unter „Kürzel“ — dort alle drei Werkzeuge nebeneinander.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .onAppear {
            guard !geladen else { return }
            geladen = true
            font  = AppConfig.getGhostty("font-family")
            size  = AppConfig.getGhostty("font-size")
            theme = AppConfig.getGhostty("theme")
            DispatchQueue.global().async {
                let t = AppConfig.ghosttyThemes(); let f = AppConfig.ghosttyFonts()
                DispatchQueue.main.async { themes = t; fonts = f }
            }
        }
    }

    private func speichern() {
        var n = 0
        if !font.isEmpty  { AppConfig.setGhostty("font-family", font); n += 1 }
        if !size.isEmpty  { AppConfig.setGhostty("font-size", size);   n += 1 }
        if !theme.isEmpty { AppConfig.setGhostty("theme", theme);      n += 1 }
        m.say(n == 0 ? "Nichts zu speichern" : "Ghostty: \(n) Einstellung(en) gespeichert")
    }
}

// ── herdr ─────────────────────────────────────────────────────────────

struct HerdrView: View {
    @ObservedObject var m: Model
    @State private var theme = ""
    @State private var prefix = ""
    @State private var geladen = false

    /// Nur die Themes, die herdr mitbringt. Eine freie Texteingabe hier
    /// wäre eine Einladung zum Vertippen, und ein falscher Name fällt
    /// erst beim nächsten Start auf.
    private let themen = ["kanagawa","catppuccin","dracula","gruvbox",
                          "nord","tokyonight","solarized","rose-pine","default"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(icon: "rectangle.split.3x1.fill", title: "herdr",
                           subtitle: "~/.config/herdr/config.toml", tint: Tool.herdr.tint)

                Card(tint: Tool.herdr.tint) {
                    FieldRow(label: "Theme") {
                        Picker("", selection: $theme) {
                            ForEach(themen, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 200)
                    }
                    FieldRow(label: "Prefix-Taste",
                             hint: "Basis aller prefix+… Kürzel") {
                        TextField("ctrl+b", text: $prefix)
                            .textFieldStyle(.roundedBorder).frame(width: 140)
                    }
                    HStack {
                        Spacer()
                        Button("Speichern") { speichern() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }

                Card(tint: .red) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.red)
                        Text("Prefix ändern zieht weit")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("""
                         Ghostty übersetzt die hyper-Anschläge in genau diese \
                         Prefix-Sequenz — \\x02 ist ctrl+b. Änderst du den \
                         Prefix hier, musst du die keybind-Zeilen in \
                         ~/.config/ghostty/config mitziehen, sonst tippt \
                         Ghostty ins Leere.
                         """)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }

                Text("""
                     Die übrigen Bindungen und die [[keys.command]]-Blöcke \
                     bleiben bewusst der Datei vorbehalten: sie tragen \
                     Kommentare, die erklären, welche Taste wem gehört und \
                     wo es kollidiert. Ein Formular würde das wegwerfen.
                     """)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .onAppear {
            guard !geladen else { return }
            geladen = true
            theme  = AppConfig.getToml(AppConfig.herdr, section: "theme", key: "name")
            prefix = AppConfig.getToml(AppConfig.herdr, section: "keys",  key: "prefix")
            if theme.isEmpty { theme = "default" }
        }
    }

    private func speichern() {
        var ok = 0
        if AppConfig.setToml(AppConfig.herdr, section: "theme", key: "name",
                             value: "\"\(theme)\"") { ok += 1 }
        if !prefix.isEmpty,
           AppConfig.setToml(AppConfig.herdr, section: "keys", key: "prefix",
                             value: "\"\(prefix)\"") { ok += 1 }
        m.say(ok == 0 ? "Nichts geändert" : "herdr: \(ok) Einstellung(en) gespeichert — herdr neu starten")
    }
}

// ── Kürzel über alle drei Werkzeuge ───────────────────────────────────

struct CheatsheetView: View {
    @ObservedObject var m: Model
    @State private var alle = false
    @State private var filter: Tool? = nil
    @State private var kuerzel: [Shortcut] = []
    @State private var suche = ""

    private var sichtbar: [Shortcut] {
        kuerzel.filter { s in
            // Beim Suchen zählt die Wichtig-Auswahl nicht mehr: wer
            // tippt, will finden, nicht gefiltert werden.
            let sichtbarkeit = alle || s.wichtig || !suche.isEmpty
            let werkzeug = filter == nil || s.tool == filter
            let treffer = suche.isEmpty
                || s.keys.localizedCaseInsensitiveContains(suche)
                || s.what.localizedCaseInsensitiveContains(suche)
            return sichtbarkeit && werkzeug && treffer
        }
    }
    private var proTool: [(Tool, [Shortcut])] {
        Tool.allCases.compactMap { t in
            let s = sichtbar.filter { $0.tool == t }
            return s.isEmpty ? nil : (t, s)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(icon: "keyboard.fill", title: "Tastenkürzel",
                       subtitle: alle ? "alle \(kuerzel.count)" : "die wichtigsten",
                       tint: .purple)

            SearchField(placeholder: "Taste oder Aktion suchen …", text: $suche)
                .padding(.horizontal, 18).padding(.bottom, 10)

            HStack(spacing: 6) {
                FilterChip(title: "Alle", tint: .secondary, active: filter == nil) { filter = nil }
                ForEach(Tool.allCases, id: \.self) { t in
                    FilterChip(title: t.rawValue, tint: t.tint, active: filter == t) { filter = t }
                }
                Spacer()
                // Kein Schalter mit Beschriftung daneben — ein Knopf, der
                // sagt, was er zeigt. „mehr …" ist der Zustand, den man
                // will, nicht der, in dem man ist.
                FilterChip(title: alle ? "weniger" : "mehr …",
                           tint: .purple, active: alle) { alle.toggle() }
            }
            .padding(.horizontal, 18).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(proTool, id: \.0) { tool, liste in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: tool.icon)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(tool.tint)
                                Text(tool.rawValue.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(tool.tint).kerning(0.6)
                                Text("\(liste.count)")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                                Rectangle().fill(tool.tint.opacity(0.28)).frame(height: 1)
                            }
                            .padding(.horizontal, 14)
                            ForEach(liste) { s in
                                HStack(alignment: .top, spacing: 10) {
                                    Keycap(text: s.keys, tint: tool.tint)
                                        .frame(width: 170, alignment: .leading)
                                    Text(s.what)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 2)
                            }
                        }
                    }
                    if sichtbar.isEmpty {
                        Text("Keine Kürzel gefunden — stimmen die Pfade der Konfigurationsdateien?")
                            .font(.caption).foregroundStyle(.secondary).padding(14)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .onAppear { if kuerzel.isEmpty { kuerzel = Shortcuts.all() } }
    }
}

struct FilterChip: View {
    let title: String
    let tint: Color
    let active: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? tint : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    Capsule().fill(tint.opacity(active ? 0.16 : (hovering ? 0.08 : 0)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
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
        VStack(spacing: 0) {
        PageHeader(icon: "gearshape.fill", title: "Einstellungen",
                   subtitle: "AeroPilot", tint: .brown)
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
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary).kerning(0.6)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        // Dunkles Band als Abschluss, wie die Ereignisliste im Kalender.
        // Der Fuss trägt den Jetzt-Zustand; ein eigener Grund hebt ihn
        // vom Inhalt ab, ohne dass es eine Trennlinie braucht.
        .background(Color.primary.opacity(0.07))
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
        DispatchQueue.main.async {
            Model.shared.startMonitorWatch()
            Model.shared.startWatch()
        }
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
