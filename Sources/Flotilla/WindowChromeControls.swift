import SwiftUI
import AppKit

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
            .foregroundStyle(hovering ? Theme.accentText : Color.secondary)
            .frame(width: 18, height: 18)
            .padding(3)
            .background(hovering ? Theme.accent.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.09), value: hovering)
    }
}
