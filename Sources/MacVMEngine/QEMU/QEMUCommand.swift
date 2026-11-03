import Foundation
import MacVMModel

/// 拼出 qemu-system-aarch64 的参数。设备选择以 Windows ARM64 为准，Linux 同样适用。
struct QEMUCommand {
    /// 经 QEMU 用户态网络转发到 Unix socket 的客户机端口：SSH 与客户机代理。
    static let forwardedPorts: [UInt32] = [22, AgentProtocol.port]

    let bundle: VMBundle
    let config: VMConfig
    let qemu: QEMUInstallation
    var display = false
    var incoming: URL?

    static func qmpSocket(_ bundle: VMBundle) -> URL { RuntimeDirectory.url.appending(path: "\(bundle.name).qmp") }
    static func portSocket(_ bundle: VMBundle, port: UInt32) -> URL { RuntimeDirectory.url.appending(path: "\(bundle.name).p\(port).sock") }
    /// 画面经此 Unix socket 以 VNC 提供，`QEMUDisplayView` 连上它显示并转发键鼠。
    static func vncSocket(_ bundle: VMBundle) -> URL { RuntimeDirectory.url.appending(path: "\(bundle.name).vnc") }

    func arguments() throws -> [String] {
        var a: [String] = [
            "-name", config.name,
            "-nodefaults", "-no-user-config",
            "-machine", "virt,highmem=on,gic-version=3",
            "-accel", "hvf", "-cpu", "host",
            // 运行它的进程（应用或 macvm run）意外退出时 QEMU 跟着退出，不留下无人管理的虚拟机。
            "-run-with", "exit-with-parent=on",
            "-smp", "\(config.cpuCount)",
            "-m", "\(config.memorySize >> 20)M",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(qemu.firmwareCode.path)",
            "-drive", "if=pflash,format=raw,file=\(QEMUInstallation.varsURL(bundle).path)",
            // Windows 启动阶段需要线性帧缓冲，virtio-gpu 的 GOP 只支持 Blt。
            "-device", "ramfb",
            "-device", "qemu-xhci,id=usb",
            "-device", "usb-kbd,bus=usb.0",
            "-device", "usb-tablet,bus=usb.0",
            "-device", "virtio-rng-pci",
            "-device", "virtio-balloon-pci",
        ]

        for (i, disk) in config.disks.enumerated() {
            let url = bundle.resolve(disk.path)
            let cache = disk.caching == .uncached ? "none" : "writeback"
            a += ["-drive", "if=none,id=disk\(i),format=raw,file=\(url.path),readonly=\(disk.readOnly ? "on" : "off"),cache=\(cache),discard=unmap,detect-zeroes=unmap"]
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
            a += ["-drive", "if=none,id=media\(i),format=raw,readonly=on,file=\(url.path)\(isISO ? ",media=cdrom" : "")"]
            a += ["-device", "usb-storage,bus=usb.0,drive=media\(i),removable=on,bootindex=\(i == 0 ? 0 : i + 1)"]
        }

        if let net = config.networks.first {
            guard net.mode == .nat else { throw MacVMError.unsupported("QEMU 引擎只支持 NAT 网络") }
            let forwards = Self.forwardedPorts.map { "hostfwd=unix:\(Self.portSocket(bundle, port: $0).path)-:\($0)" }.joined(separator: ",")
            a += ["-netdev", "user,id=net0,\(forwards)"]
            a += ["-device", "virtio-net-pci,netdev=net0\(net.macAddress.map { ",mac=\($0)" } ?? "")"]
        }

        // HDA 可迁移，挂起不受影响；usb-audio 会让 QEMU 拒绝保存状态。
        if config.audio {
            a += ["-audiodev", "coreaudio,id=snd0", "-device", "ich9-intel-hda", "-device", "hda-output,audiodev=snd0"]
        }
        if !config.shares.isEmpty {
            throw MacVMError.unsupported("QEMU 引擎在 macOS 上不支持 virtio-fs 共享目录")
        }

        a += ["-qmp", "unix:\(Self.qmpSocket(bundle).path),server=on,wait=off"]
        // ramfb 没有硬件光标，客户机自己在画面里画光标；cocoa 默认在指针进入窗口时藏起宿主光标，免得出现两个。
        a += ["-display", display ? "cocoa" : "none", "-vnc", "unix:\(Self.vncSocket(bundle).path)", "-monitor", "none", "-serial", "none"]
        if let incoming { a += ["-incoming", "file:\(incoming.path)"] }
        return a
    }
}
