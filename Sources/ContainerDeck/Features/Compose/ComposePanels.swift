import SwiftUI
import AppKit
import DeckCore

// Tab contents for the Compose screen.

/// Stable colour per service name for logs and activity.
enum ComposeColors {
    private static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green, .brown, .cyan, .mint]

    static func color(for service: String) -> Color {
        let sum = service.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

// MARK: - Services

struct ComposeServicesPanel: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true
    let store: ComposeStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let project = store.project {
                    if !project.allProfiles.isEmpty {
                        profilesCard(project)
                    }
                    if let plan = store.plan {
                        ForEach(rows(for: plan)) { model in
                            ComposeServiceRow(model: model, store: store)
                        }
                        if !plan.skipped.isEmpty {
                            HStack(spacing: 6) {
                                DeckIcon(.info, size: 12, color: DS.textSecondary)
                                Text("Left out by profiles: \(plan.skipped.joined(separator: ", "))")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                        ForEach(orphans(plan)) { model in
                            ComposeServiceRow(model: model, store: store)
                        }
                        resourcesCard(plan)
                    } else {
                        // No plan (for example a dependency loop). Show the file as is.
                        ForEach(project.services) { service in
                            ComposeServiceRow(model: rowModel(service, index: nil, command: nil), store: store)
                        }
                    }
                } else if let stack = store.currentStack {
                    ForEach(stack.services) { status in
                        ComposeServiceRow(model: rowModel(status), store: store)
                    }
                } else {
                    EmptyState(icon: .compose, title: "Nothing here yet", message: "This stack has no containers.")
                }
            }
            .padding(DS.pad)
        }
    }

    private func rows(for plan: ComposePlan) -> [ComposeServiceRowModel] {
        var result: [ComposeServiceRowModel] = []
        let changes = store.reupChanges
        for (offset, servicePlan) in plan.services.enumerated() {
            var command: String?
            if showHints, let client = state.client {
                let args = client.runArguments(servicePlan.options)
                if !args.isEmpty { command = client.commandLine(args) }
            }
            var model = rowModel(servicePlan.service, index: offset + 1, command: command)
            if store.currentStack != nil { model.change = changes[servicePlan.name] }
            result.append(model)
        }
        return result
    }

    /// Containers of this project that the file no longer lists.
    private func orphans(_ plan: ComposePlan) -> [ComposeServiceRowModel] {
        guard let stack = store.currentStack else { return [] }
        let known = Set(plan.project.services.map(\.name))
        return stack.services.filter { !known.contains($0.service) }.map { (status: ComposeServiceStatus) -> ComposeServiceRowModel in
            var model = rowModel(status)
            model.note = "Not in the file anymore. Up removes it unless Keep Orphans is on."
            return model
        }
    }

    private func rowModel(_ service: ComposeService, index: Int?, command: String?) -> ComposeServiceRowModel {
        ComposeServiceRowModel(
            index: index,
            name: service.name,
            image: service.imageDescription,
            status: store.status(for: service.name),
            ports: service.ports.map(\.displayText),
            volumes: service.volumes.map(\.displayText),
            dependsOn: service.dependsOn.map { dependency in
                dependency.condition == .started ? dependency.service : "\(dependency.service) (\(dependency.condition.title))"
            },
            profiles: service.profiles,
            hasHealthcheck: service.healthcheck.map { !$0.isDisabled } ?? false,
            command: command
        )
    }

    private func rowModel(_ status: ComposeServiceStatus) -> ComposeServiceRowModel {
        ComposeServiceRowModel(
            index: nil,
            name: status.service,
            image: status.container.image,
            status: status,
            ports: status.container.ports.map { "\($0.hostPort):\($0.containerPort)" },
            volumes: [],
            dependsOn: [],
            profiles: [],
            hasHealthcheck: false,
            command: nil
        )
    }

    private func profilesCard(_ project: ComposeProject) -> some View {
        Card("Profiles", icon: .filter) {
            Text("Services with a profile only start when it is on.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(project.allProfiles, id: \.self) { profile in
                    Toggle(isOn: Binding(
                        get: { store.activeProfiles.contains(profile) },
                        set: { _ in store.toggleProfile(profile) }
                    )) {
                        Text(profile)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    @ViewBuilder
    private func resourcesCard(_ plan: ComposePlan) -> some View {
        if !plan.networks.isEmpty || !plan.volumes.isEmpty {
            Card("Networks and volumes", icon: .networks) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.networks) { network in
                        HStack(spacing: 8) {
                            DeckIcon(.networks, size: 12, color: DS.textSecondary)
                            Text(network.name).font(.callout.monospaced()).textSelection(.enabled)
                            if network.external { Pill("external", tint: DS.stopped) }
                            if network.isInternal { Pill("internal", tint: DS.stopped) }
                            if let subnet = network.subnet { Pill(subnet, tint: DS.stopped) }
                        }
                    }
                    ForEach(plan.volumes) { volume in
                        HStack(spacing: 8) {
                            DeckIcon(.volumes, size: 12, color: DS.textSecondary)
                            Text(volume.name).font(.callout.monospaced()).textSelection(.enabled)
                            if volume.external { Pill("external", tint: DS.stopped) }
                        }
                    }
                }
            }
        }
    }
}

