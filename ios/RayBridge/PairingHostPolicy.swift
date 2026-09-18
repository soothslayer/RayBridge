import Foundation

// Hosts RayBridge will pair with. The Mac bridge is never published to the public
// internet: it is reached either on the private LAN or over a tailnet, where
// Tailscale carries the Mac's own certificate unchanged so the paired fingerprint
// still authenticates the Mac end to end.
enum PairingHostPolicy {
    static func isAllowedHost(_ host: String) -> Bool {
        guard let octets = octets(host) else { return false }
        return isPrivateLAN(octets) || isLinkLocal(octets) || isTailscale(octets)
    }

    // Canonical dotted-quad IPv4 only. Leading zeros are rejected so an octet
    // cannot be read as octal by one parser and decimal by another.
    static func octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0", let value = UInt8(part) else { return nil }
            result.append(value)
        }
        return result
    }

    // RFC 1918: 10/8, 172.16/12, 192.168/16.
    private static func isPrivateLAN(_ octets: [UInt8]) -> Bool {
        octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 172 && (16...31).contains(octets[1]))
    }

    // RFC 3927 link-local: 169.254/16.
    private static func isLinkLocal(_ octets: [UInt8]) -> Bool {
        octets[0] == 169 && octets[1] == 254
    }

    // Tailscale addresses live in the RFC 6598 shared range, 100.64/10.
    private static func isTailscale(_ octets: [UInt8]) -> Bool {
        octets[0] == 100 && (64...127).contains(octets[1])
    }
}
