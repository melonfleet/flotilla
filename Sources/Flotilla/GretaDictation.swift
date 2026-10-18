import AppKit
import AVFoundation
import Speech
import FlotillaCore

/// Greta's microphone button (DECISIONS Q61): dictation that never leaves this Mac.
///
/// `SpeechAnalyzer` with `SpeechTranscriber`, which recognise on the device by design. There is no
/// `SFSpeechRecognizer` here, and no fallback of any kind: a language the transcriber doesn't offer
/// disables the button. The only network use is `AssetInstallationRequest.downloadAndInstall()`,
/// Apple's system download of the speech model, and it runs only after the user presses Download.
///
/// The rules about where the button can be live in `DictationMachine` (FlotillaCore, tested); this
/// class does the audio and the framework calls, and feeds the machine what happened.
@MainActor
@Observable
final class GretaDictation {
    private(set) var state: DictationState = .idle
    /// A one-line note for the panel: why dictation stopped, or what failed.
    private(set) var message: String?
    /// The language dictation will recognise, named for the user ("English (United States)").
    private(set) var languageName = ""

    /// How the composer that is on screen reads and writes its text. Nil when none is.
    struct Composer {
        var read: () -> String
        var write: (String) -> Void
    }
    @ObservationIgnored private var composer: Composer?

    @ObservationIgnored private var locale: Locale?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var feed: AudioFeed?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var base = ""
    @ObservationIgnored private var finalized: [String] = []
    @ObservationIgnored private var volatile = ""
    @ObservationIgnored private var lastDelivered: String?
    /// The model download, kept apart from `task` so switching windows doesn't abandon it.
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// Set by Download, cleared by anything that stops or leaves dictation. A finished download
    /// starts listening only while this holds (Kyle, 18 October).
    @ObservationIgnored private var listenAfterDownload = false
    /// A reservation this app made only to look, released if the user says Not Now.
    @ObservationIgnored private var probeReservation: Locale?

    var isListening: Bool { state == .listening }
    /// The ⇧⌘D menu command is offered only while a composer is on screen to take the words.
    var canToggle: Bool { composer != nil && (state == .idle || state == .listening || state == .denied) }

    // MARK: - Attaching

    /// A composer appeared. Also works out, once, whether this Mac can dictate in the user's language.
    func attach(_ composer: Composer) {
        self.composer = composer
        guard locale == nil, state != .unsupported else { return }
        Task { _ = await resolveLocale() }
    }

    func detach() {
        stop(finalize: false)
        listenAfterDownload = false
        composer = nil
    }

    private func apply(_ event: DictationEvent) {
        let was = state
        state = DictationMachine.reduce(state, event)
        // A chime on each edge, so it's audible when the microphone opens and closes (Kamal).
        if was != .listening, state == .listening { DictationSound.begin.play() }
        if was == .listening, state != .listening { DictationSound.end.play() }
    }

