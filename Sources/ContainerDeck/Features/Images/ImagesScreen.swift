import SwiftUI
import AppKit
import DeckCore

/// Actions offered for one image, from a row menu or the detail pane.
enum ImageRowAction {
    case run, pullLatest, tag, save, delete, copyReference
}

/// Images: On this Mac (list, search, sort, details and actions) and Explore
/// (search Docker Hub, Quay.io and signed in registries).
struct ImagesScreen: View {
    @Environment(AppState.self) private var state

    /// Cluster nodes, read here on 1.7, where the shared feed has none. They count as image users.
    @State private var clusterNodes: [ContainerSummary] = []
    @State private var images: [ImageSummary] = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ImageSummary.shortName)]
    @State private var selection: ImageSummary.ID?
    /// The table takes keyboard focus on open and after a jump to an image.
    @FocusState private var tableFocused: Bool
    @State private var activeSheet: ImagesSheet?
    @State private var activeAlert: ImagesAlert?
    @State private var showPrune = false
    @AppStorage("imagesDetailWidth") private var detailWidth: Double = 380
    @AppStorage(ImagesSection.storageKey) private var sectionRaw = ImagesSection.local.rawValue
    @State private var sequencer = PollSequencer()

    private var section: ImagesSection { ImagesSection(rawValue: sectionRaw) ?? .local }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            Group {
                switch section {
                case .local:
                    content
                        .searchable(text: $search, placement: .toolbar, prompt: "Search images")
                case .explore:
                    ImageExploreView(localImages: images)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .navigationTitle("Images")
        .toolbar { toolbarContent }
        .task(id: state.resourcesVersion) { await load() }
        .autoRefresh { await load() }
        .onChange(of: BackgroundServices.shared.containersVersion) { _, _ in
            publish(withUsers(images))
        }
        .onChange(of: state.focusedImageRef) { _, ref in
            // Jumping to an image shows the list it is in.
            if ref != nil, section != .local { sectionRaw = ImagesSection.local.rawValue }
            applyFocus()
        }
        .onAppear {
            if state.focusedImageRef != nil { sectionRaw = ImagesSection.local.rawValue }
        }
        .sheet(item: $activeSheet) { item in
            sheetView(item)
                .environment(state)
        }
        .alert(alertTitle, isPresented: alertShown, presenting: activeAlert) { item in
            alertActions(item)
        } message: { item in
            Text(alertMessage(item))
        }
        .onDeckDebugCommand { name, value in
            if name == "images-section", let value = ImagesSection(rawValue: value) {
                sectionRaw = value.rawValue
                return
            }
            guard name == "images" else { return }
            switch value {
            case "pull": activeSheet = .pull(reference: "", platform: nil, autoStart: false)
            case "tag": if let first = images.first { activeSheet = .tag(first.reference) }
            case "prune": showPrune = true
            default: break
            }
        }
        .confirmationDialog("Remove unused images?", isPresented: $showPrune, titleVisibility: .visible) {
            Button("Remove Untagged Images") { prune(all: false) }
            Button("Remove All Unused Images", role: .destructive) { prune(all: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Untagged images have no name. Unused images are not used by any container. Images in use are kept.")
        }
    }

    // MARK: - Content

    /// On this Mac or Explore, like the other screens with sections.
    private var topBar: some View {
        let binding = Binding(get: { section }, set: { sectionRaw = $0.rawValue })
        return HStack(spacing: 12) {
            SegmentedFilter(selection: binding, options: ImagesSection.allCases, label: \.title) { option in
                option == .local && hasLoaded ? images.count : nil
            }
            if section == .explore {
                Divider().frame(height: 18)
                ExploreFilterBar()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 10)
        .background(DS.surface)
    }

    @ViewBuilder
    private var content: some View {
        if state.client == nil {
            ResourceToolMissing(icon: .images)
        } else if !hasLoaded && isLoading {
            LoadingView("Loading images", style: .logo)
        } else if let loadError, images.isEmpty {
            EmptyState(icon: .error, title: "Could not load images", message: loadError, actionTitle: "Try Again") {
                Task { await load() }
            }
        } else if images.isEmpty {
            EmptyState(
                icon: .images,
                title: "No images yet",
                message: "Pull an image from a registry or build one from a Dockerfile.",
                actionTitle: "Pull Image"
            ) {
                activeSheet = .pull(reference: "", platform: nil, autoStart: false)
            }
        } else {
            // SwiftUI row with a drag handle, not HSplitView: AppKit split views ignore the
            // top safe area, so their panes and divider ran up into the toolbar.
            GeometryReader { geo in
                let detail = clampedDetailWidth(total: geo.size.width)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        table
                        footer
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if selectedImage != nil {
                        SplitHandle(width: $detailWidth, total: geo.size.width, minList: Self.minListWidth)
                        inspectorContent
                            .frame(width: detail)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }

    /// The table needs this much room to show every column without cutting one.
    static let minListWidth: CGFloat = 630
    static let detailRange: ClosedRange<CGFloat> = 320...560

    private func clampedDetailWidth(total: CGFloat) -> CGFloat {
        let roomForDetail = total - Self.minListWidth - 1
        let upper = max(Self.detailRange.lowerBound, min(Self.detailRange.upperBound, roomForDetail))
        return min(max(detailWidth, Self.detailRange.lowerBound), upper)
    }

    private var selectedImage: ImageSummary? {
        guard let id = selection else { return nil }
        return images.first { $0.id == id }
    }

    private var table: some View {
        Table(visibleImages, selection: $selection, sortOrder: $sortOrder) {
            // Ideal = min: the table starts compact (fits next to the detail pane at the
            // smallest window) and the columns stretch to fill any extra width.
            TableColumn("Name", value: \.shortName) { image in
                ImageNameCell(image: image)
            }
            .width(min: 150, ideal: 150)

            TableColumn("Tag", value: \.tag) { image in
                Text(image.tag)
                    .deckSecondaryText()
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 60)

            TableColumn("Size", value: \.sizeBytes) { image in
                Text(Format.bytes(image.sizeBytes)).monospacedDigit()
            }
            .width(min: 64, ideal: 64)

            TableColumn("Platforms") { image in
                Text(Self.platformText(image.platforms))
                    .deckSecondaryText()
                    .lineLimit(1)
                    .help(image.platforms.joined(separator: ", "))
            }
            .width(min: 84, ideal: 84)

            TableColumn("Created", value: \.createdSortKey) { image in
                Text(Format.relative(image.createdAt)).deckSecondaryText()
            }
            .width(min: 70, ideal: 70)

            TableColumn("Used By", value: \.usedByCount) { image in
                ImageUsedByCell(names: image.usedBy)
            }
            .width(min: 100, ideal: 100)
        }
        // No table background of its own: it would run up under the transparent toolbar
        // on the list side only, splitting the toolbar strip in two at the detail pane.
        .scrollContentBackground(.hidden)
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .focused($tableFocused)
        .onAppear { tableFocused = true }
        .contextMenu(forSelectionType: ImageSummary.ID.self) { ids in
            if let id = ids.first, let image = images.first(where: { $0.id == id }) {
                rowMenu(image)
            }
        } primaryAction: { ids in
            selection = ids.first
        }
    }

    private var footer: some View {
        ListStatusBar(summaryText) {
            if let loadError {
                ResourceErrorText(loadError).lineLimit(1)
            } else if isLoading {
                ProgressView().controlSize(.small)
            }
            ResourceCommandHint(["image", "list"])
                .frame(maxWidth: 260)
        }
    }

    @ViewBuilder
    private func rowMenu(_ image: ImageSummary) -> some View {
        Button { perform(.run, on: image) } label: { DeckLabel("Run", icon: .play) }
        Button { perform(.pullLatest, on: image) } label: { DeckLabel("Pull Latest", icon: .pull) }
        Button { perform(.tag, on: image) } label: { DeckLabel("Tag…", icon: .tag) }
        Button { perform(.save, on: image) } label: { DeckLabel("Save to File…", icon: .export) }
        Button { perform(.copyReference, on: image) } label: { DeckLabel("Copy Name", icon: .copy) }
        Divider()
        Button(role: .destructive) { perform(.delete, on: image) } label: { DeckLabel("Delete…", icon: .trash) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                activeSheet = .pull(reference: "", platform: nil, autoStart: false)
            } label: {
                DeckLabel("Pull", icon: .pull)
            }
            .help("Pull an image from a registry")

            Button {
                state.buildRequest = BuildRequest()
            } label: {
                DeckLabel("Build", icon: .build)
            }
            .help("Build an image from a Dockerfile")

            Button {
                showPrune = true
            } label: {
                DeckLabel("Prune", icon: .prune)
            }
            .help("Remove unused images")

            RefreshButton(help: section == .local ? "Reload images" : "Search again",
                          isBusy: section == .local ? isLoading : ImageExploreStore.shared.isSearching) {
                if section == .local {
                    await load()
                } else {
                    await ImageExploreStore.shared.loadSources(client: state.client, force: true)
                    await ImageExploreStore.shared.run()
                }
            }
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let id = selection, let image = images.first(where: { $0.id == id }) {
            ImageDetailPane(image: image) { action in
                perform(action, on: image)
            }
        } else {
            EmptyState(icon: .images, title: "No image selected", message: "Pick an image to see its details.")
                .background(DS.surface, ignoresSafeAreaEdges: [])
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: ImagesSheet) -> some View {
        switch sheet {
        case .pull(let reference, let platform, let autoStart):
            ImagesPullSheet(reference: reference, platform: platform, autoStart: autoStart)
        case .tag(let reference):
            ImagesTagSheet(source: reference)
        }
    }

    // MARK: - Derived values

    private var visibleImages: [ImageSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? images : images.filter { image in
            image.reference.lowercased().contains(query)
                || image.usedBy.contains { $0.lowercased().contains(query) }
        }
        return filtered.sorted(using: sortOrder)
    }

    private var summaryText: String {
        let total = images.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let count = images.count == 1 ? "1 image" : "\(images.count) images"
        return "\(count), \(Format.bytes(total))"
    }

    private var alertShown: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { shown in if !shown { activeAlert = nil } }
        )
    }

    private var alertTitle: String {
        switch activeAlert {
        case .delete(let image): return "Delete \(image.shortName):\(image.tag)?"
        case .inUse: return "This image is in use"
        case .none: return ""
        }
    }

    private func alertMessage(_ item: ImagesAlert) -> String {
        switch item {
        case .delete:
            return "The image is removed from this Mac. You can pull it again later."
        case .inUse(let image):
            return "Used by \(image.usedBy.joined(separator: ", ")). Delete those containers first."
        }
    }

    @ViewBuilder
    private func alertActions(_ item: ImagesAlert) -> some View {
        switch item {
        case .delete(let image):
            Button("Delete", role: .destructive) { delete(image) }
            Button("Cancel", role: .cancel) {}
        case .inUse:
            Button("OK", role: .cancel) {}
        }
    }

    /// nil (this Mac) when the image has the host platform or none is known.
    /// amd64 only images pull as amd64, since the host platform would not match.
    static func pullPlatform(for image: ImageSummary) -> String? {
        let host = ImagePlatform.host
        let platforms = image.platforms
        if platforms.isEmpty || platforms.contains(where: { $0 == host || $0.hasPrefix(host + "/") }) {
            return nil
        }
        return platforms.first { $0 == "linux/amd64" } ?? platforms.first
    }

    static func platformText(_ platforms: [String]) -> String {
        guard !platforms.isEmpty else { return "Unknown" }
        return platforms.map { ResourceUsage.shortPlatform($0) }.joined(separator: ", ")
    }

    // MARK: - Actions

    private func perform(_ action: ImageRowAction, on image: ImageSummary) {
        switch action {
        case .run:
            state.runRequest = RunRequest(options: RunOptions(image: image.reference))
        case .pullLatest:
            activeSheet = .pull(reference: image.reference, platform: Self.pullPlatform(for: image), autoStart: true)
        case .tag:
            activeSheet = .tag(image.reference)
        case .save:
            save(image)
        case .copyReference:
            ResourceUsage.copyToPasteboard(image.reference)
            state.showToast("Copied \(image.reference)")
        case .delete:
            activeAlert = image.usedBy.isEmpty ? .delete(image) : .inUse(image)
        }
    }

    /// `image list` only. Which containers use an image comes from the shared container feed.
    private func load() async {
        guard let client = state.client else { return }
        let token = sequencer.begin()
        isLoading = true
        do {
            let list = try await client.listImages()
            // 1.7 hides cluster nodes from the shared feed, so read them here: they use kindest/node.
            let nodes = await client.platformFeatures().listHidesClusterNodes ? ((try? await client.listClusterNodes()) ?? []) : []
            // An older load that finishes late must not replace a newer one.
            guard sequencer.accept(token) else { return }
            clusterNodes = nodes
            publish(withUsers(list))
            loadError = nil
            if let id = selection, !list.contains(where: { $0.id == id }) {
                selection = nil
            }
        } catch {
            if !Task.isCancelled, sequencer.accept(token) {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
        hasLoaded = true
        applyFocus()
    }

    private func withUsers(_ list: [ImageSummary]) -> [ImageSummary] {
        let feed = BackgroundServices.shared.visibleContainers
        let known = Set(feed.map(\.id))
        let real = feed + clusterNodes.filter { !known.contains($0.id) }
        return list.map { image in
            var copy = image
            copy.usedBy = real
                .filter { container in
                    ImageRefMatch.same(container.image, image.reference)
                        || (!image.digest.isEmpty && container.image.contains(image.digest))
                        || ImageUsage.uses(container.image, image: image)
                }
                .map(\.name)
            return copy
        }
    }

    /// Only real changes reach the table, animated.
    private func publish(_ list: [ImageSummary]) {
        guard list != images else { return }
        withAnimation(.easeInOut(duration: 0.25)) { images = list }
    }

    private func applyFocus() {
        guard let ref = state.focusedImageRef, hasLoaded else { return }
        if let match = images.first(where: { $0.reference == ref || ImageRefMatch.same($0.reference, ref) }) {
            search = ""
            selection = match.id
            tableFocused = true
            state.focusedImageRef = nil
        } else if !isLoading {
            // Not here yet. Keep the request until the next reload, then give up.
            state.focusedImageRef = nil
        }
    }

    private func save(_ image: ImageSummary) {
        guard let client = state.client else { return }
        let panel = NSSavePanel()
        panel.title = "Save Image"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName(for: image) + ".tar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.showToast("Saving \(image.shortName)…")
        Task {
            do {
                try await client.saveImage(image.reference, to: url)
                state.showToast("Saved \(url.lastPathComponent)", style: .success)
            } catch {
                state.showError(error)
            }
        }
    }

    static func fileName(for image: ImageSummary) -> String {
        let raw = "\(image.shortName)-\(image.tag)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") }
        return String(scalars)
    }

    private func delete(_ image: ImageSummary) {
        guard let client = state.client else { return }
        Task {
            do {
                try await client.deleteImage(image.reference)
                if selection == image.id { selection = nil }
                state.showToast("Deleted \(image.shortName):\(image.tag)", style: .success)
                state.resourcesChanged()
            } catch {
                state.showError(error)
            }
        }
    }

    private func prune(all: Bool) {
        guard let client = state.client else { return }
        Task {
            do {
                try await client.pruneImages(all: all)
                state.showToast(all ? "Removed unused images" : "Removed untagged images", style: .success)
                state.resourcesChanged()
            } catch {
                state.showError(error)
            }
        }
    }
}

private enum ImagesSheet: Identifiable {
    case pull(reference: String, platform: String?, autoStart: Bool)
    case tag(String)

    var id: String {
        switch self {
        case .pull(let reference, _, _): return "pull:" + reference
        case .tag(let reference): return "tag:" + reference
        }
    }
}

private enum ImagesAlert {
    case delete(ImageSummary)
    case inUse(ImageSummary)
}

fileprivate extension ImageSummary {
    var createdSortKey: Date { createdAt ?? .distantPast }
    var usedByCount: Int { usedBy.count }
}

private struct ImageNameCell: View {
    let image: ImageSummary

    var body: some View {
        HStack(spacing: 9) {
            IconBadge(.images, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(image.shortName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(image.reference)
                    .font(.caption2)
                    .deckSecondaryText()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ImageUsedByCell: View {
    let names: [String]

    private var label: String {
        names.count == 1 ? "In use" : "\(names.count) containers"
    }

    var body: some View {
        if names.isEmpty {
            Text("Not used").deckTertiaryText()
        } else {
            Pill(label, tint: DS.running)
                .help("Used by " + names.joined(separator: ", "))
        }
    }
}


/// Thin divider you can drag to resize the detail pane. Stays below the toolbar.
private struct SplitHandle: View {
    @Binding var width: Double
    let total: CGFloat
    let minList: CGFloat
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(DS.border)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: .trailing))
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                let proposed = start - value.translation.width
                                let upper = max(320, min(560, Double(total - minList - 1)))
                                width = min(max(proposed, 320), upper)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
