import SwiftUI
import DeckCore

/// Free Up Space: pick what to remove, see what it frees, run it in one go.
struct FreeUpSpaceSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let usage: DiskUsage?

    @State private var picked: Set<FreeSpaceItem>
    @State private var progress: [FreeSpaceItem: StepState] = [:]
    @State private var running = false
    @State private var finished = false
    @State private var freedText: String?
    /// AI models picked for removal. Starts with the unused ones once the list is read.
    @State private var pickedModels: Set<InstalledModel.ID> = []
    @State private var modelsPrefilled = false
    @State private var modelProgress: [InstalledModel.ID: StepState] = [:]

    private var library: ModelLibraryStore { ModelLibraryStore.shared }

    enum StepState: Equatable {
        case waiting, working, done, failed(String)
    }

    init(usage: DiskUsage?) {
        self.usage = usage
        _picked = State(initialValue: FreeSpacePlan.defaultSelection(usage))
    }

    var body: some View {
        SheetScaffold("Free Up Space", subtitle: subtitle, icon: .prune, width: 560) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Containers").font(.callout.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(FreeSpaceItem.allCases.enumerated()), id: \.element) { index, item in
                        if index > 0 { Divider() }
                        row(item)
                    }
                }
                .padding(.horizontal, 12)
                .deckCard(radius: DS.smallRadius)
            }

            FreeUpModelsSection(picked: $pickedModels, progress: modelProgress, locked: running || finished)
        } footer: {
            // The total sits in the footer, so it stays in view while the lists scroll.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(finished ? "Freed" : "Frees about")
                    .foregroundStyle(DS.textSecondary)
                Text(finished ? (freedText ?? "0 KB") : DashboardFormat.bytes(estimate))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            .controlSize(.regular)
            Spacer(minLength: 12)
            if finished {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .deckPrimary()
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button {
                    Task { await run() }
                } label: {
                    if running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Cleaning Up")
                        }
                    } else {
                        Text("Free Up Space")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
                .disabled((picked.isEmpty && pickedModels.isEmpty) || running || (!picked.isEmpty && state.client == nil))
            }
        }
        .frame(maxHeight: 720)
        .task {
            await library.loadInstalled()
            prefillModels()
        }
        #if DEBUG
        .onDeckDebugCommand { name, value in
            // Automation only: free-space-models:none unpicks every model, free-space-models:all picks every unused one.
            guard name == "free-space-models" else { return }
            pickedModels = value == "none" ? [] : library.cleanupSuggestions
        }
        #endif
    }

    /// Bytes the picked containers, images and models free together.
    private var estimate: UInt64 {
        FreeSpacePlan.estimate(usage, picked: picked) + ModelInventory.size(of: pickedModels, in: library.installed)
    }

    /// Unused models start picked, once.
    private func prefillModels() {
        guard !modelsPrefilled, library.installedLoaded else { return }
        modelsPrefilled = true
        pickedModels = library.cleanupSuggestions
    }

    private var subtitle: String {
        guard let usage else { return "Remove what nothing uses." }
        let models = library.totals.total
        let used = usage.totalBytes + models
        let suggested = ModelInventory.size(of: library.cleanupSuggestions, in: library.installed)
        return "\(DashboardFormat.bytes(used)) in use. \(DashboardFormat.bytes(usage.reclaimableBytes + suggested)) can be freed."
    }

    private func row(_ item: FreeSpaceItem) -> some View {
        let isOn = Binding(
            get: { picked.contains(item) },
            set: { on in
                if on { picked.insert(item) } else { picked.remove(item) }
            }
        )
        return HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(running || finished)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium))
                Text(item.note)
                    .font(.caption)
                    .foregroundStyle(item.isRisky ? DS.warning : DS.textSecondary)
            }
            Spacer(minLength: 8)
            trailing(item)
                .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !running && !finished else { return }
            isOn.wrappedValue.toggle()
        }
    }

    @ViewBuilder
    private func trailing(_ item: FreeSpaceItem) -> some View {
        switch progress[item] {
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            HStack(spacing: 4) {
                DeckIcon(.success, size: 12, color: DS.running)
                Text("Done").font(.caption).foregroundStyle(DS.running)
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
            VStack(alignment: .trailing, spacing: 1) {
                if let bytes = item.reclaimable(usage) {
                    Text(DashboardFormat.bytes(bytes)).font(.callout).monospacedDigit()
                } else {
                    Text("-").font(.callout).foregroundStyle(DS.textTertiary)
                }
                if let count = item.unusedCount(usage) {
                    Text(count == 0 ? "None unused" : "\(count) unused")
                        .font(.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    private func run() async {
        running = true
        let steps = FreeSpacePlan.order(picked)
        for step in steps { progress[step] = .waiting }
        let plans = library.plans(for: pickedModels)
        for plan in plans { modelProgress[plan.id] = .waiting }
        let client = state.client
        for step in steps {
            guard let client else { break }
            progress[step] = .working
            do {
                switch step {
                case .containers:
                    // Same rules as the Containers screen: keeps Apple's builder and helper containers.
                    await ContainerOps.prune(state: state)
                case .images:
                    try await client.pruneImages(all: true)
                case .volumes:
                    try await client.pruneVolumes()
                case .networks:
                    try await client.pruneNetworks()
                }
                progress[step] = .done
            } catch {
                progress[step] = .failed(error.localizedDescription)
                state.showError(error)
            }
        }
        // Models go through the same delete code as the Model Library. Loaded ones were never picked.
        var modelBytes: UInt64 = 0
        for plan in plans {
            modelProgress[plan.id] = .working
            if let bytes = await library.delete(plan, notify: false) {
                modelBytes += bytes
                modelProgress[plan.id] = .done
            } else {
                modelProgress[plan.id] = .failed("Could not delete \(plan.model.name).")
            }
        }
        if !plans.isEmpty { await library.afterDelete() }
        let after = steps.isEmpty ? nil : try? await client?.diskUsage()
        let freed = FreeSpacePlan.freed(before: usage, after: after) + modelBytes
        freedText = DashboardFormat.bytes(freed)
        running = false
        finished = true
        state.resourcesChanged()
        state.showToast(freed > 0 ? "Freed \(DashboardFormat.bytes(freed))" : "Cleaned up", style: .success)
    }
}
