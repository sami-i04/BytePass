import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

struct RunResult { let status: Int32; let out: String; let err: String }

final class LineProcess: @unchecked Sendable {
    let process = Process()
    var timedOut = false

    func run(_ exe: String, _ args: [String], input: String? = nil, env: [String: String]? = nil, timeout: Double? = nil,
             onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> RunResult {
        await withCheckedContinuation { cont in
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            if let env { process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
            let out = Pipe(), err = Pipe(), inp = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input == nil ? FileHandle.nullDevice : inp
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch {
                cont.resume(returning: RunResult(status: -1, out: "", err: error.localizedDescription)); return
            }
            if let timeout {
                let p = process
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    if p.isRunning { self?.timedOut = true; p.terminate() }
                }
            }
            if let input {
                DispatchQueue.global().async {
                    try? inp.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? inp.fileHandleForWriting.close()
                }
            }
            let errBox = Box(Data()); let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async { errBox.value = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            DispatchQueue.global().async {
                let h = out.fileHandleForReading
                var buf = Data(), all = Data()
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    all.append(d); buf.append(d)
                    while let i = buf.firstIndex(of: 10) {
                        let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self)
                        buf.removeSubrange(buf.startIndex...i)
                        onLine(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                    }
                }
                if !buf.isEmpty { onLine(String(decoding: buf, as: UTF8.self)) }
                g.wait()
                while exited.wait(timeout: .now() + 1) == .timedOut {
                    if !self.process.isRunning { break }
                }
                cont.resume(returning: RunResult(status: self.process.terminationStatus,
                                                 out: String(decoding: all, as: UTF8.self),
                                                 err: String(decoding: errBox.value, as: UTF8.self)))
            }
        }
    }

    func cancel() { if process.isRunning { process.terminate() } }
}
