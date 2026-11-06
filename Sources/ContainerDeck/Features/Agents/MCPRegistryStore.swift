import SwiftUI
import DeckCore

/// Which sources Browse shows.
enum MCPSourceFilter: String, CaseIterable, Identifiable {
    case all, registry, docker
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .registry: return MCPRegistrySource.registry.title
        case .docker: return MCPRegistrySource.docker.title
        }
    }
}

/// Transport filter chips. HTTP covers streamable HTTP and SSE.
enum MCPTransportFilter: String, CaseIterable, Identifiable {
    case stdio, http
    var id: String { rawValue }
    var title: String { self == .stdio ? "stdio" : "HTTP" }

    func matches(_ server: MCPRegistryServer) -> Bool {
        switch self {
        case .stdio: return server.transports.contains(.stdio)
        case .http: return server.transports.contains(.http) || server.transports.contains(.sse)
        }
    }
}

/// Where a page starts in each source. nil means that source has no more.
struct MCPPageCursor: Equatable {
    var registry: String?
    var docker: String?
    var registryDone = false
    var dockerDone = false
}

/// Browse state for the Catalog tab: one page at a time, with the cursors kept so Previous works.
@MainActor
@Observable
final class MCPRegistryStore {
    static let pageSize = 30

    var query = ""
    var source: MCPSourceFilter = .all
    var transports: Set<MCPTransportFilter> = []
    var selection: MCPRegistryServer.ID?
    private(set) var results: [MCPRegistryServer] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var hasLoaded = false
    /// Cursor of each page seen so far. The last one is the page shown.
    private(set) var pages: [MCPPageCursor] = [MCPPageCursor()]
    private(set) var next: MCPPageCursor?
    /// Total matches when every shown source reports one.
    private(set) var total: Int?
    /// Number of servers before each page (page sizes vary when a source runs out).
    private(set) var starts: [Int] = [0]

    @ObservationIgnored private let client = MCPRegistryClient()
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var shownKey: String?

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The registry needs 3 letters. Shorter text lists the latest servers.
    var queryTooShort: Bool {
        source != .docker && !trimmedQuery.isEmpty && trimmedQuery.count < MCPRegistryClient.minimumSearchLength
    }

    /// Results after the transport chips.
    var visible: [MCPRegistryServer] {
        guard !transports.isEmpty else { return results }
        return results.filter { server in transports.contains { $0.matches(server) } }
    }

    var pageIndex: Int { pages.count - 1 }
    var canGoBack: Bool { pages.count > 1 && !isLoading }
    var canGoForward: Bool { next != nil && !isLoading }

    /// "1 to 30 of 245", or "31 to 60" when the total is not known.
    var rangeText: String {
        guard !results.isEmpty else { return "No servers" }
        let before = starts.last ?? 0
        let first = before + 1
        let last = before + results.count
        var text = "\(first) to \(last)"
        if let total { text += " of \(total)" }
        if visible.count != results.count { text += ", \(visible.count) shown" }
        return text
    }

    private var key: String { source.rawValue + "|" + (queryTooShort ? "" : trimmedQuery) }

    /// Searches after a short pause, so typing does not send a request per letter.
    func searchAfterPause() async {
        guard key != shownKey || (error != nil && results.isEmpty) else { return }
        try? await Task.sleep(for: .milliseconds(hasLoaded ? 400 : 0))
        guard !Task.isCancelled else { return }
        pages = [MCPPageCursor()]
        starts = [0]
        await load()
    }

    func reload() async {
        await load()
    }

    func goForward() async {
        guard let next, !isLoading else { return }
        starts.append((starts.last ?? 0) + results.count)
        pages.append(next)
        await load()
    }

    func goBack() async {
        guard pages.count > 1, !isLoading else { return }
        pages.removeLast()
        if starts.count > 1 { starts.removeLast() }
        await load()
    }

    private func load() async {
        sequence += 1
        let token = sequence
        let wanted = key
        let cursor = pages.last ?? MCPPageCursor()
        let text = queryTooShort ? "" : trimmedQuery
        isLoading = true
        error = nil
        defer { if token == sequence { isLoading = false; hasLoaded = true } }
        do {
            var servers: [MCPRegistryServer] = []
            var nextCursor = MCPPageCursor(registryDone: true, dockerDone: true)
            var totals: [Int?] = []
            // All: 20 from the registry and 10 from Docker per page.
            let registryLimit = source == .all ? 20 : Self.pageSize
            let dockerLimit = source == .all ? 10 : Self.pageSize
            if source != .docker, !cursor.registryDone {
                let page = try await client.search(text, source: .registry, cursor: cursor.registry, limit: registryLimit)
                servers += page.servers
                nextCursor.registry = page.nextCursor
                nextCursor.registryDone = page.nextCursor == nil
                totals.append(page.total)
            }
            if source != .registry, !cursor.dockerDone {
                let page = try await client.search(text, source: .docker, cursor: cursor.docker, limit: dockerLimit)
                servers += page.servers
                nextCursor.docker = page.nextCursor
                nextCursor.dockerDone = page.nextCursor == nil
                totals.append(page.total)
            }
            guard token == sequence else { return }
            results = servers
            next = nextCursor.registryDone && nextCursor.dockerDone ? nil : nextCursor
            total = totals.isEmpty || totals.contains(where: { $0 == nil }) ? nil : totals.compactMap { $0 }.reduce(0, +)
            shownKey = wanted
            if let selection, !servers.contains(where: { $0.id == selection }) { self.selection = servers.first?.id }
            if selection == nil { selection = servers.first?.id }
        } catch is CancellationError {
            return
        } catch {
            guard token == sequence else { return }
            self.error = error.localizedDescription
            results = []
            next = nil
            shownKey = wanted
        }
    }
}
