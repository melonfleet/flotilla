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
struct FieldHelp: Equatable, ExpressibleByStringLiteral {
    /// One line. Shown inline when there is no rail, and as the rail's opening sentence.
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

    /// True when there is more to show than the summary — the rail draws nothing extra otherwise.
    var hasDetail: Bool { detail != nil || example != nil || warning != nil }
}

/// Which field the rail is describing.
///
/// Its own object rather than a `@State` in each form, because both the field (on tap or focus)
/// and the rail need it, and they are siblings — passing a binding down two subtrees is how the
/// two drift out of step.
@MainActor
@Observable
final class FormGuide {
    private(set) var focusedLabel: String?
    private(set) var focusedHelp: FieldHelp?

    /// Set from a field's tap, which is an event — the help therefore stays declared at the one
    /// place that already declares the field, instead of in a second table keyed by a string that
    /// has to be kept in step with it.
    func focus(_ label: String, help: FieldHelp?) {
        focusedLabel = label
        focusedHelp = help
    }
}

extension EnvironmentValues {
    @Entry var formGuide: FormGuide?
    /// Set by `FormScaffold`. `FormField` reads it to decide whether to draw its own summary line
    /// or leave it to the rail — without it the same sentence appears twice.
    @Entry var formRailVisible: Bool = false
}

/// A create form: a fixed column of fields, and a rail that explains the field you are in.
///
/// The rail exists because the window had a third of its width empty whenever a form was open,
/// while the guidance that would have filled it was being compressed into one line per field. The
/// owner's complaint was both halves of that: the forms did not look good, and a one-liner could
/// not say enough.
///
/// Below `railWidthThreshold` the rail is dropped and `FormField` puts its summary back under the
/// control, so a narrow window degrades to exactly the previous layout rather than to a form with
/// no guidance at all.
struct FormScaffold<Fields: View, Preview: View>: View {
    @ViewBuilder var fields: Fields
    /// Shown in the rail under the explainer — the validated command, which used to be the last
    /// thing on a long scroll and so was read last, if at all.
    @ViewBuilder var preview: Preview

    @State private var guide = FormGuide()

    /// The column is 640 and the rail wants ~360 before it is too cramped to be worth the space;
    /// with the sidebar and padding that lands here. Measured against the shipping window, which
    /// is 1441 wide.
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
                // Capped so the rail sits beside the fields rather than across a gap: an
                // unbounded ScrollView takes every point the rail is not using, and the column
                // inside it stays 640 either way — so the surplus showed up as dead space
                // between the two, which is the thing this layout exists to remove.
                .frame(maxWidth: 680)

                if showsRail {
                    // Outside the ScrollView on purpose: the explainer for the field you are in
                    // must not scroll away from the field you are in.
                    FormExplainerRail(title: guide.focusedLabel, help: guide.focusedHelp) { preview }
                        // Takes the rest, up to a point: past about this width the measure gets
                        // too long to read comfortably and the examples start to look stranded.
                        .frame(maxWidth: 520)
                        .padding(.top, 20)
                        .padding(.trailing, 20)
                }
            }
            .environment(\.formGuide, guide)
            .environment(\.formRailVisible, showsRail)
        }
    }
}

/// The rail itself: what the focused field is, and what is about to run.
private struct FormExplainerRail<Preview: View>: View {
    /// The focused field's own label — `FormField` defaults its id to it, and the help table is
    /// keyed by the same string, so the heading cannot drift from the field it describes.
    let title: String?
    let help: FieldHelp?
    @ViewBuilder var preview: Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let help {
                card {
                    HStack(spacing: 8) {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 3, height: 15)
                        Text(title ?? "About this field")
                            .font(.headline)
                    }
                    Text(help.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = help.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let example = help.example {
                        Text(example)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let warning = help.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                // Not an empty state to apologise for: before you touch anything, the useful
                // thing to show is what pressing the button would run.
                card {
                    Text("Select a field to see what it takes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            card { preview }
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
