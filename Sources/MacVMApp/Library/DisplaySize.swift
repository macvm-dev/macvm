import Foundation

/// 界面上显示的容量，如「8 GB」「30.9 GB」：按 1024 进位，与 CLI 的数值相同，最多一位小数。
enum DisplaySize {
    static func format(_ bytes: UInt64) -> String {
        let units: [(String, UInt64)] = [("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)]
        for (unit, factor) in units where bytes >= factor {
            let value = Double(bytes) / Double(factor)
            return "\(value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))) \(unit)"
        }
        return "\(bytes) B"
    }
}
