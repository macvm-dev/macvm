import CoreGraphics
import Foundation

/// RFB 3.8 客户端，只实现显示 QEMU 画面所需的部分：无认证、Raw 编码、桌面尺寸变化、
/// QEMU 扩展按键事件（直接发扫描码，与键盘布局无关）、Alpha 光标（客户机硬件光标的形状）。
/// 读在专用线程，回调在主线程。
final class VNCClient: @unchecked Sendable {
    var onFrame: (@MainActor (CGImage, CGSize) -> Void)?
    /// 客户机硬件光标的形状与热点（像素）；尺寸为零表示隐藏光标。
    var onCursor: (@MainActor (CGImage?, CGPoint) -> Void)?
    var onClose: (@MainActor () -> Void)?

    private let socket: UnixSocket
    private let writeLock = NSLock()
    private var context: CGContext?
    private var closed = false
    /// 读线程放下的最新一帧，主线程取走前再来的帧直接覆盖它，主线程忙时不积压过时的帧。
    private let frameLock = NSLock()
    private var pendingFrame: CGImage?

    private enum Encoding: Int32 {
        case raw = 0
        case desktopSize = -223
        case qemuExtendedKey = -258
        case extendedDesktopSize = -308
        case alphaCursor = -314
    }

    init(path: String) throws {
        socket = try UnixSocket.connect(to: path)
    }

    func start() {
        let thread = Thread { [self] in
            do { try run() } catch {}
            close()
            let onClose = onClose
            Task { @MainActor in onClose?() }
        }
        thread.name = "macvm.vnc"
        thread.start()
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(socket.fd, SHUT_RDWR)
    }

    // MARK: - 输入

    /// `buttons` 各位：1 左键、2 中键、4 右键、8 滚轮上、16 滚轮下。
    func sendPointer(buttons: UInt8, x: UInt16, y: UInt16) {
        var m = Data([5, buttons])
        m.append(be: x)
        m.append(be: y)
        send(m)
    }

    /// QEMU 扩展按键事件，直接带 qnum。
    func sendKey(qnum: UInt32, down: Bool) {
        var m = Data([255, 0])
        m.append(be: UInt16(down ? 1 : 0))
        m.append(be: UInt32(0))
        m.append(be: qnum)
        send(m)
    }

    private func send(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        try? socket.writeAll(data)
    }

    // MARK: - 协议

    private func run() throws {
        guard let version = try socket.readExact(12), version.starts(with: Data("RFB 003.".utf8)) else { throw VNCError.protocol }
        send(Data("RFB 003.008\n".utf8))
        let typeCount = Int(try read(1)[0])
        guard typeCount > 0 else { throw VNCError.protocol }
        guard try read(typeCount).contains(1) else { throw VNCError.protocol }
        send(Data([1]))
        guard try read(4).be32(at: 0) == 0 else { throw VNCError.protocol }

        send(Data([1])) // ClientInit：共享连接
        let serverInit = try read(24)
        let width = Int(serverInit.be16(at: 0)), height = Int(serverInit.be16(at: 2))
        _ = try read(Int(serverInit.be32(at: 20))) // 名称
        resize(width: width, height: height)

        // SetPixelFormat：32 位小端 0x00RRGGBB，即内存中 B G R X，对应 CGImage 的 byteOrder32Little + noneSkipFirst。
        var format = Data([0, 0, 0, 0, 32, 24, 0, 1])
        format.append(be: UInt16(255)); format.append(be: UInt16(255)); format.append(be: UInt16(255))
        format.append(contentsOf: [16, 8, 0, 0, 0, 0])
        send(format)

        let encodings: [Encoding] = [.raw, .desktopSize, .extendedDesktopSize, .qemuExtendedKey, .alphaCursor]
        var setEncodings = Data([2, 0])
        setEncodings.append(be: UInt16(encodings.count))
        for e in encodings { setEncodings.append(be: UInt32(bitPattern: e.rawValue)) }
        send(setEncodings)
        requestUpdate(incremental: false)

        while true {
            switch try read(1)[0] {
            case 0: try readFramebufferUpdate()
            case 1: // SetColourMapEntries
                let h = try read(5)
                _ = try read(Int(h.be16(at: 3)) * 6)
            case 2: break // Bell
            case 3: // ServerCutText
                let h = try read(7)
                _ = try read(Int(h.be32(at: 3)))
            default: throw VNCError.protocol
            }
        }
    }

