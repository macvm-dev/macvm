import Foundation
import Security

/// 读取本进程签名里的 entitlement。
enum Entitlements {
    static let virtualization = "com.apple.security.virtualization"
    static let bridgedNetworking = "com.apple.vm.networking"
    static let usbAccessory = "com.apple.developer.accessory-access.usb"

    static func has(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        else { return false }
        return (value as? Bool) == true
    }
}
