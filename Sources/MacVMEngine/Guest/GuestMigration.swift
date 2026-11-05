public import Foundation
public import MacVMModel

/// 把已有虚拟机带到某一 `GuestRevision` 的一步：安装流程后来才做的事，在建得早的虚拟机里补做。
/// 经代理的 `exec` 运行，Linux 以 root、Windows 以登录用户（管理员、最高权限）、macOS 以登录用户；
/// 脚本要能重复执行，要重启客户机才生效时在输出里打出 `rebootMarker`。
struct GuestMigration: Sendable {
    let os: GuestOS
    let revision: Int
    /// 给用户看的一句话。
    let title: String
    /// 返回要执行的命令与送进它标准输入的内容。
    let prepare: @Sendable (VMConfig) async throws -> (AgentProtocol.ExecRequest, Data)

    static let rebootMarker = "macvm-reboot-required"

    /// 每个系统的修订号从 1 起连续，最后一条等于 `GuestRevision.latest`。
    static let all: [GuestMigration] = [windowsClockAndSSH, windowsVirtioDrivers]

    /// `config` 还没做的迁移，按修订号排好。
    static func pending(for config: VMConfig) -> [GuestMigration] {
        all.filter { $0.os == config.os && $0.revision > config.guestRevision }.sorted { $0.revision < $1.revision }
    }

    // MARK: - Windows

    static let windowsClockAndSSH = GuestMigration(os: .windows, revision: 1, title: "主板时钟按 UTC 读，SSH 只认密钥") { _ in
        let script = """
        $ErrorActionPreference = 'Stop'
        \(WindowsUnattend.utcClock)
        \(WindowsUnattend.sshKeyOnly)
        if (Get-Service sshd -ErrorAction SilentlyContinue) { Restart-Service sshd }
        """
        return (PowerShell.exec(script), Data())
    }

    /// 装上 `WindowsInstaller.virtioWinURL` 这一版的 virtio 驱动。pnputil 只在驱动包比已装的更合适时才替换，不会降级。
    static let windowsVirtioDrivers = GuestMigration(os: .windows, revision: 2, title: "virtio 驱动更新到 App 自带的版本") { _ in
        let iso = try await WindowsInstaller.cachedVirtioWin(showProgress: false)
        let id = UUID().uuidString
        let staging = FileManager.default.temporaryDirectory.appending(path: "macvm-virtio-\(id)", directoryHint: .isDirectory)
        let archive = FileManager.default.temporaryDirectory.appending(path: "macvm-virtio-\(id).tar")
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: archive)
        }
        try await DiskMount.withMounted(iso) { root in try WindowsInstaller.copyDrivers(fromVirtioWin: root, to: staging) }
        // 不带 AppleDouble 文件，pnputil 会把 `._*.inf` 当成格式不对的驱动而整体报错。
        try await Subprocess.run("/usr/bin/tar", ["--no-mac-metadata", "-c", "-f", archive.path, "-C", staging.path, "."])
        let script = """
        $ErrorActionPreference = 'Stop'
        $root = Join-Path $env:TEMP "macvm-virtio-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $root | Out-Null
        try {
          $tar = Join-Path $root 'drivers.tar'
          $in = [Console]::OpenStandardInput()
          $out = [IO.File]::Create($tar)
          try { $in.CopyTo($out) } finally { $out.Close() }
          tar -xf $tar -C $root
          if ($LASTEXITCODE) { throw "tar exited with $LASTEXITCODE" }
          pnputil /add-driver (Join-Path $root '*.inf') /subdirs /install | Out-Host
          $code = $LASTEXITCODE
          # 3010：装上了，重启后生效；259：没有要更新的设备。
          if ($code -eq 3010) { Write-Output '\(rebootMarker)' } elseif ($code -ne 0 -and $code -ne 259) { throw "pnputil exited with $code" }
        } finally {
          Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
        }
        """
        return (PowerShell.exec(script), try Data(contentsOf: archive))
    }
}
