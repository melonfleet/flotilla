import SwiftUI

/// A list of repeatable `key=value` flag values — `--build-arg`, `--label`, `--opt`.
///
/// Shared rather than copied. It began as a private method on `NetworksView` with the cap
/// written into it as the literal `8`, which is that screen's limit and nobody else's:
/// `--build-arg` allows 24. A second copy would have meant two editors that look identical and
/// disagree about how many rows you may add, which is exactly the kind of drift the shared
/// `SectionToolbar` and `CopyMenu` exist to prevent.
///
/// **The cap is shown, not silently enforced.** A disabled Add with no number beside it reads as
/// a bug; `12/24` reads as a rule. The limit is the `Allowlist`'s own `maxRepeats` for that flag,
/// passed in by the caller rather than looked up here — the allowlist is the authority on what a
/// command accepts, and a view that guessed would be a second place to keep in step.
struct KeyValueList: View {
    @Binding var values: [String]
    /// The `Allowlist` flag's `maxRepeats`.
    let limit: Int
    let placeholder: String
    /// Shown above the rows. Omitted when the enclosing `FormField` already names them.
    var title: String?
    /// What one row is, for VoiceOver — "build argument", "label".
    var itemLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let title {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(values.count)/\(limit)")
                    .font(.caption2)
                    .foregroundStyle(values.count >= limit ? AnyShapeStyle(Theme.warning)
                                                          : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            ForEach(values.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: { values.indices.contains(index) ? values[index] : "" },
                        set: { if values.indices.contains(index) { values[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .accessibilityLabel("\(itemLabel) \(index + 1)")
                    Button {
                        values.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(itemLabel) \(index + 1)")
                }
            }
            Button {
                values.append("")
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(values.count >= limit)
            .help(values.count >= limit
                  ? "\(limit) is the most \(itemLabel)s this command accepts"
                  : "Add a \(itemLabel)")
        }
    }
}
