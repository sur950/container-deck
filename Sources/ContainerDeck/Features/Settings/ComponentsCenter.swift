import SwiftUI
import AppKit
import DeckCore

/// Versions of the system tools the app depends on, and in-app updates for the safe ones.
/// Shared by Settings (Components), the Dashboard tag and the background update check.
/// All checks and updates run in DeckCore (`ComponentChecker`, `ComponentUpdater`).
@MainActor
@Observable
final class ComponentsCenter {
    static let shared = ComponentsCenter()

    /// One update at a time, shown in a sheet with its log.
    struct Run: Equatable {
        enum Phase: Equatable {
            case running
            case done(String)
            case failed(String)
            case cancelled
        }
        var componentID: String
        var title: String
        var steps: [String]
        var current: Int = 0
        var cancellable = true
        var progress: Double?
        var log: [String] = []
        var phase: Phase = .running
        /// A switch to the tested version (the done message reads differently).
        var isSwitch = false
        /// The health checks after the change, when they ran.
        var health: ComponentHealthReport?
        /// The step that runs the health checks.
        var healthStep: Int?

        var isRunning: Bool { phase == .running }
    }

    /// A switch the app can not run: the exact steps by hand.
    struct ManualSteps: Equatable, Identifiable {
        var id: String { componentID }
        var componentID: String
        var title: String
        var reason: String?
        var steps: [String]
    }

    private(set) var rows: [ComponentInfo] = []
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    /// Row being re-checked before its update.
    private(set) var preparing: String?
    private(set) var run: Run?
    /// The sheet for `run` is up.
    var showRun = false
    /// The manual switch steps sheet.
    var manual: ManualSteps?
    /// Debug automation: a row to scroll to.
    var scrollTarget: String?

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private let cache = ComponentLatestCache()
    @ObservationIgnored let healthStore = ComponentHealthStore()
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var debugObserver: NSObjectProtocol?

    static let notifiedKey = "componentsNotifiedVersions"
    static let maxLogLines = 2000

    private init() {}

    func attach(_ state: AppState) {
        self.state = state
        attachDebugAutomation()
        // Screens report real failures (`ComponentHealth.report`). They arrive here.
        ComponentHealth.setReceiver { failure in
            Task { @MainActor in await ComponentsCenter.shared.receive(failure) }
        }
    }

    /// Apple container has an update (the Dashboard tag). Nothing is blocked.
    var containerUpdate: ComponentInfo? {
        rows.first { $0.kind == .container && $0.status == .updateAvailable }
    }

    var updateCount: Int { rows.filter { $0.status == .updateAvailable }.count }

    /// Apple container failed on a version other than the tested one (the popup).
    var containerProblem: ComponentInfo? {
        rows.first { $0.kind == .container && $0.offersSwitch }
    }

    /// Other tools that failed on a version other than the tested one (the Dashboard notice).
    var toolProblems: [ComponentInfo] {
        rows.filter { $0.kind != .container && $0.offersSwitch }
    }

    /// The first row of these kinds with a switch offer, for the short notes where a feature failed.
    func problem(in kinds: [ComponentKind]) -> ComponentInfo? {
        rows.first { kinds.contains($0.kind) && $0.offersSwitch }
    }

    private var toolsDirectory: String? { ComponentChecker.debugToolsDirectory }

    private func checker() -> ComponentChecker {
        let client = state?.client
        let tools = toolsDirectory
        let fetcher = ComponentLatestFetcher(cache: cache, standIn: tools.map(ComponentStandIn.latestFile))
        let servers = tools.map(ComponentStandIn.mcpServers) ?? MCPServerRegistry().load()
        return ComponentChecker(fetcher: fetcher, containerPath: state?.report.cliPath, mcpServers: servers) {
            if let tools { return ComponentStandIn.images(tools) }
            return (try? await client?.listImages()) ?? []
        }
    }

    /// Read only health checks. Stand in tools answer from files next to them (`ComponentStandIn`).
    private func probe() -> ComponentHealthProbe {
        guard let tools = toolsDirectory else { return ComponentHealthProbe() }
        return ComponentStandIn.probe(tools)
    }

    // MARK: Checking

    /// One check at a time. `force` skips the 6 hour cache (Check Now).
    func check(force: Bool = false) async {
        if let running = checkTask {
            await running.value
            if !force { return }
        }
        let task = Task { @MainActor in
            isChecking = true
            if force { cache.expireAll() }
            let checker = checker()
            let result = await checker.checkAll(force: force)
            rows = await checker.applyHealth(to: result, probe: probe(), store: healthStore, force: force)
            lastChecked = Date()
            isChecking = false
        }
        checkTask = task
        await task.value
        checkTask = nil
    }

