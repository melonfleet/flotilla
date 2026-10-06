import AppKit
import FlotillaCore
import UniformTypeIdentifiers

/// Exporting configuration to a `.flotilla` file (DECISIONS Q29): gathering the live state the
/// exporter needs, and writing what it builds. The deciding is `ConfigurationExport`'s, in the core.
extension AppModel {

    /// The file type. Declared in the bundle's Info.plist as an exported type, so Finder opens
    /// `.flotilla` files with Flotilla; this falls back to the extension if the declaration is
    /// missing (a `swift run` build has no bundle).
    static var flotillaFileType: UTType {
        UTType("dev.melonfleet.flotilla-configuration")
            ?? UTType(filenameExtension: ConfigurationFile.fileExtension, conformingTo: .json)
            ?? .json
    }

    /// Everything the exporter reads. Refreshes what may be stale, then inspects each image a
    /// container or group member uses — for the defaults to subtract and the digest to record.
    /// An image that will not inspect is skipped; the exporter says what that costs.
    func gatherExportInputs() async -> ConfigurationExport.Inputs {
        await refresh()
        await refreshNetworks()
        await refreshVolumes()
        await refreshMachines()
        await refreshClusters()
        await refreshDNS()

        let references = Set(containers.map(\.imageReference) + groups.book.groups.flatMap { $0.members.map(\.image) })
        let images = await Task.detached { [cli] in
            references.sorted().compactMap { try? cli.inspectImage($0) }
        }.value

        // `machine list` does not say what a machine was built from; `machine inspect` does.
        let listed = machines
        let inspectedMachines = await Task.detached { [cli] in
            listed.map { machine in (try? cli.inspectMachine(machine.id)) ?? machine }
        }.value

        var inputs = ConfigurationExport.Inputs()
        inputs.containers = containers
        inputs.groups = groups.book.groups
        inputs.networks = networks
        inputs.volumes = volumes
        inputs.machines = inspectedMachines
        inputs.clusters = clusters
        inputs.images = images
        inputs.tags = tags.book
        inputs.registries = registries.book
        inputs.defaultRegistry = defaultRegistry
        inputs.dnsDomains = dnsDomains
        inputs.containerDNSDomain = containerDNSDomain
        return inputs
    }

    /// The selection that saves one group so it can be rebuilt elsewhere: the group, its network
    /// and the named volumes its services mount — all as definitions.
    static func selection(forGroup group: ContainerGroup) -> ConfigurationExport.Selection {
        var selection = ConfigurationExport.Selection()
        selection.groups = [group.id]
        if let network = group.network, network != "default" { selection.networks = [network] }
        selection.volumes = Set(group.members.flatMap(\.volumes).compactMap { mount in
            let source = mount.split(separator: ":").first.map(String.init) ?? ""
            return source.hasPrefix("/") || source.isEmpty ? nil : source
        })
        return selection
    }

    /// Asks where to save, and writes. Returns the URL written, or `nil` if cancelled.
    @discardableResult
    func saveConfiguration(_ file: ConfigurationFile, suggestedName: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.flotillaFileType]
        panel.nameFieldStringValue = suggestedName + "." + ConfigurationFile.fileExtension
        panel.canCreateDirectories = true
        panel.message = "A .flotilla file describes what to build. It holds no passwords and no data."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try file.encoded().write(to: url, options: .atomic)
        recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .runtime,
                                      subject: url.lastPathComponent, action: "Configuration exported"))
        return url
    }

    /// "Save to File…" on a group: no checklist, and a short note of what was left out.
    func saveGroupToFile(_ group: ContainerGroup) async {
        let inputs = await gatherExportInputs()
        let result = ConfigurationExport.build(inputs, selection: Self.selection(forGroup: group))
        do {
            guard try saveConfiguration(result.file, suggestedName: group.name) != nil else { return }
            if !result.omissions.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Saved “\(group.name)”"
                alert.informativeText = "Left out of the file:\n"
                    + result.omissions.map { "• \($0.subject): \($0.reason)" }.joined(separator: "\n")
                alert.runModal()
            }
        } catch {
            actionError = "Couldn't save “\(group.name)”: \(error.localizedDescription)"
        }
    }

    func requestExport() {
        configurationScreen = .export
    }
}

/// The screen File ▸ Export… or Import… puts in the main window, over whichever section is
/// selected — neither belongs to one section.
enum ConfigurationScreen: Equatable {
    case export
    case importFile(URL)
}
