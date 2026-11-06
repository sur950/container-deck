import SwiftUI
import AppKit
import DeckCore

extension PrefKey {
    static let proxyAliases = "domains.proxyAliases"           // JSON [ProxyAlias]
    static let proxyPort = "domains.proxyPort"                 // Int, default 8443
    static let proxyAutoStart = "domains.proxyAutoStart"       // Bool, default false
    static let proxyRedirectInstalledAt = "domains.redirect443At" // Double, time the 443 rule was loaded
    static let lastShareProvider = "domains.lastShareProvider" // String, provider id
}

/// Provider secrets. The Keychain normally. Debug runs pointed at stand in tools keep them in memory.
private final class ShareSecrets: @unchecked Sendable {
    private let lock = NSLock()
    private let keychain: ShareKeychain?
    private var memory: [String: String] = [:]

    init(inMemory: Bool) { keychain = inMemory ? nil : ShareKeychain() }

    func read(_ provider: String, _ key: String) -> String? {
        if let keychain { return keychain.read(provider: provider, key: key) }
        lock.lock(); defer { lock.unlock() }
        return memory[ShareKeychain.account(provider: provider, key: key)]
    }

    func save(_ value: String, _ provider: String, _ key: String) throws {
        if let keychain { return try keychain.save(value, provider: provider, key: key) }
        lock.lock(); defer { lock.unlock() }
        memory[ShareKeychain.account(provider: provider, key: key)] = value
    }

    func delete(_ provider: String, _ key: String) throws {
        if let keychain { return try keychain.delete(provider: provider, key: key) }
        lock.lock(); defer { lock.unlock() }
        memory[ShareKeychain.account(provider: provider, key: key)] = nil
    }
}

/// State for local domains, the HTTPS proxy and sharing. Lives for the whole app run,
/// so the proxy and tunnels keep going when the person leaves the screen.
@MainActor
@Observable
final class DomainsStore {
    static let shared = DomainsStore()

    // MARK: Domains
    private(set) var domains: [LocalDomain] = []
    private(set) var domainsLoaded = false
    private(set) var domainsLoading = false
    private(set) var domainsError: String?
    private(set) var savedDefault: String?
    private(set) var activeDefault: String?
    private(set) var canSetDefault = false
    var busyDomain: String?

    // MARK: Routes and aliases
    private(set) var aliases: [ProxyAlias] = []
    private(set) var installedResolvers: Set<String> = []
    private(set) var exposedPorts: [String: [Int]] = [:]
    @ObservationIgnored private var inspectedImages: Set<String> = []

