import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct SystemInfo: Sendable, Equatable {
    public var isAppleSilicon: Bool
    public var osMajor: Int
    public var osMinor: Int

    public init(isAppleSilicon: Bool, osMajor: Int, osMinor: Int) {
        self.isAppleSilicon = isAppleSilicon
        self.osMajor = osMajor
        self.osMinor = osMinor
    }

    public static func current() -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemInfo(
            isAppleSilicon: detectAppleSilicon(),
            osMajor: version.majorVersion,
            osMinor: version.minorVersion
        )
    }

    /// True on Apple silicon, even when this process runs under Rosetta.
    static func detectAppleSilicon() -> Bool {
        #if os(macOS)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }
        return false
        #else
        return false
        #endif
    }
}
