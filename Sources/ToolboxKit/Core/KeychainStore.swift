import Foundation
import Security

/// 只给密钥用的极简 Keychain 封装。
///
/// 为什么不用 settings.json：AI Key 是账号凭据，明文落盘后会被备份/同步/误传。
/// Keychain 的 generic password 不需要额外 entitlement（未沙盒 App 可直接用）。
public enum KeychainStore {
    public static let aiService = "com.toolbox.translation.ai"
    public static let aiAccount = "apiKey"

    @discardableResult
    public static func set(_ value: String, service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let updated = SecItemUpdate(base as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static var aiKey: String? {
        get { get(service: aiService, account: aiAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                set(newValue, service: aiService, account: aiAccount)
            } else {
                delete(service: aiService, account: aiAccount)
            }
        }
    }
}
