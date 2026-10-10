import SwiftUI
import FlotillaCore

/// Notifications (the owner, 10 October): every notice for a week, laid out like the Docker Hub
/// browser — a heading and its detail per row, searchable and scrolling — reached from the bell in
/// the window bar. A row opens its own page: how long it has been there, when it was last seen,
/// the fix if it has one. Several can be dismissed at once; errors cannot be dismissed, only dealt
/// with.
struct NotificationsView: View {
    let model: AppModel
    let go: (Section) -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case attention = "Needs Attention", dismissed = "Dismissed", resolved = "Resolved", all = "All"
        var id: Self { self }
    }

    @State private var filter: Filter = .attention
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var open: String?

    private var store: NoticeStore { model.notices }

    private var shown: [NoticeBook.Notice] {
        let all = store.book.notices
        let filtered: [NoticeBook.Notice] = switch filter {
        case .attention: store.attention
        case .dismissed: all.filter { $0.isActive && $0.dismissed != nil }
        case .resolved: all.filter { !$0.isActive }
        case .all: all
        }
        let ordered = filter == .attention ? filtered : filtered.sorted { $0.started > $1.started }
        let query = SearchQuery.tokens(search)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { notice in
            query.allSatisfy { SearchQuery.contains(notice.text, $0) || SearchQuery.contains(model.noticeHostName(notice) ?? "", $0) }
        }
    }

    var body: some View {
        Group {
            if let id = open, let notice = store.book.notices.first(where: { $0.id == id }) {
                NoticeDetailView(model: model, notice: notice, go: go) { open = nil }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: openPending)
        .onChange(of: model.pendingNotice) { _, _ in openPending() }
    }

    /// A notice whose macOS notification was clicked.
    private func openPending() {
        guard let id = model.pendingNotice else { return }
        model.pendingNotice = nil
        open = store.book.notices.contains { $0.id == id } ? id : nil
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(get: { !shown.isEmpty && Set(shown.map(\.id)).isSubset(of: selection) },
                                         set: { on in if on { selection.formUnion(shown.map(\.id)) } else { selection.subtract(shown.map(\.id)) } }))
                    .labelsHidden()
                    .accessibilityLabel("Select all")
                    .help("Select all \(shown.count)")
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("Search notifications", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .accessibilityLabel("Search notifications")
                Spacer()
                if !selected.isEmpty {
                    Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                    if selected.contains(where: { $0.dismissed != nil }) {
                        Button("Restore") { store.restore(Set(selected.map(\.id))); selection.removeAll() }
                    }
                    let showing = selected.filter { $0.isActive && $0.dismissed == nil }
                    let dismissible = showing.filter(\.dismissible)
                    if !showing.isEmpty {
                        Button("Dismiss \(dismissible.count)") { store.dismiss(Set(dismissible.map(\.id))); selection.removeAll() }
                            .disabled(dismissible.isEmpty)
                            .help(dismissible.isEmpty ? "Errors can't be dismissed, only dealt with" : "Hide until each one changes")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            List {
                ForEach(shown) { notice in row(notice) }
            }
            .listStyle(.inset)
            .overlay {
                if shown.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView(filter == .attention ? "Nothing needs attention" : "Nothing here",
                                               systemImage: filter == .attention ? "checkmark.circle" : "bell.slash",
                                               description: Text("Notifications are kept for seven days."))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
        }
        .onChange(of: filter) { _, _ in selection.removeAll() }
    }

    private var selected: [NoticeBook.Notice] { shown.filter { selection.contains($0.id) } }

    private func row(_ notice: NoticeBook.Notice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { selection.contains(notice.id) },
                                     set: { on in if on { selection.insert(notice.id) } else { selection.remove(notice.id) } }))
                .labelsHidden()
                .accessibilityLabel("Select \(notice.title)")
            Image(systemName: notice.level.symbol).foregroundStyle(notice.level.colour)
                .accessibilityLabel(notice.level.title)
                .help(notice.level.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(.body.weight(.medium)).lineLimit(1).help(notice.text)
                if let detail = notice.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(Self.meta(notice, host: model.noticeHostName(notice)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let fix = model.fix(for: notice) {
                Button(fix.title) { fix.run() }.controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { open = notice.id }
        .accessibilityAction(named: "Open") { open = notice.id }
        .opacity(notice.isActive && notice.dismissed == nil ? 1 : 0.65)
    }

    /// "Tahoe-Test-VM · started 5 min ago · dismissed".
    static func meta(_ notice: NoticeBook.Notice, host: String?) -> String {
        var parts: [String] = []
        if let host { parts.append(host) }
        parts.append("started \(RelativeDate.relativeToNow(notice.started))")
        if let resolved = notice.resolved { parts.append("resolved \(RelativeDate.relativeToNow(resolved))") }
        else if notice.dismissed != nil { parts.append("dismissed") }
        return parts.joined(separator: " · ")
    }
}

/// One notice's own page.
struct NoticeDetailView: View {
    let model: AppModel
    let notice: NoticeBook.Notice
    let go: (Section) -> Void
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: notice.title, systemImage: notice.level.symbol, hasUnsavedChanges: false, onBack: back)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: notice.level.symbol).font(.title2).foregroundStyle(notice.level.colour)
                            .accessibilityLabel(notice.level.title)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.text).font(.body).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DetailCard(title: "Details", minHeight: nil) {
                        line("Level", notice.level.title)
                        if let host = model.noticeHostName(notice) { line("Mac", host) }
                        line("Started", notice.started.formatted(date: .abbreviated, time: .shortened)
                             + " (\(RelativeDate.relativeToNow(notice.started)))")
                        line("Last seen", notice.isActive ? RelativeDate.relativeToNow(notice.lastSeen)
                             : notice.lastSeen.formatted(date: .abbreviated, time: .shortened))
                        if let resolved = notice.resolved {
                            line("Resolved", resolved.formatted(date: .abbreviated, time: .shortened)
                                 + " — lasted \(Self.duration(resolved.timeIntervalSince(notice.started)))")
                        } else {
                            line("Going on for", Self.duration(Date().timeIntervalSince(notice.started)))
                        }
                        if let dismissed = notice.dismissed { line("Dismissed", dismissed.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    HStack(spacing: 10) {
                        if let fix = model.fix(for: notice) {
                            Button(fix.title) { fix.run() }.buttonStyle(.borderedProminent)
                        }
                        if let section = Section(rawValue: notice.section) {
                            Button("Show in \(section.title)") { go(section) }
                        }
                        Spacer()
                        if notice.dismissed != nil {
                            Button("Restore") { model.notices.restore([notice.id]) }
                        } else if notice.isActive {
                            Button("Dismiss") { model.notices.dismiss([notice.id]); back() }
                                .disabled(!notice.dismissible)
                                .help(notice.dismissible ? "Hide until it changes" : "An error can't be dismissed, only dealt with")
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var status: String {
        if notice.resolved != nil { return "Resolved." }
        if notice.dismissed != nil { return "Dismissed — hidden until it changes." }
        return notice.level >= .warning ? "Needs attention." : "For information."
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 12)).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 3600 ? [.minute, .second] : [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, seconds)) ?? "—"
    }
}
