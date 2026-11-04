public import Foundation
public import MacVMModel

/// 包内 `snapshots/<名>/` 下的 clonefile 副本：磁盘、固件变量、配置，挂起中的虚拟机还带内存状态。
public struct Snapshot: Codable, Sendable, Equatable {
    public let name: String
    public let createdAt: Date
    /// 快照时虚拟机处于挂起状态，还原后 `start` 会接着运行。
    public let includesMemory: Bool
    /// 快照文件已分配的字节数之和，含与当前磁盘共享的块，因此是实际额外占用的上限。
    public var allocatedSize: UInt64?

    private static let metadataFile = "snapshot.json"

    public static func list(_ bundle: VMBundle) throws -> [Snapshot] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: bundle.snapshotsURL, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appending(path: metadataFile)),
                  var snap = try? decoder.decode(Snapshot.self, from: data) else { return nil }
            snap.allocatedSize = allocatedSize(of: dir)
            return snap
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public static func save(_ bundle: VMBundle, name: String) throws -> Snapshot {
        try VMLibrary.validate(name: name)
        if BundleLock.holder(of: bundle) != nil {
            throw MacVMError.alreadyRunning("\(bundle.name)（先 stop 或 suspend 再做快照）")
        }
        let config = try bundle.loadConfig()
        let dir = directory(bundle, name)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw MacVMError.alreadyExists("快照 \(name)") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            var files = BundleFiles.stateFiles(of: bundle, config: config) + [bundle.configURL.lastPathComponent]
            if bundle.hasSavedState {
                files.append(bundle.savedStateURL.lastPathComponent)
                if bundle.savedStateHasShareDevice { files.append(bundle.savedStateShareDeviceURL.lastPathComponent) }
            }
            for file in files {
                try Clone.file(from: bundle.url.appending(path: file), to: dir.appending(path: file))
            }
            let snap = Snapshot(name: name, createdAt: Date(), includesMemory: bundle.hasSavedState, allocatedSize: nil)
            try encoder.encode(snap).write(to: dir.appending(path: metadataFile))
            return snap
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// 用快照覆盖当前状态；当前未快照的改动会丢失。
    public static func restore(_ bundle: VMBundle, name: String) throws {
        if BundleLock.holder(of: bundle) != nil { throw MacVMError.alreadyRunning(bundle.name) }
        let dir = directory(bundle, name)
        guard FileManager.default.fileExists(atPath: dir.appending(path: metadataFile).path) else {
            throw MacVMError.snapshotNotFound("\(bundle.name) 的快照 \(name)")
        }
        try? FileManager.default.removeItem(at: bundle.savedStateURL)
        try? FileManager.default.removeItem(at: bundle.savedStateShareDeviceURL)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != metadataFile }
        for file in files {
            let target = bundle.url.appending(path: file)
            try? FileManager.default.removeItem(at: target)
            try Clone.file(from: dir.appending(path: file), to: target)
        }
    }

    public static func delete(_ bundle: VMBundle, name: String) throws {
        let dir = directory(bundle, name)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw MacVMError.snapshotNotFound("\(bundle.name) 的快照 \(name)") }
        try FileManager.default.removeItem(at: dir)
    }

    private static func directory(_ bundle: VMBundle, _ name: String) -> URL {
        bundle.snapshotsURL.appending(path: name, directoryHint: .isDirectory)
    }

    private static func allocatedSize(of dir: URL) -> UInt64? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.reduce(0) { sum, name in sum + ((try? DiskImage.allocatedSize(at: dir.appending(path: name)).physical) ?? 0) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
