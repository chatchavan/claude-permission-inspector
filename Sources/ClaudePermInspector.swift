// Lists macOS privacy permissions (TCC + notifications) granted to Claude.app / claude.app.
//
// Reads:
//   ~/Library/Application Support/com.apple.TCC/TCC.db   (per-user grants)
//   /Library/Application Support/com.apple.TCC/TCC.db    (system-wide grants)
//   ~/Library/Preferences/com.apple.ncprefs.plist        (notifications)
//
// The TCC databases are SIP-protected: this app needs Full Disk Access.

import AppKit
import SQLite3
import SwiftUI

// MARK: - Model

struct Entry: Identifiable, Hashable {
    let id = UUID()
    let scope: String
    let client: String
    let clientIsPath: Bool
    let service: String
    let permission: String
    let status: String
    let reason: String?
    let target: String?
    let modified: Date?
}

let serviceNames: [String: String] = [
    "kTCCServiceAccessibility": "Accessibility",
    "kTCCServiceAddressBook": "Contacts",
    "kTCCServiceAppleEvents": "Automation (Apple Events)",
    "kTCCServiceBluetoothAlways": "Bluetooth",
    "kTCCServiceCalendar": "Calendars",
    "kTCCServiceCamera": "Camera",
    "kTCCServiceDeveloperTool": "Developer Tools",
    "kTCCServiceEndpointSecurityClient": "Endpoint Security",
    "kTCCServiceFileProviderDomain": "File Provider",
    "kTCCServiceFileProviderPresence": "File Provider Presence",
    "kTCCServiceFocusStatus": "Focus Status",
    "kTCCServiceListenEvent": "Input Monitoring",
    "kTCCServiceLiverpool": "Location (Liverpool)",
    "kTCCServiceMediaLibrary": "Media & Apple Music",
    "kTCCServiceMicrophone": "Microphone",
    "kTCCServiceMotion": "Motion & Fitness",
    "kTCCServicePhotos": "Photos",
    "kTCCServicePhotosAdd": "Photos (Add Only)",
    "kTCCServicePostEvent": "Accessibility (Post Events)",
    "kTCCServiceReminders": "Reminders",
    "kTCCServiceRemoteDesktop": "Remote Desktop",
    "kTCCServiceScreenCapture": "Screen & System Audio Recording",
    "kTCCServiceSpeechRecognition": "Speech Recognition",
    "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
    "kTCCServiceSystemPolicyAppBundles": "App Management",
    "kTCCServiceSystemPolicyAppData": "App Data (other apps' containers)",
    "kTCCServiceSystemPolicyDesktopFolder": "Files: Desktop Folder",
    "kTCCServiceSystemPolicyDeveloperFiles": "Files: Developer Files",
    "kTCCServiceSystemPolicyDocumentsFolder": "Files: Documents Folder",
    "kTCCServiceSystemPolicyDownloadsFolder": "Files: Downloads Folder",
    "kTCCServiceSystemPolicyNetworkVolumes": "Files: Network Volumes",
    "kTCCServiceSystemPolicyRemovableVolumes": "Files: Removable Volumes",
    "kTCCServiceSystemPolicySysAdminFiles": "Files: System Admin Files",
    "kTCCServiceUbiquity": "iCloud",
    "kTCCServiceUserTracking": "Tracking",
    "kTCCServiceWebBrowserPublicKeyCredential": "Passkeys (Web Browser)",
]

