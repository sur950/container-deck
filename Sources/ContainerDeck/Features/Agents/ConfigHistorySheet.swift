import SwiftUI
import AppKit
import DeckCore

/// Config changes written from this screen, newest first, with undo.
struct ConfigHistorySheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let store: AgentsStore
    @State private var pendingForce: ConfigChangeRecord?

    var body: some View {
        SheetScaffold("Config changes", subtitle: "Every change keeps a backup of the file as it was.", icon: .clock, width: 620) {
            if store.history.isEmpty {
                EmptyState(icon: .clock, title: "No changes yet",
                           message: "When you connect a server to an agent, the change shows up here so you can undo it.")
                    .frame(height: 300)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.history.prefix(50).enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        row(record)
                    }
                }
                .deckCard()
            }
        } footer: {
            if let folder = store.history.first?.backupPath.map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }) {
                Button("Show Backups") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
        }
        .frame(height: 520)
        .onDeckDebugCommand { name, value in
            if name == "agents-history", value == "undo-first", let first = store.history.first(where: { !$0.undone }) {
                undo(first, force: false)
            }
        }
        .confirmationDialog("The file changed since this edit", isPresented: Binding(get: { pendingForce != nil }, set: { if !$0 { pendingForce = nil } }),
                            titleVisibility: .visible, presenting: pendingForce) { record in
            Button("Restore Backup Anyway", role: .destructive) { undo(record, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("\(abbreviatedPath(record.path)) was edited after this change. Restoring the backup drops those newer edits.")
        }
    }

    private func row(_ record: ConfigChangeRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.summary).fontWeight(.medium)
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened))  \(abbreviatedPath(record.path))")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if record.undone {
                Pill("Undone", tint: DS.stopped)
            } else {
                Button("Undo") {
                    if store.isUnchanged(record) { undo(record, force: false) } else { pendingForce = record }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func undo(_ record: ConfigChangeRecord, force: Bool) {
        Task {
            do {
                try await store.undo(record, force: force)
                state.showToast("Undone: \(record.summary)", style: .success)
            } catch {
                state.showError(error)
            }
        }
    }
}
