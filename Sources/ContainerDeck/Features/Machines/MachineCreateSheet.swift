import SwiftUI
import AppKit
import DeckCore

/// Sheet that creates a container machine.
struct MachineCreateSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// AppKit menus keep the old colors after a Light or Dark switch. They rebuild with `.id(colorScheme)`.
    @Environment(\.colorScheme) private var colorScheme

    let onCreated: (String) -> Void

    @State private var image = MachineImages.recommended
    @State private var name = ""
    @State private var cpus = MachineDefaults.defaultCPUs
    @State private var memoryGB = MachineDefaults.defaultMemoryGB
    @State private var homeMount = "rw"
    @State private var boot = true
    @State private var makeDefault = false
    @State private var creating = false
    @State private var failure: String?
    @State private var showSuggestions = false
    // Advanced options
    @State private var platform = ""
    @State private var virtualization = false
    @State private var kernelPath = ""
    @State private var accountUser = ""
    @State private var accountUID = ""
    @State private var accountGID = ""
    @State private var accountHome = ""
    @State private var showAdvanced = false
    @State private var initCheck: MachineInitCheck.Result?
    @State private var checkedImage = ""
    @State private var checking = false

    init(onCreated: @escaping (String) -> Void) {
        self.onCreated = onCreated
    }

    var body: some View {
        SheetScaffold(
            "New Machine",
            subtitle: "A Linux VM with your Mac user and home folder.",
            icon: .machines,
            width: 580
        ) {
            formBody
                .disabled(creating)
            if let failure {
                ErrorNote(message: failure)
            }
        } footer: {
            footer
        }
        .frame(height: 680)
        .onChange(of: trimmedImage) { _, _ in
            if trimmedImage != checkedImage { initCheck = nil }
        }
        .onDeckDebugCommand { name, value in
            // Automation only: machine-advanced:on opens the extra options.
            if name == "machine-advanced" { showAdvanced = value != "off" }
            if name == "machine-check" { runCheck() }
        }
    }

    @ViewBuilder
    private var formBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeckFormGroup("Image") {
                DeckFormRow("Image") {
                    HStack(spacing: 8) {
                        TextField("Image", text: $image, prompt: Text(MachineImages.recommended))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                        Button {
                            showSuggestions.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Text("Suggestions")
                                DeckIcon(.chevronDown, size: 9, color: DS.accent)
                            }
                        }
                        .buttonStyle(SoftAccentButtonStyle())
                        .fixedSize()
                        .popover(isPresented: $showSuggestions, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(MachineImages.suggestions, id: \.self) { suggestion in
                                    MachineSuggestionRow(text: suggestion, isCurrent: suggestion == trimmedImage) {
                                        image = suggestion
                                        showSuggestions = false
                                    }
                                }
                            }
                            .padding(6)
                            .frame(minWidth: 220)
                        }
                    }
                    DeckFormNote("The image needs an init system at /sbin/init. \(MachineImages.recommended) works well. App images such as nginx or plain ubuntu do not have one.")
                    initCheckRow
                }
                DeckFormRow("Platform") {
                    Picker("Platform", selection: $platform) {
                        Text("Match this Mac").tag("")
                        Text("linux/arm64").tag("linux/arm64")
                        Text("linux/amd64").tag("linux/amd64")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .id(colorScheme)
                    if platform == "linux/amd64" {
                        DeckFormNote("amd64 machines run with Rosetta and are slower.")
                    }
                }
            }

            DeckFormGroup("Machine") {
                DeckFormRow("Name") {
                    TextField("Name", text: $name, prompt: Text(suggestedName))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    if !nameIsValid {
                        Text("Use letters, numbers, dots, dashes and underscores. Start with a letter or number.")
                            .font(.caption)
                            .foregroundStyle(DS.danger)
                    }
                }
                DeckFormRow("CPUs") {
                    stepperRow(value: $cpus, range: 1...MachineDefaults.maxCPUs, text: "\(cpus) of \(MachineDefaults.maxCPUs)")
                }
                DeckFormRow("Memory") {
                    stepperRow(value: $memoryGB, range: 1...MachineDefaults.maxMemoryGB, text: "\(memoryGB) GB of \(MachineDefaults.maxMemoryGB) GB")
                }
                DeckFormRow("Home folder") {
                    Picker("Home folder", selection: $homeMount) {
                        Text("Read and write").tag("rw")
                        Text("Read only").tag("ro")
                        Text("None").tag("none")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                DeckFormRow("Options") {
                    Toggle("Boot after create", isOn: $boot)
                    Toggle("Make it the default machine", isOn: $makeDefault)
                }
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                advancedGroups
                    .padding(.top, 8)
            } label: {
                Text("Virtualisation, kernel and account")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.textSecondary)
            }

            ResourceCommandHint(createArguments)
        }
    }

    @ViewBuilder
    private var advancedGroups: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeckFormGroup("Virtualisation") {
                DeckFormRow("Nested") {
                    Toggle("Run VMs inside the machine (KVM)", isOn: $virtualization)
                        .disabled(!MachineHost.supportsNestedVirtualization())
                    DeckFormNote(MachineHost.supportsNestedVirtualization()
                        ? "Needs a kernel built with KVM. The default kernel may not have it, so pick one below."
                        : "Needs an M3 or newer chip. This Mac has \(HostFacts.chip).")
                }
                DeckFormRow("Kernel") {
                    HStack(spacing: 8) {
                        TextField("Kernel", text: $kernelPath, prompt: Text("System kernel"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                        Button("Choose…") { chooseKernel() }
                    }
                    DeckFormNote("A Linux kernel binary such as vmlinux. Leave empty to use the system kernel.")
                }
            }
            DeckFormGroup("Account") {
                DeckFormRow("User") {
                    TextField("User", text: $accountUser, prompt: Text(NSUserName()))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    DeckFormNote("Name of your account in the machine. Empty uses your Mac user.")
                }
                DeckFormRow("IDs") {
                    HStack(spacing: 8) {
                        TextField("UID", text: $accountUID, prompt: Text("UID \(getuid())"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 110)
                        TextField("GID", text: $accountGID, prompt: Text("GID \(getgid())"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 110)
                        Spacer(minLength: 0)
                    }
                    DeckFormNote("Keep them the same as on your Mac so files in your home folder keep their owner.")
                }
                DeckFormRow("Home") {
                    TextField("Home", text: $accountHome, prompt: Text("/home/\(effectiveUser)"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }
            ForEach(extras.problems, id: \.self) { problem in
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(DS.danger)
            }
            if !idsAreValid {
                Text("UID and GID must be whole numbers.")
                    .font(.caption)
                    .foregroundStyle(DS.danger)
            }
        }
    }

    @ViewBuilder
    private var initCheckRow: some View {
        HStack(spacing: 8) {
            Button {
                runCheck()
            } label: {
                DeckLabel(checking ? "Checking" : "Check Image", icon: .checklist)
            }
            .buttonStyle(SoftAccentButtonStyle())
            .disabled(checking || trimmedImage.isEmpty || state.client == nil)
            .help("Starts a throwaway container to look for /sbin/init. Pulls the image when needed.")
            if checking {
                ProgressView().controlSize(.small)
            } else if let initCheck, checkedImage == trimmedImage {
                DeckIcon(initCheck == .ok ? .success : (initCheck.canCreate ? .warning : .error), size: 13,
                         color: initCheck == .ok ? DS.running : (initCheck.canCreate ? DS.warning : DS.danger))
                Text(initCheck.title)
                    .font(.callout.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        if let initCheck, checkedImage == trimmedImage, initCheck != .ok {
            Text(initCheck.message)
                .font(.caption)
                .foregroundStyle(initCheck.canCreate ? DS.textSecondary : DS.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if creating {
            ProgressView().controlSize(.small)
            Text(checking ? "Checking the image for an init system." : (boot ? "Getting the image and booting. This can take a minute." : "Getting the image. This can take a minute."))
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(2)
        }
        Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
            .disabled(creating)
        Button("Create") { create() }
            .deckPrimary()
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate || creating)
    }

    private func stepperRow(value: Binding<Int>, range: ClosedRange<Int>, text: String) -> some View {
        HStack(spacing: 8) {
            Stepper(value: value, in: range) {
                EmptyView()
            }
            .labelsHidden()
            Text(text)
                .monospacedDigit()
                .foregroundStyle(DS.textSecondary)
        }
    }

    private var createArguments: [String] {
        state.client?.createMachineArguments(options, extras: extras) ?? []
    }

    // MARK: - Logic

    private var trimmedImage: String { image.trimmingCharacters(in: .whitespaces) }

    private var suggestedName: String { MachineImages.suggestedName(for: trimmedImage.isEmpty ? MachineImages.recommended : trimmedImage) }

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? suggestedName : typed
    }

    private var nameIsValid: Bool { MachineImages.isValidName(effectiveName) }

    private var canCreate: Bool {
        !trimmedImage.isEmpty && nameIsValid && state.client != nil && extras.problems.isEmpty && idsAreValid
            && (initCheck?.canCreate ?? true || checkedImage != trimmedImage)
    }

    private var effectiveUser: String {
        let typed = accountUser.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? NSUserName() : typed
    }

    private var idsAreValid: Bool {
        [accountUID, accountGID].allSatisfy { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || Int(trimmed) != nil
        }
    }

    private var extras: MachineCreateExtras {
        MachineCreateExtras(
            virtualization: virtualization,
            kernelPath: kernelPath,
            user: accountUser,
            uid: Int(accountUID.trimmingCharacters(in: .whitespaces)),
            gid: Int(accountGID.trimmingCharacters(in: .whitespaces)),
            home: accountHome,
            platform: platform.isEmpty ? nil : platform,
            setDefault: makeDefault
        )
    }

    private var options: MachineOptions {
        MachineOptions(
            name: effectiveName,
            image: trimmedImage,
            cpus: cpus,
            memory: "\(memoryGB)G",
            homeMount: homeMount,
            boot: boot
        )
    }

    private func chooseKernel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Kernel"
        panel.message = "Pick a Linux kernel binary, such as vmlinux."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            kernelPath = url.path
        }
    }

    private func runCheck() {
        guard let client = state.client, !trimmedImage.isEmpty, !checking else { return }
        let image = trimmedImage
        let chosenPlatform = platform.isEmpty ? nil : platform
        checking = true
        Task {
            let result = await client.checkMachineImage(image, platform: chosenPlatform)
            checkedImage = image
            initCheck = result
            checking = false
        }
    }

    private func create() {
        guard let client = state.client, canCreate else { return }
        let request = options
        let requestExtras = extras
        let image = trimmedImage
        creating = true
        failure = nil
        Task {
            // Check for an init system first, unless that already happened for this image.
            if checkedImage != image || initCheck == nil {
                checking = true
                let result = await client.checkMachineImage(image, platform: requestExtras.platform)
                checking = false
                checkedImage = image
                initCheck = result
                if !result.canCreate {
                    failure = result.message
                    creating = false
                    return
                }
            }
            do {
                try await client.createMachine(request, extras: requestExtras)
                state.resourcesChanged()
                state.showToast("Machine \(request.name) is ready.", style: .success)
                onCreated(request.name)
                dismiss()
            } catch {
                failure = error.localizedDescription
                DiagnosticsLog.shared.record(error, source: "Machines")
            }
            creating = false
        }
    }
}

/// One image in the Suggestions popover.
private struct MachineSuggestionRow: View {
    let text: String
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(text)
                    .font(.callout.monospaced())
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: 8)
                if isCurrent {
                    DeckIcon(.success, size: 13, color: DS.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? DS.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