// Anchors of the Privacy & Security pane in System Settings, keyed by TCC service.
let privacyAnchors: [String: String] = [
    "kTCCServiceAccessibility": "Privacy_Accessibility",
    "kTCCServicePostEvent": "Privacy_Accessibility",
    "kTCCServiceAddressBook": "Privacy_Contacts",
    "kTCCServiceAppleEvents": "Privacy_Automation",
    "kTCCServiceBluetoothAlways": "Privacy_Bluetooth",
    "kTCCServiceCalendar": "Privacy_Calendars",
    "kTCCServiceCamera": "Privacy_Camera",
    "kTCCServiceDeveloperTool": "Privacy_DevTools",
    "kTCCServiceFocusStatus": "Privacy_Focus",
    "kTCCServiceListenEvent": "Privacy_ListenEvent",
    "kTCCServiceLiverpool": "Privacy_LocationServices",
    "kTCCServiceMediaLibrary": "Privacy_Media",
    "kTCCServiceMicrophone": "Privacy_Microphone",
    "kTCCServiceMotion": "Privacy_Motion",
    "kTCCServicePhotos": "Privacy_Photos",
    "kTCCServicePhotosAdd": "Privacy_Photos",
    "kTCCServiceReminders": "Privacy_Reminders",
    "kTCCServiceRemoteDesktop": "Privacy_RemoteDesktop",
    "kTCCServiceScreenCapture": "Privacy_ScreenCapture",
    "kTCCServiceSpeechRecognition": "Privacy_SpeechRecognition",
    "kTCCServiceSystemPolicyAllFiles": "Privacy_AllFiles",
    "kTCCServiceSystemPolicyAppBundles": "Privacy_AppBundles",
    "kTCCServiceSystemPolicyAppData": "Privacy_AppData",
    "kTCCServiceSystemPolicyDesktopFolder": "Privacy_FilesAndFolders",
    "kTCCServiceSystemPolicyDocumentsFolder": "Privacy_FilesAndFolders",
    "kTCCServiceSystemPolicyDownloadsFolder": "Privacy_FilesAndFolders",
    "kTCCServiceSystemPolicyNetworkVolumes": "Privacy_FilesAndFolders",
    "kTCCServiceSystemPolicyRemovableVolumes": "Privacy_FilesAndFolders",
    "kTCCServiceSystemPolicyDeveloperFiles": "Privacy_FilesAndFolders",
    "kTCCServiceSystemPolicySysAdminFiles": "Privacy_FilesAndFolders",
    "kTCCServiceUserTracking": "Privacy_Advertising",
]

/// System Settings URL for an entry; unknown anchors fall back to Privacy & Security.
func settingsURL(for e: Entry) -> URL {
    if e.service == "Notifications" {
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(e.client)")!
    }
    let anchor = privacyAnchors[e.service] ?? "Privacy"
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
}

let authValues: [Int: String] = [0: "denied", 1: "unknown", 2: "allowed", 3: "limited"]

let authReasons: [Int: String] = [
    1: "error", 2: "user consent", 3: "user set", 4: "system set",
    5: "service policy", 6: "MDM policy", 7: "override policy",
    8: "missing usage string", 9: "prompt timeout", 10: "preflight unknown",
    11: "entitled", 12: "app type policy",
]

let notifAllowed = 1 << 25
let notifBits: [(Int, String)] = [
    (1 << 1, "badges"), (1 << 2, "sounds"), (1 << 3, "banners"),
    (1 << 4, "alerts"), (1 << 12, "lock screen"), (1 << 0, "notification center"),
]

// MARK: - Loading

struct Report {
    var apps: [String: String] = [:]  // bundle id -> path
    var entries: [Entry] = []
    var errors: [String] = []
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let userTCC = home + "/Library/Application Support/com.apple.TCC/TCC.db"
let systemTCC = "/Library/Application Support/com.apple.TCC/TCC.db"
let ncprefs = home + "/Library/Preferences/com.apple.ncprefs.plist"

func installedClaudeApps() -> [String: String] {
    var paths = Set<String>()
    let fm = FileManager.default
    for dir in ["/Applications", home + "/Applications"] {
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        where name.lowercased() == "claude.app" {
            paths.insert(dir + "/" + name)
        }
    }
    let mdfind = Process()
    mdfind.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    mdfind.arguments = [
        "kMDItemFSName == 'claude.app'c && kMDItemContentType == 'com.apple.application-bundle'"
    ]
    let pipe = Pipe()
    mdfind.standardOutput = pipe
    mdfind.standardError = FileHandle.nullDevice
    if (try? mdfind.run()) != nil {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        mdfind.waitUntilExit()
        String(decoding: data, as: UTF8.self).split(separator: "\n").forEach { paths.insert(String($0)) }
    }

    var apps: [String: String] = [:]
    for path in paths.sorted() {
        if let bid = Bundle(path: path)?.bundleIdentifier, apps[bid] == nil {
            apps[bid] = path
        }
    }
    return apps
}

func isClaudeClient(_ client: String, isPath: Bool, known: Set<String>) -> Bool {
    if client == Bundle.main.bundleIdentifier { return false }
    let c = client.lowercased()
    if isPath {
        return (c as NSString).lastPathComponent.contains("claude") || c.contains("/claude.app/")
    }
    return known.contains(client) || c.hasPrefix("com.anthropic.") || c.contains("claude")
}

func readTCC(_ path: String, scope: String, known: Set<String>) -> ([Entry], String?) {
    guard FileManager.default.fileExists(atPath: path) else { return ([], nil) }
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        return ([], "\(path): \(String(cString: sqlite3_errmsg(db)))")
    }

