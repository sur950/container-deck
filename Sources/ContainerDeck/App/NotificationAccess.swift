import SwiftUI
import AppKit
import UserNotifications
import DeckCore

/// What Settings and the Setup guide show for system notifications.
enum NotificationAccess: Equatable {
    /// Not read yet.
    case checking
    /// `swift run` has no app bundle, so Notification Center is off limits.
    case unavailable
    case notAsked
    case allowed
    case denied

    static func from(_ status: UNAuthorizationStatus, bundled: Bool) -> NotificationAccess {
        guard bundled else { return .unavailable }
        switch status {
        case .notDetermined: return .notAsked
        case .denied: return .denied
        // authorized, provisional and anything newer that lets alerts through.
        default: return .allowed
        }
    }

    var title: String {
        switch self {
        case .checking: return "Checking"
        case .unavailable: return "Needs the app bundle"
        case .notAsked: return "Not asked yet"
        case .allowed: return "Allowed"
        case .denied: return "Off in System Settings"
        }
    }

    /// One line under the title in Settings.
    var detail: String {
        switch self {
        case .checking: return "Reading the notification setting."
        case .unavailable: return "Notifications need the app bundle. Build it with scripts/bundle.sh."
        case .notAsked: return "Allow them to see events in Notification Center."
        case .allowed: return "Events go to Notification Center, also while the app is open."
        case .denied: return "Turn on \(AppConfig.appName) in System Settings, Notifications."
        }
    }

    /// The row in the Setup guide's Extras.
    var setupState: CheckState {
        switch self {
        case .checking: return .waiting("Checking")
        case .unavailable: return .warning("Notifications need the app bundle.")
        case .notAsked: return .missing("Get an alert in Notification Center when a stack is up, a pull or build ends, or a container stops.")
        case .allowed: return .ok("Events show in Notification Center.")
        case .denied: return .warning("Off in System Settings. Turn them on there any time.")
        }
    }
}

/// Pure rules for when to ask, what to send and how to show it.
enum NotificationPolicy {
    enum PostDecision: Equatable {
        case send
        /// Never asked yet: show the system prompt once, then send if allowed.
        case askThenSend
        case drop
    }

    /// The app asks by itself at most once, and never while the Setup guide is up
    /// (the guide has its own Allow button) or during scripted runs.
    static func shouldAskAutomatically(access: NotificationAccess, alreadyAsked: Bool, guideShowing: Bool, automation: Bool) -> Bool {
        access == .notAsked && !alreadyAsked && !guideShowing && !automation
    }

    static func postDecision(access: NotificationAccess, alreadyAsked: Bool) -> PostDecision {
        switch access {
        case .allowed: return .send
        case .notAsked: return alreadyAsked ? .drop : .askThenSend
        case .checking, .unavailable, .denied: return .drop
        }
    }

    /// In front: only Notification Center (the in-app toast covers the moment).
    /// Behind other apps: banner, Notification Center and sound.
    static func presentationOptions(appIsActive: Bool) -> UNNotificationPresentationOptions {
        appIsActive ? [.list] : [.banner, .list, .sound]
    }
}

/// Live notification status for Settings and the Setup guide. Refreshes when the app
/// becomes active, so a change in System Settings shows up right away.
@MainActor
@Observable
final class NotificationAccessModel {
    static let shared = NotificationAccessModel()

    private(set) var access: NotificationAccess = Notifier.isAvailable ? .checking : .unavailable
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Safe to call more than once.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await NotificationAccessModel.shared.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard Notifier.isAvailable else {
            access = .unavailable
            return
        }
        access = NotificationAccess.from(await Notifier.authorizationStatus(), bundled: true)
    }

    /// Shows the system prompt. macOS shows it only while the status is not decided.
    @discardableResult
    func request() async -> Bool {
        let granted = await Notifier.requestPermission()
        await refresh()
        return granted
    }

    /// Called once per launch, after the first setup check. Asks only if the app never asked before.
    func askOnceIfNeeded(guideShowing: Bool) async {
        await refresh()
        guard NotificationPolicy.shouldAskAutomatically(
            access: access,
            alreadyAsked: UserDefaults.standard.bool(forKey: PrefKey.notificationsAsked),
            guideShowing: guideShowing,
            automation: DebugAutomation.isEnabled
        ) else { return }
        await request()
    }
}

/// Status pill plus the one button that fits: Allow when not asked, Open System Settings when off.
struct NotificationAccessControls: View {
    let access: NotificationAccess
    var allowTitle = "Allow Notifications"

    var body: some View {
        HStack(spacing: 8) {
            Pill(access.title, tint: tint)
            switch access {
            case .notAsked:
                Button {
                    Task { await NotificationAccessModel.shared.request() }
                } label: {
                    DeckLabel(allowTitle, icon: .bell)
                }
                .deckPrimary()
            case .denied:
                Button("Open System Settings") { Notifier.openSystemSettings() }
            default:
                EmptyView()
            }
        }
    }

    private var tint: Color {
        switch access {
        case .allowed: return DS.running
        case .denied: return DS.warning
        default: return DS.textSecondary
        }
    }
}

/// The Notifications item in the Setup guide's Extras. Looks like the other optional checks.
struct NotificationSetupRow: View {
    let access: NotificationAccess

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(state: access.setupState)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Notifications").font(.body.weight(.medium))
                    Pill("Optional", tint: DS.textSecondary)
                }
                Text(access.setupState.message)
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch access {
            case .notAsked:
                Button {
                    Task { await NotificationAccessModel.shared.request() }
                } label: {
                    DeckLabel("Allow", icon: .bell)
                }
                .deckPrimary()
            case .denied:
                Button("Open System Settings") { Notifier.openSystemSettings() }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 10)
    }
}
