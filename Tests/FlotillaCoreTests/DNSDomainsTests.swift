import Foundation
import Testing
@testable import FlotillaCore

// `container system dns list` is the one runtime listing Flotilla cannot capture on its own:
// creating a domain needs an administrator, so `dns-domains.json` was captured from a machine
// where the owner ran `sudo container system dns create flotilla` by hand. It is kept rather
// than regenerated for exactly that reason.
//
// What it pins is how thin the endpoint is. Every other listing — containers, images, volumes,
// networks — returns objects with ids, dates and configuration. This returns bare strings:
//
//     ["flotilla"]
//
// So a DNS section modelled on Networks would be a table with one column and nothing to inspect,
// which is worth knowing before anyone designs one.

@Test func theDNSDomainListingIsBareStringsRatherThanObjects() throws {
    let url = try #require(Bundle.module.url(forResource: "dns-domains", withExtension: "json",
                                             subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    let domains = try JSONDecoder().decode([String].self, from: data)
    #expect(domains == ["flotilla"])
}
