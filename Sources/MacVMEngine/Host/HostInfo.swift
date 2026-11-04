import Foundation
public import MacVMModel

public enum HostInfo {
    /// 性能核数；取不到时退回全部逻辑核。
    public static var performanceCoreCount: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 { return Int(value) }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// 不超过主机逻辑核数。
    public static func defaultCPUCount() -> Int { min(4, ProcessInfo.processInfo.activeProcessorCount) }

    /// 不超过主机物理内存的一半，避免默认配置就压垮主机。
    public static func defaultMemorySize() -> UInt64 {
        min(8 << 30, physicalMemory / 2)
    }

    public static func defaultDiskSize(for os: GuestOS) -> UInt64 {
        os == .linux ? 64 << 30 : 96 << 30
    }
}
