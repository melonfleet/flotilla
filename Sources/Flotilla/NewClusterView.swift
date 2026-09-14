import SwiftUI
import Foundation
import FlotillaCore

/// Creating a local Kubernetes cluster.
///
/// Embedded, with `FormHeader` and Save bottom-right, like every other form since 9 August.
struct NewClusterView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var name = ""
    @State private var limitResources = false
    @State private var cpus = "2"
    @State private var memory = "4G"
    @State private var nodeImage = ""
    @State private var autoRemove = false
    @State private var creating = false
    @State private var edits = FormEditTracker()

    private var editSignature: String {
        [name, "\(limitResources)", cpus, memory, nodeImage, "\(autoRemove)"]
            .joined(separator: "\u{1}")
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "New Cluster", systemImage: "circle.hexagongrid",
                       hasUnsavedChanges: edits.isDirty(editSignature), onBack: dismiss)
            Divider()
            FormScaffold {
                form
            } preview: {
                railPreview
            }
            Divider()
            footer
        }
        .onAppear { edits.open(editSignature) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormField("Name",
                      help: FieldHelp(
                          "What the cluster is called, here and in kubectl.",
                          detail: "It becomes the kubectl context name, so `kubectl --context <name>` is how you reach it.",
                          example: "dev",
                          warning: "The CLI defaults this to `k8s-dev` when it is omitted. Flotilla always sends a name, because a default-named cluster is one you create twice by accident."),
                      problem: nameProblem) {
                TextField("dev", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }

            FormSectionHeader(
                title: "Resources",
                note: "Left alone, the CLI decides — and its default is large.")

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Set CPUs and memory", isOn: $limitResources)
                // Measured, not guessed: a cluster created here with no resource flags came back
                // with 3 CPUs and 16384 MB. That is a sixteen-gigabyte VM for a dev cluster, and
                // worth knowing before you create two.
                Text("A cluster created with neither came back with 3 CPUs and 16384 MB.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if limitResources {
                FormField("CPUs",
                          help: FieldHelp("Whole cores for the cluster's VM."),
                          problem: cpusProblem,
                          optional: true) {
                    TextField("2", text: $cpus)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                FormField("Memory",
                          help: FieldHelp("With a K, M or G suffix.", example: "4G"),
                          problem: memoryProblem,
                          optional: true) {
                    TextField("4G", text: $memory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }

            FormSectionHeader(title: "Advanced")

            FormField("Node image",
                      help: FieldHelp(
                          "The Kubernetes version, as a kind node image.",
                          detail: "Left empty, the CLI uses its own digest-pinned default — which is how you get a reproducible version rather than whatever is newest.",
                          example: "docker.io/kindest/node:v1.35.5"),
                      problem: nodeImageProblem,
                      optional: true) {
                TextField("kindest/node:v1.35.5", text: $nodeImage)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Remove the cluster when it stops", isOn: $autoRemove)
                Text("`--rm`. Useful for a throwaway cluster; wrong for one you mean to start again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Validation

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return nil }
        guard Allowlist.accepts(trimmedName, as: .identifier) else {
            return "“\(trimmedName)” cannot be a cluster name. \(ValueShape.identifier.rule)"
        }
        if model.clusters.contains(where: { $0.node == trimmedName }) {
            return "A cluster called “\(trimmedName)” already exists."
        }
        return nil
    }

    private var chosenCPUs: Int? {
        guard limitResources else { return nil }
        return Int(cpus.trimmingCharacters(in: .whitespaces))
    }

    private var chosenMemory: String? {
        guard limitResources else { return nil }
        let trimmed = memory.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var chosenNodeImage: String? {
        let trimmed = nodeImage.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var cpusProblem: String? {
        guard limitResources, !cpus.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return chosenCPUs == nil ? "Expected a whole number of cores." : nil
    }

    private var memoryProblem: String? {
        guard let chosenMemory else { return nil }
        return Allowlist.accepts(chosenMemory, as: .memorySize)
            ? nil : "“\(chosenMemory)” is not a memory size. \(ValueShape.memorySize.rule)"
    }

    private var nodeImageProblem: String? {
        guard let chosenNodeImage else { return nil }
        return Allowlist.accepts(chosenNodeImage, as: .imageReference)
            ? nil : "“\(chosenNodeImage)” is not an image reference. \(ValueShape.imageReference.rule)"
    }

    private var validation: Result<ValidatedCommand, AllowlistError> {
        AppModel.createClusterValidation(name: trimmedName.isEmpty ? "placeholder" : trimmedName,
                                         cpus: chosenCPUs, memory: chosenMemory,
                                         nodeImage: chosenNodeImage, autoRemove: autoRemove)
    }

    private var canSubmit: Bool {
        guard !trimmedName.isEmpty, nameProblem == nil, cpusProblem == nil,
              memoryProblem == nil, nodeImageProblem == nil, !creating
        else { return false }
        if case .success = validation { return true }
        return false
    }

    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)
            Text(trimmedName.isEmpty
                 ? "Name the cluster to see the command."
                 : AppModel.createClusterPreview(name: trimmedName, cpus: chosenCPUs,
                                                 memory: chosenMemory, nodeImage: chosenNodeImage,
                                                 autoRemove: autoRemove))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The two things that surprise people, said before they happen rather than after.
            Label("The first cluster downloads a node image of about a gigabyte and can take several minutes.",
                  systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Creating a cluster also writes ~/.kube/config. That is the CLI's own behaviour and it has no flag to prevent it.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if creating {
                ProgressView().controlSize(.small)
                Text("Creating… this pulls the node image and boots a VM.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: dismiss)
            Button("Save") { Task { await create() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
        .padding(12)
    }

    private func create() async {
        creating = true
        defer { creating = false }
        let succeeded = await model.createCluster(name: trimmedName, cpus: chosenCPUs,
                                                  memory: chosenMemory,
                                                  nodeImage: chosenNodeImage,
                                                  autoRemove: autoRemove)
        if succeeded { dismiss() }
    }
}

/// Loading a local image into a cluster's containerd.
///
/// A dialog rather than a screen: one field, one button, and it is an action on a row rather than
/// a place you navigate to — the distinction `ModalCard` survives for.
struct LoadImageSheet: View {
    let model: AppModel
    let cluster: K8sNode
    let dismiss: () -> Void

    @State private var reference = ""
    @State private var loading = false

    var body: some View {
        ModalCard(title: "Load an image into “\(cluster.node)”", onClose: dismiss) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Copies an image from this Mac into the cluster, so a pod can run it with no registry in between.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                FormField("Image reference",
                          help: FieldHelp(
                              "An image that already exists on this Mac.",
                              detail: "Build or pull it first; this does not fetch anything.",
                              example: "fleetcheck:1.0"),
                          problem: problem) {
                    TextField("fleetcheck:1.0", text: $reference)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                }

                Text("Then run it with an image pull policy of Never, or Kubernetes will try to fetch it and fail:")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("kubectl --context \(cluster.node) run demo \\\n  --image=\(trimmed.isEmpty ? "<image>" : trimmed) --image-pull-policy=Never")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Spacer()
                    Button("Cancel", action: dismiss)
                    Button("Load") {
                        Task {
                            loading = true
                            await model.loadImage(trimmed, into: cluster)
                            loading = false
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || problem != nil || loading)
                }
            }
            .frame(width: 460)
        }
    }

    private var trimmed: String { reference.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        guard !trimmed.isEmpty else { return nil }
        guard Allowlist.accepts(trimmed, as: .imageReference) else {
            return "“\(trimmed)” is not an image reference. \(ValueShape.imageReference.rule)"
        }
        return nil
    }
}

/// Where the kubeconfig went, and what to do with it.
///
/// A dialog rather than a banner, because the useful part is a command to copy — and because the
/// thing it has to say about `~/.kube/config` is a correction to what people will assume.
struct KubeconfigSheet: View {
    let result: KubeconfigResult
    let dismiss: () -> Void

    var body: some View {
        ModalCard(title: "Kubeconfig written", onClose: dismiss) {
            VStack(alignment: .leading, spacing: 14) {
                Text("A kubeconfig holding only “\(result.cluster)” was written to:")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(result.url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

                // The file arrives with no current-context, so kubectl fails against it until one
                // is named. Measured: "the server could not find the requested resource".
                Text("It has no current context set, so name one:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("KUBECONFIG=\"\(result.url.path)\" \\\n  kubectl --context \(result.cluster) get nodes")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

                Label("Your ~/.kube/config already has this cluster too — `container k8s create` writes it when the cluster is made, and has no flag to prevent that. This file is an extra copy, not a way to keep it out.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.url])
                    }
                    Spacer()
                    Button("Done", action: dismiss)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 500)
        }
    }
}
