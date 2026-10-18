import CryptoKit
import Foundation
import Testing
import FlotillaCore
@testable import Flotilla

/// `LibraryUpdater.verified` reads schemas 1 and 2 and refuses anything newer, signed or not.
@Suite struct LibraryVerifyTests {
    private let key = Curve25519.Signing.PrivateKey()

    private func signed(schema: Int) throws -> (Data, Data) {
        let data = Data(#"{"schema": \#(schema), "version": "2026.10.18.2", "entries": []}"#.utf8)
        let signature = try key.signature(for: data).base64EncodedString()
        return (data, Data(signature.utf8))
    }

    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    @Test func schemasOneAndTwoAreRead() throws {
        for schema in [1, 2] {
            let (data, signature) = try signed(schema: schema)
            #expect(try LibraryUpdater.verified(data, signature: signature, publicKey: publicKey).schema == schema)
        }
    }

    @Test func aNewerOrUnknownSchemaIsRefused() throws {
        for schema in [0, 3] {
            let (data, signature) = try signed(schema: schema)
            #expect(throws: LibraryUpdater.Failure.self) {
                try LibraryUpdater.verified(data, signature: signature, publicKey: publicKey)
            }
        }
    }

    @Test func theBuiltInKeyStillRefusesATestSignature() throws {
        let (data, signature) = try signed(schema: 2)
        #expect(throws: LibraryUpdater.Failure.self) { try LibraryUpdater.verified(data, signature: signature) }
    }
}
