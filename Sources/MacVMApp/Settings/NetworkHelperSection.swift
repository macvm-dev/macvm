import AppKit
import MacVMEngine
import MacVMModel
import ServiceManagement
import SwiftUI

/// 网络辅助程序 macvm-netd 的启用与停用。只有 App 能注册它：`SMAppService` 按主 bundle 找 launchd plist。
struct NetworkHelperSection: View {
    @State private var status = Self.service.status
    @State private var running = false
    @State private var error: String?

    private static var service: SMAppService { .daemon(plistName: NetworkHelper.launchdPlistName) }

    /// 从没注册过的守护进程 `status` 也是 `.notFound`，要看包里有没有 plist 才分得清是不是没打包。
    private static var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appending(path: "Contents/Library/LaunchDaemons/\(NetworkHelper.launchdPlistName)").path)
    }

    var body: some View {
        Section {
            LabeledContent("网络辅助程序") {
                HStack(spacing: 8) {
                    Text(statusText).foregroundStyle(.secondary)
                    switch status {
                    case .notRegistered:
                        Button("启用", action: enable)
                    case .notFound where Self.bundled:
                        Button("启用", action: enable)
                    case .requiresApproval:
                        Button("打开系统设置") { SMAppService.openSystemSettingsLoginItems() }
                    case .enabled:
                        Button("停用", action: disable)
                    default:
                        EmptyView()
                    }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("桥接网络")
        } footer: {
            Text("桥接让虚拟机直接接入主机所在的局域网，从局域网的路由器取得地址。收发网络帧要用到以管理员权限运行的网络辅助程序，启用后到「系统设置 › 通用 › 登录项与扩展」里允许 MacVM。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var statusText: String {
        switch status {
        case .enabled: running ? "已启用" : "已启用，未响应"
        case .requiresApproval: "等待在系统设置里允许"
        case .notRegistered: "未启用"
        case .notFound: Self.bundled ? "未启用" : "未打包运行，不可用"
        @unknown default: "未知"
        }
    }

    private func refresh() async {
        status = Self.service.status
        running = status == .enabled ? await Task.detached { HostCapabilities.networkHelperRunning() }.value : false
    }

    private func enable() {
        error = nil
        do { try Self.service.register() } catch {
            // 首次注册时系统要用户去系统设置里允许，register 以「需要批准」报错，状态随之变成 requiresApproval。
            if Self.service.status != .requiresApproval { self.error = "启用失败：\(error.localizedDescription)" }
        }
        Task { await refresh() }
        if Self.service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private func disable() {
        error = nil
        Task {
            do { try await Self.service.unregister() } catch {
                self.error = "停用失败：\(error.localizedDescription)"
            }
            await refresh()
        }
    }
}
