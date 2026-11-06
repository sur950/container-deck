import SwiftUI
import AppKit
import DeckCore

/// Something the palette can do. The palette view runs these, so confirmations
/// and follow up sheets live in one place.
enum PaletteAction {
    case screen(SidebarItem)
    case custom(title: String, icon: DeckIconName, perform: @MainActor (AppState) -> Void)
    case container(ContainerOp, id: String, name: String)
    case containerOpen(id: String, tab: String?)
    case containerShell(id: String)
    case machineBoot(String), machineStop(String), machineDelete(String), machineShell(String), machineOpen(String)
    case imageOpen(String), imageRun(String), imagePull(String), imageDelete(String)
    case volumeOpen(String), volumeDelete(String)
    case networkOpen(String), networkDelete(String)
    case stackOpen(name: String, file: String?)
    case pruneContainers
    case stopService

    /// Short label for key hints, like "Open" or "Stop".
    var label: String {
        switch self {
        case .screen: return "Go"
        case .custom: return "Run"
        case .container(let op, _, _): return op.title
        case .containerOpen(_, let tab): return tab == "logs" ? "Logs" : "Open"
        case .containerShell, .machineShell: return "Shell"
        case .machineBoot: return "Start"
        case .machineStop: return "Stop"
        case .imageRun: return "Run"
        case .imagePull: return "Pull"
        case .machineDelete, .imageDelete, .volumeDelete, .networkDelete: return "Delete"
        case .pruneContainers: return "Remove"
        case .stopService: return "Stop"
        case .machineOpen, .imageOpen, .volumeOpen, .networkOpen, .stackOpen: return "Open"
        }
    }

    var icon: DeckIconName {
        switch self {
        case .screen(let item): return item.deckIcon
        case .custom(_, let icon, _): return icon
        case .container(let op, _, _): return op.icon
        case .containerOpen(_, let tab): return tab == "logs" ? .logs : .inspect
        case .containerShell, .machineShell: return .terminal
        case .machineBoot: return .play
        case .machineStop, .stopService: return .stop
        case .imageRun: return .play
        case .imagePull: return .pull
        case .machineDelete, .imageDelete, .volumeDelete, .networkDelete: return .trash
        case .pruneContainers: return .prune
        case .machineOpen: return .machines
        case .imageOpen: return .images
        case .volumeOpen: return .volumes
        case .networkOpen: return .networks
        case .stackOpen: return .compose
        }
    }

    /// Asks before running. Text for the confirmation, or nil to run right away.
    var confirmation: (title: String, message: String, button: String)? {
        switch self {
        case .container(.delete, _, let name):
            return ("Delete \(name)?", "The container is stopped and removed. This cannot be undone.", "Delete")
        case .container(.kill, _, let name):
            return ("Kill \(name)?", "The container stops right away. Unsaved work is lost.", "Kill")
        case .machineDelete(let name):
            return ("Delete \(name)?", "This removes the machine and its disk. Files in your Mac home folder stay as they are.", "Delete Machine")
        case .imageDelete(let ref):
            return ("Delete \(ContainerText.shortImage(ref))?", "The image is removed from this Mac. You can pull it again later.", "Delete")
        case .volumeDelete(let name):
            return ("Delete volume \(name)?", "All data in the volume is lost. This cannot be undone.", "Delete")
        case .networkDelete(let name):
            return ("Delete network \(name)?", "Containers on it lose this network.", "Delete")
        case .pruneContainers:
            return ("Remove stopped containers?", "Every stopped container is deleted. The image builder stays.", "Remove")
        default:
            return nil
        }
    }
}

/// One row in the palette.
struct PaletteRow: Identifiable {
    /// Unique per row. Verb rows add the verb, so "stop web" and "web" differ.
    let id: String
    /// Entry id, saved in recents.
    let entryID: String
    let kind: PaletteKind
    /// Text before the name, like "Stop", drawn quieter. Empty for plain rows.
    var verbPrefix: String = ""
    let title: String
    var subtitle: String?
    let icon: DeckIconName
    var status: ContainerRunState?
    var badge: String?
    var highlights: [Range<Int>] = []
    let primary: PaletteAction
    var alternate: PaletteAction?
}

