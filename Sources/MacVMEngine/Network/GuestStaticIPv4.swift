import Foundation
public import MacVMModel

/// 按第一块网卡的 `NetworkConfig.staticIPv4` 设定客户机里的 IPv4，经代理 `exec` 执行，可重复执行。
/// 客户机里的网卡按 MAC 地址认；改回 DHCP 时只撤销带 MacVM 标记的配置（Linux 上是 `linuxNetworkdFile` 与
/// NetworkManager 连接 `linuxConnection`，macOS 上是 `macOSMarker` 记下的网络服务）。配置要求静态地址时，
/// 客户机里手改过的地址、网关与 DNS 会被改回配置里的值。
public enum GuestStaticIPv4 {
    /// 在运行中的 `bundle` 里按 `config` 设好，并让 `VMConfig.guestStaticIPv4` 跟上：设静态地址时在写之前就记下，改回 DHCP 成功后清掉。
    /// 设好后包里的配置已要求别的值时（另一次写入在本次读配置之后改了它），按包里的值再设，最多 `applyRounds` 轮，
    /// 免得读到旧配置的一方最后写进客户机。
    /// 没装代理、代理没上线、Windows 客户机、要改动而 macOS 客户机没有保存的密码，或客户机里的命令失败时抛错。
    /// 阻塞的 socket 往返，不要在主线程上调用。
    public static func apply(_ bundle: VMBundle, config: VMConfig) throws {
        var config = config
        for _ in 0..<applyRounds {
            let applied = try applyOnce(bundle, config: config)
            var previous: StaticIPv4?
            let latest = try bundle.updateConfig { config in
                previous = config.guestStaticIPv4
                config.guestStaticIPv4 = applied
            }
            // 改回 DHCP 后新地址要等 `BridgedAddress.watch` 取到。
            if let applied {
                BridgedAddress.store(applied.address, for: bundle)
            } else if previous != nil {
                BridgedAddress.clear(bundle)
            }
            guard latest.guestAgent, desired(in: latest) != applied else { return }
            config = latest
        }
    }

    private static let applyRounds = 3

    private static func desired(in config: VMConfig) -> StaticIPv4? {
        let net = config.networks.first
        return net?.mode == .bridged ? net?.staticIPv4 : nil
    }

