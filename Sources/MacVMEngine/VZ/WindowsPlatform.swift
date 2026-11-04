import Foundation
public import MacVMModel
import MacVMPrivate
@preconcurrency import Virtualization

extension ConfigBuilder {
    func configureWindowsPlatform(_ vz: VZVirtualMachineConfiguration) throws {
        let platform = try genericPlatform()
        guard PrivateVZ.setPMUEmulation(true, on: platform) else {
            throw MacVMError.unsupported("当前 macOS 的 Virtualization.framework 不提供 PMU 模拟，无法运行 Windows")
        }
        vz.platform = platform
        vz.bootLoader = try efiBootLoader()
    }
}

public enum WindowsSupport {
    /// 本机能否用 VZ 运行 Windows 客户机。
    public static var isAvailable: Bool {
        PrivateVZ.supportsPMUEmulation(on: VZGenericPlatformConfiguration())
    }

    public static let bootImageName = "vz-boot.img"

    /// VZ 下 Windows 的固定分辨率。viogpudo 切换模式时销毁旧资源并以同一 ID 按新尺寸重建，VZ 却一直按
    /// 驱动开机时建的第一个资源（即此尺寸）取画面，换成别的宽度就花屏或黑屏；所以不随窗口改分辨率，由 VZ 缩放画面。
    public static let displaySize = (width: 1024, height: 768)

    public static var fixedDisplayError: MacVMError {
        .unsupported("VZ 下 Windows 的分辨率固定为 \(displaySize.width)x\(displaySize.height)，画面随窗口缩放；需要其他分辨率请用 qemu 引擎")
    }

    static func bootImageURL(_ bundle: VMBundle) -> URL { bundle.url.appending(path: bootImageName) }

    /// VZ 启动 Windows 前的准备：
    /// - 包内放一块 FAT 启动盘，`\EFI\BOOT\BOOTAA64.EFI` 是 macvm-boot（帧缓冲垫片 + 转交 Windows 启动管理器）；
    /// - 重建 EFI 变量存储。Windows 会把自己的启动项写在最前，留着它固件就会绕过垫片直接启动 Windows，
    ///   而没有启动项时固件按设备顺序找可移动介质的默认路径，先找到排在第一位的启动盘。
    public static func prepareForVZ(_ bundle: VMBundle) async throws {
        let image = bootImageURL(bundle)
        if !FileManager.default.fileExists(atPath: image.path) {
            guard let loader = GuestFiles.locate("macvm-boot.efi") else {
                throw MacVMError.io("找不到 macvm-boot.efi，先运行 make boot")
            }
            let staging = FileManager.default.temporaryDirectory.appending(path: "macvm-vzboot-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging.appending(path: "EFI/BOOT"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: loader, to: staging.appending(path: "EFI/BOOT/BOOTAA64.EFI"))
            try await DiskImage.createFAT(from: staging, to: image, size: "16m", volumeName: "MACVMBOOT")
        }
        try? FileManager.default.removeItem(at: bundle.efiVariableStoreURL)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariableStoreURL)
    }
}
