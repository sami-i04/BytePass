import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

enum Fmt {
    static let bytes: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()
    static func size(_ b: Int64) -> String { bytes.string(fromByteCount: b) }
    static let date: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("ddMMyyHHmm"); return f
    }()
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
}

enum RPath {
    static func join(_ dir: String, _ name: String) -> String {
        if name.isEmpty { return dir }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
    static func parent(_ p: String) -> String {
        let n = normalize(p)
        guard n != "/", let r = n.range(of: "/", options: .backwards) else { return "/" }
        let s = String(n[..<r.lowerBound]); return s.isEmpty ? "/" : s
    }
    static func name(_ p: String) -> String { String(normalize(p).split(separator: "/").last ?? "") }
    static func normalize(_ p: String) -> String {
        var parts: [Substring] = []
        for c in p.split(separator: "/") {
            if c == "." || c.isEmpty { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }
}

func sq(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

enum Debug {
    static let q = DispatchQueue(label: "dz.debug")
    static let url = AppPaths.support.appendingPathComponent("debug.log")
    static func write(_ s: String) {
        let line = "[\(Fmt.time.string(from: Date()))] \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
