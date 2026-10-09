import SwiftUI
import FlotillaCore

/// First run: ask for appearance, with **Auto pre-selected**.
///
/// `DECISIONS.md` (item 11) settles this as *asked*, not defaulted — and the store models
/// `notChosen` as distinct from `auto` precisely so this question can be asked exactly
/// once. Auto is pre-selected rather than merely offered, so confirming without thinking
/// gives the system-following behaviour most people want, and the first paint does not
/// change under the user when they press Continue.
///
/// Two questions and no more (the owner, 7 October, added the second). Onboarding that marches
/// through every preference gets dismissed blind. Appearance has no defensible default, because
/// "follow the system" is a choice rather than an absence of one; and how a Mac is used — admin,
/// or host — decides whether it listens on the network at all, which nobody should find out
/// about later. Admin is pre-selected: it listens on nothing. A profile that sets the mode answers
/// that question, and the sheet says so instead of asking.
///
/// A third section appears only on a Mac without `container` (the owner, 8 October; DECISIONS
/// Q39): an admin is offered Apple's installer — downloaded and checked by Flotilla, approved by the
/// owner in Apple's Installer — and a host is told it will install `container` itself.
struct OnboardingView: View {
    let model: AppModel

    /// Pre-selected, not defaulted — the distinction the store keeps.
    @State private var selection: AppearanceMode = .auto
    @State private var mode: RunMode = .client
    @State private var installContainer = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to flotilla")
                    .font(.title2.weight(.semibold))
                Text("How should flotilla look? You can change this later in Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Appearance", selection: $selection) {
                ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                    Text(Self.title(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(Self.explanation(for: selection))
                .font(.callout)
                .foregroundStyle(.secondary)
                // Wrap rather than clip — the Auto explanation is the longest and is the
                // one most worth reading.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("How will you use this Mac?")
                    .font(.headline)
                if modeLocked {
                    Text("\(model.settingsStore[SettingsKeys.mode].title) — set by your organisation.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Use this Mac as", selection: $mode) {
                        ForEach(RunMode.offered, id: \.rawValue) { option in Text(option.title).tag(option) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(mode.explanation + " You can change this later in Settings ▸ Host Mode.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if model.needsContainerInstall {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("container").font(.headline)
                    if effectiveMode == .host {
                        Text("Apple's container isn't installed on this Mac. As a host, flotilla installs container "
                             + "\(ContainerRuntime.expectedVersion) and its kernel by itself once its flotilla Helper is switched "
                             + "on — in Settings ▸ Advanced, or by your organisation's profile.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Toggle("Download and install container \(ContainerRuntime.expectedVersion) when I continue",
                               isOn: $installContainer)
                            .toggleStyle(.checkbox)
                        Text("Apple's installer, about 118 MB from Apple's GitHub releases. flotilla checks it is Apple's, "
                             + "then Apple's Installer asks for your password. Then the kernel containers run on.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Continue") {
                    if !modeLocked { try? model.settingsStore.set(mode, for: SettingsKeys.mode) }
                    let install = model.needsContainerInstall && installContainer && effectiveMode != .host
                    model.chooseAppearance(selection)
                    if install { Task { await model.installContainerInteractively() } }
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var modeLocked: Bool { model.settingsStore.isLocked(SettingsKeys.mode) }
    private var effectiveMode: RunMode { modeLocked ? model.settingsStore[SettingsKeys.mode] : mode }

    private static func title(for mode: AppearanceMode) -> String {
        switch mode {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private static func explanation(for mode: AppearanceMode) -> String {
        switch mode {
        case .auto: "Follows your macOS appearance, including the automatic light/dark switch at sunset."
        case .light: "Always light, whatever macOS is set to."
        case .dark: "Always dark, whatever macOS is set to."
        }
    }
}
