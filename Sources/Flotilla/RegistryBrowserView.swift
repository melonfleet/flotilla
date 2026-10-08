import SwiftUI
import FlotillaCore

/// Images ▸ Browse Docker Hub (PLAN.md ▸ Registry browser): search Docker Hub, look at an image's
/// tags, and pull one — as Docker Desktop's Hub search does, inside the app.
///
/// A page of its own, like the forms (the same header and footer), with results on the left and
/// the chosen image on the right. Opening it lists the Docker Official Images; typing searches.
/// Those are the only two moments Flotilla asks Docker Hub anything (`AppModel.dockerHub`).
///
/// It never pulls. Pull opens the Pull form with the reference filled in, and the form validates
/// and runs it exactly as if it had been typed — a search result is untrusted text, not a command.
struct RegistryBrowserView: View {
    let model: AppModel
    /// The reference to pull — `redis:8.8` — handed to the Pull form.
    let onPull: (String) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var results: [DockerHub.Repository] = []
    @State private var total = 0
    @State private var loading = false
    @State private var problem: String?
    @State private var selectedID: DockerHub.Repository.ID?

    @State private var tags: [DockerHub.Tag] = []
    @State private var tagsLoading = false
    @State private var tagsProblem: String?
    @State private var selectedTag: DockerHub.Tag.ID?

    private var selected: DockerHub.Repository? { results.first { $0.id == selectedID } }

