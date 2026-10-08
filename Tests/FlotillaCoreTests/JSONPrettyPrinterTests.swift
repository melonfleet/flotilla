import Foundation
import Testing
@testable import FlotillaCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func prettyPrintSortsTopLevelKeys() throws {
    let input = "{\"z\":1,\"a\":2,\"m\":3}"
    let pretty = JSONPrettyPrinter.prettyPrint(input)

    let aIndex = try #require(pretty.range(of: "\"a\""))
    let mIndex = try #require(pretty.range(of: "\"m\""))
    let zIndex = try #require(pretty.range(of: "\"z\""))
    #expect(aIndex.lowerBound < mIndex.lowerBound)
    #expect(mIndex.lowerBound < zIndex.lowerBound)
}

@Test func prettyPrintSortsNestedKeysToo() throws {
    let input = "{\"outer\":{\"z\":1,\"a\":2}}"
    let pretty = JSONPrettyPrinter.prettyPrint(input)

    let aIndex = try #require(pretty.range(of: "\"a\""))
    let zIndex = try #require(pretty.range(of: "\"z\""))
    #expect(aIndex.lowerBound < zIndex.lowerBound)
}

@Test func prettyPrintProducesValidJSONThatRoundTripsTheSameData() throws {
    let input = String(decoding: try fixture("inspect-container"), as: UTF8.self)
    let pretty = JSONPrettyPrinter.prettyPrint(input)

    let originalObject = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [Any]
    let prettyObject = try JSONSerialization.jsonObject(with: Data(pretty.utf8)) as? [Any]
    #expect(originalObject != nil)
    #expect(prettyObject != nil)

    // Re-serialising both with the same (sorted) options must produce identical bytes if
    // the data is unchanged — the pretty-print is a reformat, not a mutation.
    let reNormalizedOriginal = try JSONSerialization.data(
        withJSONObject: originalObject!, options: [.sortedKeys]
    )
    let reNormalizedPretty = try JSONSerialization.data(
        withJSONObject: prettyObject!, options: [.sortedKeys]
    )
    #expect(reNormalizedOriginal == reNormalizedPretty)
}

@Test func prettyPrintReturnsMalformedInputUnchangedRatherThanThrowing() {
    let malformed = "{ this is not valid json "
    #expect(JSONPrettyPrinter.prettyPrint(malformed) == malformed)
}

@Test func prettyPrintReturnsEmptyStringUnchanged() {
    #expect(JSONPrettyPrinter.prettyPrint("") == "")
}
