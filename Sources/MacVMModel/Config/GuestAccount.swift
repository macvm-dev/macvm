import Foundation

/// 新建虚拟机时在客户机里创建的登录账户。
public enum GuestAccount {
    /// 三种客户机都能接受的写法：Linux 的 adduser 不收大写，Windows 本地账户最长 20 个字符。
    /// 用户名会拼进客户机里执行的脚本，字符集同时保证不用转义。
    public static func validate(user: String) throws {
        let first = "abcdefghijklmnopqrstuvwxyz_"
        let rest = first + "0123456789.-"
        guard (1...20).contains(user.count),
              user.first.map(first.contains) == true,
              user.allSatisfy(rest.contains)
        else {
            throw MacVMError.invalidConfig(String(l10n: "User name must be 1–20 lowercase letters, digits, _ . or -, starting with a letter or _: \(user)"))
        }
        guard !reservedUsers.contains(user) else {
            throw MacVMError.invalidConfig(String(l10n: "The user name \(user) is reserved by the system; choose another"))
        }
    }

    /// 密码存进包内 `guest-password` 后读回时去掉首尾空白，所以首尾不能是空白；换行等控制字符在客户机配置里写不进去。
    public static func validate(password: String) throws {
        guard !password.isEmpty else { throw MacVMError.invalidConfig(String(l10n: "Password can't be empty")) }
        guard password.trimmingCharacters(in: .whitespaces) == password else {
            throw MacVMError.invalidConfig(String(l10n: "Password can't start or end with a space"))
        }
        guard !password.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw MacVMError.invalidConfig(String(l10n: "Password can't contain line breaks or other control characters"))
        }
    }

    /// 客户机系统自带的账户，再建同名用户会失败或接管系统账户。
    private static let reservedUsers: Set<String> = ["root", "daemon", "nobody", "admin", "administrator", "guest", "defaultaccount"]
}