    /// 返回写进客户机的值。
    private static func applyOnce(_ bundle: VMBundle, config: VMConfig) throws -> StaticIPv4? {
        guard config.guestAgent else {
            throw MacVMError.unsupported(String(l10n: "The guest agent isn't installed in \(config.name); install it to set a static IP address"))
        }
        let desired = desired(in: config)
        try desired?.validate()
        // 没有 MAC 就认不出客户机里的网卡；不要求静态地址时也就没什么可做。
        guard let mac = config.networks.first?.macAddress else {
            if desired == nil { return nil }
            throw MacVMError.invalidConfig(String(l10n: "\(config.name)'s network adapter has no MAC address"))
        }
        let (request, input) = try command(desired, mac: mac, os: config.os, bundle: bundle)
        // 脚本中途失败也可能已在客户机里留下静态配置：先记下，`applyAfterBoot` 与撤销才找得到它。
        if let desired {
            try bundle.updateConfig { $0.guestStaticIPv4 = desired }
        }
        let (code, output) = try AgentClient.run(bundle, request: request, input: input, timeout: commandTimeout)
        guard code == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = code.map { String(l10n: "exit code \($0)") } ?? String(l10n: "the guest agent disconnected")
            throw MacVMError.engine(String(l10n: "Couldn't set the IP address in \(config.name) (\(status))") + (detail.isEmpty ? "" : String(l10n: ": \(detail)")))
        }
        return desired
    }

    /// macOS 客户机里改网络设置要 sudo：`value` 非 nil 而 `bundle` 里没有保存的客户机密码时抛 `MacVMError.unsupported`。
    /// 入口在保存 `NetworkConfig.staticIPv4` 前调用；改回 DHCP 不检查。
    public static func requirePassword(_ bundle: VMBundle, os: GuestOS, for value: StaticIPv4?) throws {
        guard value != nil, os == .macOS, GuestCredentials.password(for: bundle)?.isEmpty ?? true else { return }
        throw MacVMError.unsupported(String(l10n: "No guest password is saved for \(bundle.name); setting a static IP address on macOS needs the login password. Save it in \(GuestCredentials.passwordURL(bundle).path)"))
    }

    /// 开机后经 `AgentClient.afterOnline` 执行 `apply`，每次都重读配置。只在配置要求静态地址、或 `VMConfig.guestStaticIPv4`
    /// 记着客户机里有静态地址时执行，其余情况（含没装代理、Windows 客户机）返回 nil。
    static func applyAfterBoot(_ bundle: VMBundle, config: VMConfig) -> Task<Void, Never>? {
        guard config.guestAgent, config.os != .windows,
              desired(in: config) != nil || config.guestStaticIPv4 != nil else { return nil }
        return AgentClient.afterOnline(bundle) { try apply(bundle, config: bundle.loadConfig()) }
    }

    /// 包含脚本里等网络服务就绪与等锁的时间。
    private static let commandTimeout = 300

    static let linuxNetworkdFile = "/etc/systemd/network/05-macvm-static.network"
    static let linuxConnection = "macvm-static"
    /// 系统 DNS 不由 systemd-resolved 管时，写 `/etc/resolv.conf` 前把原文件（可能是符号链接）挪到这里，改回 DHCP 时挪回。
    static let linuxStateDirectory = "/var/lib/macvm"
    /// root 所有、所有人可读，三行：网络服务名、设上的地址、网卡的 BSD 名。
    static let macOSMarker = "/Library/Application Support/MacVM/static-ipv4"
    /// 在 `lockf` 下执行 `$0` 里的脚本、参数照传，让 macOS 上的各次执行依次进行；持锁的进程退出时锁随之释放。
    /// 锁文件放在登录用户自己的临时目录，客户机里别的用户占不住它。
    static let macOSLocked = #"""
        dir=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || dir=
        [ -n "$dir" ] || dir=${TMPDIR:-/tmp}/
        exec /usr/bin/lockf -k -t 120 "${dir}macvm-static-ipv4.lock" /bin/sh -c "$0" sh "$@"
        """#

    /// `desired` 为 nil 时改回 DHCP。参数按位置传给脚本，不拼进脚本：第一个是小写的 MAC，改回 DHCP 时只有它；
    /// 设静态地址时 Linux 依次是 CIDR、网关、各 DNS，macOS 依次是地址、子网掩码、网关、各 DNS。
    /// macOS 的标准输入第一行是保存的客户机密码，没有时为空行，脚本只在真要改动时才用它 sudo。
    static func command(_ desired: StaticIPv4?, mac: String, os: GuestOS, bundle: VMBundle) throws -> (AgentProtocol.ExecRequest, Data) {
        let mac = mac.lowercased()
        switch os {
        case .linux:
            let args = desired.map { [$0.cidr, $0.gateway] + $0.dnsServers } ?? []
            return (.init(argv: ["/bin/sh", "-c", linuxScript(), "sh", mac] + args, user: "root"), Data())
        case .macOS:
            let args = desired.map { [$0.address, $0.subnetMask, $0.gateway] + $0.dnsServers } ?? []
            let password = GuestCredentials.password(for: bundle) ?? ""
            return (.init(argv: ["/bin/sh", "-c", macOSLocked, macOSScript(), mac] + args), Data((password + "\n").utf8))
        case .windows:
            throw MacVMError.unsupported(String(l10n: "Static IP addresses aren't supported for Windows guests"))
        }
    }

    /// 以 root 运行。NetworkManager 管着网卡时用连接 `linuxConnection`（自动连接优先级高于其他连接），
    /// 否则由 systemd-networkd 用 `linuxNetworkdFile`：networkd 按文件名排序取第一个匹配的，
    /// `05-` 排在 netplan 生成的 `10-netplan-*.network` 前面。现值与要设的一致时不动网卡，免得白断一次。
    static func linuxScript() -> String {
        #"""
        set -u
        umask 022
        mac=$1
        shift
        file='\#(linuxNetworkdFile)'
        con='\#(linuxConnection)'
        resolv_orig='\#(linuxStateDirectory)/resolv.conf.orig'
        resolv_none='\#(linuxStateDirectory)/resolv.conf.none'

        dev=
        for path in /sys/class/net/*/address; do
          [ -e "${path%/address}/device" ] || continue
          if [ "$(cat "$path" 2>/dev/null)" = "$mac" ]; then
            dev=${path%/address}
            dev=${dev##*/}
            break
          fi
        done

        nm_running() { systemctl is-active --quiet NetworkManager && command -v nmcli >/dev/null 2>&1; }
        has_con() { nmcli -g NAME connection show 2>/dev/null | grep -qx "$con"; }
        nm_get() { nmcli -g "$1" connection show "$con" 2>/dev/null; }

        # The agent can start before the network services finish starting at boot; wait only while a start is pending,
        # so a stopped or skipped unit costs nothing.
        wait_unit() {
          i=0
          while [ "$i" -lt 60 ]; do
            [ "$(systemctl is-active "$1" 2>/dev/null)" = activating ] ||
              [ -n "$(systemctl show -p Job --value "$1" 2>/dev/null)" ] || return 0
            i=$((i + 1))
            sleep 1
          done
        }
        wait_unit NetworkManager
        wait_unit systemd-networkd
        if nm_running && command -v nm-online >/dev/null 2>&1; then
          nm-online -s -q -t 60 || true
        fi

        # Taken after the waits above so a boot-time run stuck waiting doesn't hold off a change made meanwhile.
        if command -v flock >/dev/null 2>&1; then
          exec 9>/run/macvm-static-ipv4.lock
          if ! flock -w 60 9; then
            echo "another static IP change is still running" >&2
            exit 1
          fi
        fi

        restore_resolv() {
          if [ -e "$resolv_orig" ] || [ -L "$resolv_orig" ]; then
            mv -f "$resolv_orig" /etc/resolv.conf
          elif [ -e "$resolv_none" ]; then
            rm -f /etc/resolv.conf "$resolv_none"
          fi
        }

        # Back up the original only once: while a backup exists, /etc/resolv.conf is ours.
        write_resolv() {
          content=$(printf 'nameserver %s\n' "$@")
          if [ ! -e "$resolv_orig" ] && [ ! -L "$resolv_orig" ] && [ ! -e "$resolv_none" ]; then
            mkdir -p "${resolv_orig%/*}" || return 1
            if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
              mv -f /etc/resolv.conf "$resolv_orig" || return 1
            else
              : > "$resolv_none" || return 1
            fi
          fi
          if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] && [ "$(cat /etc/resolv.conf)" = "$content" ]; then
            return 0
          fi
          printf '%s\n' "$content" > /etc/resolv.conf.macvm && mv -f /etc/resolv.conf.macvm /etc/resolv.conf
        }

        drop_networkd() {
          [ -e "$file" ] || return 0
          rm -f "$file"
          if systemctl is-active --quiet systemd-networkd; then
            networkctl reload || true
            [ -z "$dev" ] || networkctl reconfigure "$dev" || true
          fi
        }

        if [ $# -eq 0 ]; then
          drop_networkd
          if nm_running; then
            if has_con; then
              nmcli connection delete "$con" >/dev/null || exit 1
              [ -z "$dev" ] || nmcli device connect "$dev" >/dev/null 2>&1 || true
            fi
          elif grep -qsx "id=$con" /etc/NetworkManager/system-connections/*; then
            echo "NetworkManager isn't running, so the $con connection can't be removed" >&2
            exit 1
          fi
          restore_resolv
          exit 0
        fi

        cidr=$1
        gw=$2
        shift 2
        if [ -z "$dev" ]; then
          echo "no network interface has MAC address $mac" >&2
          exit 1
        fi

        nm_manages() {
          nm_running || return 1
          case $(nmcli -g GENERAL.STATE device show "$dev" 2>/dev/null) in
            *unmanaged*) return 1 ;;
          esac
        }

        if nm_manages; then
          drop_networkd
          restore_resolv
          dns=$(printf '%s,' "$@")
          dns=${dns%,}
          if has_con && [ "$(nm_get ipv4.method)" = manual ] && [ "$(nm_get ipv4.addresses)" = "$cidr" ] &&
             [ "$(nm_get ipv4.gateway)" = "$gw" ] && [ "$(nm_get ipv4.dns)" = "$dns" ] &&
             [ "$(nm_get GENERAL.STATE)" = activated ] && [ "$(nm_get GENERAL.DEVICES)" = "$dev" ]; then
            exit 0
          fi
          nm_set() {
            nmcli connection "$@" 802-3-ethernet.mac-address "$mac" ipv4.method manual ipv4.addresses "$cidr" \
              ipv4.gateway "$gw" ipv4.dns "$dns" ipv4.ignore-auto-dns yes \
              connection.autoconnect yes connection.autoconnect-priority 100 >/dev/null
          }
          if has_con; then
            nm_set modify "$con" connection.interface-name "$dev" || exit 1
          else
            nm_set add type ethernet con-name "$con" ifname "$dev" || exit 1
          fi
          nmcli connection up "$con" >/dev/null || exit 1
          exit 0
        fi

        if systemctl is-active --quiet systemd-networkd; then
          content=$(
            printf '[Match]\nMACAddress=%s\nType=ether\n\n[Network]\nAddress=%s\nGateway=%s\n' "$mac" "$cidr" "$gw"
            printf 'DNS=%s\n' "$@"
          )
          reload=0
          if [ ! -f "$file" ] || [ "$(cat "$file")" != "$content" ]; then
            mkdir -p "${file%/*}" || exit 1
            printf '%s\n' "$content" > "$file.tmp" && mv -f "$file.tmp" "$file" || exit 1
            reload=1
          elif ! ip -4 -o addr show dev "$dev" 2>/dev/null | grep -qF " $cidr "; then
            reload=1
          fi
          if [ "$reload" = 1 ]; then
            networkctl reload && networkctl reconfigure "$dev" || exit 1
          fi
          if systemctl is-active --quiet systemd-resolved; then
            restore_resolv
          else
            write_resolv "$@" || exit 1
          fi
          exit 0
        fi

        echo "neither NetworkManager nor systemd-networkd manages $dev" >&2
        exit 1
        """#
    }

    /// 以登录用户运行，只读设置时不用 sudo。改回 DHCP 时按 `macOSMarker` 找服务（克隆会换 MAC）：先认记下的服务名，
    /// 服务改过名就认记下的网卡上的服务；仅当它仍是手动配置、地址等于记下的地址时才改回 DHCP 并清掉 DNS，标记总会删掉。
    /// 设到另一个服务上时，标记指向的旧服务若仍是 MacVM 设的地址，一并改回 DHCP。
    static func macOSScript() -> String {
        #"""
        IFS= read -r password || password=
        mac=$1
        shift
        marker='\#(macOSMarker)'

        as_root() {
          if [ -z "$password" ]; then
            echo "no guest password is saved, and changing network settings needs sudo" >&2
            exit 1
          fi
          printf '%s\n' "$password" | /usr/bin/sudo -S -p '' /bin/sh -c "$@"
        }

        # Prepended to the scripts run as root: networksetup often exits 0 even when it fails.
        ns_def='ns() {
          out=$(/usr/sbin/networksetup "$@" 2>&1)
          status=$?
          [ -z "$out" ] || printf "%s\n" "$out"
          case $out in *"** Error"*) return 1 ;; esac
          return $status
        }
        '

        field() { printf '%s\n' "$info" | sed -n "s/^$1: //p" | head -n 1; }

        svc_of_dev() {
          /usr/sbin/networksetup -listnetworkserviceorder | awk -v dev="$1" '
            /^\([0-9*]+\) / { name = $0; sub(/^\([0-9*]+\) /, "", name); next }
            index($0, "Device: " dev ")") { print name; exit }'
        }
        svc_exists() { /usr/sbin/networksetup -listallnetworkservices | sed 's/^\*//' | grep -qxF -- "$1"; }
        # The service the marker points at: its recorded name, or, if that service was renamed, the one on its device.
        marked_svc() {
          if [ -n "$marked_name" ] && svc_exists "$marked_name"; then
            printf '%s\n' "$marked_name"
          elif [ -n "$marked_dev" ]; then
            svc_of_dev "$marked_dev"
          fi
        }
        # Still the manual address MacVM set, not one changed in the guest since.
        still_ours() {
          info=$(/usr/sbin/networksetup -getinfo "$1" 2>/dev/null)
          [ "$(printf '%s\n' "$info" | head -n 1)" = "Manual Configuration" ] && [ "$(field 'IP address')" = "$marked_addr" ]
        }
        marked_name= marked_addr= marked_dev=
        if [ -f "$marker" ]; then
          marked_name=$(sed -n 1p "$marker")
          marked_addr=$(sed -n 2p "$marker")
          marked_dev=$(sed -n 3p "$marker")
        fi

        if [ $# -eq 0 ]; then
          [ -f "$marker" ] || exit 0
          svc=$(marked_svc)
          reset=0
          if [ -n "$svc" ] && still_ours "$svc"; then reset=1; fi
          as_root "$ns_def"'
            if [ "$1" = 1 ]; then
              ns -setdhcp "$2" && ns -setdnsservers "$2" Empty || exit 1
            fi
            rm -f "$3"
          ' sh "$reset" "$svc" "$marker"
          exit
        fi

        addr=$1
        mask=$2
        gw=$3
        shift 3
        dev=$(/sbin/ifconfig -a | awk -v mac="$mac" '
          function norm(m,    n, i, p, out) {
            n = split(tolower(m), p, ":")
            out = ""
            for (i = 1; i <= n; i++) out = out (i > 1 ? ":" : "") (length(p[i]) < 2 ? "0" p[i] : p[i])
            return out
          }
          /^[^ \t]/ { iface = $1; sub(/:$/, "", iface) }
          $1 == "ether" && norm($2) == mac { print iface; exit }')
        if [ -z "$dev" ]; then
          echo "no network interface has MAC address $mac" >&2
          exit 1
        fi
        svc=$(svc_of_dev "$dev")
        if [ -z "$svc" ]; then
          echo "no network service uses $dev" >&2
          exit 1
        fi

        # A service the marker points at other than this one still has MacVM's address: switch it back too.
        stale=
        if [ -f "$marker" ]; then
          old=$(marked_svc)
          if [ -n "$old" ] && [ "$old" != "$svc" ] && still_ours "$old"; then stale=$old; fi
        fi

        info=$(/usr/sbin/networksetup -getinfo "$svc")
        if [ -z "$stale" ] && [ "$marked_name" = "$svc" ] && [ "$marked_addr" = "$addr" ] && [ "$marked_dev" = "$dev" ] &&
           [ "$(printf '%s\n' "$info" | head -n 1)" = "Manual Configuration" ] &&
           [ "$(field 'IP address')" = "$addr" ] && [ "$(field 'Subnet mask')" = "$mask" ] && [ "$(field Router)" = "$gw" ] &&
           [ "$(/usr/sbin/networksetup -getdnsservers "$svc")" = "$(printf '%s\n' "$@")" ]; then
          exit 0
        fi
        # The stale service goes back first, while the marker still points at it; then the marker, so that if a later step
        # fails, the next run still finds and finishes or undoes it.
        as_root "$ns_def"'
          svc=$1 addr=$2 mask=$3 gw=$4 dev=$5 stale=$6 marker=$7
          shift 7
          if [ -n "$stale" ]; then
            ns -setdhcp "$stale" && ns -setdnsservers "$stale" Empty || exit 1
          fi
          mkdir -p "${marker%/*}" || exit 1
          printf "%s\n%s\n%s\n" "$svc" "$addr" "$dev" > "$marker" && chmod 644 "$marker" || exit 1
          ns -setmanual "$svc" "$addr" "$mask" "$gw" || exit 1
          ns -setdnsservers "$svc" "$@"
        ' sh "$svc" "$addr" "$mask" "$gw" "$dev" "$stale" "$marker" "$@"
        """#
    }
}
