import AppKit
import MacVMEngine
import MacVMModel
import SwiftUI

/// 菜单栏图标下的菜单：逐台虚拟机的开关机，以及打开主窗口。
struct StatusMenu: View {
    /// `AppStorage` 键：是否在菜单栏显示图标。
    static let visibleKey = "showsMenuBarExtra"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.machines.isEmpty, model.pendingCreations.isEmpty, model.interruptedCreations.isEmpty {
            Text("没有虚拟机")
        }
        ForEach(model.pendingCreations, id: \.self) { name in
            Menu("\(name)：\(model.activity[name]?.text ?? "")") {
                Button("在 MacVM 中查看") {
                    model.selection = name
                    showLibrary()
                }
                Button("取消创建") { model.cancelCreation(name) }
            }
        }
        ForEach(model.machines, id: \.name) { vm in
            Menu {
                actions(vm)
            } label: {
                Label("\(vm.name)（\(model.activity[vm.name]?.text ?? vm.state.label)）", systemImage: vm.os.symbol)
            }
        }
        ForEach(model.interruptedCreations, id: \.name) { request in
            Menu("\(request.name)：创建被中断") {
                Button("继续创建") {
                    NSApp.activate()
                    model.resumeCreation(request.name) { openWindow(id: "machine", value: $0) }
                }
                Button("放弃") { model.discardCreation(request.name) }
            }
        }
        Divider()
        Button("新建虚拟机…") {
            showLibrary()
            model.showingCreate = true
        }
        Button("打开 MacVM") { showLibrary() }
        Divider()
        Button("退出 MacVM") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private func actions(_ vm: VMSummary) -> some View {
        switch vm.state {
        case .stopped, .suspended:
            Button(vm.state == .suspended ? "继续" : "启动") { show(vm.name) }
                .disabled(model.activity[vm.name] != nil)
        case .running:
            if model.canDisplay(vm.name) {
                Button("显示") { show(vm.name) }
            }
            if model.config(of: vm.name)?.supportsSuspend == true {
                Button("挂起") { Task { await model.suspend(vm.name) } }
            }
            Button("关机") { Task { await model.stop(vm.name) } }
            Button("强制断电") { Task { await model.stop(vm.name, force: true) } }
        }
        Divider()
        if model.isCreating(vm.name) {
            Button("取消创建") { model.cancelCreation(vm.name) }
        }
        Button("在 MacVM 中查看") {
            model.selection = vm.name
            showLibrary()
        }
    }

    /// 菜单栏的菜单不会激活 App，新开的窗口会落在别的 App 后面。
    private func show(_ name: String) {
        NSApp.activate()
        openWindow(id: "machine", value: name)
    }

    private func showLibrary() {
        NSApp.activate()
        openWindow(id: "library")
    }
}