/// A resource or command the palette knows, before ranking.
struct PaletteResource {
    var entry: PaletteEntry
    var icon: DeckIconName
    var status: ContainerRunState?
    var badge: String?
    var payload: Payload

    enum Payload {
        case screen(SidebarItem)
        case action(PaletteAction)
        case container(ContainerSummary)
        case image(ImageSummary)
        case volume(VolumeSummary)
        case network(NetworkSummary)
        case machine(MachineSummary)
        case stack(ComposeStack)
    }

    /// What Enter and Cmd+Enter do on a plain (no verb) row.
    var actions: (primary: PaletteAction, alternate: PaletteAction?) {
        switch payload {
        case .screen(let item): return (.screen(item), nil)
        case .action(let action): return (action, nil)
        case .container(let c):
            return (.containerOpen(id: c.id, tab: nil),
                    c.isRunning ? .container(.stop, id: c.id, name: c.name) : .container(.start, id: c.id, name: c.name))
        case .image(let image): return (.imageOpen(image.reference), .imageRun(image.reference))
        case .volume(let volume): return (.volumeOpen(volume.name), nil)
        case .network(let network): return (.networkOpen(network.name), nil)
        case .machine(let m): return (.machineOpen(m.name), m.state == .running ? .machineStop(m.name) : .machineBoot(m.name))
        case .stack(let stack): return (.stackOpen(name: stack.name, file: stack.file?.path), nil)
        }
    }

    /// The verb applied to this resource, or nil when it does not fit
    /// (for example "start" on a running container).
    func action(for verb: PaletteVerb) -> PaletteAction? {
        switch (verb, payload) {
        case (.start, .container(let c)): return c.isRunning ? nil : .container(.start, id: c.id, name: c.name)
        case (.stop, .container(let c)): return c.isRunning ? .container(.stop, id: c.id, name: c.name) : nil
        case (.restart, .container(let c)): return .container(.restart, id: c.id, name: c.name)
        case (.logs, .container(let c)): return .containerOpen(id: c.id, tab: "logs")
        case (.shell, .container(let c)): return c.isRunning ? .containerShell(id: c.id) : nil
        case (.delete, .container(let c)): return .container(.delete, id: c.id, name: c.name)
        case (.inspect, .container(let c)): return .containerOpen(id: c.id, tab: nil)
        case (.start, .machine(let m)): return m.state == .running ? nil : .machineBoot(m.name)
        case (.stop, .machine(let m)): return m.state == .running ? .machineStop(m.name) : nil
        case (.shell, .machine(let m)): return m.state == .running ? .machineShell(m.name) : nil
        case (.delete, .machine(let m)): return .machineDelete(m.name)
        case (.inspect, .machine(let m)): return .machineOpen(m.name)
        case (.run, .image(let i)): return .imageRun(i.reference)
        case (.pull, .image(let i)): return .imagePull(i.reference)
        case (.delete, .image(let i)): return .imageDelete(i.reference)
        case (.inspect, .image(let i)): return .imageOpen(i.reference)
        case (.delete, .volume(let v)): return .volumeDelete(v.name)
        case (.inspect, .volume(let v)): return .volumeOpen(v.name)
        case (.delete, .network(let n)): return n.isBuiltin || n.isDefault ? nil : .networkDelete(n.name)
        case (.inspect, .network(let n)): return .networkOpen(n.name)
        case (.inspect, .stack(let s)): return .stackOpen(name: s.name, file: s.file?.path)
        default: return nil
        }
    }

    /// Cmd+Enter on a verb row opens the thing instead.
    var openAction: PaletteAction? {
        let primary = actions.primary
        switch payload {
        case .screen, .action: return nil
        default: return primary
        }
    }
}

