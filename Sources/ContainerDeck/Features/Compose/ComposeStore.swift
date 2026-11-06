import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DeckCore

/// What is picked in the project list.
enum ComposeSelection: Hashable {
    /// A compose file on disk, by path.
    case file(String)
    /// A stack found on the Mac by its labels, by project name.
    case stack(String)
}

enum ComposeTab: String, CaseIterable, Identifiable {
    case services, problems, commands, logs, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .services: return "Services"
        case .problems: return "Problems"
        case .commands: return "Commands"
        case .logs: return "Logs"
        case .activity: return "Activity"
        }
    }
}

/// State for the Compose screen.
@MainActor
@Observable
final class ComposeStore {
    // Lists
    var stacks: [ComposeStack] = []
    var recentFiles: [URL] = []
    /// Files merged on top of each recent file, by its path.
    var recentExtras: [String: [URL]] = [:]
    var selection: ComposeSelection?

    // The open compose file
    var project: ComposeProject?
    var plan: ComposePlan?
    var planError: String?
    var loadError: String?
    var activeProfiles: Set<String> = []
    var defaultCPUs: Int?
    var defaultMemory: String?
    /// Text of the open compose file, for line excerpts in Problems.
    var sourceText: String?
    /// Text of every file of the project by path (merged, included, extended files).
    var sourceTexts: [String: String] = [:]
    /// File the last load tried, also when it failed.
    var attemptedFile: URL?
    /// The file with the YAML error when it is not the main file.
    var yamlErrorFile: URL?
    var yamlErrorText: String?

    // Work in progress
    var tab: ComposeTab = .services
    var events: [ComposeEvent] = []
    var busyTitle: String?
    private var runTask: Task<Void, Never>?

    // Logs
    var logLines: [ComposeLogLine] = []
    var logService: String?
    var logError: String?
    var isFollowingLogs = false
    private var logTask: Task<Void, Never>?

    // `container compose` terminal command
    var pluginStatus: ComposePluginInstaller.Status?
    var pluginWorking = false
    /// Remembers an earlier install, so a plugin wiped by a container upgrade can be offered again.
    static let pluginInstalledKey = "composePluginInstalledOnce"

    private let recents = ComposeRecents()
    private static let maxLogLines = 5000

    init() {
        refreshRecents()
    }

    var isBusy: Bool { runTask != nil }

    /// Project name of the selection.
    var projectName: String? {
        if let project { return project.name }
        if case .stack(let name) = selection { return name }
        return nil
    }

    /// The running stack that matches the selection.
    var currentStack: ComposeStack? {
        guard let projectName else { return nil }
        return stacks.first { $0.name == projectName }
    }

    /// What Up would do to each service, by the config hash label. Empty without a plan.
    var reupChanges: [String: ComposeServiceChange] {
        guard let plan else { return [:] }
        return ComposeReup.changes(plan, containers: currentStack?.services.map(\.container) ?? [])
    }

    /// Line of a YAML syntax error in `loadError`, when there is one.
    var loadErrorLine: Int? {
        loadError.flatMap { ComposeYAMLIssue.line(in: $0) }
    }

    func status(for service: String) -> ComposeServiceStatus? {
        currentStack?.services.first { $0.service == service }
    }

    // MARK: - Loading

    /// Groups the shared feed's containers into stacks. Assigns only on a real change.
    func applyContainers(_ containers: [ContainerSummary]) {
        let next = ComposeStack.group(containers)
        if next != stacks { stacks = next }
    }

    /// Refreshes the shared feed now (one `list` for everybody) and regroups.
    func refreshStacks(client: ContainerClient?) async {
        guard client != nil else {
            stacks = []
            return
        }
        await BackgroundServices.shared.refresh()
        applyContainers(BackgroundServices.shared.containers)
    }

