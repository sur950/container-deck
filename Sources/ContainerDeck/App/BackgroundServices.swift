import SwiftUI
import AppKit
import UserNotifications
import DeckCore

/// Starts app wide background work once the window or menu bar panel is up:
/// container polling, crash alerts, auto start containers and update checks.
///
/// This is the one shared container feed. Every screen (Dashboard, Containers, menu bar,
/// Compose, the container detail header, Images, Volumes and Networks usage) reads
/// `containers` from here. There is one `list` loop for the whole app. It publishes only
/// when the list really changed, drops results that arrive after a newer one, and slows
/// down when nobody is looking (10 seconds in the background, so crash alerts still work).
@MainActor
@Observable
final class BackgroundServices {
    static let shared = BackgroundServices()

    /// Latest container list, running first then by name. Empty until the first poll works.
    private(set) var containers: [ContainerSummary] = []
    /// nil until the first poll finishes.
    private(set) var serviceRunning: Bool?
    /// True after the first poll came back (good or not).
    private(set) var hasLoaded = false
    /// Message of the last failed poll. nil after a good one.
    private(set) var loadError: String?
    /// Bumped each time `containers` changes. Caches key on it.
    private(set) var containersVersion = 0
    /// How calls reach the container services (direct API or the container command).
    /// Read after every poll. nil until the first poll.
    private(set) var backendStatus: BackendStatus?

    /// The container list comes straight from the daemon (about 4 ms, no process).
    var listIsDirect: Bool { backendStatus?.isDirect(.containerList) ?? false }
    /// Stats come straight from the daemon (all running containers in about 25 ms).
    var statsAreDirect: Bool { backendStatus?.isDirect(.stats) ?? false }

    @ObservationIgnored private(set) var lastPoll: Date?
    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollInterval: Double = 0
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var sequencer = PollSequencer()
    @ObservationIgnored private var autoStartRunning = false
    /// Run state per container id from the last good poll. nil means no baseline yet.
    @ObservationIgnored private var lastStates: [String: ContainerRunState]?
    /// Containers the person asked to stop, by id or name, with the time they asked.
    @ObservationIgnored private var userStops: [String: Date] = [:]
    @ObservationIgnored private var autoStartDone = false
    @ObservationIgnored private let notificationDelegate = NotificationDelegate()

    /// Slow pace while no window or panel is on screen.
    static let backgroundInterval: Double = 10
    /// With the direct API a list call costs about 4 ms and spawns no process.
    static let directForegroundInterval: Double = 1
    /// The menu bar panel is a glance view: 3 s keeps it light.
    static let directPanelInterval: Double = 3

    private init() {}

    /// Containers without the app's own helpers (volume browsing).
    var visibleContainers: [ContainerSummary] {
        containers.filter { !ContainersStore.isHelper($0) }
    }

    func container(_ id: String) -> ContainerSummary? {
        containers.first { $0.id == id } ?? containers.first { $0.name == id }
    }

