import SwiftUI

/// What a form says about one field.
///
/// `summary` is the single line that used to sit under the control, and still does when the
/// window is too narrow for the rail. The other three are what the rail exists for: room to say
/// what the field is *for*, show worked examples, and name the trap — the things that never fitted
/// on one line and so were left out.
///
/// It is `ExpressibleByStringLiteral` so a field with nothing more to say stays a plain string at
/// the call site; only fields that earn a paragraph pay for one.
struct FieldHelp: Equatable, Sendable, ExpressibleByStringLiteral {
    /// One line. Shown inline when there is no rail, and the rail's opening sentence.
    let summary: String
    /// What the field is for, in a sentence or two. Rail only.
    var detail: String?
    /// Worked examples, one per line, rendered monospaced. Rail only.
    var example: String?
    /// The specific way this field goes wrong. Rail only, and marked as a warning.
    var warning: String?

    init(stringLiteral value: String) { self.summary = value }

    init(_ summary: String, detail: String? = nil, example: String? = nil, warning: String? = nil) {
        self.summary = summary
        self.detail = detail
        self.example = example
        self.warning = warning
    }
}

/// One field's entry in the rail, collected from the field itself.
struct FormFieldGuide: Equatable, Sendable, Identifiable {
    let label: String
    let help: FieldHelp
    var id: String { label }
}

/// Carries each field's help up to the scaffold.
///
/// A SwiftUI preference rather than a table passed down, because the alternative is declaring every
/// field's help twice — once at the field and once in a dictionary keyed by its label — where the
/// key silently not matching is the failure mode. Preferences also collect in view-tree order, so
/// the rail reads in the same order as the form without anyone maintaining a second ordering.
struct FormGuideKey: PreferenceKey {
    static var defaultValue: [FormFieldGuide] { [] }
    static func reduce(value: inout [FormFieldGuide], nextValue: () -> [FormFieldGuide]) {
        value.append(contentsOf: nextValue())
    }
}

extension EnvironmentValues {
    /// Set by `FormScaffold`. `FormField` reads it to decide whether to draw its own summary line
    /// or leave it to the rail — without it the same sentence appears twice.
    @Entry var formRailVisible: Bool = false
}

/// A create form: a column of fields, and a rail explaining every one of them.
///
/// The rail exists because the window had a third of its width empty whenever a form was open,
/// while the guidance that would have filled it was compressed into one line per field. The
/// complaint was both halves of that: the forms did not look good, and a one-liner could not say
/// enough.
///
/// **The rail is static and scrolls.** The first version tracked the focused field and showed only
/// that one — which read well but did not work: a tap lands on the `TextField`, not on the row
/// behind it, so clicking *into* a field left the rail on whatever you had last clicked *beside*.
/// Chasing focus through every control type is a lot of mechanism to buy one card at a time, and
/// showing everything at once is what was asked for to begin with.
///
/// Below `railWidthThreshold` the rail is dropped and `FormField` puts its summary back under the
/// control, so a narrow window degrades to exactly the previous layout rather than to a form with
/// no guidance at all.
struct FormScaffold<Fields: View, Preview: View>: View {
    @ViewBuilder var fields: Fields
    /// Pinned at the top of the rail — the validated command, which used to be the last thing on a
    /// long scroll and so was read last, if at all.
    @ViewBuilder var preview: Preview

    @State private var entries: [FormFieldGuide] = []

    /// The column is 640 and the rail wants ~340 before it is too cramped to be worth the space;
    /// with the sidebar and padding that lands here. Measured against the shipping window, 1441.
    private static var railWidthThreshold: CGFloat { 1000 }

    var body: some View {
        GeometryReader { geometry in
            let showsRail = geometry.size.width >= Self.railWidthThreshold

            HStack(alignment: .top, spacing: 28) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        fields
                        // Without a rail the preview has nowhere else to be, and a form that
                        // cannot show what it is about to run is worse than a cramped one.
                        if !showsRail { preview }
                    }
                    .padding(20)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Capped so the rail sits beside the fields rather than across a gap: an unbounded
                // ScrollView takes every point the rail is not using, and the column inside it
                // stays 640 either way — so the surplus showed up as dead space between the two.
                .frame(maxWidth: 680)

                if showsRail {
                    rail
                        .frame(maxWidth: 520)
                        .padding(.vertical, 20)
                        .padding(.trailing, 20)
                }
            }
            .environment(\.formRailVisible, showsRail)
            .onPreferenceChange(FormGuideKey.self) { entries = $0 }
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pinned, not scrolled with the guidance: it changes as you type, and a preview of
            // what is about to run is the one thing worth keeping in view the whole time.
            card { preview }

            if !entries.isEmpty {
                ScrollView {
                    card {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Divider().padding(.vertical, 2)
                            }
                            FormGuideEntry(entry: entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.hairline.opacity(0.35), lineWidth: 1)
        )
    }
}

/// One field's block in the rail.
private struct FormGuideEntry: View {
    let entry: FormFieldGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 3, height: 14)
                Text(entry.label)
                    .font(.subheadline.weight(.semibold))
            }
            Text(entry.help.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = entry.help.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let example = entry.help.example {
                Text(example)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
            if let warning = entry.help.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
