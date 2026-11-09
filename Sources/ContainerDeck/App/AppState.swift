import SwiftUI
import AppKit
import DeckCore

@MainActor
@Observable
final class AppState {
    // Navigation
    var selection: SidebarItem? = .dashboard
    var showSetup = false
    var showPalette = false

    // Setup
    var report = SetupReport.empty
    var isChecking = false
    var busyFix: FixAction?
    var progressText: String?
    var lastError: String?
    /// Kernel download and install, shown under the Linux kernel check. nil when idle.
    var kernelInstall: KernelInstallState?
    var dnsDomain = AppConfig.defaultDNSDomain
    @ObservationIgnored private var kernelTask: Task<Void, Error>?
    @ObservationIgnored private var kernelRun = 0
    private var didAutoOpenSetup = false

    // Cross screen requests (set these to open a sheet or jump to an item)
    var runRequest: RunRequest?
    var buildRequest: BuildRequest?
    var focusedContainerID: String?
    /// Tab to show in the container detail. Set together with `focusedContainerID`
    /// (see `openContainer(_:tab:)`). The detail for that container consumes it.
    var focusedContainerTab: ContainerTabFocus?
    /// Compose stack to open. The Compose screen consumes it.
    var focusedComposeStack: ComposeStackFocus?
    var focusedImageRef: String?
    var focusedMachine: String?

    // Global feedback
    var toast: Toast?

    /// Bumped whenever something changes resources, so open lists reload.
    private(set) var resourcesVersion = 0

    // Saved settings
    private(set) var customCLIPath: String
    private(set) var setupCompleted: Bool

