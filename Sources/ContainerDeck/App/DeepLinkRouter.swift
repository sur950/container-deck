import Foundation
import AppKit
import DeckCore

/// A parsed containerdeck:// link.
///
/// containerdeck://dashboard, containers, images, volumes, networks, machines,
/// compose, import, explore
/// containerdeck://container/<id>
/// containerdeck://image/<reference>   (for example image/docker.io/library/nginx:latest)
/// containerdeck://machine/<name>
/// containerdeck://setup
enum DeepLink: Equatable {
    case screen(SidebarItem)
    case container(String)
    case image(String)
    case machine(String)
    case setup
    /// Just show the window (used when a second copy hands off to the running one).
    case show
    /// The multi pane Logs window, optionally with containers: containerdeck://logs/web,db
    case logs([String])
    /// containerdeck://diagnostics
    case diagnostics

    static let scheme = AppConfig.urlScheme

    private static let screens: [String: SidebarItem] = [
        "dashboard": .dashboard,
        "containers": .containers,
        "images": .images,
        "volumes": .volumes,
        "networks": .networks,
        "machines": .machines,
        "compose": .compose,
        "import": .importEngines,
        "builds": .builds,
        "kubernetes": .kubernetes,
        "ai": .aiModels,
        "sandboxes": .sandboxes,
        "agents": .agents,
        "domains": .domains,
        "explore": .explore
    ]

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }

        // Works for containerdeck://container/abc and containerdeck:container/abc.
        var parts: [String] = []
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            parts.append(host)
        }
        let path = url.path(percentEncoded: false)
        parts += path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        guard let first = parts.first?.lowercased() else { return nil }
        let value = parts.dropFirst().joined(separator: "/")

        switch first {
        case "container":
            self = value.isEmpty ? .screen(.containers) : .container(value)
        case "image":
            self = value.isEmpty ? .screen(.images) : .image(value)
        case "machine":
            self = value.isEmpty ? .screen(.machines) : .machine(value)
        case "setup":
            self = .setup
        case "show":
            self = .show
        case "diagnostics":
            self = .diagnostics
        case "logs":
            self = .logs(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        default:
            guard let item = Self.screens[first] else { return nil }
            self = .screen(item)
        }
    }

    /// The link as a URL, for example to open a window from a notification.
    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .screen(let item):
            let name = Self.screens.first(where: { $0.value == item })?.key ?? "dashboard"
            components.host = name
        case .container(let id):
            components.host = "container"
            components.path = "/" + id
        case .image(let reference):
            components.host = "image"
            components.path = "/" + reference
        case .machine(let name):
            components.host = "machine"
            components.path = "/" + name
        case .setup:
            components.host = "setup"
        case .show:
            components.host = "show"
        case .diagnostics:
            components.host = "diagnostics"
        case .logs(let ids):
            components.host = "logs"
            if !ids.isEmpty { components.path = "/" + ids.joined(separator: ",") }
        }
        return components.url
    }
}

/// Handles containerdeck:// links.
@MainActor
enum DeepLinkRouter {
    static func handle(_ url: URL, state: AppState) {
        guard let link = DeepLink(url: url) else {
            state.showToast("\(AppConfig.appName) does not know this link.", style: .error)
            return
        }
        route(link, state: state)
        NSApp.activate()
    }

    static func route(_ link: DeepLink, state: AppState) {
        switch link {
        case .screen(let item):
            state.selection = item
        case .container(let id):
            state.selection = .containers
            state.focusedContainerID = id
        case .image(let reference):
            state.selection = .images
            state.focusedImageRef = reference
        case .machine(let name):
            state.selection = .machines
            state.focusedMachine = name
        case .setup:
            state.showSetup = true
        case .show:
            break
        case .logs(let ids):
            LogsWindow.open(state: state, containerIDs: ids)
        case .diagnostics:
            DiagnosticsWindow.show(state: state)
        }
    }
}

/// Finds the main window (WindowGroup id "main") so we bring it forward
/// instead of opening a second one.
@MainActor
enum MainWindow {
    static var existing: NSWindow? {
        NSApp.windows.first { window in
            guard window.isVisible || window.isMiniaturized else { return false }
            guard let raw = window.identifier?.rawValue else { return false }
            return raw == "main" || raw.hasPrefix("main-")
        }
    }

    /// Returns false when no main window is open.
    @discardableResult
    static func bringForward() -> Bool {
        NSApp.activate()
        guard let window = existing else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        AppWindows.updatePolicy()
        return true
    }
}
