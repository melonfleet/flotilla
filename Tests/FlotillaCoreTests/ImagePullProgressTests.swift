import Foundation
import Testing
@testable import FlotillaCore

private func fixtureLines() throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: "pull-progress", withExtension: "txt",
                                             subdirectory: "Fixtures"))
    let transcript = try String(contentsOf: url, encoding: .utf8)
    return transcript.components(separatedBy: .newlines).filter { !$0.isEmpty }
}

private func expectProgress(
    _ line: String,
    step: Int,
    stepCount: Int,
    phase: ImagePullProgress.Phase,
    platform: String?,
    fraction: Double?,
    detail: String?,
    elapsed: TimeInterval
) throws {
    let progress = try #require(ImagePullProgress(line: line))
    #expect(progress.step == step)
    #expect(progress.stepCount == stepCount)
    #expect(progress.phase == phase)
    #expect(progress.platform == platform)
    #expect(progress.fraction == fraction)
    #expect(progress.detail == detail)
    #expect(progress.elapsed == elapsed)
}

@Test func parsesFetchingWithoutOptionalFields() throws {
    try expectProgress("[1/2] Fetching image [0s]", step: 1, stepCount: 2, phase: .fetching,
                       platform: nil, fraction: nil, detail: nil, elapsed: 0)
}

@Test func parsesFetchingWithDetail() throws {
    try expectProgress("[1/2] Fetching image (2 of 17 blobs) [3s]", step: 1, stepCount: 2,
                       phase: .fetching, platform: nil, fraction: nil,
                       detail: "2 of 17 blobs", elapsed: 3)
}

@Test func parsesFetchingWithPercentageAndVerbatimDetail() throws {
    try expectProgress("[1/2] Fetching image 8% (18 of 96 blobs, 3.7/45.0 MB, 5 KB/s) [7s]",
                       step: 1, stepCount: 2, phase: .fetching, platform: nil, fraction: 0.08,
                       detail: "18 of 96 blobs, 3.7/45.0 MB, 5 KB/s", elapsed: 7)
}

@Test func parsesUnpackingWithoutOptionalFields() throws {
    try expectProgress("[2/2] Unpacking image [32s]", step: 2, stepCount: 2, phase: .unpacking,
                       platform: nil, fraction: nil, detail: nil, elapsed: 32)
}

@Test func parsesUnpackingWithPlatform() throws {
    try expectProgress("[2/2] Unpacking image for platform linux/amd64 [32s]", step: 2,
                       stepCount: 2, phase: .unpacking, platform: "linux/amd64", fraction: nil,
                       detail: nil, elapsed: 32)
}

@Test func parsesUnpackingWithPlatformAndPercentage() throws {
    try expectProgress("[2/2] Unpacking image for platform linux/s390x 0% [41s]", step: 2,
                       stepCount: 2, phase: .unpacking, platform: "linux/s390x", fraction: 0,
                       detail: nil, elapsed: 41)
}

@Test func parsesUnpackingWithPlatformAndDetail() throws {
    try expectProgress("[2/2] Unpacking image for platform linux/s390x (1 entries) [41s]", step: 2,
                       stepCount: 2, phase: .unpacking, platform: "linux/s390x", fraction: nil,
                       detail: "1 entries", elapsed: 41)
}

@Test func parsesUnpackingWithEveryOptionalField() throws {
    try expectProgress("[2/2] Unpacking image for platform linux/s390x 100% (691 entries, 12.7 MB) [35s]",
                       step: 2, stepCount: 2, phase: .unpacking, platform: "linux/s390x",
                       fraction: 1, detail: "691 entries, 12.7 MB", elapsed: 35)
}

@Test func acceptsDecimalElapsedTime() throws {
    try expectProgress("[1/2] Fetching image [7.5s]", step: 1, stepCount: 2, phase: .fetching,
                       platform: nil, fraction: nil, detail: nil, elapsed: 7.5)
}

@Test func parsesEveryCapturedProgressLineInOrder() throws {
    let progress = try fixtureLines().map { line in
        try #require(ImagePullProgress(line: line), "Unparsed fixture line: \(line)")
    }

    var stepSequence: [Int] = []
    for item in progress where stepSequence.last != item.step {
        stepSequence.append(item.step)
    }
    #expect(stepSequence == [1, 2])

    for (earlier, later) in zip(progress, progress.dropFirst()) {
        #expect(later.elapsed >= earlier.elapsed)
    }

    let last = try #require(progress.last)
    #expect(last.phase == .unpacking)
    #expect(last.fraction == 1)
}

@Test func rejectsNonProgressLines() {
    let lines = [
        "",
        "   ",
        "Error: failed to pull image",
        "[oops] Fetching image [1s]",
    ]

    for line in lines {
        #expect(ImagePullProgress(line: line) == nil)
    }
}

@Test func capturedBlobTotalCanIncreaseAsTheManifestIsDiscovered() throws {
    let details = try fixtureLines().compactMap { ImagePullProgress(line: $0)?.detail }
    let early = try #require(details.first { $0.hasSuffix("of 17 blobs") })
    let later = try #require(details.first { $0.contains("of 96 blobs") })

    func blobTotal(_ detail: String) throws -> Int {
        let words = detail.split(separator: " ")
        let ofIndex = try #require(words.firstIndex(of: "of"))
        return try #require(Int(words[words.index(after: ofIndex)]))
    }

    #expect(try blobTotal(early) < blobTotal(later))
}