    /// With the app's own update check, every `AppConfig.updateCheckInterval`. Uses the same switch.
    func checkIfDue() async {
        guard UserDefaults.standard.bool(forKey: PrefKey.checkForUpdates) else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < AppConfig.updateCheckInterval { return }
        await check()
        notifyNewVersions()
        // The popups: Apple container failed with this version, else a newer Apple container.
        // Everything else gets the Dashboard notice.
        if let problem = containerProblem {
            PlatformHealthPrompt.presentIfNeeded(problem, state: state)
        } else {
            PlatformUpdatePrompt.presentIfNeeded(containerUpdate, state: state)
        }
    }

    /// One notification per new safe version. MCP images are left out (tags such as latest move often).
    private func notifyNewVersions() {
        var notified = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? [])
        let fresh = rows.filter { row in
            guard row.status == .updateAvailable, row.kind != .mcp, let target = row.target else { return false }
            return !notified.contains("\(row.id)@\(target)")
        }
        guard !fresh.isEmpty else { return }
        for row in fresh { notified.insert("\(row.id)@\(row.target ?? "")") }
        UserDefaults.standard.set(Array(notified).sorted(), forKey: Self.notifiedKey)
        let title: String
        if fresh.count == 1, let row = fresh.first {
            title = "\(row.name) \(row.target ?? "") is ready"
        } else {
            title = "Updates for \(fresh.count) system tools"
        }
        Notifier.post(identifier: "components-\(fresh.map { "\($0.id)@\($0.target ?? "")" }.joined(separator: ","))",
                      title: title,
                      body: "Click to update in Settings, Components.",
                      userInfo: [Self.notificationKey: "1"])
    }

    nonisolated static let notificationKey = "components"

    // MARK: Updating

    /// Update pressed: read the row again with fresh data, confirm, then run. Nothing is blocked.
    func update(_ row: ComponentInfo, confirm: Bool = true) async {
        guard run?.isRunning != true, preparing == nil else { return }
        preparing = row.id
        let checker = checker()
        let fresh = await checker.check(row.kind, force: true).first { $0.id == row.id } ?? row
        replace(fresh)
        guard fresh.canUpdateInApp else {
            preparing = nil
            state?.showToast("\(fresh.name) has no update to install.")
            return
        }

        var restartOllama = false
        if fresh.kind == .ollama, confirm {
            switch confirmOllamaRestart(fresh) {
            case .none: preparing = nil; return
            case .some(let restart): restartOllama = restart
            }
        }
        let mcpRunning = fresh.kind == .mcp && BackgroundServices.shared.containers.contains {
            $0.isRunning && $0.labels[AgentsConfig.serverLabel] == fresh.name
        }
        let context = await checker.planContext(for: fresh, restartOllama: restartOllama, mcpServerRunning: mcpRunning)
        preparing = nil
        let plan: ComponentUpdatePlan
        do {
            plan = try ComponentUpdatePlanner.plan(for: fresh, context: context)
        } catch {
            state?.showError(error)
            return
        }
        if plan.manualOnly {
            showManual(plan)
            return
        }
        if confirm, fresh.kind != .ollama, confirmPlan(plan, row: fresh) == nil { return }
        start(plan, row: fresh, checker: checker, containerPath: context.containerPath)
    }

    // MARK: Switching to the tested version

    /// A screen reported a failure: add it to the tool's report for this version and show the
    /// switch offer when the version is not the tested one. Apple container gets the popup.
    func receive(_ failure: ComponentFailure) async {
        if rows.isEmpty { await check() }
        guard let row = rows.first(where: { $0.id == failure.componentID }), let installed = row.installed else { return }
        if row.health?.checks.contains(where: { $0.id == ComponentHealth.checkID(failure.feature) && $0.outcome == .failed }) == true { return }
        let report = healthStore.recordFailure(ComponentHealth.check(for: failure), componentID: row.id, version: installed)
        let assessed = await checker().assess(row, report: report)
        replace(assessed)
        if assessed.kind == .container, assessed.offersSwitch {
            PlatformHealthPrompt.presentIfNeeded(assessed, state: state)
        }
    }

    /// Switch pressed: read the row again (version, checks, target), then show the manual steps
    /// or confirm and run. A downgrade or an upgrade, whichever way the tested version is.
    func switchToTested(_ row: ComponentInfo, confirm: Bool = true) async {
        guard run?.isRunning != true, preparing == nil else { return }
        preparing = row.id
        let checker = checker()
        var fresh = await checker.check(row.kind, force: true).first { $0.id == row.id } ?? row
        fresh = await checker.applyHealth(to: fresh, probe: probe(), store: healthStore, force: true)
        replace(fresh)
        guard fresh.offersSwitch else {
            preparing = nil
            state?.showToast("\(fresh.name) \(fresh.installed ?? "") works with \(AppConfig.appName) now.", style: .success)
            return
        }
        await runSwitch(fresh, to: fresh.switchTarget, checker: checker, confirm: confirm)
    }

    /// Apple container releases people can pick in "Other Versions", newest first (no prereleases).
    func containerVersions() async -> [String] {
        let releases = await checker().fetcher.releases(.githubReleases(AppConfig.appleContainerRepository))
        return (releases?.versions ?? []).filter { !$0.isPrerelease }.sorted(by: >).prefix(12).map(\.description)
    }

    /// "Other Versions": install exactly the version the person picked, up or down, with the same
    /// plan, backup and confirmation as a switch. Nothing is blocked.
    func install(_ row: ComponentInfo, version: String) async {
        guard run?.isRunning != true, preparing == nil, version != row.installed else { return }
        preparing = row.id
        let checker = checker()
        let fresh = await checker.check(row.kind, force: true).first { $0.id == row.id } ?? row
        replace(fresh)
        await runSwitch(fresh, to: version, checker: checker, confirm: true)
    }

    private func runSwitch(_ fresh: ComponentInfo, to wanted: String?, checker: ComponentChecker, confirm: Bool) async {
        let (context, target) = await checker.switchContext(for: fresh, target: wanted)
        preparing = nil
        let plan: ComponentUpdatePlan
        do {
            plan = try ComponentSwitchPlanner.plan(for: fresh, to: target, context: context)
        } catch {
            state?.showError(error)
            return
        }
        if plan.isManual {
            manual = ManualSteps(componentID: fresh.id, title: plan.title, reason: plan.manualReason, steps: plan.manualSteps)
            return
        }
        if plan.manualOnly {
            showManual(plan)
            return
        }
        var chosen = plan
        // Clusters that share this Mac's image store (1.7) stop working on an older release:
        // always confirm then, even from the popup, and name them.
        var sharedClusters: [String] = []
        if fresh.kind == .container, plan.steps.contains(where: { if case .uninstallKeepingData = $0 { return true } else { return false } }) {
            sharedClusters = ((try? await state?.client?.listClusters()) ?? []).filter { $0.sharedImageStore == true }.map(\.name)
        }
        if confirm || !sharedClusters.isEmpty {
            guard let confirmed = confirmPlan(plan, row: fresh, action: "Switch", sharedClusters: sharedClusters) else { return }
            chosen = confirmed
        }
        start(chosen, row: fresh, checker: checker, containerPath: context.containerPath, switching: true)
    }

    func copySteps(_ steps: ManualSteps) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(steps.steps.joined(separator: "\n"), forType: .string)
        state?.showToast("Steps copied")
    }

    private func start(_ plan: ComponentUpdatePlan, row: ComponentInfo, checker: ComponentChecker, containerPath: String?,
                       switching: Bool = false) {
        run = Run(componentID: row.id, title: plan.title, steps: plan.steps.map(\.label), isSwitch: switching,
                  healthStep: plan.steps.firstIndex(of: .healthCheck))
        showRun = true
        if row.kind == .container, plan.steps.contains(.stopContainerService) { BackgroundServices.shared.noteServiceStopping() }
        let kind = row.kind
        let id = row.id
        let probe = probe()
        let updater = ComponentUpdater(client: state?.client, mcpServers: checker.mcpServers, recheck: {
            await checker.check(kind).first { $0.id == id }
        }, health: { info in
            guard let info else { return nil }
            return await probe.probe(info)
        })
        let stream = updater.run(plan, containerPath: containerPath)
        runTask = Task { @MainActor in
            var finished: ComponentInfo?
            do {
                for try await event in stream {
                    apply(event, finished: &finished)
                }
                if let finished {
                    replace(await checker.applyHealth(to: finished, probe: probe, store: healthStore))
                }
                let message: String
                let failedChecks = run?.health?.failed.count ?? 0
                if let installed = finished?.installed, installed == row.installed, row.kind != .mcp {
                    message = "\(row.name) is still \(installed). See the log for details."
                    run?.phase = .failed(message)
                    state?.showToast(message, style: .error)
                } else if failedChecks > 0 {
                    let version = finished?.installed.map { " \($0)" } ?? ""
                    message = failedChecks == 1 ? "\(row.name)\(version) is installed, but 1 feature isn't working."
                        : "\(row.name)\(version) is installed, but \(failedChecks) features aren't working."
                    // Every step ran. The checks step shows the warning, Settings shows what is not working.
                    run?.phase = .done(message)
                    state?.showToast(message, style: .error)
                } else {
                    message = finished?.installed.map { "\(row.name) is now \($0)." } ?? (switching ? "\(row.name) is switched." : "\(row.name) is updated.")
                    run?.phase = .done(message)
                    state?.showToast(message, style: .success)
                    Notifier.taskFinished(title: switching ? "\(row.name) switched" : "\(row.name) updated", body: message)
                }
            } catch is CancellationError {
                run?.phase = .cancelled
            } catch {
                run?.phase = .failed(error.localizedDescription)
                appendLog("Failed: \(error.localizedDescription)")
            }
            run?.cancellable = false
            runTask = nil
            if kind == .container, let state {
                await state.refresh()
                state.resourcesChanged()
            }
            if kind == .mcp { state?.resourcesChanged() }
        }
    }

    private func apply(_ event: ComponentUpdateEvent, finished: inout ComponentInfo?) {
        switch event {
        case .step(let index, let label, let cancellable):
            run?.current = index
            run?.cancellable = cancellable
            run?.progress = nil
            appendLog("[\(index + 1)/\(run?.steps.count ?? 0)] \(label)")
        case .log(let line):
            appendLog(line)
        case .progress(let fraction):
            run?.progress = fraction
        case .finished(let info):
            finished = info
        case .health(let report):
            healthStore.record(report)
            run?.health = report
        }
    }

    private func appendLog(_ line: String) {
        guard run != nil else { return }
        run?.log.append(line)
        if let count = run?.log.count, count > Self.maxLogLines {
            run?.log.removeFirst(count - Self.maxLogLines)
        }
    }

    /// Cancel works only while the current step is safe to stop (downloads and checks).
    func cancel() {
        guard run?.cancellable == true else { return }
        runTask?.cancel()
    }

    func dismissRun() {
        guard run?.isRunning != true else { showRun = false; return }
        showRun = false
        run = nil
    }

    private func replace(_ row: ComponentInfo) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }

    // MARK: Other actions

    /// Tools that update themselves (Ollama.app, LM Studio.app, Tailscale.app) or come from elsewhere.
    func openManualUpdate(_ row: ComponentInfo) {
        if case .appBundle(let app) = row.method, FileManager.default.fileExists(atPath: app) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration())
        } else if let url = row.downloadURL ?? row.notesURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens Settings on the Components tab (notification clicks, the Dashboard notice).
    func openSettingsTab() {
        SettingsOpener.open(tab: "components")
    }

    // MARK: Alerts

    private func runningContainerNames() -> [String] {
        BackgroundServices.shared.containers.filter(\.isRunning).map { $0.name.isEmpty ? $0.id : $0.name }.sorted()
    }

    /// nil: cancelled. Otherwise the plan to run (without the backup when its box was turned off).
    private func confirmPlan(_ plan: ComponentUpdatePlan, row: ComponentInfo, action: String = "Update",
                             sharedClusters: [String] = []) -> ComponentUpdatePlan? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(plan.title)?"
        var text = plan.confirmation
        if let clusters = ComponentSwitchNotes.sharedStoreClusters(sharedClusters) {
            text += "\n\n" + clusters
            alert.alertStyle = .warning
        }
        let backup = plan.steps.firstIndex { if case .backupContainerData = $0 { return true } else { return false } }
        if backup != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Back up the container data first (an APFS copy, almost no space)"
            alert.suppressionButton?.state = .on
        }
        if row.kind == .container, plan.steps.contains(.stopContainerService) {
            let running = runningContainerNames()
            if !running.isEmpty {
                let shown = running.prefix(8).joined(separator: ", ")
                let more = running.count > 8 ? " and \(running.count - 8) more" : ""
                if plan.steps.contains(.restartContainers) {
                    text += "\n\nThese stop now and start again when it is done: \(shown)\(more)."
                } else {
                    text += "\n\nThese stop now: \(shown)\(more). Containers set to start on their own come back when the service starts. Start the others again yourself."
                }
                alert.alertStyle = .warning
            }
        }
        alert.informativeText = text
        let ok = alert.addButton(withTitle: action)
        ok.keyEquivalent = "\r"
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var chosen = plan
        if let backup, alert.suppressionButton?.state != .on { chosen.steps.remove(at: backup) }
        return chosen
    }

    /// nil: cancelled. Otherwise whether to restart Ollama after the update.
    private func confirmOllamaRestart(_ row: ComponentInfo) -> Bool? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Update Ollama to \(row.target ?? "the newest version")?"
        alert.informativeText = "Homebrew updates Ollama. This can take a few minutes. The running server keeps the old version until it restarts."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Restart Ollama when done (loaded models unload)"
        alert.suppressionButton?.state = .off
        alert.addButton(withTitle: "Update")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return alert.suppressionButton?.state == .on
    }

    /// Macs without admin rights: the exact command to run in Terminal (by an admin).
    private func showManual(_ plan: ComponentUpdatePlan) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Run this in Terminal"
        alert.informativeText = "This account cannot approve the password prompt. Ask an admin of this Mac to run:\n\n\(plan.terminalCommand)"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plan.terminalCommand, forType: .string)
            state?.showToast("Command copied")
        }
    }

    // MARK: Debug automation (screenshots only)

    /// Debug builds with DECK_AUTOMATION=1:
    ///   components-check            check now (force)
    ///   components-update:<id>      start an update without the confirmation
    ///   components-confirm:<id>     start an update with the confirmation
    ///   components-sheet:<show|hide>
    ///   components-scroll:<id>      scroll the list to a row
    ///   components-prompt           show the Apple container update popup
    ///   components-prompt-choose:<update|later|skip>
    ///   components-switch:<id>      switch to the tested version without the confirmation (manual steps show their sheet)
    ///   components-switch-confirm:<id>   the same with the confirmation
    ///   components-report:<id>|<feature>|<error>   a failure as a screen would report it
    ///   components-health-prompt    show the Apple container "not working" popup
    ///   components-health-prompt-choose:<switch|later|skip>
    ///   components-manual:<hide>    close the manual steps sheet
    private func attachDebugAutomation() {
        guard DebugAutomation.isEnabled, debugObserver == nil else { return }
        debugObserver = NotificationCenter.default.addObserver(forName: .deckDebugCommand, object: nil, queue: .main) { note in
            let name = note.userInfo?["name"] as? String ?? ""
            let value = note.userInfo?["value"] as? String ?? ""
            MainActor.assumeIsolated { ComponentsCenter.shared.handleDebug(name, value) }
        }
    }

    private func handleDebug(_ name: String, _ value: String) {
        switch name {
        case "components-check":
            Task { await check(force: true) }
        case "components-update", "components-confirm":
            guard let row = rows.first(where: { $0.id == value }) else { return }
            Task { await update(row, confirm: name == "components-confirm") }
        case "components-install":
            // "container|1.6.1": the Other Versions menu, with its confirmation.
            let parts = value.split(separator: "|").map(String.init)
            guard parts.count == 2, let row = rows.first(where: { $0.id == parts[0] }) else { return }
            Task { await install(row, version: parts[1]) }
        case "components-prompt":
            PlatformUpdatePrompt.presentIfNeeded(containerUpdate, state: state, force: true)
        case "components-prompt-choose":
            PlatformUpdatePrompt.debugChoose(value)
        case "components-scroll":
            scrollTarget = value
        case "components-switch", "components-downgrade", "components-switch-confirm":
            guard let row = rows.first(where: { $0.id == value }) else { return }
            Task { await switchToTested(row, confirm: name == "components-switch-confirm") }
        case "components-report":
            let parts = value.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return }
            ComponentHealth.report(component: parts[0], feature: parts[1], message: parts[2])
        case "components-health-prompt":
            PlatformHealthPrompt.presentIfNeeded(containerProblem, state: state, force: true)
        case "components-health-prompt-choose":
            PlatformHealthPrompt.debugChoose(value)
        case "components-manual":
            if value == "hide" { manual = nil }
        case "components-sheet":
            showRun = value != "hide" && run != nil
        default:
            break
        }
    }
}

/// Opens Settings on one tab from code that has no `openSettings` (AppKit, deep links, notifications).
@MainActor
enum SettingsOpener {
    static func open(tab: String) {
        SettingsRouter.pendingTab = tab
        NSApp.activate()
        // The app menu's Settings item works from AppKit code, where openSettings is not available.
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        if let item = appMenu?.items.first(where: { $0.keyEquivalent == "," }), let menu = item.menu,
           let index = menu.items.firstIndex(of: item) {
            menu.performActionForItem(at: index)
        }
        NotificationCenter.default.post(name: .deckOpenSettingsTab, object: tab)
    }
}
