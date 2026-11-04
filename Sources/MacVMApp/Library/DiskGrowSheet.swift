import MacVMEngine
import MacVMModel
import SwiftUI

/// 扩大系统盘：输入新容量，说明客户机里怎样用上新增的空间。
struct DiskGrowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vmName: String
    let config: VMConfig
    /// 当前容量，字节。
    let currentSize: UInt64
    @State private var gigabytes: Int
    @State private var invalid = false

    private static let maxGB = 8192

    init(vmName: String, config: VMConfig, currentSize: UInt64) {
        self.vmName = vmName
        self.config = config
        self.currentSize = currentSize
        _gigabytes = State(initialValue: Self.range(above: currentSize)?.lowerBound ?? Self.maxGB)
    }

    /// 可选的新容量：比当前大的整 GB 数；当前已到 `maxGB` 时为空。
    private static func range(above currentSize: UInt64) -> ClosedRange<Int>? {
        let current = Int((currentSize + (1 << 30) - 1) >> 30)
        return current < maxGB ? (current + 1)...maxGB : nil
    }

    private var range: ClosedRange<Int>? { Self.range(above: currentSize) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("当前容量", value: DisplaySize.format(currentSize))
                if let range {
                    NumberField(title: "新容量", unit: "GB", value: $gigabytes, invalid: $invalid, range: range)
                } else {
                    Text("已达到上限 \(DisplaySize.format(UInt64(Self.maxGB) << 30))，不能再扩大。").foregroundStyle(.secondary)
                }
                Section {
                    Text(guestHint)
                    Text("只能扩大，不能缩小。镜像按实际写入占用主机空间，扩容本身不多占空间。")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("扩容") {
                    model.growDisk(vmName, gigabytes: gigabytes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(invalid || range == nil)
            }
            .padding()
        }
        .frame(width: 460)
    }

    private var guestHint: String {
        switch config.os {
        case .macOS:
            "macOS 的系统容器后面紧跟着恢复分区，新增的空间不会并入系统容器。要用上它，得在客户机里删除恢复分区后用 diskutil apfs resizeContainer 扩展系统容器，之后就进不了恢复模式。"
        case .linux where CloudInit.growsRootPartition(config):
            "下次开机时客户机自动把根分区和文件系统扩展到新容量。"
        case .linux:
            "开机后在客户机里扩展根分区和文件系统，如用「磁盘」工具，或 growpart 加 resize2fs。"
        case .windows:
            "开机后在客户机的「磁盘管理」里对 C 盘选「扩展卷」。"
        }
    }
}
