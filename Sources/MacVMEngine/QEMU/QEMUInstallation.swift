public import Foundation
public import MacVMModel

/// 运行 QEMU 引擎用的 QEMU：App 自带的（带 SPICE 与 GL 图形加速），或用户经 Homebrew 安装的。
public struct QEMUInstallation: Sendable {
    public let binary: URL
    public let firmwareCode: URL
    /// 新建虚拟机时复制一份作为该机的 EFI 变量存储。
    public let firmwareVarsTemplate: URL
    /// 传给 `-L` 的数据目录（键盘布局等）；Homebrew 版用它自己的默认位置。
    public var dataDirectory: URL?
    /// App 显示 SPICE 画面用的库（`SpiceDisplay.Library` 加载的 C 接口）；有它才用 SPICE + GL 显示，否则用 VNC。
    public var displayLibrary: URL?
    /// 编进了 Direct3D 转译（DXMT），virtio-gpu 可开 Windows 的 3D 上下文。
    public var direct3D = false
    /// 自带布局的根目录；有它才是带图形加速补丁的 QEMU。
    public var bundleRoot: URL?

    /// 显卡走 virglrenderer：QEMU 给 virgl 设了迁移阻断，这样的虚拟机不能挂起。
    public var usesVirgl: Bool { displayLibrary != nil }

    /// 用这个 QEMU 运行的 `config` 能否挂起。
    func canSuspend(_ config: VMConfig) -> Bool { config.supportsSuspend && !usesVirgl }

    /// 本机找到的 QEMU 能否挂起 `config` 描述的虚拟机；没装 QEMU 时为 false。
    public static func canSuspend(_ config: VMConfig) -> Bool {
        located?.canSuspend(config) == true
    }

    /// `locate` 的结果，供界面频繁查询；装卸 QEMU 后要重启 App 才更新。
    private static let located = locate()

    static let virglSuspendError = MacVMError.unsupported("App 自带 QEMU 的 3D 显卡（virgl）不支持挂起，请关机")

    /// 自带的 QEMU 把客户机经气球上报的空闲页还给宿主；Homebrew 的 QEMU 只调 madvise，macOS 上释放不了客户机写过的页。
    var returnsFreedGuestMemory: Bool { bundleRoot != nil }

    /// 启动 QEMU 时附加的环境变量：virglrenderer 按编译时的绝对路径找 render server，要改指向自带的那份；
    /// ANGLE 用 Metal 后端；Windows 的 Direct3D 经 DXMT 转成 Metal。
    var environment: [String: String] {
        guard let bundleRoot else { return [:] }
        var env = [
            "RENDER_SERVER_EXEC_PATH": bundleRoot.appending(path: "bin/virgl_render_server").path,
            "ANGLE_DEFAULT_PLATFORM": "metal",
            "XDG_RUNTIME_DIR": RuntimeDirectory.url.path,
        ]
        if direct3D {
            env["NPT_BACKEND"] = "dxmt"
            env["NPT_DXGI_LIBRARY_PATH"] = bundleRoot.appending(path: "lib/libdxmt-native.dylib").path
            env["DXMT_LOG_LEVEL"] = "none"
        }
        return env
    }

    public init(binary: URL, firmwareCode: URL, firmwareVarsTemplate: URL) {
        self.binary = binary
        self.firmwareCode = firmwareCode
        self.firmwareVarsTemplate = firmwareVarsTemplate
    }

    /// 设了环境变量 `MACVM_QEMU`（自带布局的根目录，或 Homebrew 式安装的可执行文件）时只用它；
    /// 否则依次找 App 自带的、开发时 `make qemu` 的产物、Homebrew 的 Apple Silicon 与 Intel 前缀。
    public static func locate() -> QEMUInstallation? {
        if let env = ProcessInfo.processInfo.environment["MACVM_QEMU"] {
            return bundled(at: URL(filePath: env)) ?? installed(at: [env])
        }
        for root in bundledCandidates() {
            if let found = bundled(at: root) { return found }
        }
        return installed(at: ["/opt/homebrew/bin/qemu-system-aarch64", "/usr/local/bin/qemu-system-aarch64"])
    }

