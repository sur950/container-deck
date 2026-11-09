import SwiftUI
import DeckCore

/// Images, Explore: search Docker Hub, Quay.io and every signed in registry at
/// once, look up an exact name anywhere, see tags, then pull or run.
struct ImageExploreView: View {
    @Environment(AppState.self) private var state
    /// Images on this Mac, for the "On this Mac" pills.
    let localImages: [ImageSummary]

    @State private var openRepository: RegistryImage?
    @State private var registryReference = ""
    @State private var pullRequest: ExplorePullRequest?

    private var store: ImageExploreStore { ImageExploreStore.shared }

    static let suggestions = ["nginx", "postgres", "redis", "python", "node", "alpine"]

    private var localRepositories: Set<String> {
        Set(localImages.map { ImageRefMatch.repository($0.reference) })
    }

    private var localReferences: Set<String> {
        Set(localImages.map { ImageRefMatch.normalize($0.reference) })
    }

    var body: some View {
        @Bindable var store = store
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.surface, ignoresSafeAreaEdges: [])
            .searchable(text: $store.query, placement: .toolbar, prompt: "Search registries")
            .task(id: store.query) { await store.searchAfterPause() }
            .task { await store.loadSources(client: state.client) }
            .task { await store.loadPopular() }
            .onChange(of: store.filter) { _, _ in
                Task { await store.run() }
            }
            .sheet(item: $pullRequest) { request in
                ImagesPullSheet(reference: request.reference, autoStart: true)
                    .environment(state)
                    .tint(DS.accent)
            }
            .sheet(item: $openRepository) { repository in
                ImageTagsSheet(repository: repository, localReferences: localReferences)
                    .environment(state)
            }
            .onDeckDebugCommand { name, value in
                switch name {
                case "explore-search":
                    store.query = value
                case "explore-filter":
                    store.filter = store.filterOptions.contains(value) ? value : ImageExploreStore.allFilter
                case "explore-registry":
                    registryReference = value
                case "explore-pull":
                    pullRequest = ExplorePullRequest(reference: value)
                case "explore-open":
                    openRepository = (store.merged + store.popular).first { $0.id == value || $0.reference == value }
                        ?? Self.image(named: value)
                case "explore-close":
                    openRepository = nil
                    pullRequest = nil
                case "explore-sources":
                    Task { await store.loadSources(client: state.client, force: true) }
                #if DEBUG
                case "explore-add-source":
                    store.addDebugSource(value)
                #endif
                default:
                    break
                }
            }
    }

    /// An image for a typed name, for links and checks.
    static func image(named value: String) -> RegistryImage {
        let parsed = PullReference.parse(value)
        let host = parsed?.registry ?? "docker.io"
        let path = parsed?.repository ?? value
        return RegistryImage(registry: host, repository: path, isOfficial: host == "docker.io" && !path.contains("/"))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.trimmedQuery.isEmpty {
            welcome
        } else if let name = store.lookupName {
            lookupPage(name)
        } else if store.isSearching && store.merged.isEmpty {
            LoadingView("Searching registries", style: .logo)
        } else {
            resultPage
        }
    }

    private var welcome: some View {
        DeckPage(maxWidth: 900) {
            welcomeHeader
            ExploreRegistryPullCard(reference: $registryReference) { reference in
                pullRequest = ExplorePullRequest(reference: reference)
            }
            if store.popular.isEmpty {
                // Keep the page balanced while the list loads.
                repositoryCard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading popular images").foregroundStyle(DS.textSecondary)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 80)
                }
            } else {
                SectionHeader("Popular official images", subtitle: "The most pulled images on Docker Hub.")
                repositoryList(store.popular)
            }
        }
    }

    private var sourceNames: String {
        let names = store.sources.map(\.displayName)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    private var welcomeHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            IconBadge(.explore, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text("Search every registry").font(.title2.weight(.semibold))
                Text("Searches \(sourceNames). Find an image, check its tags, then pull or run it.")
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("Try")
                        .font(.callout)
                        .foregroundStyle(DS.textTertiary)
                    ForEach(Self.suggestions, id: \.self) { name in
                        ExploreChip(title: name) { store.query = name }
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckCard()
    }

    // MARK: - Lookup

    private func lookupPage(_ name: String) -> some View {
        DeckPage(maxWidth: 900) {
            SectionHeader("Look up by name", subtitle: "Shows the tags of one image, from any registry.")
            ExploreLookupCard(
                name: name,
                lookup: store.lookup,
                isDownloaded: { localRepositories.contains(ImageRefMatch.repository($0.reference)) },
                onTags: { openRepository = $0 },
                onPull: { pullRequest = ExplorePullRequest(reference: $0) },
                onRetry: { Task { await store.run() } }
            )
            // Only the registry being looked up matters here.
            let host = PullReference.parse(name)?.registry.map { DockerConfigFile.registryHost(from: $0) }
            let related = store.notices.filter { $0.source.host == host }
            if !related.isEmpty {
                noticeCard(related)
            }
        }
    }

    // MARK: - Results

    private var resultPage: some View {
        DeckPage(maxWidth: 900) {
            SectionHeader("Results for \"\(store.searchedQuery)\"", subtitle: resultSubtitle) {
                if store.isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            if !store.notices.isEmpty {
                noticeCard(store.notices)
            }
            if store.visible.isEmpty {
                repositoryCard {
                    VStack(spacing: 6) {
                        DeckIcon(.search, size: 22, color: DS.textTertiary)
                        Text("No results").font(.headline)
                        Text(emptyMessage)
                            .font(.callout)
                            .foregroundStyle(DS.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            } else {
                repositoryList(store.visible, hasMore: store.hasMore)
            }
        }
    }

    private var resultSubtitle: String {
        let count = store.visible.count
        let text = count == 1 ? "1 image" : "\(count) images"
        let where_ = store.filter == ImageExploreStore.allFilter ? "" : " on \(store.filterTitle(store.filter))"
        return store.hasMore ? "Showing \(text)\(where_). Scroll for more." : "\(text)\(where_)"
    }

    private var emptyMessage: String {
        if store.filter == ImageExploreStore.allFilter {
            return "No registry has an image matching \"\(store.searchedQuery)\"."
        }
        return "Nothing on \(store.filterTitle(store.filter)) matches \"\(store.searchedQuery)\"."
    }

    private func noticeCard(_ notices: [RegistrySearchResult]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(notices.enumerated()), id: \.element.id) { index, result in
                ExploreNoticeRow(
                    result: result,
                    isBusy: store.accessBusy == result.source.host,
                    onAllow: { allowAccess(result.source) },
                    onRetry: { Task { await store.run() } }
                )
                if index < notices.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .deckCard()
    }

    private func allowAccess(_ source: RegistrySource) {
        Task {
            let result = await store.allowAccess(source)
            switch result {
            case .found:
                state.showToast("\(source.displayName) is searchable now", style: .success)
            case .failed(let message):
                state.showToast(message, style: .error)
            case .none:
                state.showToast("No saved login for \(source.displayName). Sign in under Settings, Registries.", style: .error)
            case .needsPermission:
                break
            }
        }
    }

    /// Rows in one card. With `hasMore`, a spinner row at the end loads the next page
    /// when it scrolls into view (the stack is lazy, so it does not load every page at once).
    private func repositoryList(_ items: [RegistryImage], hasMore: Bool = false) -> some View {
        repositoryCard {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, repository in
                    Button {
                        openRepository = repository
                    } label: {
                        RegistryImageRow(image: repository, isDownloaded: localRepositories.contains(ImageRefMatch.repository(repository.reference)))
                    }
                    .buttonStyle(.plain)
                    if index < items.count - 1 || hasMore {
                        Divider().padding(.leading, 62)
                    }
                }
                if hasMore {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .task(id: items.count) { await store.loadMore() }
                }
            }
        }
    }

    private func repositoryCard<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        inner()
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .deckCard()
    }
}

// MARK: - Filter bar

/// "All", "Docker Hub", "Quay.io" and each signed in registry, with counts.
/// Becomes a menu when there are too many registries for one row.
struct ExploreFilterBar: View {
    private var store: ImageExploreStore { ImageExploreStore.shared }

    var body: some View {
        @Bindable var store = store
        ViewThatFits(in: .horizontal) {
            SegmentedFilter(selection: $store.filter, options: store.filterOptions, label: { store.filterTitle($0) }) { option in
                store.count(for: option)
            }
            Picker("Registry", selection: $store.filter) {
                ForEach(store.filterOptions, id: \.self) { option in
                    Text(menuTitle(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .help("Pick a registry to search")
    }

    private func menuTitle(_ option: String) -> String {
        let title = store.filterTitle(option)
        guard let count = store.count(for: option) else { return title }
        return "\(title) (\(count))"
    }
}

// MARK: - Rows

private struct RegistryImageRow: View {
    let image: RegistryImage
    let isDownloaded: Bool
    @State private var hovering = false

    private var description: String {
        image.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconBadge(image.isOfficial ? .official : .images, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(image.repository)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Pill(image.registryName, tint: DS.textSecondary)
                        .help(image.registry)
                    ExploreBadges(isOfficial: image.isOfficial, isPrivate: image.isPrivate, isDownloaded: isDownloaded)
                }
                // Same height with or without pills, so every row is even.
                .frame(height: 20)
                Text(description.isEmpty ? "No description." : description)
                    .font(.callout)
                    .deckRowText(description.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(description)
            }
            Spacer(minLength: 12)
            ExploreStats(stars: image.starCount, pulls: image.pullCount, showsStars: image.isDockerHub)
            DeckIcon(.chevronRight, size: 11, color: DS.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? DS.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// One registry that needs a word: no search, listing refused, locked or failed.
private struct ExploreNoticeRow: View {
    let result: RegistrySearchResult
    let isBusy: Bool
    let onAllow: () -> Void
    let onRetry: () -> Void

    private var icon: (DeckIconName, Color) {
        switch result.status {
        case .failed: return (.warning, DS.warning)
        case .needsKeychainAccess: return (.lock, DS.textSecondary)
        default: return (.info, DS.textSecondary)
        }
    }

    private var message: String {
        switch result.status {
        case .ok: return ""
        case .lookupOnly(let note): return note
        case .listingRefused: return RegistrySearchCopy.listingRefused
        case .needsKeychainAccess: return RegistrySearchCopy.needsKeychain
        case .failed(let text): return "Search failed. \(text)"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DeckIcon(icon.0, size: 15, color: icon.1)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.source.displayName)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch result.status {
            case .needsKeychainAccess:
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Allow Access", action: onAllow)
                        .help("macOS asks once for the login saved by the container tool")
                }
            case .failed:
                Button("Try Again", action: onRetry)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// An exact name looked up in its registry: tag count, a few tags, Pull and Tags.
private struct ExploreLookupCard: View {
    let name: String
    let lookup: ImageExploreStore.LookupState
    let isDownloaded: (RegistryImage) -> Bool
    let onTags: (RegistryImage) -> Void
    let onPull: (String) -> Void
    let onRetry: () -> Void

    private var parsed: PullReference? { PullReference.parse(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconBadge(.registry, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.body.monospaced().weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if case .found(let image, _, _) = lookup {
                            Pill(image.registryName, tint: DS.textSecondary)
                            ExploreBadges(isOfficial: image.isOfficial, isPrivate: false, isDownloaded: isDownloaded(image))
                        }
                    }
                    .frame(height: 20)
                    statusLine
                }
                Spacer(minLength: 12)
                buttons
            }
            if case .found(_, _, let tags) = lookup, !tags.isEmpty {
                HStack(spacing: 6) {
                    Text("Tags")
                        .font(.caption)
                        .foregroundStyle(DS.textTertiary)
                    ForEach(Self.chipTags(tags), id: \.self) { tag in
                        Text(tag)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DS.surfaceSunken))
                            .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 48)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckCard()
    }

    /// As many whole tags as fit one short line.
    static func chipTags(_ tags: [String]) -> [String] {
        var picked: [String] = []
        var width = 0
        for tag in tags where tag.count <= 28 {
            width += tag.count + 4
            if width > 64 { break }
            picked.append(tag)
        }
        return picked
    }

    private var displayName: String {
        if case .found(let image, _, _) = lookup { return image.reference }
        return parsed.map { ($0.registry.map { "\($0)/" } ?? "") + $0.repository } ?? name
    }

    @ViewBuilder
    private var statusLine: some View {
        switch lookup {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Looking up tags").font(.callout).foregroundStyle(DS.textSecondary)
            }
        case .found(_, let count, _):
            Text(RegistryTagList.isCapped(count) ? "More than \(count.formatted()) tags" : count == 1 ? "1 tag" : "\(count.formatted()) tags")
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
        case .failed(_, let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch lookup {
        case .found(let image, _, let tags):
            HStack(spacing: 8) {
                Button { onTags(image) } label: { DeckLabel("Tags", icon: .tag) }
                Button { onPull(image.reference(tag: pullTag(tags))) } label: { DeckLabel("Pull", icon: .pull) }
                    .deckPrimary()
                    .disabled(tags.isEmpty)
            }
        case .failed:
            HStack(spacing: 8) {
                Button("Try Again", action: onRetry)
                if parsed != nil {
                    Button { onPull(name) } label: { DeckLabel("Pull", icon: .pull) }
                        .deckPrimary()
                        .help("Pull by name anyway")
                }
            }
        default:
            EmptyView()
        }
    }

    /// The typed tag, else latest, else the newest looking one.
    private func pullTag(_ tags: [String]) -> String {
        if let tag = parsed?.tag { return tag }
        if tags.contains("latest") { return "latest" }
        return tags.first ?? "latest"
    }
}

/// "Official", "Private" and "On this Mac" pills, the same everywhere in Explore.
struct ExploreBadges: View {
    let isOfficial: Bool
    var isPrivate: Bool = false
    let isDownloaded: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isOfficial {
                Pill("Official", tint: DS.accent)
            }
            if isPrivate {
                Pill("Private", tint: DS.warning)
            }
            if isDownloaded {
                Pill("On this Mac", tint: DS.running)
            }
        }
    }
}

/// Stars and pulls in fixed columns, so they line up from row to row.
/// Registries without counts keep the same width, so chevrons stay in line.
struct ExploreStats: View {
    let stars: Int
    let pulls: Int
    /// Only Docker Hub has stars. Elsewhere the column stays empty.
    var showsStars = true

    var body: some View {
        HStack(spacing: 14) {
            if showsStars && (stars > 0 || pulls > 0) {
                stat(.star, Format.count(stars), help: "\(stars.formatted()) stars")
            } else {
                Color.clear.frame(width: 62, height: 1)
            }
            if pulls > 0 || (showsStars && stars > 0) {
                stat(.download, Format.count(pulls), help: "\(pulls.formatted()) pulls")
            } else {
                Color.clear.frame(width: 62, height: 1)
            }
        }
        .font(.callout)
        .deckSecondaryText()
    }

    private func stat(_ icon: DeckIconName, _ text: String, help: String) -> some View {
        HStack(spacing: 5) {
            DeckIcon(icon, size: 12, color: DS.textTertiary)
            Text(text).monospacedDigit()
            Spacer(minLength: 0)
        }
        .frame(width: 62, alignment: .leading)
        .help(help)
    }
}

/// Small capsule button for search suggestions.
private struct ExploreChip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(hovering ? DS.accent : DS.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(hovering ? DS.accentSoft : DS.surfaceSunken))
                .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
