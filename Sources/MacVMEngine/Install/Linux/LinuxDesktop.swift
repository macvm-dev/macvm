public import Foundation
import MacVMModel

/// 可下载的 Linux 桌面版安装 ISO，装好后是带图形界面的完整系统。
/// 下载地址与 SHA-256 在下载时向发行方查询，点版本更新后不用改代码。
public enum LinuxDesktop: String, CaseIterable, Sendable {
    case ubuntu = "ubuntu-desktop"
    case fedora = "fedora-workstation"

    /// 跟随的 Ubuntu LTS 系列。
    static let ubuntuSeries = "26.04"

    public var title: String {
        switch self {
        case .ubuntu: "Ubuntu \(Self.ubuntuSeries) LTS 桌面版"
        case .fedora: "Fedora Workstation"
        }
    }

    /// 能由 `UbuntuAutoinstall` 无人值守安装；不能的只能在虚拟机窗口里走一遍安装程序。
    public var supportsUnattended: Bool { self == .ubuntu }

    public static func named(_ id: String) throws -> LinuxDesktop {
        guard let desktop = LinuxDesktop(rawValue: id) else {
            throw MacVMError.invalidConfig("未知桌面版 \(id)，可选：\(allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return desktop
    }

    struct Release: Equatable {
        let fileName: String
        let url: URL
        let sha256: String
    }

    func latestRelease() async throws -> Release {
        switch self {
        case .ubuntu:
            let base = "https://cdimage.ubuntu.com/releases/\(Self.ubuntuSeries)/release/"
            let sums = try await Self.fetch(base + "SHA256SUMS")
            guard let release = Self.ubuntuRelease(sha256sums: sums, series: Self.ubuntuSeries, base: URL(string: base)!) else {
                throw MacVMError.io("Ubuntu \(Self.ubuntuSeries) 的发布列表里没有 arm64 桌面版 ISO")
            }
            return release
        case .fedora:
            let json = try await Self.fetch("https://fedoraproject.org/releases.json")
            guard let release = Self.fedoraRelease(releasesJSON: Data(json.utf8)) else {
                throw MacVMError.io("Fedora 的发布列表里没有 aarch64 Workstation ISO")
            }
            return release
        }
    }

    /// 是否是本桌面版某个版本的安装 ISO 文件名。
    func isISOFileName(_ name: String) -> Bool {
        switch self {
        case .ubuntu: Self.isUbuntuDesktopISO(name, series: Self.ubuntuSeries)
        case .fedora: name.hasPrefix("Fedora-Workstation-") && name.hasSuffix(".aarch64.iso")
        }
    }

    /// `ubuntu-<系列>[.<点版本>]-desktop-arm64.iso`。
    static func isUbuntuDesktopISO(_ name: String, series: String) -> Bool {
        let prefix = "ubuntu-\(series)", suffix = "-desktop-arm64.iso"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count >= prefix.count + suffix.count else { return false }
        let point = name.dropFirst(prefix.count).dropLast(suffix.count)
        return point.isEmpty || (point.first == "." && point.dropFirst().allSatisfy { $0.isNumber || $0 == "." })
    }

    /// 从 `SHA256SUMS`（每行 `<hash> *<文件名>`）里挑该系列最新点版本的 arm64 桌面版。
    static func ubuntuRelease(sha256sums: String, series: String, base: URL) -> Release? {
        let candidates = sha256sums.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
            return isUbuntuDesktopISO(name, series: series) ? (name, String(parts[0])) : nil
        }
        guard let (name, hash) = candidates.max(by: { $0.0.localizedStandardCompare($1.0) == .orderedAscending }) else { return nil }
        return Release(fileName: name, url: base.appending(path: name), sha256: hash.lowercased())
    }

    /// 从 `releases.json` 里挑正式版（版本号是纯数字，排除 Beta）中最新的 aarch64 Workstation ISO。
    static func fedoraRelease(releasesJSON: Data) -> Release? {
        struct Entry: Decodable {
            let version: String, arch: String, variant: String, link: String
            let sha256: String?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: releasesJSON) else { return nil }
        let best = entries
            .filter { $0.arch == "aarch64" && $0.variant == "Workstation" && $0.link.hasSuffix(".iso") && $0.sha256 != nil }
            .compactMap { entry in Int(entry.version).map { ($0, entry) } }
            .max { $0.0 < $1.0 }?.1
        guard let best, let url = URL(string: best.link), let sha256 = best.sha256 else { return nil }
        return Release(fileName: url.lastPathComponent, url: url, sha256: sha256.lowercased())
    }

    private static func fetch(_ url: String) async throws -> String {
        try await Subprocess.run("/usr/bin/curl", ["-fsSL", "--retry", "3", url])
    }
}

/// 下载并校验过的安装 ISO，位于 `DownloadCache.root` 下的 iso。
public enum ISOCache {
    public static var root: URL {
        DownloadCache.root.appending(path: "iso", directoryHint: .isDirectory)
    }

    /// 返回最新版的安装 ISO，不在缓存里时先下载；校验和不符时删掉下载的文件并报错。
    /// 查不到最新版（如离线）时退而用缓存里最新的一份，缓存里也没有才报错。
    public static func iso(for desktop: LinuxDesktop, showProgress: Bool) async throws -> URL {
        // 只取一次：下载期间设置里的目录可能被改，中间文件得留在同一处。
        let root = root
        let release: LinuxDesktop.Release
        do { release = try await desktop.latestRelease() } catch {
            guard !(error is CancellationError), let cached = cachedISOs(of: desktop, in: root).last else { throw error }
            return cached
        }
        let iso = root.appending(path: release.fileName)
        let partial = root.appending(path: release.fileName + ".part")
        return try await Download.cached(iso, from: release.url, via: partial, showProgress: showProgress) { partial in
            try await Download.verifySHA256(of: partial, expected: release.sha256, name: release.fileName)
            try FileManager.default.moveItem(at: partial, to: iso)
            removeStalePartials(of: desktop, keeping: release.fileName, in: root)
        }
    }

    /// 缓存里本桌面版下完的 ISO，按版本从旧到新。
    static func cachedISOs(of desktop: LinuxDesktop, in root: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { desktop.isISOFileName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 删掉本桌面版其他版本名字以 `<ISO>.part` 开头的文件，锁文件除外：它可能正被别的进程持有。
    /// 下完的旧 ISO 不删：已建的虚拟机可能还挂着它当安装介质，删了就开不了机。
    static func removeStalePartials(of desktop: LinuxDesktop, keeping current: String, in root: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let name = item.lastPathComponent
            guard let marker = name.range(of: ".iso.part"), !name.hasSuffix(".lock") else { continue }
            let iso = String(name[..<marker.lowerBound]) + ".iso"
            if iso != current, desktop.isISOFileName(iso) { try? FileManager.default.removeItem(at: item) }
        }
    }
}
