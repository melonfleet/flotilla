import Foundation
import Security
import CryptoKit
import X509
import SwiftASN1
import FlotillaCore

/// This Mac's identity in host mode (PLAN.md Phase B, B2b): a P-256 key that never leaves the
/// Keychain, and a self-signed certificate for it that TLS presents (B3).
///
/// The **fingerprint** — SHA-256 of the certificate's SubjectPublicKeyInfo — is the identity every
/// other Mac pins. It depends only on the key, so re-issuing the certificate keeps it; replacing the
/// key changes it, and every peer must pair again. That is the manual recovery path when a key is
/// lost or suspected, and it is why nothing ever replaces the key silently.
public struct DeviceIdentity: @unchecked Sendable {
    public let fingerprint: PeerFingerprint
    public let certificate: SecCertificate
    let privateKey: SecKey

    /// For Network.framework's TLS options (B3).
    public func secIdentity() -> SecIdentity? {
        var identity: SecIdentity?
        return SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess ? identity : nil
    }

    /// The fingerprint of any certificate — this Mac's, or the one a peer presents during TLS.
    public static func fingerprint(of certificate: SecCertificate) throws -> PeerFingerprint {
        try fingerprint(of: Certificate(certificate).publicKey)
    }

    static func fingerprint(of publicKey: Certificate.PublicKey) throws -> PeerFingerprint {
        var serializer = DER.Serializer()
        try serializer.serialize(publicKey)
        return PeerFingerprint(bytes: Array(SHA256.hash(data: serializer.serializedBytes)))!
    }
}

/// Where the identity lives: the login Keychain, under one label. Parameterised so tests use their
/// own label and leave the real identity alone.
public struct DeviceIdentityStore: Sendable {
    public let label: String
    var tag: Data { Data(label.utf8) }

    public static let standard = DeviceIdentityStore(label: "dev.melonfleet.Flotilla.identity")

    public init(label: String) { self.label = label }

    public enum IdentityError: Error, Equatable, CustomStringConvertible {
        case keychain(OSStatus, String)
        /// The Keychain kept saying it had deleted something that was still there.
        case stillThere(String)

        public var description: String {
            switch self {
            case .keychain(let status, let step):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "Couldn't \(step) in the Keychain: \(message)"
            case .stillThere(let step):
                return "Couldn't \(step) in the Keychain: it was still there after \(DeviceIdentityStore.deleteAttempts) tries."
            }
        }
    }

    /// One at a time, process-wide. The login Keychain fails `SecKeyCreateRandomKey` with
    /// errSecItemNotFound when two keys are created at once in one process (measured 7 October:
    /// one test run in three, until creation was serialised), so every identity change takes this.
    static let keychainLock = NSLock()

    /// The identity, creating the key or the certificate if either is missing.
    public func loadOrCreate(now: Date = Date()) throws -> DeviceIdentity {
        Self.keychainLock.lock()
        defer { Self.keychainLock.unlock() }
        let key = try existingKey() ?? createKey()
        if let certificate = existingCertificate(), let identity = try? DeviceIdentity(
            fingerprint: DeviceIdentity.fingerprint(of: certificate), certificate: certificate, privateKey: key),
           try identity.fingerprint == DeviceIdentity.fingerprint(of: Certificate.PrivateKey(key).publicKey) {
            return identity
        }
        // No certificate, or one for a different key: issue one for the key we have.
        try deleteCertificates()
        let certificate = try issueCertificate(for: key, now: now)
        return DeviceIdentity(fingerprint: try DeviceIdentity.fingerprint(of: certificate),
                              certificate: certificate, privateKey: key)
    }

    /// The identity if it exists; never creates one.
    public func load() throws -> DeviceIdentity? {
        Self.keychainLock.lock()
        defer { Self.keychainLock.unlock() }
        guard let key = try existingKey(), let certificate = existingCertificate() else { return nil }
        return DeviceIdentity(fingerprint: try DeviceIdentity.fingerprint(of: certificate),
                              certificate: certificate, privateKey: key)
    }

    /// Deletes key and certificate. Every peer must pair with this Mac again afterwards.
    ///
    /// Throws unless both are gone. The Keychain's answer used to be discarded (Kyle's review,
    /// 12 October), so a delete it refused looked like one that worked — and the next
    /// `loadOrCreate` handed the old identity straight back, under a reset that said it was done.
    /// The key goes first: a certificate left without it can never be presented again.
    public func reset() throws {
        Self.keychainLock.lock()
        defer { Self.keychainLock.unlock() }
        try Self.deleteAll(keyQuery, "delete this Mac's key")
        try deleteCertificates()
    }

