import Foundation
import Security

/// 本机 Keychain 保存最近记住的一组凭据。它独立于登录会话，退出后仍可回填。
enum SavedCredential {
    struct Record: Codable {
        let phone: String
        let password: String

        fileprivate var isValid: Bool { phone.count == 11 && !password.isEmpty }
    }

    private static let service = "com.hualala.linyu.credential"
    private static let recordAccount = "remembered-login"

    static func load() -> Record? {
        if let data = read(recordAccount) {
            guard let record = try? JSONDecoder().decode(Record.self, from: data), record.isValid else { return nil }
            return record
        }

        guard let phoneData = read("phone"), let passwordData = read("password"),
              let phone = String(data: phoneData, encoding: .utf8),
              let password = String(data: passwordData, encoding: .utf8) else { return nil }
        let legacy = Record(phone: phone, password: password)
        guard legacy.isValid else { return nil }
        _ = save(legacy)
        return legacy
    }

    static func save(_ record: Record) -> Bool {
        guard record.isValid, let data = try? JSONEncoder().encode(record) else { return false }
        let lookup = query(recordAccount)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = lookup.merging(attributes) { _, value in value }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { return false }
        _ = delete("phone")
        _ = delete("password")
        return true
    }

    @discardableResult
    static func clear(for phone: String) -> Bool {
        guard load()?.phone == phone else { return true }
        let legacyPhoneRemoved = delete("phone")
        let legacyPasswordRemoved = delete("password")
        return legacyPhoneRemoved && legacyPasswordRemoved && delete(recordAccount)
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> Data? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
