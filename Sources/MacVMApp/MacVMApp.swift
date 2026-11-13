import MacVMEngine
import MacVMModel
import SwiftUI

/// 程序入口。带 `DetachedRun.appRunTarget` 认得的参数时是桥接虚拟机的后台进程：不起界面、不占单实例，运行到虚拟机停止就退出；
/// 出错或虚拟机异常停止时把消息写标准错误（即 `VMBundle.logURL`），以 `MacVMError.exitCode` 退出。
@main
@MainActor
enum AppMain {
    static func main() {
        guard let name = DetachedRun.appRunTarget(CommandLine.arguments) else {
            MacVMApp.main()
            return
        }
        Task { @MainActor in
            do {
                let reason = try await DetachedRun.serve(VMLibrary.default.bundle(named: name))
                if case .error(let message) = reason { fail(.engine(String(l10n: "The VM stopped unexpectedly: \(message)"))) }
                exit(0)
            } catch let error as MacVMError {
                fail(error)
            } catch {
                fail(.engine(error.localizedDescription))
            }
        }
        // VZ 与 `SignalHandler` 都靠主队列，主线程要一直跑 RunLoop。
        CFRunLoopRun()
    }

    private static func fail(_ error: MacVMError) -> Never {
        FileHandle.standardError.write(Data("MacVM: \(error.message)\n".utf8))
        exit(error.exitCode)
    }
}

struct MacVMApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }
    @AppStorage(StatusMenu.visibleKey) private var showsMenuBarExtra = true

    init() { AppInstance.claim() }

    var body: some Scene {
        // 单实例：菜单栏里「打开 MacVM」用 openWindow 把已有的主窗口提到前面，而不是再开一个。
        Window("MacVM", id: "library") {
            LibraryView()
                .environment(model)
                .frame(minHeight: 460)
        }
        // 详情页一屏放下头部与硬件，常用的设置不用滚动就能看到。
        .defaultSize(width: 840, height: 580)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) { UpdateMenu() }
            CommandGroup(after: .appSettings) { SkillMenu() }
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") { model.showingCreate = true }
                    .keyboardShortcut("n")
            }
        }

        WindowGroup("Virtual Machine", id: "machine", for: String.self) { $name in
            if let name {
                MachineWindow(name: name)
                    .environment(model)
                    // 全屏时画面占满屏幕，工具栏只在指针移到屏幕顶端时滑出。
                    .windowToolbarFullScreenVisibility(.onHover)
            }
        }
        .windowResizability(.contentMinSize)
        // 客户机分辨率跟随窗口（QEMU 引擎），默认给一个常用的桌面尺寸。
        .defaultSize(width: 1280, height: 800)
        // 打开窗口即启动虚拟机，恢复上次的窗口会把它们全部开机。
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .reportsErrors()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            StatusMenu()
                .environment(model)
        } label: {
            Image(nsImage: menuBarIcon.image)
                .renderingMode(.template)
                .accessibilityLabel(menuBarIcon.label)
                .help(menuBarIcon.label)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: MenuBarIcon {
        if model.isDownloading { return .downloading }
        return model.creatingNames.isEmpty ? .idle : .working
    }
}
