import Foundation

/// Windows 无人值守部署用到的文件：两阶段应答文件、WinPE 部署脚本、首次登录脚本。
enum WindowsUnattend {
    struct Options {
        var computerName: String
        var user: String
        var password: String
        /// 安装镜像的界面语言，如 zh-CN、en-US。
        var locale: String
        var sshPublicKey: String
        /// 安装盘上带有 `agentFileName`，首次登录时装好客户机代理。
        var installAgent = false
        /// 随代理写进客户机的 `AgentToken`。
        var agentToken: String?
        /// 安装盘上带有 `gpuDriverFolder`，首次登录时放进客户机，由代理装上。
        var installGPUDriver = false
        /// 首次登录联网后用它激活；省略时系统保持未激活。
        var productKey: String?
        /// Windows 时区名，如 China Standard Time；nil 时用 Windows 的默认时区。
        var timeZone: String? = windowsTimeZone(for: TimeZone.current.identifier)
    }

    static let agentFileName = "macvm-agent.exe"
    static let gpuDriverFolder = "viogpu3d"

    /// 安装盘（FAT32）的卷标，首次登录脚本据此找到自己所在的盘符。
    static let volumeLabel = "MACVMSETUP"
    /// 数据盘（exFAT）的卷标，盘上放 install.wim 与驱动。exFAT 卷标最多 11 个字符。
    static let dataVolumeLabel = "MACVMDATA"
    static let installScriptName = "macvm-install.cmd"
    /// 首次登录脚本完成后创建，宿主经 SSH 检测它判断安装结束。
    static let doneMarker = #"C:\macvm-setup.done"#

    /// Windows 11 专业版的通用安装密钥，只让 OOBE 不再询问密钥，不激活系统。用户自己的密钥在首次登录时换上：
    /// 它的版本未必是专业版，在部署阶段填错版本会让安装中止，首次登录时换不上只是不激活。
    private static let genericProKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"

    /// 第一阶段，由安装光盘启动的 WinPE 读取：只运行安装盘上的部署脚本。
    /// 脚本部署完即重启，安装程序不会继续，所以这里不需要磁盘、版本、TPM 等安装程序设置。
    static func autounattend() -> String {
        #"""
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>cmd /c "for %d in (C D E F G H I J K L M N O P) do @if exist %d:\macvm-install.cmd call %d:\macvm-install.cmd"</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
        </unattend>

        """#
    }

    /// 第二阶段，部署脚本把它放进系统盘的 `Windows\Panther`：specialize 与 OOBE。
    static func unattend(_ o: Options) -> String {
        let user = xml(o.user), password = xml(o.password), locale = xml(o.locale)
        let international = "<InputLocale>\(locale)</InputLocale><SystemLocale>\(locale)</SystemLocale><UILanguage>\(locale)</UILanguage><UserLocale>\(locale)</UserLocale>"
        let attributes = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS""#
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="specialize">
            <component name="Microsoft-Windows-Shell-Setup" \(attributes)>
              <ComputerName>\(xml(o.computerName))</ComputerName>
              <ProductKey>\(genericProKey)</ProductKey>\(o.timeZone.map { "\n      <TimeZone>\(xml($0))</TimeZone>" } ?? "")
            </component>
            <component name="Microsoft-Windows-Deployment" \(attributes)>
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>\(#"reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f"#)</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-International-Core" \(attributes)>
              \(international)
            </component>
            <component name="Microsoft-Windows-Shell-Setup" \(attributes)>
              <OOBE>
                <HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>
              <UserAccounts><LocalAccounts><LocalAccount wcm:action="add">
                <Name>\(user)</Name><Group>Administrators</Group><DisplayName>\(user)</DisplayName>
                <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
              </LocalAccount></LocalAccounts></UserAccounts>
              <AutoLogon><Enabled>true</Enabled><Username>\(user)</Username><LogonCount>9999999</LogonCount>
                <Password><Value>\(password)</Value><PlainText>true</PlainText></Password></AutoLogon>
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add"><Order>1</Order>
                  <CommandLine>\(#"powershell -NoProfile -ExecutionPolicy Bypass -Command "&amp; ((Get-Volume -FileSystemLabel MACVMSETUP).DriveLetter + ':\setup.ps1')""#)</CommandLine>
                </SynchronousCommand>
              </FirstLogonCommands>
            </component>
          </settings>
        </unattend>

        """
    }

