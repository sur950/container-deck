import SwiftUI
import DeckCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case containers, compose, machines
    case images, volumes, networks
    case importEngines
    case builds, kubernetes, aiModels, sandboxes, agents, domains

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .containers: return "Containers"
        case .compose: return "Compose"
        case .machines: return "Machines"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .importEngines: return "Import"
        case .builds: return "Builds"
        case .kubernetes: return "Kubernetes"
        case .aiModels: return "AI Models"
        case .sandboxes: return "Sandboxes"
        case .agents: return "Agents and MCP"
        case .domains: return "Domains"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .containers: return "shippingbox"
        case .compose: return "square.stack.3d.up"
        case .machines: return "desktopcomputer"
        case .images: return "square.3.layers.3d"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .importEngines: return "square.and.arrow.down.on.square"
        case .builds: return "wrench.and.screwdriver"
        case .kubernetes: return "helm"
        case .aiModels: return "brain"
        case .sandboxes: return "shield.lefthalf.filled"
        case .agents: return "person.2"
        case .domains: return "network.badge.shield.half.filled"
        }
    }

    /// Custom icon for the sidebar, palette and placeholders.
    var deckIcon: DeckIconName {
        switch self {
        case .dashboard: return .dashboard
        case .containers: return .containers
        case .compose: return .compose
        case .machines: return .machines
        case .images: return .images
        case .volumes: return .volumes
        case .networks: return .networks
        case .importEngines: return .importEngines
        case .builds: return .builds
        case .kubernetes: return .kubernetes
        case .aiModels: return .aiModels
        case .sandboxes: return .sandboxes
        case .agents: return .agents
        case .domains: return .domains
        }
    }

    /// Plan phase that delivers this screen.
    var phase: Int {
        switch self {
        case .dashboard: return 1
        case .containers, .images, .volumes, .networks: return 2
        case .machines: return 3
        case .importEngines: return 4
        case .builds: return 7
        case .domains: return 8
        case .aiModels: return 9
        case .sandboxes, .agents: return 10
        case .kubernetes: return 11
        case .compose: return 5
        }
    }

    var summary: String {
        switch self {
        case .dashboard: return "Service status, resources and disk use."
        case .containers: return "Run, stop, inspect and open a shell in your containers."
        case .compose: return "Import compose files and run whole stacks."
        case .machines: return "Lightweight Linux VMs with your home folder mounted."
        case .images: return "Pull, build, tag and clean up images. Search Docker Hub and your registries."
        case .volumes: return "Create, browse and clean up volumes."
        case .networks: return "Create and manage container networks."
        case .importEngines: return "Bring images over from Docker Desktop, OrbStack, Rancher, Podman and Colima."
        case .builds: return "Every image build with its log, time and result."
        case .kubernetes: return "Local Kubernetes clusters on Apple's container platform."
        case .aiModels: return "Run local AI models and find the ones already on this Mac."
        case .sandboxes: return "Isolated containers for AI agents, with a network allow list and a kill switch."
        case .agents: return "MCP servers and AI agents, connected to Claude, OpenAI, Gemini and local models."
        case .domains: return "Local domains, HTTPS and tunnels for your containers."
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var columns: NavigationSplitViewVisibility = .automatic
    private let updates = AppUpdates.shared

    /// A compulsory update covers the window. Nothing underneath reacts until it is installed.
    private var blocked: Bool { updates.required != nil }

    var body: some View {
        // Bindings only. Closures below use the environment `state`, not a captured local var.
        @Bindable var bindableState = state
        let blocked = blocked

        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                if !state.report.checks.isEmpty, let issue = state.report.firstIssue {
                    HealthBanner(issue: issue)
                }
                VersionNoticeBanner()
                DetailView(item: state.selection ?? .dashboard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // One surface from the title bar down. AppKit draws its own title bar background
            // a few points left of the column divider, which looked misaligned next to the sidebar.
            .background(DS.surface.ignoresSafeArea())
            .overlay(alignment: .top) { ToolbarBackdrop() }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .tint(DS.accent)
        // While blocked: no clicks or shortcuts underneath. The toolbar is hidden below.
        .disabled(blocked)
        .accessibilityHidden(blocked)
        .sheet(isPresented: $bindableState.showSetup.unless(blocked)) {
            SetupGuideView()
                .environment(state)
                .tint(DS.accent)
        }
        .sheet(isPresented: $bindableState.showPalette.unless(blocked)) {
            CommandPalette()
                .environment(state)
                .tint(DS.accent)
        }
        .sheet(item: $bindableState.runRequest.unless(blocked)) { request in
            RunSheet(request: request)
                .environment(state)
                .tint(DS.accent)
        }
        .sheet(item: $bindableState.buildRequest.unless(blocked)) { request in
            BuildSheet(request: request)
                .environment(state)
                .tint(DS.accent)
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(toast.style == .error ? 6 : 3))
                        if state.toast?.id == toast.id { state.toast = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: state.toast)
        .overlay { LaunchSplash() }
        .overlay {
            if let required = updates.required {
                RequiredUpdateView(update: required)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: blocked)
        .onChange(of: blocked, initial: true) { _, isBlocked in
            // Sheets opened by screens sit above the window. Close them so nothing covers the screen.
            // RequiredUpdateView hides the toolbar and title itself.
            guard isBlocked else { return }
            DispatchQueue.main.async {
                for window in NSApp.windows where window.sheetParent != nil && window.sheetParent == MainWindow.existing {
                    window.sheetParent?.endSheet(window)
                }
            }
        }
        .onChange(of: columns) { _, _ in
            // The toolbar's sidebar button keeps keyboard focus after a click, which leaves a
            // focus ring around it when keyboard navigation is on. Give focus back to the window.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onAppear {
            // A window just opened (maybe from the menu bar panel): bring back the Dock icon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { AppWindows.updatePolicy() }
        }
        .onOpenURL { url in
            DeepLinkRouter.handle(url, state: state)
        }
        .task {
            if DebugAutomation.isEnabled {
                DebugAutomation.shared.attach(state)
                DebugAutomation.shared.openWindow = { id in openWindow(id: id) }
                DebugAutomation.shared.openSettings = { openSettings() }
            }
            await state.refresh()
            BackgroundServices.shared.start(state: state)
        }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var state
    /// Ids of the sections the person folded, comma separated.
    @AppStorage("sidebar.collapsedGroups") private var collapsedRaw = ""

    private struct SidebarGroup: Identifiable {
        let id: String
        let title: String?
        let items: [SidebarItem]
    }

    private static let groups: [SidebarGroup] = [
        SidebarGroup(id: "home", title: nil, items: [.dashboard]),
        SidebarGroup(id: "workloads", title: "Workloads", items: [.containers, .compose, .machines, .kubernetes]),
        SidebarGroup(id: "build", title: "Build", items: [.builds]),
        SidebarGroup(id: "ai", title: "AI", items: [.aiModels, .sandboxes, .agents]),
        SidebarGroup(id: "resources", title: "Resources", items: [.images, .volumes, .networks, .domains]),
        SidebarGroup(id: "move", title: "Move in", items: [.importEngines]),
    ]

    var body: some View {
        @Bindable var bindableState = state
        List(selection: $bindableState.selection) {
            ForEach(Self.groups) { group in
                if let title = group.title {
                    Section {
                        if isOpen(group) { rows(group.items) }
                    } header: {
                        sectionHeader(group, title: title)
                    }
                } else {
                    Section { rows(group.items) }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.selection) { _, item in
            // Opening a screen from the palette or a link shows its section.
            guard let item, let group = Self.groups.first(where: { $0.items.contains(item) }), !isOpen(group) else { return }
            withAnimation(.easeInOut(duration: 0.18)) { setOpen(group, true) }
        }
        .accentColor(DS.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
    }

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: ",").map(String.init))
    }

    private func isOpen(_ group: SidebarGroup) -> Bool { !collapsed.contains(group.id) }

    private func setOpen(_ group: SidebarGroup, _ open: Bool) {
        var set = collapsed
        if open { set.remove(group.id) } else { set.insert(group.id) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    /// The whole header row folds and unfolds the section. The chevron is always visible.
    private func sectionHeader(_ group: SidebarGroup, title: String) -> some View {
        let open = isOpen(group)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { setOpen(group, !open) }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 6)
                DeckIcon(.chevronRight, size: 10, color: DS.textSecondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14, height: 14)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide \(title)" : "Show \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides this section")
    }

    @ViewBuilder
    private func rows(_ items: [SidebarItem]) -> some View {
        ForEach(items) { item in
            Label {
                Text(item.title)
            } icon: {
                SidebarIcon(icon: item.deckIcon, isSelected: state.selection == item)
            }
            .tag(item)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrandLockup(badgeSize: 30, titleSize: 13)
            Divider()
            Button {
                state.showSetup = true
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(serviceColor)
                        .frame(width: 7, height: 7)
                    Text(serviceText)
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open setup")
        }
        .padding(12)
        .deckCard(radius: 12)
        .padding(10)
    }

    private var serviceText: String {
        if state.report.checks.isEmpty { return "Checking your Mac" }
        if state.report.cliPath == nil { return "Not set up yet" }
        return state.report.serviceRunning ? "Service running" : "Service stopped"
    }

    private var serviceColor: Color {
        if state.report.checks.isEmpty { return DS.stopped }
        if state.report.cliPath == nil { return DS.warning }
        return state.report.serviceRunning ? DS.running : DS.stopped
    }
}

/// Sidebar icon with explicit colors. The vibrant sidebar turns the default
/// foreground style almost black in Dark mode.
private struct SidebarIcon: View {
    let icon: DeckIconName
    let isSelected: Bool
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if prominence == .increased {
            // Selected row in a focused list: solid accent background.
            DeckIcon(icon, size: 16, color: .white)
                .environment(\.deckIconMonochrome, true)
        } else {
            DeckIcon(icon, size: 16, color: isSelected ? DS.accent : DS.textSecondary)
        }
    }
}

struct DetailView: View {
    let item: SidebarItem
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // No app wide rebuild on a Light and Dark switch: it dropped every selection.
        // Menus that kept their old text color rebuild themselves locally (.id(colorScheme)).
        content
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .dashboard: DashboardView()
        case .containers: ContainersScreen()
        case .compose: ComposeScreen()
        case .machines: MachinesScreen()
        case .images: ImagesScreen()
        case .volumes: VolumesScreen()
        case .networks: NetworksScreen()
        case .importEngines: ImportScreen()
        case .builds: BuildsScreen()
        case .kubernetes: KubernetesScreen()
        case .aiModels: AIModelsScreen()
        case .sandboxes: SandboxesScreen()
        case .agents: AgentsScreen()
        case .domains: DomainsScreen()
        }
    }
}

/// The window toolbar is transparent (see RootView), so scrolled content would show through
/// behind the title. This band covers the toolbar area of the detail column with the page
/// surface and draws a hairline under it, so pages scroll under a solid header.
private struct ToolbarBackdrop: View {
    var body: some View {
        Rectangle()
            .fill(DS.border)
            .frame(height: 1)
            .background(alignment: .bottom) {
                DS.surface.ignoresSafeArea(edges: .top)
            }
            .shadow(color: DS.shadow, radius: 3, y: 1)
            .allowsHitTesting(false)
    }
}

/// First window of a launch: the animated logo covers the window until the first container
/// list arrives. It stays at least until the logo has built itself once, so it never flashes,
/// and gives up after a few seconds so a slow service never blocks the app.
private struct LaunchSplash: View {
    @Environment(AppState.self) private var state
    @State private var visible = !LaunchSplash.shown
    @State private var minimumDone = false
    @State private var timedOut = false

    @MainActor private static var shown = false
    private static let maximumWait: Duration = .seconds(6)

    private var dataReady: Bool {
        BackgroundServices.shared.hasLoaded
            || (state.client == nil && !state.report.checks.isEmpty)
    }

    var body: some View {
        ZStack {
            if visible {
                VStack(spacing: 18) {
                    DeckLogoLoader(size: 92)
                    Text(AppConfig.appName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(DS.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.surface.ignoresSafeArea())
                .transition(.opacity)
            }
        }
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.3), value: visible)
        .task {
            guard visible else { return }
            Self.shown = true
            try? await Task.sleep(for: .seconds(LogoTimeline.holdStart + 0.15))
            minimumDone = true
            try? await Task.sleep(for: Self.maximumWait)
            timedOut = true
        }
        .onChange(of: minimumDone && (dataReady || timedOut), initial: true) { _, ready in
            if ready { visible = false }
        }
    }
}

private extension Binding where Value == Bool {
    /// Reads false while `blocked`, so the sheet closes or never opens. Writes go through.
    func unless(_ blocked: Bool) -> Binding<Bool> {
        Binding(get: { !blocked && wrappedValue }, set: { wrappedValue = $0 })
    }
}

private extension Binding {
    /// Reads nil while `blocked`, so the sheet closes or never opens. Writes go through.
    func unless<Wrapped>(_ blocked: Bool) -> Binding<Wrapped?> where Value == Wrapped? {
        Binding<Wrapped?>(get: { blocked ? nil : wrappedValue }, set: { wrappedValue = $0 })
    }
}
