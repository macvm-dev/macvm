import CryptoKit
public import Foundation
public import MacVMModel
import Synchronization

/// 比对客户机里的代理与随程序分发的代理，并经运行中的代理自身把它换成分发的这份。
/// 更新走代理的 `exec`，不需要 SSH，客户机里任何还能 `exec` 的代理都能这样更新；
/// 代理由客户机的服务管理器重启，宿主等它带着新的 `AgentProtocol.Info.exeSHA256` 重新上线。
public enum AgentUpdate {
    public enum Status: Sendable, Equatable {
        case current
        /// 客户机里的代理与随程序分发的不同，或旧到不报 `exeSHA256`。
        case outdated
        /// 没有随程序分发的这个系统的代理，无从比对。
        case unknown
    }

    public struct Result: Sendable {
        /// 换了代理；客户机里已是随程序分发的这份时为 false。
        public let changed: Bool
        /// 换了 Windows 的 3D 显卡驱动，已请客户机重启。
        public let rebooting: Bool
    }

    /// 只换代理本身就够、不必经 SSH 重装：SSH 安装还会补上宿主有而客户机没有的认证令牌（macOS 不用令牌），
    /// 以及给还没开 3D 的 qemu 引擎 Windows 放进显卡驱动，这两种情况要走 `AgentInstaller.installOverSSH`。
    public static func coversInstall(_ bundle: VMBundle, config: VMConfig) -> Bool {
        if config.os != .macOS, AgentToken.read(bundle) == nil { return false }
        if config.os == .windows, config.engine == .qemu, !config.graphicsAcceleration,
           WindowsGPUDriver.package(QEMUInstallation.locate()) != nil { return false }
        return true
    }

    public static func status(of info: AgentProtocol.Info, os: GuestOS) -> Status {
        guard let expected = bundledSHA256(for: os) else { return .unknown }
        return info.exeSHA256 == expected ? .current : .outdated
    }

    /// 经代理查询运行中的 `bundle` 里代理的状态；代理没上线时抛错。
    public static func status(of bundle: VMBundle) throws -> Status {
        let config = try bundle.loadConfig()
        return status(of: try AgentClient.info(bundle), os: config.os)
    }

    private static let bundledHashes = Mutex<[String: String]>([:])