    /// 可执行文件在 bin/、固件在 share/qemu/ 的安装（Homebrew 的布局）。
    private static func installed(at candidates: [String]) -> QEMUInstallation? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let binary = URL(filePath: path).resolvingSymlinksInPath()
            let share = binary.deletingLastPathComponent().deletingLastPathComponent().appending(path: "share/qemu")
            let code = share.appending(path: "edk2-aarch64-code.fd")
            let vars = share.appending(path: "edk2-arm-vars.fd")
            if FileManager.default.fileExists(atPath: code.path), FileManager.default.fileExists(atPath: vars.path) {
                return QEMUInstallation(binary: binary, firmwareCode: code, firmwareVarsTemplate: vars)
            }
        }
        return nil
    }

    public static func require() throws -> QEMUInstallation {
        guard let found = locate() else {
            throw MacVMError.unsupported("QEMU 引擎需要先安装 QEMU：brew install qemu")
        }
        return found
    }

    /// 自带 QEMU 的编译产物布局：bin/、lib/、share/。自带的库按 macOS 27 编译，更早的系统上不用。
    static func bundled(at root: URL) -> QEMUInstallation? {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) else {
            return nil
        }
        let binary = root.appending(path: "bin/qemu-system-aarch64")
        let share = root.appending(path: "share")
        let code = share.appending(path: "edk2-aarch64-code.fd")
        let vars = share.appending(path: "edk2-arm-vars.fd")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binary.path), fm.fileExists(atPath: code.path), fm.fileExists(atPath: vars.path) else { return nil }
        var found = QEMUInstallation(binary: binary, firmwareCode: code, firmwareVarsTemplate: vars)
        found.dataDirectory = share
        found.bundleRoot = root
        let display = root.appending(path: "lib/libMacVMDisplay.dylib")
        if fm.fileExists(atPath: display.path) { found.displayLibrary = display }
        found.direct3D = fm.fileExists(atPath: root.appending(path: "lib/libdxmt-native.dylib").path)
        return found
    }

    /// App 里在 Contents/Resources/QEMU；CLI 在 Contents/Resources/bin 下，同样找得到。
    /// 开发构建找仓库 .build/qemu 下最新的产物。
    private static func bundledCandidates() -> [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources.appending(path: "QEMU")) }
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return roots }
        let dir = exe.deletingLastPathComponent()
        roots.append(dir.appending(path: "../QEMU").standardizedFileURL)
        // 开发构建的可执行文件在 .build 下若干层（.build/debug 是链接），往上找到 .build 再进 qemu/。
        var ancestor = dir
        while ancestor.pathComponents.count > 1, ancestor.lastPathComponent != ".build" { ancestor.deleteLastPathComponent() }
        let builds = ancestor.lastPathComponent == ".build"
            ? (try? FileManager.default.contentsOfDirectory(at: ancestor.appending(path: "qemu"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            : []
        let newest = builds.filter { $0.lastPathComponent.contains("-") }.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        if let newest { roots.append(newest.appending(path: "QEMU")) }
        return roots
    }

    static func varsURL(_ bundle: VMBundle) -> URL { bundle.url.appending(path: "qemu-efi.vars") }

    /// virt 机型的变量闪存大小，`-drive if=pflash` 的文件必须正好这么大。
    static let flashSize: UInt64 = 64 << 20

    /// 该虚拟机还没有 QEMU 用的 EFI 变量存储时从模板复制；自带的模板去掉了补零，复制后补成稀疏文件。
    func ensureVars(for bundle: VMBundle) throws {
        let url = Self.varsURL(bundle)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.copyItem(at: firmwareVarsTemplate, to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        if try handle.seekToEnd() < Self.flashSize { try handle.truncate(atOffset: Self.flashSize) }
    }
}
