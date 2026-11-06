import Foundation
import Darwin

/// Where the running app bundle lives, and the quarantine clean up that keeps macOS from
/// asking again on every launch.
///
/// Container Deck is signed with its own certificate, not notarized. A copy downloaded in a
/// browser carries `com.apple.quarantine`, and macOS checks it again on each launch while that
/// flag is there. Once the person has opened the app (approved it), the app removes the flag
/// from its own bundle. Copies started from a disk image, Downloads or a translocated path are
/// offered a move to Applications first, since those places are read only or temporary.
public enum InstallLocation: Equatable, Sendable {
    /// /Applications or ~/Applications.
    case applications
    /// macOS runs a quarantined app from a random read only path (App Translocation).
    case translocated
    /// Started from a mounted disk image under /Volumes.
    case diskImage
    /// Started from the Downloads folder.
    case downloads
    /// Anywhere else (a build folder, the Desktop).
    case other

    public static let quarantineAttribute = "com.apple.quarantine"

    public static func classify(bundlePath: String, home: String = NSHomeDirectory()) -> InstallLocation {
        let path = (bundlePath as NSString).standardizingPath
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        if path.hasPrefix(home + "/Downloads/") { return .downloads }
        return .other
    }

    /// True when the app should offer to move itself to Applications.
    public var shouldOfferMove: Bool {
        switch self {
        case .translocated, .diskImage, .downloads: return true
        case .applications, .other: return false
        }
    }

    /// True when the path or anything inside it still has the quarantine flag.
    public static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Removes the quarantine flag from the bundle and everything inside it. Returns how many
    /// items had it. Skips items it cannot change.
    @discardableResult
    public static func removeQuarantine(at path: String) -> Int {
        var removed = 0
        func strip(_ item: String) {
            if removexattr(item, quarantineAttribute, XATTR_NOFOLLOW) == 0 { removed += 1 }
        }
        strip(path)
        if let walker = FileManager.default.enumerator(atPath: path) {
            while let relative = walker.nextObject() as? String {
                strip((path as NSString).appendingPathComponent(relative))
            }
        }
        return removed
    }
}
