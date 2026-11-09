import SwiftUI
import AppKit
import DeckCore

/// Settings, Components: the system tools Container Deck uses, their versions, and safe updates.
///
/// Its own tab next to Updates: Updates is about Container Deck itself, and this list has a row
/// per tool, each with its own state and action, which needs the room of a full tab.
struct ComponentsSettings: View {
    @AppStorage(PrefKey.checkForUpdates) private var checkForUpdates = true
    private let center = ComponentsCenter.shared

    var body: some View {
        @Bindable var center = center
        ScrollViewReader { proxy in
            Form {
                Section {
                    LabeledContent("Last checked") {
                        HStack(spacing: 10) {
                            if center.isChecking {
                                ProgressView().controlSize(.small)
                            }
                            Text(center.lastChecked.map { Format.relative($0) } ?? "Not yet")
                                .foregroundStyle(DS.textSecondary)
                            Button {
                                Task { await center.check(force: true) }
                            } label: {
                                DeckLabel("Check Now", icon: .refresh)
                            }
                            .disabled(center.isChecking)
                        }
                    }
                    Toggle("Check with app updates", isOn: $checkForUpdates)
                } header: {
                    Text("System tools")
                } footer: {
                    Text("Every tool updates from here to its newest release, the same way it was installed, and you can install any version yourself. If a feature \(AppConfig.appName) uses stops working on a version other than the tested one, it shows here with a switch to the tested version.")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if center.rows.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Checking versions")
                                .foregroundStyle(DS.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                }

                ForEach(ComponentGroup.allCases, id: \.self) { group in
                    let rows = center.rows.filter { $0.kind.group == group }
                    if !rows.isEmpty {
                        Section(group.title) {
                            ForEach(rows) { row in
                                ComponentRow(row: row)
                                    .id(row.id)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: center.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
                center.scrollTarget = nil
            }
        }
        .task {
            if center.rows.isEmpty { await center.check() }
        }
        .sheet(isPresented: $center.showRun) {
            ComponentRunSheet()
        }
        .sheet(item: $center.manual) { steps in
            ComponentManualStepsSheet(steps: steps)
        }
    }
}

// MARK: - Row

private struct ComponentRow: View {
    let row: ComponentInfo
    private let center = ComponentsCenter.shared
    /// Apple container releases for "Other Versions", read when the row shows.
    @State private var versions: [String] = []

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(icon, tint: row.status == .notInstalled ? DS.textTertiary : DS.accent, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let method = row.method, row.status != .notInstalled {
                        Text(method.title)
                            .font(.caption)
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                    }
                }
                Text(versionLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = row.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(row.status == .notWorking ? DS.warning : DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if row.status == .notWorking, !row.failedChecks.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(row.failedChecks) { check in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                DeckIcon(.error, size: 9, color: DS.danger)
                                Text(check.failure)
                                    .font(.caption)
                                    .foregroundStyle(DS.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .help(check.detail ?? "")
                        }
                    }
                    .padding(.top, 1)
                }
                if let notes = row.notesURL, row.status != .notInstalled {
                    Button {
                        NSWorkspace.shared.open(notes)
                    } label: {
                        Text("Release notes")
                            .font(.caption)
                    }
                    .deckLink()
                    .help(notes.absoluteString)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Pill(row.status.title, tint: tint)
                action
                if row.kind == .container, row.installed != nil, !versions.isEmpty, !isThisRunning {
                    otherVersions
                }
            }
        }
        .padding(.vertical, 3)
        .task(id: row.installed) {
            if row.kind == .container, row.installed != nil { versions = await center.containerVersions() }
        }
    }

    private var icon: DeckIconName {
        switch row.kind {
        case .container: return .containers
        case .ollama, .mlx, .lmStudio: return .aiModels
        case .uv: return .download
        case .mcp: return .agents
        case .cloudflared, .ngrok, .tailscale: return .share
        case .kubectl, .helm: return .kubernetes
        case .agent: return .terminal
        }
    }

    private var tint: Color {
        switch row.status {
        case .upToDate: return DS.running
        case .updateAvailable: return DS.accent
        case .notWorking: return DS.danger
        case .notInstalled, .unknown: return DS.stopped
        }
    }

    /// "Installed 1.6.1, update to 1.6.2" or "Installed 4.1.0, latest 5.0.1".
    private var versionLine: String {
        guard row.status != .notInstalled || row.installed != nil else {
            return row.kind.role
        }
        var parts: [String] = []
        if let installed = row.installed { parts.append("Installed \(installed)") }
        if row.status != .notWorking, let target = row.target {
            parts.append("update to \(target)")
        } else if let latest = row.latest, latest != row.installed {
            parts.append(row.kind == .mcp ? "registry \(latest)" : "latest \(latest)")
        }
        if let tested = row.testedText, row.installed != nil { parts.append("tested \(tested)") }
        return parts.joined(separator: ", ")
    }

    private var isThisRunning: Bool { center.run?.componentID == row.id && center.run?.isRunning == true }
    private var busy: Bool { center.run?.isRunning == true || center.preparing != nil }

    @ViewBuilder
    private var action: some View {
        if isThisRunning {
            Button("Show Progress") { center.showRun = true }
                .controlSize(.small)
        } else if center.preparing == row.id {
            ProgressView().controlSize(.small)
        } else {
            switch row.status {
            case .updateAvailable where row.canUpdateInApp:
                Button("Update") {
                    Task { await center.update(row) }
                }
                .deckPrimary()
                .controlSize(.small)
                .disabled(busy)
            case .updateAvailable:
                Button(manualTitle) { center.openManualUpdate(row) }
                    .controlSize(.small)
            case .notWorking:
                if let target = row.switchTarget {
                    if ComponentSwitchPlanner.runsInApp(row) {
                        Button("Switch to \(target)") {
                            Task { await center.switchToTested(row) }
                        }
                        .deckPrimary()
                        .controlSize(.small)
                        .disabled(busy)
                    } else {
                        Button("How to Switch") {
                            Task { await center.switchToTested(row) }
                        }
                        .controlSize(.small)
                        .disabled(busy)
                        .help("The steps to switch to \(target)")
                    }
                } else {
                    Button("Check Again") {
                        Task { await center.check(force: true) }
                    }
                    .controlSize(.small)
                    .disabled(busy || center.isChecking)
                }
            case .notInstalled where row.downloadURL != nil:
                Button("Get It") { center.openManualUpdate(row) }
                    .controlSize(.small)
            default:
                EmptyView()
            }
        }
    }

    /// Any Apple container release, up or down. Same backup and confirmation as a switch.
    private var otherVersions: some View {
        Menu {
            ForEach(versions, id: \.self) { version in
                Button(version == row.installed ? "\(version), installed" : version) {
                    Task { await center.install(row, version: version) }
                }
                .disabled(version == row.installed)
            }
        } label: {
            Text("Other Versions").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .tint(DS.accent)
        .disabled(busy)
        .help("Install another Apple container release")
    }

    private var manualTitle: String {
        if case .appBundle(let app) = row.method {
            return "Open " + ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return "Download"
    }
}

// MARK: - Progress sheet

private struct ComponentRunSheet: View {
    private let center = ComponentsCenter.shared

    var body: some View {
        if let run = center.run {
            SheetScaffold(run.title, subtitle: subtitle(run), icon: .components, width: 560, scrolls: false) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(run.steps.enumerated()), id: \.offset) { index, label in
                        HStack(spacing: 8) {
                            stepIcon(index, run: run)
                                .frame(width: 16, height: 16)
                            Text(label)
                                .font(.callout)
                                .foregroundStyle(index <= run.current ? DS.textPrimary : DS.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if run.isRunning, let progress = run.progress {
                    ProgressView(value: progress)
                        .tint(DS.accent)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(run.log.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(DS.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(10)
                    }
                    .frame(minHeight: 150, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).fill(DS.surfaceSunken))
                    .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
                    .onChange(of: run.log.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            } footer: {
                if run.isRunning {
                    Button("Hide") { center.showRun = false }
                    Button("Cancel") { center.cancel() }
                        .disabled(!run.cancellable)
                        .help(run.cancellable ? "Stop the update" : "This step must finish first")
                } else {
                    Button("Done") { center.dismissRun() }
                        .keyboardShortcut(.defaultAction)
                        .deckPrimary()
                }
            }
            .frame(height: min(640, 360 + CGFloat(run.steps.count) * 28))
        }
    }

    private func subtitle(_ run: ComponentsCenter.Run) -> String {
        switch run.phase {
        case .running: return "Step \(run.current + 1) of \(run.steps.count)"
        case .done(let message): return message
        case .failed(let message): return message
        case .cancelled: return "Cancelled. Nothing was changed."
        }
    }

    @ViewBuilder
    private func stepIcon(_ index: Int, run: ComponentsCenter.Run) -> some View {
        if index == run.healthStep, let health = run.health, !health.failed.isEmpty {
            DeckIcon(.warning, size: 13, color: DS.warning)
                .help(health.failed.map(\.failure).joined(separator: "\n"))
        } else if index < run.current || (index == run.current && isDone(run)) {
            DeckIcon(.success, size: 13, color: DS.running)
        } else if index == run.current {
            switch run.phase {
            case .running: ProgressView().controlSize(.mini)
            case .failed: DeckIcon(.error, size: 13, color: DS.danger)
            case .cancelled: DeckIcon(.warning, size: 13, color: DS.warning)
            case .done: DeckIcon(.success, size: 13, color: DS.running)
            }
        } else {
            DeckIcon(.pending, size: 13, color: DS.textTertiary)
        }
    }

    private func isDone(_ run: ComponentsCenter.Run) -> Bool {
        if case .done = run.phase { return true }
        return false
    }
}

// MARK: - Manual steps

/// A downgrade the app can't run itself: why, and the exact steps with a Copy button.
private struct ComponentManualStepsSheet: View {
    let steps: ComponentsCenter.ManualSteps
    private let center = ComponentsCenter.shared

    var body: some View {
        SheetScaffold(steps.title, subtitle: steps.reason ?? "Do these steps by hand.", icon: .components, width: 560, scrolls: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: 18, alignment: .trailing)
                        if ComponentManualStepsSheet.isCommand(step) {
                            Text(step)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).fill(DS.surfaceSunken))
                                .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
                        } else {
                            Text(step)
                                .font(.callout)
                                .foregroundStyle(DS.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Text("Check Now in Settings, Components when you are done. \(AppConfig.appName) runs its checks again.")
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Button("Copy Steps") { center.copySteps(steps) }
            Button("Done") { center.manual = nil }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
        }
    }

    /// Terminal commands read as code, sentences as text.
    static func isCommand(_ step: String) -> Bool {
        let first = step.split(separator: " ").first.map(String.init) ?? ""
        let commands: Set<String> = ["brew", "curl", "sudo", "chmod", "tar", "npm", "uv", "pipx", "lms", "pkgutil", "container", "claude"]
        return commands.contains(first) || first.hasPrefix("/") || step.contains(" | ")
    }
}

// MARK: - Dashboard tag

/// Small "Update available" tag for the Dashboard platform card. Shows only while Apple
/// container has a safe update. A click opens Settings, Components.
struct ContainerUpdateTag: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let row = ComponentsCenter.shared.containerUpdate {
            Button {
                SettingsRouter.pendingTab = "components"
                openSettings()
                NotificationCenter.default.post(name: .deckOpenSettingsTab, object: "components")
            } label: {
                Pill("Update available", tint: DS.accent)
            }
            .buttonStyle(.plain)
            .help("Apple container \(row.target ?? "") is ready. Open Settings, Components.")
        }
    }
}

/// Next to the platform status on the Dashboard after a container upgrade: the release
/// recommends a newer kernel than the one installed. Opens Setup, where the kernel check has
/// "Use the recommended kernel". Containers keep working on the old kernel meanwhile.
struct KernelUpdateTag: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let check = state.report.check(.kernel), check.fix == .useRecommendedKernel {
            Button {
                state.showSetup = true
            } label: {
                Pill("Kernel update", tint: DS.accent)
            }
            .buttonStyle(.plain)
            .help(check.state.message + " Open Setup to install it.")
        }
    }
}