    func query(_ sql: String, _ row: (OpaquePointer) -> Void) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return String(cString: sqlite3_errmsg(db))
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        return nil
    }
    func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    var cols = Set<String>()
    if let err = query("PRAGMA table_info(access)", { cols.insert(text($0, 1) ?? "") }) {
        return ([], "\(path): \(err)")
    }
    if cols.isEmpty { return ([], "\(path): unable to read (no access table visible)") }
    // macOS 11+ uses auth_value; older releases used an 'allowed' boolean.
    let authCol = cols.contains("auth_value") ? "auth_value" : "allowed * 2"
    let reasonCol = cols.contains("auth_reason") ? "auth_reason" : "NULL"
    let indCol = cols.contains("indirect_object_identifier") ? "indirect_object_identifier" : "NULL"

    var entries: [Entry] = []
    let sql = "SELECT service, client, client_type, \(authCol), \(reasonCol), \(indCol), last_modified FROM access"
    let err = query(sql) { s in
        let client = text(s, 1) ?? ""
        let isPath = sqlite3_column_int(s, 2) != 0
        guard isClaudeClient(client, isPath: isPath, known: known) else { return }
        let service = text(s, 0) ?? ""
        let auth = Int(sqlite3_column_int(s, 3))
        let reason = sqlite3_column_type(s, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, 4))
        let indirect = text(s, 5)
        let modified = sqlite3_column_int64(s, 6)
        entries.append(Entry(
            scope: scope, client: client, clientIsPath: isPath, service: service,
            permission: serviceNames[service] ?? service.replacingOccurrences(of: "kTCCService", with: ""),
            status: authValues[auth] ?? "\(auth)",
            reason: reason.map { authReasons[$0] ?? "\($0)" },
            target: (indirect == nil || indirect == "UNUSED") ? nil : indirect,
            modified: modified > 0 ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil))
    }
    if let err { return ([], "\(path): \(err)") }
    return (entries, nil)
}

func readNotifications(known: Set<String>) -> [Entry] {
    guard let data = FileManager.default.contents(atPath: ncprefs),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let apps = plist["apps"] as? [[String: Any]]
    else { return [] }
    return apps.compactMap { app in
        let bid = app["bundle-id"] as? String ?? ""
        guard isClaudeClient(bid, isPath: false, known: known) else { return nil }
        let flags = app["flags"] as? Int ?? 0
        let allowed = flags & notifAllowed != 0
        let styles = allowed ? notifBits.filter { flags & $0.0 != 0 }.map(\.1) : []
        return Entry(
            scope: "user", client: bid, clientIsPath: false, service: "Notifications",
            permission: "Notifications", status: allowed ? "allowed" : "denied", reason: nil,
            target: styles.isEmpty ? nil : styles.joined(separator: ", "), modified: nil)
    }
}

func loadReport() -> Report {
    var report = Report()
    report.apps = installedClaudeApps()
    let known = Set(report.apps.keys)
    for (path, scope) in [(userTCC, "user"), (systemTCC, "system")] {
        let (entries, err) = readTCC(path, scope: scope, known: known)
        report.entries += entries
        if let err { report.errors.append(err) }
    }
    report.entries += readNotifications(known: known)
    report.entries.sort {
        ($0.client, $0.status == "allowed" ? 0 : 1, $0.permission) < ($1.client, $1.status == "allowed" ? 0 : 1, $1.permission)
    }
    return report
}

