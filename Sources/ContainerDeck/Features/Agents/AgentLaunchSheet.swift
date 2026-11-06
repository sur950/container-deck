import SwiftUI
import DeckCore

/// Progress of starting a profile in its sandbox: cache volume, sandbox, network guard, terminal.
struct AgentLaunchSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let work: AgentWorkStore
    let launchID: UUID

    private var launch: AgentLaunchState? { work.launch?.id == launchID ? work.launch : nil }

    var body: some View {
        SheetScaffold("Starting \(launch?.profile.name ?? "agent")",
                      subtitle: launch.map { "\($0.profile.tool.title) in the sandbox \($0.sandboxName)" },
                      icon: .sandboxes, width: 540, scrolls: false) {
            if let launch {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(launch.steps, id: \.self) { step in
                        stepRow(step, launch: launch)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .deckCard(radius: DS.smallRadius + 2)
                if let error = launch.error {
                    ResourceErrorText(error)
                } else if launch.finished {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The terminal is open.").font(.headline)
                        Text("The first run installs \(launch.profile.tool.title) into the sandbox. Later runs start at once.")
                            .deckSecondaryText()
                        if let note = launch.note { DeckFormNote(note) }
                    }
                }
                Spacer(minLength: 0)
            }
        } footer: {
            Button("Open Sandboxes") {
                if let name = launch?.sandboxName { SandboxRuntime.shared.selection = name }
                state.selection = .sandboxes
                dismiss()
            }
            .disabled(launch?.finished != true)
            if launch?.error != nil, let profile = launch?.profile {
                Button("Try Again") {
                    Task { await work.launchInSandbox(profile, state: state) }
                }
            }
            Button(launch?.finished == true ? "Done" : "Hide") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
        }
        .frame(height: 400)
    }

    private func stepRow(_ step: AgentSandboxStep, launch: AgentLaunchState) -> some View {
        let done = launch.done.contains(step)
        let current = launch.current == step
        let failed = current && launch.error != nil
        return HStack(spacing: 10) {
            Group {
                if failed {
                    DeckIcon(.error, size: 16, color: DS.danger)
                } else if done {
                    DeckIcon(.success, size: 16, color: DS.running)
                } else if current {
                    ProgressView().controlSize(.small)
                } else {
                    DeckIcon(.waiting, size: 16, color: DS.textTertiary)
                }
            }
            .frame(width: 20)
            Text(step.rawValue)
                .foregroundStyle(done || current ? DS.textPrimary : DS.textTertiary)
            Spacer(minLength: 0)
        }
    }
}
