import SwiftUI
import FlotillaCore

/// What is wrong with — or happening to — this Mac's `container`, and the one button that fixes it:
/// start it, download a kernel, or download and install `container` itself (DECISIONS Q25, Q39).
///
/// Shown on This Mac's page and, since beta 2's first-run test (8 October), at the top of Overview
/// too: a setup that took minutes with Overview saying nothing read as nothing happening.
struct RuntimeBanner: View {
    let model: AppModel

    /// When there is something to say: the runtime is unusable, or a setup is under way.
    static func isShown(_ model: AppModel) -> Bool {
        if model.runtimeSetup != nil { return true }
        switch model.state {
        case .unavailable, .failed: return true
        default: return false
        }
    }

    private var reason: String {
        switch model.state {
        case .unavailable(let why), .failed(let why): why
        default: ""
        }
    }

    /// A host with its helper on installs `container` itself; the button there asks the helper
    /// rather than opening Apple's Installer, which needs someone at the keyboard.
    private var installsThroughHelper: Bool {
        model.hostMode.mode == .host && model.helperEnabled && { if case .missing? = model.preflight { true } else { false } }()
    }

    /// Shown above everything when the runtime is unusable, because in that state every number
    /// below is stale and a dashboard full of confident figures would be lying.
    var body: some View {
        // A stopped service is not a fault, so it must not be dressed as one: warning colour,
        // "not running" wording, and a button that fixes it. The red triangle stays for the
        // states where something really is wrong.
        let stopped: Bool = if case .serviceStopped = model.preflight { true } else { false }
        // A missing kernel is the same kind of state: not a fault, one button from working.
        let noKernel: Bool = if case .needsKernel = model.preflight { true } else { false }
        // Missing or too old (Q39): one button from working too — Apple's installer, downloaded here.
        let needsContainer = model.needsContainerInstall
        let setup = model.runtimeSetup
        let fixable = stopped || noKernel || needsContainer
        // The kernel install reports here rather than in a progress panel (the owner, 5 October):
        // the banner already says what is wrong, so it is the natural place to say it is being
        // fixed — and a failure stays here, beside the button that tries again.
        let install = noKernel ? model.kernelInstall : nil
        let installing = install != nil && install?.failure == nil && model.startingRuntime
        let installFailure = install?.failure
        return HStack(spacing: 10) {
            Image(systemName: stopped ? "pause.circle.fill"
                  : (noKernel || needsContainer) ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(fixable ? Theme.warning : Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(setup.map(Self.setupTitle)
                     ?? (installing ? "Installing the kernel…"
                     : installFailure != nil ? "The kernel didn't install"
                     : model.startingRuntime ? "Starting the container runtime…"
                     : stopped ? "The container runtime isn't running"
                     : noKernel ? "No kernel is installed"
                     : needsContainer ? "container isn't installed"
                               : "The container runtime is not available"))
                    .font(.headline)
                if let setup {
                    Text(Self.setupDetail(setup)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                } else if installing, let install {
                    kernelInstallDetail(install)
                } else if let installFailure {
                    // The CLI's own words, selectable and in full on hover: a download that
                    // failed is most often the network, and the message is how anyone tells.
                    Text(installFailure).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(installFailure)
                } else {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // A host says what its own automatic install is waiting for, and how to get it
                    // going without being at the keyboard.
                    if needsContainer, model.hostMode.mode == .host {
                        Text(model.hostRuntimeNote
                             ?? (model.helperEnabled ? "This Mac installs it by itself through its Flotilla Helper."
                                 : "Switch on the Flotilla Helper in Settings ▸ Advanced and this Mac installs it by itself, or install it now."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer()
            if model.startingRuntime || { if let setup, case .failed = setup.phase { false } else { setup != nil } }() {
                ProgressView().controlSize(.small)
            } else if stopped {
                // Named for what it does. `container system start` takes several seconds, which
                // is why the spinner above exists rather than a button that looks inert.
                Button("Start") { Task { await model.startRuntime() } }
                    .buttonStyle(.borderedProminent)
            } else if needsContainer, setup == nil || { if case .failed = setup?.phase { true } else { false } }() {
                // Says it downloads, and from whom: the click starts a 118 MB transfer, and the
                // installer that follows is Apple's.
                Button(setup == nil ? "Download and Install container \(ContainerRuntime.expectedVersion)" : "Try Again") {
                    if installsThroughHelper {
                        Task { model.hostRuntimeNote = await model.ensureHostRuntime(allowStoppingContainers: true) }
                    } else {
                        Task { await model.installContainerInteractively() }
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if noKernel {
                // Says what it does and that it downloads, because it does: a click should not
                // start a transfer the label did not mention.
                Button(installFailure == nil ? "Download Kernel" : "Try Again") {
                    Task { await model.installKernel() }
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Retry") { Task { await model.reload() } }
                .disabled(model.startingRuntime)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((fixable ? Theme.warning : Theme.danger).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    static func setupTitle(_ setup: AppModel.RuntimeSetupProgress) -> String {
        switch setup.phase {
        case .downloading: "Downloading container \(setup.version)…"
        case .checking: "Checking it is Apple's…"
        case .waitingForInstaller: "Finish installing in Apple's Installer"
        case .installing: "Installing container \(setup.version)…"
        case .starting: "Starting the container runtime…"
        case .installingKernel: "Installing the kernel…"
        case .failed: "container wasn't installed"
        }
    }

    static func setupDetail(_ setup: AppModel.RuntimeSetupProgress) -> String {
        switch setup.phase {
        case .downloading(let started):
            "From Apple's container releases on GitHub, about 118 MB — \(Int(Date().timeIntervalSince(started))) s so far."
        case .checking: "Signed by Apple's Containerization team and notarised, and the version this Flotilla expects."
        case .waitingForInstaller: "It asks for your password. Flotilla carries on by itself when it has finished."
        case .installing: "Through the Flotilla Helper."
        case .starting: "container \(setup.version) is installed."
        case .installingKernel: "Apple's recommended kernel, so containers can start."
        case .failed(let why): why
        }
    }

    /// What the CLI says it is fetching, and for how long. There is no percentage to show: 1.5.0
    /// prints one line and then nothing until it finishes, so a bar would be invented. The seconds
    /// are real, and they are what says "still working" during a twenty-second download.
    private func kernelInstallDetail(_ install: AppModel.KernelInstall) -> some View {
        TimelineView(.periodic(from: install.started, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(install.started)))
            HStack(spacing: 6) {
                Text(install.line.map(ContainerCLI.kernelDownloadSummary) ?? "Starting the download…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(seconds) s").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
