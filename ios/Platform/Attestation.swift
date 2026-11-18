import CryptoKit
import DeviceCheck
import Foundation
import Security

/// The install's signing key - a P-256 key in the Secure Enclave, or the
/// Keychain where there is none - and Apple's App Attest, which binds it to
/// a genuine install of the app the way Android's key attestation does.
enum Attestation {
    static let keyTag = Data("com.steptrackerpro.ios.signing".utf8)
    static let headersService = "com.steptrackerpro.ios.headers"

    struct Key {
        let privateKey: SecKey
        let spki: Data
        var keyId: String { KeyEncoding.keyId(spki: spki) }
    }

    // ---- the signing key ---------------------------------------------------------------------

    static func currentKey() -> Key? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let found = item,
              CFGetTypeID(found) == SecKeyGetTypeID() else { return nil }
        let key = found as! SecKey
        guard let spki = spki(of: key) else { return nil }
        return Key(privateKey: key, spki: spki)
    }

    static func spki(of privateKey: SecKey) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        return KeyEncoding.spki(x963: point)
    }

    static func deleteKeys() {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
        ] as CFDictionary)
    }

    /// A new key: permanent, usable after the first unlock so a background
    /// wake on a locked phone can sign, never asking for the user's presence.
    /// In the Secure Enclave when the phone has one.
    static func createKey() throws -> (Key, String) {
        deleteKeys()
        if SecureEnclave.isAvailable, let key = try? makeKey(enclave: true) { return (key, "secure_enclave") }
        return (try makeKey(enclave: false), "software")
    }

    private static func makeKey(enclave: Bool) throws -> Key {
        var error: Unmanaged<CFError>?
        var privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: keyTag,
        ]
        var attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        if enclave {
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            privateAttrs[kSecAttrAccessControl as String] = access
            attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        } else {
            privateAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        attrs[kSecPrivateKeyAttrs as String] = privateAttrs
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let spki = spki(of: key) else { throw BridgeError(code: "E_UNKNOWN", message: "The new key has no public key") }
        return Key(privateKey: key, spki: spki)
    }

    /// DER ECDSA over SHA-256 of [data] - what Java's `SHA256withECDSA` makes.
    static func sign(_ data: Data, with key: Key) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key.privateKey, .ecdsaSignatureMessageX962SHA256, data as CFData, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return signature
    }

    // ---- App Attest --------------------------------------------------------------------------

    static var appAttestSupported: Bool { DCAppAttestService.shared.isSupported }

    static func generateAppAttestKey(done: @escaping (Result<String, Error>) -> Void) {
        DCAppAttestService.shared.generateKey { keyId, error in
            if let keyId { done(.success(keyId)) } else { done(.failure(error ?? BridgeError(code: "E_INTEGRITY_FAILED", message: "App Attest made no key"))) }
        }
    }

    static func attest(_ keyId: String, clientData: Data, done: @escaping (Result<Data, Error>) -> Void) {
        DCAppAttestService.shared.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: clientData))) { object, error in
            if let object { done(.success(object)) } else { done(.failure(error ?? BridgeError(code: "E_INTEGRITY_FAILED", message: "App Attest returned nothing"))) }
        }
    }

    static func assertion(_ keyId: String, clientData: Data, done: @escaping (Result<Data, Error>) -> Void) {
        DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: Data(SHA256.hash(data: clientData))) { assertion, error in
            if let assertion { done(.success(assertion)) } else { done(.failure(error ?? BridgeError(code: "E_INTEGRITY_FAILED", message: "App Attest returned nothing"))) }
        }
    }

    /// `APP_ATTEST_<CASE>` and whether calling again can help.
    static func describe(_ error: Error) -> (name: String, retryable: Bool, code: DCError.Code?) {
        guard let dc = error as? DCError else {
            let ns = error as NSError
            if ns.domain == DCErrorDomain, let code = DCError.Code(rawValue: ns.code) { return describe(DCError(code)) }
            return ("APP_ATTEST_UNKNOWN_SYSTEM_FAILURE", false, nil)
        }
        switch dc.code {
        case .serverUnavailable: return ("APP_ATTEST_SERVER_UNAVAILABLE", true, dc.code)
        case .invalidKey: return ("APP_ATTEST_INVALID_KEY", false, dc.code)
        case .invalidInput: return ("APP_ATTEST_INVALID_INPUT", false, dc.code)
        case .featureUnsupported: return ("APP_ATTEST_FEATURE_UNSUPPORTED", false, dc.code)
        case .unknownSystemFailure: return ("APP_ATTEST_UNKNOWN_SYSTEM_FAILURE", false, dc.code)
        @unknown default: return ("APP_ATTEST_UNKNOWN_SYSTEM_FAILURE", false, dc.code)
        }
    }

    static func failure(_ error: Error, while doing: String) -> BridgeError {
        let (name, retryable, _) = describe(error)
        return BridgeError(code: "E_INTEGRITY_FAILED", message: "App Attest failed (\(name)) \(doing): \(error.localizedDescription)",
                           details: ["playErrorCode": NSNull(), "playError": name, "retryable": retryable])
    }

    // ---- secrets -------------------------------------------------------------------------------

    /// `remoteSyncHeaders`, kept as Android keeps them: never in the clear in a file.
    static func saveHeaders(_ headers: [String: String]) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: headersService] as CFDictionary)
        guard !headers.isEmpty, let data = try? JSONSerialization.data(withJSONObject: headers) else { return }
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: headersService,
            kSecAttrAccount as String: "remoteSyncHeaders",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ] as CFDictionary, nil)
    }

    static func loadHeaders() -> [String: String] {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: headersService,
            kSecReturnData as String: true,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return headers
    }

    /// Keychain items outlive an uninstall on iOS; Android's keys do not.
    /// A fresh install deletes what an earlier one left.
    static func wipeLeftovers() {
        deleteKeys()
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: headersService] as CFDictionary)
    }
}
