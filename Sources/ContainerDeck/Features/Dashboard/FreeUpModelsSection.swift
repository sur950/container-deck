import SwiftUI
import DeckCore

/// The AI models part of Free Up Space: every downloaded model with its size and last use.
/// Unused ones start picked. Loaded and built in models can't be picked.
struct FreeUpModelsSection: View {
    @Binding var picked: Set<InstalledModel.ID>
    var progress: [InstalledModel.ID: FreeUpSpaceSheet.StepState]
    var locked: Bool

    private var library: ModelLibraryStore { ModelLibraryStore.shared }

    /// Suggestions first, then largest first.
    private var models: [InstalledModel] {
        let suggested = library.cleanupSuggestions
        return library.installed.sorted { a, b in
            let sa = suggested.contains(a.id), sb = suggested.contains(b.id)
            if sa != sb { return sa }
            return a.sizeBytes > b.sizeBytes
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("AI models").font(.callout.weight(.semibold))
                Text(headerNote)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                Spacer(minLength: 0)
                if !models.isEmpty && !locked {
                    Button(picked.isEmpty ? "Pick Unused" : "Clear") {
                        picked = picked.isEmpty ? library.cleanupSuggestions : []
                    }
                    .buttonStyle(.borderless)
                    .deckLink()
                    .font(.caption)
                }
            }
            if !library.installedLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading models").font(.caption).foregroundStyle(DS.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .deckCard(radius: DS.smallRadius)
            } else if models.isEmpty {
                Text("No models from Ollama, LM Studio or MLX on this Mac.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .deckCard(radius: DS.smallRadius)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                            if index > 0 { Divider() }
                            row(model)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: min(CGFloat(models.count) * 50, 220))
                .deckCard(radius: DS.smallRadius)
            }
        }
    }

    private var headerNote: String {
        let suggested = library.cleanupSuggestions
        guard !suggested.isEmpty else { return "None unused for \(ModelInventory.unusedDays) days" }
        let bytes = ModelInventory.size(of: suggested, in: library.installed)
        return "\(suggested.count) unused for \(ModelInventory.unusedDays) days, \(DashboardFormat.bytes(bytes))"
    }

    /// "used 3 days ago", "in use now", "not used in the app yet, downloaded 2 months ago".
    private func usedText(_ model: InstalledModel) -> String {
        if model.isLoaded { return "in use now" }
        if let used = model.lastUsed { return "used \(Format.relative(used))" }
        if let downloaded = model.downloaded { return "not used yet, downloaded \(Format.relative(downloaded))" }
        return "not used yet"
    }

    /// Why a model can't be picked, or nil.
    private func lockReason(_ model: InstalledModel) -> String? {
        if model.isLoaded { return model.source == .mlx ? "Serving" : "Loaded" }
        if model.isBuiltIn { return "Built in" }
        if model.filesMissing { return "Files missing" }
        if model.source == .ollama && !AIModelsStore.shared.ollamaRunning { return "Start Ollama" }
        return nil
    }

    private func row(_ model: InstalledModel) -> some View {
        let reason = lockReason(model)
        let isOn = Binding(
            get: { picked.contains(model.id) },
            set: { on in
                if on { picked.insert(model.id) } else { picked.remove(model.id) }
            }
        )
        return HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(locked || reason != nil)
            DeckIcon(model.source.deckIcon, size: 14, color: DS.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("\(model.source.displayName), \(usedText(model))")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let reason, progress[model.id] == nil {
                Pill(reason, tint: model.isLoaded ? DS.running : DS.stopped)
            }
            trailing(model)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !locked, reason == nil else { return }
            isOn.wrappedValue.toggle()
        }
    }

    @ViewBuilder
    private func trailing(_ model: InstalledModel) -> some View {
        switch progress[model.id] {
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            HStack(spacing: 4) {
                DeckIcon(.success, size: 12, color: DS.running)
                Text("Deleted").font(.caption).foregroundStyle(DS.running)
            }
        case .failed(let message):
            HStack(spacing: 4) {
                DeckIcon(.error, size: 12, color: DS.danger)
                Text("Failed").font(.caption).foregroundStyle(DS.danger)
            }
            .help(message)
        case .waiting:
            Text("Waiting").font(.caption).foregroundStyle(DS.textTertiary)
        case nil:
            Text(DashboardFormat.bytes(model.sizeBytes)).font(.callout).monospacedDigit()
        }
    }
}
