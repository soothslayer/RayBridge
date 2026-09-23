import Foundation

@main
struct PairingHistoryTests {
    static func main() throws {
        func pairing(_ host: String, token: Character = "a") throws -> Pairing {
            try Pairing(link: "raybridge://pair?host=\(host)&port=8845&token=\(String(repeating: token, count: 64))&fingerprint=\(String(repeating: "f", count: 64))")
        }

        var history = PairingHistory()
        let hosts = (1...6).map { "10.0.0.\($0)" }
        for host in hosts { history.remember(try pairing(host)) }
        precondition(history.recent.count == PairingHistory.limit)
        precondition(history.recent.map(\.host) == Array(hosts.reversed().prefix(5)))
        precondition(history.selected?.host == hosts.last)

        let selectedID = try pairing("10.0.0.3").id
        precondition(history.select(id: selectedID))
        precondition(history.selected?.host == "10.0.0.3")
        precondition(history.recent.first?.host == "10.0.0.3", "Selecting a Mac makes it most recent")
        precondition(!history.select(id: "missing:8845"))

        let normalizedWorkspace = try Pairing.normalizedWorkspace("  /Users/test/My Project  ")
        let emptyWorkspace = try Pairing.normalizedWorkspace("   ")
        precondition(normalizedWorkspace == "/Users/test/My Project")
        precondition(emptyWorkspace == nil)
        let legacyPairing = try JSONDecoder().decode(Pairing.self, from: Data("""
            {"host":"10.0.0.2","port":8845,"token":"\(String(repeating: "a", count: 64))","fingerprint":"\(String(repeating: "f", count: 64))"}
            """.utf8))
        precondition(legacyPairing.workspace == nil, "Pairings saved by older app versions must still load")
        do {
            _ = try Pairing.normalizedWorkspace("relative/folder")
            preconditionFailure("Relative working folders must be rejected")
        } catch {}
        precondition(history.setWorkspace("/Users/test/My Project", for: selectedID))
        precondition(history.selected?.workspace == "/Users/test/My Project")
        precondition(URLComponents(url: history.selected!.connectionURL(), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "workspace" })?.value == "/Users/test/My Project")

        let refreshed = try pairing("10.0.0.3", token: "b")
        history.remember(refreshed)
        precondition(history.recent.filter { $0.id == refreshed.id }.count == 1)
        precondition(history.selected?.token == String(repeating: "b", count: 64),
                     "Re-pairing must replace stale credentials")
        precondition(history.selected?.workspace == "/Users/test/My Project",
                     "Re-pairing must preserve the phone working-folder preference")

        let duplicate = PairingHistory(
            recent: [refreshed, refreshed, try pairing("10.0.0.4")],
            selectedID: "missing:8845"
        ).normalized()
        precondition(duplicate.recent.count == 2)
        precondition(duplicate.selected?.id == refreshed.id, "Invalid selections fall back to the newest Mac")

        print("Passed pairing history tests for limits, selection, credential refresh, and normalization.")
    }
}
