import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

struct LogTicker: View {
    @ObservedObject var app = AppModel.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                let last = Array(app.log.suffix(3))
                ForEach(0..<3, id: \.self) { i in
                    if i < last.count {
                        let l = last[i]
                        HStack(spacing: 10) {
                            Text(Fmt.time.string(from: l.date)).foregroundStyle(.tertiary)
                            Text(l.text).foregroundStyle(LogList.color(l.kind)).lineLimit(1).truncationMode(.middle)
                        }
                    } else { Text(" ") }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { app.activityTab = 1; openWindow(id: "activity") } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Protokoll öffnen")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .modifier(Card())
    }
}

struct ActivityWindow: View {
    @ObservedObject var app = AppModel.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $app.activityTab) {
                    Text(app.activeJobs > 0 ? String(localized: "Warteschlange (\(app.activeJobs))") : String(localized: "Warteschlange")).tag(0)
                    Text("Protokoll").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if app.activityTab == 0 {
                    Button("Erledigte entfernen") { app.clearFinished() }
                        .disabled(!app.jobs.contains { !$0.isActive }).controlSize(.small)
                } else {
                    Button("Protokoll leeren") { app.log.removeAll() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if app.activityTab == 0 { QueueList() } else { LogList() }
        }
        .background(Theme.card)
        .frame(minWidth: 560, minHeight: 280)
    }
}

struct QueueList: View {
    @ObservedObject var app = AppModel.shared
    var body: some View {
        if app.jobs.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
                Text("Keine Übertragungen").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text("Dateien per Drag & Drop zwischen Mac und Server ziehen oder doppelklicken.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(app.jobs) { job in
                        JobRow(job: job)
                        Divider().opacity(0.5).padding(.leading, 52)
                    }
                }
            }
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: TransferJob
    private var color: Color {
        switch job.state {
        case .failed: return .red
        case .cancelled: return .secondary
        default: return job.direction == .upload ? Theme.upload : Theme.download
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 24)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: job.isDir ? "folder.fill" : "doc.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(job.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("→ " + (job.direction == .upload ? RPath.parent(job.remotePath) : (job.localPath as NSString).deletingLastPathComponent))
                        .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    status
                }
                if job.state == .running || job.state == .preparing {
                    ProgressView(value: job.fraction).progressViewStyle(.linear).tint(color).controlSize(.small)
                }
                Text(job.detail).font(.system(size: 11)).foregroundStyle(job.state.isFailed ? Color.red : .secondary)
                    .monospacedDigit().lineLimit(2)
            }
            if job.isActive {
                Button { AppModel.shared.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Abbrechen")
            } else {
                if job.state.isFailed || job.state == .cancelled {
                    Button { AppModel.shared.retry(job) } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Erneut versuchen")
                }
                Button { AppModel.shared.remove(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Aus Liste entfernen")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .running: Text("\(Int(job.fraction * 100)) %").font(.system(size: 11, weight: .semibold)).foregroundStyle(color).monospacedDigit()
        case .done: Label("Fertig", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.download)
        case .failed: Label("Fehler", systemImage: "exclamationmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
        default: EmptyView()
        }
    }
}

extension TransferJob.State {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

struct LogList: View {
    @ObservedObject var app = AppModel.shared
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(app.log) { l in
                        HStack(alignment: .top, spacing: 10) {
                            Text(Fmt.time.string(from: l.date)).foregroundStyle(.tertiary)
                            Text(l.text).foregroundStyle(Self.color(l.kind)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(l.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: app.log.count) { _, _ in
                if let id = app.log.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear { if let id = app.log.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }
    static func color(_ k: LogLine.Kind) -> Color {
        switch k {
        case .info: return .primary.opacity(0.75)
        case .command: return Theme.upload
        case .success: return Theme.download
        case .error: return .red
        }
    }
}
