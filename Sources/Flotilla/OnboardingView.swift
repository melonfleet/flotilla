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
/// Deliberately only appearance. Onboarding that marches through every preference gets
/// dismissed blind, and every other setting has a defensible default; this one does not,
/// because "follow the system" is a choice rather than an absence of one.
struct OnboardingView: View {
    let model: AppModel

    /// Pre-selected, not defaulted — the distinction the store keeps.
    @State private var selection: AppearanceMode = .auto

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

            HStack {
                Spacer()
                Button("Continue") { model.chooseAppearance(selection) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

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
