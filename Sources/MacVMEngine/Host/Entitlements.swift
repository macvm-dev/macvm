import Foundation
import Security

/// 读取本进程签名里的 entitlement。
enum Entitlements {
    static let virtualization = "com.apple.security.virtualization"
    static let vmNetworking = "com.apple.vm.networking"

    static func has(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        else { return false }
        return (value as? Bool) == true
    }

    /// `url` 处可执行文件的签名里 `key` 是否为 true；读不到签名时为 false。
    static func has(_ key: String, inExecutableAt url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return (entitlements[key] as? Bool) == true
    }
}
