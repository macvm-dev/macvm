import Foundation
import MacVMModel

/// 按 ISO 9660 主卷描述符的目录树找文件在镜像里的位置，用来原地改写文件内容。
/// Joliet 与 Rock Ridge 的目录项指向同一段数据，改这一段三种名字读到的都是新内容。
enum ISO9660 {
    static let sectorSize = 2048

    struct Extent: Equatable {
        /// 字节偏移。
        let offset: UInt64
        let length: Int
    }

    /// `path` 是以 `/` 分隔的路径，按主卷描述符里的大写名字比较，忽略 `;1` 版本号。
    static func extent(of path: String, in image: URL) throws -> Extent {
        let handle = try FileHandle(forReadingFrom: image)
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw MacVMError.io("\(image.lastPathComponent) 不是完整的 ISO 9660 镜像") }
            return [UInt8](data)
        }

        let pvd = try read(16 * UInt64(sectorSize), sectorSize)
        guard pvd[0] == 1, Array(pvd[1...5]) == Array("CD001".utf8) else {
            throw MacVMError.io("\(image.lastPathComponent) 不是 ISO 9660 镜像")
        }
        var current = record(in: pvd, at: 156)
        for component in path.split(separator: "/") {
            guard let dir = current, dir.isDirectory else { throw MacVMError.io("\(image.lastPathComponent) 里没有 \(path)") }
            let bytes = try read(dir.extent.offset, dir.extent.length)
            current = children(of: bytes).first { $0.name == component.uppercased() }
        }
        guard let file = current, !file.isDirectory else { throw MacVMError.io("\(image.lastPathComponent) 里没有 \(path)") }
        return file.extent
    }

    struct Record {
        let name: String
        let extent: Extent
        let isDirectory: Bool
    }

    /// 目录项不跨扇区，扇区末尾不够放下一项时以 0 填充。
    static func children(of directory: [UInt8]) -> [Record] {
        var records: [Record] = []
        var i = 0
        while i < directory.count {
            guard directory[i] > 0 else {
                i = (i / sectorSize + 1) * sectorSize
                continue
            }
            // 名字为 0 与 1 的两项是目录自身与上级目录。
            if let r = record(in: directory, at: i), r.name != "\u{0}", r.name != "\u{1}" { records.append(r) }
            i += Int(directory[i])
        }
        return records
    }

    static func record(in bytes: [UInt8], at i: Int) -> Record? {
        let length = Int(bytes[i])
        guard length >= 34, i + length <= bytes.count else { return nil }
        let nameLength = Int(bytes[i + 32])
        guard 33 + nameLength <= length else { return nil }
        let raw = bytes[(i + 33)..<(i + 33 + nameLength)]
        var name = String(decoding: raw, as: UTF8.self)
        if let version = name.firstIndex(of: ";") { name = String(name[..<version]) }
        if name.hasSuffix(".") { name.removeLast() }
        let lba = UInt64(littleEndian32(bytes, i + 2)), size = Int(littleEndian32(bytes, i + 10))
        return Record(name: name, extent: Extent(offset: lba * UInt64(sectorSize), length: size), isDirectory: bytes[i + 25] & 0x02 != 0)
    }

    private static func littleEndian32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