struct ComposeServiceRowModel: Identifiable {
    var id: String { name }
    var index: Int?
    var name: String
    var image: String
    var status: ComposeServiceStatus?
    var ports: [String]
    var volumes: [String]
    var dependsOn: [String]
    var profiles: [String]
    var hasHealthcheck: Bool
    var command: String?
    var note: String?
    /// What Up would do to it (config hash). nil when nothing runs yet.
    var change: ComposeServiceChange?
}

struct ComposeServiceRow: View {
    @Environment(AppState.self) private var state
    let model: ComposeServiceRowModel
    let store: ComposeStore

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                if let index = model.index {
                    Text("\(index)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(DS.accent)
                        .frame(width: 24, height: 24)
                        .background(DS.iconSoft, in: Circle())
                        .help("Start order")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(model.name).font(.headline)
                        if let status = model.status {
                            StatusPill(status.container.state)
                        } else {
                            Pill("Not created", tint: DS.stopped)
                        }
                        if let change = model.change {
                            Pill(change.title, tint: changeTint(change))
                                .help(change.help)
                        }
                        ForEach(model.profiles, id: \.self) { profile in
                            Pill(profile, tint: DS.stopped)
                        }
                        Spacer(minLength: 8)
                        actions
                    }
                    Text(model.image)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    facts
                    if let note = model.note {
                        HStack(spacing: 6) {
                            DeckIcon(.warning, size: 12, color: DS.warning)
                            Text(note).font(.caption)
                        }
                    }
                    if let command = model.command {
                        CommandHint(command)
                    }
                }
            }
        }
    }

    private func changeTint(_ change: ComposeServiceChange) -> Color {
        switch change {
        case .upToDate: return DS.running
        case .willStart: return DS.stopped
        case .changed, .new: return DS.warning
        }
    }

    @ViewBuilder
    private var facts: some View {
        let hasFacts = model.status?.ipAddress != nil || !model.ports.isEmpty || !model.volumes.isEmpty
            || !model.dependsOn.isEmpty || model.hasHealthcheck
        if hasFacts {
            VStack(alignment: .leading, spacing: 4) {
                if let ip = model.status?.ipAddress {
                    fact(.network, "IP", ip)
                }
                if !model.ports.isEmpty {
                    fact(.port, "Ports", model.ports.joined(separator: ", "))
                }
                if !model.volumes.isEmpty {
                    fact(.volumes, "Volumes", model.volumes.joined(separator: "\n"))
                }
                if !model.dependsOn.isEmpty {
                    fact(.link, "Needs", model.dependsOn.joined(separator: ", "))
                }
                if model.hasHealthcheck {
                    fact(.success, "Health", "Has a healthcheck")
                }
            }
        }
    }

    private func fact(_ icon: DeckIconName, _ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            DeckIcon(icon, size: 12, color: DS.textSecondary)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private var actions: some View {
        let exists = model.status != nil
        let running = model.status?.container.isRunning ?? false
        let disabled = store.isBusy || state.client == nil
        return HStack(spacing: 2) {
            iconButton(.logs, "Logs", enabled: exists && !disabled) { client in
                store.showLogs(client: client, service: model.name)
            }
            if running {
                iconButton(.stop, "Stop", enabled: !disabled) { client in
                    store.stop(client: client, state: state, services: [model.name])
                }
            } else {
                iconButton(.play, "Start", enabled: exists && !disabled) { client in
                    store.start(client: client, state: state, services: [model.name])
                }
            }
            iconButton(.restart, "Restart", enabled: exists && !disabled) { client in
                store.restart(client: client, state: state, services: [model.name])
            }
        }
    }

    private func iconButton(_ icon: DeckIconName, _ title: String, enabled: Bool, action: @escaping (ContainerClient) -> Void) -> some View {
        Button {
            if let client = state.client { action(client) }
        } label: {
            DeckIcon(icon, size: 14, color: enabled ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Problems

struct ComposeProblemsPanel: View {
    let problems: [ComposeProblem]
    var file: URL?
    var source: String?
    var sources: [String: String] = [:]
    var showFileNames = false

    init(problems: [ComposeProblem], file: URL? = nil, source: String? = nil, sources: [String: String] = [:], showFileNames: Bool = false) {
        self.problems = problems
        self.file = file
        self.source = source
        self.sources = sources
        self.showFileNames = showFileNames
    }

    var body: some View {
        if problems.isEmpty {
            EmptyState(icon: .success, title: "No problems", message: "Everything in this file works here.")
        } else {
            ScrollView {
                ComposeProblemsList(problems: problems, file: file, source: source, sources: sources, showFileNames: showFileNames)
                    .padding(DS.pad)
            }
        }
    }
}

struct ComposeProblemsList: View {
    let problems: [ComposeProblem]
    /// The main compose file.
    var file: URL?
    /// Text of the main file.
    var source: String?
    /// Text of every file of the project by path.
    var sources: [String: String] = [:]
    /// Show "file:line" instead of "Line n", for projects made of several files.
    var showFileNames = false

    init(problems: [ComposeProblem], file: URL? = nil, source: String? = nil, sources: [String: String] = [:], showFileNames: Bool = false) {
        self.problems = problems
        self.file = file
        self.source = source
        self.sources = sources
        self.showFileNames = showFileNames
    }

    private func fileOf(_ problem: ComposeProblem) -> URL? { problem.file ?? file }

    private func text(of url: URL?) -> String? {
        guard let url else { return nil }
        if let text = sources[url.path] { return text }
        return url.path == file?.path ? source : nil
    }

    private func label(_ problem: ComposeProblem) -> String {
        if showFileNames, let url = fileOf(problem) {
            return problem.line > 0 ? "\(url.lastPathComponent):\(problem.line)" : url.lastPathComponent
        }
        return problem.line > 0 ? "Line \(problem.line)" : "File"
    }

    /// Main file first, then the others, then by line.
    private func order(_ a: ComposeProblem, _ b: ComposeProblem) -> Bool {
        func fileRank(_ problem: ComposeProblem) -> Int {
            guard let url = fileOf(problem), url.path != file?.path else { return 0 }
            return 1
        }
        let left = (fileRank(a), fileOf(a)?.path ?? "", a.line == 0 ? Int.max : a.line)
        let right = (fileRank(b), fileOf(b)?.path ?? "", b.line == 0 ? Int.max : b.line)
        return left < right
    }

    private static let order: [ComposeProblem.Kind] = [.invalid, .notPossible, .notBuilt]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.order, id: \.self) { kind in
                let items = problems.filter { $0.kind == kind }.sorted(by: order)
                if !items.isEmpty {
                    Card("\(kind.title) (\(items.count))", icon: icon(kind)) {
                        Text(explanation(kind))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(items) { problem in
                                row(problem, tint: tint(kind))
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ problem: ComposeProblem, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if problem.line > 0, let file = fileOf(problem) {
                    Button {
                        ComposeEditor.open(file, line: problem.line)
                    } label: {
                        Text(label(problem))
                            .underline()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(file.path) at line \(problem.line)")
                } else {
                    Text(label(problem))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
            .frame(width: showFileNames ? 170 : 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(problem.key)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if problem.line > 0, let source = text(of: fileOf(problem)) {
                    ComposeExcerptView(excerpt: ComposeSourceExcerpt.make(source, line: problem.line, context: 0), tint: tint)
                }
            }
            .textSelection(.enabled)
        }
    }

    private func icon(_ kind: ComposeProblem.Kind) -> DeckIconName {
        switch kind {
        case .invalid: return .error
        case .notPossible: return .warning
        case .notBuilt: return .info
        }
    }

    private func tint(_ kind: ComposeProblem.Kind) -> Color {
        switch kind {
        case .invalid: return DS.danger
        case .notPossible: return DS.warning
        case .notBuilt: return DS.textSecondary
        }
    }

    private func explanation(_ kind: ComposeProblem.Kind) -> String {
        switch kind {
        case .invalid: return "Fix these in the file, then reload it. Up stays off until then."
        case .notPossible: return "Each container runs in its own small VM, so these keys cannot work here. They are skipped."
        case .notBuilt: return "\(AppConfig.appName) does not handle these keys yet. They are skipped."
        }
    }
}

/// Lines of the compose file with line numbers. The problem line is marked.
struct ComposeExcerptView: View {
    let excerpt: ComposeSourceExcerpt
    var tint: Color = DS.danger

    var body: some View {
        if !excerpt.lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(excerpt.lines) { line in
                    HStack(spacing: 10) {
                        Text("\(line.number)")
                            .foregroundStyle(line.isTarget ? tint : DS.textTertiary)
                            .frame(width: 30, alignment: .trailing)
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.isTarget ? DS.textPrimary : DS.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(.caption.monospaced())
                    .padding(.vertical, 2)
                    .padding(.trailing, 8)
                    .background(line.isTarget ? tint.opacity(0.10) : Color.clear)
                    .overlay(alignment: .leading) {
                        if line.isTarget { Rectangle().fill(tint).frame(width: 2) }
                    }
                }
            }
            .padding(.vertical, 4)
            .background(DS.surfaceSunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

/// The file could not be read as YAML. Shows where.
struct ComposeYAMLErrorPanel: View {
    let file: URL
    let line: Int
    let message: String
    let source: String?
    let reload: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card("The file is not valid YAML", icon: .error) {
                    Text(cleanMessage)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let source {
                        ComposeExcerptView(excerpt: ComposeSourceExcerpt.make(source, line: line, context: 2))
                    }
                    HStack(spacing: 8) {
                        Button {
                            ComposeEditor.open(file, line: line)
                        } label: {
                            DeckLabel("Open at Line \(line)", icon: .edit)
                        }
                        Button(action: reload) {
                            DeckLabel("Reload", icon: .refresh)
                        }
                        Spacer(minLength: 0)
                        Text(file.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }
            .padding(DS.pad)
        }
    }

    private var cleanMessage: String {
        message.replacingOccurrences(of: "The compose file is not valid YAML. ", with: "")
    }
}

/// Opens a compose file, at a line when the editor supports it.
enum ComposeEditor {
    static func open(_ file: URL, line: Int) {
        // VS Code and Cursor take file:line links. Others open the file.
        let editors = [("com.microsoft.VSCode", "vscode"), ("com.todesktop.230313mzl4w4u92", "cursor")]
        for (bundleID, scheme) in editors where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            let path = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
            if let url = URL(string: "\(scheme)://file\(path):\(line)") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        NSWorkspace.shared.open(file)
    }
}

// MARK: - Commands

struct ComposeCommandsPanel: View {
    @Environment(AppState.self) private var state
    @AppStorage("composeKeepOrphans") private var keepOrphans = false
    @AppStorage("composePullPolicy") private var pullPolicyRaw = ""
    let store: ComposeStore

    var body: some View {
        if let plan = store.plan, let client = state.client {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("Up runs these commands in order. It also waits for healthchecks and writes service names to /etc/hosts in each container. A dry run checks them against this Mac and changes nothing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button {
                            store.up(client: client, state: state, options: ComposeRunner.UpOptions(
                                dryRun: true, removeOrphans: !keepOrphans, pull: ComposePullPolicy(rawValue: pullPolicyRaw)
                            ))
                        } label: {
                            DeckLabel("Dry Run", icon: .checklist)
                        }
                        .disabled(store.isBusy || store.project?.hasBlockingProblems == true)
                        .help("Show what Up would do on this Mac. Nothing is changed.")
                    }
                    ForEach(plan.commands(runArguments: { client.runArguments($0) })) { command in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            CommandHint(client.commandLine(command.arguments))
                        }
                    }
                }
                .padding(DS.pad)
            }
        } else {
            EmptyState(icon: .terminal, title: "No commands yet", message: "Open a compose file with no blocking problems to see the commands Up runs.")
        }
    }
}

// MARK: - Logs

struct ComposeLogsPanel: View {
    @Environment(AppState.self) private var state
    /// AppKit menus keep the old colors after a Light or Dark switch. They rebuild with `.id(colorScheme)`.
    @Environment(\.colorScheme) private var colorScheme
    let store: ComposeStore
    @State private var filter = ""

    private var services: [String] {
        if let plan = store.plan { return plan.services.map(\.name) }
        return store.currentStack?.services.map(\.service) ?? []
    }

    private var visibleLines: [ComposeLogLine] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.logLines }
        return store.logLines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Service", selection: Binding(
                    get: { store.logService ?? "" },
                    set: { value in
                        if let client = state.client {
                            store.startLogs(client: client, service: value.isEmpty ? nil : value)
                        }
                    }
                )) {
                    Text("All services").tag("")
                    ForEach(services, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .id(colorScheme)

                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                Spacer()

                if store.isFollowingLogs {
                    Button {
                        store.stopLogs()
                    } label: {
                        DeckLabel("Pause", icon: .stop)
                    }
                } else {
                    Button {
                        if let client = state.client { store.startLogs(client: client, service: store.logService) }
                    } label: {
                        DeckLabel("Follow", icon: .play)
                    }
                    .disabled(store.currentStack == nil)
                }
                Button {
                    store.logLines = []
                } label: {
                    DeckLabel("Clear", icon: .trash)
                }
            }
            .padding(.horizontal, DS.pad)
            .padding(.vertical, 8)

            Divider()

            if let error = store.logError {
                ComposeBanner(icon: .error, tint: DS.danger, text: error)
                    .padding(DS.pad)
            }

            if store.logLines.isEmpty {
                EmptyState(
                    icon: .logs,
                    title: store.currentStack == nil ? "Not running" : "No logs yet",
                    message: store.currentStack == nil ? "Run Up to see logs here." : "New lines show up as they come in."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(visibleLines) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(line.service)
                                        .foregroundStyle(ComposeColors.color(for: line.service))
                                        .lineLimit(1)
                                        .frame(width: 120, alignment: .leading)
                                    Text(line.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.caption.monospaced())
                                .id(line.id)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(12)
                    }
                    .background(DS.surfaceRaised)
                    .onChange(of: store.logLines.count) {
                        if let last = visibleLines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear {
            if !store.isFollowingLogs && store.logLines.isEmpty && store.currentStack != nil, let client = state.client {
                store.startLogs(client: client, service: store.logService)
            }
        }
    }
}

// MARK: - Activity

struct ComposeActivityPanel: View {
    let store: ComposeStore

    /// Progress output comes as many lines in a row. Show only the newest line of each run.
    private var visibleEvents: [ComposeEvent] {
        let events = store.events
        return events.enumerated().compactMap { index, event in
            if event.kind == .output, index + 1 < events.count,
               events[index + 1].kind == .output, events[index + 1].service == event.service {
                return nil
            }
            return event
        }
    }

    var body: some View {
        if store.events.isEmpty {
            EmptyState(icon: .clock, title: "No activity yet", message: "Press Up to start the stack. Each step shows up here.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleEvents) { event in
                            ComposeEventRow(event: event)
                                .id(event.id)
                        }
                        if store.isBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Working…").foregroundStyle(.secondary)
                            }
                            .padding(.top, 6)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(DS.pad)
                }
                .onChange(of: store.events.count) {
                    if let last = store.events.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct ComposeEventRow: View {
    let event: ComposeEvent

    var body: some View {
        if event.kind == .output {
            Text(event.message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.leading, 26)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DeckIcon(icon, size: 13, color: tint)
                    .frame(width: 18)
                if let service = event.service {
                    Text(service)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(ComposeColors.color(for: service))
                }
                Text(event.message)
                    .font(.callout)
                    .foregroundStyle(event.kind == .failure ? DS.danger : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(event.date.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var icon: DeckIconName {
        switch event.kind {
        case .step: return .play
        case .info: return .info
        case .output: return .logs
        case .success: return .success
        case .warning: return .warning
        case .failure: return .error
        }
    }

    private var tint: Color {
        switch event.kind {
        case .step: return DS.accent
        case .info: return DS.textSecondary
        case .output: return DS.textSecondary
        case .success: return DS.running
        case .warning: return DS.warning
        case .failure: return DS.danger
        }
    }
}
