import Foundation

public enum CheckID: String, CaseIterable, Sendable, Hashable {
    case hardware
    case cliInstalled
    case cliVersion
    case service
    case kernel
    case rosetta
    case dns
    case terminalCommand

    public var title: String {
        switch self {
        case .hardware: return "Mac and macOS"
        case .cliInstalled: return "Container tool"
        case .cliVersion: return "Tool version"
        case .service: return "Container service"
        case .kernel: return "Linux kernel"
        case .rosetta: return "Rosetta for Intel images"
        case .dns: return "Local DNS domain"
        case .terminalCommand: return "Terminal command"
        }
    }

    /// Optional checks never block setup.
    public var isOptional: Bool {
        switch self {
        case .rosetta, .dns, .terminalCommand: return true
        default: return false
        }
    }
}

public enum CheckState: Sendable, Equatable {
    /// Still being checked.
    public var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }

    case ok(String)
    case warning(String)
    case missing(String)
    case failed(String)
    case waiting(String)

    public var message: String {
        switch self {
        case .ok(let m), .warning(let m), .missing(let m), .failed(let m), .waiting(let m):
            return m
        }
    }

    public var isPassing: Bool {
        switch self {
        case .ok, .warning: return true
        default: return false
        }
    }
}

public enum FixAction: String, Sendable, Hashable {
    case installPlatform
    case chooseBinary
    case startService
    case installKernel
    case installRosetta
    case createDNSDomain
    case linkCommand

    public var title: String {
        switch self {
        case .installPlatform: return "Install"
        case .chooseBinary: return "Choose…"
        case .startService: return "Start"
        case .installKernel: return "Install kernel"
        case .installRosetta: return "Install Rosetta"
        case .createDNSDomain: return "Create domain"
        case .linkCommand: return "Add command"
        }
    }

    /// True when macOS will ask for an admin password.
    public var needsAdmin: Bool {
        switch self {
        case .installPlatform, .installRosetta, .createDNSDomain, .linkCommand: return true
        default: return false
        }
    }
}

public struct SetupCheck: Identifiable, Sendable, Equatable {
    public let id: CheckID
    public var state: CheckState
    public var fix: FixAction?

    public init(id: CheckID, state: CheckState, fix: FixAction? = nil) {
        self.id = id
        self.state = state
        self.fix = fix
    }

    public var title: String { id.title }
    public var isOptional: Bool { id.isOptional }
}

public struct SetupReport: Sendable, Equatable {
    public var checks: [SetupCheck]
    public var cliPath: String?
    public var cliVersion: SemanticVersion?
    public var serviceRunning: Bool

    public init(checks: [SetupCheck], cliPath: String?, cliVersion: SemanticVersion?, serviceRunning: Bool) {
        self.checks = checks
        self.cliPath = cliPath
        self.cliVersion = cliVersion
        self.serviceRunning = serviceRunning
    }

    public static let empty = SetupReport(checks: [], cliPath: nil, cliVersion: nil, serviceRunning: false)

    public var requiredChecks: [SetupCheck] { checks.filter { !$0.isOptional } }
    public var optionalChecks: [SetupCheck] { checks.filter { $0.isOptional } }

    /// Every required check passes.
    public var isReady: Bool {
        !checks.isEmpty && requiredChecks.allSatisfy { $0.state.isPassing }
    }

    /// Required checks the setup guide is needed for. A stopped service is left out on
    /// purpose: the app offers Start Service in place, so it never opens the guide.
    public var blockingIssues: [SetupCheck] {
        requiredChecks.filter { $0.id != .service && !$0.state.isPassing && !$0.state.isWaiting }
    }

    /// Whether the guide should open by itself at launch.
    /// - First launch ever: yes, once, so people see what the app checks.
    /// - Later: only when something compulsory is broken (tool missing or too old, no kernel, unsupported Mac).
    public static func shouldAutoOpenGuide(firstLaunch: Bool, report: SetupReport) -> Bool {
        guard !report.checks.isEmpty else { return false }
        if firstLaunch { return true }
        return !report.blockingIssues.isEmpty
    }

    /// First required check that needs attention.
    public var firstIssue: SetupCheck? {
        requiredChecks.first { !$0.state.isPassing }
    }

    public func check(_ id: CheckID) -> SetupCheck? {
        checks.first { $0.id == id }
    }
}
