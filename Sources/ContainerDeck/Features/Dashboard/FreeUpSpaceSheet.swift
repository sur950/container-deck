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

    enum StepState: Equatable {
        case waiting, working, done, failed(String)
    }

    init(usage: DiskUsage?) {
        self.usage = usage
        _picked = State(initialValue: FreeSpacePlan.defaultSelection(usage))
    }

    var body: some View {
        SheetScaffold("Free Up Space", subtitle: subtitle, icon: .prune, width: 520) {
            VStack(spacing: 0) {
                ForEach(Array(FreeSpaceItem.allCases.enumerated()), id: \.element) { index, item in
                    if index > 0 { Divider() }
                    row(item)
                }
            }
            .padding(.horizontal, 12)
            .deckCard(radius: DS.smallRadius)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(finished ? "Freed" : "Frees about")
                    .foregroundStyle(DS.textSecondary)
                Text(finished ? (freedText ?? "0 KB") : DashboardFormat.bytes(FreeSpacePlan.estimate(usage, picked: picked)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
        } footer: {
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
                .disabled(picked.isEmpty || running || state.client == nil)
            }
        }
    }

    private var subtitle: String {
        guard let usage else { return "Remove what nothing uses." }
        return "\(DashboardFormat.bytes(usage.totalBytes)) in use. \(DashboardFormat.bytes(usage.reclaimableBytes)) can be freed."
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
        guard let client = state.client else { return }
        running = true
        let steps = FreeSpacePlan.order(picked)
        for step in steps { progress[step] = .waiting }
        for step in steps {
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
        let after = try? await client.diskUsage()
        let freed = FreeSpacePlan.freed(before: usage, after: after)
        freedText = DashboardFormat.bytes(freed)
        running = false
        finished = true
        state.resourcesChanged()
        state.showToast(freed > 0 ? "Freed \(DashboardFormat.bytes(freed))" : "Cleaned up", style: .success)
    }
}
