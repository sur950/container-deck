import SwiftUI
import AppKit
import DeckCore

/// Header, actions and tabs for one compose project.
struct ComposeDetailView: View {
    @Environment(AppState.self) private var state
    /// AppKit menus keep the old colors after a Light or Dark switch. They rebuild with `.id(colorScheme)`.
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var store: ComposeStore

    @State private var downOnFailure = false
    @AppStorage("composeKeepOrphans") private var keepOrphans = false
    @AppStorage("composeKeepNetworks") private var keepNetworks = false
    /// Empty means each service's pull_policy.
    @AppStorage("composePullPolicy") private var pullPolicyRaw = ""
    @State private var showProblemsBeforeUp = false
    @State private var pendingUpOptions = ComposeRunner.UpOptions()
    @State private var confirmDown = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DS.pad)
                .padding(.top, DS.pad)
                .padding(.bottom, 12)

            if let error = store.loadError {
                ComposeBanner(icon: .error, tint: DS.danger,
                              text: store.loadErrorLine.map { line in
                                  if let other = store.yamlErrorFile {
                                      return "\(other.lastPathComponent) is not valid YAML. The problem is on line \(line)."
                                  }
                                  return "The file is not valid YAML. The problem is on line \(line)."
                              } ?? error)
                    .padding(.horizontal, DS.pad)
                    .padding(.bottom, 10)
            } else if let error = store.planError {
                ComposeBanner(icon: .error, tint: DS.danger, text: error)
                    .padding(.horizontal, DS.pad)
                    .padding(.bottom, 10)
            } else if store.pluginStatus == .removedByUpgrade {
                ComposeBanner(
                    icon: .warning, tint: DS.warning,
                    text: "A container update removed the container compose command.",
                    actionTitle: store.pluginWorking ? "Working" : "Reinstall"
                ) {
                    if let client = state.client { store.installPlugin(client: client, state: state) }
                }
                .padding(.horizontal, DS.pad)
                .padding(.bottom, 10)
            } else if let project = store.project, !project.problems.isEmpty, store.tab != .problems {
                ComposeBanner(
                    icon: project.hasBlockingProblems ? .error : .warning,
                    tint: project.hasBlockingProblems ? DS.danger : DS.warning,
                    text: problemSummary(project),
                    actionTitle: "Review"
                ) {
                    store.tab = .problems
                }
                .padding(.horizontal, DS.pad)
                .padding(.bottom, 10)
            }

            Picker("View", selection: $store.tab) {
                ForEach(visibleTabs) { tab in
                    Text(tabTitle(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.pad)
            .padding(.bottom, 10)

            Divider()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showProblemsBeforeUp) {
            if let project = store.project {
                ComposeProblemsSheet(project: project, sources: store.sourceTexts) {
                    showProblemsBeforeUp = false
                    runUp(pendingUpOptions)
                } onCancel: {
                    showProblemsBeforeUp = false
                }
            }
        }
        .confirmationDialog("Take \(store.projectName ?? "this project") down?", isPresented: $confirmDown) {
            Button("Down") { down(removeVolumes: false) }
            Button("Down and Remove Volumes", role: .destructive) { down(removeVolumes: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(keepNetworks
                 ? "This stops and removes the project containers. Networks stay. Volumes keep your data unless you remove them."
                 : "This stops and removes the project containers and networks. Volumes keep your data unless you remove them.")
        }
        .onAppear { if store.pluginStatus == nil { store.refreshPluginStatus() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            IconBadge(.compose, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(store.projectName ?? store.attemptedFile?.deletingLastPathComponent().lastPathComponent ?? "Compose")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    statusPill
                    if let summary = store.mergedFilesSummary, let project = store.project {
                        Pill(summary, tint: DS.textSecondary)
                            .help("Merged in this order:\n" + project.files.map(\.path).joined(separator: "\n"))
                    }
                }
                if let file = store.project?.file ?? store.currentStack?.file ?? store.attemptedFile {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } label: {
                        HStack(spacing: 4) {
                            DeckIcon(.folder, size: 11, color: DS.textSecondary)
                            Text(file.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                } else if store.currentStack?.origin == .docker {
                    Text("Started by another compose tool. Found by its Docker Compose labels. Open its compose file to run Up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Started outside \(AppConfig.appName). Open its compose file to run Up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            actions
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if let stack = store.currentStack {
            let tint = stack.runningCount == stack.services.count ? DS.running : (stack.runningCount == 0 ? DS.stopped : DS.warning)
            Pill("\(stack.runningCount) of \(stack.services.count) running", tint: tint)
            if stack.origin == .docker {
                Pill("Compose labels", tint: DS.stopped)
                    .help("Started by another compose tool. Up recreates its services with \(AppConfig.appName) labels.")
            }
            let changed = store.reupChanges.values.filter { $0 == .changed || $0 == .new }.count
            if changed > 0 {
                Pill(changed == 1 ? "1 to update" : "\(changed) to update", tint: DS.warning)
                    .help("Up recreates only the services whose settings changed: \(ComposeReup.summary(store.reupChanges)).")
            }
        } else if store.project != nil {
            Pill("Not started", tint: DS.stopped)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let title = store.busyTitle {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(title)…").foregroundStyle(.secondary)
                Button("Cancel") { store.cancel() }
            }
        } else {
            HStack(spacing: 8) {
                Button {
                    requestUp(upOptions())
                } label: {
                    DeckLabel("Up", icon: .play)
                }
                .deckPrimary()
                .disabled(!canUp)
                .help(upHelp)
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button {
                    if let client = state.client { store.restart(client: client, state: state) }
                } label: {
                    DeckLabel("Restart", icon: .restart)
                }
                .disabled(store.currentStack == nil)

                Button {
                    confirmDown = true
                } label: {
                    DeckLabel("Down", icon: .stop)
                }
                .disabled(store.currentStack == nil)

                Menu {
                    Toggle("Take Down if a Step Fails", isOn: $downOnFailure)
                    Toggle("Keep Orphans", isOn: $keepOrphans)
                        .help("Up removes containers whose service is no longer in the file. Turn this on to keep them.")
                    Toggle("Keep Networks on Down", isOn: $keepNetworks)
                    Picker("Pull Images", selection: $pullPolicyRaw) {
                        Text("As the File Says").tag("")
                        Text("When Missing").tag(ComposePullPolicy.missing.rawValue)
                        Text("Always").tag(ComposePullPolicy.always.rawValue)
                        Text("Never").tag(ComposePullPolicy.never.rawValue)
                    }
                    Divider()
                    Button("Dry Run") {
                        runUp(upOptions(dryRun: true))
                    }
                    .disabled(!canUp)
                    Button("Recreate All and Up") {
                        requestUp(upOptions(forceRecreate: true))
                    }
                    .disabled(!canUp)
                    Button("Build Images and Up") {
                        requestUp(upOptions(alwaysBuild: true))
                    }
                    .disabled(!canUp)
                    Button("Pull Images") {
                        if let client = state.client { store.pull(client: client, state: state) }
                    }
                    .disabled(store.plan == nil)
                    Divider()
                    Button("Start All") {
                        if let client = state.client { store.start(client: client, state: state) }
                    }
                    .disabled(store.currentStack == nil)
                    Button("Stop All") {
                        if let client = state.client { store.stop(client: client, state: state) }
                    }
                    .disabled(store.currentStack == nil)
                    Divider()
                    Button("Reload File") { store.reload() }
                        .disabled(store.project == nil)
                    if let status = store.pluginStatus, let title = status.menuTitle {
                        Divider()
                        Button(title) {
                            guard let client = state.client else { return }
                            if status == .installed {
                                store.removePlugin(client: client, state: state)
                            } else {
                                store.installPlugin(client: client, state: state)
                            }
                        }
                        .disabled(store.pluginWorking || state.client == nil)
                    }
                } label: {
                    DeckIcon(.more, size: 14)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .id(colorScheme)
            }
        }
    }

    private func upOptions(forceRecreate: Bool = false, alwaysBuild: Bool = false, dryRun: Bool = false) -> ComposeRunner.UpOptions {
        ComposeRunner.UpOptions(
            forceRecreate: forceRecreate, alwaysBuild: alwaysBuild, downOnFailure: downOnFailure,
            dryRun: dryRun, removeOrphans: !keepOrphans, pull: ComposePullPolicy(rawValue: pullPolicyRaw)
        )
    }

    private var canUp: Bool {
        guard let project = store.project, store.plan != nil, state.client != nil else { return false }
        return !project.hasBlockingProblems
    }

    private var upHelp: String {
        if store.project == nil { return "Open the compose file to run Up" }
        if store.project?.hasBlockingProblems == true { return "Fix the problems first" }
        if store.currentStack != nil {
            return "Recreate only what changed: \(ComposeReup.summary(store.reupChanges))"
        }
        return "Create and start every service"
    }

    private func requestUp(_ options: ComposeRunner.UpOptions) {
        guard canUp, let project = store.project else { return }
        // Show what will not work before the very first run.
        if !project.problems.isEmpty && store.currentStack == nil {
            pendingUpOptions = options
            showProblemsBeforeUp = true
            return
        }
        runUp(options)
    }

    private func runUp(_ options: ComposeRunner.UpOptions) {
        guard let client = state.client else { return }
        store.up(client: client, state: state, options: options)
    }

    private func down(removeVolumes: Bool) {
        guard let client = state.client else { return }
        store.down(client: client, state: state, removeVolumes: removeVolumes, keepNetworks: keepNetworks)
    }

    private func problemSummary(_ project: ComposeProject) -> String {
        let count = project.problems.count
        if project.hasBlockingProblems {
            return count == 1 ? "1 problem must be fixed before Up." : "\(count) problems. Some must be fixed before Up."
        }
        let place = project.allFiles.count > 1 ? "these files" : "this file"
        return count == 1 ? "1 thing in \(place) will not work here." : "\(count) things in \(place) will not work here."
    }

    // MARK: Tabs

    private var visibleTabs: [ComposeTab] {
        if store.project == nil {
            return [.services, .logs, .activity]
        }
        return ComposeTab.allCases
    }

    private func tabTitle(_ tab: ComposeTab) -> String {
        if tab == .problems, let count = store.project?.problems.count, count > 0 {
            return "Problems (\(count))"
        }
        return tab.title
    }

    @ViewBuilder
    private var tabContent: some View {
        switch store.tab {
        case .services:
            if store.project == nil, let line = store.loadErrorLine, let file = store.yamlErrorFile ?? store.attemptedFile {
                ComposeYAMLErrorPanel(file: file, line: line, message: store.loadError ?? "",
                                      source: store.yamlErrorFile == nil ? store.sourceText : store.yamlErrorText) {
                    store.reload()
                }
            } else {
                ComposeServicesPanel(store: store)
            }
        case .problems:
            ComposeProblemsPanel(problems: store.project?.problems ?? [], file: store.project?.file, source: store.sourceText,
                                 sources: store.sourceTexts, showFileNames: (store.project?.allFiles.count ?? 1) > 1)
        case .commands:
            ComposeCommandsPanel(store: store)
        case .logs:
            ComposeLogsPanel(store: store)
        case .activity:
            ComposeActivityPanel(store: store)
        }
    }
}

// MARK: - Banner

struct ComposeBanner: View {
    var icon: DeckIconName
    var tint: Color
    var text: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(icon: DeckIconName, tint: Color, text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.tint = tint
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            DeckIcon(icon, size: 14, color: tint)
            // At most three lines. Unbounded text here sets the window's minimum height
            // from its narrowest layout and pushes the whole window off screen.
            Text(text)
                .font(.callout)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.smallRadius))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius).stroke(tint.opacity(0.25)))
    }
}

// MARK: - Problems before the first run

private struct ComposeProblemsSheet: View {
    let project: ComposeProject
    var sources: [String: String] = [:]
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        SheetScaffold(
            "Before the first run",
            subtitle: "Some parts of \(project.file.lastPathComponent) will not work here. The rest runs fine.",
            icon: .warning,
            width: 600
        ) {
            ComposeProblemsList(problems: project.problems, file: project.file, source: sources[project.file.path],
                                sources: sources, showFileNames: project.allFiles.count > 1)
        } footer: {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Up Anyway", action: onContinue)
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
        }
        .frame(minHeight: 320, idealHeight: 480, maxHeight: 620)
    }
}
