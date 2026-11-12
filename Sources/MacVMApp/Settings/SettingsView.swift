import AppKit
import MacVMEngine
import MacVMModel
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var capabilities = HostCapabilities.current()
    @AppStorage(StatusMenu.visibleKey) private var showsMenuBarExtra = true
    @State private var language = AppLanguage.current

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("macOS", value: capabilities.hostOS)
                LabeledContent("Performance Cores", value: "\(capabilities.performanceCores)")
                LabeledContent("Memory", value: DisplaySize.format(capabilities.physicalMemory))
                capability("Windows Guests", capabilities.windows)
                capability("Linux Rosetta", capabilities.rosetta)
            }
            Section("General") {
                Toggle("Show in Menu Bar", isOn: $showsMenuBarExtra)
                AutomaticUpdateToggle()
                Picker("Language", selection: Binding(get: { language }, set: {
                    AppLanguage.set($0)
                    language = $0
                })) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.name).tag($0) }
                }
                if AppLanguage.next != AppLanguage.active {
                    LabeledContent {
                        Button("Restart MacVM") { AppLanguage.restart() }
                    } label: {
                        Text("The new language takes effect after MacVM restarts.").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LocationRow(title: "Virtual Machines", url: model.library.root, isCustom: model.settings.libraryPath != nil,
                            editable: model.canChangeLibrary) { model.setLibraryPath($0) }
                LocationRow(title: "Downloads", url: model.settings.downloadRoot, isCustom: model.settings.downloadPath != nil,
                            editable: model.canChangeDownloads) { model.setDownloadPath($0) }
                LocationRow(title: "Templates", url: model.templateLibrary.root, isCustom: model.settings.templatePath != nil,
                            editable: model.canChangeTemplates) { model.setTemplatePath($0) }
            } header: {
                Text("Locations")
            } footer: {
                footer(locationFooter)
            }
            Section {
                ForEach(model.templates, id: \.name) { TemplateRow(template: $0) }
            } header: {
                Text("Templates")
            } footer: {
                footer(model.templates.isEmpty
                       ? String(l10n: "To make a template, choose Save as Template… from a virtual machine's More Actions menu. You can then create virtual machines from it.")
                       : String(l10n: "Virtual machines created from a template get a new machine identifier and MAC address. Deleting a template doesn't affect virtual machines created from it."))
            }
            Section {
                Toggle("Add Virtual Machines to ~/.ssh/config", isOn: Binding(get: { model.sshIncluded }, set: { model.setSSHIncluded($0) }))
            } header: {
                Text("SSH")
            } footer: {
                footer(String(l10n: "Then you can run ssh \(model.machines.first?.name ?? "dev") directly. MacVM adds a single Include line and changes nothing else."))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            model.refreshSSHIncluded()
            model.refreshTemplates()
        }
    }

    /// 分组表单的说明文字默认是正文色、右对齐，改成次要色左对齐的小字。
    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var locationFooter: String {
        if VMLibrary.environmentRoot != nil { return String(l10n: "The virtual machine folder is set by the MACVM_HOME environment variable.") }
        if !model.canChangeLibrary, !model.interruptedCreations.isEmpty {
            return String(l10n: "To change the virtual machine folder, first resume or discard the interrupted creation in the list.")
        }
        if !model.canChangeLibrary { return String(l10n: "The virtual machine folder can't be changed while a virtual machine is running or being created.") }
        if !model.canChangeDownloads { return String(l10n: "The download and template folders can't be changed while downloading, installing, or saving a template.") }
        return String(l10n: "Changing a location doesn't move existing files. The macvm command uses the new location too.")
    }

    private func capability(_ title: LocalizedStringKey, _ ok: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .secondary)
        }
    }
}

/// 一个模板：名称、系统与资源，悬停时出现删除按钮。
private struct TemplateRow: View {
    @Environment(AppModel.self) private var model
    let template: TemplateSummary
    @State private var hovering = false
    @State private var confirmingDelete = false

    var body: some View {
        LabeledContent {
            Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Delete Template")
        } label: {
            Label {
                Text(template.name)
                Text(detail)
            } icon: {
                Image(systemName: template.os.symbol)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: template.path)]) }
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Delete Template “\(template.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteTemplate(template.name) }
        } message: {
            Text("Virtual machines created from it aren't affected.")
        }
    }

    private var detail: String {
        var parts = [template.os.label, String(l10n: "\(template.cpuCount) cores"), DisplaySize.format(template.memorySize)]
        if let disk = template.diskSize { parts.append(String(l10n: "\(DisplaySize.format(disk)) disk")) }
        return parts.joined(separator: " · ")
    }
}

/// 一个可更改的目录：显示路径，菜单里选择新目录、恢复默认或在 Finder 中显示。
private struct LocationRow: View {
    let title: LocalizedStringKey
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
                    Button("Choose…", action: choose).disabled(!editable)
                    Button("Restore Default") { change(nil) }.disabled(!editable || !isCustom)
                    Divider()
                    Button("Show in Finder", action: reveal)
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
        panel.prompt = String(l10n: "Choose")
        if panel.runModal() == .OK, let picked = panel.url { change(picked) }
    }

    private func reveal() {
        // 默认目录在第一次用到前还不存在。
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