    private let runner = ProcessRunner()
    /// One router for the app session, per container tool path. It holds the XPC
    /// connections, the selector and the fallback counts, so every `client` shares it.
    @ObservationIgnored private var routerCache: (path: String, router: ContainerBackendRouter)?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let cliPath = "customCLIPath"
        static let setupCompleted = "setupCompleted"
        static let setupGuideSeen = "setupGuideSeen"
    }

    init() {
        customCLIPath = UserDefaults.standard.string(forKey: Keys.cliPath) ?? ""
        setupCompleted = UserDefaults.standard.bool(forKey: Keys.setupCompleted)
    }

    /// Client for Apple's platform. nil until the container tool is found.
    /// Calls that can go straight to Apple's container service use the shared router
    /// (direct API, the container command as fallback). The rest run the command.
    var client: ContainerClient? {
        guard let path = report.cliPath else { return nil }
        return ContainerClient(cliPath: path).routed(through: router(for: path)).withPlatformVersion(report.cliVersion)
    }

    /// The session's backend router. nil until the container tool is found.
    var router: ContainerBackendRouter? {
        report.cliPath.map { router(for: $0) }
    }

    func router(for path: String) -> ContainerBackendRouter {
        if let cached = routerCache, cached.path == path { return cached.router }
        let made = ContainerBackendRouter(cliPath: path)
        routerCache = (path, made)
        return made
    }

    /// Opens a container's detail, on a tab when given. Works from any screen,
    /// also when the Containers screen is not on screen yet.
    func openContainer(_ id: String, tab: ContainerDetailTab? = nil) {
        selection = .containers
        focusedContainerTab = tab.map { ContainerTabFocus(containerID: id, tab: $0) }
        focusedContainerID = id
    }

    /// Opens a compose stack (its file when known) on the Compose screen.
    func openComposeStack(_ name: String, file: String?) {
        selection = .compose
        focusedComposeStack = ComposeStackFocus(name: name, file: file)
    }

    /// Call after any change to containers, images, volumes or networks.
    func resourcesChanged() {
        resourcesVersion += 1
        // The shared container feed reloads once for everybody.
        BackgroundServices.shared.pollNow()
    }

    func showToast(_ message: String, style: Toast.Style = .info) {
        toast = Toast(message: message, style: style)
    }

    func showError(_ error: Error) {
        DiagnosticsLog.shared.record(error)
        toast = Toast(message: error.localizedDescription, style: .error)
    }

    // MARK: - Checks

    /// Runs every setup check. Opens the guide on first launch.
    func refresh() async {
        isChecking = true
        let path = customCLIPath.isEmpty ? nil : customCLIPath
        // The service check asks the daemon directly (no process), with the CLI as fallback.
        let service = SetupService(runner: runner, environment: .live(customCLIPath: path)) { [weak self] cliPath in
            guard let router = await self?.router(for: cliPath) else { return false }
            return try await router.isServiceRunning()
        }
        report = await service.runChecks()
        // Version dependent calls (Kubernetes on 1.7) read it from here, also on the router's CLI path.
        if let path = report.cliPath { await PlatformVersionCache.shared.seed(path, version: report.cliVersion) }
        isChecking = false
        if report.check(.kernel)?.state.isPassing == true, kernelTask == nil {
            // Installed (here or in Terminal): drop a failed note and any leftover download.
            if case .failed = kernelInstall { kernelInstall = nil }
            KernelInstaller.removeLeftoverDownloads()
        }
        // The guide opens by itself once on the very first launch, and after that only when
        // something compulsory is broken. It never opens again just because "Done" was not clicked.
        if !didAutoOpenSetup, SetupReport.shouldAutoOpenGuide(firstLaunch: !setupGuideSeen, report: report) {
            didAutoOpenSetup = true
            showSetup = true
            markSetupGuideSeen()
        }
    }

    /// True once the guide has been shown (or setup was finished in an older version).
    private var setupGuideSeen: Bool {
        setupCompleted || defaults.bool(forKey: Keys.setupGuideSeen)
    }

    private func markSetupGuideSeen() {
        defaults.set(true, forKey: Keys.setupGuideSeen)
    }

    func completeSetup() {
        setupCompleted = true
        defaults.set(true, forKey: Keys.setupCompleted)
        showSetup = false
    }

    func setCustomCLIPath(_ path: String) {
        customCLIPath = path
        defaults.set(path, forKey: Keys.cliPath)
    }

    // MARK: - Fixes

    func fix(_ action: FixAction) async {
        busyFix = action
        lastError = nil
        do {
            switch action {
            case .installPlatform:
                try await installPlatform()
            case .chooseBinary:
                chooseBinary()
            case .startService:
                try await cli().startService().orThrow()
            case .installKernel, .useRecommendedKernel:
                // Shows its own progress and errors under the kernel check (KernelInstallPanel).
                await installKernel()
            case .installRosetta:
                try await PrivilegedRunner(runner: runner)
                    .run("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"])
                    .orThrow()
            case .createDNSDomain:
                let domain = dnsDomain.trimmingCharacters(in: .whitespaces)
                let path = try cli().path
                try await PrivilegedRunner(runner: runner)
                    .run(path, ["system", "dns", "create", domain])
                    .orThrow()
            case .linkCommand:
                let path = try cli().path
                try await PrivilegedRunner(runner: runner).run([
                    ["/bin/mkdir", "-p", "/usr/local/bin"],
                    ["/bin/ln", "-sf", path, "/usr/local/bin/container"]
                ]).orThrow()
            }
        } catch {
            lastError = error.localizedDescription
        }
        progressText = nil
        busyFix = nil
        await refresh()
        resourcesChanged()
    }

    // MARK: - Kernel

    /// Downloads the recommended kernel with resume and a checksum, then installs it with
    /// Apple's tool (`KernelInstaller`). Progress and errors go to `kernelInstall`.
    private func installKernel() async {
        guard let path = report.cliPath else {
            kernelInstall = .failed(.other(message: DeckError.notInstalled.localizedDescription, details: ""))
            return
        }
        kernelRun += 1
        let run = kernelRun
        let installer = KernelInstaller(cli: ContainerCLI(path: path, runner: runner))
        kernelInstall = .running(.preparing)
        let task = Task.detached(priority: .userInitiated) {
            try await installer.install { stage in
                Task { @MainActor [weak self] in
                    guard let self, self.kernelRun == run, case .running = self.kernelInstall else { return }
                    self.kernelInstall = .running(stage)
                }
            }
        }
        kernelTask = task
        do {
            try await task.value
            kernelInstall = nil
            showToast("Linux kernel installed", style: .success)
        } catch is CancellationError {
            kernelInstall = nil
        } catch {
            let failure = error as? KernelInstallError
                ?? .other(message: error.localizedDescription, details: String(describing: error))
            DiagnosticsLog.shared.record(failure)
            kernelInstall = .failed(failure)
        }
        kernelTask = nil
    }

    /// Stops the kernel download. The partial file is deleted.
    func cancelKernelInstall() {
        kernelTask?.cancel()
    }

    #if DEBUG
    /// Automation only ("kernel-state:<name>"): shows a kernel install state without downloading.
    func debugKernelState(_ name: String) {
        let total: Int64 = 676_287_269
        switch name {
        case "download":
            kernelInstall = .running(.downloading(KernelDownloadProgress(receivedBytes: 312_400_000, totalBytes: total, bytesPerSecond: 8_400_000)))
        case "resume":
            kernelInstall = .running(.downloading(KernelDownloadProgress(receivedBytes: 498_100_000, totalBytes: total, bytesPerSecond: 2_350_000, attempt: 2)))
        case "verify":
            kernelInstall = .running(.verifying)
        case "install":
            kernelInstall = .running(.installing)
        case "mismatch":
            kernelInstall = .failed(.damaged(details: """
            https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst
            Download 1: kernel archive digest mismatch: expected sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6, got sha256:bef140a1a96994029153dca8c00b1750b9a5a764fb9db2dc68d7bb40e8a29e8a
            Download 2: kernel archive digest mismatch: expected sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6, got sha256:0d1f6a2a40b7e5c1a9e3f8b2c4d6e8f0a1b3c5d7e9f1a3b5c7d9e1f3a5b7c9d1
            """))
        case "offline":
            kernelInstall = .failed(.offline(details: """
            https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst
            URLError -1009: The Internet connection appears to be offline.
            Stopped after 4 tries.
            """))
        default:
            kernelInstall = nil
        }
    }
    #endif

    /// Stops Apple's container service. Asks first and names the containers that will stop.
    func stopService(confirm: Bool = true) async {
        if confirm, !(await confirmServiceStop()) { return }
        BackgroundServices.shared.noteServiceStopping()
        do {
            try await cli().stopService().orThrow()
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
        resourcesChanged()
    }

    /// Confirmation for stopping the service. Lists running containers and machines that stop with it.
    /// Use before anything that stops the service, including a restart.
    func confirmServiceStop(restart: Bool = false) async -> Bool {
        var running: [String] = []
        if let client {
            let all = (try? await client.listContainers(all: false)) ?? []
            running = all.filter(\.isRunning).map(\.id).sorted()
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = running.isEmpty ? .informational : .warning
        alert.messageText = restart ? "Restart the container service?" : "Stop the container service?"
        if running.isEmpty {
            alert.informativeText = restart
                ? "No containers are running. The service is back in a few seconds."
                : "No containers are running. You can start the service again at any time."
        } else {
            let shown = running.prefix(8).joined(separator: ", ")
            let more = running.count > 8 ? " and \(running.count - 8) more" : ""
            let count = running.count == 1 ? "1 running container" : "\(running.count) running containers"
            alert.informativeText = "\(count) will stop: \(shown)\(more).\n\nUnsaved work inside them is lost. Machines stop too. " + (restart ? "Start them again after the restart." : "Start the service again to bring them back.")
        }
        let verb = restart ? "Restart" : "Stop"
        let stop = alert.addButton(withTitle: running.isEmpty ? "\(verb) Service" : "\(verb) Service and Stop Containers")
        stop.hasDestructiveAction = !running.isEmpty
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func cli() throws -> ContainerCLI {
        guard let path = report.cliPath else { throw DeckError.notInstalled }
        return ContainerCLI(path: path, runner: runner)
    }

    private func installPlatform() async throws {
        let installer = PlatformInstaller(runner: runner)
        progressText = "Finding the release to install…"
        let release = try await installer.recommendedRelease()
        progressText = "Downloading container \(release.version)…"
        let package = try await installer.download(release)
        progressText = "Checking Apple's signature…"
        try await installer.verifySignature(of: package)
        progressText = "Installing. macOS will ask for your password."
        try await installer.install(package)
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.title = "Choose the container binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            setCustomCLIPath(url.path)
        }
    }
}

/// A request to show one tab of a container's detail.
struct ContainerTabFocus: Equatable {
    var containerID: String
    var tab: ContainerDetailTab

    /// The tab, when this request is for the detail showing `id` (or a container named `name`).
    func tab(forContainer id: String, name: String? = nil) -> ContainerDetailTab? {
        if containerID == id { return tab }
        if let name, !name.isEmpty, containerID == name { return tab }
        return nil
    }
}

/// A request to open a compose stack on the Compose screen.
struct ComposeStackFocus: Equatable {
    var name: String
    /// The compose file the stack was started from, when known.
    var file: String?

    /// What the Compose screen selects: the file when it is still on disk, else the stack by name.
    func selection(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ComposeSelection {
        if let file, !file.isEmpty, fileExists(file) { return .file(file) }
        return .stack(name)
    }
}

/// Opens the Run sheet. `replacing` is set for Edit and Recreate.
struct RunRequest: Identifiable {
    let id = UUID()
    var options: RunOptions
    var replacing: String?

    init(options: RunOptions, replacing: String? = nil) {
        self.options = options
        self.replacing = replacing
    }
}

/// Opens the Build Image sheet.
struct BuildRequest: Identifiable {
    let id = UUID()
    var contextDir: String?

    init(contextDir: String? = nil) {
        self.contextDir = contextDir
    }
}

struct Toast: Identifiable, Equatable {
    enum Style { case info, success, error }
    let id = UUID()
    var message: String
    var style: Style
}
