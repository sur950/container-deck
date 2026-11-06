import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DeckCore

/// Sheet that makes a local Kubernetes cluster.
struct KubeClusterCreateSheet: View {
    enum CNI: String, CaseIterable, Identifiable {
        case kindnet, none, manifest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .kindnet: return "kindnet"
            case .none: return "None"
            case .manifest: return "Own manifest"
            }
        }
    }

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let existing: Set<String>
    let onCreated: (String) -> Void

    @State private var name = ""
    @State private var version = KubernetesConfig.defaultVersion
    @State private var customImage = ""
    @State private var useCustomImage = false
    @State private var workers = 0
    @State private var cni: CNI = .kindnet
    @State private var manifestPath = ""
    @State private var cpus = KubernetesConfig.defaultCPUs()
    @State private var memoryGB = KubernetesConfig.defaultMemoryGB()

    init(existing: Set<String>, onCreated: @escaping (String) -> Void) {
        self.existing = existing
        self.onCreated = onCreated
    }

    var body: some View {
        SheetScaffold(
            "New Cluster",
            subtitle: "A local Kubernetes cluster. Each node is a light VM.",
            icon: .kubernetes,
            width: 600
        ) {
            DeckFormGroup("Cluster") {
                DeckFormRow("Name") {
                    TextField("Name", text: $name, prompt: Text(suggestedName))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    if let problem = nameProblem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(DS.danger)
                    }
                }
                DeckFormRow("Version", note: versionNote) {
                    if useCustomImage {
                        TextField("Node image", text: $customImage, prompt: Text("docker.io/kindest/node:v1.35.5"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    } else {
                        Picker("Version", selection: $version) {
                            ForEach(KubernetesConfig.versions, id: \.self) { item in
                                Text(item == KubernetesConfig.defaultVersion ? "\(item) (default)" : item).tag(item)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220, alignment: .leading)
                        .popUpAppearanceRefresh()
                    }
                    Toggle("Use my own node image", isOn: $useCustomImage)
                }
                DeckFormRow("Workers", note: workers == 0 ? "No workers. The control plane runs your pods too." : "Each worker is one more VM with the CPUs and memory below.") {
                    stepperRow(value: $workers, range: 0...8, text: workers == 1 ? "1 worker" : "\(workers) workers")
                }
            }

            DeckFormGroup("Network") {
                DeckFormRow("CNI", note: cniNote) {
                    Picker("CNI", selection: $cni) {
                        ForEach(CNI.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    if cni == .manifest {
                        HStack(spacing: 8) {
                            TextField("Manifest", text: $manifestPath, prompt: Text("/path/to/cni.yaml"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            Button("Choose") { chooseManifest() }
                        }
                    }
                }
            }

            DeckFormGroup("Resources per node") {
                DeckFormRow("CPUs") {
                    stepperRow(value: $cpus, range: KubernetesConfig.minCPUs...MachineDefaults.maxCPUs, text: "\(cpus) of \(MachineDefaults.maxCPUs)")
                }
                DeckFormRow("Memory", note: "Kubernetes needs at least 2 GB per node.") {
                    stepperRow(value: $memoryGB, range: KubernetesConfig.minMemoryGB...MachineDefaults.maxMemoryGB, text: "\(memoryGB) GB of \(MachineDefaults.maxMemoryGB) GB")
                }
                if totalMemoryGB > MachineDefaults.maxMemoryGB / 2 {
                    Text("All nodes together use \(totalMemoryGB) GB, more than half of this Mac.")
                        .font(.caption)
                        .foregroundStyle(DS.warning)
                        .padding(.leading, DeckForm.labelWidth + 12)
                }
            }

            ResourceCommandHint(state.client?.createClusterArguments(options) ?? [])
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") { create() }
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .frame(height: 690)
    }

    private func stepperRow(value: Binding<Int>, range: ClosedRange<Int>, text: String) -> some View {
        HStack(spacing: 8) {
            Stepper(value: value, in: range) { EmptyView() }
                .labelsHidden()
            Text(text)
                .monospacedDigit()
                .foregroundStyle(DS.textSecondary)
        }
    }

    // MARK: - Logic

    private var suggestedName: String {
        if !existing.contains(KubernetesConfig.defaultClusterName) { return KubernetesConfig.defaultClusterName }
        var index = 2
        while existing.contains("\(KubernetesConfig.defaultClusterName)-\(index)") { index += 1 }
        return "\(KubernetesConfig.defaultClusterName)-\(index)"
    }

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? suggestedName : typed
    }

    private var nameProblem: String? {
        if !KubernetesConfig.isValidName(effectiveName) {
            return "Use letters, numbers, dots, dashes and underscores. Start with a letter or number."
        }
        if existing.contains(effectiveName) || KubernetesStore.shared.jobs[effectiveName] != nil {
            return "A cluster with this name already exists."
        }
        return nil
    }

    private var versionNote: String {
        if useCustomImage { return "A kind node image with a version tag." }
        return version == KubernetesConfig.defaultVersion
            ? "The version Apple's cluster plugin is tested with."
            : "Newer node images may need a newer container tool."
    }

    private var cniNote: String {
        switch cni {
        case .kindnet: return "kindnet comes with the cluster plugin. Pods get a network right away."
        case .none: return "No network plugin. Nodes wait for one until you apply a CNI manifest yourself."
        case .manifest: return "A YAML manifest on this Mac, such as Calico or Cilium."
        }
    }

    private var totalMemoryGB: Int { memoryGB * (workers + 1) }

    private var nodeImage: String {
        if useCustomImage { return customImage.trimmingCharacters(in: .whitespaces) }
        return KubernetesConfig.nodeImage(forVersion: version)
    }

    private var options: KubeClusterOptions {
        let choice: KubeCNIChoice
        switch cni {
        case .kindnet: choice = .kindnet
        case .none: choice = .none
        case .manifest: choice = .manifest(manifestPath.trimmingCharacters(in: .whitespaces))
        }
        return KubeClusterOptions(
            name: effectiveName,
            nodeImage: nodeImage == KubernetesConfig.defaultNodeImage ? "" : nodeImage,
            workers: workers,
            cni: choice,
            cpus: cpus,
            memory: "\(memoryGB)G"
        )
    }

    private var canCreate: Bool {
        guard state.client != nil, nameProblem == nil else { return false }
        if useCustomImage && KubernetesConfig.version(fromNodeImage: nodeImage) == nil { return false }
        if cni == .manifest {
            let path = manifestPath.trimmingCharacters(in: .whitespaces)
            return !path.isEmpty && FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
        }
        return true
    }

    private func chooseManifest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.yaml, .json, .data]
        panel.message = "Pick a CNI manifest"
        if panel.runModal() == .OK, let url = panel.url {
            manifestPath = url.path
        }
    }

    private func create() {
        guard let client = state.client, canCreate else { return }
        var request = options
        if case .manifest(let path) = request.cni {
            request.cni = .manifest((path as NSString).expandingTildeInPath)
        }
        KubernetesStore.shared.create(request, client: client, state: state)
        onCreated(request.name)
        dismiss()
    }
}
