import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

struct BackupMeta: Codable, Identifiable, Hashable {
    var id = UUID()
    var siteName: String
    var host: String
    var user: String
    var home: String
    var remotePath: String
    var full: Bool
    var date: Date
    var size: Int64
    var files: Int
    var encrypted: Bool
    var fileName: String
    var serverKey: String { "\(user)@\(host)" }
    var title: String { full ? String(localized: "Komplett-Backup") : String(localized: "Ordner „\(RPath.name(remotePath))“") }
    var relPath: String {
        let h = home == "/" ? "" : home
        if !h.isEmpty, remotePath.hasPrefix(h + "/") { return String(remotePath.dropFirst(h.count + 1)) }
        if h.isEmpty { return String(remotePath.drop(while: { $0 == "/" })) }
        return RPath.name(remotePath)
    }
}

@MainActor final class BackupStore: ObservableObject {
    @Published var items: [BackupMeta] = []
    @Published var busy: String?
    @Published var job: TransferJob?
    @Published var step = ""
    @Published var encrypt = UserDefaults.standard.bool(forKey: "backupEncrypt") {
        didSet { UserDefaults.standard.set(encrypt, forKey: "backupEncrypt") }
    }
    let dir: URL = {
        let u = AppPaths.support.appendingPathComponent("Backups")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    var tmp: URL { dir.appendingPathComponent(".tmp") }

    init() { reload() }

    func reload() {
        var out: [BackupMeta] = []
        let fm = FileManager.default
        for server in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !server.hasPrefix(".") {
            let sd = dir.appendingPathComponent(server)
            for f in (try? fm.contentsOfDirectory(atPath: sd.path)) ?? [] where f.hasSuffix(".json") {
                if let d = try? Data(contentsOf: sd.appendingPathComponent(f)),
                   let m = try? JSONDecoder().decode(BackupMeta.self, from: d),
                   fm.fileExists(atPath: sd.appendingPathComponent(m.fileName).path) { out.append(m) }
            }
        }
        items = out.sorted { $0.date > $1.date }
    }
    var grouped: [(key: String, name: String, items: [BackupMeta])] {
        Dictionary(grouping: items, by: \.serverKey)
            .map { (key: $0.key, name: $0.value.first?.siteName ?? $0.key, items: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func folder(_ m: BackupMeta) -> URL { dir.appendingPathComponent(Self.slug(m.serverKey)) }
    func file(_ m: BackupMeta) -> URL { folder(m).appendingPathComponent(m.fileName) }
    static func slug(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "@" ? $0 : "_" })
    }

    func create(folder: String? = nil) {
        Task { _ = await createAndWait(folder: folder, askPassword: true) }
    }

    func createAndWait(folder: String?, askPassword: Bool, forceEncrypt: Bool? = nil) async -> Bool {
        let app = AppModel.shared
        guard let s = app.session, case .connected(let site) = app.conn else {
            Prompt.info(String(localized: "Nicht verbunden"), String(localized: "Backups werden immer vom aktuell verbundenen Server erstellt.")); return false
        }
        guard busy == nil else { Prompt.info(String(localized: "Backup läuft bereits"), busy ?? ""); return false }
        var password: String?
        if forceEncrypt ?? encrypt {
            guard askPassword, let p = Prompt.password(String(localized: "Backup mit Passwort schützen"), String(localized: "Das Backup wird als verschlüsseltes Disk-Image (AES-256) gespeichert."), confirm: true) else { return false }
            password = p
        }
        let root = folder ?? s.home
        let id = UUID()
        let work = tmp.appendingPathComponent(id.uuidString)
        let content = work.appendingPathComponent("content")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        busy = String(localized: "Backup von \(site.name) wird heruntergeladen …")
        defer { busy = nil }
        app.addLog(.command, folder == nil ? String(localized: "Backup: kompletter Webspace von \(site.name)") : String(localized: "Backup: \(root) von \(site.name)"))

        let job = TransferJob(direction: .download, name: String(localized: "Backup · \(site.name)\(folder == nil ? "" : " · " + RPath.name(root))"),
                              localPath: content.path, remotePath: root, isDir: true, size: 0)
        job.tolerant = true
        self.job = job
        let okDL = await app.runAndWait(job)
        self.job = nil
        guard okDL else { app.addLog(.error, String(localized: "Backup abgebrochen.")); return false }

        busy = String(localized: "Backup wird gepackt …")
        let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f.string(from: Date()) }()
        let label = folder == nil ? "komplett" : Self.slug(RPath.name(root))
        let name = "\(stamp)_\(label).\(password == nil ? "zip" : "dmg")"
        let meta = BackupMeta(id: id, siteName: site.name, host: site.host, user: site.user, home: s.home, remotePath: root,
                              full: folder == nil, date: Date(), size: 0, files: job.filesTotal, encrypted: password != nil, fileName: name)
        let out = self.folder(meta)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let target = out.appendingPathComponent(name)
        let r: RunResult
        if let pw = password {
            r = await LineProcess().run("/usr/bin/hdiutil", ["create", "-srcfolder", content.path, "-volname", "BytePass Backup",
                                                             "-encryption", "AES-256", "-stdinpass", "-format", "UDZO", "-quiet", target.path],
                                        input: pw + "\u{0}")
        } else {
            r = await LineProcess().run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", content.path, target.path])
        }
        guard r.status == 0 else {
            app.addLog(.error, String(localized: "Packen fehlgeschlagen: \(r.err)"))
            Prompt.info(String(localized: "Backup fehlgeschlagen"), r.err); return false
        }
        var m = meta
        m.size = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: out.appendingPathComponent(name + ".json")) }
        reload()
        app.addLog(.success, String(localized: "Backup gespeichert: \(m.title) von \(site.name) (\(Fmt.size(m.size)))"))
        return true
    }

    func ensureConnected(_ site: Site) async -> Bool {
        let app = AppModel.shared
        if app.isConnected && app.currentSite?.id == site.id { return true }
        app.connect(site)
        for _ in 0..<240 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if app.isConnected { return true }
            if app.conn == .disconnected { return false }
        }
        return false
    }

    func export(_ m: BackupMeta) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(Self.slug(m.siteName))_\(m.fileName)"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? FileManager.default.removeItem(at: u)
        do { try FileManager.default.copyItem(at: file(m), to: u) }
        catch { Prompt.info(String(localized: "Export fehlgeschlagen"), error.localizedDescription) }
    }
    func delete(_ m: BackupMeta) {
        guard Prompt.confirm(String(localized: "Backup löschen?"), String(localized: "\(m.title) von \(m.siteName) vom \(Fmt.date.string(from: m.date)) wird endgültig gelöscht."),
                             ok: String(localized: "Löschen"), destructive: true) else { return }
        try? FileManager.default.removeItem(at: file(m))
        try? FileManager.default.removeItem(at: folder(m).appendingPathComponent(m.fileName + ".json"))
        reload()
    }

    func restore(_ m: BackupMeta, to site: Site, replaceAll: Bool, safetyBackup: Bool, targetPath: String? = nil) {
        Task { await restoreAndWait(m, to: site, replaceAll: replaceAll, safetyBackup: safetyBackup, targetPath: targetPath) }
    }

    private func restoreAndWait(_ m: BackupMeta, to site: Site, replaceAll: Bool, safetyBackup: Bool, targetPath: String? = nil) async {
        let app = AppModel.shared
        guard busy == nil else { return }
        if m.full && replaceAll {
            guard Prompt.confirmTyped(String(localized: "Server „\(site.name)“ komplett ersetzen?"),
                                      String(localized: "Alle eigenen Dateien auf dem Server werden gelöscht und aus dem Backup neu geladen. Geschützte Ordner des Providers bleiben erhalten."),
                                      word: site.name, ok: String(localized: "Ersetzen")) else { return }
        }
        var password: String?
        if m.encrypted {
            guard let p = Prompt.password(String(localized: "Backup entsperren"), String(localized: "Passwort für dieses Backup eingeben."), confirm: false) else { return }
            password = p
        }
        busy = String(localized: "Backup wird entpackt …")
        defer { busy = nil }
        let work = tmp.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var mount: String?
        defer {
            if let mount { _ = Process.launchedProcess(launchPath: "/usr/bin/hdiutil", arguments: ["detach", "-force", "-quiet", mount]).waitUntilExit() }
            try? FileManager.default.removeItem(at: work)
        }
        var source: URL
        if let pw = password {
            let mp = work.appendingPathComponent("mnt")
            try? FileManager.default.createDirectory(at: mp, withIntermediateDirectories: true)
            let r = await LineProcess().run("/usr/bin/hdiutil", ["attach", "-stdinpass", "-nobrowse", "-readonly", "-quiet", "-mountpoint", mp.path, file(m).path],
                                            input: pw + "\u{0}")
            guard r.status == 0 else { Prompt.info(String(localized: "Entsperren fehlgeschlagen"), String(localized: "Passwort falsch oder Backup beschädigt.")); return }
            mount = mp.path
            source = mp
        } else {
            let dest = work.appendingPathComponent("x")
            let r = await LineProcess().run("/usr/bin/ditto", ["-x", "-k", file(m).path, dest.path])
            guard r.status == 0 else { Prompt.info(String(localized: "Entpacken fehlgeschlagen"), r.err); return }
            source = dest
        }
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []).filter { !$0.hasPrefix(".") }
        if entries == ["content"] { source = source.appendingPathComponent("content") }

        busy = String(localized: "Verbinde mit \(site.name) …")
        if app.currentSite?.id != site.id || !app.isConnected {
            app.connect(site)
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if app.isConnected { break }
                if app.conn == .disconnected { break }
            }
        }
        guard app.isConnected, let s = app.session else { Prompt.info(String(localized: "Wiederherstellung abgebrochen"), String(localized: "Keine Verbindung zu \(site.name).")); return }

        let target = targetPath ?? (m.full ? s.home : RPath.join(s.home, m.relPath))

        if m.full && replaceAll {
            if safetyBackup {
                busy = nil
                app.addLog(.info, String(localized: "Sicherheits-Backup von \(site.name) vor dem Ersetzen …"))
                guard await createAndWait(folder: nil, askPassword: false, forceEncrypt: false) else {
                    Prompt.info(String(localized: "Abgebrochen"), String(localized: "Das Sicherheits-Backup konnte nicht erstellt werden – es wurde nichts gelöscht.")); return
                }
            }
            busy = String(localized: "Server-Inhalt wird gelöscht …")
            await wipe(s, target, keepRoot: true)
        } else if !m.full {
            if (try? await s.list(target)) != nil {
                busy = String(localized: "Vorhandener Ordner wird ersetzt …")
                await wipe(s, target, keepRoot: false)
            }
        }

        busy = String(localized: "Backup wird hochgeladen …")
        let job = TransferJob(direction: .upload, name: String(localized: "Wiederherstellung · \(m.title) → \(site.name)"),
                              localPath: source.path, remotePath: target, isDir: true, size: 0)
        job.tolerant = m.full
        self.job = job
        let ok = await app.runAndWait(job)
        self.job = nil
        app.addLog(ok ? .success : .error, ok ? String(localized: "Wiederherstellung abgeschlossen: \(m.title) → \(site.name)") : String(localized: "Wiederherstellung fehlgeschlagen."))
        await app.load(app.remote, app.remote.path.isEmpty ? s.home : app.remote.path, record: false)
    }

    private func wipe(_ s: SFTPSession, _ root: String, keepRoot: Bool) async {
        let app = AppModel.shared
        guard let tree = try? await app.walkRemote(s, root) else { return }
        let files = tree.files.map { "-rm \(sq(RPath.join(root, $0.rel)))" }
        let dirs = tree.dirs.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.map { "-rmdir \(sq(RPath.join(root, $0)))" }
        let cmds = files + dirs + (keepRoot ? [] : ["-rmdir \(sq(root))"])
        app.addLog(.command, String(localized: "Lösche \(tree.files.count) Dateien und \(tree.dirs.count - 1) Ordner in \(root) …"))
        _ = try? await s.batch(cmds, timeout: nil)
    }
}
