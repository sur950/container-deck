import SwiftUI
import DeckCore

/// Data behind the Dashboard: counts and disk use. Containers come from the shared feed
/// and the live CPU and memory history from the shared stats sampler, so this model runs
/// no loop. Counts are cheap: `volume list` and `network list` without any inspect.
@MainActor
@Observable
final class DashboardModel {
    var imageCount: Int?
    var volumeCount: Int?
    var networkCount: Int?
    var machineCount: Int?
    var usage: DiskUsage?
    var hasLoaded = false

    @ObservationIgnored private var sequencer = PollSequencer()

    var containers: [ContainerSummary] { BackgroundServices.shared.visibleContainers }
    var running: [ContainerSummary] { containers.filter(\.isRunning) }
    var containersLoaded: Bool { BackgroundServices.shared.hasLoaded }

    /// Totals across running containers, from the shared sampler.
    var samples: [ContainerStatsSample] { StatsSampler.shared.totals }

    func load(client: ContainerClient?) async {
        guard let client else {
            imageCount = nil
            volumeCount = nil
            networkCount = nil
            machineCount = nil
            usage = nil
            hasLoaded = true
            return
        }
        let token = sequencer.begin()
        async let imagesResult = try? client.listImages()
        async let volumesResult = try? client.countVolumes()
        async let networksResult = try? client.countNetworks()
        async let usageResult = try? client.diskUsage()
        async let machinesResult = try? client.listMachines()

        let images = await imagesResult
        let volumes = await volumesResult
        let networks = await networksResult
        let disk = await usageResult
        let machines = await machinesResult
        // A slower, older load must not overwrite a newer one.
        guard sequencer.accept(token) else { return }

        set(\.imageCount, images?.count ?? imageCount)
        set(\.volumeCount, volumes ?? volumeCount)
        set(\.networkCount, networks ?? networkCount)
        set(\.machineCount, machines?.count ?? machineCount)
        if let disk, disk != usage { usage = disk }
        hasLoaded = true
    }

    /// Assigns only real changes, so tiles do not redraw for nothing.
    private func set(_ keyPath: ReferenceWritableKeyPath<DashboardModel, Int?>, _ value: Int?) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
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
