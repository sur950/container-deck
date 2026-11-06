import Foundation

/// Cloudflare quick tunnel: `cloudflared tunnel --no-autoupdate --url http://<ip>:<port>`.
/// No account. The `trycloudflare.com` link is read from cloudflared's output.
public struct CloudflareShareProvider: ShareProvider {
    public init() {}

    public let id = "cloudflared"
    public let title = "Cloudflare Tunnel"
    public let summary = "Free, no account needed."
    public let binaryName = "cloudflared"

    static let urlPattern = #"https://[a-z0-9-]+\.trycloudflare\.com"#

    public func candidatePaths(searchPaths: [String], toolsDirectory: String, includeAppBundle: Bool) -> [String] {
        // Our own verified download lives in Application Support.
        searchPaths.map { "\($0)/\(binaryName)" } + ["\(toolsDirectory)/\(binaryName)"]
    }

    public var installOptions: [ShareInstallOption] {
        [.homebrew("cloudflared"), .direct(title: "Download from Cloudflare")]
    }

    public func readiness(executable: String, context: ShareContext) async -> ShareReadiness {
        let version = await CloudflaredInstaller(runner: context.runner).version(at: executable)
        return .ready(detail: version.map { "Version \($0). No account needed." } ?? "No account needed.")
    }

    public func arguments(for route: ProxyRoute) -> [String]? {
        route.upstreamURL.map { ["tunnel", "--no-autoupdate", "--url", $0] }
    }

    public func prepare(route: ProxyRoute, publishedPort: Int?, executable: String, context: ShareContext,
                        reservedPorts: Set<Int>) async throws -> ShareLaunch {
        guard let args = arguments(for: route) else { throw ShareFailure.containerStopped(route.container) }
        return ShareLaunch(providerID: id, executable: executable, arguments: args)
    }

    public func publicURL(in output: String, launch: ShareLaunch?) -> String? {
        output.range(of: Self.urlPattern, options: .regularExpression).map { String(output[$0]) }
    }

    public func classify(_ output: String) -> ShareFailure? {
        let lower = output.lowercased()
        if lower.contains("failed to request quick tunnel") || lower.contains("failed to dial") || lower.contains("no such host")
            || (lower.contains("connection refused") && lower.contains("trycloudflare")) {
            return ShareFailure(.offline, "cloudflared cannot reach Cloudflare.", fix: "Your network may block it. Try another provider.")
        }
        if lower.contains("quick tunnel provisioning failed") {
            return ShareFailure(.busy, "Cloudflare did not hand out a quick tunnel.", fix: "Try again in a minute, or try another provider.")
        }
        return nil
    }

    public func install(_ option: ShareInstallOption, context: ShareContext, brew: String?) async throws {
        let installer = CloudflaredInstaller(runner: context.runner)
        switch option {
        case .homebrew:
            guard let brew else { throw DeckError.commandFailed("Homebrew is not installed.") }
            try await installer.installWithHomebrew(brew: brew)
        case .direct:
            _ = try await installer.installDirect()
        case .webPage:
            break
        }
    }
}
