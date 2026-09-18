import Foundation

@main
struct PairingHostPolicyTests {
    static func main() {
        let allowed = [
            "10.0.0.2", "10.255.255.255", "192.168.1.14", "172.16.0.1", "172.31.255.254",
            "169.254.3.4",
            // Tailscale tailnet addresses (100.64.0.0/10).
            "100.64.0.1", "100.100.32.7", "100.127.255.254"
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
            // Hostnames are not supported; MagicDNS names must not slip through.
            "mac.tail1234.ts.net", "localhost"
        ]

        for host in allowed {
            precondition(PairingHostPolicy.isAllowedHost(host), "Expected to allow pairing host: \(host)")
        }
        for host in rejected {
            precondition(!PairingHostPolicy.isAllowedHost(host), "Expected to reject pairing host: \(host)")
        }
        precondition(PairingHostPolicy.octets("100.100.32.7") == [100, 100, 32, 7])
        precondition(PairingHostPolicy.octets("10.0.0.256") == nil)
        print("Passed pairing host policy tests for private LAN, link-local, tailnet, and rejected hosts.")
    }
}
