import SwiftUI
import DeckCore

/// Data behind the Dashboard: tile counts and disk use. Containers come from the shared
/// feed and the live CPU and memory history from the shared stats sampler, so this model
/// runs no loop. Tile counts are derived from container labels (`DashboardCounts`).
@MainActor
@Observable
final class DashboardModel {
    /// Listed images, for the system image note in the Disk usage card.
    var imageCount: Int?
    var usage: DiskUsage?
    /// Machines, for the Machines tile. nil until the first list came back.
    var machines: [MachineSummary]?
    /// Cluster nodes, read on their own from container 1.7 on, where the shared container
    /// list (like `container list`) no longer has them. nil on older releases.
    var clusterNodes: [ContainerSummary]?
    var hasLoaded = false

    @ObservationIgnored private var sequencer = PollSequencer()
    @ObservationIgnored private var cachedCounts: (version: Int, counts: DashboardCounts)?

    var containers: [ContainerSummary] { BackgroundServices.shared.visibleContainers }
    var running: [ContainerSummary] { containers.filter(\.isRunning) }
    var containersLoaded: Bool { BackgroundServices.shared.hasLoaded }

    /// Tile counts, worked out again only when the container list changed.
    var counts: DashboardCounts {
        let version = BackgroundServices.shared.containersVersion &+ clusterNodesVersion
        if let cachedCounts, cachedCounts.version == version { return cachedCounts.counts }
        var counts = DashboardCounts.make(containers)
        if let clusterNodes {
            let kube = DashboardCounts.make(clusterNodes)
            counts.clusters = kube.clusters
            counts.clustersRunning = kube.clustersRunning
            counts.nodes = kube.nodes
        }
        cachedCounts = (version, counts)
        return counts
    }

    @ObservationIgnored private var clusterNodesVersion = 0

    /// Totals across running containers, from the shared sampler.
    var samples: [ContainerStatsSample] { StatsSampler.shared.totals }

    func load(client: ContainerClient?) async {
        guard let client else {
            imageCount = nil
            machines = nil
            usage = nil
            hasLoaded = true
            return
        }
        let token = sequencer.begin()
        async let imagesResult = try? client.listImages()
        async let usageResult = try? client.diskUsage()
        async let machinesResult = try? client.listMachines()
        async let nodesResult: [ContainerSummary]? = {
            guard await client.platformFeatures().listHidesClusterNodes else { return nil }
            return try? await client.listClusterNodes()
        }()

        let images = await imagesResult
        let disk = await usageResult
        let machineList = await machinesResult
        let nodes = await nodesResult
        // A slower, older load must not overwrite a newer one.
        guard sequencer.accept(token) else { return }

        if let count = images?.count, count != imageCount { imageCount = count }
        if let disk, disk != usage { usage = disk }
        if let machineList, machineList != machines { machines = machineList }
        if nodes != clusterNodes {
            clusterNodes = nodes
            clusterNodesVersion &+= 1
        }
        hasLoaded = true
    }

    func reading(for container: ContainerSummary) -> StatsReading? {
        StatsSampler.shared.reading(for: container)
    }

    /// "4 minutes" or "40 seconds", from the real sample times.
    static func windowText(_ samples: [ContainerStatsSample]) -> String? {
        guard let first = samples.first?.date, let last = samples.last?.date, samples.count >= 2 else { return nil }
        let seconds = Int(last.timeIntervalSince(first).rounded())
        if seconds >= 120 { return "\(seconds / 60) minutes" }
        if seconds >= 60 { return "1 minute" }
        return "\(max(seconds, 1)) seconds"
    }
}

/// Byte text for the Dashboard. `ByteCountFormatter` prints "Zero KB" for 0,
/// so zero is shown as "0 KB" here.
enum DashboardFormat {
    static func bytes(_ value: UInt64) -> String {
        value == 0 ? "0 KB" : Format.bytes(value)
    }

    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value >= 1 else { return "0 KB" }
        return bytes(UInt64(min(value, 1e18)))
    }

    /// Columns for the tile row. Always a divisor of the tile count so rows stay full.
    static func tileColumns(width: CGFloat, tiles: Int, minimumTile: CGFloat = 150, spacing: CGFloat = 12) -> Int {
        guard tiles > 0 else { return 1 }
        let options = (1...tiles).reversed().filter { tiles % $0 == 0 }
        for count in options {
            let needed = CGFloat(count) * minimumTile + CGFloat(count - 1) * spacing
            if width >= needed { return count }
        }
        return 1
    }
}
