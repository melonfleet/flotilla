import SwiftUI
import Foundation
import FlotillaCore

/// One page hosting three sections — Disk usage, Volumes, Networks — per `research/FEATURES.md`
/// §2.1: "UX wants these on one 'System' page, not new nav items." We shipped Volumes and
/// Networks as separate sidebar items instead; this is the page that deviation asked for.
///
/// Whether the sidebar actually collapses to one "System" entry is the owner's call, wired by
/// the app owner in `Navigation.swift` — not touched here. This view is built to be embedded either
/// way: nothing above assumes anything about how it got on screen.
///
/// `VolumesView`/`NetworksView` are embedded, not copied: each owns its own toolbar, load
/// state and actions already, and duplicating that here would drift the moment either one
/// changes. Deliberately a plain `VStack`, not a `ScrollView` wrapping everything — a `List`
/// (which both of those views render) inside a `ScrollView` is a known SwiftUI layout
/// conflict (ambiguous/collapsing height), so each subview instead gets
/// `.frame(maxHeight: .infinity)` here and the `VStack` splits the remaining space between
/// them. Untested on a real build (see report) — worth the app owner's visual check.
struct SystemView: View {
    let model: AppModel

    @State private var diskUsage: SystemDiskUsage?
    @State private var diskUsageLoading = false
    @State private var diskUsageError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            diskUsageSection
                .padding(12)
            Divider()
            VolumesView(model: model)
                .frame(maxHeight: .infinity)
            Divider()
            NetworksView(model: model)
                .frame(maxHeight: .infinity)
        }
        .task { await loadDiskUsage() }
    }

    private var diskUsageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Disk Usage").font(.title3.bold())
                Spacer()
                Button {
                    Task { await loadDiskUsage() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(diskUsageLoading)
            }
            diskUsageContent
        }
    }

    @ViewBuilder
    private var diskUsageContent: some View {
        if diskUsageLoading && diskUsage == nil {
            ProgressView("Loading disk usage…")
        } else if let diskUsageError {
            ContentUnavailableView(
                "Can't read disk usage",
                systemImage: "exclamationmark.triangle",
                description: Text(diskUsageError)
            )
        } else if let diskUsage {
            VStack(spacing: 6) {
                ForEach(diskUsage.categories) { category in
                    diskRow(category)
                }
            }
        }
    }

    private func diskRow(_ category: SystemDiskUsage.Category) -> some View {
        HStack {
            Text(category.id)
                .frame(width: 110, alignment: .leading)
            Text(Self.byteCount(category.sizeInBytes))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Text(reclaimableText(category))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .trailing)
            Spacer()
            Text("\(category.active)/\(category.total) active")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// `reclaimableFraction` is nil, not zero, when nothing at all is stored in this
    /// category — the CLI's own `system df` table prints `0 B (0%)` for both "nothing
    /// reclaimable" and "nothing here", and that distinction is deliberately kept.
    private func reclaimableText(_ category: SystemDiskUsage.Category) -> String {
        guard let fraction = category.reclaimableFraction else { return "Nothing stored" }
        return "\(Self.byteCount(category.reclaimable)) reclaimable (\(Int((fraction * 100).rounded()))%)"
    }

    private func loadDiskUsage() async {
        diskUsageLoading = true
        diskUsageError = nil
        do {
            diskUsage = try await model.fetchSystemDiskUsage()
        } catch {
            diskUsageError = String(describing: error)
        }
        diskUsageLoading = false
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
