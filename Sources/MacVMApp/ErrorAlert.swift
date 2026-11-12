import SwiftUI

extension View {
    /// 用弹窗显示 `AppModel.lastError`。挂在每个可能触发报错的窗口与 sheet 上，键盘焦点所在的那个把错误取走自己弹，
    /// 同一个错误不会在几个窗口里各弹一次；报错时没有挂了它的窗口在前面，就等下一个成为焦点时再弹。
    func reportsErrors() -> some View {
        modifier(ErrorAlert())
    }
}

private struct ErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    /// 弹窗本身会抢走宿主窗口的焦点，所以只在认领时看焦点，认领后弹窗只看这里。
    @State private var shown: ReportedError?

    func body(content: Content) -> some View {
        content
            .onChange(of: activeState == .key && model.lastError != nil, initial: true) { _, claim in
                guard claim, shown == nil else { return }
                shown = model.lastError
                model.lastError = nil
            }
            // 认领后窗口关了（如虚拟机停下时虚拟机窗口随之关闭），错误还回去，由下一个窗口或菜单栏显示。
            .onDisappear {
                if let shown, model.lastError == nil { model.lastError = shown }
            }
            .alert("The Operation Couldn't Be Completed", isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil } }),
                   presenting: shown) { _ in
                Button("OK") { shown = nil }
            } message: { error in
                Text(error.message)
            }
    }
}
