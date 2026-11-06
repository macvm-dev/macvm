import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Copy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: String(l10n: "Copy files and folders between the host and a guest (via the guest agent)."),
        discussion: String(l10n: """
        Write guest paths as <vm>:<absolute path>, for either the sources or the destination but not both. The destination must be an existing directory; if a name is already taken there, a number is appended (a.txt → a 2.txt).
        To copy a local path that contains a colon, write it as ./a:b. Starts the VM in the background if it isn't running. Examples:
          macvm cp report.pdf src dev:/home/me
          macvm cp 'win:C:\\Users\\me\\Desktop\\a.txt' .
        """)
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "One or more sources, then the destination directory."))) var paths: [String]

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
        guard paths.count >= 2, let target = paths.last else { throw ValidationError(String(l10n: "Give at least one source and a destination")) }
        let sources = paths.dropLast().map { (arg: $0, remote: remote($0)) }
        if let dest = remote(target) {
            guard sources.allSatisfy({ $0.remote == nil }) else { throw ValidationError(String(l10n: "The sources and the destination can't both be on the guest")) }
            guard !dest.path.isEmpty else { throw ValidationError(String(l10n: "The guest destination must be a directory path, such as \(dest.name):/tmp")) }
            return .toGuest(name: dest.name, sources: sources.map(\.arg), dir: dest.path)
        }
        let remotes = sources.compactMap(\.remote)
        guard remotes.count == sources.count else { throw ValidationError(String(l10n: "Either the sources or the destination must be a guest path (<vm>:<path>)")) }
        guard Swift.Set(remotes.map(\.name)).count == 1 else { throw ValidationError(String(l10n: "The sources must all be on the same VM")) }
        guard remotes.allSatisfy({ !$0.path.isEmpty }) else { throw ValidationError(String(l10n: "Guest sources must include a path")) }
        return .fromGuest(name: remotes[0].name, sources: remotes.map(\.path), dir: target)
    }

    func validate() throws { _ = try Self.direction(paths) }

    func run() async throws {
        try await Output.run(json: global.json, human: { (r: Result) in r.files.joined(separator: "\n") }) {
            let direction = try Self.direction(paths)
            let name = switch direction { case .toGuest(let name, _, _), .fromGuest(let name, _, _): name }
            let bundle = try VMLibrary.default.bundle(named: name)
            let config = try bundle.loadConfig()
            guard config.guestAgent else { throw MacVMError.unsupported(String(l10n: "cp needs the guest agent, which isn't installed on \(name)")) }
            try await Wait.untilReady(bundle, config: config, timeout: 120)
            try GuestFileTransfer.requireSupport(bundle)
            let progress = Progress()
            switch direction {
            case .toGuest(_, let sources, let dir):
                let urls = sources.map { URL(filePath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
                for url in urls where !FileManager.default.fileExists(atPath: url.path) {
                    throw MacVMError.invalidConfig(String(l10n: "Couldn't find \(url.path)"))
                }
                return Result(files: try GuestFileTransfer.send(urls, to: .dir(dir), bundle: bundle, progress: progress).map(\.path))
            case .fromGuest(_, let sources, let dir):
                let url = URL(filePath: (dir as NSString).expandingTildeInPath, directoryHint: .isDirectory).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw MacVMError.invalidConfig(String(l10n: "\(url.path) doesn't exist or isn't a directory"))
                }
                return Result(files: try GuestFileTransfer.receive(sources, into: url, bundle: bundle, progress: progress).map(\.path))
            }
        }
    }
}
