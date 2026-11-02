import MacVMEngine
import MacVMModel
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var capabilities = HostCapabilities.current()
    @State private var sshIncluded = SSHConfig.isIncluded

    var body: some View {
        Form {
            Section("本机") {
                LabeledContent("macOS", value: capabilities.hostOS)
                LabeledContent("性能核", value: "\(capabilities.performanceCores)")
                LabeledContent("内存", value: ByteSize.format(capabilities.physicalMemory))
                capability("Windows 客户机", capabilities.windows)
                capability("Linux Rosetta", capabilities.rosetta)
                capability("桥接网络", capabilities.bridgedNetworking)
            }
            Section("位置") {
                LabeledContent("虚拟机", value: capabilities.libraryPath).textSelection(.enabled)
            }
            Section {
                Toggle("让 ssh 与 runode 看到虚拟机（macvm-<名>）", isOn: Binding(get: { sshIncluded }, set: { enable in
                    guard enable else { return }
                    do {
                        _ = try SSHConfig.write(library: model.library, macvmPath: CLILocation.path)
                        try SSHConfig.installInclude()
                        sshIncluded = SSHConfig.isIncluded
                    } catch { model.report(error) }
                }))
                .disabled(sshIncluded)
            } header: {
                Text("SSH")
            } footer: {
                Text("在 ~/.ssh/config 开头加入 \(SSHConfig.includeLine)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private func capability(_ title: String, _ ok: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .secondary)
        }
    }
}

/// App 内置 CLI 的位置；未打包运行（开发构建）时取同目录下的 macvm。
enum CLILocation {
    static var path: String {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Resources/bin/macvm")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "macvm").path
    }
}
