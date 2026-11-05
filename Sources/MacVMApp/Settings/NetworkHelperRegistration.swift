import Foundation
import MacVMEngine
import MacVMModel
import ServiceManagement

/// 网络辅助程序 macvm-netd 的 launchd 注册。只有 App 能注册它：`SMAppService` 按主 bundle 找 launchd plist。
/// launchd 按后台任务管理（BTM）登记里的启动约束拉起守护进程：正式签名时约束 Team ID 与签名 identifier，
/// ad-hoc 签名时约束 cdhash。包里的 macvm-netd 换了签名就对不上约束，被内核杀掉，要重新注册。
@MainActor
enum NetworkHelperRegistration {
    static var service: SMAppService { .daemon(plistName: NetworkHelper.launchdPlistName) }

    /// 从没注册过的守护进程 `status` 也是 `.notFound`，要看包里有没有 plist 才分得清是不是没打包。
    static var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appending(path: "Contents/Library/LaunchDaemons/\(NetworkHelper.launchdPlistName)").path)
    }

    /// 用户是否要启用：只随用户在设置里启用、重新启用、停用而变，自动注册失败时不清掉，下次启动再试。
    private static let wantedKey = "networkHelperWanted"
    private static var wanted: Bool { UserDefaults.standard.bool(forKey: wantedKey) }

    static func enable() throws {
        UserDefaults.standard.set(true, forKey: wantedKey)
        try register()
    }

    static func disable() async throws {
        UserDefaults.standard.set(false, forKey: wantedKey)
        try await service.unregister()
    }

    /// 先注销再注册，让 launchd 换用 BTM 里的当前登记；正在用桥接的虚拟机会断网。
    static func reregister() async throws {
        UserDefaults.standard.set(true, forKey: wantedKey)
        try await cycle()
    }

    /// App 启动时调用，在后台让注册符合用户的意愿：要启用却没注册时补注册，已启用却不响应时重新注册。
    /// 出错时静默放弃，设置页里仍可手动操作。
    static func reconcile() {
        guard bundled else { return }
        let defaults = UserDefaults.standard
        switch service.status {
        case .enabled:
            defaults.set(true, forKey: wantedKey)
            Task { await repairIfUnresponsive() }
        case .notRegistered, .notFound:
            guard wanted else { return }
            Task { try? await registerRetrying() }
        default:
            return
        }
    }

    /// 重新注册后 BTM 可能仍沿用旧登记，要等按旧约束拉起失败、launchd 隔一阵再拉一次时才换成新登记，再重新注册才生效。
    /// 所以重新注册后的那次等得够 launchd 再拉一次，仍不响应就再来一轮。
    private static func repairIfUnresponsive() async {
        for timeout: TimeInterval in [2, 15, 15] {
            if await Task.detached(operation: { HostCapabilities.networkHelperRunning(timeout: timeout) }).value { return }
            guard service.status == .enabled, (try? await cycle()) != nil else { return }
        }
    }

    /// 首次注册时系统要用户去系统设置里允许，`register` 以「需要批准」报错、状态变成 `requiresApproval`，这不算失败。
    private static func register() throws {
        do { try service.register() } catch {
            guard service.status == .requiresApproval else { throw error }
        }
    }

    private static func cycle() async throws {
        try await service.unregister()
        try await registerRetrying()
    }

    /// 注销刚返回时 BTM 可能仍把这项记成停用，紧接着注册会被拒绝，隔一会儿再试。
    /// 每次注册前都看用户是否仍要启用：重试期间用户可能已在设置里停用。
    private static func registerRetrying() async throws {
        var delay = Duration.milliseconds(500)
        while wanted {
            do { return try register() } catch {
                guard delay <= .seconds(4) else { throw error }
                try await Task.sleep(for: delay)
                delay *= 2
            }
        }
    }
}
