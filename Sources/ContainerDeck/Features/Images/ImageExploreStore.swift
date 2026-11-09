import SwiftUI
import DeckCore

/// State for Images, Explore: one search across Docker Hub, Quay.io and every
/// signed in registry. Shared, so the search survives a switch to On this Mac
/// and links can fill it in.
@MainActor @Observable
final class ImageExploreStore {
    static let shared = ImageExploreStore()

    /// "all" or a registry host.
    static let allFilter = "all"

    enum LookupState: Equatable {
        case idle
        case loading(String)
        case found(RegistryImage, tagCount: Int, tags: [String])
        case failed(String, message: String)
    }

    var query = ""
    var filter = ImageExploreStore.allFilter
    private(set) var sources: [RegistrySource] = [.dockerHub, .quay]
    private(set) var results: [RegistrySearchResult] = []
    private(set) var merged: [RegistryImage] = []
    private(set) var searchedQuery = ""
    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    private(set) var popular: [RegistryImage] = []
    private(set) var lookup: LookupState = .idle
    private(set) var accessBusy: String?
    private var page = 1
    private var loginsLoaded = false

    let service = RegistrySearchService()

    private init() {}

    // MARK: Derived

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var filterOptions: [String] { [Self.allFilter] + sources.map(\.host) }

    func filterTitle(_ value: String) -> String {
        value == Self.allFilter ? "All" : RegistrySource.displayName(for: value)
    }

    /// Result count per filter once a search has run.
    func count(for value: String) -> Int? {
        guard !searchedQuery.isEmpty, lookupName == nil else { return nil }
        if value == Self.allFilter { return merged.count }
        guard let result = results.first(where: { $0.source.host == value }), result.status == .ok else { return nil }
        return merged.filter { $0.registry == value }.count
    }

    var selectedSource: RegistrySource? { sources.first { $0.host == filter } }

    var visible: [RegistryImage] {
        filter == Self.allFilter ? merged : merged.filter { $0.registry == filter }
    }

    /// Registries that need a word: no search, refused, locked or failed.
    var notices: [RegistrySearchResult] {
        results.filter { $0.status.isProblem && (filter == Self.allFilter || $0.source.host == filter) }
    }

    var hasMore: Bool {
        results.contains { $0.nextPage != nil && (filter == Self.allFilter || $0.source.host == filter) }
    }

    /// The exact name to look up instead of searching, when there is one: a full
    /// name from another registry, or any name while a registry without search
    /// is picked.
    var lookupName: String? {
        let text = trimmedQuery
        guard !text.isEmpty, let parsed = PullReference.parse(text) else { return nil }
        if (parsed.registry != nil && !parsed.isDockerHub) || parsed.digest != nil { return text }
        if let source = selectedSource, parsed.registry == nil, Self.searchless(source, in: results) { return "\(source.host)/\(text)" }
        return nil
    }

    private static func searchless(_ source: RegistrySource, in results: [RegistrySearchResult]) -> Bool {
        if source.kind == .amazon || source.kind == .google { return true }
        guard let status = results.first(where: { $0.source.host == source.host })?.status else { return false }
        switch status {
        case .lookupOnly, .listingRefused, .needsKeychainAccess: return true
        default: return false
        }
    }

    // MARK: Loading

    /// Signed in registries from `container registry list`. Quiet on failure:
    /// Docker Hub and Quay.io still work.
    func loadSources(client: ContainerClient?, force: Bool = false) async {
        guard let client, force || !loginsLoaded else { return }
        guard let logins = try? await client.registryLogins() else { return }
        loginsLoaded = true
        let next = RegistrySource.sources(logins: logins)
        if next != sources {
            sources = next
            await service.reset()
            if !filterOptions.contains(filter) { filter = Self.allFilter }
        }
    }

    func loadPopular() async {
        guard popular.isEmpty else { return }
        if let page = try? await DockerHubClient().search("", page: 1) {
            popular = page.items.map(RegistryImage.init(hub:))
        }
    }

    /// Waits a moment after typing, then searches or looks up.
    func searchAfterPause() async {
        let text = trimmedQuery
        if text.isEmpty {
            results = []
            merged = []
            searchedQuery = ""
            isSearching = false
            lookup = .idle
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        await run()
    }

    func run() async {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        if let name = lookupName {
            await runLookup(name)
            return
        }
        lookup = .idle
        isSearching = true
        page = 1
        let found = await service.search(text, in: sources)
        if Task.isCancelled { return }
        results = found
        merged = RegistrySearchMerge.merge(found, query: text)
        searchedQuery = text
        isSearching = false
        // A registry without search was picked while typing: look the name up there.
        if let name = lookupName { await runLookup(name) }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !searchedQuery.isEmpty else { return }
        let text = searchedQuery
        let next = page + 1
        let pending = results.filter { $0.nextPage == next }.map(\.source)
        guard !pending.isEmpty else { return }
        isLoadingMore = true
        let found = await service.search(text, in: pending, page: next)
        if text == searchedQuery {
            page = next
            // New rows go after the ones already shown, so nothing jumps.
            let known = Set(merged.map(\.id))
            merged += RegistrySearchMerge.merge(found.filter { $0.status == .ok }, query: text).filter { !known.contains($0.id) }
            for result in found {
                guard let index = results.firstIndex(where: { $0.source.host == result.source.host }) else { continue }
                results[index].nextPage = result.status == .ok && !result.images.isEmpty ? result.nextPage : nil
            }
        }
        isLoadingMore = false
    }

    private func runLookup(_ name: String) async {
        lookup = .loading(name)
        let source = PullReference.parse(name)?.registry.flatMap { host in
            sources.first { $0.host == DockerConfigFile.registryHost(from: host) }
        }
        do {
            let found = try await service.lookup(name, in: source)
            if Task.isCancelled { return }
            let names = found.tags.items.map(\.name)
            lookup = .found(found.image, tagCount: names.count, tags: Array(names.prefix(8)))
        } catch {
            if Task.isCancelled { return }
            lookup = .failed(name, message: error.localizedDescription)
        }
    }

    /// Asks macOS for the saved login (the person pressed Allow Access), then searches again.
    func allowAccess(_ source: RegistrySource) async -> RegistryCredentialLookup {
        accessBusy = source.host
        let result = await service.requestAccess(source)
        accessBusy = nil
        if case .found = result { await run() }
        return result
    }

    #if DEBUG
    /// Checks only: search one more registry without signing in to it.
    func addDebugSource(_ host: String) {
        let source = RegistrySource(host: host)
        guard !host.isEmpty, !sources.contains(where: { $0.host == source.host }) else { return }
        sources.append(source)
    }
    #endif

    func source(for host: String) -> RegistrySource {
        sources.first { $0.host == host } ?? RegistrySource(host: host)
    }
}
