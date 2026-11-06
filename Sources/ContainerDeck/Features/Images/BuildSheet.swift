import SwiftUI
import AppKit
import DeckCore

/// Build an image from a Dockerfile. Presented by RootView from AppState.buildRequest,
/// and by the Builds screen. Every build runs through the shared build store, so it also
/// shows on the Builds screen and keeps going when the sheet is hidden.
struct BuildSheet: View {
    let request: BuildRequest
    /// Builds screen: start the build, close the sheet and hand back its id.
    var startsInBackground = false
    var onStarted: ((UUID) -> Void)?

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var contextDir: String
    @State private var dockerfile = ""
    @State private var tagsText = ""
    @State private var buildArgs: [ResourcePair] = []
    @State private var platform = "linux/arm64"
    @State private var target = ""
    @State private var noCache = false

    @State private var phase: BuildPhase = .editing
    @State private var lines: [String] = []
    @State private var buildID: UUID?
    @State private var builtTags: [String] = []
    private var store: BuildsStore { BuildsStore.shared }

    /// `container build` refuses Dockerfiles over 16 KB (apple/container#735).
    static let dockerfileSizeLimit: UInt64 = 16 * 1024

    enum BuildPhase: Equatable {
        case editing, building, succeeded, failed(String), cancelled
    }

    init(request: BuildRequest, prefill: BuildSpec? = nil, startsInBackground: Bool = false, onStarted: ((UUID) -> Void)? = nil) {
        self.request = request
        self.startsInBackground = startsInBackground
        self.onStarted = onStarted
        _contextDir = State(initialValue: prefill?.contextDir ?? request.contextDir ?? "")
        if let prefill {
            _dockerfile = State(initialValue: prefill.dockerfile ?? "")
            _tagsText = State(initialValue: prefill.tags.joined(separator: ", "))
            _buildArgs = State(initialValue: prefill.buildArgs.map { ResourcePair(key: $0.key, value: $0.value) })
            _platform = State(initialValue: prefill.platform)
            _target = State(initialValue: prefill.target ?? "")
            _noCache = State(initialValue: prefill.noCache)
        }
    }

    var body: some View {
        SheetScaffold("Build Image", subtitle: subtitle, icon: .build, width: 640, scrolls: phase == .editing) {
            if phase == .editing {
                form
            } else {
                progressView
            }
        } footer: {
            footer
        }
        .frame(height: 640)
        .interactiveDismissDisabled(phase == .building)
        .onAppear {
            store.attach(state)
            prefill()
        }
        .onChange(of: store.logVersion) { _, _ in syncBuild() }
    }

    // MARK: - Header and footer

