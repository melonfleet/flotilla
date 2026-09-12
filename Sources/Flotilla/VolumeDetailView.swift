import SwiftUI
import FlotillaCore

/// Which pane of the volume detail is showing.
///
/// Two, not five. A volume has no process list, no shell, no log and nothing `volume set` can
/// change — the CLI has no such subcommand — so every other tab the container screen carries
/// would be a control with nothing behind it, which this project has shipped once and does not
/// intend to again.
enum VolumeDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case inspect = "Inspect"
    var id: Self { self }

    var systemImage: String {
        switch self {
        case .overview: "info.circle"
        case .inspect: "curlybraces"
        }
    }
}

/// Detail for one volume, embedded in the window like the container and machine details it
/// mirrors.
///
/// This replaces a floating inspect sheet, now deleted. Volumes and Networks were the last two sections where
/// looking at one thing threw a modal over the list rather than taking you to it — the exception
/// to the 9 August "everything is embedded" decision, kept because the reasoning was about the
/// *content* ("a pane would mostly re-present the table") and never about the shape. The owner's
/// call, and the right one: the exception was what looked wrong.
struct VolumeDetailView: View {
    let model: AppModel
    let volume: ContainerVolume

    /// A tab the caller asked for — "Inspect" from the row menu — which wins over the default.
    let requestedTab: VolumeDetailTab?

    @State private var tab: VolumeDetailTab

    init(model: AppModel, volume: ContainerVolume, requestedTab: VolumeDetailTab? = nil) {
        self.model = model
        self.volume = volume
        self.requestedTab = requestedTab
        _tab = State(initialValue: requestedTab ?? .overview)
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailTabBar(items: VolumeDetailTab.allCases.map {
                .init(tab: $0, title: $0.rawValue, systemImage: $0.systemImage)
            }, selection: $tab)

            Group {
                switch tab {
                case .overview: overview
                case .inspect:
                    InspectPane(command: "container volume inspect \(volume.name)",
                                failureTitle: "Couldn't inspect this volume") {
                        try await model.fetchVolumeInspectJSON(for: volume.name)
                    }
                }
            }
            // `.topLeading`, not `.top`: SwiftUI's `.top` is horizontally centred, which is what
            // made the Inspect JSON read as a floating block rather than a document.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    DetailCard(title: "Volume", minHeight: 112) {
                        row("Name", volume.name)
                        row("Driver", volume.configuration.driver ?? "—")
                        row("Format", volume.format ?? "—")
                    }

                    DetailCard(title: "Storage", minHeight: 112) {
                        // **Capacity, not usage.** Proved by creating a volume with `--size 64M`
                        // and finding `sizeInBytes` exactly 67,108,864 while `du` charged 2.2 MB
                        // — so this is the size the volume was created with, and the column in
                        // the table is named Capacity for the same reason.
                        row("Capacity", capacityLabel)
                        row("Created", RelativeDate.relative(volume.configuration.creationDate))
                    }
                }

                DetailCard(title: "On disk", minHeight: nil) {
                    // The host path is the one thing here you cannot get from the table, and the
                    // reason `volume inspect` is worth having at all.
                    row("Source", volume.source ?? "—", monospaced: true)
                }

                DetailCard(title: "Recent events", minHeight: nil) {
                    let events = model.events(for: volume.name, kind: .volume)
                    if events.isEmpty {
                        Text("Nothing has changed since Flotilla started. Changes appear here as "
                             + "they happen; history from before launch is not recorded.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(events.prefix(8)) { event in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Theme.color(forEventEndingIn: event.to))
                                    .frame(width: 6, height: 6)
                                Text(event.summary).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(event.date.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var capacityLabel: String {
        guard let bytes = volume.sizeInBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
