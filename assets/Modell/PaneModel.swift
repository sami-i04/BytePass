import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

@MainActor final class PaneModel: ObservableObject {
    enum Kind { case local, remote }
    let kind: Kind
    @Published var path = ""
    @Published var items: [FileItem] = []
    @Published var selection = Set<String>()
    @Published var loading = false
    @Published var error: String?
    @Published var history: [String] = []
    @Published var forward: [String] = []
    @Published var showHidden: Bool
    enum SortKey { case name, size, modified, perms }
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    var anchor: String?

    init(kind: Kind) { self.kind = kind; showHidden = kind == .remote }

    var visible: [FileItem] {
        let s = items.filter { showHidden || !$0.name.hasPrefix(".") }.sorted { a, b in
            let r: Bool
            switch sortKey {
            case .name: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: r = a.size == b.size ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.size < b.size
            case .modified: r = a.modified < b.modified
            case .perms: r = a.perms < b.perms
            }
            return ascending ? r : !r
        }
        return s.filter(\.isDir) + s.filter { !$0.isDir }
    }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.id) } }
    func fullPath(_ name: String) -> String {
        kind == .local ? (path as NSString).appendingPathComponent(name) : RPath.join(path, name)
    }

    static func listLocal(_ path: String) throws -> [FileItem] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let link = v?.isSymbolicLink ?? false
            let dir = link ? ((try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                           : (v?.isDirectory ?? false)
            var perms = ""
            if let p = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber {
                let m = p.intValue
                perms = (dir ? "d" : "-") + (0..<9).map { i in
                    m & (1 << (8 - i)) != 0 ? ["r", "w", "x"][i % 3] : "-"
                }.joined()
            }
            return FileItem(name: u.lastPathComponent, isDir: dir, isLink: link,
                            size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast, perms: perms)
        }
    }
}
