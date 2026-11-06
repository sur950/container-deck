import SwiftUI
import DeckCore

/// Engine Import: find other container engines on this Mac and bring their images over.
struct ImportScreen: View {
    @Environment(AppState.self) private var state

    private var store: ImportStore { ImportStore.shared }

    /// Filters the list by image name or tag, across engines.
    @State private var search = ""
    /// Engine card picked at the top. The list then shows only that engine.
    @State private var focusedEngine: String?

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
        .searchable(text: $search, placement: .toolbar, prompt: "Search images")
        .toolbar {
            ToolbarItemGroup {
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
        // "In Apple's store" follows the real image list: on open and after any image change.
        .task(id: state.resourcesVersion) {
            await store.refreshLocalImages(client: state.client)
        }
        .onDeckDebugCommand { name, value in
            handleDebugCommand(name, value)
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
        let withImages = Set(allGroups.map(\.id))
        let focused = activeFocus
        return EqualHeightRow(spacing: 12) {
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
                    isFocused: focused == engine.id,
                    onFocus: withImages.contains(engine.id) && withImages.count > 1 ? { focus(engine) } : nil,
                    onLoad: { store.loadImages(from: engine, state: state) },
                    onCancel: { store.cancelLoad(engine) }
                )
                    .frame(minWidth: compact ? 0 : 160, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Click a card to show only that engine. Click it again to show all.
    private func focus(_ engine: DetectedEngine) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if focusedEngine == engine.id {
                focusedEngine = nil
            } else {
                focusedEngine = engine.id
                store.setExpanded(engine.id, true)
            }
        }
    }

    // MARK: - Groups

    private struct ImageGroup: Identifiable {
        let engine: DetectedEngine
        let images: [EngineImage]
        var id: String { engine.id }
    }

    /// Every engine with images, before search and focus.
    private var allGroups: [ImageGroup] {
        store.engines.compactMap { engine in
            let list = store.images(in: engine)
            return list.isEmpty ? nil : ImageGroup(engine: engine, images: list)
        }
    }

    /// The focused engine, while it still has images and there is more than one engine to pick from.
    private var activeFocus: String? {
        let groups = allGroups
        guard let focusedEngine, groups.count > 1, groups.contains(where: { $0.id == focusedEngine }) else { return nil }
        return focusedEngine
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Groups as shown: focus and search applied, empty groups dropped.
    private var visibleGroups: [ImageGroup] {
        let focus = activeFocus
        return allGroups.compactMap { group in
            if let focus, group.id != focus { return nil }
            let list = ImportListRules.filter(group.images, query: search)
            return list.isEmpty ? nil : ImageGroup(engine: group.engine, images: list)
        }
    }

    private var defaultOpen: Set<String> {
        ImportListRules.defaultExpanded(allGroups.map { (id: $0.id, count: $0.images.count) })
    }

    /// Search shows every match, so sections are open while searching.
    private func isOpen(_ group: ImageGroup, defaults: Set<String>) -> Bool {
        isSearching || store.isExpanded(group.id, defaults: defaults)
    }

    // MARK: - Images

    @ViewBuilder
    private var imagesArea: some View {
        if store.images.isEmpty {
            emptyArea
        } else {
            VStack(spacing: 0) {
                let groups = visibleGroups
                if groups.isEmpty {
                    EmptyState(
                        icon: .search,
                        title: "No matching images",
                        message: "No image name or tag matches \"\(search)\"."
                    )
                } else {
                    sectionList(groups)
                }
                ListStatusBar(statusText(groups)) {
                    statusActions
                }
            }
        }
    }

    private func sectionList(_ groups: [ImageGroup]) -> some View {
        let defaults = defaultOpen
        return ScrollView {
            VStack(spacing: 12) {
                ForEach(groups) { group in
                    let open = isOpen(group, defaults: defaults)
                    ImportEngineSection(
                        engine: group.engine,
                        images: group.images,
                        isOpen: open,
                        canCollapse: !isSearching,
                        locked: store.isImporting,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.18)) { store.setExpanded(group.id, !open) }
                        }
                    )
                }
            }
            .padding(.horizontal, Layout.pagePadding)
            .padding(.vertical, DS.pad)
            .frame(maxWidth: .infinity)
        }
        .background(DS.surface)
    }