/// Lists the palette reads once when it opens. Containers come from the shared feed.
struct PaletteData {
    var images: [ImageSummary] = []
    var volumes: [VolumeSummary] = []
    var networks: [NetworkSummary] = []
    var machines: [MachineSummary] = []
    /// Only used when the shared feed has not polled yet.
    var containers: [ContainerSummary]?

    static func load(client: ContainerClient, needContainers: Bool) async -> PaletteData {
        async let images = try? client.listImages()
        async let volumes = try? client.listVolumes()
        async let networks = try? client.listNetworks()
        async let machines = try? client.listMachines()
        async let containers: [ContainerSummary]? = needContainers ? (try? client.listContainers(all: true)) : nil
        return PaletteData(images: await images ?? [], volumes: await volumes ?? [], networks: await networks ?? [],
                           machines: await machines ?? [], containers: await containers)
    }
}

/// Builds the resource list and the visible rows. Pure apart from reading AppState.
@MainActor
enum PaletteCatalog {
    static func resources(state: AppState, containers: [ContainerSummary], data: PaletteData) -> [PaletteResource] {
        var list: [PaletteResource] = []

        let visible = containers.filter { !ContainersStore.isHelper($0) }
        for c in visible {
            var words = [c.id, ContainerText.shortImage(c.image), c.image]
            if let ip = c.ipAddress { words.append(ip) }
            if let project = c.labels[ComposeLabel.project] { words.append(project) }
            var subtitle = ContainerText.shortImage(c.image)
            if let port = c.ports.first { subtitle += "  ·  " + ContainerText.portLabel(port) }
            list.append(PaletteResource(
                entry: PaletteEntry(id: "container:\(c.id)", kind: .container, title: c.name.isEmpty ? c.id : c.name,
                                    subtitle: subtitle, keywords: words),
                icon: .containers, status: c.state,
                badge: ContainersStore.isBuilder(c) ? "Builder" : nil, payload: .container(c)))
        }

        for stack in ComposeStack.group(visible) {
            let total = stack.services.count
            list.append(PaletteResource(
                entry: PaletteEntry(id: "stack:\(stack.name)", kind: .stack, title: stack.name,
                                    subtitle: total == 1 ? "1 service" : "\(total) services",
                                    keywords: stack.services.map(\.service)),
                icon: .compose, badge: "\(stack.runningCount) of \(total) running", payload: .stack(stack)))
        }

        for machine in data.machines {
            list.append(PaletteResource(
                entry: PaletteEntry(id: "machine:\(machine.name)", kind: .machine, title: machine.name,
                                    subtitle: machine.image.isEmpty ? "Machine" : ContainerText.shortImage(machine.image),
                                    keywords: [machine.hostname, machine.ipAddress].compactMap { $0 }),
                icon: .machines, status: machine.state, badge: machine.isDefault ? "Default" : nil, payload: .machine(machine)))
        }

        // Commands and screens after live things, so an empty query shows containers first.
        for item in SidebarItem.allCases {
            list.append(PaletteResource(
                entry: PaletteEntry(id: "screen:\(item.rawValue)", kind: .screen, title: "Go to \(item.title)",
                                    subtitle: item.summary, keywords: [item.title]),
                icon: item.deckIcon, payload: .screen(item)))
        }
        for (id, title, subtitle, action, words) in commands(state: state) {
            list.append(PaletteResource(
                entry: PaletteEntry(id: "action:\(id)", kind: .action, title: title, subtitle: subtitle, keywords: words),
                icon: action.icon, payload: .action(action)))
        }

        for image in data.images {
            var subtitle = Format.bytes(image.sizeBytes)
            if !image.usedBy.isEmpty { subtitle += image.usedBy.count == 1 ? "  ·  used by 1 container" : "  ·  used by \(image.usedBy.count) containers" }
            list.append(PaletteResource(
                entry: PaletteEntry(id: "image:\(image.reference)", kind: .image, title: "\(image.shortName):\(image.tag)",
                                    subtitle: subtitle, keywords: [image.reference]),
                icon: .images, payload: .image(image)))
        }

        for volume in data.volumes where !volume.isAnonymous {
            var subtitle = volume.sizeBytes.map { Format.bytes($0) } ?? "Volume"
            if !volume.usedBy.isEmpty { subtitle += "  ·  " + volume.usedBy.joined(separator: ", ") }
            list.append(PaletteResource(
                entry: PaletteEntry(id: "volume:\(volume.name)", kind: .volume, title: volume.name, subtitle: subtitle),
                icon: .volumes, payload: .volume(volume)))
        }

        for network in data.networks {
            list.append(PaletteResource(
                entry: PaletteEntry(id: "network:\(network.name)", kind: .network, title: network.name,
                                    subtitle: network.subnet ?? (network.isInternal ? "Host only" : "Network"),
                                    keywords: [network.subnet].compactMap { $0 }),
                icon: .networks, badge: network.isBuiltin || network.isDefault ? "Built in" : nil, payload: .network(network)))
        }
        return list
    }

