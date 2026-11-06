import SwiftUI
import DeckCore

/// Pull an image with a live progress log.
struct ImagesPullSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private let autoStart: Bool
    @State private var reference: String
    @State private var platform: String
    @State private var lines: [String] = []
    @State private var phase: Phase = .idle
    @State private var pullTask: Task<Void, Never>?
    @State private var progress: PullProgress?

    enum Phase: Equatable {
        case idle, running, done, failed(String)
    }

    init(reference: String = "", platform: String? = nil, autoStart: Bool = false) {
        _reference = State(initialValue: reference)
        _platform = State(initialValue: platform ?? "")
        self.autoStart = autoStart
    }

    private var trimmedReference: String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Match this Mac" pulls only the host platform. Without `--platform`
    /// the tool fetches and unpacks every platform in the index.
    private var resolvedPlatform: String? {
        switch platform {
        case "": return ImagePlatform.host
        case Self.allPlatforms: return nil
        default: return platform
        }
    }

    static let allPlatforms = "all"

    private var hintArguments: [String] {
        let ref = trimmedReference.isEmpty ? "<image>" : trimmedReference
        return state.client?.pullArguments(ref, platform: resolvedPlatform) ?? ["image", "pull", ref]
    }

    var body: some View {
        SheetScaffold("Pull Image", subtitle: "Download an image from a registry.", icon: .pull, width: 580, scrolls: false) {
            DeckFormGroup {
                DeckFormRow("Image") {
                    TextField("Image", text: $reference, prompt: Text("nginx:latest"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(start)
                }
                DeckFormRow("Platform") {
                    Picker("Platform", selection: $platform) {
                        Text("Match this Mac").tag("")
                        Text("linux/arm64").tag("linux/arm64")
                        Text("linux/amd64").tag("linux/amd64")
                        Text("All platforms").tag(Self.allPlatforms)
                    }
                    .labelsHidden()
                    .fixedSize()
                    if platform == "linux/amd64" {
                        ResourceWarningText("amd64 images run with Rosetta on Apple silicon.")
                    }
                }
            }
            .disabled(phase == .running)

            ResourceCommandHint(hintArguments)

            ResourceLogView(lines: lines, placeholder: "Pull progress shows here.")
                .frame(height: 200)

            statusRow
                .frame(minHeight: 34, alignment: .center)
        } footer: {
            if phase == .running {
                Button("Stop") { pullTask?.cancel() }
            } else {
                Button(phase == .done ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if phase != .done {
                Button(action: start) {
                    DeckLabel("Pull", icon: .pull)
                }
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedReference.isEmpty || phase == .running || state.client == nil)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if autoStart && phase == .idle { start() }
        }
        .onDisappear { pullTask?.cancel() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch phase {
        case .idle:
            Text("Ready to pull.")
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                Text("Pulling \(trimmedReference)")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                PullProgressBar(progress: progress)
            }
        case .done:
            HStack(spacing: 6) {
                DeckIcon(.success, size: 14, color: DS.running)
                Text("Pulled \(trimmedReference)").font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            ResourceErrorText(message)
        }
    }

    private func start() {
        guard let client = state.client, phase != .running else { return }
        let ref = trimmedReference
        guard !ref.isEmpty else { return }
        let chosenPlatform = resolvedPlatform
        lines = []
        progress = nil
        phase = .running
        pullTask = Task {
            do {
                for try await line in client.pullImage(ref, platform: chosenPlatform) {
                    appendLine(line)
                }
                if Task.isCancelled {
                    appendLine("Stopped.")
                    phase = .idle
                    return
                }
                phase = .done
                state.showToast("Pulled \(ref)", style: .success)
                Notifier.taskFinished(title: "Pulled \(ref)", body: "The image is ready to run.", link: .image(ref))
                state.resourcesChanged()
            } catch {
                if Task.isCancelled {
                    phase = .idle
                } else {
                    phase = .failed(CLIFailure.message(in: lines) ?? error.localizedDescription)
                }
            }
        }
    }

    private func appendLine(_ line: String) {
        if let parsed = PullProgress.parse(line) { progress = parsed }
        ResourceLog.append(line, to: &lines)
    }
}

/// Give an image another name.
struct ImagesTagSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let source: String
    @State private var target: String
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(source: String) {
        self.source = source
        let summary = ImageSummary(reference: source)
        _target = State(initialValue: summary.shortName + ":")
    }

    private var trimmedTarget: String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedTarget.isEmpty && !trimmedTarget.hasSuffix(":") && !trimmedTarget.contains(" ")
    }

    var body: some View {
        SheetScaffold("Tag Image", subtitle: "Give the image another name. It keeps its current name too.", icon: .tag, width: 520, scrolls: false) {
            DeckFormGroup {
                DeckFormRow("Image") {
                    Text(source)
                        .font(.callout.monospaced())
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(source)
                }
                DeckFormRow("New name", note: "Use name:tag, like my-app:v1.") {
                    TextField("New name", text: $target, prompt: Text("my-app:v1"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(save)
                }
            }
            ResourceCommandHint(["image", "tag", source, trimmedTarget.isEmpty ? "<new name>" : trimmedTarget])
            if let errorMessage {
                ResourceErrorText(errorMessage)
            }
        } footer: {
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Tag", action: save)
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isWorking)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        guard let client = state.client, isValid, !isWorking else { return }
        let newName = trimmedTarget
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await client.tagImage(source, as: newName)
                state.showToast("Tagged as \(newName)", style: .success)
                state.resourcesChanged()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
