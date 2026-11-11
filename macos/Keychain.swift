// Voci del Portachiavi di macOS (quello tradizionale, a file). Niente Portachiavi "data
// protection" né access group: richiedono un team Apple. Senza Team ID la partition list lega
// ogni voce alla build che l'ha creata: dopo un aggiornamento macOS chiede la password una volta
// per voce (vedi `KeyStore` in Settings.swift).

import Foundation
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus
    let account: String

    var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? String(format: L("errore %d"), Int(status))
        return String(format: L("Portachiavi, voce %@: %@"), account, reason)
    }
}

/// Voci `kSecClassGenericPassword` di un servizio; account = nome della variabile (es. `GEMINI_API_KEY`).
struct Keychain {
    let service: String

    static let conclave = Keychain(service: "io.github.peppolone.conclave")

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// nil se la voce non esiste.
    func read(_ account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status, account: account) }
        return String(data: data, encoding: .utf8)
    }

    /// Crea o aggiorna la voce. Un valore vuoto la cancella.
    func write(_ account: String, _ value: String) throws {
        guard !value.isEmpty else { return try delete(account) }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            // Nome leggibile in Accesso Portachiavi.
            q[kSecAttrLabel as String] = "Conclave – \(account)"
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status, account: account) }
    }

    /// Cancellare una voce che non c'è non è un errore.
    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status, account: account) }
    }
}
