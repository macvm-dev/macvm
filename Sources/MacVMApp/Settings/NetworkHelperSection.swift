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
            LabeledContent("Network Helper") {
                HStack(spacing: 8) {
                    Text(statusText).foregroundStyle(.secondary)
                    switch status {
                    case .notRegistered:
                        Button("Enable", action: enable)
                    case .notFound where Self.bundled:
                        Button("Enable", action: enable)
                    case .requiresApproval:
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                    case .enabled:
                        if running == false { Button("Re-enable") { confirmingReenable = true } }
                        Button("Disable", action: disable)
                    default:
                        EmptyView()
                    }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Bridged Networking")
        } footer: {
            Text("Bridged networking puts virtual machines directly on your Mac's local network, where they get addresses from the router. To send and receive network traffic, it needs a network helper that runs with administrator privileges. After you enable it, allow MacVM in System Settings › General › Login Items & Extensions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Re-enable the Network Helper?", isPresented: $confirmingReenable) {
            Button("Re-enable", action: reenable)
        } message: {
            Text("The helper will be turned off and back on. Virtual machines using bridged networking will lose their network connection.")
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var statusText: String {
        switch status {
        case .enabled: running == false ? String(l10n: "Enabled but not responding") : String(l10n: "Enabled")
        case .requiresApproval: String(l10n: "Waiting for approval in System Settings")
        case .notRegistered: String(l10n: "Not enabled")
        case .notFound: Self.bundled ? String(l10n: "Not enabled") : String(l10n: "Unavailable outside the app bundle")
        @unknown default: String(l10n: "Unknown")
        }
    }

    private func refresh() async {
        status = Self.service.status
        running = status == .enabled ? await Task.detached { HostCapabilities.networkHelperRunning() }.value : nil
    }

    private func enable() {
        error = nil
        do { try NetworkHelperRegistration.enable() } catch {
            self.error = String(l10n: "Couldn't enable: \(error.localizedDescription)")
        }
        Task { await refresh() }
        if Self.service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private func reenable() {
        error = nil
        Task {
            do { try await NetworkHelperRegistration.reregister() } catch {
                self.error = String(l10n: "Couldn't re-enable: \(error.localizedDescription)")
            }
            await refresh()
            if Self.service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    private func disable() {
        error = nil
        Task {
            do { try await NetworkHelperRegistration.disable() } catch {
                self.error = String(l10n: "Couldn't disable: \(error.localizedDescription)")
            }
            await refresh()
        }
    }
}