    private func readFramebufferUpdate() throws {
        let h = try read(3)
        let count = Int(h.be16(at: 1))
        for _ in 0..<count {
            let r = try read(12)
            let x = Int(r.be16(at: 0)), y = Int(r.be16(at: 2)), w = Int(r.be16(at: 4)), hgt = Int(r.be16(at: 6))
            switch Encoding(rawValue: Int32(bitPattern: r.be32(at: 8))) {
            case .raw: try readRaw(x: x, y: y, width: w, height: hgt)
            case .desktopSize: resize(width: w, height: hgt)
            case .extendedDesktopSize:
                let screens = Int(try read(4)[0])
                _ = try read(screens * 16)
                resize(width: w, height: hgt)
            case .qemuExtendedKey: break // 服务端确认支持扩展按键，无载荷
            case .alphaCursor: try readAlphaCursor(hotspot: CGPoint(x: x, y: y), width: w, height: hgt)
            case nil: throw VNCError.protocol
            }
        }
        if let image = context?.makeImage(), post(image) {
            let onFrame = onFrame
            Task { @MainActor [self] in
                guard let image = takeFrame() else { return }
                onFrame?(image, CGSize(width: image.width, height: image.height))
            }
        }
        requestUpdate(incremental: true)
    }

    /// 放下最新一帧，返回是否需要派主线程来取（已有一次在途时不必）。
    private func post(_ image: CGImage) -> Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        let idle = pendingFrame == nil
        pendingFrame = image
        return idle
    }

    private func takeFrame() -> CGImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        defer { pendingFrame = nil }
        return pendingFrame
    }

    /// 像素直接读进位图上下文；矩形越界时读出丢弃。
    private func readRaw(x: Int, y: Int, width: Int, height: Int) throws {
        let rowBytes = width * 4
        guard let context, let base = context.data, x + width <= context.width, y + height <= context.height else {
            _ = try read(rowBytes * height)
            return
        }
        let stride = context.bytesPerRow
        if x == 0, rowBytes == stride {
            try read(into: base + y * stride, count: rowBytes * height)
        } else {
            for row in 0..<height { try read(into: base + (y + row) * stride + x * 4, count: rowBytes) }
        }
    }

    /// 载荷为一个编码号（只会是 Raw）加逐像素 32 位小端 ARGB（内存中 B G R A，非预乘）。
    private func readAlphaCursor(hotspot: CGPoint, width: Int, height: Int) throws {
        guard Int32(bitPattern: try read(4).be32(at: 0)) == Encoding.raw.rawValue else { throw VNCError.protocol }
        let image = cursorImage(bgra: try read(width * height * 4), width: width, height: height)
        let onCursor = onCursor
        Task { @MainActor [image] in onCursor?(image, hotspot) }
    }

    private func resize(width: Int, height: Int) {
        guard width > 0, height > 0, context?.width != width || context?.height != height else { return }
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
    }

    private func requestUpdate(incremental: Bool) {
        guard let context else { return }
        var m = Data([3, incremental ? 1 : 0])
        m.append(be: UInt16(0)); m.append(be: UInt16(0))
        m.append(be: UInt16(context.width)); m.append(be: UInt16(context.height))
        send(m)
    }

    private func read(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        guard let data = try socket.readExact(count) else { throw VNCError.closed }
        return data
    }

    private func read(into destination: UnsafeMutableRawPointer, count: Int) throws {
        guard try socket.readExact(into: UnsafeMutableRawBufferPointer(start: destination, count: count)) else { throw VNCError.closed }
    }

    private enum VNCError: Error { case `protocol`, closed }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(be value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func be16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func be32(at offset: Int) -> UInt32 {
        UInt32(be16(at: offset)) << 16 | UInt32(be16(at: offset + 2))
    }
}

/// 逐像素 B G R A（非预乘）、自上而下的光标图；尺寸为零或数据不足时为 nil。
func cursorImage(bgra: Data, width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, bgra.count >= width * height * 4, let provider = CGDataProvider(data: bgra as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}
