import SwiftUI
import AppKit
import DeckCore

/// Installs a catalog server, or a custom one from an image or a command on this Mac.
struct MCPInstallSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let store: AgentsStore
    let item: MCPCatalogItem?

    enum Source: String, CaseIterable, Identifiable {
        case image, command
        var id: String { rawValue }
        var title: String { self == .image ? "Container image" : "Command on this Mac" }
    }

    struct EnvRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        var secret: Bool
        var label: String?
        var required: Bool = false
        var placeholder: String = ""
    }

    @State private var name = ""
    @State private var source: Source = .image
    @State private var image = ""
    @State private var transport: MCPTransport = .stdio
    @State private var commandText = ""
    @State private var containerPort = ""
    @State private var path = "/mcp"
    @State private var envRows: [EnvRow] = []
    @State private var folder = ""
    @State private var folderReadOnly = false
    @State private var checkAfter = true
    @State private var working = false
    @State private var step: String?

    /// A remote server from the MCP Registry: connected by URL, nothing runs here.
    private var remoteURL: String? { item?.remoteURL }

    var body: some View {
        SheetScaffold(item.map { "Install \($0.title)" } ?? "Add an MCP server",
                      subtitle: item?.summary ?? "Run an MCP server image in a container, or a command on this Mac.",
                      icon: item == nil ? .wand : .agents, width: 600) {
            DeckFormGroup("Server") {
                DeckFormRow("Name", note: nameNote) {
                    TextField("Name", text: $name, prompt: Text("my-server"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                if item == nil {
                    DeckFormRow("Runs") {
                        Picker("Runs", selection: $source) {
                            ForEach(Source.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                if let remoteURL {
                    DeckFormRow("URL", note: "Nothing runs on this Mac. Agents connect to this address.") {
                        Text(remoteURL).font(.callout.monospaced()).textSelection(.enabled)
                    }
                } else if source == .image {
                    DeckFormRow("Image") {
                        TextField("Image", text: $image, prompt: Text("mcp/time or ghcr.io/owner/server"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .disabled(item != nil)
                    }
                    if item == nil {
                        DeckFormRow("Transport", note: transportNote) {
                            Picker("Transport", selection: $transport) {
                                ForEach(MCPTransport.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                }
                if remoteURL == nil {
                DeckFormRow(source == .image ? "Arguments" : "Command",
                            note: source == .image ? "After the image. Leave empty to use the image default." : "Full command, like npx -y @scope/server") {
                    TextField("Command", text: $commandText, prompt: Text(source == .image ? "optional" : "npx -y @modelcontextprotocol/server-everything"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                }
                }
                if remoteURL == nil && source == .image && transport != .stdio {
                    DeckFormRow("Port", note: "The port the server listens on inside the container. The Mac side gets a free port on 127.0.0.1.") {
                        HStack(spacing: 8) {
                            TextField("Port", text: $containerPort, prompt: Text("8000"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Text("Path").foregroundStyle(DS.textSecondary)
                            TextField("Path", text: $path, prompt: Text("/mcp"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                    }
                }
            }

            if source == .image, item?.mount != nil || item == nil {
                DeckFormGroup(item?.mount?.label ?? "Folder") {
                    DeckFormRow(item?.mount?.label ?? "Folder", note: folderNote) {
                        HStack(spacing: 8) {
                            TextField("Folder", text: $folder, prompt: Text(folderPrompt))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { chooseFolder() }
                        }
                        if item?.mount?.isFile != true {
                            Toggle("Read only", isOn: $folderReadOnly)
                        }
                    }
                }
            }

            DeckFormGroup(remoteURL == nil ? "Settings and secrets" : "Headers") {
                if let fixed = fixedSettingsNote {
                    DeckFormNote(fixed)
                }
                if envRows.isEmpty {
                    DeckFormNote(remoteURL == nil ? "No settings needed. Add one if the server reads an environment variable."
                                                  : "No headers needed. Add one if the server asks for a header.")
                }
                ForEach($envRows) { $row in
                    DeckFormRow(row.label ?? "Variable", note: note(for: row)) {
                        HStack(spacing: 8) {
                            if row.label == nil {
                                TextField("Name", text: $row.key, prompt: Text("NAME"))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .font(.callout.monospaced())
                                    .frame(width: 150)
                            }
                            if row.secret {
                                SecureField("Value", text: $row.value, prompt: Text(row.placeholder.isEmpty ? "secret" : row.placeholder))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField("Value", text: $row.value, prompt: Text(row.placeholder.isEmpty ? "value" : row.placeholder))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                            }
                            if row.label == nil {
                                Toggle("Secret", isOn: $row.secret)
                                    .toggleStyle(.checkbox)
                                Button {
                                    envRows.removeAll { $0.id == row.id }
                                } label: {
                                    Image.deck(.close, size: 12)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove")
                            }
                        }
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        envRows.append(EnvRow(key: "", value: "", secret: false))
                    } label: {
                        DeckLabel(remoteURL == nil ? "Add Variable" : "Add Header", icon: .add)
                    }
                    .controlSize(.small)
                }
            }

            Toggle(source == .image && transport == .stdio
                   ? "Check it after install (starts the container once, pulls the image if needed)"
                   : "Check it after install", isOn: $checkAfter)
            if let step {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(DS.textSecondary)
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Button(item == nil ? "Add Server" : "Install") { install() }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
                .disabled(!canInstall || working)
        }
        .onAppear(perform: prefill)
        .onDeckDebugCommand { name, value in
            guard name == "agents-install" else { return }
            if value == "go" { install() }
            if value.hasPrefix("name=") { self.name = String(value.dropFirst(5)) }
        }
    }

    // MARK: Text

    private var nameNote: String? {
        if !name.isEmpty, !MCPLaunch.isValidName(name) { return "Use letters, numbers, dashes or underscores." }
        if store.installed.contains(where: { $0.name == name }) { return "A server with this name exists. Installing replaces it." }
        return "Agents see this name."
    }

    private func note(for row: EnvRow) -> String? {
        var parts: [String] = []
        if let label = row.label, label != row.key, !row.key.isEmpty { parts.append("Sets \(row.key).") }
        if row.secret {
            parts.append(remoteURL == nil ? "Kept in your Keychain. Never written to agent config files."
                                          : "Agents need it in their config, so it is written there when you connect.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var transportNote: String {
        switch transport {
        case .stdio: return "The agent starts the container when it needs the server."
        case .http: return "Streamable HTTP. Runs as a container with a published port."
        case .sse: return "Older HTTP transport with server sent events."
        }
    }

    private var folderNote: String {
        guard let mount = item?.mount else { return "Optional. Mounted at /workspace." }
        if mount.isFile { return "Mounted read only at \(mount.containerPath). The server can only see this file." }
        return (mount.optional ? "Optional. " : "") + "Mounted at \(mount.containerPath). The server can only see this folder."
    }

    private var folderPrompt: String {
        guard let mount = item?.mount else { return "optional" }
        if mount.optional { return "optional" }
        return mount.isFile ? "Choose a file" : "Choose a folder"
    }

    /// Settings the catalog sets without asking, and where saved data goes.
    private var fixedSettingsNote: String? {
        guard let item, remoteURL == nil else { return nil }
        var parts = item.env.map { "Sets \($0.key) to \($0.value)." }
        if let volume = item.volume, MCPLaunch.isValidName(name) {
            parts.append("Saves its data in the volume \(volume.name(server: name)).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var canInstall: Bool {
        guard MCPLaunch.isValidName(name) else { return false }
        if remoteURL != nil { return envRows.allSatisfy { !$0.required || !$0.value.isEmpty } }
        if source == .command { return !commandText.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !image.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if transport != .stdio, Int(containerPort) == nil { return false }
        if let mount = item?.mount, !mount.optional, folder.isEmpty { return false }
        return envRows.allSatisfy { !$0.required || !$0.value.isEmpty }
    }

    // MARK: Actions

    private func prefill() {
        guard let item else { return }
        var base = item.defaultServerName
        if store.installed.contains(where: { $0.name == base }) {
            var n = 2
            while store.installed.contains(where: { $0.name == "\(base)-\(n)" }) { n += 1 }
            base = "\(base)-\(n)"
        }
        name = base
        image = item.image
        transport = item.transport
        commandText = item.command.map(MCPLaunch.shellQuote).joined(separator: " ")
        containerPort = item.containerPort.map(String.init) ?? ""
        path = item.path ?? "/mcp"
        envRows = item.fields.map {
            EnvRow(key: $0.key, value: "", secret: $0.secret, label: $0.label, required: $0.required, placeholder: $0.placeholder)
        }
        folderReadOnly = item.mount?.readOnly ?? false
        folder = item.mount?.existingSuggestion() ?? ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        let file = item?.mount?.isFile == true
        panel.canChooseDirectories = !file
        panel.canChooseFiles = file
        panel.showsHiddenFiles = file
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func makeServer() -> MCPInstalledServer {
        if let remoteURL {
            let headers = envRows.filter { !$0.key.isEmpty && !$0.value.isEmpty }.map { EnvVar(key: $0.key, value: $0.value) }
            return MCPInstalledServer(name: name, kind: .remote, catalogID: item?.id, transport: transport,
                                      remoteURL: remoteURL, headers: headers)
        }
        let args = MCPCommandWords.split(commandText)
        let typed = envRows.filter { !$0.secret && !$0.key.isEmpty }.map { EnvVar(key: $0.key, value: $0.value) }
        // Fixed catalog settings first, so a row with the same name wins.
        let fixed = (item?.env ?? []).filter { setting in !typed.contains { $0.key == setting.key } }
        let plain = fixed + typed
        let secretKeys = envRows.filter { $0.secret && !$0.key.isEmpty }.map(\.key)
        if source == .command {
            return MCPInstalledServer(name: name, kind: .hostCommand, transport: .stdio, command: args, env: plain, secretKeys: [])
        }
        var mounts: [MountSpec] = []
        if !folder.isEmpty {
            let readOnly = item?.mount?.isFile == true ? true : folderReadOnly
            mounts.append(MountSpec(kind: .bind, source: folder, destination: item?.mount?.containerPath ?? "/workspace", readOnly: readOnly))
        }
        if let volume = item?.volume {
            mounts.append(MountSpec(kind: .volume, source: volume.name(server: name), destination: volume.containerPath))
        }
        let longRunning = transport != .stdio
        return MCPInstalledServer(
            name: name, kind: .container, catalogID: item?.id, image: image.trimmingCharacters(in: .whitespaces),
            transport: transport, command: args,
            containerPort: longRunning ? Int(containerPort) : nil, hostPort: longRunning ? store.freePort() : nil,
            path: longRunning ? (path.hasPrefix("/") ? path : "/" + path) : nil,
            env: plain, secretKeys: secretKeys, mounts: mounts
        )
    }

    private func install() {
        guard canInstall, !working, let client = state.client else {
            if state.client == nil { state.showError(DeckError.commandFailed("The container command was not found.")) }
            return
        }
        working = true
        let server = makeServer()
        let secrets = remoteURL != nil ? [:] : Dictionary(envRows.filter { $0.secret && !$0.key.isEmpty }.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        Task {
            defer { working = false; step = nil }
            do {
                step = server.isLongRunning ? "Starting the container" : "Saving"
                try await store.install(server, secretValues: secrets, client: client)
                if checkAfter, !server.isLongRunning {
                    step = server.kind == .remote ? "Checking the server" : "Checking the server (first run pulls the image)"
                    await store.check(server, cliPath: client.cliPath)
                }
                state.resourcesChanged()
                await store.load()
                if case .failed(let message, _) = store.health[server.name] {
                    state.showToast("Installed \(server.name). Check failed: \(message)", style: .error)
                } else {
                    state.showToast("Installed \(server.name). Connect it to an agent from Servers.", style: .success)
                }
                dismiss()
            } catch {
                state.showError(error)
            }
        }
    }
}

/// Splits a command line into words. Single and double quotes group words.
enum MCPCommandWords {
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        var escaping = false
        for ch in text {
            if escaping { current.append(ch); escaping = false; continue }
            if ch == "\\", quote != "'" { escaping = true; hasWord = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; hasWord = true; continue }
            if ch == " " || ch == "\t" || ch == "\n" {
                if hasWord { words.append(current); current = ""; hasWord = false }
                continue
            }
            current.append(ch)
            hasWord = true
        }
        if hasWord { words.append(current) }
        return words
    }
}
