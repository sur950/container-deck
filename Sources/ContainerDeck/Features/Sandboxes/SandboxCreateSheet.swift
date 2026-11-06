import SwiftUI
import AppKit
import DeckCore

/// Create a sandbox in one form: template, workspace, limits, network and model.
struct SandboxCreateSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    /// Extra model endpoints (for example from Local AI). Shown next to the presets.
    var modelSources: [any SandboxModelSource] = []
    var onCreated: (String) -> Void = { _ in }

    @State private var templateID = SandboxConfig.templates.first?.id ?? "alpine"
    @State private var customImage = ""
    @State private var name = ""
    @State private var suggestedName = ""
    @State private var workspace = ""
    @State private var workspaceReadOnly = true
    @State private var cpus = SandboxConfig.defaultCPUs
    @State private var memoryMB = SandboxConfig.defaultMemoryMB
    @State private var egress: SandboxEgress = .isolated
    @State private var allowText = ""
    @State private var useModel = false
    @State private var modelKind: SandboxModelKind = .ollama
    @State private var modelURL = "http://127.0.0.1:11434"
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var foundModels: [String] = []
    @State private var probing = false
    @State private var probeMessage: String?
    @State private var step: SandboxCreateStep?
    @State private var errorMessage: String?

    private static let memoryChoices = [512, 1024, 2048, 4096, 8192, 16384, 32768]
    private static let allowSuggestions: [(String, String)] = [
        ("Python packages", "pypi.org files.pythonhosted.org"),
        ("npm", "registry.npmjs.org"),
        ("GitHub", "github.com *.githubusercontent.com"),
        ("Alpine packages", "dl-cdn.alpinelinux.org"),
        ("Hugging Face", "huggingface.co *.hf.co"),
    ]

    private var hostCPUs: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }
    private var hostMemoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
    private var memoryChoices: [Int] { Self.memoryChoices.filter { $0 <= max(1024, hostMemoryMB / 2) } }

    private var template: SandboxTemplate? { SandboxConfig.template(id: templateID) }
    private var image: String {
        (templateID == SandboxConfig.customTemplateID ? customImage : template?.image ?? "").trimmingCharacters(in: .whitespaces)
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool {
        SandboxRuntime.shared.sandboxes.contains { $0.name == trimmedName }
            || BackgroundServices.shared.containers.contains { $0.name == trimmedName || $0.id == trimmedName }
    }
    private var nameIsValid: Bool { SandboxSpec.isValidName(trimmedName) && !nameTaken }
    private var allowList: [String] { EgressPolicy.parseList(allowText) }
    private var invalidAllow: [String] { EgressPolicy.invalidEntries(allowText) }
    private var modelURLValue: URL? {
        guard let url = URL(string: modelURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil, url.host != nil else { return nil }
        return url
    }
    private var modelRoute: SandboxModelRoute? {
        guard useModel, let url = modelURLValue else { return nil }
        return SandboxModelRoute.route(for: url, egress: egress)
    }

    private var canCreate: Bool {
        nameIsValid && !image.isEmpty && step == nil
            && (egress != .allowList || invalidAllow.isEmpty)
            && (!useModel || (modelURLValue != nil && modelRoute?.isReachable == true))
    }

    private var spec: SandboxSpec {
        var model: SandboxModel?
        if useModel, let url = modelURLValue {
            let modelText = modelName.trimmingCharacters(in: .whitespaces)
            model = SandboxModel(kind: modelKind, url: url, name: modelText.isEmpty ? nil : modelText, hasKey: !apiKey.isEmpty)
        }
        return SandboxSpec(
            name: trimmedName, templateID: templateID, image: image,
            workspace: workspace.isEmpty ? nil : workspace, workspaceReadOnly: workspaceReadOnly,
            cpus: cpus, memoryMB: memoryMB, egress: egress, allowList: allowList, model: model
        )
    }

    var body: some View {
        ScrollViewReader { scroller in
            form
                .onDeckDebugCommand { command, value in
                    if command == "sbx-scroll" { scroller.scrollTo(value, anchor: .top) }
                }
        }
    }

    private var form: some View {
        SheetScaffold("New Sandbox", subtitle: "A container with its own network, ready for an AI agent.", icon: .sandboxes, width: 640) {
            templateGroup
            DeckFormGroup("Sandbox") {
                DeckFormRow("Name") {
                    TextField("Name", text: $name, prompt: Text("agent"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    if !trimmedName.isEmpty && !nameIsValid {
                        ResourceWarningText(nameTaken ? "A container with this name exists." : "Use lowercase letters, numbers, dots and dashes.")
                    }
                }
                DeckFormRow("Workspace", note: workspace.isEmpty ? "Optional. A folder on this Mac, mounted at /workspace." : nil) {
                    HStack(spacing: 8) {
                        Text(workspace.isEmpty ? "None" : (workspace as NSString).abbreviatingWithTildeInPath)
                            .font(workspace.isEmpty ? .body : .body.monospaced())
                            .foregroundStyle(workspace.isEmpty ? DS.textTertiary : DS.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !workspace.isEmpty {
                            Button("Clear") { workspace = "" }
                        }
                        Button("Choose…", action: chooseFolder)
                    }
                    if !workspace.isEmpty {
                        Picker("Access", selection: $workspaceReadOnly) {
                            Text("Read only").tag(true)
                            Text("Read and write").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                DeckFormRow("CPUs") {
                    Stepper(value: $cpus, in: 1...hostCPUs) {
                        Text("\(cpus) of \(hostCPUs)").monospacedDigit()
                    }
                    .fixedSize()
                }
                DeckFormRow("Memory") {
                    Picker("Memory", selection: $memoryMB) {
                        ForEach(memoryChoices, id: \.self) { value in
                            Text(value >= 1024 ? "\(value / 1024) GB" : "\(value) MB").tag(value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .popUpAppearanceRefresh()
                }
            }
            networkGroup.id("network")
            modelGroup.id("model")
            ResourceCommandHint(hintArguments)
            if let errorMessage {
                ResourceErrorText(errorMessage)
            }
        } footer: {
            if let step {
                ProgressView().controlSize(.small)
                Text(step.rawValue).font(.callout).foregroundStyle(DS.textSecondary)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Sandbox", action: create)
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .frame(height: 720)
        .onAppear(perform: suggestName)
        .onChange(of: templateID) { _, _ in suggestName() }
        .onDeckDebugCommand { command, value in
            switch command {
            case "sbx-name": name = value
            case "sbx-egress": egress = SandboxEgress(rawValue: value) ?? egress
            case "sbx-allow": allowText = value
            case "sbx-template": templateID = value
            case "sbx-model": useModel = value == "on"
            case "sbx-create": create()
            default: break
            }
        }
    }

    // MARK: - Groups

    private var templateGroup: some View {
        DeckFormGroup("Template") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                ForEach(SandboxConfig.templates) { item in
                    templateTile(id: item.id, title: item.title, detail: item.image)
                }
                templateTile(id: SandboxConfig.customTemplateID, title: "Custom image", detail: "Your own image", monospaced: false)
            }
            if templateID == SandboxConfig.customTemplateID {
                DeckFormRow("Image") {
                    TextField("Image", text: $customImage, prompt: Text("ghcr.io/owner/agent:latest"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            } else if let template {
                DeckFormNote(template.summary)
            }
        }
    }

    private func templateTile(id: String, title: String, detail: String, monospaced: Bool = true) -> some View {
        let selected = templateID == id
        return Button {
            templateID = id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(DS.textPrimary)
                Text(detail)
                    .font(monospaced ? .caption.monospaced() : .caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.smallRadius).fill(selected ? DS.accentSoft : DS.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: DS.smallRadius).strokeBorder(selected ? DS.accent : DS.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var networkGroup: some View {
        DeckFormGroup("Network") {
            DeckFormRow("Access") {
                Picker("Access", selection: $egress) {
                    ForEach([SandboxEgress.isolated, .allowList, .open]) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                DeckFormNote(egressNote)
            }
            if egress == .allowList {
                DeckFormRow("Allowed hosts") {
                    TextEditor(text: $allowText)
                        .font(.callout.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DS.surfaceSunken))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border))
                    HStack(spacing: 6) {
                        ForEach(Self.allowSuggestions, id: \.0) { item in
                            Button(item.0) { addAllow(item.1) }
                                .controlSize(.small)
                        }
                    }
                    if !invalidAllow.isEmpty {
                        ResourceWarningText("Not a host name: \(invalidAllow.joined(separator: ", "))")
                    } else {
                        DeckFormNote("One per line or comma. *.example.com covers every name below it. Apps must use the HTTP_PROXY settings. Other traffic cannot leave the network.")
                    }
                }
            }
        }
    }

    private var egressNote: String {
        switch egress {
        case .isolated: return "Host only network made for this sandbox. No internet. It can still reach a model on this Mac through the app."
        case .allowList: return "Host only network plus a proxy in the app that lets through only the hosts you list."
        case .open: return "Full internet access, like a normal container."
        }
    }

    private var modelGroup: some View {
        DeckFormGroup("Model") {
            DeckFormRow("Model") {
                Toggle("Connect a model", isOn: $useModel)
                    .toggleStyle(.checkbox)
                if !useModel {
                    DeckFormNote("Sets OPENAI_BASE_URL, OLLAMA_HOST and OPENAI_API_KEY in the sandbox.")
                }
            }
            if useModel {
                DeckFormRow("Server") {
                    HStack(spacing: 6) {
                        ForEach(SandboxModelPreset.local) { preset in
                            Button(preset.title) {
                                modelKind = preset.kind
                                modelURL = preset.url
                                foundModels = []
                                probeMessage = nil
                            }
                            .controlSize(.small)
                        }
                        ForEach(Array(modelSources.enumerated()), id: \.offset) { _, source in
                            Button(source.title) { apply(source) }
                                .controlSize(.small)
                        }
                    }
                }
                DeckFormRow("API") {
                    Picker("Kind", selection: $modelKind) {
                        ForEach(SandboxModelKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                DeckFormRow("Base URL") {
                    TextField("Base URL", text: $modelURL, prompt: Text("http://127.0.0.1:11434"))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .labelsHidden()
                    routeNote
                }
                DeckFormRow("Model name") {
                    HStack(spacing: 8) {
                        if foundModels.isEmpty {
                            TextField("Model name", text: $modelName, prompt: Text("llama3.2"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                        } else {
                            Picker("Model name", selection: $modelName) {
                                ForEach(foundModels, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .popUpAppearanceRefresh()
                        }
                        Button(probing ? "Checking…" : "Find Models", action: probe)
                            .disabled(probing || modelURLValue == nil)
                    }
                    if let probeMessage {
                        DeckFormNote(probeMessage)
                    }
                }
                DeckFormRow("API key", note: "Optional. Kept in your Keychain. Inside the sandbox it lives only in memory, never on disk.") {
                    SecureField("API key", text: $apiKey, prompt: Text("Not needed for local servers"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }
        }
    }

    @ViewBuilder
    private var routeNote: some View {
        switch modelRoute {
        case .relay?:
            DeckFormNote("Reached through a relay the app runs on the sandbox network.")
        case .proxy(let host)?:
            DeckFormNote("Reached through the proxy. \(host) is added to the allow list.")
        case .direct?:
            DeckFormNote("Reached straight over the internet.")
        case .unreachable(let reason)?:
            ResourceWarningText(reason)
        case nil:
            if modelURLValue == nil { ResourceWarningText("Enter a full URL, like http://127.0.0.1:11434.") }
        }
    }

    private var hintArguments: [String] {
        guard let client = state.client else { return [] }
        let preview = spec
        let placeholder = SandboxSpec(name: preview.name.isEmpty ? "<name>" : preview.name, templateID: preview.templateID,
                                      image: preview.image.isEmpty ? "<image>" : preview.image, workspace: preview.workspace,
                                      workspaceReadOnly: preview.workspaceReadOnly, cpus: preview.cpus, memoryMB: preview.memoryMB,
                                      egress: preview.egress, allowList: preview.allowList, model: preview.model)
        return client.sandboxNetworkArguments(placeholder)
    }

    // MARK: - Actions

    private func suggestName() {
        guard trimmedName.isEmpty || name == suggestedName else { return }
        let base = templateID == SandboxConfig.customTemplateID ? "sandbox" : templateID
        var candidate = base
        var index = 1
        let taken = Set(BackgroundServices.shared.containers.map(\.name))
        while taken.contains(candidate) {
            index += 1
            candidate = "\(base)-\(index)"
        }
        name = candidate
        suggestedName = candidate
    }

    private func addAllow(_ hosts: String) {
        let joined = (allowList + EgressPolicy.parseList(hosts))
        allowText = EgressPolicy.parseList(joined.joined(separator: "\n")).joined(separator: "\n")
    }

    private func apply(_ source: any SandboxModelSource) {
        modelKind = source.kind
        modelURL = source.baseURL.absoluteString
        apiKey = source.apiKey ?? ""
        modelName = source.defaultModel ?? ""
        foundModels = []
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the folder the sandbox can see at /workspace."
        if panel.runModal() == .OK, let url = panel.url {
            workspace = url.path
        }
    }

    private func probe() {
        guard let url = modelURLValue else { return }
        probing = true
        probeMessage = nil
        let kind = modelKind
        let key = apiKey
        Task {
            do {
                let models = try await SandboxModelProbe.models(baseURL: url, kind: kind, apiKey: key)
                foundModels = models
                if models.isEmpty {
                    probeMessage = "The server has no models yet."
                } else if !models.contains(modelName) {
                    modelName = models[0]
                }
            } catch {
                foundModels = []
                probeMessage = "Could not reach the server. Is it running?"
            }
            probing = false
        }
    }

    private func create() {
        guard canCreate, let client = state.client else { return }
        let spec = spec
        let key = apiKey.isEmpty ? nil : apiKey
        errorMessage = nil
        step = .network
        Task {
            do {
                if let key {
                    try SandboxKeychain().save(key, account: spec.name)
                } else {
                    try? SandboxKeychain().delete(account: spec.name)
                }
                SandboxRuntime.shared.clearKill(spec.name)
                try await client.createSandbox(spec, apiKey: key) { newStep in
                    Task { @MainActor in step = newStep }
                }
                state.showToast("Created \(spec.name)", style: .success)
                state.resourcesChanged()
                onCreated(spec.name)
                dismiss()
            } catch {
                if key != nil { try? SandboxKeychain().delete(account: spec.name) }
                errorMessage = error.localizedDescription
            }
            step = nil
        }
    }
}
