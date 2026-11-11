import Combine
import Sparkle
import SwiftUI

/// 用 Sparkle 检查与安装 App 的新版本：按主 bundle 的 `SUFeedURL` 取 appcast，下载后用 `SUPublicEDKey` 核对签名，
/// 安装经 App 的正常退出流程，退出被取消时留到下次退出再装。
@MainActor
enum AppUpdater {
    /// debug 构建为 nil：它与发布版同一个 bundle ID、共用 Sparkle 的偏好，一检查就可能被发布版替换掉。
    /// 不在 App 包里运行（直接执行 swift build 的产物）时没有 `SUFeedURL` 等配置，Sparkle 起不来，也为 nil。
    static let controller: SPUStandardUpdaterController? = {
        #if DEBUG
        return nil
        #else
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }()

    static var updater: SPUUpdater? { controller?.updater }

    /// 在 App 启动完成时调用，让 Sparkle 开始按计划自动检查。
    static func start() {
        _ = controller
    }
}

/// App 菜单里的「检查更新…」。Sparkle 正在检查或安装时不可用。
struct UpdateMenu: View {
    private let model = UpdateMenuModel.shared

    var body: some View {
        Button("Check for Updates…") { AppUpdater.controller?.checkForUpdates(nil) }
            .disabled(!model.canCheck)
    }
}

@MainActor @Observable
private final class UpdateMenuModel {
    /// 菜单随 App 的 body 反复重建，订阅只建一份。
    static let shared = UpdateMenuModel()

    var canCheck = false
    @ObservationIgnored private var subscription: AnyCancellable?

    private init() {
        subscription = AppUpdater.updater?.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }
}

/// 设置里「自动检查更新」的开关，存在 Sparkle 自己的偏好项里。
struct AutomaticUpdateToggle: View {
    @State private var enabled = AppUpdater.updater?.automaticallyChecksForUpdates ?? false

    var body: some View {
        Toggle("Check for Updates Automatically", isOn: $enabled)
            .disabled(AppUpdater.updater == nil)
            .onChange(of: enabled) { AppUpdater.updater?.automaticallyChecksForUpdates = enabled }
    }
}
