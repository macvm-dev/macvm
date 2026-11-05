import AppKit
import MacVMEngine
import MacVMModel
import ServiceManagement
import SwiftUI

/// 网络辅助程序 macvm-netd 的启用与停用。
struct NetworkHelperSection: View {
    @State private var status = Self.service.status
    /// 辅助进程是否响应 ping；未启用或首次查询还没完成时为 nil。
    @State private var running: Bool?
    @State private var confirmingReenable = false
    @State private var error: String?

    private static var service: SMAppService { NetworkHelperRegistration.service }

    private static var bundled: Bool { NetworkHelperRegistration.bundled }

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
                        if running == false { Button("重新启用") { confirmingReenable = true } }
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
        .confirmationDialog("重新启用网络辅助程序？", isPresented: $confirmingReenable) {
            Button("重新启用", action: reenable)
        } message: {
            Text("辅助程序会先停用再启用，正在使用桥接网络的虚拟机会断网。")
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var statusText: String {
        switch status {
        case .enabled: running == false ? "已启用，未响应" : "已启用"
        case .requiresApproval: "等待在系统设置里允许"
        case .notRegistered: "未启用"
        case .notFound: Self.bundled ? "未启用" : "未打包运行，不可用"
        @unknown default: "未知"
        }
    }

    private func refresh() async {
        status = Self.service.status
        running = status == .enabled ? await Task.detached { HostCapabilities.networkHelperRunning() }.value : nil
    }

    private func enable() {
        error = nil
        do { try NetworkHelperRegistration.enable() } catch {
            self.error = "启用失败：\(error.localizedDescription)"
        }
        Task { await refresh() }
        if Self.service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private func reenable() {
        error = nil
        Task {
            do { try await NetworkHelperRegistration.reregister() } catch {
                self.error = "重新启用失败：\(error.localizedDescription)"
            }
            await refresh()
            if Self.service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    private func disable() {
        error = nil
        Task {
            do { try await NetworkHelperRegistration.disable() } catch {
                self.error = "停用失败：\(error.localizedDescription)"
            }
            await refresh()
        }
    }
}
