import SwiftUI
import AppKit
// `AppearanceMode` lives in the portable core — the appearance preference is part of the settings
// registry, not a UI detail.
import FlotillaCore

/// A gear button for the window toolbar.
///
/// Reuses `IconActionButtonStyle` (`IconActionButton.swift`) rather than a bare
/// `Image(systemName:)` — a static toolbar glyph with no hover/press feedback is exactly the
/// "did that do anything?" problem that style was built to fix. The action is injected so this
/// file has no dependency on `AppModel` or any view it does not own; whoever wires this into the
/// toolbar decides what "Settings" means.
struct SettingsToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(IconActionButtonStyle())
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

/// Cycles Auto → Light → Dark → Auto, beside the gear.
///
/// **Three states, not two, and it drives the same stored setting Settings does.** The preference
/// has always had three (`AppearanceMode.auto/.light/.dark`), and `auto` is the one this app
/// treats as first-class — `DECISIONS.md`: onboarding asks, with Auto *pre-selected*, and Auto
/// means follow the system. A two-way switch would have to either drop Auto, which is the default
/// most people should stay on, or silently redefine it as "whatever it resolved to last", which is
/// a lie about what the setting says.
///
/// It reads and writes `AppModel.appearance` rather than holding a state of its own, so this and
/// the Settings pane can never disagree — a second source of truth for one preference is how the
/// settings that "drove nothing" happened.
///
/// **Never accent-tinted, deliberately.** It was, on the reasoning that a pinned appearance is an
/// "engaged" state — and on screen it just read as one button being permanently pink, which is the
/// exact noise the links grid was carrying an hour earlier. The accent means *this control is on
/// right now*; a toggle that reports which of three modes you are in is not that, and the glyph
/// already says which one (half-circle, sun, moon) without borrowing a colour to do it.
struct AppearanceToggleButton: View {
    let model: AppModel

    var body: some View {
        IconActionButton(systemImage: systemImage,
                         label: "Appearance: \(title)",
                         help: "Appearance: \(title). Click for \(nextTitle).") {
            model.chooseAppearance(next)
        }
    }

    private var systemImage: String {
        switch model.appearance {
        case .auto: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private var title: String {
        switch model.appearance {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Auto → Light → Dark → Auto. Auto first in the cycle because it is where most people should
    /// end up, so it is never more than two clicks away.
    private var next: AppearanceMode {
        switch model.appearance {
        case .auto: .light
        case .light: .dark
        case .dark: .auto
        }
    }

    private var nextTitle: String {
        switch next {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// One external link offered by `AppLinksMenu`.
///
/// A struct rather than a hand-written `Button` per destination, so the stated near-term
/// change — a third link — is one array element, not a new branch to keep in sync with the
/// other two.
///
/// Every `systemImage` used to build an `AppLink` below has been checked against
/// `NSImage(systemSymbolName:accessibilityDescription:) != nil` before shipping: an unknown
/// name renders nothing at all, with no warning, which is how every overflow menu in this app
/// silently vanished once — see the note on `RowOverflowLabel` in `IconActionButton.swift`.
struct AppLink: Identifiable {
    let name: String
    let url: URL
    let systemImage: String

    var id: String { name }
}

/// A grid-icon toolbar button that opens a menu of external links.
///
/// `NSWorkspace.shared.open` rather than an in-app browser: these are one-off destinations —
/// source, marketing site — not content the app renders or tracks, so there is nothing here
/// worth a WebView or navigation state.
struct AppLinksMenu: View {
    /// Verified to exist: `chevron.left.slash.chevron.right` and `globe`, alongside the
    /// button's own `square.grid.2x2`, via a scratch `NSImage(systemSymbolName:)` check.
    static let links: [AppLink] = [
        AppLink(name: "Flotilla on GitHub",
                url: URL(string: "https://github.com/melonfleet/flotilla")!,
                systemImage: "chevron.left.slash.chevron.right"),
        AppLink(name: "melonfleet.dev",
                url: URL(string: "https://melonfleet.dev")!,
                systemImage: "globe"),
    ]

    var body: some View {
        Menu {
            ForEach(Self.links) { link in
                Button {
                    NSWorkspace.shared.open(link.url)
                } label: {
                    Label(link.name, systemImage: link.systemImage)
                }
            }
        } label: {
            ToolbarMenuGlyph(systemImage: "square.grid.2x2")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Flotilla links")
        .accessibilityLabel("Flotilla links")
    }
}

/// Hover feedback for a toolbar-level menu glyph.
///
/// `Menu` is not a `Button`, so it cannot take `IconActionButtonStyle` — the same constraint
/// noted on `RowOverflowLabel` in `IconActionButton.swift`. That label also reads
/// `backgroundProminence` because it can sit on a selected table row's accent fill; a window
/// toolbar item never does, so this only needs the plain hover tint every other toolbar
/// control uses, matching `IconActionButtonStyle`'s colour and timing rather than inventing a
/// new feel.
private struct ToolbarMenuGlyph: View {
    let systemImage: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemImage)
            // **`.primary` at rest, exactly like every `IconActionButton`.** This was
            // `secondary`-at-rest and accent-on-hover, its own private colour scheme, which is why
            // the links grid read pink while the gear beside it did not. A `Menu` cannot take
            // `IconActionButtonStyle`, so the rule is mirrored here by hand — and it must stay
            // mirrored: hover speaks through the background fill below, never through the glyph.
            .foregroundStyle(Color.primary)
            .frame(width: 18, height: 18)
            .padding(3)
            .background(hovering ? Theme.accent.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.09), value: hovering)
    }
}
