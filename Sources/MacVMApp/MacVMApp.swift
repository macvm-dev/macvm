import MacVMEngine
import MacVMModel
import SwiftUI

@main
struct MacVMApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacVM", id: "library") {
            LibraryView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 460)
        }
        .commands {
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
    }
}
