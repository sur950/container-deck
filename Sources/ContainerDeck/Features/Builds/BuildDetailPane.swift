import SwiftUI
import AppKit
import DeckCore

/// One build: actions, live log and the settings it ran with.
struct BuildDetailPane: View {
    @Environment(AppState.self) private var state

    let record: BuildRecord
    let onRebuild: (BuildRecord) -> Void
    let onEdit: () -> Void

    @State private var tab: Tab = .log
    @State private var lines: [String] = []

    private var store: BuildsStore { BuildsStore.shared }

    enum Tab: String, CaseIterable, Identifiable {
        case log, details
        var id: String { rawValue }
        var title: String { self == .log ? "Log" : "Details" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DS.pad)
                .padding(.top, DS.pad)
                .padding(.bottom, 12)
            SegmentedFilter(selection: $tab, options: Tab.allCases, label: { $0.title })
                .padding(.horizontal, DS.pad)
                .padding(.bottom, 12)
            Divider()
            Group {
                switch tab {
                case .log: logView
                case .details: details
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .onAppear { lines = store.log(record.id) }
        .onChange(of: store.logVersion) { _, _ in
            // Only running builds get new lines.
            if record.status == .running || lines.count != record.logLineCount {
                lines = store.log(record.id)
            }
        }
        .onChange(of: record.status) { _, _ in lines = store.log(record.id) }
        .onReceive(NotificationCenter.default.publisher(for: .buildsDetailTab)) { note in
            if let name = note.object as? String, let value = Tab(rawValue: name) { tab = value }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(.build, tint: BuildText.tint(record.status), size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(record.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Pill(record.spec.shortPlatform, tint: DS.textSecondary)
                    }
                    HStack(spacing: 6) {
                        BuildStatusLabel(record: record)
                            .foregroundStyle(BuildText.tint(record.status))
                        Text("·").foregroundStyle(DS.textTertiary)
                        BuildDurationText(record: record)
                        Text("·").foregroundStyle(DS.textTertiary)
                        Text(BuildText.started(record.startedAt))
                    }
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                }
                Spacer(minLength: 0)
            }
            if let message = record.message, record.status == .failed || record.status == .interrupted {
                ResourceErrorText(message)
                    .lineLimit(4)
            } else if record.status == .running {
                runningStep
            }
            actions
        }
    }

    @ViewBuilder
    private var runningStep: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let index = record.stepIndex, let count = record.stepCount, count > 0 {
                ProgressView(value: Double(max(0, index - 1)), total: Double(count))
                    .tint(DS.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(DS.accent)
            }
            Text(stepCaption)
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var stepCaption: String {
        guard let step = record.lastStep else { return "Starting the builder" }
        if let text = record.stepText { return "\(text): \(step)" }
        return step
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch record.status {
            case .running:
                Button { store.cancel(record.id) } label: { DeckLabel("Stop Build", icon: .stop) }
            case .succeeded:
                Button { BuildActions.run(record, state: state) } label: { DeckLabel("Run", icon: .play) }
                    .deckPrimary()
                if let tag = record.spec.tags.first {
                    Button { BuildActions.openImage(tag, state: state) } label: { DeckLabel("Show Image", icon: .images) }
                }
                Button { onRebuild(record) } label: { DeckLabel("Rebuild", icon: .restart) }
            case .failed, .cancelled, .interrupted:
                Button { onRebuild(record) } label: { DeckLabel("Rebuild", icon: .restart) }
                    .deckPrimary()
                Button(action: onEdit) { DeckLabel("Edit…", icon: .edit) }
            }
            Spacer(minLength: 0)
            Menu {
                if record.status == .succeeded {
                    Button(action: onEdit) { DeckLabel("Edit and Rebuild…", icon: .edit) }
                    if let tag = record.spec.tags.first, let url = DeepLink.image(tag).url {
                        Button { ResourceUsage.copyToPasteboard(url.absoluteString) } label: { DeckLabel("Copy Image Link", icon: .link) }
                    }
                }
                Button { ResourceUsage.revealInFinder(record.spec.contextDir) } label: { DeckLabel("Show Folder", icon: .folder) }
                Button { ResourceUsage.copyToPasteboard(commandLine) } label: { DeckLabel("Copy Command", icon: .copy) }
                if record.status.isFinished {
                    Divider()
                    Button(role: .destructive) { store.remove([record.id]) } label: { DeckLabel("Remove from List", icon: .trash) }
                }
            } label: {
                DeckIcon(.more, size: 14)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .controlSize(.regular)
    }

    private var commandLine: String {
        guard let client = state.client else { return "" }
        return client.commandLine(client.buildArguments(record.spec.options))
    }

    // MARK: - Log

    private var logView: some View {
        ResourceLogView(lines: lines, placeholder: record.status == .running ? "Starting the builder…" : "No output was saved for this build.")
            .padding(DS.pad)
    }

    // MARK: - Details

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                Card("Image", icon: .images) {
                    VStack(alignment: .leading, spacing: 8) {
                        KeyValueRow("Tags", value: record.spec.tags.joined(separator: "\n"), monospaced: true, copyable: true)
                        KeyValueRow("Platform", value: record.spec.platform)
                        KeyValueRow("Target", value: record.spec.target ?? "Last stage")
                        KeyValueRow("Cache", value: record.spec.noCache ? "Not used" : "Used")
                    }
                }
                Card("Source", icon: .folder) {
                    VStack(alignment: .leading, spacing: 8) {
                        KeyValueRow("Folder", value: record.spec.contextDir, monospaced: true, copyable: true)
                        KeyValueRow("Dockerfile", value: record.spec.dockerfileDisplay, monospaced: true)
                        KeyValueRow("Build args", value: buildArgsText, monospaced: !record.spec.buildArgs.isEmpty)
                        KeyValueRow("Started from", value: BuildText.origin(record))
                    }
                }
                Card("Timing", icon: .clock) {
                    VStack(alignment: .leading, spacing: 8) {
                        KeyValueRow("Started", value: record.startedAt.formatted(date: .abbreviated, time: .standard))
                        KeyValueRow("Finished", value: record.finishedAt?.formatted(date: .abbreviated, time: .standard) ?? "Still building")
                        KeyValueRow("Took") { BuildDurationText(record: record) }
                    }
                }
                if record.status == .succeeded {
                    usedBy
                }
                ResourceCommandHint(state.client?.buildArguments(record.spec.options) ?? ["build"])
            }
            .padding(DS.pad)
        }
    }

    private var buildArgsText: String {
        guard !record.spec.buildArgs.isEmpty else { return "None" }
        return record.spec.buildArgs.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private var usedBy: some View {
        let users = BuildActions.users(of: record, in: BackgroundServices.shared.containers)
        return Card("Used By", icon: .containers) {
            if users.isEmpty {
                Text("No container uses this image yet.")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(users) { container in
                        Button {
                            state.openContainer(container.id)
                        } label: {
                            HStack(spacing: 8) {
                                StatusPill(container.state)
                                Text(container.name.isEmpty ? container.id : container.name)
                                    .foregroundStyle(DS.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                DeckIcon(.chevronRight, size: 11, color: DS.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(container.name)")
                    }
                }
            }
        }
    }
}
