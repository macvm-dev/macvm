import Foundation

/// `DisplayConfig.retina` 改动后通知已打开的画面立即按新设置请求分辨率。
public enum DisplayPreference {
    static let changed = Notification.Name("MacVMDisplayPreferenceChanged")

    public static func didChange(for name: String) {
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["name": name])
    }

    /// 在主线程上收到 `name` 这台虚拟机的设置改动时调用 `handler`；返回的观察者由调用方移除。
    static func observe(_ name: String, _ handler: @escaping @MainActor () -> Void) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: changed, object: nil, queue: .main) { note in
            guard note.userInfo?["name"] as? String == name else { return }
            MainActor.assumeIsolated { handler() }
        }
    }
}
