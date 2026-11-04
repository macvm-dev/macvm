import SwiftUI

/// 可直接输入、也可用步进器调整的整数。输入超出 `range` 或不是数字时不改 `value`，字标红并置 `invalid`；
/// 离开输入框或回车后文字回到当前 `value`。
struct NumberField: View {
    let title: String
    let unit: String
    @Binding var value: Int
    @Binding var invalid: Bool
    let range: ClosedRange<Int>
    var step = 1

    @State private var text: String
    @FocusState private var focused: Bool

    init(title: String, unit: String, value: Binding<Int>, invalid: Binding<Bool>, range: ClosedRange<Int>, step: Int = 1) {
        self.title = title
        self.unit = unit
        _value = value
        _invalid = invalid
        self.range = range
        self.step = step
        _text = State(initialValue: String(value.wrappedValue))
    }

    private var valid: Bool { Int(text).map(range.contains) ?? false }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .foregroundStyle(valid ? Color.primary : Color.red)
                    .focused($focused)
                    .onSubmit { text = String(value) }
                Text(unit).foregroundStyle(.secondary)
                Stepper(title, value: $value, in: range, step: step).labelsHidden()
            }
        }
        .help("\(range.lowerBound)–\(range.upperBound)")
        .onChange(of: text) { _, new in
            if let number = Int(new), range.contains(number), number != value { value = number }
        }
        .onChange(of: value) { _, new in
            if Int(text) != new { text = String(new) }
        }
        .onChange(of: valid, initial: true) { _, valid in invalid = !valid }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { text = String(value) }
        }
    }
}