    /// Safe to call more than once. Only the first call starts the loops.
    func start(state: AppState) {
        self.state = state
        StatsSampler.shared.attach(state)
        guard pollTask == nil else { return }

        Notifier.setUp(delegate: notificationDelegate)
        AppActivity.shared.start()
        AppActivity.shared.onChange { BackgroundServices.shared.activityChanged() }
        restartLoop()

        // Services that live for the whole app session.
        StatsHistoryRecorder.shared.start()
        DomainsStore.shared.startIfEnabled(client: state.client)
        SandboxRuntime.shared.attach()

        AppUpdates.shared.attachDebugAutomation()
        updateTask = Task {
            // Let the app settle before the first network call, then check every
            // AppConfig.updateCheckInterval (checkIfDue decides). Wake often so sleep and
            // turning the switch on are picked up.
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await AppUpdates.shared.checkIfDue()
                try? await Task.sleep(for: .seconds(min(15 * 60, AppConfig.updateCheckInterval)))
            }
        }
    }

    /// Seconds between polls for the current activity.
    var currentInterval: Double {
        Self.interval(for: AppActivity.shared.mode, direct: listIsDirect, preferred: Prefs.refreshInterval)
    }

    /// Direct API: 1 s with a window, 3 s with only the panel. The container command:
    /// the Refresh setting (3 s by default), at least 5 s for the panel. Nobody looking: 10 s.
    nonisolated static func interval(for mode: AppActivity.Mode, direct: Bool, preferred: Double) -> Double {
        switch mode {
        case .foreground: return direct ? min(preferred, directForegroundInterval) : preferred
        case .panel: return direct ? directPanelInterval : max(preferred, 5)
        case .background: return max(preferred, backgroundInterval)
        }
    }

    private func restartLoop() {
        pollTask?.cancel()
        pollInterval = currentInterval
        pollTask = Task {
            while !Task.isCancelled {
                // Cheap safety net in case a window notification was missed.
                AppActivity.shared.recompute()
                await self.poll()
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    /// Window shown, hidden, minimised or the panel opened or closed, or the backend changed.
    private func activityChanged() {
        guard pollTask != nil else { return }
        let interval = currentInterval
        if interval < pollInterval {
            // Somebody is looking again: poll now and keep the faster pace.
            restartLoop()
        } else {
            pollInterval = interval
        }
    }

    /// Containers call this before a stop, kill or delete the person asked for,
    /// so we do not alert about it.
    func noteUserAction(stopping id: String) {
        userStops[id] = Date()
    }

    /// Call before stopping the container service, so the stops are not alerts.
    func noteServiceStopping() {
        let now = Date()
        for container in containers where container.isRunning {
            userStops[container.id] = now
        }
        lastStates = nil
    }

    /// Call before Compose stops, restarts or removes a stack.
    func noteProjectStopping(_ project: String, key: String) {
        let now = Date()
        for container in containers where container.labels[key] == project || ComposeLabel.projectName(container.labels) == project {
            userStops[container.id] = now
        }
    }

    /// Polls right away, for example after an action in the menu bar panel.
    func pollNow() {
        guard state != nil else { return }
        Task { await poll() }
    }

    /// Manual refresh. Waits for the result.
    func refresh() async {
        await poll()
    }

    // MARK: - Service control (used by the menu bar panel)

    func startService() async {
        guard let state else { return }
        await state.fix(.startService)
        await poll()
    }

    func stopService() async {
        guard let state else { return }
        noteServiceStopping()
        await state.stopService()
        await poll()
    }

    // MARK: - Polling

    /// One `list --all`. Several may run at once (a manual refresh during a poll):
    /// the sequencer makes sure an older result never replaces a newer one.
    func poll() async {
        guard let state, let client = state.client else { return }
        let token = sequencer.begin()

        do {
            let list = try await client.listContainers(all: true)
            guard sequencer.accept(token) else { return }
            await updateBackendStatus(client)
            lastPoll = Date()
            apply(Self.ordered(list))
            if serviceRunning != true { serviceRunning = true }
            if loadError != nil { loadError = nil }
            if !hasLoaded { hasLoaded = true }
            detectUnexpectedStops(in: list)
            if !autoStartDone, !autoStartRunning {
                autoStartDone = true
                autoStartRunning = true
                await autoStart(from: list, client: client)
                autoStartRunning = false
            }
        } catch is CancellationError {
            return
        } catch {
            let message = error.localizedDescription
            let running = (try? await client.isServiceRunning()) ?? false
            guard sequencer.accept(token) else { return }
            await updateBackendStatus(client)
            // We lost track, so start a fresh baseline next time.
            apply([])
            lastStates = nil
            if serviceRunning != running { serviceRunning = running }
            if loadError != message { loadError = running ? message : nil }
            if !hasLoaded { hasLoaded = true }
            if !running {
                // Auto start again the next time the service comes up.
                autoStartDone = false
            }
        }
    }

    /// Reads the router's status. A change of backend (fallback, the Settings switch, a
    /// daemon update) changes the poll pace and the stats sampler's mode.
    func updateBackendStatus(_ client: ContainerClient? = nil) async {
        guard let client = client ?? state?.client, let status = await client.backendStatus() else { return }
        guard status != backendStatus else { return }
        let before = (listIsDirect, statsAreDirect)
        backendStatus = status
        DebugAutomation.log("backend: \(status.summary)")
        if before.0 != listIsDirect { activityChanged() }
        if before.1 != statsAreDirect { StatsSampler.shared.update() }
    }

    /// Running first, then by name.
    nonisolated static func ordered(_ list: [ContainerSummary]) -> [ContainerSummary] {
        list.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Publishes only real changes. Rows that appear, go or change state animate.
    private func apply(_ list: [ContainerSummary]) {
        let change = ListDiff.diff(old: containers, new: list)
        guard !change.isEmpty else { return }
        DebugAutomation.log("feed: list changed (\(containers.count) to \(list.count))")
        let runningChanged = containers.runningIDs != list.runningIDs
        withAnimation(.easeInOut(duration: 0.25)) {
            containers = list
            containersVersion += 1
        }
        if runningChanged { StatsSampler.shared.update() }
    }

    private func detectUnexpectedStops(in list: [ContainerSummary]) {
        let now = Date()
        userStops = userStops.filter { now.timeIntervalSince($0.value) < 300 }

        let previous = lastStates
        lastStates = Dictionary(list.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        guard let previous else { return }

        for container in list where container.state == .stopped && previous[container.id] == .running {
            let byID = userStops.removeValue(forKey: container.id) != nil
            let byName = userStops.removeValue(forKey: container.name) != nil
            if byID || byName { continue }
            reportUnexpectedStop(container)
        }
    }

    private func reportUnexpectedStop(_ container: ContainerSummary) {
        state?.resourcesChanged()
        guard UserDefaults.standard.bool(forKey: PrefKey.notifyOnUnexpectedStop) else { return }
        let name = container.name.isEmpty ? container.id : container.name
        Notifier.post(
            identifier: "stop-\(container.id)-\(Int(Date().timeIntervalSince1970))",
            title: "\(name) stopped unexpectedly",
            body: "Nobody asked it to stop. Click to open it in Container Deck.",
            userInfo: [NotificationKey.containerID: container.id]
        )
    }

    private func autoStart(from list: [ContainerSummary], client: ContainerClient) async {
        let wanted = Set(Prefs.autoStartContainers)
        guard !wanted.isEmpty else { return }
        let targets = list.filter { !$0.isRunning && (wanted.contains($0.id) || wanted.contains($0.name)) }
        guard !targets.isEmpty else { return }

        var started = 0
        var failed: [String] = []
        for container in targets {
            do {
                try await client.startContainer(container.id)
                started += 1
            } catch {
                failed.append(container.name.isEmpty ? container.id : container.name)
            }
        }

        if failed.isEmpty {
            state?.showToast(started == 1 ? "Auto started 1 container." : "Auto started \(started) containers.", style: .success)
        } else {
            state?.showToast("Could not auto start \(failed.joined(separator: ", ")).", style: .error)
        }
        state?.resourcesChanged()
    }

    // MARK: - Notification clicks

    func openFromNotification(containerID: String?, link: String?) {
        if let link, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let containerID else {
            NSApp.activate()
            return
        }
        let deepLink = DeepLink.container(containerID)
        if let state {
            DeepLinkRouter.route(deepLink, state: state)
        }
        // No main window open: open our own link so SwiftUI makes a window.
        if !MainWindow.bringForward(), let url = deepLink.url {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Notifications

enum NotificationKey {
    static let containerID = "containerID"
    static let link = "link"
    /// Update notification: the version. A click shows the install prompt.
    static let update = "update"
}

/// Thin wrapper over UNUserNotificationCenter. Does nothing without an app bundle,
/// because `swift run` has no bundle and the center would crash.
@MainActor
enum Notifier {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Asks once. Returns true when alerts are allowed.
    static func requestPermission() async -> Bool {
        guard isAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    static func post(identifier: String, title: String, body: String, userInfo: [String: String] = [:]) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var info: [AnyHashable: Any] = [:]
        for (key, value) in userInfo {
            info[key] = value
        }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Posts after asking for permission the first time. Quiet when permission is denied.
    static func postAsking(identifier: String, title: String, body: String, userInfo: [String: String] = [:]) {
        guard isAvailable else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let status: UNAuthorizationStatus = await withCheckedContinuation { continuation in
                center.getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
            }
            if status == .notDetermined {
                guard await requestPermission() else { return }
            } else if status == .denied {
                return
            }
            post(identifier: identifier, title: title, body: body, userInfo: userInfo)
        }
    }

    /// A long task finished (compose up, image pull, build). Respects the Settings switch.
    /// `whenInBackground`: only notify while the app is not in front (the toast covers the rest).
    static func taskFinished(title: String, body: String, link: DeepLink? = nil, whenInBackground: Bool = false) {
        guard UserDefaults.standard.bool(forKey: PrefKey.notifyOnTaskDone) else { return }
        if whenInBackground && NSApp.isActive { return }
        var info: [String: String] = [:]
        if let url = link?.url { info[NotificationKey.link] = url.absoluteString }
        postAsking(identifier: "task-\(UUID().uuidString)", title: title, body: body, userInfo: info)
    }

    /// Opens the Notifications pane of System Settings.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? AppConfig.bundleID
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Shows alerts while the app is in front and handles clicks.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let containerID = info[NotificationKey.containerID] as? String
        let link = info[NotificationKey.link] as? String
        let update = info[NotificationKey.update] as? String
        Task { @MainActor in
            if update != nil {
                AppUpdates.shared.promptForUpdate()
                return
            }
            BackgroundServices.shared.openFromNotification(containerID: containerID, link: link)
        }
        completionHandler()
    }
}

// MARK: - Updates


/// Update state shared by Settings, the menu bar panel and the app menu.
/// Checks GitHub releases, and installs a new version in place: download, checksum, Ed25519
/// update signature, code signing certificate check, then a small script swaps the bundle after
/// we quit and opens the new app. Builds without an update key open the download page instead.
@MainActor
@Observable
final class AppUpdates {
    static let shared = AppUpdates()

    enum Phase: Equatable {
        case idle
        case checking
        case done
        case failed(String)
    }

    enum InstallPhase: Equatable {
        case idle
        /// Fraction 0...1, nil while the size is unknown.
        case downloading(Double?)
        case verifying(String)
        case relaunching
        /// `manual`: offer to open the disk image instead.
        case failed(String, manual: Bool)
    }

    private(set) var phase: Phase = .idle
    private(set) var result: UpdateCheckResult?
    private(set) var lastChecked: Date?
    private(set) var install: InstallPhase = .idle
    /// The version the person pressed Later on.
    private(set) var skippedVersion: String? = UserDefaults.standard.string(forKey: PrefKey.skippedUpdateVersion)

    @ObservationIgnored private var notifiedVersion: String?
    @ObservationIgnored private let checker = UpdateChecker()
    @ObservationIgnored private let installer = UpdateInstaller()
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var debugObserver: NSObjectProtocol?

    private init() {}

    /// CFBundleShortVersionString, or nil for `swift run` builds.
    var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var latest: AppRelease? { result?.latest }
    var isUpdateAvailable: Bool { result?.isUpdateAvailable == true }
    var isChecking: Bool { phase == .checking }
    /// False when this build has no update key (AppConfig.updatePublicKey). Then updates are
    /// never installed by the app itself, the person downloads them from the release page.
    var canInstallInPlace: Bool { installer.canInstallAutomatically }
    /// Shown in the menu bar panel: a newer version the person did not put off.
    var shouldOfferUpdate: Bool { UpdatePolicy.shouldOffer(result, skippedVersion: skippedVersion) }
    var isLatestSkipped: Bool {
        guard let latest else { return false }
        return UpdatePolicy.isSkipped(latest.version, skippedVersion: skippedVersion)
    }
    var isInstalling: Bool {
        switch install {
        case .downloading, .verifying, .relaunching: return true
        case .idle, .failed: return false
        }
    }

    /// The bundle that would be replaced. nil under `swift run`.
    private var runningBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    private static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(AppConfig.appName)/update.log")
    }

    // MARK: Checking

    func check() async {
        guard phase != .checking else { return }
        phase = .checking
        do {
            result = try await checker.check(currentVersion: currentVersion)
            phase = .done
        } catch {
            // 404 (no release yet), rate limits and offline land here. Quiet: Settings shows the reason.
            phase = .failed(error.localizedDescription)
        }
        lastChecked = Date()
    }

    /// Automatic check, every `AppConfig.updateCheckInterval`. Runs only with the Settings switch on.
    func checkIfDue() async {
        guard UserDefaults.standard.bool(forKey: PrefKey.checkForUpdates) else { return }
        guard UpdatePolicy.isDue(lastChecked: lastChecked) else { return }
        await check()

        guard UpdatePolicy.shouldNotify(result, skippedVersion: skippedVersion, alreadyNotified: notifiedVersion),
              let latest else { return }
        notifiedVersion = latest.version.description
        Notifier.postAsking(
            identifier: "update-\(latest.version)",
            title: "\(AppConfig.appName) \(latest.version) is ready",
            body: canInstallInPlace
                ? "Click to install it. \(AppConfig.appName) opens again when it is done."
                : "Click to open the download page.",
            userInfo: [NotificationKey.update: latest.version.description]
        )
    }

    /// "Check for Updates…" in the app menu and Check Now: checks, then shows the answer.
    func checkAndReport() async {
        await check()
        NSApp.activate()

        let current = currentVersion ?? "dev"
        switch phase {
        case .failed(let message) where message == UpdateCheckError.noRelease.errorDescription:
            simpleAlert("No release is published yet", "You have version \(current).")
        case .failed(let message):
            simpleAlert("Could not check for updates", message, style: .warning)
        default:
            guard let latest else { return }
            if isUpdateAvailable {
                promptForUpdate()
            } else if result?.current == nil {
                simpleAlert("This build has no version number", "The latest release is \(latest.version).")
            } else {
                simpleAlert("You are up to date", "\(AppConfig.appName) \(current) is the latest version.")
            }
        }
    }

    /// Install and Relaunch, Release Notes or Later.
    func promptForUpdate() {
        guard let latest, isUpdateAvailable else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(AppConfig.appName) \(latest.version) is ready"
        if canInstallInPlace {
            alert.informativeText = "You have version \(currentVersion ?? "dev"). Install it now and \(AppConfig.appName) opens again when it is done. Your containers keep running."
            alert.addButton(withTitle: "Install and Relaunch")
        } else {
            alert.informativeText = "You have version \(currentVersion ?? "dev"). Download the new version from the release page."
            alert.addButton(withTitle: "Open Download Page")
        }
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: installAndRelaunch()
        case .alertSecondButtonReturn: openReleasePage()
        default: skipLatest()
        }
    }

    private func simpleAlert(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Later

    /// Later: stay quiet about this version. A newer release is offered again.
    func skipLatest() {
        guard let latest else { return }
        skippedVersion = latest.version.description
        UserDefaults.standard.set(skippedVersion, forKey: PrefKey.skippedUpdateVersion)
    }

    func clearSkipped() {
        skippedVersion = nil
        UserDefaults.standard.removeObject(forKey: PrefKey.skippedUpdateVersion)
    }

    // MARK: Install

    /// Downloads and verifies the new version, hands the swap to a script, then quits.
    /// `showPanel`: show the progress window (Settings shows progress inline and passes false).
    func installAndRelaunch(showPanel: Bool = true) {
        guard let latest, !isInstalling else { return }
        // No update key in this build: never install by ourselves.
        guard canInstallInPlace else {
            openReleasePage()
            return
        }
        if showPanel { UpdateProgressPanel.show() }

        guard let bundle = runningBundle else {
            install = .failed("This is a development build. Updates install only into a bundled app.", manual: true)
            return
        }
        if let problem = UpdateLocation.problem(bundlePath: bundle.path, isWritable: FileManager.default.isWritableFile(atPath:)) {
            install = .failed(problem.errorDescription ?? "This copy cannot update itself.", manual: true)
            return
        }
        guard latest.diskImage != nil else {
            install = .failed(UpdateInstallError.noDiskImage.errorDescription ?? "", manual: false)
            return
        }

        install = .downloading(0)
        let installer = self.installer
        let current = currentVersion
        let bundleID = Bundle.main.bundleIdentifier ?? AppConfig.bundleID
        installTask = Task {
            do {
                let prepared = try await installer.prepare(
                    release: latest, expectedBundleID: bundleID, currentVersion: current, runningApp: bundle
                ) { step in
                    Task { @MainActor in AppUpdates.shared.apply(step) }
                }
                try Task.checkCancellation()
                install = .relaunching
                try installer.handOff(prepared, replacing: bundle, pid: ProcessInfo.processInfo.processIdentifier,
                                      logFile: Self.logFile)
                // Give the script a moment to start, then quit so it can swap the bundle.
                try? await Task.sleep(for: .milliseconds(400))
                NSApp.terminate(nil)
            } catch is CancellationError {
                install = .idle
            } catch {
                let manual = (error as? UpdateInstallError)?.suggestsManualInstall ?? false
                install = .failed(error.localizedDescription, manual: manual)
            }
            installTask = nil
        }
    }

    /// Fallback when the app cannot replace itself: download (and check) the disk image, then open it in Finder.
    func openDiskImageInstead(showPanel: Bool = true) {
        guard let latest, let asset = latest.diskImage, !isInstalling else {
            openDownload()
            return
        }
        if showPanel { UpdateProgressPanel.show() }
        install = .downloading(0)
        let installer = self.installer
        installTask = Task {
            do {
                let work = try installer.makeWorkDir()
                let (dmg, _) = try await installer.downloadVerified(asset: asset, release: latest, into: work) { step in
                    Task { @MainActor in AppUpdates.shared.apply(step) }
                }
                install = .idle
                UpdateProgressPanel.close()
                NSWorkspace.shared.open(dmg)
            } catch is CancellationError {
                install = .idle
            } catch {
                install = .failed(error.localizedDescription, manual: false)
            }
            installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        if install != .relaunching { install = .idle }
    }

    /// Clears a failure so the panel or Settings goes back to the offer.
    func dismissInstallError() {
        if case .failed = install { install = .idle }
    }

    private func apply(_ step: UpdateInstaller.Step) {
        switch step {
        case .downloading(let fraction):
            // Late progress events must not move the bar back from a later step.
            if case .downloading = install { install = .downloading(fraction) }
        case .verifyingChecksum:
            install = .verifying("Checking the download")
        case .verifyingUpdateSignature:
            install = .verifying("Checking the update signature")
        case .mounting:
            install = .verifying("Opening the disk image")
        case .verifyingSignature:
            install = .verifying("Checking the signature")
        case .ready:
            install = .verifying("Ready to install")
        }
    }

    /// Opens the disk image link in the browser, or the release page when there is none.
    func openDownload() {
        if let latest {
            NSWorkspace.shared.open(latest.downloadURL)
        } else if let page = checker.releasesPageURL {
            NSWorkspace.shared.open(page)
        }
    }

    func openReleasePage() {
        if let url = latest?.pageURL ?? checker.releasesPageURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Debug automation (screenshots only)

    /// Debug builds with DECK_AUTOMATION=1:
    ///   update-fake                fake an available update
    ///   update-progress:<0..1|verify|relaunch|fail|fail-manual|idle>   fake install progress (opens the panel)
    ///   update-prompt              show the update alert
    ///   update-local:<dmg path>    use a local disk image as the release (tests the real install steps)
    ///   update-install             start Install and Relaunch
    func attachDebugAutomation() {
        guard DebugAutomation.isEnabled, debugObserver == nil else { return }
        debugObserver = NotificationCenter.default.addObserver(forName: .deckDebugCommand, object: nil, queue: .main) { note in
            let name = note.userInfo?["name"] as? String ?? ""
            let value = note.userInfo?["value"] as? String ?? ""
            MainActor.assumeIsolated { AppUpdates.shared.handleDebug(name, value) }
        }
    }

    private func handleDebug(_ name: String, _ value: String) {
        switch name {
        case "update-fake":
            let version = ReleaseVersion(value) ?? ReleaseVersion(9, 9, 0)
            guard let page = URL(string: "https://github.com/\(AppConfig.repository)/releases/tag/v\(version)"),
                  let dmg = URL(string: "https://example.invalid/ContainerDeck-\(version).dmg") else { return }
            let release = AppRelease(
                version: version, tagName: "v\(version)", title: "\(AppConfig.appName) \(version)",
                notes: "- Updates install in place and relaunch\n- Checksums and signature checks before install\n- Faster container list",
                pageURL: page, publishedAt: Date().addingTimeInterval(-3600), isPrerelease: false,
                assets: [ReleaseAsset(name: dmg.lastPathComponent, url: dmg, sizeBytes: 9_000_000)]
            )
            result = UpdateChecker.evaluate(latest: release, currentVersion: currentVersion ?? "0.1.0")
            phase = .done
            lastChecked = Date()
            clearSkipped()
        case "update-progress":
            UpdateProgressPanel.show()
            switch value {
            case "verify": install = .verifying("Checking the signature")
            case "relaunch": install = .relaunching
            case "fail": install = .failed(UpdateInstallError.checksumMismatch(expected: "", actual: "").errorDescription ?? "", manual: false)
            case "fail-manual": install = .failed(UpdateInstallError.notWritable("/Applications").errorDescription ?? "", manual: true)
            case "idle": install = .idle; UpdateProgressPanel.close()
            default: install = .downloading(Double(value))
            }
        case "update-local":
            // A local disk image as the release asset, with "<dmg>.sha256" and "<dmg>.sig" next to it when present.
            let dmg = URL(fileURLWithPath: value)
            var assets = [ReleaseAsset(name: dmg.lastPathComponent, url: dmg)]
            for ext in [".sha256", ".sig"] {
                let file = URL(fileURLWithPath: value + ext)
                if FileManager.default.fileExists(atPath: file.path) {
                    assets.append(ReleaseAsset(name: file.lastPathComponent, url: file))
                }
            }
            guard let page = URL(string: "https://github.com/\(AppConfig.repository)/releases") else { return }
            let release = AppRelease(version: ReleaseVersion(99, 0, 0), tagName: "v99.0.0", title: "Local test", notes: "",
                                     pageURL: page, publishedAt: Date(), isPrerelease: false, assets: assets)
            result = UpdateChecker.evaluate(latest: release, currentVersion: currentVersion ?? "0.1.0")
            phase = .done
        case "update-install":
            installAndRelaunch()
        case "update-prompt":
            DispatchQueue.main.async { AppUpdates.shared.promptForUpdate() }
        default:
            break
        }
    }
}