    /// 随程序分发的代理可执行文件的 `fingerprint`；macOS 版取代理 App 包里的可执行文件。按文件路径与修改时间缓存。
    static func bundledSHA256(for os: GuestOS) -> String? {
        guard var url = AgentInstaller.binary(for: os) else { return nil }
        if os == .macOS { url = url.appending(path: "Contents/MacOS/macvm-agent") }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)@\(modified?.timeIntervalSince1970 ?? 0)"
        if let cached = bundledHashes.withLock({ $0[key] }) { return cached }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let hash = fingerprint(data)
        bundledHashes.withLock { $0[key] = hash }
        return hash
    }

    /// 可执行文件的指纹：带代码签名的 64 位 Mach-O 取签名里主 CodeDirectory 的 SHA-256，签名时间等不在其中，
    /// 同样的代码换个时间重签指纹不变；其余取整个文件的 SHA-256。
    static func fingerprint(_ data: Data) -> String {
        let bytes = [UInt8](data)
        let digest = SHA256.hash(data: codeDirectory(bytes).map { Data(bytes[$0]) } ?? data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `LC_CODE_SIGNATURE` 指向的签名 SuperBlob 里 0 号槽的 CodeDirectory 的字节范围；不是带签名的 64 位小端 Mach-O 时为 nil。
    static func codeDirectory(_ bytes: [UInt8]) -> Range<Int>? {
        func word(_ at: Int, bigEndian: Bool) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            let b = bytes[at..<at + 4].map(Int.init)
            return bigEndian ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0]
        }
        guard word(0, bigEndian: false) == 0xfeed_facf, let count = word(16, bigEndian: false) else { return nil }
        var at = 32
        for _ in 0..<count {
            guard let cmd = word(at, bigEndian: false), let size = word(at + 4, bigEndian: false) else { return nil }
            if cmd == 0x1d {
                guard let offset = word(at + 8, bigEndian: false), let length = word(at + 12, bigEndian: false),
                      offset + length <= bytes.count, word(offset, bigEndian: true) == 0xfade_0cc0,
                      let slots = word(offset + 8, bigEndian: true) else { return nil }
                for i in 0..<slots where word(offset + 12 + i * 8, bigEndian: true) == 0 {
                    guard let blob = word(offset + 16 + i * 8, bigEndian: true).map({ offset + $0 }),
                          word(blob, bigEndian: true) == 0xfade_0c02, let size = word(blob + 4, bigEndian: true),
                          blob + size <= offset + length else { return nil }
                    return blob..<blob + size
                }
                return nil
            }
            at += size
        }
        return nil
    }

    /// 把运行中的 `bundle` 里的代理换成随程序分发的，等新代理上线。
    /// 用 qemu 引擎、开了 3D 加速的 Windows 随后经新代理推送显卡驱动，换了驱动就重启客户机。
    /// 经代理的往返都是阻塞的 socket 往返，整个过程离开调用方的 actor：运行器在 App 里时控制 socket 由主 actor 应答。
    public static func update(_ bundle: VMBundle) async throws -> Result {
        try await Task.detached {
            guard try await replace(bundle) else { return Result(changed: false, rebooting: false) }
            return Result(changed: true, rebooting: try syncGPUDriver(bundle, config: bundle.loadConfig()))
        }.value
    }

    /// 换代理并等新代理上线，返回是否换了；客户机里已是随程序分发的这份时什么也不做。要在调用方的 actor 之外调用。
    static func replace(_ bundle: VMBundle) async throws -> Bool {
        let config = try bundle.loadConfig()
        guard let binary = AgentInstaller.binary(for: config.os), let expected = bundledSHA256(for: config.os) else {
            throw MacVMError.io("找不到 \(config.os.rawValue) 版客户机代理，先运行 make agent")
        }
        guard let user = config.guestUser else { throw MacVMError.unsupported("不知道 \(config.name) 的登录用户，无法更新代理") }
        try GuestAccount.validate(user: user)
        let current = try AgentClient.info(bundle)
        guard current.exeSHA256 != expected else { return false }

        let request: AgentProtocol.ExecRequest
        let input: Data
        switch config.os {
        case .linux:
            request = .init(argv: ["/bin/sh", "-c", linuxScript(user: user)], user: "root")
            input = try Data(contentsOf: binary)
        case .macOS:
            request = .init(argv: ["/bin/sh", "-c", AgentInstaller.macOSInstallScript(user: user, detachOutput: true)])
            let archive = try await AgentInstaller.macOSArchive(binary)
            defer { try? FileManager.default.removeItem(at: archive) }
            input = try Data(contentsOf: archive)
        case .windows:
            request = PowerShell.exec(windowsScript(user: user))
            input = try Data(contentsOf: binary)
        }
        let (code, output) = try AgentClient.run(bundle, request: request, input: input)
        if let code, code != 0 {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacVMError.engine("更新客户机代理失败（退出码 \(code)）" + (detail.isEmpty ? "" : "：\(detail)"))
        }
        let online = try await VMStatus.poll(timeout: restartTimeout, interval: 1) {
            (try? AgentClient.info(bundle, timeout: 2))?.exeSHA256 == expected
        }
        guard online else { throw MacVMError.timeout("客户机代理已更新，但 \(Int(restartTimeout)) 秒内没有以新版本上线") }
        return true
    }

    /// 新代理重新上线的期限：Windows 上要等一次性计划任务停下旧代理、重新注册再启动。
    private static let restartTimeout: TimeInterval = 120

    /// 换代理会打断开机时经旧代理推送的显卡驱动，这里经新代理补推；换了驱动就请客户机重启，桌面合成才用上新驱动。
    static func syncGPUDriver(_ bundle: VMBundle, config: VMConfig) throws -> Bool {
        guard config.os == .windows, config.engine == .qemu, config.graphicsAcceleration,
              let zip = WindowsGPUDriver.package(QEMUInstallation.locate()) else { return false }
        let payload = try WindowsGPUDriver.Payload(contentsOf: zip)
        let changed = try WindowsGPUDriver.push(payload) { try ControlClient.openGuestPort(bundle, port: AgentProtocol.port) }
        if changed { _ = try AgentClient.call(.shutdown(reboot: true), bundle: bundle, timeout: 5) }
        return changed
    }

    // MARK: - 客户机里的更新脚本

    /// 以 root 运行，标准输入是新的代理。重启排进 systemd 的队列后立即返回：重启会连同本脚本结束代理的整个 cgroup。
    static func linuxScript(user: String) -> String {
        let path = AgentInstaller.linuxPath
        return """
        set -e
        cat > \(path).new
        chmod 0755 \(path).new
        mv -f \(path).new \(path)
        cat > /etc/systemd/system/macvm-agent.service <<'UNIT'
        \(AgentInstaller.linuxCloudInit(user: user).unit)UNIT
        systemctl daemon-reload
        systemctl enable macvm-agent >/dev/null 2>&1 || true
        systemctl restart --no-block macvm-agent
        """
    }

    /// 在代理目录里暂存新代理的文件名与执行替换的脚本名。
    static let windowsStagedName = "macvm-agent.update.exe"
    static let windowsScriptName = "update.ps1"
    /// 执行替换的一次性计划任务。
    static let windowsUpdateTaskName = "macvm-agent-update"

    /// 以登录用户（管理员、最高权限）运行，标准输入是新的代理。旧代理正在运行，替换不能在它的子进程里做：
    /// 把新代理与替换脚本放进代理目录，交给以 SYSTEM 运行的一次性计划任务，它照安装时的方式停下代理、收紧目录、重新注册并启动，
    /// 不管成败最后都把两个代理任务重新启动。代理目录的所有者不是 Administrators 时不往里放东西；放进去的文件所有者改成
    /// Administrators，收紧目录时才不会把它们当成不可信的内容连目录一起挪走。
    /// 脚本只用 ASCII：Windows PowerShell 按 ANSI 读无 BOM 的脚本文件。
    static func windowsScript(user: String) -> String {
        let quote = PowerShell.quote
        let directory = AgentInstaller.windowsDirectory
        let staged = directory + #"\"# + windowsStagedName
        let script = directory + #"\"# + windowsScriptName
        // 目录不可信时会被整个挪开重建，新代理先读进内存，收紧后再写回。
        let replace = """
        $agent = [IO.File]::ReadAllBytes(\(quote(staged)))
        try {
        \(AgentInstaller.windowsPrepareDirectory)
        [IO.File]::WriteAllBytes(\(quote(staged)), $agent)
        \(AgentInstaller.windowsRegistration(source: quote(staged), user: user))
        } finally {
          Start-ScheduledTask -TaskName \(AgentInstaller.windowsDesktopTaskName) -ErrorAction SilentlyContinue
          Start-ScheduledTask -TaskName \(AgentInstaller.windowsTaskName) -ErrorAction SilentlyContinue
          Remove-Item -LiteralPath \(quote(staged)) -Force -ErrorAction SilentlyContinue
          Remove-Item -LiteralPath \(quote(script)) -Force -ErrorAction SilentlyContinue
          Unregister-ScheduledTask -TaskName \(windowsUpdateTaskName) -Confirm:$false -ErrorAction SilentlyContinue
        }
        """
        return """
        $ErrorActionPreference = 'Stop'
        $admins = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Value
        $dir = Get-Item -LiteralPath \(quote(directory)) -Force
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $dir.GetAccessControl('Owner').GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $admins) {
          throw '\(directory) has an untrusted owner; reinstall macvm-agent over SSH'
        }
        $in = [Console]::OpenStandardInput()
        $out = [IO.File]::Create(\(quote(staged)))
        try { $in.CopyTo($out) } finally { $out.Close() }
        [IO.File]::WriteAllText(\(quote(script)), @'
        \(replace)
        '@, [Text.Encoding]::ASCII)
        foreach ($path in \(quote(staged)), \(quote(script))) {
          $acl = New-Object Security.AccessControl.FileSecurity
          $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier $admins))
          [IO.File]::SetAccessControl($path, $acl)
        }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "\(script)"'
        $system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName \(windowsUpdateTaskName) -Action $action -Principal $system -Force | Out-Null
        Start-ScheduledTask -TaskName \(windowsUpdateTaskName)
        """
    }
}
