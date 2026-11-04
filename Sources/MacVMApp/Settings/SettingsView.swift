import AppKit
import MacVMEngine
import MacVMModel
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var capabilities = HostCapabilities.current()
    @State private var sshIncluded = SSHConfig.isIncluded
    @AppStorage(StatusMenu.visibleKey) private var showsMenuBarExtra = true

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
            Section("通用") {
                Toggle("在菜单栏显示", isOn: $showsMenuBarExtra)
            }
            Section {
                LocationRow(title: "虚拟机", url: model.library.root, isCustom: model.settings.libraryPath != nil,
                            editable: model.canChangeLibrary) { model.setLibraryPath($0) }
                LocationRow(title: "下载", url: model.settings.downloadRoot, isCustom: model.settings.downloadPath != nil,
                            editable: model.canChangeDownloads) { model.setDownloadPath($0) }
            } header: {
                Text("位置")
            } footer: {
                footer(locationFooter)
            }
            Section {
                Toggle("把虚拟机加入 ~/.ssh/config", isOn: Binding(get: { sshIncluded }, set: { enable in
                    do {
                        if enable {
                            _ = try SSHConfig.write(library: model.library, macvmPath: CLILocation.path)
                            try SSHConfig.installInclude()
                        } else {
                            try SSHConfig.removeInclude()
                        }
                    } catch { model.report(error) }
                    sshIncluded = SSHConfig.isIncluded
                }))
            } header: {
                Text("SSH")
            } footer: {
                footer("可直接 ssh \(model.machines.first?.name ?? "dev")。只加一行 Include，不改动其他内容。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// 分组表单的说明文字默认是正文色、右对齐，改成次要色左对齐的小字。
    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var locationFooter: String {
        if VMLibrary.environmentRoot != nil { return "虚拟机目录由环境变量 MACVM_HOME 指定。" }
        if !model.canChangeLibrary { return "有虚拟机运行或正在创建时不能更改虚拟机目录。" }
        if !model.canChangeDownloads { return "正在下载或安装时不能更改下载目录。" }
        return "更改后不会搬动已有文件，命令行同样生效。"
    }

    private func capability(_ title: String, _ ok: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .secondary)
        }
    }
}

/// 一个可更改的目录：显示路径，菜单里选择新目录、恢复默认或在 Finder 中显示。
private struct LocationRow: View {
    let title: String
    let url: URL
    let isCustom: Bool
    let editable: Bool
    /// 参数为 nil 表示恢复默认。
    let change: (URL?) -> Void

    var body: some View {
        let path = url.path(percentEncoded: false)
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(path)
                Menu {
                    Button("选择…", action: choose).disabled(!editable)
                    Button("恢复默认") { change(nil) }.disabled(!editable || !isCustom)
                    Divider()
                    Button("在 Finder 中显示", action: reveal)
                } label: {
                    Image(systemName: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = url
        panel.prompt = "选择"
        if panel.runModal() == .OK, let picked = panel.url { change(picked) }
    }

    private func reveal() {
        // 默认目录在第一次用到前还不存在。
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
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
