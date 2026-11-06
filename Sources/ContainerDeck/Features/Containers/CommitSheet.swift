import SwiftUI
import DeckCore

/// Saves a container's file system as a new image (`container commit`).
struct CommitSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let container: ContainerSummary

    @State private var reference: String
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(container: ContainerSummary) {
        self.container = container
        _reference = State(initialValue: Self.suggestedName(for: container))
    }

    /// `container commit` came with 1.6.0. Unknown versions get the benefit of the doubt.
    static func isSupported(_ state: AppState) -> Bool {
        guard let version = state.report.cliVersion else { return true }
        return !(version < ImageReferenceCheck.commitMinimumVersion)
    }

    /// "web" becomes "web-snapshot:latest".
    static func suggestedName(for container: ContainerSummary) -> String {
        let base = (container.name.isEmpty ? container.id : container.name).lowercased()
        let cleaned = base.map { char -> Character in
            char.isLetter || char.isNumber || char == "-" || char == "_" || char == "." ? char : "-"
        }
        return String(cleaned) + "-snapshot:latest"
    }

    private var trimmed: String { reference.trimmingCharacters(in: .whitespaces) }
    private var problem: String? { ImageReferenceCheck.problem(trimmed) }

    var body: some View {
        SheetScaffold("Commit to Image", subtitle: "Save this container's files as a new image.", icon: .layers, width: 520, scrolls: false) {
            DeckFormGroup {
                DeckFormRow("Container") {
                    Text(container.name)
                        .font(.callout.monospaced())
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                DeckFormRow("Image name", note: "Use name:tag, like my-app:v1.") {
                    TextField("Image name", text: $reference, prompt: Text("my-app:v1"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(commit)
                }
            }
            ResourceCommandHint(["commit", container.id, trimmed.isEmpty ? "<image name>" : trimmed])
            if let message = errorMessage ?? (trimmed.isEmpty ? nil : problem) {
                ResourceErrorText(message)
            } else if container.isRunning {
                ResourceWarningText("The container keeps running. Files being written right now may be missing.")
            }
        } footer: {
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(action: commit) {
                DeckLabel("Commit", icon: .layers)
            }
            .deckPrimary()
            .keyboardShortcut(.defaultAction)
            .disabled(problem != nil || isWorking || state.client == nil)
        }
    }

    private func commit() {
        guard let client = state.client, problem == nil, !isWorking else { return }
        let name = trimmed
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await client.commitContainer(container.id, reference: name)
                state.showToast("Saved \(container.name) as \(name)", style: .success)
                state.resourcesChanged()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
