import AppKit
import MacVMModel
import SwiftUI

/// 共享给客户机的主机目录；`editable` 为 false 时只读。
struct SharesSection: View {
    @Environment(AppModel.self) private var model
    let vmName: String
    let config: VMConfig
    let editable: Bool
    @State private var choosing = false

    var body: some View {
        Section {
            if config.shares.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("没有共享目录").foregroundStyle(.secondary)
                    Text(editable ? "把主机上的文件夹共享给客户机，两边看到同一份文件。也可以把文件夹拖到这里。" : "把主机上的文件夹共享给客户机，两边看到同一份文件。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            ForEach(config.shares, id: \.hostPath) { share in
                row(share)
            }
        } header: {
            HStack {
                Text("共享目录")
                Spacer()
                Button { choosing = true } label: { Label("添加", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(!editable)
                    .help(editable ? "" : "现在不能添加，关机后再改")
            }
        } footer: {
            if !config.shares.isEmpty {
                Text(guestHint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { model.addShares(vmName, urls) }
        }
    }

    private func row(_ share: ShareConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(share.tag)
                Text((share.hostPath as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(share.hostPath)
            }
            Spacer()
            Toggle("只读", isOn: Binding(get: { share.readOnly },
                                        set: { model.setShareReadOnly(vmName, hostPath: share.hostPath, $0) }))
                .toggleStyle(.checkbox)
                .disabled(!editable)
            Button { model.removeShare(vmName, hostPath: share.hostPath) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!editable)
                .help("移除共享")
        }
        .contextMenu {
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: share.hostPath)]) }
        }
    }

    private var guestHint: String {
        if config.os == .macOS { return "客户机里在 /Volumes/My Shared Files 下，以名称为目录。" }
        let example = config.shares[0].tag
        return "Linux 客户机里挂载：sudo mkdir -p /mnt/\(example) && sudo mount -t virtiofs \(example) /mnt/\(example)，开机自动挂载要写进 /etc/fstab。"
    }
}

extension View {
    /// 接受从 Finder 拖来的文件夹，加为 `vmName` 的共享目录；`editable` 为 false 时不接受。
    func acceptsShareDrops(vmName: String, editable: Bool) -> some View {
        modifier(ShareDropTarget(vmName: vmName, editable: editable))
    }
}

private struct ShareDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let vmName: String
    let editable: Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let folders = urls.filter(Self.isFolder)
                guard editable, !folders.isEmpty else { return false }
                model.addShares(vmName, folders)
                return true
            } isTargeted: { targeted = editable && $0 }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
    }

    /// 只收文件夹；App 之类的包虽是目录也不收。
    private static func isFolder(_ url: URL) -> Bool {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }
}
