import Foundation

// ONE place for product, brand and release settings.
// Change names, links, colors, the update feed or the logo files here.
// The app (DeckCore and the SwiftUI layer) reads these values, and
// scripts/bundle.sh reads the `static let x = "..."` lines below, so keep that format.

public enum AppConfig {
    // MARK: Product
    public static let appName = "Container Deck"
    public static let author = "Suresh Konakanchi"                   // copyright holder and licensor
    public static let authorURL = "https://suresh-konakanchi.in"
    // Copyright line in Info.plist (scripts/bundle.sh reads this line, keep the format).
    public static let company = "Suresh Konakanchi"
    public static let tagline = "Run Linux containers on your Mac with Apple's container platform."
    public static let bundleID = "io.github.sur950.containerdeck"
    /// Names the app's data folders and Keychain services. The running app's own id when it is a
    /// variant of ours (test copies run as `<bundleID>.debug`), so a test copy never reads or
    /// writes the real app's data. The plain id everywhere else, tests included.
    public static let dataID: String = {
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix(bundleID + ".") else { return bundleID }
        return id
    }()
    public static let urlScheme = "containerdeck"
    public static let minimumMacOS = "15.0"

    // MARK: Links
    public static let repository = "sur950/container-deck"          // GitHub owner/name. Releases feed the updater.
    public static let websiteURL = "https://github.com/sur950/container-deck"
    public static let issuesURL = "https://github.com/sur950/container-deck/issues"
    public static let siteURL = "https://sur950.github.io/container-deck"
    public static let license = "Apache 2.0 with Commons Clause"   // free to use and change, not to sell
    public static let licenseFile = "LICENSE"
    public static let appleContainerRepository = "apple/container"

    // MARK: Updates
    public static let updateCheckInterval: TimeInterval = 6 * 60 * 60  // seconds between automatic checks
    public static let updateAssetSuffix = ".dmg"                         // release asset the updater installs
    // Compulsory updates (DeckCore/Release/UpdateRequirement.swift). Versions are x.y.z, where
    // x is a breaking change. A newer release blocks the app with the "Update required" screen
    // when its x is higher, or when its CHANGELOG section has <!-- deck-update: required -->
    // (or <!-- deck-update: required-below 1.2.4 -->). The installed app reads this switch, so it
    // stays on: a copy built with it off could never be made to update later.
    public static let requiredUpdatesEnabled = true
    // Ed25519 public key (base64 of the 32 raw bytes) that signs every release disk image.
    // Made by scripts/make_update_keys.sh. The private key lives only in the UPDATE_SIGNING_KEY
    // GitHub secret. Empty means the app never installs updates by itself, it opens the download page.
    public static let updatePublicKey = "wjClDVajeu5xXEHOFQgsKPcNbXXOUZzZlJFzbYvziTI="
    // Common name of the free self signed code signing certificate (scripts/make_signing_cert.sh).
    // Keep it the same for every release so macOS keeps the app's permissions.
    // scripts/config.sh builds the same name from appName.
    public static let codeSigningIdentity = appName + " Code Signing"

    // MARK: Theme (hex sRGB, Light and Dark).
    // Every color in the app comes from here through DS in DesignSystem/Components.swift.
    public static let accentLight: UInt32 = 0xB3122E      // crimson
    public static let accentDark: UInt32 = 0xD3263F
    public static let accentTop: UInt32 = 0xD3263F        // logo tile gradient
    public static let accentBottom: UInt32 = 0xA10F28

    public struct Pair: Sendable { public let light: UInt32; public let dark: UInt32 }
    public enum Theme {
        public static let surface = Pair(light: 0xF4F3F0, dark: 0x0E0F12)
        public static let surfaceRaised = Pair(light: 0xFFFFFF, dark: 0x1B1C20)
        public static let surfaceSunken = Pair(light: 0xECEBE7, dark: 0x08090B)
        public static let cardTop = Pair(light: 0xFFFFFF, dark: 0x1B1C20)
        public static let cardBottom = Pair(light: 0xFCFCFB, dark: 0x15161A)
        public static let ink = Pair(light: 0x111215, dark: 0xF2F1EE)            // text and hairlines
        public static let textSecondary = Pair(light: 0x5B5E66, dark: 0xA1A3AB)
        public static let textTertiary = Pair(light: 0x8A8C93, dark: 0x6E7078)
        public static let running = Pair(light: 0x2F8F57, dark: 0x4FBF7E)
        public static let stopped = Pair(light: 0x8A8C93, dark: 0x7E8088)
        public static let warning = Pair(light: 0xB7860B, dark: 0xE5C56A)
        public static let danger = Pair(light: 0xC2410C, dark: 0xF0844F)
    }

    // MARK: Brand files (paths relative to the repo, used by scripts/bundle.sh and `swift run`)
    public static let appIconFile = "assets/brand/app-icon-1024.png"
    public static let logoFile = "assets/brand/logo.svg"

