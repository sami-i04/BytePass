import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Conn: Equatable { case disconnected, connecting(Site), connected(Site) }

    let store = SiteStore()
    let local = PaneModel(kind: .local)
    let remote = PaneModel(kind: .remote)
    @Published var conn: Conn = .disconnected
    @Published var log: [LogLine] = []
    @Published var jobs: [TransferJob] = []
    @Published var settingsTab = 0
    var openWindowHandler: ((String) -> Void)?
    func openSettings(_ tab: Int = 0) { settingsTab = tab; openWindowHandler?("settings") }
    var quickSites: [Site] { store.sites.filter { $0.quick == true } }
    let backups = BackupStore()
    @Published var treeRoot: TreeNode?
    @Published var activityTab = 0
    @Published var appearance = UserDefaults.standard.integer(forKey: "appearance")
    @Published var lastSiteID: UUID? = UUID(uuidString: UserDefaults.standard.string(forKey: "lastSite") ?? "")
    private(set) var session: SFTPSession?
    private var bag = Set<AnyCancellable>()
    private let maxParallel = 2

    init() {
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        Task { await load(local, FileManager.default.homeDirectoryForCurrentUser.path, record: false) }
    }

    var isConnected: Bool { if case .connected = conn { return true }; return false }
    var currentSite: Site? {
        switch conn { case .connected(let s), .connecting(let s): return s; case .disconnected: return nil }
    }
    var activeJobs: Int { jobs.filter(\.isActive).count }

    func addLog(_ kind: LogLine.Kind, _ text: String) {
        log.append(LogLine(kind: kind, text: text))
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
        osLog.info("\(text, privacy: .public)")
        Debug.write("LOG  " + text)
    }

    func connect(_ site: Site) {
        disconnect(silent: true)
        let pw = store.password(for: site)
        let s = SFTPSession(site: site, password: pw)
        s.onLog = { kind, text in DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.addLog(kind, text) } } }
        s.onDrop = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = AppModel.shared
                    guard m.session === s else { return }
                    m.addLog(.error, String(localized: "Verbindung zum Server wurde getrennt."))
                    m.session = nil; m.conn = .disconnected; m.remote.items = []
                }
            }
        }
        session = s
        conn = .connecting(site)
        lastSiteID = site.id
        UserDefaults.standard.set(site.id.uuidString, forKey: "lastSite")
        addLog(.command, String(localized: "Verbinde mit \(site.user)@\(site.host):\(site.port) (SFTP) …"))
        Task {
            do {
                try await s.connect()
                guard session === s else { return }
                conn = .connected(site)
                addLog(.success, String(localized: "Verbunden. Startverzeichnis: \(s.home)"))
                let start = site.remoteDir.isEmpty ? s.home : site.remoteDir
                remote.history = []; remote.forward = []
                treeRoot = TreeNode(path: "/")
                await load(remote, start, record: false)
                if remote.path.isEmpty && start != s.home { await load(remote, s.home, record: false) }
                if !site.localDir.isEmpty { await load(local, (site.localDir as NSString).expandingTildeInPath, record: true) }
            } catch {
                guard session === s else { return }
                s.disconnect()
                session = nil
                conn = .disconnected
                addLog(.error, error.localizedDescription)
                Prompt.info(String(localized: "Verbindung fehlgeschlagen"), error.localizedDescription)
            }
        }
    }

    func disconnect(silent: Bool = false) {
        for j in jobs where j.isActive { cancel(j) }
        session?.disconnect()
        if session != nil && !silent { addLog(.info, String(localized: "Verbindung getrennt.")) }
        session = nil
        conn = .disconnected
        remote.items = []; remote.path = ""; remote.selection = []; remote.history = []; remote.forward = []; treeRoot = nil
    }

    func navigate(_ pane: PaneModel, to path: String) {
        Task { await load(pane, path, record: true) }
    }

    func load(_ pane: PaneModel, _ rawPath: String, record: Bool) async {
        let path: String
        if pane.kind == .local {
            path = ((rawPath as NSString).expandingTildeInPath as NSString).standardizingPath
        } else {
            path = RPath.normalize(rawPath.hasPrefix("/") ? rawPath : RPath.join(pane.path.isEmpty ? "/" : pane.path, rawPath))
        }
        pane.loading = true
        Debug.write("NAV  \(pane.kind == .local ? "lokal" : "server") → \(path)")
        defer { pane.loading = false; Debug.write("NAV  fertig \(path)") }
        do {
            let items: [FileItem]
            if pane.kind == .local {
                items = try PaneModel.listLocal(path)
            } else {
                guard let s = session else { return }
                items = try await s.list(path)
                addLog(.info, String(localized: "Verzeichnisinhalt von „\(path)“ abgerufen (\(items.count) Einträge)."))
            }
            if record && !pane.path.isEmpty && pane.path != path { pane.history.append(pane.path); pane.forward = [] }
            if pane.path != path { pane.selection = [] }
            pane.path = path
            pane.items = items
            pane.selection = pane.selection.filter { id in items.contains { $0.id == id } }
            pane.error = nil
            if pane.kind == .remote { await revealInTree(path, items: items) }
        } catch {
            pane.error = error.localizedDescription
            addLog(.error, "„\(path)“: \(error.localizedDescription)")
        }
    }

    func refresh(_ pane: PaneModel) { Task { await load(pane, pane.path, record: false) } }
    func goUp(_ pane: PaneModel) {
        let p = pane.kind == .local ? (pane.path as NSString).deletingLastPathComponent : RPath.parent(pane.path)
        if p != pane.path && !p.isEmpty { navigate(pane, to: p) }
    }
    func goBack(_ pane: PaneModel) {
        guard let p = pane.history.popLast() else { return }
        if !pane.path.isEmpty { pane.forward.append(pane.path) }
        Task { await load(pane, p, record: false) }
    }
    func goForward(_ pane: PaneModel) {
        guard let p = pane.forward.popLast() else { return }
        if !pane.path.isEmpty { pane.history.append(pane.path) }
        Task { await load(pane, p, record: false) }
    }

    func open(_ item: FileItem, in pane: PaneModel) {
        if item.isDir || (item.isLink && pane.kind == .remote) {
            if item.isLink && !item.isDir {
                let p = pane.fullPath(item.name)
                Task {
                    if let s = session, (try? await s.list(p)) != nil { await load(pane, p, record: true) }
                    else { transfer([item], from: pane) }
                }
                return
            }
            navigate(pane, to: pane.fullPath(item.name))
        } else {
            transfer([item], from: pane)
        }
    }

    func loadChildren(_ node: TreeNode) async {
        guard let s = session else { return }
        node.loading = true
        defer { node.loading = false }
        if let items = try? await s.list(node.path) { node.setChildren(from: items) } else { node.children = [] }
    }

    func toggle(_ node: TreeNode) {
        if node.expanded { node.expanded = false; return }
        node.expanded = true
        if node.children == nil { Task { await loadChildren(node) } }
    }

    func revealInTree(_ path: String, items: [FileItem]) async {
        guard var node = treeRoot else { return }
        Debug.write("TREE reveal \(path)")
        for comp in path.split(separator: "/") {
            if node.children == nil { await loadChildren(node) }
            node.expanded = true
            let next = RPath.join(node.path, String(comp))
            guard let child = node.children?.first(where: { $0.path == next }) else {
                let n = TreeNode(path: next)
                node.children = ((node.children ?? []) + [n]).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                node = n; continue
            }
            node = child
        }
        node.setChildren(from: items)
        node.expanded = true
    }

    func setAppearance(_ i: Int) {
        appearance = i
        UserDefaults.standard.set(i, forKey: "appearance")
        NSApp.appearance = i == 1 ? NSAppearance(named: .aqua) : i == 2 ? NSAppearance(named: .darkAqua) : nil
    }

    func newFolder(in pane: PaneModel) {
        guard let name = Prompt.text(String(localized: "Neuer Ordner"), String(localized: "Name des neuen Ordners in „\(pane.path)“:"), initial: String(localized: "Neuer Ordner"), ok: String(localized: "Erstellen")),
              !name.isEmpty else { return }
        let p = pane.fullPath(name)
        if pane.kind == .local {
            do { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: false); refresh(pane) }
            catch { Prompt.info(String(localized: "Ordner konnte nicht erstellt werden"), error.localizedDescription) }
        } else {
            remoteOp(String(localized: "Ordner erstellen"), ["mkdir \(sq(p))"], log: String(localized: "Ordner „\(p)“ erstellt."))
        }
    }

    func rename(_ item: FileItem, in pane: PaneModel) {
        guard let name = Prompt.text(String(localized: "Umbenennen"), String(localized: "Neuer Name für „\(item.name)“:"), initial: item.name, ok: String(localized: "Umbenennen")),
              !name.isEmpty, name != item.name else { return }
        let from = pane.fullPath(item.name), to = pane.fullPath(name)
        if pane.kind == .local {
            do { try FileManager.default.moveItem(atPath: from, toPath: to); refresh(pane) }
            catch { Prompt.info(String(localized: "Umbenennen fehlgeschlagen"), error.localizedDescription) }
        } else {
            remoteOp(String(localized: "Umbenennen"), ["rename \(sq(from)) \(sq(to))"], log: String(localized: "„\(from)“ → „\(to)“ umbenannt."))
        }
    }

    func delete(_ items: [FileItem], in pane: PaneModel) {
        guard !items.isEmpty else { return }
        let what = items.count == 1 ? "„\(items[0].name)“" : String(localized: "\(items.count) Elemente")
        if pane.kind == .local {
            guard Prompt.confirm(String(localized: "\(what) in den Papierkorb legen?"), "", ok: String(localized: "In den Papierkorb")) else { return }
            NSWorkspace.shared.recycle(items.map { URL(fileURLWithPath: pane.fullPath($0.name)) }) { _, err in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let err { Prompt.info(String(localized: "Löschen fehlgeschlagen"), err.localizedDescription) }
                        AppModel.shared.refresh(pane)
                    }
                }
            }
            return
        }
        guard let s = session,
              Prompt.confirm(String(localized: "\(what) endgültig vom Server löschen?"),
                             String(localized: "Dies kann nicht rückgängig gemacht werden. Ordner werden mit ihrem gesamten Inhalt gelöscht."),
                             ok: String(localized: "Löschen"), destructive: true) else { return }
        let base = pane.path
        Task {
            pane.loading = true
            defer { pane.loading = false }
            do {
                var files: [String] = [], dirs: [String] = []
                for it in items {
                    let p = RPath.join(base, it.name)
                    if it.isDir {
                        let tree = try await walkRemote(s, p)
                        files += tree.files.map { RPath.join(p, $0.rel) }
                        dirs += tree.dirs.map { RPath.join(p, $0) }
                    } else { files.append(p) }
                }
                let cmds = files.map { "rm \(sq($0))" } + dirs.sorted { $0.count > $1.count }.map { "rmdir \(sq($0))" }
                addLog(.command, String(localized: "Lösche \(files.count) Dateien und \(dirs.count) Ordner …"))
                try await s.batch(cmds, timeout: nil)
                addLog(.success, String(localized: "\(what) gelöscht."))
            } catch {
                addLog(.error, String(localized: "Löschen fehlgeschlagen: \(error.localizedDescription)"))
                Prompt.info(String(localized: "Löschen fehlgeschlagen"), error.localizedDescription)
            }
            await load(pane, pane.path, record: false)
        }
    }

    private func remoteOp(_ title: String, _ cmds: [String], log text: String) {
        guard let s = session else { return }
        Task {
            do { try await s.batch(cmds); addLog(.success, text) }
            catch { addLog(.error, "\(title): \(error.localizedDescription)"); Prompt.info(String(localized: "\(title) fehlgeschlagen"), error.localizedDescription) }
            await load(remote, remote.path, record: false)
        }
    }

    func walkRemote(_ s: SFTPSession, _ root: String) async throws -> (dirs: [String], files: [(rel: String, size: Int64)]) {
        var dirs = [""], files: [(rel: String, size: Int64)] = []
        var level = [""]
        while !level.isEmpty {
            let listings = try await s.listMany(level.map { RPath.join(root, $0) })
            var next: [String] = []
            for (rel, items) in zip(level, listings) {
                for it in items {
                    let r = rel.isEmpty ? it.name : rel + "/" + it.name
                    if it.isDir { dirs.append(r); next.append(r) }
                    else if it.isLink { addLog(.info, String(localized: "Symbolischer Link übersprungen: \(r)")) }
                    else { files.append((r, it.size)) }
                }
            }
            level = next
        }
        return (dirs, files)
    }

    func transfer(_ items: [FileItem], from pane: PaneModel) {
        guard isConnected else { Prompt.info(String(localized: "Nicht verbunden"), String(localized: "Verbinde dich zuerst mit einem Server.")); return }
        if pane.kind == .local {
            enqueueUploads(items.map { (pane.fullPath($0.name), $0.isDir) }, to: remote.path)
        } else {
            enqueueDownloads(items.map { (RPath.join(pane.path, $0.name), $0.isDir, $0.size) }, to: local.path)
        }
    }

    func enqueueUploads(_ entries: [(path: String, isDir: Bool)], to remoteDir: String) {
        guard isConnected, !remoteDir.isEmpty else { return }
        Task {
            var entries = entries
            let existing: Set<String>
            if remoteDir == remote.path { existing = Set(remote.items.map(\.name)) }
            else { existing = Set(((try? await session?.list(remoteDir)) ?? []).map(\.name)) }
            let conflicts = entries.filter { existing.contains(($0.path as NSString).lastPathComponent) }
            if !conflicts.isEmpty {
                switch Prompt.overwrite(conflicts.map { ($0.path as NSString).lastPathComponent }) {
                case .cancel: return
                case .skip: entries.removeAll { existing.contains(($0.path as NSString).lastPathComponent) }
                case .overwrite: break
                }
            }
            for e in entries {
                let name = (e.path as NSString).lastPathComponent
                let size = (try? FileManager.default.attributesOfItem(atPath: e.path)[.size] as? NSNumber)??.int64Value ?? 0
                jobs.append(TransferJob(direction: .upload, name: name, localPath: e.path,
                                        remotePath: RPath.join(remoteDir, name), isDir: e.isDir, size: size))
            }
            pump()
        }
    }

    func enqueueDownloads(_ entries: [(path: String, isDir: Bool, size: Int64)], to localDir: String) {
        guard isConnected else { return }
        var entries = entries
        let conflicts = entries.filter {
            FileManager.default.fileExists(atPath: (localDir as NSString).appendingPathComponent(RPath.name($0.path)))
        }
        if !conflicts.isEmpty {
            switch Prompt.overwrite(conflicts.map { RPath.name($0.path) }) {
            case .cancel: return
            case .skip: entries.removeAll { e in conflicts.contains { $0.path == e.path } }
            case .overwrite: break
            }
        }
        for e in entries {
            let name = RPath.name(e.path)
            jobs.append(TransferJob(direction: .download, name: name,
                                    localPath: (localDir as NSString).appendingPathComponent(name),
                                    remotePath: e.path, isDir: e.isDir, size: e.size))
        }
        pump()
    }

    func runAndWait(_ job: TransferJob) async -> Bool {
        await withCheckedContinuation { cont in
            job.onFinish = { ok in cont.resume(returning: ok) }
            jobs.append(job)
            pump()
        }
    }

    func cancel(_ job: TransferJob) {
        job.cancelled = true
        job.proc?.cancel()
        if job.state == .waiting { job.state = .cancelled; job.onFinish?(false); job.onFinish = nil }
    }
    func remove(_ job: TransferJob) { jobs.removeAll { $0.id == job.id } }
    func clearFinished() { jobs.removeAll { !$0.isActive } }
    func retry(_ job: TransferJob) {
        let j = TransferJob(direction: job.direction, name: job.name, localPath: job.localPath,
                            remotePath: job.remotePath, isDir: job.isDir, size: job.knownSize)
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = j } else { jobs.append(j) }
        pump()
    }

    private func pump() {
        let running = jobs.filter { $0.state == .running || $0.state == .preparing }.count
        guard running < maxParallel, let next = jobs.first(where: { $0.state == .waiting }) else { return }
        next.state = .preparing
        Task { await run(next); pump() }
        pump()
    }

    private func run(_ job: TransferJob) async {
        guard let s = session else { job.state = .failed(String(localized: "Nicht verbunden")); return }
        job.started = Date()
        let arrow = job.direction == .upload ? String(localized: "Hochladen") : String(localized: "Herunterladen")
        addLog(.command, "\(arrow): \(job.direction == .upload ? job.localPath : job.remotePath)")
        do {
            var cmds: [String] = []
            var files: [(target: String, size: Int64)] = []
            switch job.direction {
            case .upload:
                if job.isDir {
                    cmds.append("-mkdir \(sq(job.remotePath))")
                    let en = FileManager.default.enumerator(atPath: job.localPath)
                    while let rel = en?.nextObject() as? String {
                        let attrs = en?.fileAttributes
                        let type = attrs?[.type] as? FileAttributeType
                        if type == .typeDirectory {
                            cmds.append("-mkdir \(sq(RPath.join(job.remotePath, rel)))")
                        } else if type == .typeRegular, (rel as NSString).lastPathComponent != ".DS_Store" {
                            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                            let r = RPath.join(job.remotePath, rel)
                            cmds.append("\(job.tolerant ? "-" : "")put \(sq((job.localPath as NSString).appendingPathComponent(rel))) \(sq(r))")
                            files.append((r, size))
                        }
                    }
                } else {
                    cmds.append("\(job.tolerant ? "-" : "")put \(sq(job.localPath)) \(sq(job.remotePath))")
                    files.append((job.remotePath, job.knownSize))
                }
            case .download:
                if job.isDir {
                    let tree = try await walkRemote(s, job.remotePath)
                    for d in tree.dirs {
                        try FileManager.default.createDirectory(atPath: (job.localPath as NSString).appendingPathComponent(d),
                                                                withIntermediateDirectories: true)
                    }
                    for f in tree.files {
                        let l = (job.localPath as NSString).appendingPathComponent(f.rel)
                        cmds.append("\(job.tolerant ? "-" : "")get \(sq(RPath.join(job.remotePath, f.rel))) \(sq(l))")
                        files.append((l, f.size))
                    }
                } else {
                    cmds.append("\(job.tolerant ? "-" : "")get \(sq(job.remotePath)) \(sq(job.localPath))")
                    files.append((job.localPath, job.knownSize))
                }
            }
            if job.cancelled { job.state = .cancelled; return }

            job.filesTotal = files.count
            job.totalBytes = files.reduce(0) { $0 + $1.size }
            job.state = .running

            let index = Box(-1)
            var base: Int64 = 0
            let fileList = files
            let proc = LineProcess()
            job.proc = proc

            let ticker = Task { @MainActor in
                var lastBytes: Int64 = 0, lastTime = Date(), lastRemote = Date.distantPast
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let i = index.value
                    guard i >= 0, i < fileList.count else { continue }
                    let f = fileList[i]
                    var partial: Int64 = 0
                    if job.direction == .download {
                        partial = ((try? FileManager.default.attributesOfItem(atPath: f.target))?[.size] as? NSNumber)?.int64Value ?? 0
                    } else if f.size > 1_000_000, Date().timeIntervalSince(lastRemote) > 1 {
                        lastRemote = Date()
                        partial = await s.size(of: f.target) ?? 0
                    } else { continue }
                    guard index.value == i else { continue }
                    job.doneBytes = base + min(partial, f.size)
                    let now = Date(), dt = now.timeIntervalSince(lastTime)
                    if dt > 0 {
                        let inst = Double(max(0, job.doneBytes - lastBytes)) / dt
                        job.speed = job.speed == 0 ? inst : job.speed * 0.7 + inst * 0.3
                    }
                    lastBytes = job.doneBytes; lastTime = now
                }
            }
            defer { ticker.cancel() }

            try await s.batch(cmds, proc: proc, timeout: nil) { line in
                guard line.hasPrefix("sftp> put ") || line.hasPrefix("sftp> get ") || line.hasPrefix("sftp> -put ") || line.hasPrefix("sftp> -get ") else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let i = index.value
                        if i >= 0 && i < fileList.count { base += fileList[i].size; job.filesDone += 1 }
                        index.value = i + 1
                        job.doneBytes = base
                        if i + 1 < fileList.count { job.currentFile = (fileList[i + 1].target as NSString).lastPathComponent }
                    }
                }
            }
            await Task.yield()
            job.filesDone = files.count
            job.doneBytes = job.totalBytes
            job.state = .done
            addLog(.success, files.count == 1 ? String(localized: "Übertragung erfolgreich: \(job.name) (1 Datei, \(Fmt.size(job.totalBytes)))") : String(localized: "Übertragung erfolgreich: \(job.name) (\(files.count) Dateien, \(Fmt.size(job.totalBytes)))"))
        } catch {
            if job.cancelled { job.state = .cancelled; addLog(.info, String(localized: "Abgebrochen: \(job.name)")) }
            else { job.state = .failed(error.localizedDescription); addLog(.error, String(localized: "Fehler bei \(job.name): \(error.localizedDescription)")) }
        }
        job.proc = nil
        job.onFinish?(job.state == .done)
        job.onFinish = nil
        if job.direction == .upload, remote.path == RPath.parent(job.remotePath) { await load(remote, remote.path, record: false) }
        if job.direction == .download, local.path == (job.localPath as NSString).deletingLastPathComponent { await load(local, local.path, record: false) }
    }

    nonisolated static let dragType = UTType(importedAs: "de.dateizilla.items")

    func dragProvider(for item: FileItem, in pane: PaneModel) -> NSItemProvider {
        let items = pane.selection.contains(item.id) ? pane.selectedItems : [item]
        let provider = NSItemProvider()
        let s: String
        if pane.kind == .local {
            s = "dzlocal\n" + items.map { "\($0.isDir ? "D" : "F")\t\(pane.fullPath($0.name))" }.joined(separator: "\n")
            if items.count == 1 {
                let url = URL(fileURLWithPath: pane.fullPath(items[0].name))
                provider.registerObject(url as NSURL, visibility: .all)
                provider.suggestedName = url.lastPathComponent
            }
        } else {
            s = "dzremote\n" + items.map { "\($0.isDir ? "D" : "F")\t\(pane.fullPath($0.name))\t\($0.size)" }.joined(separator: "\n")
        }
        let data = Data(s.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.dragType.identifier, visibility: .ownProcess) { c in
            c(data, nil); return nil
        }
        return provider
    }

    var remoteDragActive = false

    func beginRemoteDrag(for item: FileItem, in pane: PaneModel) {
        guard !remoteDragActive, let event = NSApp.currentEvent,
              let view = (event.window ?? NSApp.keyWindow)?.contentView else { return }
        remoteDragActive = true
        let items = pane.selection.contains(item.id) ? pane.selectedItems : [item]
        let origin = view.convert(event.locationInWindow, from: nil)
        let dragItems: [NSDraggingItem] = items.enumerated().map { i, it in
            let entry = RemotePromise.Entry(path: pane.fullPath(it.name), isDir: it.isDir, size: it.size)
            let p = RemotePromise(entry: entry)
            let di = NSDraggingItem(pasteboardWriter: p)
            di.setDraggingFrame(NSRect(x: origin.x - 16 + CGFloat(i * 4), y: origin.y - 16 - CGFloat(i * 4), width: 32, height: 32),
                                contents: Icons.icon(it))
            return di
        }
        view.beginDraggingSession(with: dragItems, event: event, source: DragSource.shared)
    }

    func handleDrop(_ providers: [NSItemProvider], onto pane: PaneModel) -> Bool {
        let group = DispatchGroup()
        let urls = Box<[URL]>([]), texts = Box<[String]>([])
        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(Self.dragType.identifier) {
                _ = p.loadDataRepresentation(forTypeIdentifier: Self.dragType.identifier) { data, _ in
                    DispatchQueue.main.async { if let data { texts.value.append(String(decoding: data, as: UTF8.self)) }; group.leave() }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async { if let url { urls.value.append(url) }; group.leave() }
                }
            } else {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    DispatchQueue.main.async { if let s = obj as? String { texts.value.append(s) }; group.leave() }
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let m = AppModel.shared
                if pane.kind == .remote {
                    var entries: [(path: String, isDir: Bool)] = urls.value.map { u in
                        var d: ObjCBool = false
                        FileManager.default.fileExists(atPath: u.path, isDirectory: &d)
                        return (u.path, d.boolValue)
                    }
                    for t in texts.value where t.hasPrefix("dzlocal\n") {
                        for l in t.split(separator: "\n").dropFirst() {
                            let c = l.split(separator: "\t", maxSplits: 1).map(String.init)
                            if c.count == 2 { entries.append((c[1], c[0] == "D")) }
                        }
                    }
                    if !entries.isEmpty { m.enqueueUploads(entries, to: m.remote.path) }
                } else {
                    var entries: [(path: String, isDir: Bool, size: Int64)] = []
                    for t in texts.value where t.hasPrefix("dzremote\n") {
                        for l in t.split(separator: "\n").dropFirst() {
                            let c = l.split(separator: "\t").map(String.init)
                            if c.count >= 2 { entries.append((c[1], c[0] == "D", Int64(c.count > 2 ? c[2] : "0") ?? 0)) }
                        }
                    }
                    if !entries.isEmpty { m.enqueueDownloads(entries, to: m.local.path) }
                }
            }
        }
        return true
    }
}
