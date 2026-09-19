import Foundation

@main
struct PairingHostPolicyTests {
    static func main() {
        let allowed = [
            "10.0.0.2", "10.255.255.255", "192.168.1.14", "172.16.0.1", "172.31.255.254",
            "169.254.3.4",
            // Tailscale tailnet addresses (100.64.0.0/10).
            "100.64.0.1", "100.100.32.7", "100.127.255.254",
            // MagicDNS names inside the tailnet's own .ts.net domain.
            "mac.tail1234.ts.net", "my-mac.tailnet-name.ts.net", "Mac.Tail1234.TS.NET",
            "mac.ts.net", "a.b.c.d.ts.net"
        ]
        let rejected = [
            // Public addresses, including the CGNAT neighbours just outside 100.64/10.
            "100.63.255.255", "100.128.0.1", "8.8.8.8", "203.0.113.5",
            "172.15.0.1", "172.32.0.1", "192.169.1.1", "169.253.0.1",
            // Not a canonical dotted quad.
            "127.0.0.1.1", "10.0.0", "10.0.0.256", "10.0.0.-1", "10.0.0.a",
            "10.0.0.", "", "10..0.1", " 10.0.0.2", "10.0.0.2 ",
            // Leading zeros must not be accepted as decimal.
            "010.0.0.1", "100.064.0.1",
            // Only .ts.net names are accepted, so no other hostname can be paired.
            "localhost", "mac.local", "example.com", "bridge.ngrok.io",
            "ts.net", ".ts.net", "mac..ts.net", "mac.tail1234.ts.net.evil.com",
            "-mac.tail1234.ts.net", "mac-.tail1234.ts.net", "mac_1.tail1234.ts.net",
            "mac.tail1234.ts.net:8845", "mac.tail1234.ts.network"
        ]

        for host in allowed {
            precondition(PairingHostPolicy.isAllowedHost(host), "Expected to allow pairing host: \(host)")
        }
        for host in rejected {
            precondition(!PairingHostPolicy.isAllowedHost(host), "Expected to reject pairing host: \(host)")
        }
        precondition(PairingHostPolicy.octets("100.100.32.7") == [100, 100, 32, 7])
        precondition(PairingHostPolicy.octets("10.0.0.256") == nil)

        // A label may be 63 characters but no longer, and the whole name at most 253.
        let longest = String(repeating: "m", count: 63)
        precondition(PairingHostPolicy.isAllowedHost("\(longest).tail1234.ts.net"))
        precondition(!PairingHostPolicy.isAllowedHost("\(longest)m.tail1234.ts.net"))
        let overLength = Array(repeating: longest, count: 4).joined(separator: ".") + ".ts.net"
        precondition(overLength.count > 253 && !PairingHostPolicy.isAllowedHost(overLength))

        print("Passed pairing host policy tests for private LAN, link-local, tailnet, MagicDNS, and rejected hosts.")
    }
}
