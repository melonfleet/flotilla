import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FlotillaCore

enum FilesSort: String, CaseIterable {
    case name = "Name", modified = "Date Modified", size = "Size", kind = "Kind"
    func sorted(_ entries: [FileEntry], ascending: Bool) -> [FileEntry] {
        entries.sorted { left, right in
            let order: ComparisonResult
            switch self {
            case .name: order = left.name.localizedStandardCompare(right.name)
            case .kind: order = left.kindLabel.localizedStandardCompare(right.kindLabel)
            case .size:
                let l = left.isDirectory ? -1 : left.sizeBytes ?? -1, r = right.isDirectory ? -1 : right.sizeBytes ?? -1
                order = l == r ? .orderedSame : l < r ? .orderedAscending : .orderedDescending
            case .modified:
                let l = left.modifiedDate ?? .distantPast, r = right.modifiedDate ?? .distantPast
                order = l.compare(r)
            }
            if order == .orderedSame { return left.path.localizedStandardCompare(right.path) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

struct FilesRow: Identifiable {
    let entry: FileEntry
    let depth: Int
    var id: FileEntry.ID { entry.id }
}
struct FilesRowGroup: Identifiable {
    let name: String
    let rows: [FilesRow]
    var id: String { name }
}

/// Workspace's UTType icons preserve the system's blue folder and per-kind artwork.
struct FileSystemIcon: View {
    let entry: FileEntry
    var size: CGFloat = 20
    private var icon: NSImage {
        let type: UTType = entry.isDirectory ? .folder : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
    var body: some View {
        Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size)
            .overlay(alignment: .bottomLeading) {
                if entry.kind == .symbolicLink { Image(systemName: "arrow.turn.up.right").font(.system(size: max(8, size / 4))).foregroundStyle(.primary) }
            }.accessibilityHidden(true)
    }
}

/// The list's selection is SwiftUI's own, including command/shift click and keyboard selection.
/// Fixed metadata columns live in a horizontal scroller at narrow pane widths, never overlap.
struct FilesListView<MenuContent: View>: View {
    let groups: [FilesRowGroup]
    @Binding var selection: Set<FileEntry.ID>
    let expanded: Set<FileEntry.ID>
    let sort: FilesSort
    let ascending: Bool
    let sortBy: (FilesSort) -> Void
    let toggle: (FileEntry) -> Void
    let activate: ([FileEntry]) -> Void
    @ViewBuilder let menu: ([FileEntry]) -> MenuContent
    let entries: [FileEntry]

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        header(.name).frame(maxWidth: .infinity, alignment: .leading)
                        header(.modified).frame(width: 140, alignment: .leading)
                        header(.size).frame(width: 85, alignment: .leading)
                        header(.kind).frame(width: 110, alignment: .leading)
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                    Divider()
                    List(selection: $selection) {
                        ForEach(groups) { group in
                            if group.name.isEmpty { rows(group.rows) }
                            else { SwiftUI.Section(group.name) { rows(group.rows) } }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .overlay { if groups.allSatisfy({ $0.rows.isEmpty }) { ContentUnavailableView("Empty directory", systemImage: "folder") } }
                    .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
                        menu(entries.filter { ids.contains($0.id) })
                    } primaryAction: { ids in activate(entries.filter { ids.contains($0.id) }) }
                }
                .frame(width: max(600, geometry.size.width), height: geometry.size.height)
            }
        }
    }
    private func header(_ key: FilesSort) -> some View {
        Button { sortBy(key) } label: {
            HStack(spacing: 4) {
                Text(key.rawValue)
                if sort == key { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8)) }
            }.font(.caption).contentShape(.rect)
        }.buttonStyle(.plain).help("Sort by \(key.rawValue)").accessibilityLabel("Sort by \(key.rawValue)\(sort == key ? ascending ? ", ascending" : ", descending" : "")")
    }
    @ViewBuilder private func rows(_ rows: [FilesRow]) -> some View {
        ForEach(rows) { row in
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    if row.entry.isDirectory {
                        Button { toggle(row.entry) } label: {
                            Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 14)
                        }.buttonStyle(.plain)
                            .help("\(expanded.contains(row.id) ? "Collapse" : "Expand") \(row.entry.name)")
                            .accessibilityLabel("\(expanded.contains(row.id) ? "Collapse" : "Expand") \(row.entry.name)")
                    } else { Color.clear.frame(width: 14, height: 1) }
                    FileSystemIcon(entry: row.entry)
                    Text(row.entry.name).lineLimit(1)
                    if let target = row.entry.symlinkTarget {
                        Text("→ \(target)").foregroundStyle(.tertiary).lineLimit(1).help(target)
                    }
                }.padding(.leading, CGFloat(row.depth) * 16).frame(maxWidth: .infinity, alignment: .leading)
                Text(row.entry.modified).frame(width: 140, alignment: .leading).foregroundStyle(.secondary)
                Text(row.entry.sizeLabel).monospacedDigit().frame(width: 85, alignment: .leading).foregroundStyle(.secondary)
                Text(row.entry.kindLabel).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
            }
            .font(.system(size: 12)).padding(.vertical, 2).contentShape(.rect)
            .tag(row.id)
            .help(row.entry.path)
        }
    }
}

