import SwiftUI
import DeckCore

/// Engine Import: find other container engines on this Mac and bring their images over.
struct ImportScreen: View {
    @Environment(AppState.self) private var state

    private var store: ImportStore { ImportStore.shared }

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            enginesStrip
            Divider()
            imagesArea
            Divider()
            bottomBar
        }
        .navigationTitle("Import")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.selectAll(store.images)
                } label: {
                    DeckLabel("Select All", icon: .success)
                }
                .help("Select every image that is not here yet")
                .disabled(store.images.isEmpty || store.isImporting)
                RefreshButton("Scan Again", help: "Look for engines and images again", isBusy: store.isScanning) {
                    await store.scan(client: state.client)
                }
                .disabled(store.isImporting)
            }
        }
        .task {
            if store.lastScan == nil {
                await store.scan(client: state.client)
            }
        }
        .onDeckDebugCommand { name, value in
            // Automation: "import:load-orbstack", "import:cancel-orbstack".
            guard name == "import" else { return }
            let parts = value.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let engine = store.engines.first(where: { $0.kind.rawValue.lowercased() == parts[1] })
            else { return }
            if parts[0] == "load" { store.loadImages(from: engine, state: state) }
            if parts[0] == "cancel" { store.cancelLoad(engine) }
        }
    }

    // MARK: - Engines

    private var enginesStrip: some View {
        Group {
            if store.engines.isEmpty && store.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Docker Desktop, OrbStack, Rancher Desktop, Podman, Colima and Lima")
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                // One row of equal cards that share the width. Narrow windows get a compact card.
                ViewThatFits(in: .horizontal) {
                    engineRow(compact: false)
                    engineRow(compact: true)
                }
            }
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, DS.pad)
        .frame(maxWidth: .infinity)
        .background(DS.surface)
    }

    private func engineRow(compact: Bool) -> some View {
        EqualHeightRow(spacing: 12) {
            ForEach(store.engines) { engine in
                EngineCard(
                    engine: engine,
                    error: store.engineErrors[engine.id],
                    compact: compact,
                    canLoad: store.plan(for: engine) != nil,
                    activity: store.engineActivity[engine.id],
                    isLoading: store.isLoading(engine),
                    loadedCount: store.loadedCount(engine),
                    locked: store.isImporting,
                    onLoad: { store.loadImages(from: engine, state: state) },
                    onCancel: { store.cancelLoad(engine) }
                )
                    .frame(minWidth: compact ? 0 : 160, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Images

    private struct ImageGroup: Identifiable {
        let engine: DetectedEngine
        let images: [EngineImage]
        var id: String { engine.id }
    }

    private var groups: [ImageGroup] {
        store.engines.compactMap { engine in
            let list = store.images(in: engine)
            return list.isEmpty ? nil : ImageGroup(engine: engine, images: list)
        }
    }

    @ViewBuilder
    private var imagesArea: some View {
        if store.images.isEmpty {
            if store.isScanning {
                LoadingView("Reading images", style: .logo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.engines.contains(where: { $0.isRunning }) {
                EmptyState(
                    icon: .images,
                    title: "No images to bring over",
                    message: "The running engines have no tagged images. Untagged images are not shown."
                )
            } else if !store.engines.isEmpty && store.engines.allSatisfy({ $0.state == .notFound }) {
                EmptyState(
                    icon: .importEngines,
                    title: "No other engines found",
                    message: "\(AppConfig.appName) looks for Docker Desktop, OrbStack, Rancher Desktop, Podman and Colima. None are on this Mac.",
                    actionTitle: "Scan Again"
                ) {
                    Task { await store.scan(client: state.client) }
                }
            } else if let stopped = store.engines.first(where: { store.plan(for: $0) != nil }) {
                EmptyState(
                    icon: .importEngines,
                    title: "Your engines are stopped",
                    message: "Load images from a stopped engine. \(AppConfig.appName) starts it in the background and stops it again when done.",
                    actionTitle: store.isLoading(stopped) ? nil : "Load from \(stopped.name)"
                ) {
                    store.loadImages(from: stopped, state: state)
                }
            } else {
                EmptyState(
                    icon: .importEngines,
                    title: "No running engines",
                    message: "Start Docker Desktop, OrbStack, Rancher Desktop, Podman or Colima, then scan again.",
                    actionTitle: "Scan Again"
                ) {
                    Task { await store.scan(client: state.client) }
                }
            }
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.images) { image in
                            ImportImageRow(
                                image: image,
                                isSelected: selectionBinding(for: image),
                                step: store.steps[image.id],
                                locked: store.isImporting
                            )
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func groupHeader(_ group: ImageGroup) -> some View {
        let allSelected = group.images.filter { !$0.alreadyHere }.allSatisfy { store.selection.contains($0.id) }
        return HStack(spacing: 8) {
            Text(group.engine.name).font(.headline)
            if group.engine.state == .stopped {
                Pill("Stopped", tint: DS.warning)
            }
            Text(group.images.count == 1 ? "1 image" : "\(group.images.count) images")
                .foregroundStyle(.secondary)
            Spacer()
            Button(allSelected ? "Select None" : "Select All") {
                if allSelected {
                    store.deselectAll(group.images)
                } else {
                    store.selectAll(group.images)
                }
            }
            .deckLink()
            .disabled(store.isImporting)
        }
    }

    private func selectionBinding(for image: EngineImage) -> Binding<Bool> {
        let id = image.id
        return Binding(
            get: { ImportStore.shared.selection.contains(id) },
            set: { isOn in
                if isOn {
                    ImportStore.shared.selection.insert(id)
                } else {
                    ImportStore.shared.selection.remove(id)
                }
            }
        )
    }

    // MARK: - Bottom bar

    private var rosettaMissing: Bool {
        !(state.report.check(.rosetta)?.state.isPassing ?? false)
    }

    private var bottomBar: some View {
        let selected = store.selectedImages
        let size = selected.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let needsRosetta = rosettaMissing && selected.contains { $0.isAmd64 }
        return VStack(alignment: .leading, spacing: 10) {
            if needsRosetta {
                HStack(spacing: 8) {
                    DeckIcon(.rosetta, size: 14, color: DS.warning)
                    Text("Some selected images are built for Intel (amd64). Install Rosetta to run them on this Mac.")
                        .font(.callout)
                    Spacer()
                    Button("Open Setup") { state.showSetup = true }
                }
                .padding(10)
                .background(DS.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.smallRadius))
            }
            if let error = store.importError {
                ErrorNote(message: error)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.count == 1 ? "1 image selected" : "\(selected.count) images selected")
                        .font(.callout.weight(.medium))
                    Text(selected.isEmpty
                         ? "Images from a registry are pulled again. Local builds are copied."
                         : "About \(Format.bytes(size)). Needs about \(Format.bytes(size * 2)) of free disk space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.client == nil {
                    Text("Set up the container tool first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if store.isImporting {
                    if let activity = store.importActivity {
                        Text(activity.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ProgressView(value: Double(store.currentIndex), total: Double(max(store.totalCount, 1)))
                        .frame(width: 120)
                    Text("\(store.currentIndex) of \(store.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Cancel") { store.cancel() }
                        .disabled(isStopping)
                } else {
                    Button {
                        if let client = state.client {
                            store.startImport(client: client, state: state)
                        }
                    } label: {
                        DeckLabel("Import", icon: .download)
                    }
                    .deckPrimary()
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || state.client == nil || store.isBusyWithEngines)
                }
            }
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 12)
        .background(DS.surfaceSunken)
    }

    /// The engine is being stopped. Cancel has nothing left to stop.
    private var isStopping: Bool {
        if case .stopping? = store.importActivity { return true }
        return false
    }
}

// MARK: - Engine card

struct EngineCard: View {
    let engine: DetectedEngine
    let error: String?
    var compact = false
    /// We can start this stopped engine in the background.
    var canLoad = false
    var activity: EngineActivity?
    var isLoading = false
    /// Images loaded from this stopped engine.
    var loadedCount: Int?
    /// An import is running, so loading waits.
    var locked = false
    var onLoad: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !compact {
                    DeckIcon(.importEngines, size: 14, color: engine.isRunning ? DS.accent : DS.textSecondary)
                }
                Text(engine.name)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            EngineStatePill(state: engine.state)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(error == nil ? DS.textSecondary : DS.danger)
                    .lineLimit(3, reservesSpace: canLoad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if canLoad {
                if isLoading {
                    Button("Cancel", action: onCancel)
                        .controlSize(.small)
                        .disabled(isStopping)
                } else {
                    Button(loadedCount == nil ? "Load Images" : "Load Again", action: onLoad)
                        .controlSize(.small)
                        .disabled(locked)
                        .help("Start \(engine.name) in the background, read its images, then stop it again")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .deckCard(radius: DS.smallRadius + 2)
        .opacity(engine.state == .notFound ? 0.6 : 1)
        .help(error ?? engine.note ?? engine.endpoint?.displayPath ?? engine.name)
    }

    private var isStopping: Bool {
        if case .stopping? = activity { return true }
        return false
    }

    private var detailText: String {
        if let activity, isLoading { return activity.title }
        if let error { return canLoad ? error : "Could not read images" }
        switch engine.state {
        case .running:
            let count = engine.imageCount.map { $0 == 1 ? "1 image" : "\($0) images" } ?? "Images unknown"
            if let version = engine.version { return "\(count), version \(version)" }
            return count
        case .stopped:
            if let loadedCount {
                return loadedCount == 1 ? "Stopped. 1 image loaded." : "Stopped. \(loadedCount) images loaded."
            }
            if canLoad { return "Stopped. \(AppConfig.appName) can start it in the background to import." }
            return "Start it to import images"
        case .notFound:
            return "Not on this Mac"
        }
    }
}

struct EngineStatePill: View {
    let state: EngineState

    var body: some View {
        Pill(state.title, tint: tint)
    }

    private var tint: Color {
        switch state {
        case .running: return DS.running
        case .stopped: return DS.warning
        case .notFound: return DS.stopped
        }
    }
}

// MARK: - Image row

struct ImportImageRow: View {
    let image: EngineImage
    @Binding var isSelected: Bool
    let step: ImportStep?
    let locked: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("Select \(image.reference)", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(locked)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(image.shortName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Pill(image.tag, tint: DS.stopped)
                    if let arch = image.architecture {
                        Pill(arch, tint: image.isAmd64 ? DS.warning : DS.stopped)
                    }
                    if image.alreadyHere {
                        Pill("Already here", tint: DS.running)
                    }
                }
                HStack(spacing: 10) {
                    Text(Format.bytes(image.sizeBytes))
                    Text("Created \(Format.relative(image.createdAt))")
                    Text(image.canPullFromRegistry ? "From a registry" : "Built locally")
                    if !image.alsoIn.isEmpty {
                        Text("Also in \(image.alsoIn.joined(separator: ", "))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let step {
                stepView(step)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func stepView(_ step: ImportStep) -> some View {
        HStack(spacing: 6) {
            if step.isActive {
                if let fraction = step.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if step.isFinished {
                DeckIcon(icon(for: step), size: 13, color: tint(for: step))
            }
            Text(label(for: step))
                .font(.caption)
                .foregroundStyle(tint(for: step))
                .lineLimit(2)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .help(helpText(for: step))
    }

    private func label(for step: ImportStep) -> String {
        switch step {
        case .exporting(let done, let total):
            return total > 0 ? "Copying \(Format.bytes(done)) of \(Format.bytes(total))" : "Copying"
        case .failed:
            return "Failed"
        default:
            return step.title
        }
    }

    private func helpText(for step: ImportStep) -> String {
        switch step {
        case .pulling(let line): return line
        case .failed(let message): return message
        default: return step.title
        }
    }

    private func icon(for step: ImportStep) -> DeckIconName {
        switch step {
        case .done: return .success
        case .failed: return .error
        case .cancelled: return .close
        default: return .waiting
        }
    }

    private func tint(for step: ImportStep) -> Color {
        switch step {
        case .done: return DS.running
        case .failed: return DS.danger
        default: return .secondary
        }
    }
}