    // MARK: Window
    // Smallest window where no list cuts off a column (Images with its detail pane is the widest).
    public static let minimumWindowWidth: Double = 1260
    public static let minimumWindowHeight: Double = 720

    // MARK: Direct API
    // Daemon versions the direct XPC client (DeckCore/API) is tested with: 1.4.0 up to
    // any 1.7.x. Other versions use the `container` CLI. Widen after testing a new release.
    // Behaviour that differs inside the range (1.7 hides cluster nodes) is in ContainerPlatformFeatures.
    public static let apiSupportedVersions = SemanticVersion(1, 4, 0)..<SemanticVersion(1, 8, 0)
    // UserDefaults key of the support switch that sends every call through the CLI.
    public static let forceCLIBackendKey = "forceCLIBackend"

    // MARK: Components
    // The version of each system tool that Container Deck was verified with (Settings, Components).
    // The owner's rule: nothing is blocked. People update and downgrade any tool as they like,
    // from the app or elsewhere. The tested version is only where "Switch to the tested version"
    // goes when a feature the app uses is found broken on another version.
    // `line` is the release line we verified ("1.7" matches 1.7.0, 1.7.1 and so on). The switch
    // installs the newest published release of that line, or `version` when no list is published.
    // Apple container follows apiSupportedVersions: its newest tested minor.
    // Tools with only a major line were not pinned to one release on a test Mac.
    // Last raised 12 Nov 2026 with ComponentsLiveTests (DECK_LIVE_COMPONENTS=1) on the newest releases.
    public struct ComponentTested: Sendable, Equatable {
        public let line: String
        public let version: String?
        public init(_ line: String, _ version: String? = nil) { self.line = line; self.version = version }
    }
    public static var containerTested: ComponentTested {
        let upper = apiSupportedVersions.upperBound
        let line = upper.minor > 0 ? "\(upper.major).\(upper.minor - 1)" : "\(max(upper.major - 1, 0))"
        return ComponentTested(line)
    }
    public static let componentTested: [String: ComponentTested] = [
        "ollama": ComponentTested("0.40", "0.40.15"),
        "mlx": ComponentTested("0.32", "0.32.2"),
        "lmstudio": ComponentTested("0.0.27", "0.0.27-1"),   // llmster (LM Studio core)
        "lmstudio-app": ComponentTested("0.3"),
        "uv": ComponentTested("0.13", "0.13.7"),
        "cloudflared": ComponentTested("2026.10", "2026.10.7"),
        "ngrok": ComponentTested("3", "3.39.13"),
        "tailscale": ComponentTested("1.104", "1.104.5"),
        "kubectl": ComponentTested("1.37", "1.37.2"),
        "helm": ComponentTested("4.3", "4.3.1"),
        // AI agent command line tools.
        "agent:claude": ComponentTested("2.1", "2.1.322"),
        "agent:gemini": ComponentTested("0.68", "0.68.0"),
        "agent:aider": ComponentTested("0.86", "0.86.2"),
        "agent:codex": ComponentTested("0"),
        "agent:qwen": ComponentTested("0"),
        "agent:amp": ComponentTested("0"),
        "agent:opencode": ComponentTested("1"),
        "agent:goose": ComponentTested("1"),
        "agent:crush": ComponentTested("0")
        // Cursor's agent has date versions and no published list: no tested version.
    ]

    // MARK: Linux kernel
    // Recommended kernel for each `container` release we tested, copied from Apple's
    // KernelConfig defaults (Sources/ContainerPersistence/ContainerSystemConfig.swift).
    // The kernel installer first asks the installed `container` (`system property list`)
    // and only uses this list when that fails, for example while the service is stopped.
    // Newest first. The first entry whose `from` is at or below the installed version wins.
    public struct KernelDefaults: Sendable, Equatable {
        public let from: SemanticVersion      // first `container` release with these values
        public let url: String
        public let digest: String             // sha256:<hex> of the archive
        public let binaryPath: String         // kernel file inside the archive
        public let size: Int64                // archive size in bytes (from GitHub)
    }
    public static let kernelDefaults: [KernelDefaults] = [
        KernelDefaults(
            from: SemanticVersion(1, 7, 0),
            url: "https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst",
            digest: "sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6",
            binaryPath: "opt/kata/share/kata-containers/vmlinux-6.18.56-208-debug",
            size: 676_287_269
        ),
        KernelDefaults(
            from: SemanticVersion(0, 0, 0),         // 1.3 to 1.6.x, also used for older releases
            url: "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst",
            digest: "sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5",
            binaryPath: "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug",
            size: 696_573_576
        )
    ]
    // Folder under Application Support/<bundle id> for the kernel download. Emptied after an install.
    public static let kernelDownloadFolder = "Kernel"

    // MARK: Behaviour defaults
    public static let defaultRefreshInterval: Double = 3
    public static let defaultDNSDomain = "test"
}