struct FilesIconView<MenuContent: View>: View {
    let groups: [FilesRowGroup]
    let selection: Set<FileEntry.ID>
    let select: (FileEntry, [FileEntry]) -> Void
    let activate: ([FileEntry]) -> Void
    @ViewBuilder let menu: ([FileEntry]) -> MenuContent
    let selected: [FileEntry]
    private var visible: [FileEntry] { groups.flatMap { $0.rows.map(\.entry) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    if !group.name.isEmpty { Text(group.name).font(.headline).foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140))], alignment: .leading, spacing: 12) {
                        ForEach(group.rows) { row in
                            VStack(spacing: 6) {
                                FileSystemIcon(entry: row.entry, size: 56)
                                Text(row.entry.name).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(8)
                            .background(selection.contains(row.id) ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                            .onTapGesture(count: 2) { activate([row.entry]) }
                            .onTapGesture { select(row.entry, visible) }
                            .contextMenu { menu(selection.contains(row.id) ? selected : [row.entry]) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(row.entry.name), \(row.entry.kindLabel)")
                            .accessibilityAddTraits(selection.contains(row.id) ? [.isSelected] : [])
                            .accessibilityAction { select(row.entry, visible) }
                            .accessibilityAction(named: "Open") { activate([row.entry]) }
                        }
                    }
                }
            }.padding(12)
        }
        .overlay { if visible.isEmpty { ContentUnavailableView("Empty directory", systemImage: "folder") } }
    }
}

struct FilesColumnView<MenuContent: View>: View {
    let paths: [String]
    let cache: [FileEntry.ID: [FileEntry]]
    let grouping: FileGrouping
    let sort: FilesSort
    let ascending: Bool
    let selection: Set<FileEntry.ID>
    let select: (FileEntry, [FileEntry]) -> Void
    let activate: ([FileEntry]) -> Void
    @ViewBuilder let menu: ([FileEntry]) -> MenuContent
    let selected: [FileEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(paths.map { Array($0.utf8) }, id: \.self) { bytes in
                        column(String(decoding: bytes, as: UTF8.self)).frame(width: 220).id(bytes)
                        Divider()
                    }
                }
            }
            .onChange(of: paths.map { Array($0.utf8) }) { _, newPaths in if let last = newPaths.last { proxy.scrollTo(last, anchor: .trailing) } }
            .onAppear { if let last = paths.last { proxy.scrollTo(Array(last.utf8), anchor: .trailing) } }
        }
    }
    private func column(_ path: String) -> some View {
        let groups = grouping.groups(sort.sorted(cache[Array(path.utf8)] ?? [], ascending: ascending))
        let visible = groups.flatMap(\.entries)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups, id: \.name) { group in
                        if !group.name.isEmpty { Text(group.name).font(.caption.bold()).foregroundStyle(.secondary).padding(6) }
                        ForEach(group.entries) { entry in
                            HStack(spacing: 6) {
                                FileSystemIcon(entry: entry)
                                Text(entry.name).lineLimit(1)
                                Spacer(minLength: 2)
                                if entry.isDirectory { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                            }
                            .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5)
                            .background(selection.contains(entry.id) ? Color.accentColor.opacity(0.22) : paths.contains(where: { Array($0.utf8) == entry.id }) ? .primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 4))
                            .contentShape(.rect)
                            .onTapGesture(count: 2) { activate([entry]) }
                            .onTapGesture { select(entry, visible) }
                            .contextMenu { menu(selection.contains(entry.id) ? selected : [entry]) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(entry.name), \(entry.kindLabel)")
                            .accessibilityAddTraits(selection.contains(entry.id) ? [.isSelected] : [])
                            .accessibilityAction { select(entry, visible) }
                            .accessibilityAction(named: "Open") { activate([entry]) }
                        }
                    }
                }.padding(4)
            }
        }
    }
}