    /// What the default registry is, for the note when it is not Docker Hub.
    private var defaultRegistry: String { model.settingsStore[SettingsKeys.defaultRegistryDomain] }
    private var defaultIsDockerHub: Bool {
        KnownRegistry.canonicalHost(defaultRegistry) == KnownRegistry.canonicalHost(DockerHub.registryDomain)
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Browse Docker Hub", systemImage: "magnifyingglass",
                       hasUnsavedChanges: false, onBack: dismiss)
            Divider()
            HStack(spacing: 0) {
                resultsPane
                    .frame(minWidth: 380, maxWidth: .infinity)
                Divider()
                detailPane
                    .frame(width: 400)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A short pause after typing, so a search is one request per word rather than per key.
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(450)) }
            guard !Task.isCancelled else { return }
            await search(from: 0)
        }
        .task(id: selectedID) { await loadTags() }
    }

    // MARK: Results

    private var resultsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search Docker Hub", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await search(from: 0) } }
            if !defaultIsDockerHub {
                Label("Your default registry is \(defaultRegistry), which has no public search, so this "
                      + "searches Docker Hub. Pulls from here come from Docker Hub.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Docker Official Images" : "\(total.formatted()) result\(total == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.small) }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(selection: $selectedID) {
                ForEach(results) { repository in
                    resultRow(repository).tag(repository.id)
                }
                if results.count < total, !loading {
                    Button("Show More") { Task { await search(from: results.count) } }
                        .buttonStyle(.link)
                        .selectionDisabled()
                }
            }
            .listStyle(.inset)
            .overlay {
                if results.isEmpty, !loading, problem == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .padding(16)
    }

    private func resultRow(_ repository: DockerHub.Repository) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(repository.reference).font(.body.weight(.medium)).lineLimit(1)
                if let badge = repository.badgeLabel {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.info.opacity(0.14), in: Capsule())
                        .foregroundStyle(Theme.info)
                }
                if !repository.isPullable {
                    Text(Self.kindLabel(repository.type))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let description = repository.shortDescription, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(Self.stats(repository)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .opacity(repository.isPullable ? 1 : 0.6)
    }

    static func stats(_ repository: DockerHub.Repository) -> String {
        var parts: [String] = []
        if let pulls = repository.pullCount { parts.append("\(pulls) pulls") }
        if let stars = repository.starCount, stars > 0 { parts.append("\(stars.formatted()) stars") }
        if repository.isPullable {
            parts.append(repository.hasARM64 ? "Apple silicon" : "Intel only — runs under Rosetta")
        }
        return parts.joined(separator: " · ")
    }

    /// The listing kinds Docker Hub returns that are not images on docker.io.
    static func kindLabel(_ type: String) -> String {
        switch type {
        case "dhi": "Docker Hardened Image — separate subscription"
        case "mcp": "MCP server listing"
        case "extension": "Docker Desktop extension"
        case "plugin": "Docker plugin"
        default: "Not an image on docker.io"
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        if let repository = selected {
            VStack(alignment: .leading, spacing: 10) {
                Text(repository.reference).font(.title3.weight(.semibold)).textSelection(.enabled)
                if let description = repository.shortDescription, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Self.stats(repository)).font(.caption).foregroundStyle(.secondary)
                if repository.isPullable {
                    HStack {
                        Text("Tags").font(.headline)
                        if tagsLoading { ProgressView().controlSize(.small) }
                    }
                    .padding(.top, 6)
                    if let tagsProblem {
                        Label(tagsProblem, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                    List(selection: $selectedTag) {
                        ForEach(tags.filter(\.isUsable)) { tag in
                            tagRow(tag).tag(tag.id)
                        }
                    }
                    .listStyle(.inset)
                } else {
                    Label("\(Self.kindLabel(repository.type)), so Flotilla can't pull it from docker.io by name.",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView("Choose an image", systemImage: "shippingbox",
                                   description: Text("Its tags show here, newest first."))
        }
    }

    private func tagRow(_ tag: DockerHub.Tag) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tag.name).font(.body.monospaced()).lineLimit(1)
            HStack(spacing: 6) {
                Text(tag.hasLinuxARM64 ? "Apple silicon" : "Intel only — runs under Rosetta")
                    .foregroundStyle(tag.hasLinuxARM64 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                if let size = tag.fullSize, size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let date = DockerHub.date(tag.lastUpdated) {
                    Text(date.formatted(.relative(presentation: .named)))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Footer

    private var pullReference: String? {
        guard let repository = selected, repository.isPullable,
              let tag = tags.first(where: { $0.id == selectedTag }), tag.isUsable else { return nil }
        return "\(repository.reference):\(tag.name)"
    }

    private var footer: some View {
        HStack {
            Text("Searches go to hub.docker.com only when you open this page or type, and carry only "
                 + "what you typed.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button(pullReference.map { "Pull \($0)…" } ?? "Pull…") {
                if let reference = pullReference { onPull(reference) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(pullReference == nil)
        }
        .padding(12)
    }

    // MARK: Loading

    private func search(from offset: Int) async {
        loading = true
        defer { loading = false }
        do {
            let page = try await model.searchDockerHub(query: query, from: offset)
            let fresh = offset == 0 ? page.results : results + page.results.filter { new in !results.contains { $0.id == new.id } }
            results = fresh
            total = page.total
            problem = nil
            if offset == 0 { selectedID = fresh.first(where: \.isPullable)?.id }
        } catch is CancellationError {
        } catch {
            problem = AppModel.describeDockerHubFailure(error)
            if offset == 0 { results = []; total = 0 }
        }
    }

    private func loadTags() async {
        tags = []
        selectedTag = nil
        tagsProblem = nil
        guard let repository = selected, repository.isPullable else { return }
        tagsLoading = true
        defer { tagsLoading = false }
        do {
            let page = try await model.dockerHubTags(repository: repository.id)
            guard repository.id == selectedID else { return }
            var found = page.results
            // `latest` is what most people want and is often not among the newest-updated tags.
            if !found.contains(where: { $0.name == "latest" }),
               let latest = try? await model.dockerHubTag(repository: repository.id, tag: "latest") {
                found.insert(latest, at: 0)
            }
            guard repository.id == selectedID else { return }
            tags = found
            selectedTag = (tags.first { $0.name == "latest" } ?? tags.first(where: \.isUsable))?.id
        } catch is CancellationError {
        } catch {
            tagsProblem = AppModel.describeDockerHubFailure(error)
        }
    }
}

// MARK: - Requests

extension AppModel {
    /// The one session Flotilla uses for Docker Hub: nothing stored, no cookies, no cache, and a
    /// bare "Flotilla" user agent — so a request carries the search and nothing about this Mac.
    private static let dockerHubSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent": "Flotilla", "Accept": "application/json"]
        return URLSession(configuration: configuration)
    }()

    enum DockerHubFailure: Error {
        case status(Int)
        case unreadable
    }

    func searchDockerHub(query: String, from: Int) async throws -> DockerHub.SearchPage {
        try await dockerHubGet(DockerHub.searchURL(query: query, from: from), as: DockerHub.SearchPage.self)
    }

    func dockerHubTags(repository: String) async throws -> DockerHub.TagPage {
        guard let url = DockerHub.tagsURL(repository: repository) else { throw DockerHubFailure.unreadable }
        return try await dockerHubGet(url, as: DockerHub.TagPage.self)
    }

    func dockerHubTag(repository: String, tag: String) async throws -> DockerHub.Tag {
        guard let url = DockerHub.tagURL(repository: repository, tag: tag) else { throw DockerHubFailure.unreadable }
        return try await dockerHubGet(url, as: DockerHub.Tag.self)
    }

    private func dockerHubGet<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        let (data, response) = try await Self.dockerHubSession.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DockerHubFailure.status(status) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw DockerHubFailure.unreadable }
    }

    static func describeDockerHubFailure(_ error: Error) -> String {
        switch error {
        case DockerHubFailure.status(429):
            return "Docker Hub is limiting searches from this network. Wait a minute and try again."
        case DockerHubFailure.status(let code):
            return "Docker Hub answered with an error (\(code)). Try again in a moment."
        case DockerHubFailure.unreadable:
            return "Docker Hub's answer wasn't in a shape Flotilla knows — its search may have changed."
        case let error as URLError where error.code == .notConnectedToInternet:
            return "This Mac isn't connected to the internet."
        default:
            return "Couldn't reach Docker Hub: \(error.localizedDescription)"
        }
    }
}
