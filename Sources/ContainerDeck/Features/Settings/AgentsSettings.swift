import SwiftUI
import AppKit
import DeckCore

/// Settings, Agents: where each agent's program, MCP config and sessions are.
/// Each field shows the detected path. Changing it stores an override, Reset goes back to the detected path.
struct AgentsSettings: View {
    @State private var overrides = AgentPathOverrides.load()
    @State private var version = 0

    /// Tools found on this Mac first.
    private var tools: [AgentTool] {
        let resolver = AgentPathsEnvironment.resolver(overrides: overrides)
        let found = AgentTool.allCases.filter { resolver.executable($0).exists }
        return found + AgentTool.allCases.filter { !found.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                Text("Each field shows what \(AppConfig.appName) found. Change one to use your own path, and Reset to go back. It checks the agent's own setting first (CLAUDE_CONFIG_DIR, CODEX_HOME, GEMINI_CLI_HOME, in the app or in your shell config), then the usual places, then PATH.")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(tools) { tool in
                let detected = detectedResolver(tool)
                Section(tool.title) {
                    let program = detected.executable(tool)
                    AgentPathField(title: tool.isApp ? "App" : "Program", kind: tool.isApp ? .app : .executable,
                                   value: binding(tool, \.executable, detected: program),
                                   placeholder: detected.usualExecutablePath(tool),
                                   isOverride: overrides[tool].executable != nil,
                                   current: resolver.executable(tool))
                    if tool.ownsConfigFile, let current = resolver.configFile(tool), let found = detected.configFile(tool) {
                        AgentPathField(title: "MCP config", kind: .file, value: binding(tool, \.config, detected: found),
                                       placeholder: found.path ?? "", isOverride: overrides[tool].config != nil, current: current)
                    }
                    if let current = resolver.sessionsFolder(tool), let found = detected.sessionsFolder(tool) {
                        AgentPathField(title: "Sessions", kind: .folder, value: binding(tool, \.sessions, detected: found),
                                       placeholder: found.path ?? "", isOverride: overrides[tool].sessions != nil, current: current)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .id(version)
    }

    private var resolver: AgentPathResolver { AgentPathsEnvironment.resolver(overrides: overrides) }

    /// The resolver without this tool's overrides, for the detected value.
    private func detectedResolver(_ tool: AgentTool) -> AgentPathResolver {
        var copy = overrides
        copy[tool] = AgentPathOverride()
        return AgentPathsEnvironment.resolver(overrides: copy)
    }

    /// Shows the override or the detected path. Stores an override only when it differs from what was detected.
    private func binding(_ tool: AgentTool, _ key: WritableKeyPath<AgentPathOverride, String?>,
                         detected: ResolvedAgentPath) -> Binding<String> {
        let resolver = detectedResolver(tool)
        return Binding(
            get: { resolver.fieldValue(override: overrides[tool][keyPath: key], detected: detected) },
            set: { value in
                var item = overrides[tool]
                item[keyPath: key] = resolver.overrideToStore(value, detected: detected)
                overrides[tool] = item
                overrides.save()
                NotificationCenter.default.post(name: .deckAgentPathsChanged, object: nil)
            }
        )
    }
}

/// One path: a field with the detected or chosen path, Found or Not found, Choose, Reveal and Reset.
private struct AgentPathField: View {
    enum Kind { case executable, app, file, folder }

    let title: String
    let kind: Kind
    @Binding var value: String
    /// Usual place, shown when nothing was found.
    let placeholder: String
    let isOverride: Bool
    let current: ResolvedAgentPath

    var body: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 6) {
                TextField(title, text: $value, prompt: Text(abbreviatedPath(placeholder)))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    status
                    Spacer(minLength: 4)
                    Button("Choose…", action: choose)
                    Button("Reveal") {
                        if let path = current.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    .disabled(!current.exists)
                    Button("Reset") { value = "" }
                        .disabled(!isOverride)
                        .help("Go back to the detected path")
                }
                .controlSize(.small)
                if isOverride && !current.exists {
                    Text("Nothing is at this path. Choose another or press Reset.")
                        .font(.caption)
                        .foregroundStyle(DS.warning)
                }
            }
            .frame(width: 400)
        } label: {
            Text(title)
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 5) {
            Circle().fill(current.exists ? DS.running : DS.warning).frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(current.exists ? DS.textSecondary : DS.warning)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(statusText)
    }

    private var statusText: String {
        guard current.exists else { return "Not found" }
        if isOverride { return "Found, set here" }
        if let variable = current.variable {
            return current.source == .shellConfig ? "Found, \(variable) in shell config" : "Found, from \(variable)"
        }
        return current.source == .path ? "Found on PATH" : "Found"
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind != .folder
        panel.treatsFilePackagesAsDirectories = kind == .executable
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        if let path = current.path ?? (placeholder.isEmpty ? nil : placeholder) {
            let url = URL(fileURLWithPath: path)
            panel.directoryURL = kind == .folder ? url : url.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
}
