import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

struct FileItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDir: Bool
    let isLink: Bool
    let size: Int64
    let modified: Date
    let perms: String
}

struct LogLine: Identifiable {
    enum Kind { case info, command, success, error }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
}

struct Site: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var user: String
    var remoteDir: String = ""
    var localDir: String = ""
    var secret: String? = nil
    var quick: Bool? = nil
}

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("BytePass")
        let old = base.appendingPathComponent("DateiZilla")
        if !FileManager.default.fileExists(atPath: u.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: u)
        }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let askpass: URL = {
        let u = support.appendingPathComponent("askpass.sh")
        try? "#!/bin/sh\nprintf '%s\\n' \"$DZ_SECRET\"\n".write(to: u, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
        return u
    }()
}
