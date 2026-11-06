import SwiftUI
import DeckCore

/// Search Docker Hub, see stars and pulls, and open a repository's tags.
struct ExploreScreen: View {
    @Environment(AppState.self) private var state

    @State private var query = ""
    @State private var searchedQuery = ""
    @State private var results: [HubRepository] = []
    @State private var nextPage: Int?
    @State private var isSearching = false
    @State private var isLoadingMore = false
    @State private var searchError: String?
    @State private var localRepositories: Set<String> = []
    @State private var localReferences: Set<String> = []
    @State private var openRepository: HubRepository?
    @State private var popular: [HubRepository] = []
    @State private var registryReference = ""
    @State private var pullRequest: ExplorePullRequest?

    private let hub = DockerHubClient()

    static let suggestions = ["nginx", "postgres", "redis", "python", "node", "alpine"]

    var body: some View {
        content
            .navigationTitle("Explore")
            .searchable(text: $query, placement: .toolbar, prompt: "Search Docker Hub")
            .task(id: query) { await searchAfterPause() }
            .task(id: state.resourcesVersion) { await loadLocalImages() }
            .task { await loadPopular() }
            .sheet(item: $pullRequest) { request in
                ImagesPullSheet(reference: request.reference, autoStart: true)
                    .environment(state)
                    .tint(DS.accent)
            }
            .sheet(item: $openRepository) { repository in
                ExploreRepositorySheet(repository: repository, localReferences: localReferences)
                    .environment(state)
            }
            .onDeckDebugCommand { name, value in
                switch name {
                case "explore-search":
                    query = value
                case "explore-registry":
                    registryReference = value
                case "explore-pull":
                    pullRequest = ExplorePullRequest(reference: value)
                case "explore-open":
                    openRepository = (results + popular).first { $0.fullName == value }
                        ?? HubRepository(fullName: value, isOfficial: !value.contains("/"))
                default:
                    break
                }
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            welcome
        } else if PullReference.looksLikeDirectPull(trimmed) {
            DeckPage(maxWidth: 900) {
                SectionHeader("Pull by name", subtitle: "This image lives on another registry.")
                ExploreDirectPullRow(reference: trimmed) {
                    pullRequest = ExplorePullRequest(reference: trimmed)
                }
            }
        } else if isSearching && results.isEmpty {
            LoadingView("Searching Docker Hub", style: .logo)
                .background(DS.surface)
        } else if let searchError, results.isEmpty {
            EmptyState(icon: .error, title: "Search failed", message: searchError, actionTitle: "Try Again") {
                Task { await runSearch(trimmed) }
            }
            .background(DS.surface)
        } else if results.isEmpty && !searchedQuery.isEmpty {
            EmptyState(icon: .search, title: "No results", message: "Nothing on Docker Hub matches \"\(searchedQuery)\".")
                .background(DS.surface)
        } else {
            resultList
        }
    }

    private var welcome: some View {
        DeckPage(maxWidth: 900) {
            welcomeHeader
            ExploreRegistryPullCard(reference: $registryReference) { reference in
                pullRequest = ExplorePullRequest(reference: reference)
            }
            if popular.isEmpty {
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
                repositoryList(popular)
            }
        }
    }

    private var welcomeHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            IconBadge(.explore, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text("Search Docker Hub").font(.title2.weight(.semibold))
                Text("Find an image, check its tags, then pull or run it.")
                    .foregroundStyle(DS.textSecondary)
                HStack(spacing: 6) {
                    Text("Try")
                        .font(.callout)
                        .foregroundStyle(DS.textTertiary)
                    ForEach(Self.suggestions, id: \.self) { name in
                        ExploreChip(title: name) { query = name }
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

    private var resultList: some View {
        DeckPage(maxWidth: 900) {
            SectionHeader(
                "Results for \"\(searchedQuery)\"",
                subtitle: nextPage == nil ? resultCountText : "Showing \(resultCountText). Scroll for more."
            ) {
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            repositoryList(results, hasMore: nextPage != nil)
        }
    }

    private var resultCountText: String {
        results.count == 1 ? "1 image" : "\(results.count) images"
    }

    /// Rows in one card. With `hasMore`, a spinner row at the end loads the next page
    /// when it scrolls into view (the stack is lazy, so it does not load every page at once).
    private func repositoryList(_ items: [HubRepository], hasMore: Bool = false) -> some View {
        repositoryCard {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, repository in
                    Button {
                        openRepository = repository
                    } label: {
                        HubRepositoryRow(repository: repository, isDownloaded: isDownloaded(repository))
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
                    .task(id: items.count) { await loadMore() }
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

    private func isDownloaded(_ repository: HubRepository) -> Bool {
        localRepositories.contains(ImageRefMatch.repository(repository.fullName))
    }

    // MARK: - Loading

    private func searchAfterPause() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = []
            nextPage = nil
            searchError = nil
            searchedQuery = ""
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        await runSearch(trimmed)
    }

    private func runSearch(_ text: String) async {
        // Full names from other registries are pulled by name, not searched.
        if PullReference.looksLikeDirectPull(text) { return }
        isSearching = true
        searchError = nil
        do {
            let page = try await hub.search(text, page: 1)
            if Task.isCancelled { return }
            results = page.items
            nextPage = page.nextPage
            searchedQuery = text
        } catch {
            if Task.isCancelled { return }
            results = []
            nextPage = nil
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    private func loadMore() async {
        guard let page = nextPage, !isLoadingMore, !searchedQuery.isEmpty else { return }
        let text = searchedQuery
        isLoadingMore = true
        do {
            let next = try await hub.search(text, page: page)
            if text == searchedQuery {
                let known = Set(results.map(\.id))
                results += next.items.filter { !known.contains($0.id) }
                nextPage = next.items.isEmpty ? nil : next.nextPage
            }
        } catch {
            if !Task.isCancelled {
                nextPage = nil
                state.showError(error)
            }
        }
        isLoadingMore = false
    }

    /// Official images, most pulled first. Shown before the first search.
    private func loadPopular() async {
        guard popular.isEmpty else { return }
        // Quiet on failure. Search still works.
        if let page = try? await hub.search("", page: 1) {
            popular = page.items
        }
    }

    private func loadLocalImages() async {
        guard let client = state.client else { return }
        guard let images = try? await client.listImages() else { return }
        localRepositories = Set(images.map { ImageRefMatch.repository($0.reference) })
        localReferences = Set(images.map { ImageRefMatch.normalize($0.reference) })
    }
}

private struct HubRepositoryRow: View {
    let repository: HubRepository
    let isDownloaded: Bool
    @State private var hovering = false

    private var description: String {
        repository.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconBadge(repository.isOfficial ? .official : .images, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(repository.fullName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    ExploreBadges(isOfficial: repository.isOfficial, isDownloaded: isDownloaded)
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
            ExploreStats(stars: repository.starCount, pulls: repository.pullCount)
            DeckIcon(.chevronRight, size: 11, color: DS.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? DS.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// "Official" and "Downloaded" pills, the same everywhere in Explore.
struct ExploreBadges: View {
    let isOfficial: Bool
    let isDownloaded: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isOfficial {
                Pill("Official", tint: DS.accent)
            }
            if isDownloaded {
                Pill("On this Mac", tint: DS.running)
            }
        }
    }
}

/// Stars and pulls in fixed columns, so they line up from row to row.
struct ExploreStats: View {
    let stars: Int
    let pulls: Int

    var body: some View {
        HStack(spacing: 14) {
            stat(.star, Format.count(stars), help: "\(stars.formatted()) stars")
            stat(.download, Format.count(pulls), help: "\(pulls.formatted()) pulls")
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
