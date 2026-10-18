import XCTest
@testable import FlotillaCore

final class GretaDictationTests: XCTestCase {
    private func run(_ start: DictationState, _ events: [DictationEvent]) -> DictationState {
        events.reduce(start) { DictationMachine.reduce($0, $1) }
    }

    func testHappyPathListensThenStops() {
        XCTAssertEqual(run(.idle, [.modelChecked(.installed), .permissionChecked(.granted)]), .listening)
        XCTAssertEqual(run(.listening, [.tapped]), .idle)
        XCTAssertEqual(run(.listening, [.stopped]), .idle)
        XCTAssertEqual(run(.listening, [.failed]), .idle)
    }

    func testMissingModelWaitsForAnExplicitDownload() {
        let waiting = run(.idle, [.modelChecked(.needsDownload)])
        XCTAssertEqual(waiting, .needsModel)
        // Clicking the mic again, or anything else, does not start a download.
        XCTAssertEqual(run(waiting, [.tapped, .permissionChecked(.granted)]), .needsModel)
        XCTAssertEqual(run(waiting, [.downloadRequested]), .downloading(fraction: nil))
    }

    func testDownloadProgressFinishFailAndNoRestart() {
        let going = DictationState.downloading(fraction: nil)
        XCTAssertEqual(run(going, [.downloadProgress(0.4)]), .downloading(fraction: 0.4))
        XCTAssertEqual(run(going, [.downloadProgress(0.4), .tapped, .downloadRequested]), .downloading(fraction: 0.4))
        XCTAssertEqual(run(going, [.downloadFinished]), .idle)
        XCTAssertEqual(run(going, [.downloadFailed]), .needsModel)
    }

    func testListeningIsNeverEnteredWithoutPermission() {
        XCTAssertEqual(run(.idle, [.permissionChecked(.denied)]), .denied)
        XCTAssertEqual(run(.idle, [.permissionChecked(.notAsked)]), .idle)
        XCTAssertEqual(run(.denied, [.tapped, .modelChecked(.installed)]), .denied)
        XCTAssertEqual(run(.denied, [.permissionChecked(.granted)]), .idle)
    }

    func testUnsupportedLanguageIsTerminal() {
        XCTAssertEqual(run(.idle, [.modelChecked(.unsupported)]), .unsupported)
        XCTAssertEqual(run(.needsModel, [.modelChecked(.unsupported)]), .unsupported)
        let events: [DictationEvent] = [.tapped, .downloadRequested, .downloadFinished,
                                        .permissionChecked(.granted), .modelChecked(.installed)]
        XCTAssertEqual(run(.unsupported, events), .unsupported)
    }

    func testStoppedWhileIdleOrWaitingDoesNotListen() {
        XCTAssertEqual(run(.idle, [.stopped]), .idle)
        XCTAssertEqual(run(.needsModel, [.stopped]), .idle)
    }

    func testComposeKeepsWhatWasTypedAndAppendsAtTheEnd() {
        XCTAssertEqual(DictationText.compose(base: "list my", dictated: "containers"), "list my containers")
        XCTAssertEqual(DictationText.compose(base: "list my ", dictated: "containers"), "list my containers")
        XCTAssertEqual(DictationText.compose(base: "line one\n", dictated: "two"), "line one\ntwo")
        XCTAssertEqual(DictationText.compose(base: "", dictated: "  hello "), "hello")
        XCTAssertEqual(DictationText.compose(base: "typed", dictated: "  "), "typed")
    }

    func testTranscriptJoinsFinishedSegmentsThenTheVolatileOne() {
        XCTAssertEqual(DictationText.transcript(finalized: ["start the", " web server "], volatile: "on port"),
                       "start the web server on port")
        XCTAssertEqual(DictationText.transcript(finalized: [], volatile: ""), "")
    }

    func testSilenceTimeoutIsSixtySeconds() {
        XCTAssertEqual(DictationMachine.silenceTimeout, 60)
    }
}
