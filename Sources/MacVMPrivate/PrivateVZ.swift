public import Foundation
import ObjectiveC

/// Virtualization.framework 私有选项的唯一入口。
///
/// 参数用 `NSObject` 而不是具体的 VZ 类型，使本 target 不依赖 Virtualization；
/// 选择子缺失或签名不符时视为不可用，由调用方降级，不按猜测的 ABI 调用。
public enum PrivateVZ {
    /// Windows ARM64 启动时访问 PMU 寄存器，缺少该模拟会卡死在首个 vCPU 上。
    /// 目标是 `VZGenericPlatformConfiguration`。
    private static let setPMUEmulationSelector = NSSelectorFromString("_setPerformanceMonitoringUnitEmulationEnabled:")
    private static let boolSetterEncoding = "v20@0:8B16"

    public static func supportsPMUEmulation(on platform: NSObject) -> Bool {
        boolSetter(setPMUEmulationSelector, on: platform) != nil
    }

    /// 选项不可用时返回 false。
    @discardableResult
    public static func setPMUEmulation(_ enabled: Bool, on platform: NSObject) -> Bool {
        guard let setter = boolSetter(setPMUEmulationSelector, on: platform) else { return false }
        setter(platform, setPMUEmulationSelector, enabled)
        return true
    }

    private typealias BoolSetter = @convention(c) (NSObject, Selector, Bool) -> Void

    private static func boolSetter(_ selector: Selector, on object: NSObject) -> BoolSetter? {
        guard let method = class_getInstanceMethod(type(of: object), selector),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding) == boolSetterEncoding
        else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: BoolSetter.self)
    }
}
