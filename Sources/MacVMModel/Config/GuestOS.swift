public enum GuestOS: String, Codable, Sendable, CaseIterable {
    case macOS = "macos"
    case linux
    case windows

    /// 走 EFI 固件与通用平台（`VZGenericPlatformConfiguration`）的客户机。
    public var usesEFI: Bool { self != .macOS }

    /// 该系统的客户机能否 `saveMachineState`，不考虑具体设备配置。
    /// Windows 依赖的私有平台选项会让保存被拒绝。
    public var supportsSuspend: Bool { self != .windows }
}
