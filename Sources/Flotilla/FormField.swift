import SwiftUI

/// One labelled field: name above, control below, guidance beneath — everything left-aligned.
///
/// Reading order is the entire point. `.formStyle(.grouped)` puts the label hard against the
/// left edge and the control hard against the right, and in this app's window that is a 400pt
/// jump for every row, with the value right-aligned *inside* the field on top of it. The owner's
/// complaint was precise: the form filled itself "right to left", which made it confusing to
/// read. Label, then control, then explanation, in one direction, fixes that.
///
/// It is also not a new style. `VolumesView` and `NetworksView` already lay their create forms
/// out exactly this way; `MachineFormView`, `RunSheetView` and `BuildImageView` were the three
/// that used grouped `Form`. Extracting the shape the majority already used — rather than
/// inventing a third — is what makes the five create screens read the same.
struct FormField<Content: View>: View {
    let label: String
    /// What the field takes. Its `summary` sits under the control when there is no rail; the rail
    /// shows the whole thing. Never a placeholder — a placeholder vanishes at the exact moment
    /// someone starts typing and most needs to know what belongs there, so the placeholder carries
    /// one specimen value and the rules live here.
    var help: FieldHelp?
    /// A real refusal, coloured as one. It replaces `help` rather than stacking with it, because
    /// two lines of small text under a field is where people stop reading either. An empty field
    /// is not a refusal, so callers pass nil until there is genuinely something wrong.
    var problem: String?
    /// Marks the field as not required, in the label rather than the placeholder — "optional" as
    /// a placeholder reads like a value someone typed.
    var optional: Bool = false
    let content: Content

    init(_ label: String, help: FieldHelp? = nil, problem: String? = nil,
         optional: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.help = help
        self.problem = problem
        self.optional = optional
        self.content = content()
    }

    @Environment(\.formRailVisible) private var railVisible

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                if optional {
                    Text("optional")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }
            content
            // A refusal is shown wherever the rail is, because it is about what you just typed.
            // The summary is not: with a rail it would be the same sentence twice.
            if let problem {
                fieldNote(problem, systemImage: "exclamationmark.circle", style: AnyShapeStyle(Theme.danger))
            } else if let help, !railVisible {
                fieldNote(help.summary, systemImage: nil, style: AnyShapeStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The rail is built from these, in view-tree order. Declared here and nowhere else, so a
        // field and its explanation cannot drift apart.
        .preference(key: FormGuideKey.self,
                    value: help.map { [.field(FormFieldGuide(label: label, help: $0))] } ?? [])
    }

    /// `fixedSize` on the vertical axis so a two-line explanation wraps instead of being
    /// truncated to one — the guidance is the reason this component exists, and a clipped
    /// sentence is worse than none because it looks like the whole sentence.
    private func fieldNote(_ text: String, systemImage: String?, style: AnyShapeStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(style)
    }
}

/// A heading over a group of `FormField`s.
///
/// Replaces `SwiftUI.Section` inside a grouped `Form`, which drew a filled card around each
/// group and pushed the controls to its right edge. Left-aligned text and a rule carry the same
/// grouping without moving anything.
struct FormSectionHeader: View {
    let title: String
    /// One line on what the whole group is for, where that is not obvious from the fields.
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The rail groups under these, in this order, without the grouping being declared twice.
        .preference(key: FormGuideKey.self, value: [.section(title)])
    }
}

/// The column a create form's content sits in.
///
/// Capped, and left-aligned inside the window rather than centred. A text field stretched to
/// 1400pt is not easier to fill in, and the fields, their help text and the command preview all
/// want the same left edge to read down. 640 is the width `VolumesView` already uses.
extension View {
    func formColumn(_ width: CGFloat = 640) -> some View {
        self
            .frame(maxWidth: width, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
