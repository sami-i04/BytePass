import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

@MainActor final class TransferJob: ObservableObject, Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable { case waiting, preparing, running, done, failed(String), cancelled }

    let id = UUID()
    let direction: Direction
    let name: String
    let localPath: String
    let remotePath: String
    let isDir: Bool
    let knownSize: Int64

    @Published var state: State = .waiting
    @Published var totalBytes: Int64 = 0
    @Published var doneBytes: Int64 = 0
    @Published var filesTotal = 0
    @Published var filesDone = 0
    @Published var currentFile = ""
    @Published var speed: Double = 0
    var proc: LineProcess?
    var tolerant = false
    var onFinish: ((Bool) -> Void)?
    var cancelled = false
    var started = Date()

    init(direction: Direction, name: String, localPath: String, remotePath: String, isDir: Bool, size: Int64) {
        self.direction = direction; self.name = name; self.localPath = localPath
        self.remotePath = remotePath; self.isDir = isDir; self.knownSize = size
    }

    var isActive: Bool { state == .waiting || state == .preparing || state == .running }
    var fraction: Double {
        if state == .done { return 1 }
        if totalBytes > 0 { return min(1, Double(doneBytes) / Double(totalBytes)) }
        return filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0
    }
    var detail: String {
        switch state {
        case .waiting: return String(localized: "Wartet …")
        case .preparing: return String(localized: "Wird vorbereitet …")
        case .running:
            var s = String(localized: "\(Fmt.size(doneBytes)) von \(Fmt.size(totalBytes))")
            if filesTotal > 1 { s += String(localized: " · Datei \(min(filesDone + 1, filesTotal)) von \(filesTotal)") }
            if speed > 0 {
                s += " · \(Fmt.size(Int64(speed)))/s"
                let rest = Double(totalBytes - doneBytes) / speed
                if rest.isFinite, rest > 0 { s += String(localized: " · noch \(Self.eta(rest))") }
            }
            if !currentFile.isEmpty && filesTotal > 1 { s += " · \(currentFile)" }
            return s
        case .done:
            let dt = Date().timeIntervalSince(started)
            return filesTotal == 1 ? String(localized: "1 Datei · \(Fmt.size(totalBytes)) · \(Self.eta(dt))") : String(localized: "\(filesTotal) Dateien · \(Fmt.size(totalBytes)) · \(Self.eta(dt))")
        case .failed(let e): return e
        case .cancelled: return String(localized: "Abgebrochen")
        }
    }
    static func eta(_ s: Double) -> String {
        let i = Int(s.rounded())
        return i >= 3600 ? String(format: "%d:%02d:%02d h", i / 3600, i % 3600 / 60, i % 60)
                         : String(format: "%d:%02d min", i / 60, i % 60)
    }
}

enum OverwriteChoice { case overwrite, skip, cancel }