    /// App commands: id, title, subtitle, action, search words.
    private static func commands(state: AppState) -> [(String, String, String, PaletteAction, [String])] {
        var list: [(String, String, String, PaletteAction, [String])] = []
        let hasCLI = state.report.cliPath != nil
        if hasCLI {
            list.append(("run", "Run a container", "Start a new container from an image.",
                         .custom(title: "Run", icon: .play) { $0.runRequest = RunRequest(options: RunOptions(image: "")) }, ["new"]))
            list.append(("pull", "Pull an image", "Download an image from a registry.", .imagePull(""), ["download"]))
            list.append(("build", "Build an image", "Build from a Dockerfile.",
                         .custom(title: "Build", icon: .build) { $0.buildRequest = BuildRequest() }, ["dockerfile"]))
            list.append(("logswindow", "Open the Logs window", "Logs from several containers side by side.",
                         .custom(title: "Open", icon: .logs) { LogsWindow.open(state: $0) }, ["logs", "tail", "panes"]))
            list.append(("prune", "Remove stopped containers", "Delete every stopped container.", .pruneContainers, ["prune", "clean"]))
        }
        list.append(("diagnostics", "Diagnostics", "Versions, backend, recent errors. Copy for bug reports.",
                     .custom(title: "Open", icon: .info) { DiagnosticsWindow.show(state: $0) }, ["debug", "support", "bug"]))
        list.append(("checks", "Run setup checks", "Check the tool, service and kernel again.",
                     .custom(title: "Check", icon: .checklist) { state in Task { await state.refresh() } }, ["doctor"]))
        list.append(("setup", "Open setup guide", "Install, start and fix the platform.",
                     .custom(title: "Open", icon: .wand) { $0.showSetup = true }, ["install"]))
        if hasCLI {
            if state.report.serviceRunning {
                list.append(("service-stop", "Stop container service", "Running containers stop too.", .stopService, ["system"]))
            } else {
                list.append(("service-start", "Start container service", "Needed to run containers.",
                             .custom(title: "Start", icon: .play) { state in Task { await state.fix(.startService) } }, ["system"]))
            }
        }
        return list
    }

