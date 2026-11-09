import SwiftUI
import DeckCore

/// Confirms deleting one model: names what runs or the folder that goes, and the space it frees.
/// A loaded model asks to unload first.
struct ModelDeleteSheet: View {
    let pending: ModelLibraryStore.PendingDelete
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    private var library: ModelLibraryStore { ModelLibraryStore.shared }

    private var model: InstalledModel { pending.model }

    var body: some View {
        SheetScaffold(pending.plan == nil ? "Unload \(model.name) first?" : "Delete \(model.name)?",
                      subtitle: subtitle, icon: pending.plan == nil ? .warning : .trash, width: 480, scrolls: false) {
            VStack(alignment: .leading, spacing: 0) {
                KeyValueRow("Runtime", value: model.source.displayName)
                KeyValueRow("Frees", value: Format.bytes(pending.plan?.bytes ?? model.sizeBytes))
                KeyValueRow("Last used", value: AILibraryView.lastUsedText(model))
            }
            if let plan = pending.plan {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.deletesFiles ? "This folder is deleted" : "This runs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.textSecondary)
                    AICopyField(text: plan.target, help: "Copy")
                    Text(note(plan))
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    DeckIcon(.warning, size: 14, color: DS.warning)
                    Text(model.source == .mlx
                         ? "The MLX server is serving this model. Stop the server, then delete it."
                         : "\(model.source.displayName) has this model in memory. Unload it, then delete it.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            if pending.plan == nil {
                Button {
                    working = true
                    Task {
                        await library.unloadForDelete(model)
                        working = false
                    }
                } label: {
                    if working {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Unloading") }
                    } else {
                        Text(model.source == .mlx ? "Stop Server" : "Unload")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
                .disabled(working)
            } else if let plan = pending.plan {
                Button(role: .destructive) {
                    working = true
                    Task {
                        await library.delete(plan)
                        working = false
                        library.pendingDelete = nil
                    }
                } label: {
                    if working {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Deleting") }
                    } else {
                        Text("Delete")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
                .disabled(working)
            }
        }
    }

    private var subtitle: String {
        if pending.plan == nil { return "It is loaded, so it can't be deleted yet." }
        return "\(Format.bytes(pending.plan?.bytes ?? model.sizeBytes)) is freed. You can download it again."
    }

    private func note(_ plan: ModelRemovalPlan) -> String {
        switch plan.action {
        case .ollama: return "Ollama removes the model. Layers other models share stay."
        case .lmStudioFolder: return "LM Studio has no remove command, so the model's folder is deleted."
        case .lmStudioFile: return "Other models share this folder, so only this file is deleted."
        case .mlx(let local):
            return local.source == .huggingFaceCache
                ? "It is removed from the shared Hugging Face cache, which other apps use too."
                : "It is removed from \(AppConfig.appName)'s model folder."
        }
    }
}
