import Foundation

/// Settings for local domains, the HTTPS proxy and sharing. One place to change them.
public enum DomainsConfig {
    // MARK: Routes
    /// Container label that picks the port the proxy sends traffic to, like `deck.port=3000`.
    public static let portLabel = "deck.port"
    /// Container label that turns the automatic route off when set to "false".
    public static let routeLabel = "deck.route"
    /// Names below this domain resolve to 127.0.0.1 on every Mac without setup.
    public static let proxyDomain = "localhost"
    /// Port used when a container has no label, no published port and no exposed port.
    public static let fallbackPort = 80

    // MARK: Proxy
    /// Loopback only. Never 0.0.0.0, so nothing on the local network can reach the proxy.
    public static let listenHost = "127.0.0.1"
    /// High port, no admin needed. Port 443 is an opt in redirect (see `PortRedirect`).
    public static let defaultProxyPort: UInt16 = 8443
    public static let httpsPort: UInt16 = 443
    /// Small DNS server for aliases outside `.localhost` (UDP, loopback only).
    public static let dnsResponderPort: UInt16 = 15353
    /// pf anchor under `com.apple/*`, so the stock /etc/pf.conf loads it without edits.
    public static let pfAnchor = "com.apple/250.ContainerDeck"
    /// Marker written in every /etc/resolver file we add, so we only ever remove our own.
    /// Checks match it as a fixed substring, so files written by older builds (whose
    /// marker had a company name after this text) are still found and cleaned up.
    public static let resolverMarker = "# Added by Container Deck"

    // MARK: Certificates
    public static let caCommonName = AppConfig.appName + " Local CA"
    public static let caValidityDays = 3650
    /// Apple accepts at most 825 days for TLS server certificates. Browsers prefer 398 or less.
    public static let leafValidityDays = 397
    public static let opensslPath = "/usr/bin/openssl"
    public static let securityPath = "/usr/bin/security"

    // MARK: Host alias
    /// Default name and address for "containers reach Mac services by name".
    /// The address comes from a documentation range, as Apple's docs suggest.
    public static let hostAliasName = "host.container.internal"
    public static let hostAliasAddress = "203.0.113.113"

    // MARK: Sharing
    public static let cloudflaredRepository = "cloudflare/cloudflared"
    /// Release asset for Apple silicon Macs.
    public static let cloudflaredAsset = "cloudflared-darwin-arm64.tgz"
    public static let quickTunnelHostSuffix = ".trycloudflare.com"
    public static let toolSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    /// CLI inside the Tailscale app (Mac App Store and Standalone builds).
    public static let tailscaleAppBinary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    /// The only ports Funnel listens on.
    public static let funnelPorts = [443, 8443, 10000]
    /// A share with no public link after this long is stopped and reported.
    public static let shareLinkTimeout: TimeInterval = 60
    /// When a tool runs but prints no link, ask it another way (like ngrok's local API) after this long.
    public static let shareLookupDelay: TimeInterval = 6
    /// Keychain service for provider secrets (like the ngrok authtoken), one item per provider and field.
    public static let keychainService = AppConfig.dataID + ".share"
    public static let ngrokDownloadPage = "https://ngrok.com/download"
    public static let ngrokAuthtokenPage = "https://dashboard.ngrok.com/get-started/your-authtoken"
    public static let tailscaleDownloadPage = "https://tailscale.com/download/mac"
    public static let tailscaleFunnelDocs = "https://tailscale.com/kb/1223/funnel"

    /// Preference key for a plain provider setting, like the ngrok domain.
    public static func shareSettingKey(provider: String, key: String) -> String { "domains.share.\(provider).\(key)" }
    /// Debug builds only: a folder of stand in share tools that replaces the normal search (see docs/DOMAINS.md).
    public static let debugToolsEnvironmentKey = "DECK_SHARE_TOOLS_DIR"

    /// Application Support folder for the CA, leaf certificates and tools.
    public static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppConfig.dataID, isDirectory: true)
    }

    public static func certificatesDirectory() -> URL {
        supportDirectory().appendingPathComponent("Proxy", isDirectory: true)
    }

    public static func toolsDirectory() -> URL {
        supportDirectory().appendingPathComponent("bin", isDirectory: true)
    }
}
