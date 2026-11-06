import SwiftUI
import AppKit
import ServiceManagement
import DeckCore

struct GeneralSettings: View {
    @AppStorage(PrefKey.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(PrefKey.terminalApp) private var terminalApp = TerminalApp.terminal.rawValue
    @AppStorage(PrefKey.refreshInterval) private var refreshInterval = 3.0
    @AppStorage(PrefKey.showCommandHints) private var showCommandHints = true
    @AppStorage(PrefKey.notifyOnUnexpectedStop) private var notifyOnStop = true
    @AppStorage(PrefKey.notifyOnTaskDone) private var notifyOnTaskDone = true
    @AppStorage(PrefKey.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(PrefKey.hideDockIcon) private var hideDockIcon = false
    @AppStorage(PrefKey.composeDefaultCPUs) private var composeCPUs = 2
    @AppStorage(PrefKey.composeDefaultMemory) private var composeMemory = "1G"
    @AppStorage(PrefKey.saveChatHistory) private var saveChatHistory = true

    @State private var installedTerminals: Set<String> = []
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    private let notifications = NotificationAccessModel.shared

    private let refreshChoices: [Double] = [1, 2, 3, 5, 10, 30]
    private let memoryChoices = ["512M", "1G", "2G", "4G", "8G", "16G"]

    var body: some View {
        Form {
            Section("Look") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Toggle("Show menu bar icon", isOn: $showMenuBarExtra)
                Toggle(isOn: $hideDockIcon) {
                    Text("Hide Dock icon")
                    Text("\(AppConfig.appName) stays in the menu bar only.")
                }
                    .onChange(of: hideDockIcon) { _, hide in
                        applyDockIcon(hidden: hide)
                    }
                if hideDockIcon && !showMenuBarExtra {
                    note("With both icons hidden, open Container Deck from Spotlight or Finder.")
                }
            }

            Section("Startup") {
                Toggle(isOn: openAtLoginBinding) {
                    Text("Open at login")
                    if !isBundledApp {
                        Text("Works in the bundled app only. Build it with scripts/bundle.sh and move it to Applications.")
                    } else if showMenuBarExtra {
                        Text("Starts quietly in the menu bar.")
                    }
                }
                .disabled(!isBundledApp)
                if loginStatus == .requiresApproval {
                    HStack {
                        note("Allow Container Deck in System Settings, Login Items.")
                        Spacer()
                        Button("Open Login Items") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
                if let loginError {
                    note(loginError, isError: true)
                }
            }

            Section("Containers") {
                Picker("Refresh every", selection: $refreshInterval) {
                    ForEach(refreshChoices, id: \.self) { seconds in
                        Text(seconds == 1 ? "1 second" : "\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                Toggle(isOn: $showCommandHints) {
                    Text("Show CLI commands for actions")
                    Text("Each action shows the container command it runs.")
                }
            }

            Section("AI Models") {
                Toggle(isOn: $saveChatHistory) {
                    Text("Save chat history")
                    Text("Keeps chats in the \(ChatVolumeSync.volumeName) volume. When off, chats are not saved.")
                }
                .onChange(of: saveChatHistory) { _, _ in
                    ChatSyncCenter.shared.historySettingChanged(ChatSyncCenter.modelsTarget)
                }
            }

            Section("Notifications") {
                LabeledContent {
                    NotificationAccessControls(access: notifications.access)
                } label: {
                    Text("System notifications")
                    Text(notifications.access.detail)
                }
                Toggle(isOn: $notifyOnStop) {
                    Text("Alert me when a container stops on its own")
                }
                .disabled(!Notifier.isAvailable)
                .onChange(of: notifyOnStop) { _, isOn in
                    if isOn { askIfNeverAsked() }
                }
                Toggle(isOn: $notifyOnTaskDone) {
                    Text("Notify when a stack is up or a pull or build finishes")
                }
                .disabled(!Notifier.isAvailable)
                .onChange(of: notifyOnTaskDone) { _, isOn in
                    if isOn { askIfNeverAsked() }
                }
            }

            Section("Terminal") {
                Picker("Open shells in", selection: $terminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(installedTerminals.contains(app.rawValue) ? app.title : "\(app.title) (not installed)")
                            .tag(app.rawValue)
                    }
                }
                if !installedTerminals.isEmpty && !installedTerminals.contains(terminalApp) {
                    note("This app is not installed. Shells will open in Terminal until you install it.")
                }
            }

            Section {
                // Value on the right, next to the stepper, like the Memory picker below.
                LabeledContent("CPUs per service") {
                    HStack(spacing: 6) {
                        Text(composeCPUs == 1 ? "1 CPU" : "\(composeCPUs) CPUs")
                            .monospacedDigit()
                        Stepper("CPUs per service", value: $composeCPUs, in: 1...maxCPUs)
                            .labelsHidden()
                    }
                }
                Picker("Memory per service", selection: $composeMemory) {
                    ForEach(memoryOptions, id: \.self) { value in
                        Text(memoryTitle(value)).tag(value)
                    }
                }
            } header: {
                Text("Compose defaults")
            } footer: {
                Text("Used for services that do not set their own limits.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .onAppear {
            installedTerminals = Set(
                TerminalApp.allCases
                    .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil }
                    .map(\.rawValue)
            )
            loginStatus = SMAppService.mainApp.status
            Task { await notifications.refresh() }
        }
    }

    // MARK: - Helpers

    private func note(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? DS.danger : DS.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var maxCPUs: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// The fixed choices plus the saved value when it is something else.
    private var memoryOptions: [String] {
        memoryChoices.contains(composeMemory) ? memoryChoices : memoryChoices + [composeMemory]
    }

    private func memoryTitle(_ value: String) -> String {
        if value.hasSuffix("G") { return String(value.dropLast()) + " GB" }
        if value.hasSuffix("M") { return String(value.dropLast()) + " MB" }
        return value
    }

    // MARK: - Dock icon

    private func applyDockIcon(hidden: Bool) {
        AppWindows.updatePolicy()
        // Changing the policy can send our windows to the back. Bring them forward again.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.activate()
        }
    }

    // MARK: - Open at login

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var openAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { setOpenAtLogin($0) }
        )
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Could not change this. \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }

    // MARK: - Alerts

    /// Turning a switch on asks for permission, but only while it was never decided.
    private func askIfNeverAsked() {
        guard notifications.access == .notAsked else { return }
        Task { await notifications.request() }
    }
}
