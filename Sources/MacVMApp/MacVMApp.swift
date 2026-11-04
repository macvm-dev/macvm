import MacVMEngine
import MacVMModel
import SwiftUI

@main
struct MacVMApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }
    @AppStorage(StatusMenu.visibleKey) private var showsMenuBarExtra = true

    var body: some Scene {
        // 单实例：菜单栏里「打开 MacVM」用 openWindow 把已有的主窗口提到前面，而不是再开一个。
        Window("MacVM", id: "library") {
            LibraryView()
                .environment(model)
                .frame(minHeight: 460)
        }
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("新建虚拟机…") { model.showingCreate = true }
                    .keyboardShortcut("n")
            }
        }

        WindowGroup("虚拟机", id: "machine", for: String.self) { $name in
            if let name {
                MachineWindow(name: name)
                    .environment(model)
            }
        }
        .windowResizability(.contentMinSize)
        // 客户机分辨率跟随窗口（QEMU 引擎），默认给一个常用的桌面尺寸。
        .defaultSize(width: 1280, height: 800)
        // 打开窗口即启动虚拟机，恢复上次的窗口会把它们全部开机。
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
        }

        // 有虚拟机在创建、下载或安装时换个图标，菜单没打开也能看出来。
        MenuBarExtra("MacVM", systemImage: model.activity.isEmpty ? "desktopcomputer" : "desktopcomputer.and.arrow.down",
                     isInserted: $showsMenuBarExtra) {
            StatusMenu()
                .environment(model)
        }
    }
}
