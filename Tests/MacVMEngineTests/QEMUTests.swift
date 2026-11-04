import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing

struct QEMUCommandTests {
    let qemu = QEMUInstallation(binary: URL(filePath: "/q"), firmwareCode: URL(filePath: "/code.fd"), firmwareVarsTemplate: URL(filePath: "/vars.fd"))

    @Test func windowsInstallArguments() throws {
        let bundle = VMBundle(url: URL(filePath: "/vms/win.macvm"))
        let config = VMConfig(name: "win", os: .windows, engine: .qemu, cpuCount: 4, memorySize: 8 << 30,
                              disks: [DiskConfig(path: "disk.img", bus: .nvme), DiskConfig(path: "data.img", bus: .nvme)],
                              networks: [NetworkConfig(macAddress: "02:00:00:00:00:01")],
                              installMedia: ["/isos/win.iso", "setup.img"])
        let args = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments().joined(separator: " ")
        #expect(args.contains("-m 8192M"))
        #expect(args.contains("nvme,drive=disk0,serial=macvm0,bootindex=1"))
        #expect(args.contains("nvme,drive=disk1,serial=macvm1 "))
        #expect(args.contains("file=/isos/win.iso,media=cdrom"))
        #expect(args.contains("drive=media0,removable=on,bootindex=0"))
        #expect(args.contains("file=/vms/win.macvm/setup.img"))
        #expect(args.contains("hostfwd=unix:"))
        #expect(args.contains("mac=02:00:00:00:00:01"))
    }

    @Test func bridgedNetworkReadsFramesFromStandardInput() throws {
        let bundle = VMBundle(url: URL(filePath: "/vms/deb.macvm"))
        let config = VMConfig(name: "deb", os: .linux, engine: .qemu, cpuCount: 2, memorySize: 2 << 30,
                              disks: [DiskConfig(path: "disk.img", bus: .virtio)],
                              networks: [NetworkConfig(mode: .bridged, interface: "en0", macAddress: "02:00:00:00:00:01")])
        let args = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments().joined(separator: " ")
        #expect(args.contains("-netdev dgram,id=net0,local.type=fd,local.str=0"))
        #expect(!args.contains("hostfwd"))
        #expect(args.contains("mac=02:00:00:00:00:01"))
    }

    @Test func installedWindowsUsesVirtioGPU() throws {
        let bundle = VMBundle(url: URL(filePath: "/vms/win.macvm"))
        var config = VMConfig(name: "win", os: .windows, engine: .qemu, cpuCount: 2, memorySize: 4 << 30,
                              disks: [DiskConfig(path: "disk.img", bus: .nvme)], installMedia: ["/isos/win.iso"])
        #expect(try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments().contains("ramfb"))
        config.installMedia = []
        let args = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments()
        #expect(args.contains("virtio-gpu-pci") && !args.contains("ramfb"))
        #expect(args.contains("unix:" + QEMUCommand.vncSocket(bundle).path))
    }

    @Test func bundledQEMUUsesSpiceGL() throws {
        var bundled = qemu
        bundled.dataDirectory = URL(filePath: "/q/share")
        bundled.displayLibrary = URL(filePath: "/q/lib/libMacVMDisplay.dylib")
        bundled.direct3D = true
        bundled.bundleRoot = URL(filePath: "/q")
        let bundle = VMBundle(url: URL(filePath: "/vms/win.macvm"))
        var config = VMConfig(name: "win", os: .windows, engine: .qemu, cpuCount: 2, memorySize: 4 << 30,
                              disks: [DiskConfig(path: "disk.img", bus: .nvme)], installMedia: ["/isos/win.iso"])
        let args = try QEMUCommand(bundle: bundle, config: config, qemu: bundled).arguments()
        let joined = args.joined(separator: " ")
        // 安装期与装好后是同一个设备，Windows 不会因换设备重新识别显卡。
        let device = try #require(args.first { $0.hasPrefix("virtio-ramfb-gl,id=gpu,blob=true,hostmem=2147483648,") })
        #expect(device.hasSuffix(",neptune=true"))
        // 初始尺寸不小于配置，本机有更大的屏幕时取屏幕的。
        let xres = try #require(device.split(separator: ",").first { $0.hasPrefix("xres=") }.flatMap { Int($0.dropFirst(5)) })
        #expect(xres >= config.display.width)
        #expect(joined.contains("-spice unix=on,addr=\(QEMUCommand.spiceSocket(bundle).path),disable-ticketing=on,gl=on"))
        #expect(!args.contains("-vnc") && args.starts(with: ["-L", "/q/share"]))
        #expect(joined.contains("-bios /code.fd -drive if=pflash,unit=1,"))
        #expect(joined.contains("-accel hvf,ipa-granule-size=4096"))
        #expect(bundled.environment["RENDER_SERVER_EXEC_PATH"] == "/q/bin/virgl_render_server")
        config.os = .linux
        #expect(!(try QEMUCommand(bundle: bundle, config: config, qemu: bundled).arguments().joined().contains("neptune")))
    }

    @Test func guestSizeFitsEDID() {
        #expect(QEMUCommand.fittingEDID((2560, 1600)) == (2560, 1600))
        let (w, h) = QEMUCommand.fittingEDID((5120, 2880))
        #expect(w * h <= QEMUCommand.maximumGuestPixels && w % 2 == 0 && h % 2 == 0)
        #expect(abs(Double(w) / Double(h) - 16.0 / 9.0) < 0.01)
    }

    @Test func rejectsDirectorySharing() {
        let bundle = VMBundle(url: URL(filePath: "/vms/a.macvm"))
        let config = VMConfig(name: "a", os: .linux, engine: .qemu, cpuCount: 2, memorySize: 1 << 30, disks: [],
                              shares: [ShareConfig(hostPath: "/tmp", tag: "tmp")])
        #expect(throws: MacVMError.self) { _ = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments() }
    }
}
