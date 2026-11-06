import SwiftUI
import DeckCore

/// Small panel for the setup guide: engines found on this Mac and an Import button.
struct EngineImportSummary: View {
    @Environment(AppState.self) private var state

    private var store: ImportStore { ImportStore.shared }

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isScanning && store.lastScan == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for other container engines")
                        .foregroundStyle(.secondary)
                }
            } else if found.isEmpty {
                Text("No other container engines were found on this Mac. You can skip this step.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(found) { engine in
                        HStack(spacing: 8) {
                            DeckIcon(.importEngines, size: 13, color: engine.isRunning ? DS.accent : .secondary)
                            Text(engine.name)
                            Spacer()
                            if engine.isRunning, let count = engine.imageCount {
                                Text(count == 1 ? "1 image" : "\(count) images")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            EngineStatePill(state: engine.state)
                        }
                    }
                }
                .padding(12)
                .background(DS.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.smallRadius))
                .overlay(RoundedRectangle(cornerRadius: DS.smallRadius).stroke(DS.border))
            }

            HStack(spacing: 8) {
                Button {
                    state.selection = .importEngines
                    state.showSetup = false
                } label: {
                    DeckLabel("Open Import", icon: .importEngines)
                }
                .deckPrimary()
                Button("Scan Again") {
                    Task { await store.scan(client: state.client) }
                }
                .disabled(store.isScanning)
                if store.isScanning && store.lastScan != nil {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task {
            if store.lastScan == nil {
                await store.scan(client: state.client)
            }
        }
    }

    private var found: [DetectedEngine] {
        store.engines.filter { $0.state != .notFound }
    }
}