    /// Files picked together, merged in order like `-f` flags. Folders are opened alone.
    func open(files urls: [URL]) {
        let files = urls.filter { !Self.isDirectory($0) }
        guard files.count > 1 else {
            if let first = urls.first { open(first) }
            return
        }
        let ordered = ComposeFileOrder.sorted(files)
        let main = ordered[0]
        recents.add(main, extraFiles: Array(ordered.dropFirst()))
        refreshRecents()
        if selection == .file(main.path) {
            reload()
        } else {
            select(.file(main.path))
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Files merged on top of a recent file. Empty when it was opened alone.
    func extraFiles(for file: URL) -> [URL] {
        recentExtras[file.path] ?? []
    }

    private func refreshRecents() {
        recentFiles = recents.files
        var extras: [String: [URL]] = [:]
        for file in recentFiles {
            let extra = recents.extraFiles(for: file)
            if !extra.isEmpty { extras[file.path] = extra }
        }
        recentExtras = extras
    }

    /// Opens a compose file or a folder that holds one.
    func open(_ url: URL) {
        var file = url
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            guard let found = ComposeFileLocator().locate(from: url).first else {
                loadError = ComposeError.noFile(url.path).localizedDescription
                return
            }
            file = found
        }
        recents.add(file)
        refreshRecents()
        if selection == .file(file.path) {
            reload()
        } else {
            select(.file(file.path))
        }
    }

    func forget(_ file: URL) {
        recents.remove(file)
        refreshRecents()
        if selection == .file(file.path) { select(nil) }
    }

    func select(_ newSelection: ComposeSelection?) {
        guard newSelection != selection || project == nil else { return }
        stopLogs()
        selection = newSelection
        events = []
        project = nil
        plan = nil
        planError = nil
        loadError = nil
        sourceText = nil
        sourceTexts = [:]
        attemptedFile = nil
        yamlErrorFile = nil
        yamlErrorText = nil
        activeProfiles = []
        logLines = []
        tab = .services
        switch newSelection {
        case .file(let path):
            load(URL(fileURLWithPath: path))
        case .stack(let name):
            // Load the file the stack was started from, when it is still there.
            if let stack = stacks.first(where: { $0.name == name }), let file = stack.file,
               FileManager.default.fileExists(atPath: file.path) {
                let extra = stack.files.dropFirst().filter { FileManager.default.fileExists(atPath: $0.path) }
                load(file, extraFiles: extra.isEmpty ? nil : Array(extra))
            }
        case nil:
            break
        }
    }

    func reload() {
        if let project, project.files.count > 1 {
            load(project.file, extraFiles: project.overrideFiles)
            return
        }
        guard let file = project?.file ?? selectedFileURL ?? attemptedFile else { return }
        load(file, extraFiles: attemptedExtraFiles)
    }

    /// Extra files of the last load, so a reload after a fix reads the same list.
    private var attemptedExtraFiles: [URL]?

    private var selectedFileURL: URL? {
        if case .file(let path) = selection { return URL(fileURLWithPath: path) }
        return nil
    }

    /// Loads `file` with the files merged on top of it. Without a list it uses the
    /// list remembered in recents, else the override file next to it, like Docker Compose.
    private func load(_ file: URL, extraFiles: [URL]? = nil) {
        let extra = extraFiles ?? recents.extraFiles(for: file)
        attemptedFile = file
        attemptedExtraFiles = extraFiles
        sourceText = try? String(contentsOf: file, encoding: .utf8)
        yamlErrorFile = nil
        yamlErrorText = nil
        do {
            let loaded = extra.isEmpty
                ? try ComposeParser.load(file: file)
                : try ComposeParser.load(files: [file] + extra)
            project = loaded
            var texts: [String: String] = [:]
            for url in loaded.allFiles {
                texts[url.path] = url.path == file.path ? sourceText : (try? String(contentsOf: url, encoding: .utf8))
            }
            sourceTexts = texts
            loadError = nil
            replan()
        } catch {
            if let fileError = error as? ComposeFileYAMLError {
                yamlErrorFile = fileError.file
                yamlErrorText = try? String(contentsOf: fileError.file, encoding: .utf8)
            }
            project = nil
            plan = nil
            sourceTexts = [:]
            loadError = error.localizedDescription
        }
    }

    /// "with compose.override.yaml" or "with 2 more files". nil for one file.
    var mergedFilesSummary: String? {
        guard let extra = project?.overrideFiles, !extra.isEmpty else { return nil }
        return extra.count == 1 ? "with \(extra[0].lastPathComponent)" : "with \(extra.count) more files"
    }

    func replan() {
        guard let project else { return }
        let settings = ComposePlanSettings(
            activeProfiles: activeProfiles,
            defaultCPUs: defaultCPUs,
            defaultMemory: defaultMemory
        )
        do {
            plan = try ComposePlanner.plan(project, settings: settings)
            planError = nil
        } catch {
            plan = nil
            planError = error.localizedDescription
        }
    }

    func toggleProfile(_ profile: String) {
        if activeProfiles.contains(profile) {
            activeProfiles.remove(profile)
        } else {
            activeProfiles.insert(profile)
        }
        replan()
    }

    // MARK: - Actions

    func up(client: ContainerClient, state: AppState, options: ComposeRunner.UpOptions) {
        guard let plan else { return }
        perform(options.dryRun ? "Dry Run" : "Up", client: client, state: state) { runner, events in
            try await runner.up(plan, options: options, events: events)
        }
    }

    func down(client: ContainerClient, state: AppState, removeVolumes: Bool, keepNetworks: Bool = false) {
        guard let name = projectName else { return }
        let plan = self.plan
        perform("Down", client: client, state: state) { runner, events in
            try await runner.down(project: name, removeVolumes: removeVolumes, keepNetworks: keepNetworks, plan: plan, events: events)
        }
    }

    func start(client: ContainerClient, state: AppState, services: [String]? = nil) {
        guard let name = projectName else { return }
        let plan = self.plan
        perform("Start", client: client, state: state) { runner, events in
            try await runner.start(project: name, services: services, plan: plan, events: events)
        }
    }

    func stop(client: ContainerClient, state: AppState, services: [String]? = nil) {
        guard let name = projectName else { return }
        let plan = self.plan
        perform("Stop", client: client, state: state) { runner, events in
            try await runner.stop(project: name, services: services, plan: plan, events: events)
        }
    }

    func restart(client: ContainerClient, state: AppState, services: [String]? = nil) {
        guard let name = projectName else { return }
        let plan = self.plan
        perform("Restart", client: client, state: state) { runner, events in
            try await runner.restart(project: name, services: services, plan: plan, events: events)
        }
    }

    func pull(client: ContainerClient, state: AppState) {
        guard let plan else { return }
        perform("Pull", client: client, state: state) { runner, events in
            try await runner.pull(plan, events: events)
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func perform(
        _ title: String,
        client: ContainerClient,
        state: AppState,
        _ work: @escaping @Sendable (ComposeRunner, @escaping ComposeEventHandler) async throws -> Void
    ) {
        guard runTask == nil else { return }
        let project = projectName ?? "Stack"
        if ["Up", "Down", "Stop", "Restart"].contains(title) {
            // These stops are on purpose (Up recreates and removes orphans), so no "stopped unexpectedly" alerts.
            BackgroundServices.shared.noteProjectStopping(project, key: ComposeLabel.project)
        }
        let serviceCount = plan?.services.count ?? 0
        busyTitle = title
        tab = .activity
        events = []

        let (stream, continuation) = AsyncStream.makeStream(of: ComposeEvent.self)
        let runner = ComposeRunner(client: client)
        let consumer = Task { @MainActor [weak self] in
            for await event in stream {
                self?.events.append(event)
            }
        }
        runTask = Task { @MainActor [weak self] in
            do {
                try await work(runner) { event in
                    _ = continuation.yield(event)
                }
                if title == "Up" {
                    let services = serviceCount == 1 ? "1 service is running" : "\(serviceCount) services are running"
                    state.showToast("\(project) is up", style: .success)
                    Notifier.taskFinished(title: "\(project) is up", body: "All \(services).", link: .screen(.compose))
                }
            } catch is CancellationError {
                // The runner already said it stopped.
            } catch {
                state.showError(error)
                DiagnosticsLog.shared.record(error, source: "Compose")
                if title == "Up" {
                    Notifier.taskFinished(title: "\(project) could not start", body: error.localizedDescription, link: .screen(.compose))
                }
            }
            continuation.finish()
            await consumer.value
            self?.runTask = nil
            self?.busyTitle = nil
            state.resourcesChanged()
            await self?.refreshStacks(client: client)
        }
    }

    // MARK: - container compose command

    func refreshPluginStatus() {
        let installedBefore = UserDefaults.standard.bool(forKey: Self.pluginInstalledKey)
        Task { @MainActor [weak self] in
            let status = await Task.detached { ComposePluginInstaller().status(previouslyInstalled: installedBefore) }.value
            if status == .installed || status == .outdated {
                UserDefaults.standard.set(true, forKey: Self.pluginInstalledKey)
            }
            self?.pluginStatus = status
        }
    }

    /// One admin prompt. Copies the plugin into Apple's plugin folder, then asks the CLI for it.
    func installPlugin(client: ContainerClient, state: AppState) {
        guard !pluginWorking else { return }
        pluginWorking = true
        Task { @MainActor [weak self] in
            do {
                try await ComposePluginInstaller().install(runner: client.runner)
                UserDefaults.standard.set(true, forKey: Self.pluginInstalledKey)
                if await ComposePluginInstaller.verify(client: client) {
                    state.showToast("container compose is ready", style: .success)
                } else {
                    state.showToast("Installed. Start the container services to use it.", style: .info)
                }
            } catch {
                if !Self.isCancelledPrompt(error) { state.showError(error) }
            }
            self?.pluginWorking = false
            self?.refreshPluginStatus()
        }
    }

    func removePlugin(client: ContainerClient, state: AppState) {
        guard !pluginWorking else { return }
        pluginWorking = true
        Task { @MainActor [weak self] in
            do {
                try await ComposePluginInstaller().remove(runner: client.runner)
                UserDefaults.standard.set(false, forKey: Self.pluginInstalledKey)
                state.showToast("Removed the container compose command", style: .info)
            } catch {
                if !Self.isCancelledPrompt(error) { state.showError(error) }
            }
            self?.pluginWorking = false
            self?.refreshPluginStatus()
        }
    }

    /// The admin password prompt was closed.
    private static func isCancelledPrompt(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("-128") || text.contains("user canceled") || text.contains("user cancelled")
    }

    // MARK: - Logs

    func startLogs(client: ContainerClient, service: String?) {
        guard let name = projectName else { return }
        stopLogs()
        logLines = []
        logError = nil
        logService = service
        isFollowingLogs = true
        let runner = ComposeRunner(client: client)
        let services = service.map { [$0] }
        logTask = Task { @MainActor [weak self] in
            do {
                for try await line in runner.logs(project: name, services: services, follow: true, tail: 300) {
                    guard let self else { return }
                    self.logLines.append(line)
                    if self.logLines.count > ComposeStore.maxLogLines {
                        self.logLines.removeFirst(self.logLines.count - ComposeStore.maxLogLines)
                    }
                }
            } catch is CancellationError {
            } catch {
                self?.logError = error.localizedDescription
            }
            self?.isFollowingLogs = false
        }
    }

    func stopLogs() {
        logTask?.cancel()
        logTask = nil
        isFollowingLogs = false
    }

    /// Shows the logs tab for one service, or all with nil.
    func showLogs(client: ContainerClient, service: String?) {
        tab = .logs
        startLogs(client: client, service: service)
    }

    // MARK: - Import

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Compose File"
        panel.message = "Pick a compose file or a folder that has one. Pick several files to merge them."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.yaml]
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        panel.allowedContentTypes = types + [.folder]
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            open(files: panel.urls)
        }
    }
}
