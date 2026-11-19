import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

final class ListUI: ObservableObject { @Published var hovered: String? }

struct FileListView<Menu: View>: View {
    @ObservedObject var pane: PaneModel
    let menu: (Set<String>) -> Menu
    @StateObject private var ui = ListUI()
    @FocusState private var focused: Bool

    static var sizeW: CGFloat { 90 }
    static var dateW: CGFloat { 125 }
    static var permW: CGFloat { 95 }

    var body: some View {
        let rows = pane.visible
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                header(String(localized: "Name"), .name).frame(maxWidth: .infinity, alignment: .leading)
                header(String(localized: "Größe"), .size).frame(width: Self.sizeW, alignment: .trailing)
                header(String(localized: "Geändert"), .modified).frame(width: Self.dateW, alignment: .leading).padding(.leading, 14)
                header(String(localized: "Rechte"), .perms).frame(width: Self.permW, alignment: .leading)
            }
            .padding(.horizontal, 14).frame(height: 28)
            Divider()
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                                row(item, rows: rows)
                                let hide = pane.selection.contains(item.id) || (i + 1 < rows.count && pane.selection.contains(rows[i + 1].id))
                                Divider().opacity(hide ? 0 : 0.55).padding(.leading, 14)
                            }
                        }
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: max(40, geo.size.height - CGFloat(rows.count) * 31))
                            .contentShape(Rectangle())
                            .onTapGesture { focused = true; pane.selection = [] }
                            .contextMenu { menu([]) }
                    }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onCommand(#selector(NSResponder.selectAll(_:))) { pane.selection = Set(rows.map(\.id)) }
        .onExitCommand { pane.selection = [] }
        .onDeleteCommand { AppModel.shared.delete(pane.selectedItems, in: pane) }
        .overlay(alignment: .top) {
            if focused { Rectangle().fill(Color.accentColor.opacity(0.7)).frame(height: 2) }
        }
    }

    private func header(_ title: String, _ key: PaneModel.SortKey) -> some View {
        Button {
            if pane.sortKey == key { pane.ascending.toggle() } else { pane.sortKey = key; pane.ascending = true }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if pane.sortKey == key { Image(systemName: pane.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: FileItem, rows: [FileItem]) -> some View {
        let selected = pane.selection.contains(item.id)
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: Icons.icon(item))
                    .resizable().interpolation(.high).frame(width: 17, height: 17)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.isLink { Image(systemName: "arrow.turn.up.right").font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.isDir ? "—" : Fmt.size(item.size)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: Self.sizeW, alignment: .trailing)
            Text(item.modified == .distantPast ? "" : Fmt.date.string(from: item.modified)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: Self.dateW, alignment: .leading).padding(.leading, 14)
            Text(item.perms).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: Self.permW, alignment: .leading)
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : (ui.hovered == item.id ? Color.primary.opacity(0.06) : Color.clear))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { ui.hovered = item.id } else if ui.hovered == item.id { ui.hovered = nil }
        }
        .gesture(TapGesture(count: 2).onEnded {
            focused = true
            pane.selection = [item.id]
            AppModel.shared.open(item, in: pane)
        })
        .simultaneousGesture(TapGesture().onEnded { click(item, rows: rows) })
        .modifier(RowDrag(item: item, pane: pane))
        .contextMenu { menu(pane.selection.contains(item.id) ? pane.selection : [item.id]) }
    }

    private func click(_ item: FileItem, rows: [FileItem]) {
        focused = true
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if pane.selection.contains(item.id) { pane.selection.remove(item.id) } else { pane.selection.insert(item.id) }
            pane.anchor = item.id
        } else if mods.contains(.shift), let a = pane.anchor,
                  let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == item.id }) {
            pane.selection = Set(rows[min(i, j)...max(i, j)].map(\.id))
        } else {
            pane.selection = [item.id]
            pane.anchor = item.id
        }
    }
}
