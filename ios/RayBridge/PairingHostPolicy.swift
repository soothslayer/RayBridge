import Foundation

// Hosts RayBridge will pair with: a private LAN address, or a tailnet address or
// MagicDNS name. The Mac bridge is never published to the public internet. Tailscale
// carries the Mac's own certificate unchanged, so the paired fingerprint still
// authenticates the Mac end to end over a tailnet.
enum PairingHostPolicy {
    static func isAllowedHost(_ host: String) -> Bool {
        if let octets = octets(host) {
            return isPrivateLAN(octets) || isLinkLocal(octets) || isTailscale(octets)
        }
        return isMagicDNSName(host)
    }

    // A MagicDNS name is fully qualified inside the tailnet's own .ts.net domain and
    // resolves only for devices on that tailnet, so accepting this one domain cannot
    // point the app at a public tunnel endpoint. The certificate fingerprint, not the
    // name, is what authenticates the Mac.
    static func isMagicDNSName(_ host: String) -> Bool {
        let name = host.lowercased()
        guard name.count <= 253, name.hasSuffix(".ts.net") else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3 else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-" &&
                label.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
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
