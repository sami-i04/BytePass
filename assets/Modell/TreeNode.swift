import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

@MainActor final class TreeNode: ObservableObject, Identifiable {
    nonisolated let path: String
    nonisolated var id: String { path }
    @Published var children: [TreeNode]?
    @Published var expanded = false
    @Published var loading = false
    init(path: String) { self.path = path }
    var name: String { path == "/" ? "/" : RPath.name(path) }

    func setChildren(from items: [FileItem]) {
        let old = Dictionary((children ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        children = items.filter(\.isDir)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { old[RPath.join(path, $0.name)] ?? TreeNode(path: RPath.join(path, $0.name)) }
    }
}