    private var subtitle: String {
        switch phase {
        case .editing: return "Build an image from a Dockerfile."
        case .building: return "Building \(builtTags.first ?? "image")"
        case .succeeded: return "Built \(builtTags.joined(separator: ", "))"
        case .failed: return "The build failed."
        case .cancelled: return "The build was stopped."
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch phase {
            case .editing:
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: startBuild) {
                    DeckLabel("Build", icon: .build)
                }
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!canBuild)
            case .building:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building").foregroundStyle(DS.textSecondary)
                }
                Spacer()
                Button("Hide") { dismiss() }
                    .help("The build keeps going. Find it in Builds.")
                Button("Stop Build") {
                    if let buildID { store.cancel(buildID) }
                }
                .keyboardShortcut(.cancelAction)
            case .succeeded:
                Button("Show in Images", action: showInImages)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: runBuiltImage) {
                    DeckLabel("Run", icon: .play)
                }
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
            case .failed, .cancelled:
                Button("Edit Settings") { phase = .editing }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Build Again", action: startBuild)
                    .deckPrimary()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canBuild)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Form

    @ViewBuilder
    private var form: some View {
        DeckFormGroup("Source") {
            DeckFormRow("Folder") {
                pathPicker(contextDir, placeholder: "Choose a folder", action: chooseContext)
            }
            DeckFormRow("Dockerfile") {
                pathPicker(dockerfile.isEmpty ? "" : dockerfileDisplay, placeholder: "Dockerfile in the folder", action: chooseDockerfile)
            }
            ForEach(warnings, id: \.self) { warning in
                DeckFormRow("") {
                    ResourceWarningText(warning)
                }
            }
        }

        DeckFormGroup("Image") {
            DeckFormRow("Tags", note: "Separate more than one tag with a comma.") {
                TextField("Tags", text: $tagsText, prompt: Text("my-app:latest"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            DeckFormRow("Platform", note: platform == "linux/amd64" ? "amd64 builds and runs with Rosetta." : nil) {
                Picker("Platform", selection: $platform) {
                    Text("arm64 (Apple silicon)").tag("linux/arm64")
                    Text("amd64 (Intel)").tag("linux/amd64")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }

        DeckFormGroup("Options") {
            DeckFormRow("Target stage") {
                TextField("Target stage", text: $target, prompt: Text("Optional"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            DeckFormRow("Cache") {
                Toggle("Do not use the build cache", isOn: $noCache)
                    .toggleStyle(.checkbox)
            }
            DeckFormRow("Build args") {
                ResourcePairEditor(rows: $buildArgs, keyPrompt: "NAME", valuePrompt: "value", addTitle: "Add Build Arg")
            }
        }

        ResourceCommandHint(hintArguments)
    }

    private func pathPicker(_ path: String, placeholder: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                DeckIcon(.folder, size: 13, color: path.isEmpty ? DS.textTertiary : DS.accent)
                Text(path.isEmpty ? placeholder : path)
                    .foregroundStyle(path.isEmpty ? DS.textTertiary : DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
            Button("Choose…", action: action)
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .failed(let message) = phase {
                ResourceErrorText(message)
            }
            if phase == .succeeded {
                HStack(spacing: 10) {
                    IconBadge(.success, tint: DS.running, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image built").font(.headline)
                        Text(builtTags.joined(separator: ", "))
                            .font(.callout.monospaced())
                            .foregroundStyle(DS.textSecondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .deckCard(radius: DS.smallRadius + 2)
            }
            ResourceLogView(lines: lines, placeholder: "Starting the builder…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Values

    private var tags: [String] {
        tagsText
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var trimmedContext: String {
        contextDir.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var defaultDockerfilePath: String {
        (trimmedContext as NSString).appendingPathComponent("Dockerfile")
    }

    /// nil lets the tool pick Dockerfile or Containerfile in the folder.
    private var dockerfileArgument: String? {
        let path = dockerfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private var dockerfileDisplay: String {
        guard !trimmedContext.isEmpty else { return dockerfile }
        let prefix = trimmedContext.hasSuffix("/") ? trimmedContext : trimmedContext + "/"
        return dockerfile.hasPrefix(prefix) ? String(dockerfile.dropFirst(prefix.count)) : dockerfile
    }

    private var canBuild: Bool {
        state.client != nil && !trimmedContext.isEmpty && !tags.isEmpty && phase != .building
    }

    private var buildOptions: BuildOptions {
        let args = buildArgs
            .map { EnvVar(key: $0.key.trimmingCharacters(in: .whitespaces), value: $0.value) }
            .filter { !$0.key.isEmpty }
        let stage = target.trimmingCharacters(in: .whitespaces)
        return BuildOptions(
            contextDir: trimmedContext,
            dockerfile: dockerfileArgument,
            tags: tags,
            buildArgs: args,
            platform: platform,
            target: stage.isEmpty ? nil : stage,
            noCache: noCache
        )
    }

    private var hintArguments: [String] {
        state.client?.buildArguments(buildOptions) ?? ["build"]
    }

    private var warnings: [String] {
        var result: [String] = []
        let context = trimmedContext
        if !context.isEmpty {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: context, isDirectory: &isDir) || !isDir.boolValue {
                result.append("This folder does not exist.")
            }
        }
        let file = dockerfileArgument ?? (context.isEmpty ? "" : defaultDockerfilePath)
        if !file.isEmpty {
            if let size = Self.fileSize(file) {
                if size > Self.dockerfileSizeLimit {
                    result.append("This Dockerfile is \(Format.bytes(size)). The build tool only takes files up to 16 KB.")
                }
            } else if dockerfileArgument != nil {
                result.append("The Dockerfile was not found.")
            } else if !FileManager.default.fileExists(atPath: (context as NSString).appendingPathComponent("Containerfile")) {
                result.append("No Dockerfile found in this folder. Choose one.")
            }
        }
        return result
    }

    static func fileSize(_ path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    // MARK: - Actions

    private func prefill() {
        if tagsText.isEmpty && !trimmedContext.isEmpty {
            tagsText = Self.suggestedTag(for: trimmedContext)
        }
    }

    static func suggestedTag(for folder: String) -> String {
        let name = (folder as NSString).lastPathComponent.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return (cleaned.isEmpty ? "my-image" : cleaned) + ":latest"
    }

    private func chooseContext() {
        let panel = NSOpenPanel()
        panel.title = "Choose the build folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !trimmedContext.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: trimmedContext)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let oldSuggestion = trimmedContext.isEmpty ? "" : Self.suggestedTag(for: trimmedContext)
        contextDir = url.path
        // A Dockerfile from the old folder no longer fits.
        if !dockerfile.isEmpty && !dockerfile.hasPrefix(url.path + "/") {
            dockerfile = ""
        }
        if tagsText.isEmpty || tagsText == oldSuggestion {
            tagsText = Self.suggestedTag(for: url.path)
        }
    }

    private func chooseDockerfile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Dockerfile"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !trimmedContext.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: trimmedContext)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dockerfile = url.path
        if trimmedContext.isEmpty {
            contextDir = url.deletingLastPathComponent().path
            if tagsText.isEmpty { tagsText = Self.suggestedTag(for: contextDir) }
        }
    }

    private func startBuild() {
        guard let client = state.client, canBuild else { return }
        let options = buildOptions
        store.attach(state)
        if startsInBackground {
            let id = store.start(options, client: client, origin: .buildsScreen)
            onStarted?(id)
            dismiss()
            return
        }
        builtTags = options.tags
        lines = []
        phase = .building
        buildID = store.start(options, client: client, origin: .imageSheet)
    }

    /// Follows the build in the shared store: log lines and the end result.
    private func syncBuild() {
        guard phase == .building, let id = buildID, let record = store.record(id) else { return }
        lines = store.log(id)
        switch record.status {
        case .running:
            break
        case .succeeded:
            phase = .succeeded
            state.showToast("Built \(record.title)", style: .success)
            Notifier.taskFinished(title: "Built \(record.title)", body: "The build finished.", whenInBackground: true)
        case .failed:
            phase = .failed(record.message ?? "The build failed.")
        case .cancelled, .interrupted:
            lines.append("Build stopped.")
            phase = .cancelled
        }
    }

    private func runBuiltImage() {
        guard let reference = builtTags.first else { return }
        let appState = state
        let runPlatform = platformForRun
        appState.buildRequest = nil
        dismiss()
        ResourceUsage.afterSheetCloses {
            appState.runRequest = RunRequest(options: RunOptions(image: reference, platform: runPlatform))
        }
    }

    /// Run amd64 builds as amd64. nil means native.
    private var platformForRun: String? {
        platform == "linux/amd64" ? platform : nil
    }

    private func showInImages() {
        guard let reference = builtTags.first else { return }
        state.focusedImageRef = reference
        state.selection = .images
        state.buildRequest = nil
        dismiss()
    }
}
