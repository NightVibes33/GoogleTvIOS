import Foundation
import Security

/// One RSA identity per installation, retained in the iOS Keychain. No shared demo certificates.
enum ClientCertificateStore {
    enum Failure: LocalizedError {
        case key(OSStatus)
        case certificate
        case signing
        case identity

        var errorDescription: String? {
            switch self {
            case .key(let status): return "Cannot access the remote identity Keychain (\(status))."
            case .certificate: return "Could not create a device certificate."
            case .signing: return "Could not sign the device certificate."
            case .identity: return "Certificate and private key could not be resolved as a TLS identity."
            }
        }
    }

    static func load() throws -> (identity: SecIdentity, certificate: SecCertificate) {
        let privateKey = try loadPrivateKey()
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let defaults = UserDefaults.standard
        let key = "remote.certificate.der.v1"

        var certificate: SecCertificate?
        if let stored = defaults.data(forKey: key) {
            certificate = SecCertificateCreateWithData(nil, stored as CFData)
        }
        if certificate == nil {
            let encoded = try createCertificate(privateKey: privateKey, publicKey: publicKey)
            certificate = SecCertificateCreateWithData(nil, encoded as CFData)
            guard certificate != nil else { throw Failure.certificate }
            let status = SecItemAdd([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate!,
                kSecAttrLabel as String: "CastDeck Remote Certificate"
            ] as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw Failure.key(status) }
            defaults.set(encoded, forKey: key)
        }
        guard let cert = certificate else { throw Failure.certificate }

        // Match the exact certificate; never accidentally use an unrelated identity.
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let candidates = result as? [SecIdentity] else {
            throw Failure.identity
        }
        let expected = SecCertificateCopyData(cert) as Data
        for identity in candidates {
            var candidate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &candidate) == errSecSuccess,
                  let candidate,
                  (SecCertificateCopyData(candidate) as Data) == expected else { continue }
            return (identity, cert)
        }
        throw Failure.identity
    }

    private static func loadPrivateKey() throws -> SecKey {
        let tag = Data("com.castdeck.remote.identity.v1".utf8)
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let key = item {
            return (key as! SecKey)
        }
        guard status == errSecItemNotFound else { throw Failure.key(status) }
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw Failure.certificate
        }
        return key
    }

    private static func createCertificate(privateKey: SecKey, publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw Failure.certificate
        }
        let algorithm = DER.sequence(DER.oid([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x0B]) + DER.null)
        let rsaAlgorithm = DER.sequence(DER.oid([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01]) + DER.null)
        let name = DER.sequence(DER.set(DER.sequence(
            DER.oid([0x55,0x04,0x03]) + DER.utf8("CastDeck Remote")
        )))
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7F
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let start = Date().addingTimeInterval(-86_400)
        let end = start.addingTimeInterval(86400 * 365 * 9)
        let validity = DER.sequence(
            DER.tlv(0x17, Data(formatter.string(from: start).utf8)) +
            DER.tlv(0x17, Data(formatter.string(from: end).utf8))
        )
        let subjectPublicKeyInfo = DER.sequence(rsaAlgorithm + DER.bitString(pkcs1))
        let tbs = DER.sequence(
            DER.tlv(0xA0, DER.integer(Data([2]))) +
            DER.integer(serial) +
            algorithm + name + validity + name + subjectPublicKeyInfo
        )
        guard let signature = SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error
        ) as Data? else { throw Failure.signing }
        return DER.sequence(tbs + algorithm + DER.bitString(signature))
    }
}

private enum DER {
    static let null = Data([0x05, 0x00])
    static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        if count < 256 { return Data([0x81, UInt8(count)]) }
        return Data([0x82, UInt8((count >> 8) & 255), UInt8(count & 255)])
    }
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }
    static func sequence(_ content: Data) -> Data { tlv(0x30, content) }
    static func set(_ content: Data) -> Data { tlv(0x31, content) }
    static func oid(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    static func utf8(_ value: String) -> Data { tlv(0x0C, Data(value.utf8)) }
    static func integer(_ source: Data) -> Data {
        var bytes = source
        if bytes.first.map({ $0 & 0x80 != 0 }) == true { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }
}
