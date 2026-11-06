import Foundation

/// Short counts for tiles and stat chips: 999, 1.2K, 15K, 1M, 2.5M.
/// At most one decimal, only below 10 of a unit, and never a trailing ".0".
/// Integer math only, so 2,450,000 rounds to 2.5M and not 2.4M.
public enum CountFormat {
    private static let units: [(base: Int, suffix: String)] = [
        (1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B"), (1_000_000_000_000, "T")
    ]

    public static func compact(_ value: Int) -> String {
        if value < 0 { return "-" + compact(value == .min ? .max : -value) }
        if value < 1_000 { return "\(value)" }
        for (index, unit) in units.enumerated() {
            let tenth = unit.base / 10
            let tenths = value / tenth + (value % tenth >= tenth / 2 ? 1 : 0)
            if tenths < 100 {
                return tenths % 10 == 0 ? "\(tenths / 10)\(unit.suffix)" : "\(tenths / 10).\(tenths % 10)\(unit.suffix)"
            }
            let whole = value / unit.base + (value % unit.base >= unit.base / 2 ? 1 : 0)
            // 999,950 rounds to 1000K, which reads better as 1M.
            if whole < 1_000 || index == units.count - 1 { return "\(whole)\(unit.suffix)" }
        }
        return "\(value)"
    }
}
