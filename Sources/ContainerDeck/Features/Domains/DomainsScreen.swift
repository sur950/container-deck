import SwiftUI
import AppKit
import DeckCore

/// Domains: local DNS domains, host aliases, the local HTTPS proxy with its routes
/// and aliases, and sharing a route to the internet. Everything here starts off.
struct DomainsScreen: View {
    @Environment(AppState.self) private var state
    @State private var sheet: DomainsSheet?
    @State private var pendingDelete: LocalDomain?
    @State private var pendingAliasDelete: ProxyAlias?
    @State private var showRestart = false
    @State private var isRestarting = false
    @State private var contentWidth: CGFloat = 900
    /// Route whose share picker is open (debug automation can open it).
    @State private var pickerHost: String?

    private var store: DomainsStore { DomainsStore.shared }
    private var feed: BackgroundServices { BackgroundServices.shared }
    private var routes: [ProxyRoute] { store.routes(for: feed.containers) }

    /// Below this width card pairs stack.
    private static let twoColumnWidth: CGFloat = 820

    var body: some View {
        ScrollViewReader { scroller in
            page
                .onDeckDebugCommand { name, value in
                    if name == "domains-scroll" { withAnimation { scroller.scrollTo(value, anchor: .top) } }
                }
        }
    }

    private var page: some View {
        DeckPage {
            if state.client == nil {
                ResourceToolMissing(icon: .domains)
            } else {
                tiles
                pair { domainsCard } and: { proxyCard }
                routesCard.id("routes")
                pair { aliasesCard } and: { shareCard }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .navigationTitle(SidebarItem.domains.title)
        .toolbar {
            ToolbarItem {
                RefreshButton(help: "Reload domains, routes and tools", isBusy: store.domainsLoading) {
                    await reload()
                }
            }
        }
        .task(id: state.resourcesVersion) {
            store.attach(state.client)
            await reload()
        }
        .task(id: feed.containersVersion) {
            await store.learnExposedPorts(feed.containers)
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .domain(let hostAlias):
                AddDomainSheet(startAsHostAlias: hostAlias).environment(state)
            case .alias:
                AddAliasSheet(containers: feed.containers).environment(state)
            case .providerSetup(let id):
                if let provider = ShareProviders.provider(id: id) {
                    ShareSetupSheet(provider: provider).environment(state)
                }
            }
        }
        .alert("Delete \(pendingDelete?.name ?? "")?", isPresented: deleteShown, presenting: pendingDelete) { domain in
            Button("Delete", role: .destructive) { deleteDomain(domain) }
            Button("Cancel", role: .cancel) {}
        } message: { domain in
            Text(domain.isHostAlias
                 ? "Containers can no longer reach this Mac by this name. macOS asks for your admin password."
                 : "Containers can no longer be reached by names in this domain. macOS asks for your admin password.")
        }
        .alert("Remove \(pendingAliasDelete?.pattern ?? "")?", isPresented: aliasDeleteShown, presenting: pendingAliasDelete) { alias in
            Button("Remove", role: .destructive) { removeAlias(alias) }
            Button("Cancel", role: .cancel) {}
        } message: { alias in
            Text(store.installedResolvers.contains(alias.pattern)
                 ? "The proxy stops answering for this name. macOS asks for your admin password to remove its DNS file."
                 : "The proxy stops answering for this name.")
        }
        .confirmationDialog("Restart the container service?", isPresented: $showRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { restartService() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running containers stop.")
        }
        .onDeckDebugCommand { name, value in
            switch name {
            case "domains-add": sheet = .domain(hostAlias: value == "host")
            case "domains-alias": sheet = .alias
            case "proxy-start": run { try await store.startProxy() }
            case "proxy-stop": store.stopProxy()
            case "domains-share":
                // "host" shares with the first provider, "host=ngrok" picks one by id.
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                let provider = parts.count == 2 ? ShareProviders.provider(id: parts[1]) : ShareProviders.all.first
                if let provider, let route = routes.first(where: { $0.host == parts.first }) {
                    run { try await store.share(route, with: provider) }
                }
            case "domains-share-setup": sheet = .providerSetup(value)
            case "domains-share-picker": pickerHost = value
            case "domains-unshare": store.stopSharing(value)
            case "domains-alias-add":
                // "pattern=container"
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { store.addAlias(ProxyAlias(pattern: parts[0], container: parts[1])) }
            case "domains-alias-remove":
                if let alias = store.aliases.first(where: { $0.pattern == value }) { removeAlias(alias) }
            default: break
            }
        }
    }

    @ViewBuilder
    private func pair<A: View, B: View>(@ViewBuilder _ first: () -> A, @ViewBuilder and second: () -> B) -> some View {
        if contentWidth >= Self.twoColumnWidth {
            EqualHeightRow {
                first()
                second()
            }
        } else {
            first()
            second()
        }
    }

    private func reload() async {
        await store.loadDomains()
        store.refreshCertificateState()
        store.refreshResolvers()
        await store.refreshTools()
    }

    // MARK: - Tiles

    private var tiles: some View {
        EqualHeightRow {
            MetricTile(
                title: "Domains",
                value: "\(store.domains.count)",
                subtitle: store.savedDefault.map { "Default \($0)" } ?? "No default",
                icon: .dns
            )
            MetricTile(
                title: "Routes",
                value: "\(routes.count)",
                subtitle: routesSubtitle,
                icon: .link
            )
            MetricTile(
                title: "HTTPS proxy",
                value: store.proxyRunning ? "On" : "Off",
                subtitle: store.proxyRunning ? "Port \(store.displayPort)" : "Starts when you turn it on",
                icon: .lock,
                tint: store.proxyRunning ? DS.running : DS.stopped
            )
            MetricTile(
                title: "Public",
                value: "\(store.sharedCount)",
                subtitle: store.sharedCount == 0 ? "Nothing shared" : "On the internet now",
                icon: .share,
                tint: store.sharedCount == 0 ? DS.stopped : DS.warning
            )
        }
    }

    private var routesSubtitle: String {
        let reachable = routes.filter(\.isReachable).count
        if routes.isEmpty { return "No containers yet" }
        return reachable == routes.count ? "All reachable" : "\(reachable) reachable"
    }

    // MARK: - Domains card

    private var domainsCard: some View {
        Card("Local domains", icon: .dns) {
            Text(verbatim: "Containers get names like web.\(store.savedDefault ?? AppConfig.defaultDNSDomain). A host alias lets containers reach services on this Mac by name.")
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                if !store.domainsLoaded && store.domainsLoading {
                    ForEach(0..<2, id: \.self) { _ in
                        SkeletonBlock(height: 18).padding(.vertical, 9)
                    }
                } else if store.domains.isEmpty {
                    // Centered in the room the card gets from its taller neighbour.
                    VStack(spacing: 6) {
                        DeckIcon(.dns, size: 22, color: DS.textTertiary)
                        Text("No local domains yet")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(DS.textSecondary)
                        Text("Add one to reach containers by name.")
                            .font(.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)
                }
                ForEach(Array(store.domains.enumerated()), id: \.element.id) { index, domain in
                    if index > 0 { Divider() }
                    domainRow(domain)
                }
            }
            if let error = store.domainsError {
                ResourceErrorText(error)
            }
            if store.needsRestartForDefault {
                HStack(spacing: 8) {
                    ResourceWarningText("Saved. Restart the container service to use the new default.")
                    Spacer(minLength: 0)
                    Button("Restart Service") { showRestart = true }
                        .controlSize(.small)
                        .disabled(isRestarting)
                }
            }
            if !store.domains.isEmpty || !store.domainsLoaded {
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { sheet = .domain(hostAlias: false) } label: { DeckLabel("Add Domain", icon: .add) }
                    .deckPrimary()
                Button { sheet = .domain(hostAlias: true) } label: { DeckLabel("Reach This Mac", icon: .link) }
                    .buttonStyle(SoftAccentButtonStyle())
                    .help("Add a name containers use to reach services on this Mac")
                Spacer(minLength: 0)
                adminNote
            }
        }
    }

    private func domainRow(_ domain: LocalDomain) -> some View {
        HStack(spacing: 8) {
            Text(domain.name).font(.body.monospaced())
            if domain.name == store.savedDefault {
                Pill("Default", tint: DS.running)
            }
            if let address = domain.localhostAddress {
                Pill("This Mac", tint: DS.accent)
                    .help("Containers that use \(domain.name) reach this Mac. Traffic to \(address) goes to 127.0.0.1.")
            }
            Spacer(minLength: 8)
            if store.busyDomain == domain.name {
                ProgressView().controlSize(.small)
            } else {
                if store.canSetDefault && !domain.isHostAlias && domain.name != store.savedDefault {
                    Button("Make Default") { makeDefault(domain.name) }
                        .controlSize(.small)
                }
                Button(role: .destructive) { pendingDelete = domain } label: { DeckIcon(.trash, size: 13) }
                    .buttonStyle(.borderless)
                    .help("Delete \(domain.name)")
            }
        }
        .padding(.vertical, 7)
    }

    private var adminNote: some View {
        HStack(spacing: 5) {
            DeckIcon(.lock, size: 11, color: DS.textTertiary)
            Text("Needs your admin password")
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
        }
    }

    // MARK: - Proxy card

    private var proxyCard: some View {
        Card("HTTPS proxy", icon: .lock) {
            Text(verbatim: "Open containers at https://name.localhost with a trusted certificate. Listens only on this Mac.")
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                KeyValueRow("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(store.proxyRunning ? DS.running : DS.stopped).frame(width: 7, height: 7)
                        Text(store.proxyRunning ? "Running on 127.0.0.1:\(String(store.proxyPort))" : "Off")
                            .font(.callout)
                    }
                }
                KeyValueRow("Certificate") {
                    HStack(spacing: 8) {
                        if !store.caExists {
                            Pill("Not made yet", tint: DS.stopped)
                        } else if store.caTrusted {
                            Pill("Trusted", tint: DS.running)
                        } else {
                            Pill("Not trusted", tint: DS.warning)
                        }
                        Spacer(minLength: 0)
                        certificateButtons
                    }
                }
                KeyValueRow("Port 443") {
                    HStack(spacing: 8) {
                        Text(store.redirectActive ? "On, links have no port" : "Off, links use :\(String(store.proxyPort))")
                            .font(.callout)
                            .foregroundStyle(store.redirectActive ? DS.textPrimary : DS.textSecondary)
                        Spacer(minLength: 0)
                        if store.redirectBusy {
                            ProgressView().controlSize(.small)
                        } else if store.redirectActive {
                            Button("Turn Off") { run { try await store.removeRedirect() } }
                                .controlSize(.small)
                        } else {
                            Button("Use Port 443") { run { try await store.installRedirect() } }
                                .controlSize(.small)
                                .help("Adds a packet filter rule that sends 127.0.0.1 port 443 to the proxy. Needs your admin password. Gone after a restart.")
                        }
                    }
                }
                if store.port443Busy && !store.redirectActive {
                    ResourceWarningText("Another app listens on port 443. Using 443 here sends 127.0.0.1 traffic to the proxy instead.")
                }
                if !store.caTrusted && store.caExists {
                    ResourceWarningText("Browsers warn until you trust the certificate. You approve it once in Keychain.")
                }
                if let error = store.proxyError, !store.proxyRunning {
                    ResourceErrorText(error)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if store.proxyRunning {
                    Button { store.stopProxy() } label: { DeckLabel("Stop Proxy", icon: .stop) }
                } else {
                    Button { run { try await store.startProxy() } } label: { DeckLabel("Start Proxy", icon: .play) }
                        .deckPrimary()
                        .disabled(store.proxyBusy)
                }
                if store.proxyBusy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Toggle("Start with the app", isOn: autoStartBinding)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var certificateButtons: some View {
        if store.caBusy {
            ProgressView().controlSize(.small)
        } else if store.caTrusted {
            Button("Remove Trust") { run { try await store.untrustAuthority() } }
                .controlSize(.small)
        } else {
            Button("Trust in Keychain") { run { try await store.trustAuthority() } }
                .controlSize(.small)
                .help("Adds the proxy's own certificate authority to your login keychain. macOS asks you to approve.")
        }
        if store.caExists {
            Button { NSWorkspace.shared.activateFileViewerSelecting([store.caCertificateURL]) } label: { DeckIcon(.folder, size: 12) }
                .buttonStyle(.borderless)
                .help("Show the certificate in Finder")
        }
    }

    private var autoStartBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: PrefKey.proxyAutoStart) },
            set: { UserDefaults.standard.set($0, forKey: PrefKey.proxyAutoStart) }
        )
    }

