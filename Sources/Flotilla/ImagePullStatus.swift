import SwiftUI
import FlotillaCore

/// A pull in flight, in two sizes.
///
/// Shared because a pull outlives its form: the compact form sits in the Images list so that
/// pressing Back during a forty-second pull does not look exactly like the pull having been
/// cancelled, and the full form is the New Image screen while its own pull runs. Two copies of
/// this would be two chances for the list and the form to disagree about what is happening.
struct ImagePullStatus: View {
    let pull: AppModel.ImagePull
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            HStack(spacing: 8) {
                Text(pull.reference)
                    .font(.system(compact ? .caption : .body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let elapsed = pull.progress?.elapsed {
                    Text("\(Int(elapsed))s")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            // Linear in both states, so the shape does not jump when the first percentage
            // arrives — the early lines carry no percentage at all.
            Group {
                if let fraction = pull.progress?.fraction {
                    ProgressView(value: fraction) { Text(Self.phaseLabel(pull.progress)) }
                } else {
                    ProgressView { Text(Self.phaseLabel(pull.progress)) }
                }
            }
            .progressViewStyle(.linear)
            .font(.caption)

            if let detail = pull.progress?.detail, !compact {
                // The CLI's own wording, passed through. See `ImagePullProgress.detail`.
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func phaseLabel(_ progress: ImagePullProgress?) -> String {
        guard let progress else { return "Contacting registry…" }
        var label = progress.phase == .fetching ? "Fetching" : "Unpacking"
        if let platform = progress.platform { label += " \(platform)" }
        return "\(label) · step \(progress.step) of \(progress.stepCount)"
    }
}
