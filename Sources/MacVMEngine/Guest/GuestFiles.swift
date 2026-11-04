public import Foundation

/// 随程序分发、要放进客户机的文件：客户机代理、UEFI 引导程序。
public enum GuestFiles {
    /// 查找顺序：环境变量 `MACVM_GUEST_DIR`；App 内 `Contents/Resources/guest`（CLI 在旁边的 `bin/`）；
    /// 开发构建时向上查找源码树里的 `.build/guest`。
    public static func locate(_ name: String) -> URL? {
        var dirs: [URL] = []
        if let custom = ProcessInfo.processInfo.environment["MACVM_GUEST_DIR"] { dirs.append(URL(filePath: custom)) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let here = exe.deletingLastPathComponent()
            dirs.append(here.appending(path: "../guest").standardizedFileURL)
            dirs.append(here.appending(path: "../Resources/guest").standardizedFileURL)
            var dir = here
            for _ in 0..<6 {
                dirs.append(dir.appending(path: ".build/guest"))
                dir = dir.deletingLastPathComponent()
            }
        }
        return dirs.map { $0.appending(path: name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