    private typealias GetWindowsTimeZoneID = @convention(c) (UnsafePointer<UInt16>, Int32, UnsafeMutablePointer<UInt16>, Int32, UnsafeMutablePointer<Int32>) -> Int32
    /// ICU 的 `ucal_getWindowsTimeZoneID`。
    private static let getWindowsTimeZoneID: GetWindowsTimeZoneID? = {
        guard let icu = dlopen("/usr/lib/libicucore.dylib", RTLD_LAZY), let symbol = dlsym(icu, "ucal_getWindowsTimeZoneID") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowsTimeZoneID.self)
    }()

    /// tz 数据库时区名对应的 Windows 时区名，用系统 ICU 的映射表；没有对应时返回 nil。
    static func windowsTimeZone(for identifier: String) -> String? {
        guard let convert = getWindowsTimeZoneID else { return nil }
        let id = Array(identifier.utf16)
        var buffer = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0
        let length = convert(id, Int32(id.count), &buffer, Int32(buffer.count), &status)
        // ICU 的 UErrorCode 大于 0 才是错误，负数是警告。
        guard status <= 0, length > 0, length <= buffer.count else { return nil }
        return String(utf16CodeUnits: buffer, count: Int(length))
    }

    /// WinPE 里运行的部署脚本：找出系统盘并分区，用 DISM 从数据盘应用专业版映像，离线注入 virtio 驱动，
    /// 写引导，放好第二阶段应答文件后重启。日志写在数据盘的 macvm-install.log。
    ///
    /// 系统盘是不含安装盘、数据盘卷标的那块磁盘。cmd 按 OEM 代码页读批处理，所以全文只用 ASCII 并以 CRLF 换行；
    /// WinPE 没有 findstr，子串判断用延迟展开的变量替换。
    static func installScript() -> String {
        let script = #"""
        @echo off
        setlocal EnableDelayedExpansion
        set SETUP=%~d0
        set DATA=
        for %%d in (C D E F G H I J K L M N O P Q R S T U V Y Z) do if exist %%d:\install.wim set DATA=%%d:
        if not defined DATA goto fail
        set LOG=%DATA%\macvm-install.log
        echo macvm-install start > %LOG%
        set SYS=
        for %%n in (0 1 2 3 4) do if not defined SYS (
          echo select disk %%n> X:\dp.txt
          echo detail disk>> X:\dp.txt
          diskpart /s X:\dp.txt > X:\dp.out
          if not errorlevel 1 (
            set OURS=
            for /f "usebackq delims=" %%l in ("X:\dp.out") do (
              set "LINE=%%l"
              if not "!LINE:MACVMDATA=!"=="!LINE!" set OURS=1
              if not "!LINE:MACVMSETUP=!"=="!LINE!" set OURS=1
            )
            if not defined OURS set SYS=%%n
          )
        )
        echo system disk: %SYS% >> %LOG%
        if not defined SYS goto fail
        (
        echo select disk %SYS%
        echo clean
        echo convert gpt
        echo create partition efi size=200
        echo format quick fs=fat32 label=System
        echo assign letter=S
        echo create partition msr size=16
        echo create partition primary
        echo format quick fs=ntfs label=Windows
        echo assign letter=W
        ) > X:\part.txt
        diskpart /s X:\part.txt >> %LOG% || goto fail
        set IDX=
        for /L %%i in (1,1,16) do if not defined IDX (
          dism /English /Get-WimInfo /WimFile:%DATA%\install.wim /Index:%%i > X:\wim.out 2>nul
          for /f "usebackq delims=" %%l in ("X:\wim.out") do (
            set "LINE=%%l"
            if "!LINE!"=="Edition : Professional" set IDX=%%i
          )
        )
        if not defined IDX set IDX=1
        echo image index: %IDX% >> %LOG%
        dism /English /Apply-Image /ImageFile:%DATA%\install.wim /Index:%IDX% /ApplyDir:W:\ >> %LOG% || goto fail
        dism /English /Image:W:\ /Add-Driver /Driver:%DATA%\drivers /Recurse >> %LOG%
        bcdboot W:\Windows /s S: /f UEFI >> %LOG% || goto fail
        mkdir W:\Windows\Panther
        copy /y %SETUP%\unattend.xml W:\Windows\Panther\unattend.xml >> %LOG%
        echo macvm-install done >> %LOG%
        wpeutil reboot
        exit /b 0
        :fail
        echo macvm-install FAILED >> %LOG%
        wpeutil shutdown
        """#
        return script.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
    }

    /// 首次登录时运行：关休眠、装并启动 OpenSSH Server（只认密钥）、写入 macvm 公钥、装客户机代理，最后留下完成标记。
    /// OpenSSH Server 是按需功能，需联网下载，所以先等网络可用。用户态网络会被识别为公用网络，
    /// 而系统自带的 sshd 入站规则只对专用网络生效，因此改为对所有网络生效。
    /// PowerShell 的全局配置把控制台输出设为 UTF-8，经 SSH 取回的中文才不乱码。
    /// 虚拟机的主板时钟是 UTC，Windows 默认当本地时间读。
    static let utcClock = #"Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name RealTimeIsUniversal -Value 1 -Type DWord"#

    /// 让 sshd 只认密钥，已是这样时不改；改了要重启 sshd 生效。sshd 取选项第一次出现的值，文件末尾又是 Match 段，所以加在最前。
    static let sshKeyOnly = #"""
        $sshdConfig = 'C:\ProgramData\ssh\sshd_config'
        if ((Test-Path $sshdConfig) -and (@(Get-Content $sshdConfig)[0] -ne 'PasswordAuthentication no')) {
          Set-Content -Path $sshdConfig -Encoding ascii -Value (@('PasswordAuthentication no') + @(Get-Content $sshdConfig))
        }
        """#

    static func setupScript(_ o: Options) -> String {
        return #"""
        $ErrorActionPreference = 'Continue'
        Start-Transcript -Path C:\macvm-setup.log -Append
        for ($i = 0; $i -lt 60 -and -not (Test-NetConnection -ComputerName www.microsoft.com -Port 443 -InformationLevel Quiet); $i++) { Start-Sleep 5 }
        powercfg /hibernate off
        \#(utcClock)
        powercfg /change standby-timeout-ac 0
        powercfg /change monitor-timeout-ac 0
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
        if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name }
        Set-Service sshd -StartupType Automatic
        Start-Service sshd
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force
        $keys = 'C:\ProgramData\ssh\administrators_authorized_keys'
        Set-Content -Path $keys -Value \#(PowerShell.quote(o.sshPublicKey)) -Encoding ascii
        icacls $keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
        if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
          Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Profile Any -Enabled True
        } else {
          New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Profile Any -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        }
        Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
        Set-Content -Path $PSHOME\profile.ps1 -Encoding utf8 -Value '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $OutputEncoding = [Console]::OutputEncoding'
        \#(sshKeyOnly)
        Restart-Service sshd
        \#(o.productKey.map { "cscript //nologo $env:SystemRoot\\System32\\slmgr.vbs /ipk \($0)\ncscript //nologo $env:SystemRoot\\System32\\slmgr.vbs /ato" } ?? "")
        \#(o.installAgent ? AgentInstaller.windowsPrepareDirectory : "")
        \#(o.installGPUDriver ? "Copy-Item -Recurse -Force -LiteralPath (Join-Path $PSScriptRoot '\(gpuDriverFolder)') -Destination '\(WindowsGPUDriver.guestDirectory)'" : "")
        \#(o.installAgent ? (o.agentToken.map(AgentToken.windowsInstall) ?? "") : "")
        \#(o.installAgent ? AgentInstaller.windowsRegistration(source: "(Join-Path $PSScriptRoot '\(agentFileName)')", user: o.user) : "")
        New-Item -ItemType File -Path \#(doneMarker) -Force
        Stop-Transcript

        """#
    }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum PowerShell {
    /// 经代理 `exec` 以 Windows PowerShell 运行 `script`。标准错误接到管道时 PowerShell 把错误与进度写成 CLIXML，
    /// 所以关掉进度、把终止错误的消息原样写到标准错误并以 1 退出；控制台代码页设成 UTF-8，子进程的中文输出才不乱码。
    static func exec(_ script: String) -> AgentProtocol.ExecRequest {
        let wrapped = """
        $ProgressPreference = 'SilentlyContinue'
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        trap { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
        \(script)
        """
        return .init(argv: ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                            "-EncodedCommand", AgentInstaller.powerShellBase64(wrapped)])
    }

    /// 单引号字面量：内容原样，不展开变量与转义。
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
