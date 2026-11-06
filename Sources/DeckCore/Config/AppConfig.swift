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
    // any 1.6.x. Other versions use the `container` CLI. Widen after testing a new release.
    public static let apiSupportedVersions = SemanticVersion(1, 4, 0)..<SemanticVersion(1, 7, 0)
    // UserDefaults key of the support switch that sends every call through the CLI.
    public static let forceCLIBackendKey = "forceCLIBackend"

    // MARK: Behaviour defaults
    public static let defaultRefreshInterval: Double = 3
    public static let defaultDNSDomain = "test"
}
