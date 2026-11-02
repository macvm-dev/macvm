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

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
