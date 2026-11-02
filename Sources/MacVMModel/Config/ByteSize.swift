public import Foundation

/// 解析与格式化 `512M`、`8G`、`1T` 这类二进制单位的容量。
public enum ByteSize {
    public static func parse(_ text: String) throws -> UInt64 {
        let s = text.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, UInt64)] = [("TIB", 1 << 40), ("GIB", 1 << 30), ("MIB", 1 << 20), ("KIB", 1 << 10),
                                         ("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10),
                                         ("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10), ("B", 1)]
        for (suffix, factor) in units where s.hasSuffix(suffix) {
            let number = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if let v = Double(number), v > 0 { return UInt64(v * Double(factor)) }
            break
        }
        if let v = UInt64(s), v > 0 { return v }
        throw MacVMError.invalidConfig("无法解析容量：\(text)（示例：512M、8G、1T）")
    }

    public static func format(_ bytes: UInt64) -> String {
        let units: [(String, UInt64)] = [("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10)]
        for (suffix, factor) in units where bytes >= factor {
            let v = Double(bytes) / Double(factor)
            return v == v.rounded() ? "\(Int(v))\(suffix)" : String(format: "%.1f%@", v, suffix)
        }
        return "\(bytes)B"
    }
}
