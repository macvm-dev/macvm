public import Foundation
public import MacVMModel

/// Ubuntu 桌面版的无人值守安装。安装程序（subiquity）从卷标 `cidata` 的种子盘里读 user-data 的 `autoinstall:`；
/// 内核命令行没有 `autoinstall` 时它会在写盘前停下等人确认，所以从改过 GRUB 配置的 ISO 副本引导。
/// 安装环境一开始就关掉网络，安装程序只用安装盘里的软件包离线安装，不联网拉更新；装好的系统照常联网。
/// 装好的系统带登录用户、SSH 公钥、免密 sudo 与客户机代理；代理经 vsock 响应即算装完。
public enum UbuntuAutoinstall {
    public static let seedFileName = "autoinstall-seed.iso"
    static let setupScriptName = "macvm-setup.sh"
    static let agentUnitName = "macvm-agent.service"
    static let agentTokenName = "macvm-agent-token"

    public struct Options: Sendable {
        public var hostname: String
        public var user: String
        public var password: String
        public var sshPublicKey: String
        public var shares: [ShareConfig]
        public var rosetta: Bool
        /// tz 数据库里的时区名。
        public var timezone: String
        public var agentBinary: URL?
        /// 写进客户机的 `AgentToken`。
        public var agentToken: String?

        public init(hostname: String, user: String, password: String, sshPublicKey: String, shares: [ShareConfig] = [], rosetta: Bool = false,
                    timezone: String = TimeZone.current.identifier,
                    agentBinary: URL? = AgentInstaller.binary(for: .linux), agentToken: String? = nil) {
            self.hostname = UbuntuAutoinstall.hostname(for: hostname)
            self.user = user
            self.password = password
            self.sshPublicKey = sshPublicKey
            self.shares = shares
            self.rosetta = rosetta
            self.timezone = timezone
            self.agentBinary = agentBinary
            self.agentToken = agentToken
        }
    }

    // MARK: - 引导 ISO

    static let bootISOExtension = "autoinstall.iso"