    /// The user's current language, if `SpeechTranscriber` offers it. Nil marks the button
    /// unsupported; it is never swapped for some other language.
    private func resolveLocale() async -> Locale? {
        if let locale { return locale }
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            languageName = Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
            apply(.modelChecked(.unsupported))
            return nil
        }
        locale = supported
        languageName = Locale.current.localizedString(forIdentifier: supported.identifier) ?? supported.identifier
        return supported
    }

    private func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    // MARK: - The button

    func toggle() {
        switch state {
        case .listening: stop(finalize: true)
        case .idle, .denied: begin()
        case .needsModel, .downloading, .unsupported: break
        }
    }

    private func begin() {
        guard !starting, composer != nil else { return }
        starting = true
        message = nil
        let mine = UUID()
        session = mine
        task = Task { [weak self] in
            await self?.checkAndListen(session: mine)
            self?.starting = false
        }
    }

    private func checkAndListen(session mine: UUID) async {
        // 1. The microphone, as it stands. This never prompts; the prompt comes after the model.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .denied, .restricted:
            apply(.permissionChecked(.denied))
            return
        default:
            if state == .denied { apply(.permissionChecked(.granted)) }
        }

        // 2. The speech model. Missing means the user is asked; nothing is fetched here.
        guard let locale = await resolveLocale(), session == mine else { return }
        let transcriber = makeTranscriber(locale)
        var model = await AssetInventory.status(forModules: [transcriber])
        if model == .supported {
            // Often the model is already on this Mac (macOS's own dictation put it there) and only
            // this app's reservation is missing, which is local bookkeeping and fetches nothing.
            // Reserve, then ask again, so the Download prompt appears only for a real download.
            await reserveForProbe(locale)
            model = await AssetInventory.status(forModules: [transcriber])
            if model == .installed { probeReservation = nil }   // in use now: keep it
        }
        guard session == mine else { return }
        switch model {
        case .installed: break
        case .unsupported: apply(.modelChecked(.unsupported)); return
        case .supported, .downloading: apply(.modelChecked(.needsDownload)); return
        @unknown default: apply(.modelChecked(.needsDownload)); return
        }
        guard session == mine else { return }

        // 3. Ask for the microphone, the first time only.
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { apply(.permissionChecked(.denied)); return }
            guard session == mine else { return }
        }

        // 4. Listen.
        do {
            try await listen(transcriber: transcriber, session: mine)
        } catch {
            teardown()
            message = "Dictation couldn't start: \(error.localizedDescription)"
            apply(.failed)
        }
    }

    private func listen(transcriber: SpeechTranscriber, session mine: UUID) async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.noAudioFormat
        }
        // Stopped while waiting for the format: never open the microphone (Kyle, 18 October).
        guard session == mine, !Task.isCancelled else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let feed = AudioFeed()
        try await analyzer.start(inputSequence: stream)
        // And again after starting the analyser, before the engine and its tap exist.
        guard session == mine, !Task.isCancelled else {
            continuation.finish(); await analyzer.cancelAndFinishNow()
            return
        }
        do {
            try feed.start(target: format, into: continuation)
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        guard session == mine else {
            feed.stop(); continuation.finish(); await analyzer.cancelAndFinishNow()
            return
        }
        self.feed = feed
        self.analyzer = analyzer
        base = composer?.read() ?? ""
        finalized = []
        volatile = ""
        lastDelivered = base
        // `.permissionChecked(.granted)` is the machine's step from idle to listening.
        apply(.permissionChecked(.granted))
        resetSilenceTimer()
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.received(text, isFinal: result.isFinal, session: mine)
                }
            } catch {
                self?.resultsFailed(error, session: mine)
            }
        }
    }

    // MARK: - Words in

    private func received(_ text: String, isFinal: Bool, session mine: UUID) {
        guard session == mine, composer != nil else { return }
        // The user typed in the field since we last wrote to it: their words win, dictation ends.
        if let composer, let lastDelivered, composer.read() != lastDelivered {
            stop(finalize: false)
            return
        }
        if isFinal {
            finalized.append(text)
            volatile = ""
        } else {
            volatile = text
        }
        let combined = DictationText.compose(
            base: base, dictated: DictationText.transcript(finalized: finalized, volatile: volatile))
        lastDelivered = combined
        composer?.write(combined)
        if state == .listening { resetSilenceTimer() }
    }

    private func resultsFailed(_ error: Error, session mine: UUID) {
        guard session == mine, state == .listening else { return }
        stop(finalize: false)
        message = "Dictation stopped: \(error.localizedDescription)"
    }

    /// The field changed under us (a keystroke, a paste, Send clearing it).
    func textChanged(to text: String) {
        // Typing while the model downloads means they've moved on: don't open the mic after it.
        if case .downloading = state { listenAfterDownload = false }
        guard state == .listening, let lastDelivered, text != lastDelivered else { return }
        stop(finalize: false)
    }

    // MARK: - Stopping

    /// `finalize` lets the recogniser finish the word it is hearing, which is right for a click on
    /// the mic. Send, typing, a closed panel and a lost window drop it instead: those must not have
    /// words arrive in a field afterwards.
    func stop(finalize: Bool) {
        listenAfterDownload = false
        silenceTask?.cancel(); silenceTask = nil
        task?.cancel()
        let analyzer = analyzer, feed = feed, results = resultsTask
        self.analyzer = nil; self.feed = nil
        feed?.stop()
        if state == .listening { apply(.stopped) }
        if finalize, let analyzer {
            // The last words arrive after the button has gone idle, under the same session. A new
            // click, typing, or `stop(finalize: false)` rotates the session and they are dropped.
            let finishing = session
            Task { [weak self] in
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
                self?.finished(finishing)
            }
        } else {
            session = UUID()                   // anything from the old session is ignored from here
            results?.cancel()
            resultsTask = nil
            if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        }
    }

    private func finished(_ finishing: UUID) {
        if session == finishing { resultsTask = nil }
    }

    private func teardown() {
        feed?.stop(); feed = nil
        resultsTask?.cancel(); resultsTask = nil
        silenceTask?.cancel(); silenceTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    private func resetSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DictationMachine.silenceTimeout))
            guard !Task.isCancelled else { return }
            self?.silenceElapsed()
        }
    }

    private func silenceElapsed() {
        guard state == .listening else { return }
        stop(finalize: true)
        message = "Stopped listening after a minute of silence."
    }

    // MARK: - The model

    /// The Download button. The one place anything leaves this Mac: Apple's system download of
    /// the speech model, started by this click and by nothing else.
    func download() {
        guard state == .needsModel, let locale else { return }
        apply(.downloadRequested)
        message = nil
        probeReservation = nil                  // asked for: the reservation is wanted now
        listenAfterDownload = true
        downloadTask = Task { [weak self] in
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let progress = request.progress
                    let poll = Task { [weak self] in
                        while !Task.isCancelled {
                            let fraction = progress.fractionCompleted
                            self?.apply(.downloadProgress(fraction > 0 ? fraction : nil))
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                    defer { poll.cancel() }
                    try await request.downloadAndInstall()
                }
                _ = try await AssetInventory.reserve(locale: locale)
                self?.downloadFinished()
            } catch {
                self?.listenAfterDownload = false
                self?.message = "The download didn't finish: \(error.localizedDescription)"
                self?.apply(.downloadFailed)
            }
        }
    }

    /// The click on the mic asked to dictate, so carry it on, but only if nothing has happened
    /// since: no stop, no lost key window, no other app in front, the composer still there.
    private func downloadFinished() {
        apply(.downloadFinished)
        let carryOn = listenAfterDownload && composer != nil && NSApp.isActive && NSApp.keyWindow != nil
        listenAfterDownload = false
        if carryOn { begin() } else { message = "Speech recognition for \(languageName) is ready. Click the mic to dictate." }
    }

    /// Reserves `locale` to see whether the model is already here, remembering whether this was
    /// a new reservation so Not Now can give it back. Stale reservations for other languages are
    /// released first, so the per-app quota can't fill up as the language changes.
    private func reserveForProbe(_ locale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        let isNew = !reserved.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        for stale in reserved where stale.identifier(.bcp47) != locale.identifier(.bcp47) {
            await AssetInventory.release(reservedLocale: stale)
        }
        guard isNew else { return }
        if (try? await AssetInventory.reserve(locale: locale)) == true { probeReservation = locale }
    }

    /// "Not now": back to the idle button without fetching anything.
    func dismissModelPrompt() {
        apply(.stopped); message = nil
        if let probe = probeReservation {
            probeReservation = nil
            Task { await AssetInventory.release(reservedLocale: probe) }
        }
    }

    func dismissMessage() { message = nil }

    /// The Privacy & Security ▸ Microphone pane. Opened for the user; nothing is changed.
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}

