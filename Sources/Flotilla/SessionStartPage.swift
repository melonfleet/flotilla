import SwiftUI
import AppKit

/// The page a tab shows before it does anything (Kamal, 18 October): a container's Terminal, a
/// machine's shell, a host's SSH, Screen Sharing and Files.
///
/// Laid out like the Files and Screen Sharing pages Kamal liked — a heading with the thing's
/// status, one paragraph on what it is, then left-aligned cards, the first with the button that
/// starts it. It replaced a `ContentUnavailableView` centred in the pane on Terminal and Shell,
/// and SSH's habit of connecting the moment its tab was clicked. A click on a tab now only ever
/// shows a page; the button on the page is what runs something. Once a session is open the tab is
/// the terminal, as before, and a tab whose item already has one goes straight to it.
struct SessionStartPage<Cards: View>: View {
    let systemImage: String
    let title: String
    let statusColour: Color
    let statusLine: String
    /// What it is, in a sentence or two.
    let purpose: String
    @ViewBuilder let cards: () -> Cards

    /// The cards' width, the same as the Files and Screen Sharing pages'.
    static var cardWidth: CGFloat { 520 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage).font(.system(size: 22)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.title3.weight(.semibold))
                        HStack(spacing: 5) {
                            Circle().fill(statusColour).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(statusLine).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text(purpose).font(.callout)
                    .lineLimit(5).frame(maxWidth: Self.cardWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) { cards() }
                    .frame(maxWidth: Self.cardWidth, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// How the last thing a start page ran ended, with what it printed last — its terminal is gone.
struct SessionOutcome: Equatable {
    enum Tone { case done, problem }
    let tone: Tone
    let message: String
    var output = ""

    static func problem(_ message: String, output: String = "") -> Self { .init(tone: .problem, message: message, output: output) }
    static func done(_ message: String, output: String = "") -> Self { .init(tone: .done, message: message, output: output) }
}

struct SessionOutcomeNote: View {
    let outcome: SessionOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(outcome.message, systemImage: outcome.tone == .done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(outcome.tone == .done ? Theme.online : Theme.warning).font(.callout)
                .lineLimit(4)
            if !outcome.output.isEmpty {
                Text(outcome.output).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6)
            }
        }
    }
}

/// A command shown as it will run: monospaced, selectable, quiet.
struct SessionCommandLine: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            .textSelection(.enabled).lineLimit(3)
    }
}
