import SwiftUI
import AppKit
import FlotillaCore

/// Settings ▸ General ▸ Appearance: pick the light theme and the dark theme from drawn previews.
///
/// **VS Code's model, on the owner's ask**: a small mock-up of the window per theme — the bar, a
/// sidebar with a selected row, and a card of content — rather than a list of names. They are
/// sketches, not screenshots, so they cannot go stale when a screen changes, and each is drawn
/// from `ThemePalette`, the same table the real window reads, so a preview cannot disagree with
/// what it previews.
///
/// Two rows rather than one list, because Auto switches appearance: the user picks a pair, and
/// the window moves between them at sunset. Light offers eight themes, cream and honeydew, and
/// dark four. See `LightTheme`.
struct ThemePickerRow: View {
    enum Appearance { case light, dark }

    let appearance: Appearance
    let model: AppModel

    private var store: SettingsStore { model.settingsStore }

    private var locked: Bool {
        switch appearance {
        case .light: store.isLocked(SettingsKeys.lightTheme)
        case .dark: store.isLocked(SettingsKeys.darkTheme)
        }
    }

    private var title: String { appearance == .light ? "Light theme" : "Dark theme" }

    private var caption: String {
        if locked { return "Managed by your organization." }
        return appearance == .light
            ? "The window bar and background whenever Flotilla draws light."
            : "The window bar and background whenever Flotilla draws dark."
    }

    /// One entry per theme in this row, in the order the enum declares them.
    private struct Option: Identifiable {
        let id: String
        let title: String
        let palette: ThemePalette
        let isDefault: Bool
        let isSelected: Bool
        let choose: () -> Void
    }

    private var options: [Option] {
        switch appearance {
        case .light:
            LightTheme.allCases.map { theme in
                Option(id: theme.rawValue, title: theme.title, palette: theme.palette,
                       isDefault: theme == SettingsKeys.lightTheme.defaultValue,
                       isSelected: theme == model.themeChoice.light,
                       choose: { try? store.set(theme, for: SettingsKeys.lightTheme) })
            }
        case .dark:
            DarkTheme.allCases.map { theme in
                Option(id: theme.rawValue, title: theme.title, palette: theme.palette,
                       isDefault: theme == SettingsKeys.darkTheme.defaultValue,
                       isSelected: theme == model.themeChoice.dark,
                       choose: { try? store.set(theme, for: SettingsKeys.darkTheme) })
            }
        }
    }

    /// Four to a row, at a fixed size — one column per brand bar (the owner, 5 October). Light's
    /// eight come out as a cream row with the honeydew row under it, each bar above its own
    /// honeydew form, and dark's four as one row. Fixed rather than adaptive: an adaptive grid put
    /// five or six on a row in a wide pane, which broke the rows apart; and a sketch scaled down to
    /// fit stops showing the bar's ink.
    private let columns = Array(repeating: GridItem(.fixed(ThemeSketch.size.width), spacing: 12,
                                                    alignment: .topLeading),
                                count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                    if locked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .help("Managed by your organization")
                    }
                }
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(options) { option in
                    ThemeCard(title: option.title, palette: option.palette,
                              isDark: appearance == .dark, isDefault: option.isDefault,
                              isSelected: option.isSelected, action: option.choose)
                }
            }
            .disabled(locked)
        }
        .padding(.vertical, 4)
    }
}

/// One clickable theme: its sketch, its name, and whether it is the install default.
private struct ThemeCard: View {
    let title: String
    let palette: ThemePalette
    let isDark: Bool
    let isDefault: Bool
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ThemeSketch(palette: palette, isDark: isDark)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(border, lineWidth: isSelected ? 2.5 : 1)
                    }
                    // Bottom-right, inside the body: at the top it covered the bar's buttons, which
                    // are part of what the card is previewing.
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(5)
                        }
                    }
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(isSelected ? .semibold : .regular)
                    if isDefault {
                        Text("Default").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { hovering = isEnabled && $0 }
        .animation(.easeOut(duration: 0.09), value: hovering)
        .help(isSelected ? "\(title) is selected" : "Use \(title)")
        .accessibilityLabel("\(title) \(isDark ? "dark" : "light") theme")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var border: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.separator))
    }
}

