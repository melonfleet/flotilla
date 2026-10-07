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
/// host, or both — decides whether it listens on the network at all, which nobody should find out
/// about later. Admin is pre-selected: it listens on nothing. A profile that sets the mode answers
/// that question, and the sheet says so instead of asking.
struct OnboardingView: View {
    let model: AppModel

    /// Pre-selected, not defaulted — the distinction the store keeps.
    @State private var selection: AppearanceMode = .auto
    @State private var mode: RunMode = .client

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Flotilla")
                    .font(.title2.weight(.semibold))
                Text("How should Flotilla look? You can change this later in Settings.")
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
                        ForEach(RunMode.allCases, id: \.rawValue) { option in Text(option.title).tag(option) }
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

            HStack {
                Spacer()
                Button("Continue") {
                    if !modeLocked { try? model.settingsStore.set(mode, for: SettingsKeys.mode) }
                    model.chooseAppearance(selection)
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var modeLocked: Bool { model.settingsStore.isLocked(SettingsKeys.mode) }

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