    /// Whether anything of this identity is in the Keychain — the key, or a certificate under the
    /// label — without creating either. Unlike `load`, a key whose certificate is missing counts:
    /// `loadOrCreate` would issue it a new certificate and the old fingerprint would be back.
    /// Throws when the Keychain can't say, because an error is not an answer.
    public func exists() throws -> Bool {
        Self.keychainLock.lock()
        defer { Self.keychainLock.unlock() }
        return try isPresent(keyQuery, "read this Mac's key") || isPresent(certificateQuery, "read this Mac's certificate")
    }

    // MARK: Keychain

    private var keyQuery: [String: Any] { [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] }
    private var certificateQuery: [String: Any] { [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] }

    /// The most deletes one item may take — see `deleteAll`.
    static let deleteAttempts = 16

    /// Deletes everything `query` matches — the identity's key and certificate, and the enrolment
    /// keys, all go through here. The login Keychain may delete one match per call, so this repeats
    /// until it says nothing matches, which is the only answer that proves the item gone. Any other
    /// answer throws, and so does running out of tries. `delete` is `SecItemDelete` except in
    /// tests, which script it. Callers hold `keychainLock`.
    static func deleteAll(_ query: [String: Any], _ step: String,
                          delete: ([String: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }) throws {
        for _ in 0..<deleteAttempts {
            let status = delete(query)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw IdentityError.keychain(status, step) }
        }
        throw IdentityError.stillThere(step)
    }

    private func isPresent(_ query: [String: Any], _ step: String) throws -> Bool {
        var match = query
        match[kSecReturnRef as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(match as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw IdentityError.keychain(status, step) }
        return true
    }

    private func existingKey() throws -> SecKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result else { throw IdentityError.keychain(status, "read this Mac's key") }
        return (result as! SecKey)
    }

    private func createKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrLabel as String: label,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
            ],
        ] as CFDictionary, &error) else {
            let status = (error?.takeRetainedValue()).map { OSStatus(CFErrorGetCode($0)) } ?? errSecParam
            throw IdentityError.keychain(status, "create this Mac's key")
        }
        return key
    }

    private func existingCertificate() -> SecCertificate? {
        var result: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ] as CFDictionary, &result) == errSecSuccess, let result else { return nil }
        return (result as! SecCertificate)
    }

    /// Every certificate under the label.
    private func deleteCertificates() throws {
        try Self.deleteAll(certificateQuery, "delete this Mac's certificate")
    }

    /// Self-signed, P-256/SHA-256, valid for twenty years: trust is the pinned fingerprint, not the
    /// dates, so an expiring certificate would only be a way for a fleet to stop working one day.
    /// The subject names no person and no computer — it travels to every peer.
    private func issueCertificate(for key: SecKey, now: Date) throws -> SecCertificate {
        let privateKey = try Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("Flotilla") }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(20 * 365 * 24 * 3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            },
            issuerPrivateKey: privateKey)
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        guard let secCertificate = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else {
            throw IdentityError.keychain(errSecDecode, "read the new certificate")
        }
        let status = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCertificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.keychain(status, "save this Mac's certificate") }
        // The login Keychain names a certificate after its subject and ignores the label passed to
        // `SecItemAdd` (measured 7 October: a lookup by label then finds nothing). Set it after.
        let relabel = SecItemUpdate([kSecClass as String: kSecClassCertificate,
                                     kSecValueRef as String: secCertificate] as CFDictionary,
                                    [kSecAttrLabel as String: label] as CFDictionary)
        guard relabel == errSecSuccess else { throw IdentityError.keychain(relabel, "label this Mac's certificate") }
        return secCertificate
    }
}

extension PairingCrypto {
    /// The real thing: HMAC-SHA256 and SHA-256 from CryptoKit, random bytes from the system.
    public static let system = PairingCrypto(
        mac: { key, message in
            Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        },
        digest: { bytes in Array(SHA256.hash(data: bytes)) },
        random: { count in
            var bytes = [UInt8](repeating: 0, count: count)
            precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess,
                         "the system random number generator failed")
            return bytes
        })
}
