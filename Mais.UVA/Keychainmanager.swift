import Foundation
import Security
import LocalAuthentication

struct KeychainCredentials {
    let username: String
    let password: String
}

class KeychainManager {
    static let shared = KeychainManager()
    private init() {}

    private let service = "br.uva.portalaluno"
    private let usernameKey = "uva_username"
    private let passwordKey = "uva_password"

    // MARK: - Salvar credenciais protegidas por biometria

    func saveCredentials(username: String, password: String) throws {
        // Cria controle de acesso: biometria obrigatória, não sincroniza com iCloud
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryAny,
            &error
        ) else {
            throw KeychainError.unexpectedError(error?.takeRetainedValue())
        }

        // Salva usuário (sem biometria, só protegido no dispositivo)
        try saveString(username, forKey: usernameKey)

        // Salva senha com biometria usando LAContext moderno
        let context = LAContext()
        let passwordData = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String:                kSecClassGenericPassword,
            kSecAttrService as String:          service,
            kSecAttrAccount as String:          passwordKey,
            kSecValueData as String:            passwordData,
            kSecAttrAccessControl as String:    access,
            kSecUseAuthenticationContext as String: context
        ]

        SecItemDelete(query as CFDictionary) // remove anterior se existir
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - Recuperar credenciais (aciona Face ID/Touch ID)

    func loadCredentials(reason: String = "Entrar no Portal UVA") async throws -> KeychainCredentials {
        let username = try loadString(forKey: usernameKey)

        // LAContext moderno com mensagem personalizada
        let context = LAContext()
        context.localizedReason = reason

        let query: [String: Any] = [
            kSecClass as String:                kSecClassGenericPassword,
            kSecAttrService as String:          service,
            kSecAttrAccount as String:          passwordKey,
            kSecReturnData as String:           true,
            kSecMatchLimit as String:           kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.itemNotFound
        }

        return KeychainCredentials(username: username, password: password)
    }

    // MARK: - Verificar se há credenciais salvas (sem acionar biometria)

    func hasCredentials() -> Bool {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  usernameKey,
            kSecReturnData as String:   false,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Apagar credenciais

    func deleteCredentials() {
        deleteItem(forKey: usernameKey)
        deleteItem(forKey: passwordKey)
    }

    // MARK: - Helpers privados

    private func saveString(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key,
            kSecValueData as String:    data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    private func loadString(forKey key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { throw KeychainError.itemNotFound }
        return string
    }

    private func deleteItem(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Erros

enum KeychainError: LocalizedError {
    case itemNotFound
    case unhandledError(status: OSStatus)
    case unexpectedError(CFError?)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Nenhuma credencial salva encontrada."
        case .unhandledError(let status):
            return "Erro no Keychain: \(status)"
        case .unexpectedError(let err):
            return err.map { CFErrorCopyDescription($0) as String } ?? "Erro desconhecido."
        }
    }
}
