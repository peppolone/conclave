// Chiavi API nel Portachiavi di macOS (quello tradizionale, a file).
// L'app è firmata con un certificato stabile: le voci create da lei restano sue tra le versioni,
// senza richiesta di password. Niente Portachiavi "data protection" né access group: richiedono
// un team Apple.

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

    /// Nomi delle voci del servizio. Solo attributi: il Portachiavi tradizionale non restituisce
    /// i valori di più voci in una sola ricerca.
    func accounts() throws -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status, account: "*") }
        return (out as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Valori non vuoti delle voci indicate (tutte quelle del servizio se `names` è nil).
    /// Una voce illeggibile si salta (e si registra): non deve far perdere le altre.
    func readAll(_ names: [String]? = nil) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try names ?? accounts() {
            do { if let v = try read(name), !v.isEmpty { out[name] = v } }
            catch { NSLog("Conclave: %@", error.localizedDescription) }
        }
        return out
    }
}
