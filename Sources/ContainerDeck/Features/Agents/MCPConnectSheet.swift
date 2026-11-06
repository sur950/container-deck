import SwiftUI
import AppKit
import DeckCore

/// Preview of a config change (add or remove a server), then write with backup, then undo.
struct MCPConnectSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let store: AgentsStore
    let target: ConnectTarget

    @State private var scopeChoice = "user"
    @State private var plan: ConfigChangePlan?
    @State private var planError: String?
    @State private var record: ConfigChangeRecord?
    @State private var working = false

    private var agent: AgentKind {
        switch target.mode {
        case .connect(_, let agent): return agent
        case .disconnect(let found): return found.agent
        }
    }

    private var isConnect: Bool {
        if case .connect = target.mode { return true }
        return false
    }

    private var scope: AgentConfigScope {
        if case .disconnect(let found) = target.mode { return found.scope }
        if scopeChoice == "user" { return .user }
        if scopeChoice.hasPrefix("local:") { return .local(String(scopeChoice.dropFirst(6))) }
        return .project(scopeChoice)
    }

    var body: some View {
        SheetScaffold(title, subtitle: subtitle, icon: isConnect ? .link : .trash, width: 680, scrolls: false) {
            if isConnect, agent.supportsProjectScope, !store.projects.isEmpty, record == nil {
                DeckFormRow("Where") {
                    Picker("Where", selection: $scopeChoice) {
                        Text("All projects (user config)").tag("user")
                        Divider()
                        ForEach(store.projects, id: \.self) { folder in
                            Text("Project " + abbreviatedPath(folder)).tag(folder)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    .popUpAppearanceRefresh()
                }
            }
            if let record {
                done(record)
            } else if let planError {
                EmptyState(icon: .error, title: "Cannot change this file", message: planError)
            } else if let plan {
                preview(plan)
            } else {
                LoadingView("Preparing the change", style: .list)
            }
        } footer: {
            if record != nil {
                Button("Undo") { undo() }
                    .disabled(working)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .deckPrimary()
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isConnect ? "Write Change" : "Remove Entry") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .deckPrimary()
                    .disabled(plan == nil || working || plan?.diff.isEmpty == true)
            }
        }
        .frame(height: 560)
        .task(id: scopeChoice) { await makePlan() }
        .onDeckDebugCommand { name, value in
            if name == "agents-connect", value == "apply" { apply() }
            if name == "agents-connect", value == "undo" { undo() }
        }
    }

    private var title: String {
        switch target.mode {
        case .connect(let entry, let agent): return "Connect \(entry.name) to \(agent.title)"
        case .disconnect(let found): return "Remove \(found.name) from \(found.agent.title)"
        }
    }

    private var subtitle: String {
        if let plan { return abbreviatedPath(plan.path) }
        return "Review the change before it is written."
    }

    private func preview(_ plan: ConfigChangePlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Pill(plan.original == nil ? "New file" : (plan.action == .replace ? "Update" : (plan.action == .add ? "Add" : "Remove")),
                     tint: plan.action == .remove ? DS.danger : DS.accent)
                if plan.bridged {
                    Pill("via mcp-remote", tint: DS.warning)
                }
                Text(summary(plan)).font(.callout).foregroundStyle(DS.textSecondary)
                Spacer(minLength: 0)
            }
            if plan.diff.isEmpty {
                EmptyState(icon: .success, title: "Already set", message: "\(agent.title) already has this exact entry.")
            } else {
                DiffView(lines: plan.diff)
            }
            Text("A copy of the file is saved first. Only this entry changes, every other setting stays as it is.")
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func summary(_ plan: ConfigChangePlan) -> String {
        let added = plan.diff.filter { $0.kind == .added }.count
        let removed = plan.diff.filter { $0.kind == .removed }.count
        return "\(added) \(added == 1 ? "line" : "lines") added, \(removed) removed"
    }

    private func done(_ record: ConfigChangeRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(record.summary).font(.headline)
            } icon: {
                DeckIcon(.success, size: 18, color: DS.running)
            }
            Text(agent.reloadHint).foregroundStyle(DS.textSecondary)
            if let backup = record.backupPath {
                KeyValueRow("Backup", value: abbreviatedPath(backup), monospaced: true, copyable: true)
            }
            Text("Undo puts the file back exactly as it was. You can also undo later from Changes.")
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Work

    private func makePlan() async {
        plan = nil
        planError = nil
        do {
            switch target.mode {
            case .connect(let entry, let agent):
                plan = try await store.planConnect(entry, agent: agent, scope: scope)
            case .disconnect(let found):
                plan = try await store.planDisconnect(found)
            }
        } catch {
            planError = error.localizedDescription
        }
    }

    private func apply() {
        guard let plan, !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                record = try await store.apply(plan)
                state.showToast(record?.summary ?? "Saved", style: .success)
            } catch {
                state.showError(error)
                await makePlan()
            }
        }
    }

    private func undo() {
        guard let record else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await store.undo(record)
                state.showToast("Undone", style: .success)
                dismiss()
            } catch {
                state.showError(error)
            }
        }
    }
}

/// Line diff with + and - marks, red and green tints that work in Light and Dark.
struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 0) {
                            Text(line.number.map(String.init) ?? "")
                                .frame(width: 44, alignment: .trailing)
                                .foregroundStyle(DS.textTertiary)
                            Text(mark(line.kind))
                                .frame(width: 22)
                                .foregroundStyle(markColor(line.kind))
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.kind == .gap ? DS.textTertiary : DS.textPrimary)
                                .fixedSize()
                            Spacer(minLength: 12)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 1.5)
                        .background(background(line.kind))
                    }
                }
                .padding(.vertical, 6)
                // Rows fill the visible width so the change tints run edge to edge.
                .frame(minWidth: geo.size.width, alignment: .leading)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.topLeading)
        }
        .background(DS.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: DS.smallRadius))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius).stroke(DS.border))
    }

    private func mark(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        default: return ""
        }
    }

    private func markColor(_ kind: DiffLine.Kind) -> Color {
        kind == .added ? DS.running : (kind == .removed ? DS.danger : DS.textTertiary)
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return DS.running.opacity(0.14)
        case .removed: return DS.danger.opacity(0.14)
        default: return .clear
        }
    }
}