    // MARK: - Routes card

    private var routesCard: some View {
        Card("Routes", icon: .link) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "One link per container. The port comes from the \(DomainsConfig.portLabel) label, a published port or the image. Add aliases for other names.")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if routes.isEmpty {
                EmptyState(icon: .link, title: "No routes yet", message: "Start a container to get a link like https://web.localhost.")
                    .frame(height: 170)
            } else {
                VStack(spacing: 0) {
                    routeHeader
                    ForEach(routes) { route in
                        Divider()
                        RouteRow(route: route, store: store, port: store.displayPort, pickerHost: $pickerHost,
                                 onError: { error in state.showError(error) },
                                 onSetup: { provider in sheet = .providerSetup(provider.id) })
                    }
                }
            }
            HStack(spacing: 12) {
                Text(routesStatus)
                    .font(.caption)
                    .foregroundStyle(DS.textTertiary)
                    .fixedSize()
                Spacer(minLength: 0)
                CommandHint("container run -l \(DomainsConfig.portLabel)=3000 ...")
                    .frame(maxWidth: 380)
            }
        }
    }

    private var routeHeader: some View {
        HStack(spacing: 12) {
            Text("Link").frame(maxWidth: .infinity, alignment: .leading)
            Text("Container").frame(width: RouteRow.containerWidth, alignment: .leading)
            Text("Target").frame(width: RouteRow.targetWidth, alignment: .leading)
            Text("Port from").frame(width: RouteRow.sourceWidth, alignment: .leading)
            Text("").frame(width: RouteRow.actionsWidth)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(DS.textSecondary)
        .padding(.vertical, 6)
    }

    private var routesStatus: String {
        let live = routes.filter(\.isReachable).count
        let served = store.requestsByHost.values.reduce(0, +)
        var text = "\(live) of \(routes.count) reachable"
        if store.proxyRunning { text += ", \(served) connections served" }
        return text
    }

    // MARK: - Aliases card

    private var aliasesCard: some View {
        Card("Aliases", icon: .tag) {
            Text(verbatim: "Extra names for a container, like api.localhost or *.gateway.test for every name below a domain. Names under .localhost work at once. Others need one admin step.")
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                if store.aliases.isEmpty {
                    Text("No aliases yet.")
                        .font(.callout)
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                ForEach(Array(store.aliases.enumerated()), id: \.element.id) { index, alias in
                    if index > 0 { Divider() }
                    aliasRow(alias)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button { sheet = .alias } label: { DeckLabel("Add Alias", icon: .add) }
                    .deckPrimary()
                Spacer(minLength: 0)
            }
        }
    }

    private func aliasRow(_ alias: ProxyAlias) -> some View {
        HStack(spacing: 8) {
            Text(alias.pattern).font(.body.monospaced())
            DeckIcon(.chevronRight, size: 10, color: DS.textTertiary)
            Text(alias.port.map { "\(alias.container):\($0)" } ?? alias.container)
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if alias.needsResolver {
                if store.installedResolvers.contains(alias.pattern) {
                    Pill("DNS ready", tint: DS.running)
                } else {
                    Button("Set Up DNS") { run { try await store.installResolver(for: alias) } }
                        .controlSize(.small)
                        .help("Adds \(AliasResolverFiles.path(for: alias.pattern)) so this Mac asks the proxy for these names. Needs your admin password.")
                }
            }
            Button(role: .destructive) { pendingAliasDelete = alias } label: { DeckIcon(.trash, size: 13) }
                .buttonStyle(.borderless)
                .help("Remove \(alias.pattern)")
        }
        .padding(.vertical, 7)
    }

    // MARK: - Share card

    private var shareCard: some View {
        Card("Share to the internet", icon: .share) {
            Text(verbatim: "Give a route a public link for a demo or a webhook. Anyone with the link can open it, so stop it when you are done.")
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { Divider() }
                    ProviderStatusRow(provider: provider, store: store,
                                      onSetup: { sheet = .providerSetup(provider.id) },
                                      onError: { state.showError($0) })
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text(store.sharedCount == 0 ? "Use Share on a route to start." : "\(store.sharedCount) shared now")
                    .font(.caption)
                    .foregroundStyle(DS.textTertiary)
                Spacer(minLength: 0)
                if store.activeShareCount > 0 {
                    Button(role: .destructive) { store.stopAllSharing() } label: { DeckLabel("Stop All Sharing", icon: .stop) }
                }
            }
        }
    }

    // MARK: - Actions

    private var deleteShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var aliasDeleteShown: Binding<Bool> {
        Binding(get: { pendingAliasDelete != nil }, set: { if !$0 { pendingAliasDelete = nil } })
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { state.showError(error) }
        }
    }

    private func deleteDomain(_ domain: LocalDomain) {
        run {
            try await store.deleteDomain(domain.name)
            state.showToast("Removed \(domain.name)", style: .success)
            state.resourcesChanged()
        }
    }

    private func makeDefault(_ name: String) {
        run {
            try await store.makeDefault(name)
            state.dnsDomain = name
            state.showToast("Default domain is now \(name). Restart the service to apply.", style: .success)
        }
    }

    private func removeAlias(_ alias: ProxyAlias) {
        run {
            try await store.removeAlias(alias)
            state.showToast("Removed \(alias.pattern)", style: .success)
        }
    }

    private func restartService() {
        guard let client = state.client, !isRestarting else { return }
        Task {
            guard await state.confirmServiceStop(restart: true) else { return }
            BackgroundServices.shared.noteServiceStopping()
            isRestarting = true
            do {
                try await client.restartSystemService()
                state.showToast("The container service restarted", style: .success)
            } catch {
                state.showError(error)
            }
            await state.refresh()
            state.resourcesChanged()
            isRestarting = false
        }
    }
}

