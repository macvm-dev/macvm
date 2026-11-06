import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import MacVMModel
import UniformTypeIdentifiers

/// 把另一个进程建的 global IOSurface（BGRA，自上而下）存成 PNG。
enum IOSurfaceImage {
    static func writePNG(surfaceID: IOSurfaceID, to url: URL) throws {
        guard let surface = IOSurfaceLookup(surfaceID) else {
            throw MacVMError.engine(String(l10n: "Couldn't find the QEMU display surface (IOSurface \(surfaceID))"))
        }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        // 读的时候 QEMU 还在往里画，先整块拷出来再解锁，免得编码途中被改。
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else {
            throw MacVMError.engine(String(l10n: "Couldn't read the QEMU display surface (IOSurface \(surfaceID))"))
        }
        let pixels = Data(bytes: IOSurfaceGetBaseAddress(surface), count: bytesPerRow * height)
        IOSurfaceUnlock(surface, .readOnly, nil)

        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw MacVMError.engine(String(l10n: "Couldn't encode the image as PNG")) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MacVMError.engine(String(l10n: "Couldn't write \(url.path)")) }
    }
}