    // MARK: Proxy
    private(set) var proxyRunning = false
    private(set) var proxyBusy = false
    private(set) var proxyError: String?
    private(set) var caExists = false
    private(set) var caTrusted = false
    private(set) var caBusy = false
    private(set) var redirectBusy = false
    private(set) var redirectInstalledAt: Date?
    private(set) var requestsByHost: [String: Int] = [:]
    var proxyPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: PrefKey.proxyPort)
        return (1025...65535).contains(stored) ? UInt16(stored) : DomainsConfig.defaultProxyPort
    }

    // MARK: Sharing
    private(set) var installedTools: [String: String] = [:]
    private(set) var readiness: [String: ShareReadiness] = [:]
    private(set) var installing: Set<String> = []
    private(set) var tunnelStates: [String: TunnelSession.State] = [:]
    private(set) var tunnelProviders: [String: String] = [:]
    /// Bumped when setup values change, so views reading them refresh.
    private(set) var setupVersion = 0
    @ObservationIgnored private var shareTokens: [String: UUID] = [:]

    @ObservationIgnored private var client: ContainerClient?
    @ObservationIgnored private let authority = LocalCertificateAuthority()
    @ObservationIgnored private var proxy: HTTPSProxyServer?
    @ObservationIgnored private let dnsResponder = AliasDNSResponder()
    @ObservationIgnored private var routeSync: Task<Void, Never>?
    @ObservationIgnored private var lastSyncedVersion = -1
    @ObservationIgnored private let locator = DomainsStore.makeLocator()
    @ObservationIgnored private let secrets = ShareSecrets(inMemory: DomainsStore.debugToolsDirectory != nil)
    @ObservationIgnored private lazy var manager: ShareManager = {
        let secrets = self.secrets
        let context = ShareContext(
            secret: { secrets.read($0, $1) },
            setting: { UserDefaults.standard.string(forKey: DomainsConfig.shareSettingKey(provider: $0, key: $1)) },
            homeDirectory: DomainsStore.debugToolsDirectory ?? NSHomeDirectory()
        )
        let manager = ShareManager(locator: locator, context: context)
        manager.onChange = { host, session, state in
            Task { @MainActor in DomainsStore.shared.tunnelChanged(host: host, session: session, state: state) }
        }
        return manager
    }()

    private init() {
        aliases = Self.loadAliases()
        let stamp = UserDefaults.standard.double(forKey: PrefKey.proxyRedirectInstalledAt)
        redirectInstalledAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        refreshCertificateState()
        refreshResolvers()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DomainsStore.shared.shutDown() }
        }
    }

    func attach(_ client: ContainerClient?) {
        self.client = client
    }

    // MARK: - Domains

    func loadDomains() async {
        guard let client else { return }
        domainsLoading = true
        do {
            domains = try await client.localDomains()
            domainsError = nil
        } catch {
            if !Task.isCancelled { domainsError = error.localizedDescription }
        }
        do {
            let value = try await client.defaultDNSDomain()
            activeDefault = value.active
            savedDefault = value.saved
            canSetDefault = true
        } catch {
            canSetDefault = false
        }
        domainsLoaded = true
        domainsLoading = false
    }

    var containerDomains: [LocalDomain] { domains.filter { !$0.isHostAlias } }
    var needsRestartForDefault: Bool { canSetDefault && savedDefault != activeDefault }

    func createDomain(_ name: String, hostAddress: String?) async throws {
        guard let client else { return }
        busyDomain = name
        defer { busyDomain = nil }
        if let hostAddress {
            try await client.createHostAlias(name, address: hostAddress)
        } else {
            try await client.createDNSDomain(name)
        }
        await loadDomains()
    }

    func deleteDomain(_ name: String) async throws {
        guard let client else { return }
        busyDomain = name
        defer { busyDomain = nil }
        try await client.deleteDNSDomain(name)
        await loadDomains()
    }

    func makeDefault(_ name: String) async throws {
        guard let client else { return }
        busyDomain = name
        defer { busyDomain = nil }
        try await client.setDefaultDNSDomain(name)
        savedDefault = name
    }

    // MARK: - Routes

    func routes(for containers: [ContainerSummary]) -> [ProxyRoute] {
        RoutePlanner.routes(containers: containers, aliases: aliases, exposedPorts: exposedPorts)
    }

    var currentRoutes: [ProxyRoute] { routes(for: BackgroundServices.shared.containers) }

    /// Reads exposed ports of images that have no label and no published port. Once per image.
    func learnExposedPorts(_ containers: [ContainerSummary]) async {
        guard let client else { return }
        let wanted = containers.filter { c in
            c.labels[DomainsConfig.portLabel] == nil && c.ports.isEmpty && !inspectedImages.contains(c.image)
        }
        for image in Set(wanted.map(\.image)) {
            inspectedImages.insert(image)
            if let detail = try? await client.inspectImage(image) {
                exposedPorts[image] = RoutePlanner.exposedTCPPorts(detail.config.exposedPorts)
            }
        }
    }

    func addAlias(_ alias: ProxyAlias) {
        aliases.removeAll { $0.pattern == alias.pattern }
        aliases.append(alias)
        aliases.sort { $0.pattern < $1.pattern }
        saveAliases()
        pushRoutes()
    }

    func removeAlias(_ alias: ProxyAlias) async throws {
        if installedResolvers.contains(alias.pattern), let client {
            try await PrivilegedRunner(runner: client.runner).run(AliasResolverFiles.removeCommands(for: alias.pattern)).orThrow()
        }
        aliases.removeAll { $0.pattern == alias.pattern }
        saveAliases()
        refreshResolvers()
        pushRoutes()
    }

    /// Admin step: sends one alias domain to our small DNS server.
    func installResolver(for alias: ProxyAlias) async throws {
        guard let client else { return }
        try await PrivilegedRunner(runner: client.runner).run(AliasResolverFiles.installCommands(for: alias.pattern)).orThrow()
        refreshResolvers()
    }

    func refreshResolvers() {
        installedResolvers = Set(aliases.filter { $0.needsResolver && AliasResolverFiles.isInstalled($0.pattern) }.map(\.pattern))
    }

    private static func loadAliases() -> [ProxyAlias] {
        guard let data = UserDefaults.standard.data(forKey: PrefKey.proxyAliases),
              let list = try? JSONDecoder().decode([ProxyAlias].self, from: data) else { return [] }
        return list.filter { HostName.isValidPattern($0.pattern) }
    }

    private func saveAliases() {
        if let data = try? JSONEncoder().encode(aliases) {
            UserDefaults.standard.set(data, forKey: PrefKey.proxyAliases)
        }
    }

    // MARK: - Certificates

    func refreshCertificateState() {
        caExists = authority.exists
        caTrusted = caExists && authority.isTrusted()
    }

    var caCertificateURL: URL { authority.caCertificateURL }

    /// Only from the Trust button. macOS asks the person to approve.
    func trustAuthority() async throws {
        caBusy = true
        defer { caBusy = false }
        try await authority.createIfNeeded()
        try await authority.trust()
        refreshCertificateState()
    }

    func untrustAuthority() async throws {
        caBusy = true
        defer { caBusy = false }
        try await authority.untrust()
        refreshCertificateState()
    }

    // MARK: - Proxy

    func startProxy() async throws {
        guard !proxyBusy else { return }
        proxyBusy = true
        defer { proxyBusy = false }
        try await authority.createIfNeeded()
        refreshCertificateState()
        let server = HTTPSProxyServer(port: proxyPort, authority: authority)
        await learnExposedPorts(BackgroundServices.shared.containers)
        do {
            try await server.start(routes: currentRoutes)
        } catch {
            proxyError = error.localizedDescription
            throw error
        }
        proxy = server
        let patterns = aliases.filter(\.needsResolver).map(\.pattern)
        try? dnsResponder.start(patterns: patterns)
        proxyRunning = true
        proxyError = nil
        startRouteSync()
    }

    func stopProxy() {
        routeSync?.cancel()
        routeSync = nil
        proxy?.stop()
        proxy = nil
        dnsResponder.stop()
        proxyRunning = false
        requestsByHost = [:]
    }

    /// Call at app launch. Does nothing unless the person turned auto start on.
    func startIfEnabled(client: ContainerClient?) {
        guard UserDefaults.standard.bool(forKey: PrefKey.proxyAutoStart), !proxyRunning else { return }
        attach(client)
        Task { try? await startProxy() }
    }

    private func pushRoutes() {
        let routes = currentRoutes
        proxy?.update(routes: routes)
        dnsResponder.update(patterns: aliases.filter(\.needsResolver).map(\.pattern))
    }

    /// Follows the shared container feed while the proxy runs.
    private func startRouteSync() {
        routeSync?.cancel()
        routeSync = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let feed = BackgroundServices.shared
                if feed.containersVersion != self.lastSyncedVersion {
                    self.lastSyncedVersion = feed.containersVersion
                    await self.learnExposedPorts(feed.containers)
                    self.pushRoutes()
                }
                if let snapshot = self.proxy?.snapshot() {
                    if snapshot.requestsByHost != self.requestsByHost { self.requestsByHost = snapshot.requestsByHost }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Port 443

    var redirectActive: Bool { PortRedirect.isLikelyActive(installedAt: redirectInstalledAt) }
    var displayPort: UInt16 { redirectActive ? DomainsConfig.httpsPort : proxyPort }
    /// Something other than us already answers on 443 (like a local web server).
    var port443Busy: Bool { !redirectActive && LoopbackPortCheck.isListening(DomainsConfig.httpsPort) }

    func installRedirect() async throws {
        guard let client else { return }
        redirectBusy = true
        defer { redirectBusy = false }
        try await PrivilegedRunner(runner: client.runner).run(PortRedirect.installCommands(to: proxyPort)).orThrow()
        let now = Date()
        redirectInstalledAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: PrefKey.proxyRedirectInstalledAt)
    }

    func removeRedirect() async throws {
        guard let client else { return }
        redirectBusy = true
        defer { redirectBusy = false }
        try await PrivilegedRunner(runner: client.runner).run(PortRedirect.removeCommands()).orThrow()
        redirectInstalledAt = nil
        UserDefaults.standard.removeObject(forKey: PrefKey.proxyRedirectInstalledAt)
    }

    // MARK: - Sharing

    /// Debug builds can point at a folder of stand in tools to show every share state.
    private static func makeLocator() -> ShareToolLocator {
        #if DEBUG
        if let dir = debugToolsDirectory { return .only(dir) }
        #endif
        return ShareToolLocator()
    }

    private static var debugToolsDirectory: String? {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment[DomainsConfig.debugToolsEnvironmentKey], !dir.isEmpty { return dir }
        #endif
        return nil
    }

    var providers: [any ShareProvider] { ShareProviders.all }

    func refreshTools() async {
        installedTools = locator.installed()
        let manager = self.manager
        await withTaskGroup(of: (String, ShareReadiness).self) { group in
            for provider in providers {
                group.addTask { (provider.id, await manager.readiness(of: provider)) }
            }
            for await (id, value) in group { readiness[id] = value }
        }
    }

    /// Nil while it has not been checked yet.
    func readiness(of provider: any ShareProvider) -> ShareReadiness? {
        if installedTools[provider.id] == nil && !readiness.isEmpty { return .notInstalled }
        return readiness[provider.id]
    }

    var homebrewPath: String? { locator.homebrewPath }

    /// Install options that can run on this Mac.
    func installOptions(for provider: any ShareProvider) -> [ShareInstallOption] {
        provider.installOptions.filter { if case .homebrew = $0 { return homebrewPath != nil } else { return true } }
    }

    /// Only from a click. Web pages open in the browser.
    func install(_ provider: any ShareProvider, option: ShareInstallOption) async throws {
        if case .webPage(let url) = option {
            NSWorkspace.shared.open(url)
            return
        }
        installing.insert(provider.id)
        defer { installing.remove(provider.id) }
        try await provider.install(option, context: manager.context, brew: homebrewPath)
        await refreshTools()
    }

    // MARK: Provider setup values

    func setupValue(_ provider: any ShareProvider, _ field: ShareSetupField) -> String {
        guard !field.isSecret else { return "" }
        return UserDefaults.standard.string(forKey: DomainsConfig.shareSettingKey(provider: provider.id, key: field.key)) ?? ""
    }

    func hasSecret(_ provider: any ShareProvider, _ field: ShareSetupField) -> Bool {
        field.isSecret && secrets.read(provider.id, field.key) != nil
    }

    /// Secrets go to the Keychain, other values to preferences. An empty secret keeps the saved one.
    func saveSetup(_ provider: any ShareProvider, values: [String: String]) async throws {
        for field in provider.setupFields {
            let value = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if field.isSecret {
                if !value.isEmpty { try secrets.save(value, provider.id, field.key) }
            } else {
                let key = DomainsConfig.shareSettingKey(provider: provider.id, key: field.key)
                if value.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(value, forKey: key) }
            }
        }
        setupVersion += 1
        readiness[provider.id] = await manager.readiness(of: provider)
    }

    func removeSecrets(_ provider: any ShareProvider) async throws {
        for field in provider.setupFields where field.isSecret { try secrets.delete(provider.id, field.key) }
        setupVersion += 1
        readiness[provider.id] = await manager.readiness(of: provider)
    }

    // MARK: Shares

    var sharedCount: Int {
        tunnelStates.values.filter { if case .live = $0 { return true } else { return false } }.count
    }

    /// Shares that are live or starting, the ones Stop All ends.
    var activeShareCount: Int {
        tunnelStates.values.filter { if case .failed = $0 { return false } else { return true } }.count
    }

    func state(for route: ProxyRoute) -> TunnelSession.State? { tunnelStates[route.host] }

    func provider(for route: ProxyRoute) -> (any ShareProvider)? {
        tunnelProviders[route.host].flatMap(ShareProviders.provider(id:))
    }

    func publishedPort(for route: ProxyRoute) -> Int? {
        BackgroundServices.shared.containers
            .first { $0.name == route.container }?
            .ports.first { $0.containerPort == route.targetPort && $0.proto == "tcp" }?.hostPort
    }

    /// Why this route cannot use this provider right now. Nil when it can.
    func blocker(_ route: ProxyRoute, _ provider: any ShareProvider) -> ShareFailure? {
        provider.blocker(for: route, publishedPort: publishedPort(for: route))
    }

    func canShare(_ route: ProxyRoute, with provider: any ShareProvider) -> Bool {
        readiness(of: provider)?.isReady == true && blocker(route, provider) == nil
    }

    var lastProviderID: String? { UserDefaults.standard.string(forKey: PrefKey.lastShareProvider) }

    /// The provider the picker starts on: the last one used when it can share, else the first that can.
    func preferredProvider(for route: ProxyRoute) -> (any ShareProvider)? {
        if let id = lastProviderID, let last = ShareProviders.provider(id: id), canShare(route, with: last) { return last }
        return providers.first { canShare(route, with: $0) }
    }

    /// Ready providers this route could use instead of `id`.
    func alternatives(for route: ProxyRoute, excluding id: String?) -> [any ShareProvider] {
        providers.filter { $0.id != id && canShare(route, with: $0) }
    }

    /// Starts a share. Problems the person can fix show on the route, other errors are thrown.
    func share(_ route: ProxyRoute, with provider: any ShareProvider) async throws {
        let host = route.host
        let token = UUID()
        shareTokens[host] = token
        tunnelStates[host] = .starting
        tunnelProviders[host] = provider.id
        UserDefaults.standard.set(provider.id, forKey: PrefKey.lastShareProvider)
        do {
            let session = try await manager.share(route, with: provider, publishedPort: publishedPort(for: route))
            guard shareTokens[host] == token else {
                // Stopped while it was getting ready.
                await manager.stop(host)
                return
            }
            tunnelStates[host] = session.state
        } catch let failure as ShareFailure {
            guard shareTokens[host] == token else { return }
            tunnelStates[host] = .failed(failure)
            if failure.kind == .notInstalled { await refreshTools() }
        } catch {
            guard shareTokens[host] == token else { return }
            clear(host)
            throw error
        }
    }

    func stopSharing(_ host: String) {
        clear(host)
        let manager = self.manager
        Task { await manager.stop(host) }
    }

    func stopAllSharing() {
        for host in Array(tunnelStates.keys) { clear(host) }
        let manager = self.manager
        Task { await manager.stopAll() }
    }

    private func clear(_ host: String) {
        shareTokens[host] = nil
        tunnelStates[host] = nil
        tunnelProviders[host] = nil
    }

    private func tunnelChanged(host: String, session: TunnelSession, state: TunnelSession.State) {
        // Only the current share of a route counts. Stopped ones were cleared already.
        guard shareTokens[host] != nil, manager.session(for: host) === session else { return }
        switch state {
        case .stopped: clear(host)
        default: tunnelStates[host] = state
        }
    }

    private func shutDown() {
        manager.stopAllNow()
        proxy?.stop()
        dnsResponder.stop()
    }
}