enum DomainsSheet: Identifiable {
    case domain(hostAlias: Bool)
    case alias
    case providerSetup(String)

    var id: String {
        switch self {
        case .domain(let host): return host ? "host" : "domain"
        case .alias: return "alias"
        case .providerSetup(let id): return "setup-" + id
        }
    }
}

/// One route in the routes card.
struct RouteRow: View {
    let route: ProxyRoute
    let store: DomainsStore
    let port: UInt16
    @Binding var pickerHost: String?
    let onError: (Error) -> Void
    let onSetup: (any ShareProvider) -> Void

    static let containerWidth: CGFloat = 150
    static let targetWidth: CGFloat = 150
    static let sourceWidth: CGFloat = 110
    static let actionsWidth: CGFloat = 150

    private var tunnel: TunnelSession.State? { store.state(for: route) }
    private var link: String { route.url(port: port) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(link)
                        .font(.callout.monospaced())
                        .foregroundStyle(route.isReachable ? DS.textPrimary : DS.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    statusPill
                }
                if case .live(let url) = tunnel {
                    Text(url)
                        .font(.caption.monospaced())
                        .foregroundStyle(DS.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else if case .failed(let failure) = tunnel {
                    failureLine(failure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(route.container)
                .font(.callout)
                .lineLimit(1)
                .frame(width: Self.containerWidth, alignment: .leading)
            Text(route.target)
                .font(.callout.monospaced())
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .frame(width: Self.targetWidth, alignment: .leading)
            Text(route.source.title)
                .font(.callout)
                .foregroundStyle(route.source == .fallback ? DS.warning : DS.textSecondary)
                .help(route.source == .fallback ? "No label, published port or image port. Set \(DomainsConfig.portLabel) to pick one." : "")
                .frame(width: Self.sourceWidth, alignment: .leading)
            actions
                .frame(width: Self.actionsWidth, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch tunnel {
        case .live: Pill("Public", tint: DS.warning)
        case .starting: Pill("Sharing", tint: DS.stopped)
        case .failed: Pill("Share failed", tint: DS.danger)
        default:
            if !route.isRunning { Pill("Stopped", tint: DS.stopped) }
            else if route.source == .alias && HostName.needsResolver(route.host) && !store.installedResolvers.contains(route.host) {
                Pill("Needs DNS", tint: DS.warning)
                    .help("Use Set Up DNS on the alias so this Mac finds the name.")
            } else if route.isWildcard { Pill("Wildcard", tint: DS.accent) }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { open(link) } label: { DeckIcon(.openExternal, size: 13) }
                .buttonStyle(.borderless)
                .disabled(!store.proxyRunning || !route.isReachable || route.isWildcard)
                .help(store.proxyRunning ? "Open in your browser" : "Start the proxy to open this link")
            Button { copy(tunnelURL ?? link) } label: { DeckIcon(.copy, size: 13) }
                .buttonStyle(.borderless)
                .help(tunnelURL == nil ? "Copy link" : "Copy public link")
            if isActive {
                Button { store.stopSharing(route.host) } label: { DeckLabel("Stop", icon: .stop) }
                    .controlSize(.small)
                    .help("Stop sharing. The public link stops working at once.")
            } else {
                shareMenu
            }
        }
    }

    private var isActive: Bool {
        switch tunnel {
        case .starting, .live: return true
        default: return false
        }
    }

    private var pickerShown: Binding<Bool> {
        Binding(get: { pickerHost == route.host }, set: { pickerHost = $0 ? route.host : nil })
    }

    private var shareMenu: some View {
        Button("Share") { pickerHost = route.host }
            .buttonStyle(.borderless)
            .disabled(!route.isReachable || route.isWildcard)
            .help("Give this route a public link")
            .popover(isPresented: pickerShown, arrowEdge: .leading) {
                SharePickerPopover(route: route, store: store,
                                   onShare: { provider in
                                       pickerHost = nil
                                       share(with: provider)
                                   },
                                   onSetup: { provider in
                                       pickerHost = nil
                                       onSetup(provider)
                                   },
                                   onError: onError)
            }
    }

    private func share(with provider: any ShareProvider) {
        Task { do { try await store.share(route, with: provider) } catch { onError(error) } }
    }

    /// One short line: what went wrong, then the fixes. The full text with the fix is in the tooltip.
    private func failureLine(_ failure: ShareFailure) -> some View {
        let current = store.provider(for: route)
        let other = failure.otherProviderMayWork ? store.alternatives(for: route, excluding: current?.id).first : nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(failure.message)
                .font(.caption)
                .foregroundStyle(DS.danger)
                .lineLimit(2)
                .help([failure.errorDescription, failure.code].compactMap { $0 }.joined(separator: " "))
            Group {
                if failure.opensSetup, let current {
                    Button("Set Up") { onSetup(current) }
                } else if let link = failure.link {
                    Button("Open") { NSWorkspace.shared.open(link) }
                        .help(link.absoluteString)
                }
                if let other {
                    Button("Try \(other.title)") { share(with: other) }
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DS.accent)
            .font(.caption.weight(.medium))
            .fixedSize()
            Button { store.stopSharing(route.host) } label: { DeckIcon(.close, size: 9) }
                .buttonStyle(.borderless)
                .help("Clear")
        }
    }

    private var tunnelURL: String? {
        if case .live(let url) = tunnel { return url }
        return nil
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
