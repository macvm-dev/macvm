import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Copy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "在宿主与客户机之间复制文件或目录（经客户机代理）。",
        discussion: """
        来源与目标中恰好一方写成 <虚拟机>:<客户机上的绝对路径>，目标必须是已有目录；复制进去的项与已有项重名时编号改名（a.txt → a 2.txt）。
        含冒号的本地路径写成 ./a:b。虚拟机未运行时自动在后台启动。示例：
          macvm cp report.pdf src dev:/home/me
          macvm cp 'win:C:\\Users\\me\\Desktop\\a.txt' .
        """
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "来源（一个或多个）与目标目录。") var paths: [String]

    struct Result: Encodable, Sendable {
        /// 各顶层项复制到的位置：送进客户机时是客户机上的路径。
        let files: [String]
    }

    /// `<虚拟机>:<路径>`：冒号前不含 `/` 的才算虚拟机名。
    static func remote(_ arg: String) -> (name: String, path: String)? {
        guard let colon = arg.firstIndex(of: ":"), colon != arg.startIndex, !arg[..<colon].contains("/") else { return nil }
        return (String(arg[..<colon]), String(arg[arg.index(after: colon)...]))
    }

    enum Direction {
        case toGuest(name: String, sources: [String], dir: String)
        case fromGuest(name: String, sources: [String], dir: String)
    }

    static func direction(_ paths: [String]) throws -> Direction {
        guard paths.count >= 2, let target = paths.last else { throw ValidationError("至少要有一个来源和一个目标") }
        let sources = paths.dropLast().map { (arg: $0, remote: remote($0)) }
        if let dest = remote(target) {
            guard sources.allSatisfy({ $0.remote == nil }) else { throw ValidationError("来源与目标只能有一方在客户机里") }
            guard !dest.path.isEmpty else { throw ValidationError("客户机目标要写目录路径，如 \(dest.name):/tmp") }
            return .toGuest(name: dest.name, sources: sources.map(\.arg), dir: dest.path)
        }
        let remotes = sources.compactMap(\.remote)
        guard remotes.count == sources.count else { throw ValidationError("来源与目标要有一方写成 <虚拟机>:<路径>") }
        guard Swift.Set(remotes.map(\.name)).count == 1 else { throw ValidationError("来源要来自同一台虚拟机") }
        guard remotes.allSatisfy({ !$0.path.isEmpty }) else { throw ValidationError("客户机来源要写路径") }
        return .fromGuest(name: remotes[0].name, sources: remotes.map(\.path), dir: target)
    }

    func validate() throws { _ = try Self.direction(paths) }

    func run() async throws {
        try await Output.run(json: global.json, human: { (r: Result) in r.files.joined(separator: "\n") }) {
            let direction = try Self.direction(paths)
            let name = switch direction { case .toGuest(let name, _, _), .fromGuest(let name, _, _): name }
            let bundle = try VMLibrary.default.bundle(named: name)
            let config = try bundle.loadConfig()
            guard config.guestAgent else { throw MacVMError.unsupported("cp 要经客户机代理，\(name) 未安装代理") }
            try await Wait.untilReady(bundle, config: config, timeout: 120)
            try GuestFileTransfer.requireSupport(bundle)
            let progress = Progress()
            switch direction {
            case .toGuest(_, let sources, let dir):
                let urls = sources.map { URL(filePath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
                for url in urls where !FileManager.default.fileExists(atPath: url.path) {
                    throw MacVMError.invalidConfig("找不到 \(url.path)")
                }
                return Result(files: try GuestFileTransfer.send(urls, to: .dir(dir), bundle: bundle, progress: progress).map(\.path))
            case .fromGuest(_, let sources, let dir):
                let url = URL(filePath: (dir as NSString).expandingTildeInPath, directoryHint: .isDirectory).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw MacVMError.invalidConfig("\(url.path) 不是已有目录")
                }
                return Result(files: try GuestFileTransfer.receive(sources, into: url, bundle: bundle, progress: progress).map(\.path))
            }
        }
    }
}