// MARK: - UI

@main
struct ClaudePermInspectorApp: App {
    var body: some Scene {
        WindowGroup("Claude Permission Inspector") { ContentView() }
            .defaultSize(width: 980, height: 560)
    }
}

struct ContentView: View {
    @State private var report = Report()
    @State private var showDenied = false

    private var visible: [Entry] {
        showDenied ? report.entries : report.entries.filter { $0.status == "allowed" || $0.status == "limited" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !report.errors.isEmpty { accessBanner }

            VStack(alignment: .leading, spacing: 2) {
                Text("Installed Claude apps").font(.headline)
                if report.apps.isEmpty {
                    Text("No Claude.app / claude.app bundle found (still checking for leftover grants).")
                        .foregroundStyle(.secondary)
                }
                ForEach(report.apps.sorted(by: { $0.key < $1.key }), id: \.key) { bid, path in
                    Text("\(path)  [\(bid)]").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }

            Table(visible) {
                TableColumn("") { e in
                    Button { NSWorkspace.shared.open(settingsURL(for: e)) } label: {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.borderless)
                    .help("Show \(e.permission) in System Settings")
                }
                .width(24)
                TableColumn("App") { e in Text(appLabel(e)).help(e.client) }
                    .width(min: 140, ideal: 190)
                TableColumn("Permission") { e in Text(e.permission).help(e.service) }
                    .width(min: 150, ideal: 220)
                TableColumn("Status") { e in statusLabel(e.status) }
                    .width(min: 80, ideal: 90)
                TableColumn("Detail") { e in
                    Text(e.target.map { e.service == "kTCCServiceAppleEvents" ? "→ \($0)" : $0 } ?? "")
                }
                TableColumn("Granted by") { e in Text(e.reason ?? "") }
                    .width(min: 80, ideal: 110)
                TableColumn("Scope") { e in Text(e.scope) }
                    .width(min: 50, ideal: 60)
                TableColumn("Last modified") { e in
                    Text(e.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                }
                .width(min: 110, ideal: 150)
            }
            .overlay {
                if visible.isEmpty {
                    Text(showDenied ? "No matching permissions found." : "No granted permissions found. Try “Show denied”.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .toolbar {
            Toggle("Show denied", isOn: $showDenied)
            Button { copyReport() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the list as text")
            Button { report = loadReport() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
        }
        .onAppear { report = loadReport() }
    }

    private var accessBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Can’t read the TCC permission databases").font(.headline)
                Text("Give this app Full Disk Access, then quit and reopen it. Only notification settings are shown until then.")
                ForEach(report.errors, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Open Full Disk Access Settings…") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func appLabel(_ e: Entry) -> String {
        if let path = report.apps[e.client] {
            let name = (path as NSString).lastPathComponent
            return e.client == "com.anthropic.claude-code" ? "\(name) (Claude Code)" : name
        }
        return e.clientIsPath ? (e.client as NSString).lastPathComponent : e.client
    }

    private func statusLabel(_ status: String) -> some View {
        let (symbol, color): (String, Color) = switch status {
        case "allowed": ("checkmark.circle.fill", .green)
        case "limited": ("circle.lefthalf.filled", .yellow)
        case "denied": ("xmark.circle.fill", .red)
        default: ("questionmark.circle", .secondary)
        }
        return Label(status, systemImage: symbol).foregroundStyle(color)
    }

    private func copyReport() {
        var lines = report.apps.sorted(by: { $0.key < $1.key }).map { "\($0.value)  [\($0.key)]" }
        for e in visible {
            var detail = [e.target, e.reason, e.scope].compactMap { $0 }
            if let m = e.modified { detail.append(m.formatted()) }
            lines.append("\(e.client)\t\(e.permission)\t\(e.status)\t\(detail.joined(separator: "; "))")
        }
        lines += report.errors.map { "error: \($0)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
