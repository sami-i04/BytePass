import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

@MainActor final class SiteStore: ObservableObject {
    @Published var sites: [Site] = []
    private let url = AppPaths.support.appendingPathComponent("sites.json")

    init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([Site].self, from: d) { sites = s }
    }
    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        guard let d = try? enc.encode(sites) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func password(for s: Site) -> String {
        if let p = sites.first(where: { $0.id == s.id })?.secret { return Self.decode(p) }
        return ""
    }
    func setPassword(_ p: String, for s: Site) {
        guard let i = sites.firstIndex(where: { $0.id == s.id }) else { return }
        sites[i].secret = p.isEmpty ? nil : Self.encode(p)
        save()
    }
    static func encode(_ p: String) -> String { Data(p.utf8).base64EncodedString() }
    static func decode(_ p: String) -> String { Data(base64Encoded: p).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    func migrateKeychain() {
        var changed = false
        for i in sites.indices where sites[i].secret == nil {
            if let p = Keychain.get(sites[i].id.uuidString), !p.isEmpty {
                sites[i].secret = Self.encode(p); Keychain.set("", for: sites[i].id.uuidString); changed = true
            }
        }
        if changed { save() }
    }
    func upsert(_ s: Site) {
        if let i = sites.firstIndex(where: { $0.id == s.id }) { sites[i] = s } else { sites.append(s) }
        save()
    }
    func remove(_ s: Site) {
        sites.removeAll { $0.id == s.id }
        save()
    }

    func importEnv(_ url: URL) -> Site? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var kv: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let sep = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let k = line[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
            var v = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            kv[k] = v
        }
        guard var host = kv["server"] ?? kv["host"] ?? kv["sftp_host"],
              let user = kv["user"] ?? kv["username"] ?? kv["sftp_user"] else { return nil }
        for p in ["sftp://", "ssh://"] where host.hasPrefix(p) { host = String(host.dropFirst(p.count)) }
        var port = Int(kv["port"] ?? "") ?? 22
        if let c = host.lastIndex(of: ":"), let p = Int(host[host.index(after: c)...]) { port = p; host = String(host[..<c]) }
        if let existing = sites.first(where: { $0.host == host && $0.user == user }) {
            if let pw = kv["passwd"] ?? kv["password"] ?? kv["pass"] { setPassword(pw, for: existing) }
            return existing
        }
        let site = Site(name: host.components(separatedBy: ".").first.map { String(localized: "Webspace (\($0))") } ?? host,
                        host: host, port: port, user: user)
        upsert(site)
        if let pw = kv["passwd"] ?? kv["password"] ?? kv["pass"] { setPassword(pw, for: site) }
        return site
    }
}
