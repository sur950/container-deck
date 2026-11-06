import SwiftUI
import AppKit
import DeckCore

/// Run a new container, or recreate one with new settings.
/// Presented by RootView from AppState.runRequest.
struct RunSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// AppKit menus and pop up buttons keep the old colors after a Light or Dark switch.
    /// They rebuild with `.id(colorScheme)`.
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let request: RunRequest

    // Form values
    @State private var image: String
    @State private var name: String
    @State private var command: String
    @State private var entrypoint: String
    @State private var workingDir: String
    @State private var ports: [RunPortRow]
    @State private var env: [RunPairRow]
    @State private var labels: [RunPairRow]
    @State private var mounts: [RunMountRow]
    @State private var cpus: Int
    @State private var memory: String
    @State private var network: String
    @State private var platform: String
    @State private var autoRemove: Bool
    @State private var user: String
    @State private var readOnlyRootfs: Bool

    // Lookups
    @State private var localImages: [ImageSummary] = []
    @State private var volumes: [VolumeSummary] = []
    @State private var networks: [NetworkSummary] = []
    @State private var hubResults: [HubRepository] = []
    @State private var hubSearching = false
    @State private var showSuggestions = false
    @State private var pickedImage: String
    @State private var amd64Only = false
    @State private var platformWasAuto = false
    @State private var exposedPorts: [String] = []

    // Run state
    @State private var isWorking = false
    @State private var progressText: String?
    @State private var errorText: String?
    @State private var errorTitle: String?
    /// Command that makes the old container again, when the app could not.
    @State private var restoreCommand: String?

    private let maxCPUs = max(1, ProcessInfo.processInfo.activeProcessorCount)

    init(request: RunRequest) {
        self.request = request
        let options = request.options
        _image = State(initialValue: options.image)
        _pickedImage = State(initialValue: options.image)
        _name = State(initialValue: options.name ?? "")
        _command = State(initialValue: ContainerText.shellJoin(options.command))
        _entrypoint = State(initialValue: options.entrypoint ?? "")
        _workingDir = State(initialValue: options.workingDir ?? "")
        _ports = State(initialValue: options.ports.map {
            RunPortRow(address: $0.hostAddress, host: "\($0.hostPort)", container: "\($0.containerPort)", proto: $0.proto.lowercased())
        })
        _env = State(initialValue: options.env.map { RunPairRow(key: $0.key, value: $0.value) })
        _labels = State(initialValue: options.labels.sorted { $0.key < $1.key }.map { RunPairRow(key: $0.key, value: $0.value) })
        _mounts = State(initialValue: options.mounts.map {
            RunMountRow(kind: $0.kind, source: $0.source, destination: $0.destination, readOnly: $0.readOnly)
        })
        _cpus = State(initialValue: options.cpus ?? 0)
        _memory = State(initialValue: options.memory ?? "")
        _network = State(initialValue: options.network ?? "")
        _platform = State(initialValue: options.platform ?? "")
        _autoRemove = State(initialValue: options.autoRemove)
        _user = State(initialValue: options.user ?? "")
        _readOnlyRootfs = State(initialValue: options.readOnlyRootfs)
    }

    private var isRecreate: Bool { request.replacing != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                Form {
                    imageSection
                    platformSection
                    processSection
                    portsSection.id("ports")
                    envSection
                    mountsSection.id("mounts")
                    resourcesSection.id("resources")
                    labelsSection.id("labels")
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .disabled(isWorking)
                .onDeckDebugCommand { name, value in
                    // Automation only: run-scroll:ports|mounts|resources|labels.
                    if name == "run-scroll" { proxy.scrollTo(value, anchor: .top) }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 600, idealHeight: 760)
        .background(DS.surface)
        .task {
            await loadLookups()
        }
        .task(id: image) {
            await checkImage()
        }
        .onDeckDebugCommand { name, value in
            handleDebug(name, value)
        }
    }

    // MARK: Header and footer

    // Header and footer follow SheetScaffold, so this sheet matches the others.
    // The body is a grouped Form, which scrolls by itself.
    private var header: some View {
        HStack(spacing: 12) {
            IconBadge(isRecreate ? .edit : .play, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(isRecreate ? "Edit and Recreate" : "Run a Container")
                    .font(.title3.weight(.semibold))
                Text(isRecreate
                     ? "A new container replaces the old one. If it fails to start, the old one is put back."
                     : "Pick an image and choose how it runs.")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
                if isRecreate {
                    Text("Files saved inside the old container are not kept. Volumes and shared folders are.")
                        .font(.caption)
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorText {
                HStack(alignment: .top, spacing: 8) {
                    DeckIcon(.error, size: 14, color: DS.danger)
                    VStack(alignment: .leading, spacing: 6) {
                        if let errorTitle {
                            Text(errorTitle)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(DS.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ScrollView {
                            Text(errorText)
                                .font(.callout)
                                .foregroundStyle(errorTitle == nil ? DS.textPrimary : DS.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                        .fixedSize(horizontal: false, vertical: true)
                        if let restoreCommand {
                            CommandHint(restoreCommand)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).fill(DS.danger.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.danger.opacity(0.25), lineWidth: 1))
            }
            HStack(spacing: 10) {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text(progressText ?? "Working…")
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                } else if let reason = blockReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                } else if showHints, let client = state.client {
                    CommandHint(client.commandLine(client.runArguments(options)))
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRecreate ? "Recreate" : "Run") {
                    Task { await runNow() }
                }
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(blockReason != nil || isWorking)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    /// Short help line under a form section, aligned with the rows.
    private func sectionNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(DS.textSecondary)
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Image

    private var imageSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("Image", text: $image, prompt: Text("nginx:latest"))
                    .onChange(of: image) { _, value in
                        showSuggestions = value != pickedImage
                    }
                Menu {
                    if localImages.isEmpty {
                        Text("No local images")
                    }
                    ForEach(localImages) { item in
                        Button(ContainerText.shortImage(item.reference)) {
                            pick(item.reference)
                        }
                    }
                } label: {
                    DeckLabel("Local", icon: .images)
                }
                .fixedSize()
                .id(colorScheme)
                .help("Pick an image you already have")
            }
            if showSuggestions && !trimmed(image).isEmpty {
                suggestions
            }
        } header: {
            Text("Image")
        } footer: {
            sectionNote("Images from Docker Hub are pulled when the container starts.")
        }
    }

    private var localMatches: [ImageSummary] {
        let query = trimmed(image).lowercased()
        guard !query.isEmpty else { return [] }
        return Array(localImages.filter { $0.reference.lowercased().contains(query) }.prefix(4))
    }

    @ViewBuilder
    private var suggestions: some View {
        let local = localMatches
        VStack(alignment: .leading, spacing: 2) {
            if !local.isEmpty {
                Text("On this Mac").font(.caption).foregroundStyle(DS.textSecondary)
                ForEach(local) { item in
                    suggestionRow(
                        icon: .images,
                        title: ContainerText.shortImage(item.reference),
                        detail: Format.bytes(item.sizeBytes),
                        official: false
                    ) {
                        pick(item.reference)
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Docker Hub").font(.caption).foregroundStyle(DS.textSecondary)
                if hubSearching { ProgressView().controlSize(.mini) }
            }
            .padding(.top, local.isEmpty ? 0 : 6)
            if hubResults.isEmpty && !hubSearching {
                Text("No results yet").font(.caption).foregroundStyle(DS.textTertiary)
            }
            ForEach(hubResults.prefix(6)) { repo in
                suggestionRow(
                    icon: .explore,
                    title: repo.fullName,
                    detail: repo.description.isEmpty ? "\(Format.count(repo.pullCount)) pulls" : repo.description,
                    official: repo.isOfficial,
                    stars: repo.starCount
                ) {
                    pick(repo.fullName)
                }
            }
        }
    }

    private func suggestionRow(
        icon: DeckIconName, title: String, detail: String, official: Bool, stars: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DeckIcon(icon, size: 13, color: DS.textSecondary)
                Text(title).fontWeight(.medium).lineLimit(1)
                if official { Pill("Official", tint: DS.running) }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let stars {
                    HStack(spacing: 3) {
                        DeckIcon(.star, size: 10, color: DS.textTertiary)
                        Text(Format.count(stars)).font(.caption).monospacedDigit()
                    }
                    .foregroundStyle(DS.textSecondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Platform

    private var rosettaMissing: Bool {
        guard let check = state.report.check(.rosetta) else { return false }
        return !check.state.isPassing
    }

    private var platformSection: some View {
        Section("Platform") {
            Picker("Platform", selection: Binding(
                get: { platform },
                set: { value in
                    platform = value
                    platformWasAuto = false
                }
            )) {
                Text("Native (arm64)").tag("")
                Text("Intel (amd64) with Rosetta").tag("linux/amd64")
            }
            // Form rows: each id must be unique, or the form shows one row twice.
            .id("platform-\(colorScheme)")
            if amd64Only {
                noteRow(icon: .rosetta, tint: DS.warning, text: "This image is built only for Intel Macs. It runs with Rosetta, which is a bit slower.")
            } else if platform == "linux/amd64" {
                noteRow(icon: .rosetta, tint: DS.textSecondary, text: "Runs with Rosetta. Pick Native when the image has an arm64 build.")
            }
            if platform == "linux/amd64" && rosettaMissing {
                HStack(spacing: 8) {
                    DeckIcon(.warning, size: 13, color: DS.danger)
                    Text("Rosetta is not installed. Install it to run Intel images.")
                        .font(.callout)
                    Spacer()
                    if state.busyFix == .installRosetta {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await state.fix(.installRosetta) }
                        } label: {
                            DeckLabel("Install Rosetta", icon: .lock)
                        }
                    }
                }
            }
        }
    }

    private func noteRow(icon: DeckIconName, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DeckIcon(icon, size: 13, color: tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Process

    private var processSection: some View {
        Section("Container") {
            TextField("Name", text: $name, prompt: Text("Optional, a name is made for you"))
            TextField("Command", text: $command, prompt: Text("Image default"))
            TextField("Entrypoint", text: $entrypoint, prompt: Text("Image default"))
            TextField("Working folder", text: $workingDir, prompt: Text("Image default"))
            TextField("User", text: $user, prompt: Text("Image default, like 1000 or nginx"))
            Toggle("Read only root file system", isOn: $readOnlyRootfs)
            Toggle("Remove when it stops", isOn: $autoRemove)
            if isRecreate, !keptSettings.isEmpty {
                noteRow(icon: .success, tint: DS.textSecondary, text: "Also kept: " + keptSettings.joined(separator: ", ") + ".")
            }
        }
    }

    /// Settings with no field here that still carry over to the new container.
    private var keptSettings: [String] {
        let o = request.options
        var list: [String] = []
        if o.macAddress != nil { list.append("MAC address") }
        if !o.extraNetworks.isEmpty { list.append("\(o.extraNetworks.count + 1) networks") }
        if !o.tmpfs.isEmpty { list.append("tmpfs " + o.tmpfs.joined(separator: " ")) }
        if !o.capAdd.isEmpty || !o.capDrop.isEmpty { list.append("capabilities") }
        if o.noDNS {
            list.append("no DNS")
        } else if !o.dnsServers.isEmpty || !o.dnsSearch.isEmpty || !o.dnsOptions.isEmpty || o.dnsDomain != nil {
            list.append("DNS")
        }
        if !o.ulimits.isEmpty { list.append("limits") }
        if o.useInit { list.append("init") }
        if o.rosetta { list.append("Rosetta") }
        if o.ssh { list.append("SSH agent") }
        if o.shmSize != nil { list.append("shared memory size") }
        if !o.publishSockets.isEmpty { list.append("sockets") }
        if o.maskedPaths != nil || o.readOnlyPaths != nil { list.append("protected paths") }
        if o.runtime != nil { list.append("runtime") }
        if o.virtualization { list.append("virtualization") }
        return list
    }

    // MARK: Ports

    private var portsSection: some View {
        Section {
            ForEach(ports) { row in
                HStack(spacing: 8) {
                    TextField("Mac port", text: rowBinding($ports, row.id, \.host, fallback: ""), prompt: Text("Mac port"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .frame(width: 120)
                    DeckIcon(.chevronRight, size: 11, color: DS.textTertiary)
                    TextField("Container port", text: rowBinding($ports, row.id, \.container, fallback: ""), prompt: Text("Container port"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .frame(width: 120)
                    Picker("Protocol", selection: rowBinding($ports, row.id, \.proto, fallback: "tcp")) {
                        Text("TCP").tag("tcp")
                        Text("UDP").tag("udp")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .id(colorScheme)
                    Spacer()
                    if !row.isValid {
                        DeckIcon(.warning, size: 12, color: DS.warning)
                            .help("Ports are numbers from 1 to 65535")
                    }
                    removeButton { ports.removeAll { $0.id == row.id } }
                }
                .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                addButton("Add Port") { ports.append(RunPortRow()) }
                ForEach(suggestedPorts, id: \.self) { value in
                    Button {
                        addExposed(value)
                    } label: {
                        Pill("+ \(value)", tint: DS.accent)
                    }
                    .buttonStyle(.plain)
                    .help("The image listens on \(value)")
                }
            }
        } header: {
            Text("Ports")
        } footer: {
            sectionNote("Open a container port on your Mac, like 8080 to 80.")
        }
    }

    private var suggestedPorts: [String] {
        let used = Set(ports.map { "\($0.container)/\($0.proto)" })
        return exposedPorts.filter { value in
            let parts = value.split(separator: "/")
            let port = parts.first.map(String.init) ?? value
            let proto = parts.count > 1 ? String(parts[1]).lowercased() : "tcp"
            return !used.contains("\(port)/\(proto)")
        }
    }

    private func addExposed(_ value: String) {
        let parts = value.split(separator: "/")
        let port = parts.first.map(String.init) ?? value
        let proto = parts.count > 1 ? String(parts[1]).lowercased() : "tcp"
        ports.append(RunPortRow(host: port, container: port, proto: proto))
    }

    // MARK: Env and labels

    private var envSection: some View {
        Section("Environment") {
            ForEach(env) { row in
                pairRow($env, row, keyPrompt: "NAME", valuePrompt: "value")
            }
            addButton("Add Variable") { env.append(RunPairRow()) }
        }
    }

    private var labelsSection: some View {
        Section("Labels") {
            ForEach(labels) { row in
                pairRow($labels, row, keyPrompt: "key", valuePrompt: "value")
            }
            addButton("Add Label") { labels.append(RunPairRow()) }
        }
    }

    private func pairRow(_ rows: Binding<[RunPairRow]>, _ row: RunPairRow, keyPrompt: String, valuePrompt: String) -> some View {
        HStack(spacing: 8) {
            TextField("Key", text: rowBinding(rows, row.id, \.key, fallback: ""), prompt: Text(keyPrompt))
                .labelsHidden()
                .font(.body.monospaced())
                .frame(width: 200)
            Text("=").foregroundStyle(DS.textTertiary)
            TextField("Value", text: rowBinding(rows, row.id, \.value, fallback: ""), prompt: Text(valuePrompt))
                .labelsHidden()
                .font(.body.monospaced())
            removeButton { rows.wrappedValue.removeAll { $0.id == row.id } }
        }
        .textFieldStyle(.roundedBorder)
    }

    // MARK: Mounts

    private var mountsSection: some View {
        Section {
            ForEach(mounts) { row in
                mountRow(row)
            }
            addButton("Add Mount") { mounts.append(RunMountRow()) }
        } header: {
            Text("Mounts")
        } footer: {
            sectionNote("Share a folder from your Mac or attach a volume.")
        }
    }

    private func mountRow(_ row: RunMountRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Type", selection: rowBinding($mounts, row.id, \.kind, fallback: MountSpec.Kind.bind)) {
                    Text("Folder").tag(MountSpec.Kind.bind)
                    Text("Volume").tag(MountSpec.Kind.volume)
                }
                .labelsHidden()
                .fixedSize()
                .id(colorScheme)
                TextField(
                    "Source",
                    text: rowBinding($mounts, row.id, \.source, fallback: ""),
                    prompt: Text(row.kind == .bind ? "Folder on your Mac" : "Volume name")
                )
                .labelsHidden()
                if row.kind == .bind {
                    Button("Choose…") { chooseFolder(for: row.id) }
                } else {
                    Menu {
                        if volumes.isEmpty {
                            Text("No volumes")
                        }
                        ForEach(volumes) { volume in
                            Button(volume.name) {
                                setMountSource(row.id, volume.name)
                            }
                        }
                    } label: {
                        DeckLabel("Volumes", icon: .volumes)
                    }
                    .fixedSize()
                    .id(colorScheme)
                }
                removeButton { mounts.removeAll { $0.id == row.id } }
            }
            HStack(spacing: 8) {
                TextField("Path in container", text: rowBinding($mounts, row.id, \.destination, fallback: ""), prompt: Text("Path in container, like /data"))
                    .labelsHidden()
                    .font(.body.monospaced())
                Toggle("Read only", isOn: rowBinding($mounts, row.id, \.readOnly, fallback: false))
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 2)
    }

    private func chooseFolder(for id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to share"
        panel.prompt = "Share"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setMountSource(id, url.path)
        if let index = mounts.firstIndex(where: { $0.id == id }), mounts[index].destination.isEmpty {
            mounts[index].destination = "/mnt/" + url.lastPathComponent
        }
    }

    private func setMountSource(_ id: UUID, _ value: String) {
        if let index = mounts.firstIndex(where: { $0.id == id }) {
            mounts[index].source = value
        }
    }

    // MARK: Resources

    private var resourcesSection: some View {
        Section("Resources") {
            Picker("CPUs", selection: $cpus) {
                Text("Default").tag(0)
                ForEach(Array(1...maxCPUs), id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .id("cpus-\(colorScheme)")
            TextField("Memory", text: $memory, prompt: Text("Default, like 1G or 512M"))
            Picker("Network", selection: $network) {
                Text("Default").tag("")
                ForEach(networks.filter { !$0.isDefault }) { item in
                    Text(item.name).tag(item.name)
                }
                if !network.isEmpty && !networks.contains(where: { $0.name == network }) {
                    Text(network).tag(network)
                }
            }
            .id("network-\(colorScheme)")
        }
    }

    // MARK: Small controls

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DeckLabel(title, icon: .add)
        }
        .buttonStyle(.borderless)
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DeckIcon(.close, size: 10, color: DS.textSecondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(DS.hover))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Remove")
    }

    /// Binding to one field of one row, looked up by id so removing rows is safe.
    private func rowBinding<Row: Identifiable, Value>(
        _ rows: Binding<[Row]>, _ id: Row.ID, _ keyPath: WritableKeyPath<Row, Value>, fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                rows.wrappedValue.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback
            },
            set: { newValue in
                if let index = rows.wrappedValue.firstIndex(where: { $0.id == id }) {
                    rows.wrappedValue[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clean(_ text: String) -> String? {
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }

    // MARK: Options

    private var options: RunOptions {
        var result = request.options
        result.image = trimmed(image)
        result.name = clean(name)
        // `--entrypoint` takes one program. Extra words, like the "-c" in
        // "sh -c", go in front of the command.
        let entryWords = ContainerText.shellSplit(entrypoint)
        result.entrypoint = entryWords.first.flatMap { clean($0) }
        result.command = Array(entryWords.dropFirst()) + ContainerText.shellSplit(command)
        result.workingDir = clean(workingDir)
        result.env = env.compactMap { row in
            let key = trimmed(row.key)
            return key.isEmpty ? nil : EnvVar(key: key, value: row.value)
        }
        result.ports = ports.compactMap { $0.mapping }
        result.mounts = mounts.compactMap { row in
            let source = trimmed(row.source)
            let destination = trimmed(row.destination)
            guard !source.isEmpty, !destination.isEmpty else { return nil }
            return MountSpec(kind: row.kind, source: source, destination: destination, readOnly: row.readOnly)
        }
        result.cpus = cpus > 0 ? cpus : nil
        result.memory = clean(memory)
        result.network = network.isEmpty ? nil : network
        var labelMap: [String: String] = [:]
        for row in labels {
            let key = trimmed(row.key)
            if !key.isEmpty { labelMap[key] = row.value }
        }
        result.labels = labelMap
        result.detach = true
        result.autoRemove = autoRemove
        result.platform = platform.isEmpty ? nil : platform
        result.user = clean(user)
        result.readOnlyRootfs = readOnlyRootfs
        return result
    }

    /// Why Run is disabled, or nil when it can run.
    private var blockReason: String? {
        if state.client == nil { return "Finish setup first." }
        if trimmed(image).isEmpty { return "Enter an image." }
        if ports.contains(where: { !$0.isEmpty && !$0.isValid }) { return "Check the port numbers." }
        if mounts.contains(where: { trimmed($0.source).isEmpty != trimmed($0.destination).isEmpty }) {
            return "Each mount needs a source and a path."
        }
        if platform == "linux/amd64" && rosettaMissing { return "Install Rosetta to run Intel images." }
        return nil
    }

    // MARK: Loading

    private func loadLookups() async {
        guard let client = state.client else { return }
        if let list = try? await client.listImages() {
            localImages = list.sorted { $0.reference < $1.reference }
        }
        if let list = try? await client.listVolumes() {
            volumes = list.sorted { $0.name < $1.name }
        }
        if let list = try? await client.listNetworks() {
            networks = list.sorted { $0.name < $1.name }
        }
        // Check the starting image once the local list is known.
        await inspectLocal(trimmed(image))
    }

    private func pick(_ reference: String) {
        pickedImage = reference
        image = reference
        showSuggestions = false
    }

    /// Debounced: Docker Hub search and platform check for the typed image.
    private func checkImage() async {
        do {
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            return
        }
        let query = trimmed(image)
        await inspectLocal(query)
        if Task.isCancelled { return }

        guard showSuggestions, query.count >= 2 else {
            hubResults = []
            return
        }
        var term = query
        if let colon = term.lastIndex(of: ":"), !term[colon...].contains("/") {
            term = String(term[..<colon])
        }
        hubSearching = true
        let results = try? await DockerHubClient().search(term)
        if Task.isCancelled { return }
        hubSearching = false
        hubResults = results?.items ?? []
    }

    private func localImage(matching query: String) -> ImageSummary? {
        guard !query.isEmpty else { return nil }
        return localImages.first { item in
            item.reference == query
                || "\(item.shortName):\(item.tag)" == query
                || (item.shortName == query && item.tag == "latest")
        }
    }

    /// Reads the platforms and exposed ports of a local image.
    private func inspectLocal(_ query: String) async {
        guard let client = state.client, let local = localImage(matching: query) else {
            amd64Only = false
            exposedPorts = []
            if platformWasAuto {
                platform = ""
                platformWasAuto = false
            }
            return
        }
        var platforms = local.platforms
        if let detail = try? await client.inspectImage(local.reference) {
            if !detail.summary.platforms.isEmpty { platforms = detail.summary.platforms }
            exposedPorts = detail.config.exposedPorts
        }
        if Task.isCancelled { return }
        let hasArm = platforms.contains { $0.contains("arm64") }
        let hasIntel = platforms.contains { $0.contains("amd64") }
        amd64Only = hasIntel && !hasArm
        if amd64Only && platform != "linux/amd64" {
            platform = "linux/amd64"
            platformWasAuto = true
        } else if !amd64Only && platformWasAuto {
            platform = ""
            platformWasAuto = false
        }
    }

    // MARK: Run

    private func runNow() async {
        guard let client = state.client, blockReason == nil else { return }
        let opts = options
        isWorking = true
        errorText = nil
        errorTitle = nil
        restoreCommand = nil
        if let old = request.replacing {
            await recreate(old, with: opts, client: client)
            return
        }
        do {
            progressText = "Starting \(ContainerText.shortImage(opts.image))…"
            let returned = try await client.runContainer(opts)
            var newID = trimmed(returned)
            if newID.isEmpty { newID = opts.name ?? "" }
            finish(newID: newID, label: opts.name ?? ContainerText.shortImage(opts.image), recreated: false)
        } catch {
            errorText = Self.friendlyError(error.localizedDescription)
            progressText = nil
            isWorking = false
        }
    }

    /// Checks first, then replaces the old container. When the new one
    /// fails, DeckCore puts the old one back and this shows what happened.
    private func recreate(_ old: String, with opts: RunOptions, client: ContainerClient) async {
        let report: @Sendable (String) -> Void = { text in
            Task { @MainActor in progressText = text }
        }
        do {
            progressText = "Checking the new settings…"
            // Capture again now, so the restore uses the latest state.
            let capture = try await client.captureForRecreate(old)
            let plan = RecreatePlan(old: capture, new: opts)
            let issues = await client.checkRecreate(plan, progress: report)
            if !issues.isEmpty {
                errorTitle = "Nothing was changed. Fix this first."
                errorText = issues.map(\.message).joined(separator: "\n")
                progressText = nil
                isWorking = false
                return
            }

            let keepAutoStart = ContainerOps.isAutoStart(old)
            BackgroundServices.shared.noteUserAction(stopping: old)
            let outcome = try await client.performRecreate(plan, progress: report)
            state.resourcesChanged()
            switch outcome {
            case .recreated(let id):
                let newID = id.isEmpty ? (opts.name ?? "") : id
                if newID != old { ContainerOps.removeAutoStart(old) }
                if keepAutoStart && !newID.isEmpty { ContainerOps.setAutoStart(newID, true) }
                finish(newID: newID, label: opts.name ?? ContainerText.shortImage(opts.image), recreated: true)
                return
            case .restored(let failure, let running):
                errorTitle = running
                    ? "The new container did not start. \(old) was put back and is running."
                    : "The new container did not start. \(old) was put back."
                errorText = Self.friendlyError(failure)
            case .notRestored(let failure, let restoreFailure, let command):
                errorTitle = "The new container did not start, and \(old) could not be put back. Run this command to make it again."
                errorText = Self.friendlyError(failure) + "\n\nPutting it back failed: " + restoreFailure
                restoreCommand = command
            }
        } catch {
            errorTitle = "Nothing was changed."
            errorText = Self.friendlyError(error.localizedDescription)
            state.resourcesChanged()
        }
        progressText = nil
        isWorking = false
    }

    private func finish(newID: String, label: String, recreated: Bool) {
        state.resourcesChanged()
        state.showToast(recreated ? "Recreated \(label)" : "Started \(label)", style: .success)
        isWorking = false
        dismiss()
        if !newID.isEmpty {
            state.focusedContainerID = newID
            state.selection = .containers
        }
    }

    /// Automation (debug builds): `run-field:image=x`, `run-field:port=18555:80`,
    /// `run-field:memory=2G`, `run-go`.
    private func handleDebug(_ name: String, _ value: String) {
        switch name {
        case "run-field":
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            switch parts[0] {
            case "image": pick(parts[1])
            case "memory": memory = parts[1]
            case "mount":
                // mount=volume or mount=folder adds an empty row of that kind.
                mounts.append(RunMountRow(kind: parts[1] == "volume" ? .volume : .bind, source: "", destination: "", readOnly: false))
            case "user": user = parts[1]
            case "port":
                let ends = parts[1].split(separator: ":").map(String.init)
                if ends.count == 2 { ports.append(RunPortRow(host: ends[0], container: ends[1])) }
            default: break
            }
        case "run-go":
            Task { await runNow() }
        default:
            break
        }
    }
}

extension RunSheet {
    /// Adds a plain hint to CLI errors that are hard to read.
    static func friendlyError(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("storage device attachment is invalid") {
            return "A volume can be used by only one running container at a time. Stop the other container or pick another volume.\n\n" + message
        }
        if lower.contains("address already in use") || lower.contains("port is already allocated") {
            return "A Mac port is already in use. Pick another port.\n\n" + message
        }
        return message
    }
}

// MARK: - Rows

private struct RunPortRow: Identifiable, Hashable {
    var id = UUID()
    var address: String?
    var host = ""
    var container = ""
    var proto = "tcp"

    var isEmpty: Bool {
        host.trimmingCharacters(in: .whitespaces).isEmpty && container.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isValid: Bool {
        if isEmpty { return true }
        return mapping != nil
    }

    var mapping: PortMapping? {
        let containerText = container.trimmingCharacters(in: .whitespaces)
        let hostText = host.trimmingCharacters(in: .whitespaces)
        guard let containerPort = Int(containerText), (1...65535).contains(containerPort) else { return nil }
        let hostPort = hostText.isEmpty ? containerPort : (Int(hostText) ?? -1)
        guard (1...65535).contains(hostPort) else { return nil }
        return PortMapping(hostAddress: address, hostPort: hostPort, containerPort: containerPort, proto: proto)
    }
}

private struct RunPairRow: Identifiable, Hashable {
    var id = UUID()
    var key = ""
    var value = ""
}

private struct RunMountRow: Identifiable, Hashable {
    var id = UUID()
    var kind: MountSpec.Kind = .bind
    var source = ""
    var destination = ""
    var readOnly = false
}