/// A miniature of the main window in one theme — a mock-up, not a screenshot.
///
/// Everything is drawn with **fixed** colours for the sketch's own appearance, because a dark
/// theme has to look dark even while Settings is light. That rules out the app's dynamic tokens
/// and the system's own dynamic colours, which resolve against the *window's* appearance: the
/// system accent and link colour are resolved explicitly against light or dark instead.
///
/// What is drawn is chosen to show what a theme changes and what it does not: the bar and the
/// background take the theme; the sidebar selection, the link and the chart line are the same in
/// every card of a row.
struct ThemeSketch: View {
    let palette: ThemePalette
    let isDark: Bool

    static let size = CGSize(width: 132, height: 84)

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(Color.black.opacity(isDark ? 0.45 : 0.12)).frame(height: 0.5)
            HStack(spacing: 0) {
                sidebar
                content
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    // MARK: Pieces

    private var bar: some View {
        HStack(spacing: 3) {
            // Traffic lights, at their own colours in every theme — as macOS draws them.
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { hex in
                Circle().fill(Color(hex: hex)).frame(width: 4.5, height: 4.5)
            }
            // The wordmark, as a bar of the theme's ink.
            Capsule().fill(ink).frame(width: 26, height: 3).padding(.leading, 5)
            Spacer(minLength: 0)
            ForEach(0..<2) { _ in
                RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.85)).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 14)
        .background(Color(hex: palette.bar))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            line(width: 16)
            // The selected row: the system accent, the same in every theme.
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 24, height: 7)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.95)).frame(width: 13, height: 2.5)
                        .padding(.leading, 3)
                }
            line(width: 18)
            line(width: 14)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .padding(.leading, 3)
        .frame(width: 30)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: isDark ? 0x2A2A2C : 0xE8E6E3))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            // A card of content on the theme's background: a running row, a link, a chart line.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    Circle().fill(Color(hex: isDark ? 0x7CB342 : 0x4C8C2B)).frame(width: 4, height: 4)
                    line(width: 30)
                }
                Capsule().fill(link).frame(width: 22, height: 2.5)
                sparkline.frame(height: 10)
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: isDark ? 0x312D28 : 0xFFFFFF), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(hairline, lineWidth: 0.5))
            line(width: 40)
            line(width: 28)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: palette.body))
    }

    private var sparkline: some View {
        GeometryReader { geo in
            Path { path in
                let points: [CGFloat] = [0.6, 0.4, 0.55, 0.2, 0.45, 0.3, 0.1]
                for (index, y) in points.enumerated() {
                    let point = CGPoint(x: geo.size.width * CGFloat(index) / CGFloat(points.count - 1),
                                        y: geo.size.height * y)
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            // `Theme.melon`'s values: the chart colour is fixed, whatever the theme.
            .stroke(Color(hex: isDark ? 0xFC4A6B : 0xEE7B4D),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }

    private func line(width: CGFloat) -> some View {
        Capsule()
            .fill(isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.18))
            .frame(width: width, height: 2.5)
    }

    // MARK: Colours

    private var ink: Color { Color(hex: palette.onBar) }

    private var hairline: Color {
        isDark ? Color(hex: 0xA7D98C, opacity: 0.16) : Color(hex: 0x1B5E20, opacity: 0.14)
    }

    private var accent: Color { Self.resolved(.controlAccentColor, dark: isDark) }
    private var link: Color { Self.resolved(.linkColor, dark: isDark) }

    /// A system colour as it would draw in light or dark, independent of the window's own
    /// appearance — what lets the dark sketches show the dark accent inside a light Settings pane.
    private static func resolved(_ color: NSColor, dark: Bool) -> Color {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return Color(nsColor: color) }
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return Color(nsColor: result)
    }
}