    /// Rows for a query, grouped in sections.
    static func sections(for text: String, resources: [PaletteResource], recents: [String]) -> [(title: String, rows: [PaletteRow])] {
        let query = PaletteQuery.parse(text)
        let byID = Dictionary(resources.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hasQuery = !query.target.isEmpty
        let cap = hasQuery ? 12 : 6
        var result: [(title: String, rows: [PaletteRow])] = []

        if let verb = query.verb {
            // Free text first for pull and run: "pull nginx:alpine" works for images not on this Mac.
            var freeRows: [PaletteRow] = []
            if verb.acceptsFreeText, hasQuery, !resources.contains(where: { $0.entry.kind == .image && ($0.entry.title == query.target || $0.entry.keywords.contains(query.target)) }) {
                let ref = query.target
                let action: PaletteAction = verb == .pull ? .imagePull(ref) : .imageRun(ref)
                freeRows.append(PaletteRow(id: "free:\(verb.rawValue):\(ref)", entryID: "", kind: .image,
                                           verbPrefix: verb.title, title: ref,
                                           subtitle: verb == .pull ? "Download from the registry." : "Open the Run sheet with this image.",
                                           icon: verb == .pull ? .pull : .play, primary: action,
                                           alternate: verb == .pull ? .imageRun(ref) : .imagePull(ref)))
            }
            let candidates = resources.filter { verb.targetKinds.contains($0.entry.kind) && $0.action(for: verb) != nil }
            let ranked = PaletteRanker.rank(candidates.map(\.entry), query: query.target, recents: recents)
            var sections = PaletteRanker.sections(ranked, hasQuery: hasQuery)
            if !freeRows.isEmpty {
                result.append(("Top hit", freeRows))
                // The best resource joins its kind section instead.
                if let top = sections.first, top.title == "Top hit" {
                    sections.removeFirst()
                    if let index = sections.firstIndex(where: { $0.title == top.items[0].entry.kind.sectionTitle }) {
                        sections[index].items.insert(top.items[0], at: 0)
                    } else {
                        sections.insert(PaletteSection(title: top.items[0].entry.kind.sectionTitle, items: top.items), at: 0)
                    }
                }
            }
            for section in sections {
                let rows = section.items.prefix(cap).compactMap { item -> PaletteRow? in
                    guard let res = byID[item.id], let action = res.action(for: verb) else { return nil }
                    return row(res, item: item, primary: action, alternate: res.openAction, verb: verb)
                }
                if !rows.isEmpty { result.append((section.title, rows)) }
            }
            // The whole text still finds screens and commands ("stop service", "open setup guide").
            let commands = resources.filter { $0.entry.kind == .screen || $0.entry.kind == .action }
            let extra = PaletteRanker.rank(commands.map(\.entry), query: query.raw, recents: recents, limit: 4)
            let extraRows = extra.compactMap { item -> PaletteRow? in
                guard let res = byID[item.id] else { return nil }
                let pair = res.actions
                return row(res, item: item, primary: pair.primary, alternate: pair.alternate, verb: nil)
            }
            if !extraRows.isEmpty { result.append(("Commands", extraRows)) }
            return result
        }

        let ranked = PaletteRanker.rank(resources.map(\.entry), query: query.target, recents: recents)
        for section in PaletteRanker.sections(ranked, hasQuery: hasQuery) {
            // Without a query, keep the list short. Screens and actions are always all shown.
            let limit = (!hasQuery && (section.title == PaletteKind.screen.sectionTitle || section.title == PaletteKind.action.sectionTitle)) ? 20 : cap
            let rows = section.items.prefix(limit).compactMap { item -> PaletteRow? in
                guard let res = byID[item.id] else { return nil }
                let pair = res.actions
                return row(res, item: item, primary: pair.primary, alternate: pair.alternate, verb: nil)
            }
            if !rows.isEmpty { result.append((section.title, rows)) }
        }
        return result
    }

    private static func row(_ res: PaletteResource, item: RankedEntry, primary: PaletteAction, alternate: PaletteAction?, verb: PaletteVerb?) -> PaletteRow {
        PaletteRow(id: (verb.map { $0.rawValue + "|" } ?? "") + res.entry.id, entryID: res.entry.id, kind: res.entry.kind,
                   verbPrefix: verb?.title ?? "", title: res.entry.title, subtitle: res.entry.subtitle,
                   icon: verb == nil ? res.icon : primary.icon, status: res.status, badge: res.badge,
                   highlights: item.highlights, primary: primary, alternate: alternate)
    }
}
