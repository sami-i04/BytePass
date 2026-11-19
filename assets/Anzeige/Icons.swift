import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

@MainActor enum Icons {
    static var cache: [String: NSImage] = [:]
    static func icon(_ item: FileItem) -> NSImage {
        let key = item.isDir ? "/dir" : (item.name as NSString).pathExtension.lowercased()
        if let i = cache[key] { return i }
        let img = item.isDir ? NSWorkspace.shared.icon(for: .folder)
                             : NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        cache[key] = img
        return img
    }
    static func sidebarSymbol(_ path: String) -> NSImage {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = (path as NSString).standardizingPath
        let map: [String: String] = [
            "/Applications": "appstore", "/System/Applications": "appstore", home + "/Applications": "appstore",
            "/Applications/Utilities": "wrench.and.screwdriver",
            home + "/Desktop": "menubar.dock.rectangle",
            home + "/Documents": "document",
            home + "/Downloads": "arrow.down.circle",
            home + "/Movies": "film",
            home + "/Music": "music.note",
            home + "/Pictures": "photo",
            home + "/Library/Mobile Documents/com~apple~CloudDocs": "icloud",
            home: "house",
            "/": "internaldrive",
        ]
        var name = map[p] ?? "folder"
        if map[p] == nil, p.hasPrefix("/Volumes/"), p.split(separator: "/").count == 2 { name = "externaldrive" }
        return symbol(name) ?? symbol("folder") ?? NSImage()
    }
    static func symbol(_ name: String) -> NSImage? {
        if let i = NSImage(systemSymbolName: name, accessibilityDescription: nil) { return i }
        let sel = NSSelectorFromString("imageWithPrivateSystemSymbolName:accessibilityDescription:")
        let cls: AnyObject = NSImage.self
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel, with: name, with: nil)?.takeUnretainedValue() as? NSImage
    }
    static func displayName(_ path: String) -> String {
        let n = FileManager.default.displayName(atPath: path)
        return n.isEmpty ? (path as NSString).lastPathComponent : n
    }

    static var pathCache: [String: NSImage] = [:]
    static func local(_ path: String, isDir: Bool = true) -> NSImage {
        if let i = pathCache[path] { return i }
        let img = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: isDir ? .folder : .data)
        if pathCache.count > 3000 { pathCache.removeAll() }
        pathCache[path] = img
        return img
    }
}
