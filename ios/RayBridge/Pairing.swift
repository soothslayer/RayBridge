import Foundation
import Security

struct Pairing: Codable, Equatable, Identifiable {
    let host: String
    let port: Int
    let token: String
    let fingerprint: String
    var workspace: String?

    var id: String { "\(host.lowercased()):\(port)" }
    var displayName: String { id }

    init(link: String) throws {
        guard let parts = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "raybridge", parts.host == "pair" else {
            throw BridgeError.message("Paste the complete pairing link from your Mac.")
        }
        func value(_ name: String) -> String? { parts.queryItems?.first { $0.name == name }?.value }
        guard let host = value("host"), let portText = value("port"), let port = Int(portText),
              (1...65535).contains(port), let token = value("token"), let fingerprint = value("fingerprint"),
              token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              fingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw BridgeError.message("This pairing link is incomplete. Copy it again from the Mac.")
        }
        guard PairingHostPolicy.isAllowedHost(host) else {
            throw BridgeError.message("Pair with a Mac on your private local network or tailnet.")
        }
        self.host = host; self.port = port; self.token = token; self.fingerprint = fingerprint
        self.workspace = nil
    }
    func connectionURL() -> URL {
        var parts = URLComponents()
        parts.scheme = "wss"; parts.host = host; parts.port = port; parts.path = "/v1/connect"
        if let workspace { parts.queryItems = [URLQueryItem(name: "workspace", value: workspace)] }
        return parts.url!
    }

    func save() throws {
        var history = Self.loadHistory()
        history.remember(self)
        try Self.saveHistory(history)
    }

    static func load() -> Pairing? {
        loadHistory().selected
    }

    static func recent() -> [Pairing] {
        loadHistory().recent
    }

    static func select(id: String) throws {
        var history = loadHistory()
        guard history.select(id: id) else {
            throw BridgeError.message("That saved Mac is no longer available. Pair it again.")
        }
        try saveHistory(history)
    }

    static func setWorkspace(_ value: String, for id: String) throws -> String? {
        let workspace = try normalizedWorkspace(value)
        var history = loadHistory()
        guard history.setWorkspace(workspace, for: id) else {
            throw BridgeError.message("That saved Mac is no longer available. Pair it again.")
        }
        try saveHistory(history)
        return workspace
    }

    static func normalizedWorkspace(_ value: String) throws -> String? {
        let workspace = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.isEmpty { return nil }
        guard workspace.utf8.count <= 1024,
              !workspace.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              workspace == "~" || workspace.hasPrefix("~/") || workspace.hasPrefix("/") else {
            throw BridgeError.message("Enter an absolute Mac folder path, such as /Users/yourname/Documents, or leave it blank.")
        }
        return workspace
    }

    private static let service = "org.raybridge.pairing"
    private static let historyAccount = "macs"
    private static let legacyAccount = "mac"

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func data(account: String) -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    private static func loadHistory() -> PairingHistory {
        if let data = data(account: historyAccount),
           let stored = try? JSONDecoder().decode(PairingHistory.self, from: data) {
            return stored.normalized()
        }
        // Existing installs stored one pairing under the `mac` account. Make it
        // immediately available, then persist the new format when Keychain is writable.
        guard let data = data(account: legacyAccount),
              let legacy = try? JSONDecoder().decode(Pairing.self, from: data) else {
            return PairingHistory()
        }
        let migrated = PairingHistory(recent: [legacy], selectedID: legacy.id)
        try? saveHistory(migrated)
        return migrated
    }

    private static func saveHistory(_ history: PairingHistory) throws {
        let data = try JSONEncoder().encode(history.normalized())
        let itemQuery = query(account: historyAccount)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = itemQuery
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw BridgeError.message("Could not save pairing in the iPhone Keychain.")
        }
        SecItemDelete(query(account: legacyAccount) as CFDictionary)
    }
}

struct PairingHistory: Codable, Equatable {
    static let limit = 5
    var recent: [Pairing] = []
    var selectedID: String?

    var selected: Pairing? {
        recent.first(where: { $0.id == selectedID }) ?? recent.first
    }

    mutating func remember(_ pairing: Pairing) {
        var pairing = pairing
        if pairing.workspace == nil {
            pairing.workspace = recent.first(where: { $0.id == pairing.id })?.workspace
        }
        recent.removeAll { $0.id == pairing.id }
        recent.insert(pairing, at: 0)
        recent = Array(recent.prefix(Self.limit))
        selectedID = pairing.id
    }

    @discardableResult
    mutating func select(id: String) -> Bool {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return false }
        let pairing = recent.remove(at: index)
        recent.insert(pairing, at: 0)
        selectedID = id
        return true
    }

    @discardableResult
    mutating func setWorkspace(_ workspace: String?, for id: String) -> Bool {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return false }
        recent[index].workspace = workspace
        return true
    }

    func normalized() -> PairingHistory {
        var unique: [Pairing] = []
        for pairing in recent where !unique.contains(where: { $0.id == pairing.id }) {
            unique.append(pairing)
            if unique.count == Self.limit { break }
        }
        let selection = unique.contains(where: { $0.id == selectedID }) ? selectedID : unique.first?.id
        return PairingHistory(recent: unique, selectedID: selection)
    }
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
