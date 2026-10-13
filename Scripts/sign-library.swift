// Signs a suggestions library for publishing (DECISIONS Q54).
//
//   swift Scripts/sign-library.swift path/to/library.json
//
// Checks the file decodes as a library this build understands, then signs its exact bytes with the
// library key in the login Keychain ("Flotilla suggestions library signing key") and writes
// `library.json.sig` beside it: the Ed25519 signature, base64. The private key is stored only in the
// owner's login Keychain; signing reads it into this process's memory for the moment it signs, and
// it is never printed or written anywhere. macOS asks to allow the read: choose **Allow**, not
// Always Allow, which would let any Swift script read it (Kyle, 13 October). Flotilla verifies with
// the public key it carries (`LibraryUpdater.publicKey`).
import CryptoKit
import Foundation
import Security

guard CommandLine.arguments.count == 2 else { print("usage: swift Scripts/sign-library.swift library.json"); exit(2) }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let data = try? Data(contentsOf: url) else { print("can't read \(url.path)"); exit(1) }
guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["schema"] as? Int == 1, object["version"] is String, object["entries"] is [Any] else {
    print("\(url.lastPathComponent) isn't a schema-1 library"); exit(1)
}
var item: CFTypeRef?
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: "Flotilla suggestions library signing key",
                            kSecAttrAccount as String: "melonfleet", kSecReturnData as String: true]
guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let raw = item as? Data,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    print("the library signing key isn't in this Mac's Keychain"); exit(1)
}
let signature = try key.signature(for: data)
let sigURL = url.appendingPathExtension("sig")
try Data(signature.base64EncodedString().utf8).write(to: sigURL)
print("signed \(url.lastPathComponent) (version \(object["version"]!), \((object["entries"] as! [Any]).count) entries)")
print("public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
