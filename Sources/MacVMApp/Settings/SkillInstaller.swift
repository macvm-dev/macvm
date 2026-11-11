import AppKit
import SwiftUI

/// App 自带的 `macvm` 技能（教 agent 用 CLI 操作虚拟机），经 `npx skills add` 装进各 agent。
/// 装给哪些 agent 由用户在终端里选；源用 App 包里的这份，与本机的 CLI 版本一致。
enum SkillInstaller {
    static let name = "macvm"

    /// App 包里的技能目录；未打包运行（开发构建）时没有。
    static var source: URL? {
        guard let url = Bundle.main.resourceURL?.appending(path: "skills/\(name)"),
              FileManager.default.fileExists(atPath: url.appending(path: "SKILL.md").path) else { return nil }
        return url
    }

    /// 在终端里运行 `npx skills add`：要交互选择装给哪些 agent，也要让用户看到 npx 的输出与报错。
    /// 用 `.command` 文件交给 LaunchServices 打开，不需要 Apple Events 权限。
    static func openInstaller() throws {
        guard let source else { throw CocoaError(.fileNoSuchFile) }
        let missing = String(l10n: "npx wasn't found. Install Node.js (https://nodejs.org), then choose Install Agent Skill… again.")
        // 登录 shell 才有 Homebrew 等加进 PATH 的目录；从 Finder 打开的终端环境里没有它们时再补上常见位置。
        let script = """
        #!/bin/zsh -l
        export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
        if ! command -v npx >/dev/null 2>&1; then
          echo \(shellQuoted(missing))
          exit 1
        fi
        npx -y skills add \(shellQuoted(source.path)) -g

        """
        let url = FileManager.default.temporaryDirectory.appending(path: "MacVM Install Agent Skill.command")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
    }

    /// 已装的技能与 App 自带的不同时换成自带的，让技能跟着 App 升级；`npx skills update` 不更新本地源装的技能。
    /// 没装过的不装，符号链接（指向 `~/.agents/skills` 的，或用户自己链到源码仓库的）不动，出错时静默放弃。
    /// 技能要与终端里的 `macvm` 一致，从 DMG 里直接打开或被系统随机挪位（App Translocation）时那不是本 App，不更新。
    static func updateInstalled() {
        guard let source,
              (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly != true else { return }
        let fm = FileManager.default
        let wanted = contents(of: source)
        for destination in installedCopies() where contents(of: destination) != wanted {
            // 先复制到同目录下的临时名再整个换上去，复制到一半失败时不会留下残缺的技能；指向这个路径的链接不受影响。
            let staging = destination.deletingLastPathComponent().appending(path: ".\(name)-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            do {
                try fm.copyItem(at: source, to: staging)
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } catch {}
        }
    }

    /// 已装的副本：`~/.agents/skills/macvm`，以及只装给单个 agent 时 `skills` 直接复制进去的
    /// `~/.<agent>/skills/macvm`、`~/.config/<agent>/skills/macvm`。
    private static func installedCopies() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let config = home.appending(path: ".config")
        let roots = [home.appending(path: ".agents")]
            + ((try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".") }
            + ((try? fm.contentsOfDirectory(at: config, includingPropertiesForKeys: nil)) ?? [])
        return Set(roots.map { $0.appending(path: "skills/\(name)").standardizedFileURL }).filter { url in
            (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil
                && fm.fileExists(atPath: url.appending(path: "SKILL.md").path)
        }.sorted { $0.path < $1.path }
    }

    /// 目录下各文件相对路径到内容的映射。
    private static func contents(of directory: URL) -> [String: Data] {
        let root = directory.standardizedFileURL.path + "/"
        var result: [String: Data] = [:]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let url as URL in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(root.count))] = data
        }
        return result
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// App 菜单里的「安装 Agent 技能…」。
struct SkillMenu: View {
    var body: some View {
        Button("Install Agent Skill…") {
            do {
                try SkillInstaller.openInstaller()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        .disabled(SkillInstaller.source == nil)
    }
}
