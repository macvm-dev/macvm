import CoreGraphics
import CryptoKit
import Foundation
import MacVMModel

/// 拼出 qemu-system-aarch64 的参数。设备选择以 Windows ARM64 为准，Linux 同样适用。
struct QEMUCommand {
    /// NAT 下经 QEMU 用户态网络转发到 Unix socket 的客户机端口：SSH 与客户机代理。
    static let forwardedPorts: [UInt32] = [22, AgentProtocol.port]

    let bundle: VMBundle
    let config: VMConfig
    let qemu: QEMUInstallation
    var display = false
    var incoming: URL?

    static func qmpSocket(_ bundle: VMBundle) -> URL { RuntimeDirectory.url.appending(path: "\(bundle.runtimeName).qmp") }
    static func portSocket(_ bundle: VMBundle, port: UInt32) -> URL { RuntimeDirectory.url.appending(path: "\(bundle.runtimeName).p\(port).sock") }
    /// 画面经这两个 Unix socket 之一提供，`QEMUDisplayView` 连上它显示并转发键鼠：
    /// 自带的 QEMU 用 SPICE（GL 画面经 IOSurface 共享，不拷像素），Homebrew 的用 VNC。
    static func vncSocket(_ bundle: VMBundle) -> URL { RuntimeDirectory.url.appending(path: "\(bundle.runtimeName).vnc") }
    static func spiceSocket(_ bundle: VMBundle) -> URL { RuntimeDirectory.url.appending(path: "\(bundle.runtimeName).spice") }

    var usesSpice: Bool { qemu.displayLibrary != nil }

    /// 自带的 QEMU 用 virtio-ramfb-gl：驱动加载前是 ramfb 的线性帧缓冲（固件、WinPE、不带 DRM 驱动的内核都能用），
    /// 之后由 virtio-gpu 接管并经 virglrenderer 加速。
    /// Homebrew 的 QEMU 没有它：装好的 Windows 用 virtio-gpu，viogpudo 的硬件光标经 VNC 交给宿主作系统光标；
    /// 安装阶段的 WinPE 没有 viogpudo，Linux 云镜像内核不带 DRM 驱动，都只能用 ramfb。
    var graphicsDevice: String {
        if usesSpice {
            // hostmem 只是给客户机映射 GPU 资源的地址窗口，用多少占多少。
            // Windows 的 viogpu3d 只提供不超过开机时这个尺寸的模式，分辨率跟随窗口（含 Retina）时就到不了更大；
            // 取本机最大屏幕的像素尺寸，窗口放在哪块屏幕上都够用。
            let initial = Self.fittingEDID(Self.largestHostDisplay().map { (max($0.width, config.display.width), max($0.height, config.display.height)) }
                ?? (config.display.width, config.display.height))
            var device = "virtio-ramfb-gl,id=gpu,blob=true,hostmem=\(Self.hostMemoryWindow(config.memorySize)),xres=\(initial.0),yres=\(initial.1)"
            if config.os == .windows, qemu.direct3D { device += ",neptune=true" }
            return device
        }
        return config.os == .windows && config.installMedia.isEmpty ? "virtio-gpu-pci" : "ramfb"
    }

    /// 不超过内存一半的最大 2 的幂：hostmem 是 PCI BAR 的大小，QEMU 要求 BAR 大小是 2 的幂，否则启动即断言失败。
    static func hostMemoryWindow(_ memorySize: UInt64) -> UInt64 {
        let half = memorySize / 2
        guard half > 0 else { return 0 }
        return UInt64(1) << (63 - half.leadingZeroBitCount)
    }

    /// QEMU 的 `key=value,...` 选项里逗号是分隔符，值中的逗号要写成两个。
    static func optionValue(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    /// Windows 只采用 EDID 详细时序描述得了的首选模式：像素时钟只有 16 位（单位 10 kHz），按 QEMU 生成时序的消隐比例
    /// 与自带 QEMU 的 EDID 刷新率（60 Hz）算，宽×高最多这么多像素；超过时 QEMU 改用 DisplayID 描述，Windows 不认。
    static let maximumGuestPixels = 7_800_000

    /// 超过 `maximumGuestPixels` 时按比例缩小，保持宽高比与偶数宽高。
    static func fittingEDID(_ size: (Int, Int)) -> (Int, Int) {
        let pixels = size.0 * size.1
        guard pixels > maximumGuestPixels else { return size }
        let scale = (Double(maximumGuestPixels) / Double(pixels)).squareRoot()
        return (Int(Double(size.0) * scale) & ~1, Int(Double(size.1) * scale) & ~1)
    }

    /// 当前接着的显示器里像素最多的那块的像素尺寸；没有显示器（如远程登录的无头 Mac）时为 nil。
    static func largestHostDisplay() -> (width: Int, height: Int)? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.compactMap { CGDisplayCopyDisplayMode($0) }.map { (width: $0.pixelWidth, height: $0.pixelHeight) }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// 主板（SMBIOS）UUID，从包内的机器标识算出：每台虚拟机唯一、每次启动不变，克隆时随机器标识一起换。
    /// 客户机据它认出同一台机器（Windows 激活即是），QEMU 默认给的是全零。
    static func systemUUID(_ bundle: VMBundle) -> String? {
        guard let identity = try? Data(contentsOf: bundle.machineIdentifierURL) else { return nil }
        var bytes = Array(SHA256.hash(data: identity).prefix(16))
        // 只借用 RFC 9562 第 5 版的版本位与变体位，让它是格式合法的 UUID；散列是 SHA-256，并非真正的第 5 版 UUID。
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: uuid).uuidString
    }

