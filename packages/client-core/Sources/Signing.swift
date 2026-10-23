import Foundation
import CryptoKit
import Security

public protocol RecordSigner {
    var publicKeyData: Data { get }
    func sign(_ data: Data) throws -> Data
}

/// For tests or explicitly temporary local experiments. Never selected as a Keychain fallback.
public final class EphemeralSigner: RecordSigner {
    private let key: Curve25519.Signing.PrivateKey
    public init() { key = Curve25519.Signing.PrivateKey() }
    public init(privateKeyRawData: Data) throws {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRawData)
    }
    public var publicKeyData: Data { key.publicKey.rawRepresentation }
    public func sign(_ data: Data) throws -> Data { try key.signature(for: data) }
}

/// Storage injection makes failures testable without modifying the user's Keychain.
public protocol KeyMaterialStorage {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public final class KeychainSigner: RecordSigner {
    private let key: Curve25519.Signing.PrivateKey
    public convenience init(service: String = "org.humanbrowser.local-alpha.signing", account: String = "primary-v0", allowCreation: Bool = true) throws {
        try self.init(storage: SystemKeyMaterialStorage(service: service, account: account), allowCreation: allowCreation)
    }
    public init(storage: any KeyMaterialStorage, allowCreation: Bool = true) throws {
        if let raw = try storage.load() {
            do { key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw) }
            catch { throw LedgerError.keychain("저장된 키 형식이 올바르지 않습니다.") }
        } else {
            guard allowCreation else { throw LedgerError.keychain("기존 저장소의 키가 없습니다. 새 키로 교체하지 않았습니다.") }
            let generated = Curve25519.Signing.PrivateKey()
            try storage.save(generated.rawRepresentation)
            // Re-read the stored key; an unsuccessful or racing write must not create a new identity.
            guard let persisted = try storage.load(), persisted == generated.rawRepresentation else {
                throw LedgerError.keychain("저장한 키를 확인하지 못했습니다.")
            }
            key = generated
        }
    }
    public var publicKeyData: Data { key.publicKey.rawRepresentation }
    public func sign(_ data: Data) throws -> Data { try key.signature(for: data) }
}

private final class SystemKeyMaterialStorage: KeyMaterialStorage {
    private let service: String
    private let account: String
    init(service: String, account: String) { self.service = service; self.account = account }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func load() throws -> Data? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LedgerError.keychain("읽기 오류 \(status)")
        }
        return data
    }
    func save(_ data: Data) throws {
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw LedgerError.keychain("저장 오류 \(status)") }
    }
}
