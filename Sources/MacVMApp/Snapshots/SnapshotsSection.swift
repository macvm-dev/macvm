import MacVMEngine
import MacVMModel
import SwiftUI

struct SnapshotsSection: View {
    @Environment(AppModel.self) private var model
    let vmName: String
    let state: VMSummary.State
    @State private var snapshots: [Snapshot] = []
    @State private var newName = ""
    @State private var naming = false
    @State private var restoring: Snapshot?

    var body: some View {
        Section {
            if snapshots.isEmpty {
                Text("没有快照").foregroundStyle(.secondary)
            }
            ForEach(snapshots, id: \.name) { snap in
                HStack {
                    VStack(alignment: .leading) {
                        Text(snap.name)
                        Text("\(snap.createdAt.formatted(date: .abbreviated, time: .shortened))\(snap.includesMemory ? " · 含内存" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("还原") { restoring = snap }.disabled(state == .running)
                    Button(role: .destructive) { perform { try Snapshot.delete($0, name: snap.name) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            HStack {
                Text("快照")
                Spacer()
                Button("创建快照…") { newName = Self.defaultName(); naming = true }
                    .disabled(state == .running)
                    .help(state == .running ? "先关机或挂起" : "")
            }
        }
        .task(id: "\(vmName)-\(state)") { reload() }
        .alert("快照名称", isPresented: $naming) {
            TextField("名称", text: $newName)
            Button("创建") { perform { _ = try Snapshot.save($0, name: newName) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("还原到 \(restoring?.name ?? "")？当前未保存为快照的改动会丢失。", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("还原", role: .destructive) {
                if let snap = restoring { perform { try Snapshot.restore($0, name: snap.name) } }
            }
        }
    }

    private func perform(_ action: (VMBundle) throws -> Void) {
        do { try action(model.library.bundle(named: vmName)) } catch { model.report(error) }
        reload()
        model.refresh()
    }

    private func reload() {
        snapshots = (try? model.library.bundle(named: vmName)).flatMap { try? Snapshot.list($0) } ?? []
    }

    private static func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