    /// `iso` 旁边的引导副本 `<名>.autoinstall.iso`，没有时克隆一份再改写其中的 GRUB 配置。
    /// 克隆在 APFS 上共享数据块，副本只多占改写的那一个扇区。
    static func bootISO(for iso: URL) throws -> URL {
        let boot = iso.deletingPathExtension().appendingPathExtension(bootISOExtension)
        if FileManager.default.fileExists(atPath: boot.path) { return boot }
        let staging = iso.deletingLastPathComponent().appending(path: ".\(boot.lastPathComponent).\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Clone.file(from: iso, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staging.path)

        let extent = try ISO9660.extent(of: "boot/grub/grub.cfg", in: staging)
        let handle = try FileHandle(forUpdating: staging)
        defer { try? handle.close() }
        try handle.seek(toOffset: extent.offset)
        let original = String(decoding: try handle.read(upToCount: extent.length) ?? Data(), as: UTF8.self)
        try handle.seek(toOffset: extent.offset)
        try handle.write(contentsOf: Data(try grubConfig(patching: original).utf8))
        try handle.synchronize()

        // 别的进程同时生成的副本内容相同，谁后改名都一样。
        guard rename(staging.path, boot.path) == 0 else { throw MacVMError.posix(String(l10n: "Couldn't generate \(boot.lastPathComponent)")) }
        return boot
    }

    /// 只留第一个启动项并立即启动，内核参数加上 `autoinstall` 与 `noprompt`（关机时 casper 不等人取出安装盘）。
    /// 原地改写不能改变文件长度，结果用空格补齐到原来的字节数。
    static func grubConfig(patching original: String) throws -> String {
        let lines = original.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard var kernel = lines.first(where: { $0.hasPrefix("linux ") }),
              let initrd = lines.first(where: { $0.hasPrefix("initrd ") }),
              let dashes = kernel.range(of: " ---")
        else { throw MacVMError.io(String(l10n: "Couldn't find the kernel boot entry in the Ubuntu installer's GRUB configuration")) }
        kernel.insert(contentsOf: " autoinstall noprompt", at: dashes.lowerBound)
        let config = """
        set timeout=0
        menuentry "Install Ubuntu" {
            set gfxpayload=keep
            \(kernel)
            \(initrd)
        }

        """
        let padding = original.utf8.count - config.utf8.count
        guard padding >= 0 else { throw MacVMError.io(String(l10n: "The Ubuntu installer's GRUB configuration is too short to fit the autoinstall boot entry")) }
        return config + String(repeating: " ", count: padding)
    }

    // MARK: - 种子盘

    static func writeSeed(_ o: Options, in bundle: VMBundle) async throws {
        try await CloudInit.buildSeed(at: bundle.url.appending(path: seedFileName)) { staging in
            try CloudInit.metaData(instanceID: UUID().uuidString, hostname: o.hostname)
                .write(to: staging.appending(path: "meta-data"), atomically: true, encoding: .utf8)
            try userData(o).write(to: staging.appending(path: "user-data"), atomically: true, encoding: .utf8)
            try setupScript(o).write(to: staging.appending(path: setupScriptName), atomically: true, encoding: .utf8)
            if let agent = o.agentBinary {
                try FileManager.default.copyItem(at: agent, to: staging.appending(path: "macvm-agent"))
                try AgentInstaller.linuxCloudInit(user: o.user).unit.write(to: staging.appending(path: agentUnitName), atomically: true, encoding: .utf8)
            }
            if let token = o.agentToken {
                try token.write(to: staging.appending(path: agentTokenName), atomically: true, encoding: .utf8)
            }
        }
    }

    /// 装完重启进入装好的系统：EFI 启动顺序里安装程序写的启动项排在安装盘前面。
    /// 安装界面的语言跟随 `locale`，arm64 安装程序显示不了中日韩文字，所以固定用英文。
    /// - early-commands 在安装程序判断有没有网络之前执行：关掉网络并等默认路由消失，它就直接离线安装；
    ///   `geoip: false` 免得它再等 geoip 超时。
    /// - 安装环境关机时有服务要等到停止超时才放行，late-commands 把这次关机的停止超时压短。
    static func userData(_ o: Options) -> String {
        let yaml = CloudInit.yaml
        let seed = "/run/macvm-seed"
        let offline = "nmcli networking off || true; for i in $(seq 20); do ip -4 route show default | grep -q . || break; sleep 0.5; done"
        let setup = "mkdir -p \(seed) && mount -o ro /dev/disk/by-label/cidata \(seed) && sh \(seed)/\(setupScriptName) \(seed) /target; s=$?; umount \(seed); exit $s"
        let quickShutdown = "mkdir -p /run/systemd/system.conf.d && printf '[Manager]\\nDefaultTimeoutStopSec=5s\\n' > /run/systemd/system.conf.d/90-macvm.conf && systemctl daemon-reload"
        return """
        #cloud-config
        autoinstall:
          version: 1
          early-commands:
            - \(yaml(offline))
          locale: en_US.UTF-8
          keyboard:
            layout: us
          timezone: \(yaml(o.timezone))
          apt:
            geoip: false
          storage:
            layout:
              name: direct
          identity:
            hostname: \(yaml(o.hostname))
            realname: \(yaml(o.user))
            username: \(yaml(o.user))
            password: \(yaml(ShadowPassword.sha512Crypt(o.password)))
          ssh:
            install-server: true
            allow-pw: false
            authorized-keys:
              - \(yaml(o.sshPublicKey))
          late-commands:
            - \(yaml(setup))
            - \(yaml(quickShutdown))
          shutdown: reboot

        """
    }

    /// 在安装环境里以 `sh <脚本> <种子盘挂载点> <目标系统根>` 运行，配置装好的系统。
    /// 安装程序按安装环境里关掉的网卡写出不带 DHCP 的 netplan，删掉它，网卡交给 NetworkManager 默认的 DHCP。
    /// NetworkManager 按 MAC 发 DHCP 客户端标识，主机才能在租约表里按 MAC 查到这台机器。
    /// gdm 自动登录这个用户，开机直接进桌面。
    /// GNOME 的系统默认设置（`/etc/dconf/db/local.d`）关掉锁屏与空闲挂起，用户仍可在设置里改回；
    /// 挂起的虚拟机要从宿主唤醒，而空闲黑屏不锁屏，动一下就回来。
    static func setupScript(_ o: Options) -> String {
        var lines = [
            "set -eu",
            #"seed=$1 target=$2"#,
            "printf '%s\\n' \(sh("\(o.user) ALL=(ALL) NOPASSWD:ALL")) > \"$target/etc/sudoers.d/90-macvm\"",
            #"chmod 0440 "$target/etc/sudoers.d/90-macvm""#,
            #"rm -f "$target"/etc/netplan/00-installer-config*.yaml"#,
            #"conf="$target/etc/gdm3/custom.conf""#,
            #"mkdir -p "$target/etc/gdm3""#,
            #"grep -q '^\[daemon\]' "$conf" 2>/dev/null || printf '[daemon]\n' >> "$conf""#,
            "awk -v user=\(sh(o.user)) '{ print } /^\\[daemon\\]$/ { print \"AutomaticLoginEnable=true\"; print \"AutomaticLogin=\" user }' \"$conf\" > \"$conf.new\"",
            #"mv "$conf.new" "$conf""#,
            #"mkdir -p "$target/etc/dconf/profile" "$target/etc/dconf/db/local.d""#,
            #"[ -f "$target/etc/dconf/profile/user" ] || printf 'user-db:user\nsystem-db:local\n' > "$target/etc/dconf/profile/user""#,
            #"printf '%s\n' '[org/gnome/desktop/screensaver]' 'lock-enabled=false' 'ubuntu-lock-on-suspend=false' '' '[org/gnome/settings-daemon/plugins/power]' "sleep-inactive-ac-type='nothing'" "sleep-inactive-battery-type='nothing'" > "$target/etc/dconf/db/local.d/90-macvm""#,
            #"if [ -x "$target/usr/bin/dconf" ]; then chroot "$target" dconf update; fi"#,
            #"mkdir -p "$target/etc/NetworkManager/conf.d""#,
            #"printf '[connection]\nipv4.dhcp-client-id=mac\n' > "$target/etc/NetworkManager/conf.d/90-macvm.conf""#,
        ]
        if o.agentBinary != nil {
            lines += [
                #"install -m 0755 "$seed/macvm-agent" "$target"# + AgentInstaller.linuxPath + "\"",
                #"install -m 0644 "$seed/\#(agentUnitName)" "$target/etc/systemd/system/\#(agentUnitName)""#,
                #"systemctl --root="$target" enable \#(agentUnitName)"#,
            ]
        }
        if o.agentToken != nil {
            lines.append("(\(AgentToken.linuxInstallCommand(root: #""$target""#))) < \"$seed/\(agentTokenName)\"")
        }
        var mounts = o.shares.map { share in
            (tag: share.tag, path: share.samePath ? share.hostPath : "/mnt/\(share.tag)", flags: share.readOnly ? "ro,nofail" : "rw,nofail")
        }
        if o.rosetta {
            mounts.append((tag: "rosetta", path: "/media/rosetta", flags: "ro,nofail"))
            lines += [
                #"mkdir -p "$target/etc/binfmt.d""#,
                "printf '%s\\n' \(sh(CloudInit.rosettaBinfmtRule)) > \"$target/etc/binfmt.d/rosetta.conf\"",
            ]
        }
        for m in mounts {
            lines.append("mkdir -p \"$target\"\(sh(m.path))")
            lines.append("printf '%s\\n' \(sh("\(fstab(m.tag)) \(fstab(m.path)) virtiofs \(m.flags) 0 0")) >> \"$target/etc/fstab\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 完成安装

    /// 等装好的系统里的代理响应，然后 `finishSetup`；虚拟机不停，安装盘与种子盘下次开机才卸下。
    /// 客户机重启时虚拟机可能停下而不是原地重启，这时经 `start` 开机一次；再停下就报错，安装盘仍挂着。
    public static func completeSetup(_ bundle: VMBundle, timeout: TimeInterval = 2 * 3600,
                                     isolation: isolated (any Actor)? = #isolation,
                                     start: () async throws -> Void) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var restarted = false
        // 安装环境里没有代理，代理响应就是装好的系统。探测是阻塞的 socket 往返，要离开调用方的 actor：
        // 运行器在 App 里时控制 socket 由主 actor 应答，在主 actor 上同步等就会卡死到超时。
        while !(await Task.detached { AgentClient.isReachable(bundle) }.value) {
            if BundleLock.holder(of: bundle) == nil {
                guard !restarted else { throw MacVMError.engine(String(l10n: "The virtual machine stopped unexpectedly during installation; see the log at \(bundle.logURL.path)")) }
                restarted = true
                try await start()
                continue
            }
            guard Date() < deadline else { throw MacVMError.timeout(String(l10n: "Ubuntu installation timed out")) }
            try await Task.sleep(for: .seconds(3))
        }
        try finishSetup(bundle)
    }

    /// 从配置里卸下引导 ISO 与种子盘并删掉种子盘，用户另用 `--iso` 挂的介质留着。引导 ISO 在下载缓存里，留给别的虚拟机用。
    static func finishSetup(_ bundle: VMBundle) throws {
        try bundle.updateConfig { config in
            config.installMedia.removeAll { $0.hasSuffix(".\(bootISOExtension)") }
            config.disks.removeAll { $0.path == seedFileName }
        }
        try? FileManager.default.removeItem(at: bundle.url.appending(path: seedFileName))
    }

    // MARK: - 取值

    /// autoinstall 的 identity 只认小写主机名。
    static func hostname(for name: String) -> String {
        CloudInit.hostname(for: name.lowercased(), fallback: "ubuntu")
    }

    /// 单引号包起来的 shell 字面量。
    private static func sh(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// fstab 字段里空白与反斜杠要写成八进制转义。
    private static func fstab(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: #"\134"#).replacingOccurrences(of: " ", with: #"\040"#).replacingOccurrences(of: "\t", with: #"\011"#)
    }
}