    private func statusText(_ groups: [ImageGroup]) -> String {
        let total = allGroups.reduce(0) { $0 + $1.images.count }
        let engines = allGroups.count
        let shown = groups.reduce(0) { $0 + $1.images.count }
        let here = store.images.filter(\.alreadyHere).count
        var text: String
        if let focus = activeFocus, let group = allGroups.first(where: { $0.id == focus }) {
            text = isSearching
                ? "\(shown) of \(group.images.count) images in \(group.engine.name) match"
                : (group.images.count == 1 ? "1 image in \(group.engine.name)" : "\(group.images.count) images in \(group.engine.name)")
        } else if isSearching {
            text = "\(shown) of \(total) images match"
        } else {
            let images = total == 1 ? "1 image" : "\(total) images"
            text = engines == 1 ? images : "\(images) in \(engines) engines"
        }
        if here > 0 && !isSearching { text += ", \(here) already in Apple's store" }
        return text
    }

    @ViewBuilder
    private var statusActions: some View {
        if activeFocus != nil {
            Button("Show All Engines") {
                withAnimation(.easeInOut(duration: 0.18)) { focusedEngine = nil }
            }
            .deckLink()
        } else if allGroups.count > 1 && !isSearching {
            let defaults = defaultOpen
            let anyClosed = allGroups.contains { !store.isExpanded($0.id, defaults: defaults) }
            Button(anyClosed ? "Expand All" : "Collapse All") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    for group in allGroups { store.setExpanded(group.id, anyClosed) }
                }
            }
            .deckLink()
        }
    }

    @ViewBuilder
    private var emptyArea: some View {
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
                    if let note = store.importNote, !store.isImporting {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                    } else {
                        Text(selected.isEmpty
                             ? "Images from a registry are pulled again. Local builds are copied."
                             : "About \(Format.bytes(size)). Needs about \(Format.bytes(size * 2)) of free disk space.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

    // MARK: - Automation

    /// "import:load-orbstack", "import:cancel-orbstack", "import-search:<text>",
    /// "import-engine:<kind or all>", "import-toggle:<kind>", "import-select:<kind>-<count>",
    /// "import-sections:reset". Debug builds also take "import:sample", "import:sample-steps"
    /// and "import:sample-cancel" (made up images, nothing starts and nothing imports).
    private func handleDebugCommand(_ name: String, _ value: String) {
        func engine(_ kind: String) -> DetectedEngine? {
            store.engines.first { $0.kind.rawValue.lowercased() == kind.lowercased() }
        }
        switch name {
        case "import":
            #if DEBUG
            switch value {
            case "sample": store.showSampleListing(); return
            case "sample-steps": store.showSampleSteps(); return
            case "sample-cancel": store.showSampleCancel(); return
            default: break
            }
            #endif
            let parts = value.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2, let target = engine(parts[1]) else { return }
            if parts[0] == "load" { store.loadImages(from: target, state: state) }
            if parts[0] == "cancel" { store.cancelLoad(target) }
        case "import-search":
            search = value
        case "import-engine":
            if value == "all" { focusedEngine = nil } else if let target = engine(value) { focus(target) }
        case "import-toggle":
            if let target = engine(value) {
                store.setExpanded(target.id, !store.isExpanded(target.id, defaults: defaultOpen))
            }
        case "import-select":
            let parts = value.split(separator: "-").map(String.init)
            if parts.count == 2, let target = engine(parts[0]), let count = Int(parts[1]) {
                store.selectAll(Array(store.images(in: target).prefix(count)))
            }
        case "import-sections":
            if value == "reset" { store.forgetExpanded() }
        default:
            break
        }
    }
}

// MARK: - Engine section

/// One engine's images on a card. The header opens and closes it and picks images.
struct ImportEngineSection: View {
    let engine: DetectedEngine
    let images: [EngineImage]
    let isOpen: Bool
    /// False while searching: every match stays visible.
    let canCollapse: Bool
    let locked: Bool
    var onToggle: () -> Void

    private var store: ImportStore { ImportStore.shared }

    var body: some View {
        let selected = ImportListRules.selectedCount(images, selection: store.selection)
        let selectable = ImportListRules.selectable(images)
        let allSelected = !selectable.isEmpty && selectable.allSatisfy { store.selection.contains($0.id) }
        VStack(spacing: 0) {
            header(selected: selected, allSelected: allSelected, canSelect: !selectable.isEmpty)
            if isOpen {
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        ImportImageRow(
                            image: image,
                            isSelected: selectionBinding(for: image),
                            step: store.steps[image.id],
                            locked: locked
                        )
                        if index < images.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.smallRadius + 2, style: .continuous))
        .deckCard(radius: DS.smallRadius + 2)
    }

    private func header(selected: Int, allSelected: Bool, canSelect: Bool) -> some View {
        let busy = store.isImporting && images.contains { store.steps[$0.id].map { !$0.isFinished } ?? false }
        return HStack(spacing: 12) {
            Button {
                if canCollapse { onToggle() }
            } label: {
                HStack(spacing: 10) {
                    DeckIcon(.chevronRight, size: 11, color: canCollapse ? DS.textSecondary : DS.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 14)
                    Text(engine.name)
                        .font(.headline)
                        .foregroundStyle(DS.textPrimary)
                    Pill(engine.isRunning ? "Running" : "Stopped", tint: engine.isRunning ? DS.running : DS.warning)
                    Text(ImportListRules.countText(selected: selected, total: images.count))
                        .font(.callout.weight(selected > 0 ? .medium : .regular))
                        .monospacedDigit()
                        .foregroundStyle(selected > 0 ? DS.accent : DS.textSecondary)
                    if busy {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(canCollapse ? (isOpen ? "Hide \(engine.name) images" : "Show \(engine.name) images") : "Clear the search to fold sections")
            .accessibilityLabel("\(engine.name), \(isOpen ? "open" : "closed")")

            HStack(spacing: 14) {
                Button("Select All") { store.selectAll(images) }
                    .deckLink()
                    .disabled(locked || allSelected || !canSelect)
                    .help("Select every image here that is not in Apple's store yet")
                Button("Select None") { store.deselectAll(images) }
                    .deckLink()
                    .disabled(locked || selected == 0)
            }
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
    /// The list shows only this engine.
    var isFocused = false
    /// Set when clicking the card can focus the list on this engine.
    var onFocus: (() -> Void)?
    var onLoad: () -> Void = {}
    var onCancel: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !compact {
                    DeckIcon(.importEngines, size: 14, color: engine.isRunning || isFocused ? DS.accent : DS.textSecondary)
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
        .overlay {
            let shape = RoundedRectangle(cornerRadius: DS.smallRadius + 2, style: .continuous)
            if isFocused {
                shape.fill(DS.accentSoft.opacity(0.5)).allowsHitTesting(false)
                shape.strokeBorder(DS.accent, lineWidth: 1.5)
            } else if hovering && onFocus != nil {
                shape.strokeBorder(DS.borderStrong, lineWidth: 1)
            }
        }
        .opacity(engine.state == .notFound ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: DS.smallRadius + 2, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { onFocus?() }
        .help(helpText)
        .accessibilityAddTraits(onFocus != nil ? [.isButton] : [])
        .accessibilityAddTraits(isFocused ? [.isSelected] : [])
    }

    private var helpText: String {
        if onFocus != nil, error == nil {
            return isFocused ? "Show images from every engine" : "Show only \(engine.name) images"
        }
        return error ?? engine.note ?? engine.endpoint?.displayPath ?? engine.name
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

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("Select \(image.reference)", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(DS.accent)
                .disabled(locked)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(image.shortName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Pill(image.tag, tint: DS.stopped)
                    if let arch = image.architecture {
                        Pill(arch, tint: image.isAmd64 ? DS.warning : DS.stopped)
                    }
                }
                HStack(spacing: 10) {
                    Text(Format.bytes(image.sizeBytes))
                    if let created = image.createdAt {
                        Text("Created \(Format.relative(created))")
                    }
                    Text(image.canPullFromRegistry ? "From a registry" : "Built locally")
                    if !image.alsoIn.isEmpty {
                        Text("Also in \(image.alsoIn.joined(separator: ", "))")
                    }
                }
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                if case .failed(let message) = step {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(DS.danger)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(message)
                }
            }
            Spacer(minLength: 8)
            if let step {
                stepView(step)
            } else if image.alreadyHere {
                Text("In Apple's store")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .help("This tag is already in Apple's container. Select it to bring a fresh copy.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(hovering && !locked ? DS.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if !locked { isSelected.toggle() }
        }
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
                .lineLimit(1)
                .fixedSize()
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
        default: return DS.textSecondary
        }
    }
}
