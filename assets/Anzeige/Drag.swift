import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

final class RemotePromise: NSFilePromiseProvider {
    struct Entry: Sendable { let path: String; let isDir: Bool; let size: Int64 }
    let entry: Entry
    init(entry: Entry) {
        self.entry = entry
        super.init()
        let ext = (entry.path as NSString).pathExtension
        fileType = entry.isDir ? UTType.folder.identifier : (UTType(filenameExtension: ext) ?? .data).identifier
        delegate = DragSource.shared
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [NSPasteboard.PasteboardType(AppModel.dragType.identifier)]
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type.rawValue == AppModel.dragType.identifier ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type.rawValue == AppModel.dragType.identifier {
            return Data("dzremote\n\(entry.isDir ? "D" : "F")\t\(entry.path)\t\(entry.size)".utf8)
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

final class DragSource: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = DragSource()

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { AppModel.shared.remoteDragActive = false }
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        RPath.name((p as! RemotePromise).entry.path)
    }
    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { .main }
    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let e = (p as! RemotePromise).entry
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            let m = AppModel.shared
            guard m.isConnected else {
                done(NSError(domain: "DateiZilla", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Nicht verbunden")])); return
            }
            let job = TransferJob(direction: .download, name: RPath.name(e.path), localPath: url.path,
                                  remotePath: e.path, isDir: e.isDir, size: e.size)
            let ok = await m.runAndWait(job)
            done(ok ? nil : NSError(domain: "DateiZilla", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Download fehlgeschlagen")]))
        }
    }
}

struct RowDrag: ViewModifier {
    let item: FileItem
    let pane: PaneModel
    func body(content: Content) -> some View {
        if pane.kind == .local {
            content.onDrag { AppModel.shared.dragProvider(for: item, in: pane) }
        } else {
            content.gesture(DragGesture(minimumDistance: 4).onChanged { _ in
                AppModel.shared.beginRemoteDrag(for: item, in: pane)
            })
        }
    }
}
