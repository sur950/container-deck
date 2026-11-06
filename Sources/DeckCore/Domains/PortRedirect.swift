import Foundation

/// Opt in: lets `https://web.localhost` work without `:8443`.
///
/// Binding 127.0.0.1:443 needs root, and the app never runs as root. Instead one admin
/// step loads a packet filter rule that sends 127.0.0.1 port 443 to the proxy's high port.
/// The rule lives in the anchor `com.apple/250.ContainerDeck`, which the stock
/// /etc/pf.conf already loads, so no system file is edited. It is gone after a restart
/// (like Apple's own `--localhost` rules), and `removeCommands` takes it out at once.
public enum PortRedirect {
    static let pfctl = "/sbin/pfctl"

    /// The one rule. Loopback only, TCP only.
    public static func rule(from: UInt16 = DomainsConfig.httpsPort, to: UInt16 = DomainsConfig.defaultProxyPort) -> String {
        "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port \(from) -> 127.0.0.1 port \(to)"
    }

    /// Loads the rule and turns pf on (pf keeps a reference so other users are not affected).
    public static func installCommands(to port: UInt16 = DomainsConfig.defaultProxyPort) -> [[String]] {
        let script = "printf '%s\\n' \"$1\" | \(pfctl) -a \"$2\" -f - && (\(pfctl) -E 2>/dev/null || true)"
        return [["/bin/sh", "-c", script, "deck-pf", rule(to: port), DomainsConfig.pfAnchor]]
    }

    public static func removeCommands() -> [[String]] {
        [[pfctl, "-a", DomainsConfig.pfAnchor, "-F", "all"]]
    }

    /// Reading pf rules also needs root, so the app remembers the state itself and
    /// treats it as gone after the Mac restarts.
    public static func isLikelyActive(installedAt: Date?, bootTime: Date = Self.bootTime()) -> Bool {
        guard let installedAt else { return false }
        return installedAt > bootTime
    }

    public static func bootTime() -> Date {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }
}
