import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

final class SFTPSession: @unchecked Sendable {
    let site: Site
    private let password: String
    let sock: String
    private var master: Process?
    private let masterErr = Box("")
    private(set) var home = "/"
    var onLog: (@Sendable (LogLine.Kind, String) -> Void)?
    var onDrop: (@Sendable () -> Void)?
    private var closing = false
    private var ready = false

    init(site: Site, password: String) {
        self.site = site
        self.password = password
        sock = "/tmp/dz-\(getpid())-\(UInt32.random(in: 1...UInt32.max)).sock"
    }

    private var target: String { "\(site.user)@\(site.host)" }
    private var baseOpts: [String] {
        ["-o", "StrictHostKeyChecking=accept-new", "-o", "ControlPath=\(sock)", "-o", "LogLevel=ERROR"]
    }

    private var isTest: Bool { site.host == "__localtest__" }

    func connect() async throws {
        if isTest { home = (try? await batch(["pwd"]))?.components(separatedBy: "directory: ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/"; return }
        let plan: [(family: String, limit: Double)] = [("any", 12), ("inet", 12), ("inet6", 12), ("inet", 20)]
        var lastError: Error = SFTPError(String(localized: "Verbindung fehlgeschlagen."))
        for (i, step) in plan.enumerated() {
            if closing { throw SFTPError(String(localized: "Abgebrochen."), fatal: true) }
            if i > 0 {
                onLog?(.info, String(localized: "Neuer Verbindungsversuch \(i + 1)/\(plan.count) (\(step.family == "inet" ? "IPv4" : step.family == "inet6" ? "IPv6" : "automatisch")) …"))
            }
            do {
                try await startMaster(family: step.family, limit: step.limit)
                try await fetchHome()
                return
            } catch let e as SFTPError where e.fatal {
                stopMaster(); throw e
            } catch {
                lastError = error
                Debug.write("CONNECT Versuch \(i + 1) fehlgeschlagen: \(error.localizedDescription)")
                stopMaster()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw lastError
    }

    private func stopMaster() {
        if let m = master, m.isRunning {
            m.terminationHandler = nil
            m.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if m.isRunning { kill(m.processIdentifier, SIGKILL) } }
        }
        master = nil
        try? FileManager.default.removeItem(atPath: sock)
    }

    private func startMaster(family: String, limit: Double) async throws {
        try? FileManager.default.removeItem(atPath: sock)
        masterErr.value = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-v", "-M", "-N", "-p", "\(site.port)",
                       "-o", "AddressFamily=\(family)",
                       "-o", "ControlPersist=no", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
                       "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "TCPKeepAlive=yes",
                       "-o", "NumberOfPasswordPrompts=1", "-o", "BatchMode=no",
                       "-o", "PreferredAuthentications=password,keyboard-interactive,publickey",
                       "-o", "GSSAPIAuthentication=no", "-o", "UseKeychain=no", "-o", "UpdateHostKeys=no"] + baseOpts + [target]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = AppPaths.askpass.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"
        env["DZ_SECRET"] = password
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        let box = masterErr
        let log = onLog
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            box.value += s
            for l in s.split(whereSeparator: \.isNewline) {
                Debug.write("ssh: " + l)
                if !l.hasPrefix("debug") && !l.contains("Permanently added") { log?(.info, "ssh: " + l) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self, !self.closing, self.ready else { return }
            self.onDrop?()
        }
        try p.run()
        master = p

        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if closing { throw SFTPError(String(localized: "Abgebrochen."), fatal: true) }
            if !p.isRunning {
                let msg = box.value.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("debug") }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let all = box.value
                if all.contains("Permission denied") || all.contains("Authentication failed") || all.contains("Too many authentication failures") {
                    throw SFTPError(Self.friendly("Permission denied"), fatal: true)
                }
                if all.contains("Could not resolve hostname") || all.contains("HOST IDENTIFICATION HAS CHANGED") {
                    throw SFTPError(Self.friendly(all), fatal: true)
                }
                throw SFTPError(msg.isEmpty ? String(localized: "Verbindung fehlgeschlagen.") : Self.friendly(msg))
            }
            if box.value.contains("Authenticated to") || box.value.contains("Authentication succeeded") || FileManager.default.fileExists(atPath: sock) {
                let r = await LineProcess().run("/usr/bin/ssh", ["-S", sock, "-O", "check", target], timeout: 3)
                if r.status == 0 { ready = true; return }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw SFTPError(String(localized: "Zeitüberschreitung beim Verbindungsaufbau."))
    }

    private func fetchHome() async throws {
        var out = ""
        for attempt in 1...4 {
            do { out = try await batch(["pwd"], timeout: 6); break }
            catch {
                if attempt == 4 || master?.isRunning != true { throw error }
                onLog?(.info, String(localized: "Server antwortet noch nicht – neuer Versuch (\(attempt + 1)/4) …"))
                try await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        if let l = out.split(separator: "\n").first(where: { $0.hasPrefix("Remote working directory:") }) {
            home = l.replacingOccurrences(of: "Remote working directory:", with: "").trimmingCharacters(in: .whitespaces)
        }
    }

    static func friendly(_ msg: String) -> String {
        if msg.contains("Permission denied") { return String(localized: "Anmeldung fehlgeschlagen – Benutzername oder Passwort falsch.") }
        if msg.contains("Could not resolve hostname") { return String(localized: "Server nicht gefunden – Hostname prüfen.") }
        if msg.contains("timed out") { return String(localized: "Zeitüberschreitung – Server nicht erreichbar.") }
        if msg.contains("Connection refused") { return String(localized: "Verbindung abgelehnt – Port prüfen.") }
        if msg.contains("HOST IDENTIFICATION HAS CHANGED") { return String(localized: "Host-Schlüssel des Servers hat sich geändert (~/.ssh/known_hosts prüfen).") }
        return msg
    }

    func disconnect() {
        closing = true
        if let m = master, m.isRunning {
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            x.arguments = ["-S", sock, "-O", "exit", target]
            x.standardOutput = FileHandle.nullDevice; x.standardError = FileHandle.nullDevice
            try? x.run(); x.waitUntilExit()
            if m.isRunning { m.terminate() }
        }
        master = nil
        try? FileManager.default.removeItem(atPath: sock)
    }

    func sftpArgs() -> [String] {
        if isTest { return ["-b", "-", "-D", "/usr/libexec/sftp-server"] }
        return ["-b", "-", "-P", "\(site.port)", "-o", "ControlMaster=no"] + baseOpts + [target]
    }

    @discardableResult
    func batch(_ cmds: [String], proc: LineProcess = LineProcess(), timeout: Double? = 45,
               onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let t0 = Date()
        Debug.write("SFTP > " + cmds.prefix(5).joined(separator: " | ") + (cmds.count > 5 ? " … (\(cmds.count))" : ""))
        let r = await proc.run("/usr/bin/sftp", sftpArgs(), input: cmds.joined(separator: "\n") + "\n", env: ["LC_ALL": "C", "LANG": "C"], timeout: timeout, onLine: onLine)
        Debug.write(String(format: "SFTP < Code %d in %.2fs, %d Bytes", r.status, Date().timeIntervalSince(t0), r.out.utf8.count))
        Debug.write("  OUT: " + r.out.prefix(1500).replacingOccurrences(of: "\n", with: "\n       "))
        if !r.err.isEmpty { Debug.write("  ERR: " + r.err.prefix(800)) }
        if r.status == 15 || (r.status != 0 && proc.timedOut) { throw SFTPError(String(localized: "Zeitüberschreitung – Server antwortet nicht.")) }
        if r.status != 0 {
            let e = r.err.split(whereSeparator: \.isNewline)
                .filter { !$0.contains("Connection closed") && !$0.hasPrefix("Warning:") }
                .joined(separator: "\n")
            throw SFTPError(e.isEmpty ? (r.status == 15 ? String(localized: "Zeitüberschreitung – Server antwortet nicht.") : String(localized: "sftp-Befehl fehlgeschlagen (Code \(r.status)).")) : e)
        }
        return r.out
    }

    func list(_ path: String) async throws -> [FileItem] {
        let out: String
        do { out = try await batch(["ls -lan \(sq(path))"], timeout: 15) }
        catch let e as SFTPError where e.message.hasPrefix(String(localized: "Zeitüberschreitung")) {
            onLog?(.info, String(localized: "Keine Antwort – Verzeichnis wird erneut abgefragt …"))
            out = try await batch(["ls -lan \(sq(path))"], timeout: 20)
        }
        let items = Self.parseListing(out)
        if items.isEmpty {
            let raw = out.split(separator: "\n").filter { !$0.hasPrefix("sftp>") }.prefix(5)
            for l in raw { onLog?(.info, String(localized: "Unerkannte Zeile: \(l)")) }
        }
        return items
    }

    func listMany(_ paths: [String]) async throws -> [[FileItem]] {
        guard !paths.isEmpty else { return [] }
        let out = try await batch(paths.map { "-ls -lan \(sq($0))" })
        var result: [[FileItem]] = []
        var current: [String]? = nil
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("sftp> ") {
                if let c = current { result.append(Self.parseListing(c.joined(separator: "\n"))) }
                current = []
            } else { current?.append(String(line)) }
        }
        if let c = current { result.append(Self.parseListing(c.joined(separator: "\n"))) }
        while result.count < paths.count { result.append([]) }
        return result
    }

    func size(of path: String) async -> Int64? {
        guard let out = try? await batch(["ls -ln \(sq(path))"]) else { return nil }
        return Self.parseListing(out, keepAll: true).first?.size
    }

    private static let lsRegex = try! NSRegularExpression(pattern:
        #"^([\-dlcbps])([rwxsStT\-]{9})\S*\s+\S+\s+\S+\s+\S+\s+(\d+)\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.+)$"#)
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func parseListing(_ out: String, keepAll: Bool = false) -> [FileItem] {
        var items: [FileItem] = []
        let cal = Calendar.current
        let now = Date()
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            guard let m = lsRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let g = { (i: Int) in ns.substring(with: m.range(at: i)) }
            let type = g(1)
            var name = g(7)
            let isLink = type == "l"
            if isLink, let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
            if !keepAll {
                if name.contains("/") { name = String(name.split(separator: "/").last ?? "") }
                if name == "." || name == ".." { continue }
            }
            var comps = DateComponents()
            comps.month = (months.firstIndex(of: g(4).lowercased()) ?? 0) + 1
            comps.day = Int(g(5))
            let t = g(6)
            if t.contains(":") {
                let hm = t.split(separator: ":")
                comps.hour = Int(hm[0]); comps.minute = Int(hm[1])
                comps.year = cal.component(.year, from: now)
                if let d = cal.date(from: comps), d > now.addingTimeInterval(86400 * 2) { comps.year! -= 1 }
            } else { comps.year = Int(t) }
            items.append(FileItem(name: name, isDir: type == "d", isLink: isLink,
                                  size: Int64(g(3)) ?? 0, modified: cal.date(from: comps) ?? .distantPast,
                                  perms: g(1) + g(2)))
        }
        return items
    }
}

struct SFTPError: LocalizedError {
    let message: String
    var fatal = false
    init(_ m: String, fatal: Bool = false) { message = m; self.fatal = fatal }
    var errorDescription: String? { message }
}
