import AppKit
import DeckCore

/// Keeps a downloaded copy from asking macOS for permission on every launch.
/// In Applications: removes the browser's quarantine flag once the app has been opened.
/// From a disk image, Downloads or a translocated path: offers to move to Applications.
@MainActor
enum InstallMover {
    static func check() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app",
              ProcessInfo.processInfo.environment["DECK_AUTOMATION"] == nil else { return }
        let path = bundle.path
        let location = InstallLocation.classify(bundlePath: path)
        if location == .applications {
            guard InstallLocation.isQuarantined(path) else { return }
            DispatchQueue.global(qos: .utility).async { InstallLocation.removeQuarantine(at: path) }
            return
        }
        guard location.shouldOfferMove, !UserDefaults.standard.bool(forKey: PrefKey.skipMoveToApplications) else { return }
        // Let the main window appear first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { offerMove(from: path, location: location) }
    }

    private static func offerMove(from runningPath: String, location: InstallLocation) {
        let alert = NSAlert()
        alert.messageText = "Move \(AppConfig.appName) to Applications?"
        let place: String
        switch location {
        case .diskImage: place = "the disk image"
        case .downloads: place = "your Downloads folder"
        default: place = "a temporary location macOS made for it"
        }
        alert.informativeText = "It is running from \(place). In Applications it can update itself, and macOS stops asking each time you open it."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: PrefKey.skipMoveToApplications)
        }
        guard answer == .alertFirstButtonReturn else { return }
        let source = originalPath(of: runningPath)
        let destination = "/Applications/" + (source as NSString).lastPathComponent
        do {
            try move(from: source, to: destination)
            relaunch(at: destination)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Could not move \(AppConfig.appName)"
            failed.informativeText = "\(error.localizedDescription)\n\nDrag \(AppConfig.appName) into your Applications folder in Finder instead."
            failed.runModal()
        }
    }

    private static func move(from source: String, to destination: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination) {
            // An older copy: keep it in the Trash rather than deleting it.
            try fm.trashItem(at: URL(fileURLWithPath: destination), resultingItemURL: nil)
        }
        try fm.copyItem(atPath: source, toPath: destination)
        InstallLocation.removeQuarantine(at: destination)
        // A copy in Downloads can go once it is safely in Applications. Disk images stay mounted.
        if InstallLocation.classify(bundlePath: source) == .downloads {
            try? fm.trashItem(at: URL(fileURLWithPath: source), resultingItemURL: nil)
        }
    }

    /// Opens the moved copy once this process has quit (only one copy may run at a time).
    private static func relaunch(at path: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "relaunch", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// The real location of a translocated app, through Security's SecTranslocate functions.
    /// Falls back to the running path when they are not available.
    private static func originalPath(of path: String) -> String {
        guard InstallLocation.classify(bundlePath: path) == .translocated,
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return path }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let function = unsafeBitCast(symbol, to: Original.self)
        guard let url = function(URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue() else { return path }
        return (url as URL).path
    }
}
