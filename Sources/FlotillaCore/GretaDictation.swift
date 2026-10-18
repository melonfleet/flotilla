import Foundation

/// Where Greta's microphone button is (DECISIONS Q61). Speech is recognised on this Mac only; the
/// one thing that ever leaves it is the user-approved download of Apple's speech model.
///
/// Pure value logic, so the rules are tested without a microphone: `DictationState` is every place
/// the button can be, `DictationEvent` is everything that moves it, and `reduce` is the only way
/// from one to the next.
public enum DictationState: Equatable, Sendable {
    /// Ready: a click starts listening (after checking the model and the microphone).
    case idle
    /// The speech model for this language isn't installed. Nothing downloads until the user says so.
    case needsModel
    /// Apple's system API is fetching the model; `fraction` is 0...1, or nil while it is unknown.
    case downloading(fraction: Double?)
    case listening
    /// The user has refused (or macOS restricts) the microphone.
    case denied
    /// On-device recognition isn't offered for this language on this Mac. Never a server fallback.
    case unsupported
}

public enum DictationEvent: Equatable, Sendable {
    /// The button was clicked.
    case tapped
    /// The model check finished: whether it is installed, downloadable, or not offered at all.
    case modelChecked(ModelAvailability)
    case permissionChecked(MicrophonePermission)
    /// The user pressed Download.
    case downloadRequested
    case downloadProgress(Double?)
    case downloadFinished
    case downloadFailed
    /// Click again, Esc, Send, the window losing key, the panel closing, or 60 seconds of silence.
    case stopped
    /// The audio engine or analyzer failed while listening.
    case failed
}

public enum ModelAvailability: Equatable, Sendable {
    case installed
    case needsDownload
    case unsupported
}

public enum MicrophonePermission: Equatable, Sendable {
    case granted
    case notAsked
    case denied
}

public enum DictationMachine {
    /// Seconds of silence after which listening stops by itself.
    public static let silenceTimeout: TimeInterval = 60

    public static func reduce(_ state: DictationState, _ event: DictationEvent) -> DictationState {
        switch (state, event) {
        // A language with no on-device model disables the button for good: no event revives it.
        case (.unsupported, _):
            return .unsupported
        case (_, .modelChecked(.unsupported)):
            return .unsupported

        case (.listening, .stopped), (.listening, .failed), (.listening, .tapped):
            return .idle
        case (.listening, _):
            return .listening

        // A download in flight can't be restarted by clicking again, and can't be abandoned either:
        // the system API owns it.
        case (.downloading, .downloadProgress(let fraction)):
            return .downloading(fraction: fraction)
        case (.downloading, .downloadFinished):
            return .idle
        case (.downloading, .downloadFailed):
            return .needsModel
        case (.downloading, _):
            return state

        case (.needsModel, .downloadRequested):
            return .downloading(fraction: nil)
        case (.needsModel, .modelChecked(.installed)):
            return .idle
        case (.needsModel, .stopped):
            return .idle
        case (.needsModel, _):
            return .needsModel

        case (.denied, .permissionChecked(.granted)):
            return .idle
        case (.denied, .tapped):
            return .denied
        case (.denied, _):
            return .denied

        case (.idle, .modelChecked(.needsDownload)):
            return .needsModel
        case (.idle, .permissionChecked(.denied)):
            return .denied
        case (.idle, .permissionChecked(.granted)):
            return .listening
        case (.idle, _):
            return .idle
        }
    }
}

/// How dictated words join what the user had already typed.
public enum DictationText {
    /// `base` is the field's text when listening began; it stays exactly as it was. The dictated
    /// words go at its end, with one space between unless `base` already ends in whitespace.
    /// Dictated text is trimmed: the recogniser's own leading or trailing space isn't the user's.
    public static func compose(base: String, dictated: String) -> String {
        let words = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return base }
        guard let last = base.last else { return words }
        return last.isWhitespace ? base + words : base + " " + words
    }

    /// The dictated text so far: finished segments in order, then the segment still being heard.
    public static func transcript(finalized: [String], volatile: String) -> String {
        (finalized + [volatile])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