    func arguments() throws -> [String] {
        var a: [String] = qemu.dataDirectory.map { ["-L", $0.path] } ?? []
        a += ["-name", Self.optionValue(config.name)]
        if let uuid = Self.systemUUID(bundle) { a += ["-uuid", uuid] }
        a += [
            "-nodefaults", "-no-user-config",
            "-machine", "virt,highmem=on,gic-version=3",
            // 自带的 QEMU 支持 4K 的 IPA 粒度：Windows 的 GPU 驱动按 4K 偏移映射资源，默认的 16K 粒度下映射失败、QEMU 退出。
            "-accel", qemu.bundleRoot == nil ? "hvf" : "hvf,ipa-granule-size=4096", "-cpu", "host",
            // 运行它的进程（应用或 macvm run）意外退出时 QEMU 跟着退出，不留下无人管理的虚拟机。
            "-run-with", "exit-with-parent=on",
            // 固件的启动菜单倒计时默认取 EFI 变量 Timeout（客户机里的引导程序可能把它设成几秒）；
            // 等待时间为 0 时固件按它把倒计时改成 0，不再每次开机白等。
            "-boot", "menu=on,splash-time=0",
            "-smp", "\(config.cpuCount)",
            "-m", "\(config.memorySize >> 20)M",
            // 自带的固件去掉了补零，不能当 pflash0；-bios 两种都能加载。
            "-bios", qemu.firmwareCode.path,
            "-drive", "if=pflash,unit=1,format=raw,file=\(Self.optionValue(QEMUInstallation.varsURL(bundle).path))",
            "-device", graphicsDevice,
            "-device", "qemu-xhci,id=usb",
            "-device", "usb-kbd,bus=usb.0",
            "-device", "usb-tablet,bus=usb.0",
            "-device", "virtio-rng-pci",
            // 客户机把空闲页报给宿主，自带的 QEMU 随即把它们还给 macOS。
            "-device", "virtio-balloon-pci,free-page-reporting=on",
        ]

        for (i, disk) in config.disks.enumerated() {
            let url = bundle.resolve(disk.path)
            let cache = disk.caching == .uncached ? "none" : "writeback"
            a += ["-drive", "if=none,id=disk\(i),format=raw,file=\(Self.optionValue(url.path)),readonly=\(disk.readOnly ? "on" : "off"),cache=\(cache),discard=unmap,detect-zeroes=unmap"]
            let boot = i == 0 ? ",bootindex=1" : ""
            switch disk.bus {
            case .nvme: a += ["-device", "nvme,drive=disk\(i),serial=macvm\(i)\(boot)"]
            case .virtio: a += ["-device", "virtio-blk-pci,drive=disk\(i)\(boot)"]
            case .usb: a += ["-device", "usb-storage,bus=usb.0,drive=disk\(i),removable=on\(boot)"]
            }
        }

        // 第一张 ISO 优先启动；其余介质也要带启动序号，固件只会连接列在启动顺序里的设备。
        for (i, media) in config.installMedia.enumerated() {
            let url = bundle.resolve(media)
            let isISO = url.pathExtension.lowercased() == "iso"
            a += ["-drive", "if=none,id=media\(i),format=raw,readonly=on,file=\(Self.optionValue(url.path))\(isISO ? ",media=cdrom" : "")"]
            a += ["-device", "usb-storage,bus=usb.0,drive=media\(i),removable=on,bootindex=\(i == 0 ? 0 : i + 1)"]
        }

        if let net = config.networks.first {
            switch net.mode {
            case .nat:
                let forwards = Self.forwardedPorts.map { "hostfwd=unix:\(Self.optionValue(Self.portSocket(bundle, port: $0).path))-:\($0)" }.joined(separator: ",")
                a += ["-netdev", "user,id=net0,\(forwards)"]
            case .bridged:
                // `BridgeSession` 的 socket 作为 QEMU 的标准输入交给它：`Process` 只把标准输入输出传给子进程。
                a += ["-netdev", "dgram,id=net0,local.type=fd,local.str=0"]
            case .vmnetShared, .vmnetHost:
                throw MacVMError.unsupported("QEMU 引擎不支持 vmnet 网络")
            }
            // 固件自带 virtio-net 驱动，不加载网卡的选项 ROM（自带的 QEMU 也没带）。
            a += ["-device", "virtio-net-pci,netdev=net0,romfile=\(net.macAddress.map { ",mac=\(Self.optionValue($0))" } ?? "")"]
        }

        // HDA 可迁移，挂起不受影响；usb-audio 会让 QEMU 拒绝保存状态。
        if config.audio {
            a += ["-audiodev", "coreaudio,id=snd0", "-device", "ich9-intel-hda", "-device", "hda-output,audiodev=snd0"]
        }
        if !config.shares.isEmpty {
            throw MacVMError.unsupported("QEMU 引擎在 macOS 上不支持 virtio-fs 共享目录")
        }

        a += ["-qmp", "unix:\(Self.optionValue(Self.qmpSocket(bundle).path)),server=on,wait=off"]
        if usesSpice {
            // GL 画面不能同时给 VNC；自带的 QEMU 也不带 Cocoa 窗口，`display` 不起作用。
            a += ["-display", "none", "-spice", "unix=on,addr=\(Self.optionValue(Self.spiceSocket(bundle).path)),disable-ticketing=on,gl=on"]
        } else {
            a += ["-display", display ? "cocoa" : "none", "-vnc", "unix:\(Self.optionValue(Self.vncSocket(bundle).path))"]
        }
        a += ["-monitor", "none", "-serial", "none"]
        if let incoming { a += ["-incoming", "file:\(incoming.path)"] }
        return a
    }
}
