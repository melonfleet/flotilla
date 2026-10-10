import SwiftUI
import FlotillaCore
import FlotillaNet

/// A host page's Settings tab (the owner, 9 October): every Flotilla setting on that Mac, as a table
/// or as the property list a configuration profile would carry — built like the Inspect tab next
/// door, with the same header: copy and reload, the view switch, the filter.
///
/// This Mac reads its own store; a host answers `.settingsReport` (wire version 8). Settings marked
/// sensitive are listed without their value, in both views and in Copy.
struct HostSettingsTab: View {
    let model: AppModel
    let host: HostRef

    enum Presentation: String, CaseIterable, Identifiable {
        case table = "Table", plist = "Property list"
        var id: Self { self }
        var symbol: String { self == .table ? "tablecells" : "chevron.left.forwardslash.chevron.right" }
    }

    @State private var report: SettingsReport?
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var presentation: Presentation = .table

    private var rows: [SettingsReport.Entry] {
        let entries = report?.entries ?? []
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.displayValue.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ActionCluster {
                    IconActionButton(systemImage: "doc.on.doc", label: "Copy",
                                     help: presentation == .table ? "Copy the settings as text" : "Copy the property list",
                                     disabled: report == nil) {
                        guard let report else { return }
                        Clipboard.copy(presentation == .table
                                       ? report.entries.map { "\($0.name) = \($0.displayValue)  (\(Self.source($0.source)))" }
                                           .joined(separator: "\n")
                                       : report.propertyListXML())
                    }
                    Divider().frame(height: 14)
                    IconActionButton(systemImage: "arrow.clockwise", label: "Reload", help: "Reload", busy: loading) {
                        Task { await reload() }
                    }
                }
                Picker("View", selection: $presentation) {
                    ForEach(Presentation.allCases) {
                        Label($0.rawValue, systemImage: $0.symbol).labelStyle(.iconOnly).help($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if presentation == .table {
                    TextField("Filter settings", text: $search)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
                Spacer(minLength: 12)
                Text("dev.melonfleet.Flotilla")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            content
            HStack(spacing: 6) {
                Image(systemName: "eye.slash").font(.caption2)
                Text("Sensitive settings — the trusted fingerprints — are listed without their value, here and in Copy.")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .task(id: host) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't read the settings", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if report == nil {
            ProgressView("Reading the settings…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presentation == .table {
            SwiftUI.Table(rows) {
                TableColumn("Setting") { entry in
                    Text(entry.name).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .help(entry.summary)
                }
                .width(min: 160, ideal: 240)
                TableColumn("Value") { entry in
                    Text(entry.displayValue).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .foregroundStyle(entry.value == nil ? .tertiary : .primary)
                }
                .width(min: 120, ideal: 220)
                TableColumn("Source") { entry in
                    Text(Self.source(entry.source)).font(.system(size: 11))
                        .foregroundStyle(entry.source == .builtIn ? .secondary : .primary)
                }
                .width(min: 90, ideal: 130)
                TableColumn("What it does") { entry in
                    Text(entry.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .help(entry.summary)
                }
            }
        } else if let report {
            ScrollView([.vertical, .horizontal]) {
                Text(report.propertyListXML())
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
    }

    /// Where a value comes from, in the words Settings uses.
    static func source(_ source: SettingSource) -> String {
        switch source {
        case .builtIn: "Default"
        case .user: "Set on this Mac"
        case .managedDefault: "Profile default"
        case .locked: "Locked by a profile"
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            report = try await model.settingsReport(on: host)
            error = nil
        } catch {
            self.error = (error as? HostCallFailure)?.message
                ?? "\(model.hostMode.hostName(host, local: "This Mac")) didn't answer. A host needs this build of Flotilla to list its settings."
        }
    }
}
