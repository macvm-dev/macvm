public import Foundation

/// `<name>.macvm` 目录的布局。只描述路径与读写配置，不涉及运行时。
public struct VMBundle: Sendable, Equatable {
    public static let pathExtension = "macvm"

    public let url: URL

    public init(url: URL) { self.url = url }

    public var name: String { url.deletingPathExtension().lastPathComponent }

    public var configURL: URL { url.appending(path: "config.json") }
    public var diskURL: URL { url.appending(path: "disk.img") }
    public var auxiliaryStorageURL: URL { url.appending(path: "aux.img") }
    public var hardwareModelURL: URL { url.appending(path: "hw.model") }
    public var machineIdentifierURL: URL { url.appending(path: "machine.id") }
    public var efiVariableStoreURL: URL { url.appending(path: "efi.vars") }
    public var savedStateURL: URL { url.appending(path: "state.vzvmsave") }
    /// 存在即表示 `savedStateURL` 的挂起状态里有 macOS 客户机的自动挂载共享目录设备。每次挂起都重写，
    /// 只在有挂起状态时才有意义。
    public var savedStateShareDeviceURL: URL { url.appending(path: "state.shares") }
    public var snapshotsURL: URL { url.appending(path: "snapshots", directoryHint: .isDirectory) }
    public var lockURL: URL { url.appending(path: "run.lock") }
    public var logURL: URL { url.appending(path: "run.log") }
    /// 存发起方给的创建令牌。引擎建好包后不删它，由发起方在整个创建流程结束时删掉；
    /// 包里留着这个文件、内容又与发起方记下的令牌相同，就是它中断时留下的半成品。
    public var creationMarkerURL: URL { url.appending(path: "creating") }

    /// `creationMarkerURL` 里的令牌；没有标记时为 nil。
    public var creationToken: String? { try? String(contentsOf: creationMarkerURL, encoding: .utf8) }

    /// 控制 socket 放在短路径的运行时目录：`sun_path` 只有 104 字节，放进包内会被长路径撑爆。
    public var controlSocketURL: URL { RuntimeDirectory.url.appending(path: "\(name).sock") }

    public var hasSavedState: Bool { FileManager.default.fileExists(atPath: savedStateURL.path) }

    public var savedStateHasShareDevice: Bool { FileManager.default.fileExists(atPath: savedStateShareDeviceURL.path) }

    public func loadConfig() throws -> VMConfig {
        let data: Data
        do { data = try Data(contentsOf: configURL) } catch {
            throw MacVMError.io("读取 \(configURL.path) 失败：\(error.localizedDescription)")
        }
        do { return try VMConfig.decode(data) } catch let e as MacVMError { throw e } catch {
            throw MacVMError.invalidConfig("解析 \(configURL.path) 失败：\(error)")
        }
    }

    public func saveConfig(_ config: VMConfig) throws {
        do { try config.encoded().write(to: configURL, options: .atomic) } catch {
            throw MacVMError.io("写入 \(configURL.path) 失败：\(error.localizedDescription)")
        }
    }

    /// 解析磁盘、介质等配置里的路径：相对路径以包目录为基准。
    public func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(filePath: expanded) : url.appending(path: expanded)
    }
}

public enum RuntimeDirectory {
    /// 每个用户独占、权限 0700 的目录，存放控制 socket。
    public static var url: URL { URL(filePath: "/tmp/macvm-\(getuid())", directoryHint: .isDirectory) }

    public static func ensure() throws {
        let path = url.path
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw MacVMError.posix("创建 \(path)")
        }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw MacVMError.io("\(path) 不是当前用户拥有的目录")
        }
        chmod(path, 0o700)
    }
}
