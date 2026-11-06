import Foundation

/// What Free Up Space can remove, with the space each part frees.
public enum FreeSpaceItem: String, CaseIterable, Sendable, Identifiable, Hashable {
    case containers, images, volumes, networks

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .containers: return "Stopped containers"
        case .images: return "Unused images"
        case .volumes: return "Unused volumes"
        case .networks: return "Unused networks"
        }
    }

    public var note: String {
        switch self {
        case .containers: return "Running containers and Apple's builder are kept."
        case .images: return "Images used by any container are kept."
        case .volumes: return "Data in these volumes is lost."
        case .networks: return "Networks used by any container are kept."
        }
    }

    /// Volumes hold data, so they are never picked for you.
    public var isRisky: Bool { self == .volumes }

    /// Bytes this item frees, when known. Networks take no real space.
    public func reclaimable(_ usage: DiskUsage?) -> UInt64? {
        guard let usage else { return nil }
        switch self {
        case .containers: return usage.containers.reclaimableBytes
        case .images: return usage.images.reclaimableBytes
        case .volumes: return usage.volumes.reclaimableBytes
        case .networks: return nil
        }
    }

    /// How many items it would remove, when known.
    public func unusedCount(_ usage: DiskUsage?) -> Int? {
        guard let usage else { return nil }
        switch self {
        case .containers: return max(0, usage.containers.total - usage.containers.active)
        case .images: return max(0, usage.images.total - usage.images.active)
        case .volumes: return max(0, usage.volumes.total - usage.volumes.active)
        case .networks: return nil
        }
    }
}

public enum FreeSpacePlan {
    /// Picked at first: everything safe that frees something.
    public static func defaultSelection(_ usage: DiskUsage?) -> Set<FreeSpaceItem> {
        var picked: Set<FreeSpaceItem> = []
        for item in FreeSpaceItem.allCases where !item.isRisky && item != .networks {
            if (item.reclaimable(usage) ?? 0) > 0 || (item.unusedCount(usage) ?? 0) > 0 { picked.insert(item) }
        }
        return picked
    }

    /// Bytes the picked items free together.
    public static func estimate(_ usage: DiskUsage?, picked: Set<FreeSpaceItem>) -> UInt64 {
        picked.reduce(UInt64(0)) { $0 + ($1.reclaimable(usage) ?? 0) }
    }

    /// Order to run them: containers first, so their images and volumes become unused too.
    public static func order(_ picked: Set<FreeSpaceItem>) -> [FreeSpaceItem] {
        FreeSpaceItem.allCases.filter { picked.contains($0) }
    }

    /// Bytes freed between two readings. Never negative.
    public static func freed(before: DiskUsage?, after: DiskUsage?) -> UInt64 {
        guard let before, let after, before.totalBytes > after.totalBytes else { return 0 }
        return before.totalBytes - after.totalBytes
    }
}
