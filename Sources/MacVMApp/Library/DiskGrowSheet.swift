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
        let current = ResourceRange.wholeGB(currentSize)
        return current < maxGB ? (current + 1)...maxGB : nil
    }

    private var range: ClosedRange<Int>? { Self.range(above: currentSize) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Current Size", value: DisplaySize.format(currentSize))
                if let range {
                    NumberField(title: "New Size", unit: "GB", value: $gigabytes, invalid: $invalid, range: range)
                } else {
                    Text("The disk is already at its maximum size of \(DisplaySize.format(UInt64(Self.maxGB) << 30)).").foregroundStyle(.secondary)
                }
                Section {
                    Text(guestHint)
                    Text("Disks can grow but can't shrink. The image uses space on the Mac only as data is written, so growing it doesn't take up any extra space by itself.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Resize") {
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
            String(l10n: "On macOS, the recovery partition sits right after the system container, so the new space isn't added to the container. To use it, delete the recovery partition in the guest and grow the container with diskutil apfs resizeContainer. Recovery mode won't be available after that.")
        case .linux where CloudInit.growsRootPartition(config):
            String(l10n: "The guest expands its root partition and file system to the new size the next time it starts.")
        case .linux:
            String(l10n: "After the guest starts, expand its root partition and file system, for example with the Disks app or with growpart and resize2fs.")
        case .windows:
            String(l10n: "After the guest starts, open Disk Management in it and choose Extend Volume on drive C.")
        }
    }
}
