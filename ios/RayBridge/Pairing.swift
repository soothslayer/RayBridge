import Foundation
import Security

struct Pairing: Codable {
    let host: String
    let port: Int
    let token: String
    let fingerprint: String

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
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4,
              octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) ||
              (octets[0] == 172 && (16...31).contains(octets[1])) ||
              (octets[0] == 169 && octets[1] == 254) else {
            throw BridgeError.message("Pair with a Mac on your private local network.")
        }
        self.host = host; self.port = port; self.token = token; self.fingerprint = fingerprint
    }
    var url: URL { URL(string: "wss://\(host):\(port)/v1/connect")! }

    func save() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.raybridge.pairing", kSecAttrAccount as String: "mac"]
        let data = try JSONEncoder().encode(self)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw BridgeError.message("Could not save pairing in the iPhone Keychain.")
        }
    }
    static func load() -> Pairing? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.raybridge.pairing", kSecAttrAccount as String: "mac",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
