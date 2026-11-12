import MacVMEngine
import MacVMModel
import SwiftUI

@main
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
