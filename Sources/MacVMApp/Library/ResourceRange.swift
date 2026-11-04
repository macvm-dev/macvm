import Foundation
import MacVMEngine

/// 新建与修改虚拟机时，处理器与内存可选的范围。
enum ResourceRange {
    static var cpuCount: ClosedRange<Int> { 1...ProcessInfo.processInfo.activeProcessorCount }

    /// 上限为主机物理内存向下取到偶数 GB。
    static var memoryGB: ClosedRange<Int> { 1...max(1, Int(HostInfo.physicalMemory >> 30) / 2 * 2) }
}