enum DictationError: LocalizedError {
    case noAudioFormat
    case noConverter

    var errorDescription: String? {
        switch self {
        case .noAudioFormat: "no audio format is available for speech recognition"
        case .noConverter: "the microphone's audio format can't be used"
        }
    }
}

/// The microphone, converted to what the analyzer wants. Kept out of the main actor: the tap runs on
/// an audio thread, and a closure written in `@MainActor` code would trap there under Swift 6.
private final class AudioFeed: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    func start(target: AVAudioFormat, into continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: source, to: target) else { throw DictationError.noConverter }
        input.installTap(onBus: 0, bufferSize: 4096, format: source) { buffer, _ in
            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
        }
        self.continuation = continuation
        engine.prepare()
        try engine.start()
    }

    /// Ends the audio, and with it the analyzer's input.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}

/// The chimes macOS's own dictation plays, read from the system rather than shipped, with a
/// standard system sound if a future macOS moves them. Silent when "Play user interface sound
/// effects" is off, as macOS's own are.
@MainActor
enum DictationSound {
    case begin, end

    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static var cache: [DictationSound: NSSound] = [:]

    private var sound: NSSound? {
        if let cached = Self.cache[self] { return cached }
        let (file, fallback) = self == .begin ? ("begin_record.caf", "Tink") : ("end_record.caf", "Pop")
        let loaded = NSSound(contentsOfFile: Self.folder + file, byReference: true) ?? NSSound(named: fallback)
        Self.cache[self] = loaded
        return loaded
    }

    func play() {
        // The global preference; absent means on, which is macOS's default.
        let enabled = UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
        guard enabled, let sound else { return }
        sound.stop()
        sound.play()
    }
}
