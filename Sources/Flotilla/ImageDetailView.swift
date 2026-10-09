import SwiftUI
import FlotillaCore

/// Which pane of the image detail is showing. Two, as for volumes and networks: an image has no
/// process list, no shell and no log, and `image` has no `set` subcommand.
enum ImageDetailTab: String, CaseIterable, Identifiable {
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

/// Detail for one image, embedded like every other detail screen.
///
/// Images were the last section with no detail at all — the strip's `open` could only select the
/// row, because there was nowhere to go. There was a place all along: `image inspect` is
/// allowlisted, implemented in `ContainerCLI` twice over, has a captured fixture, and was never
/// called from the app.
struct ImageDetailView: View {
    let model: AppModel
    let image: ContainerImage

    /// A tab the caller asked for — "Inspect" from the row menu — which wins over the default.
    let requestedTab: ImageDetailTab?

    @State private var tab: ImageDetailTab

    /// Which Mac it is on (PLAN.md Phase C).
    var host: HostRef = .local

    init(model: AppModel, image: ContainerImage, host: HostRef = .local, requestedTab: ImageDetailTab? = nil) {
        self.model = model
        self.image = image
        self.host = host
        self.requestedTab = requestedTab
        _tab = State(initialValue: requestedTab ?? .overview)
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailTabBar(items: ImageDetailTab.allCases.map {
                .init(tab: $0, title: $0.rawValue, systemImage: $0.systemImage)
            }, selection: $tab)

            Group {
                switch tab {
                case .overview: overview
                case .inspect:
                    InspectPane(command: "container image inspect \(image.reference)",
                                failureTitle: "Couldn't inspect this image",
                                hostName: model.hostMode.hostName(host, local: "this Mac")) {
                        host.isLocal ? try await model.fetchImageInspectJSON(for: image.reference)
                                     : try await model.fetchImageInspectJSON(for: image.reference, host: host)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    DetailCard(title: "Image", minHeight: 112) {
                        row("Repository", ImagesView.repository(image))
                        row("Tag", ImagesView.tag(image))
                        row("Reference", image.reference, monospaced: true)
                    }

                    DetailCard(title: "Content", minHeight: 112) {
                        row("Platform", ImagesView.platformLabel(image))
                        row("Size", image.displaySize.map {
                            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                        } ?? "—")
                        row("Created", RelativeDate.relative(image.configuration.creationDate))
                        // The full digest, not the short form the table shows — this is the
                        // screen with room for it, and it is what you paste when pinning.
                        row("Digest", image.configuration.descriptor?.digest ?? "—",
                            monospaced: true)
                    }
                }

                DetailCard(title: "Used by", minHeight: nil) {
                    // The question you arrive with, and the one `image inspect` cannot answer:
                    // the reference is recorded on the *container*. It is also the set Prune
                    // reasons about — an image with no rows here is one Prune would remove.
                    // That Mac's containers: on a paired host, what it last reported.
                    let pool: [Container] = switch host {
                    case .local: model.containers
                    case .peer(let fingerprint): model.hostMode.containerSnapshots[fingerprint]?.items ?? []
                    }
                    let users = pool.filter {
                        $0.configuration.image.reference == image.reference
                    }
                    if users.isEmpty {
                        Text("No containers use this image. Prune would remove it.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(users) { container in
                            HStack(spacing: 8) {
                                Circle().fill(container.stateColor).frame(width: 6, height: 6)
                                Button(container.id) {
                                    model.requestDetail(kind: .container, subject: host.rowID(container.id))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.link)
                                Spacer()
                                Text(container.status.state)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                DetailCard(title: "Recent events", minHeight: nil) {
                    // Keyed on `reference`, which is what the feed records images by —
                    // `ContainerImage.id` is the digest, and matching on it would find nothing.
                    let events = model.events(for: image.reference, kind: .image, host: host)
                    if events.isEmpty {
                        Text("Nothing has changed since flotilla started. Changes appear here as "
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
