import MacVMEngine
import MacVMModel
import SwiftUI

struct SnapshotsSection: View {
    @Environment(AppModel.self) private var model
    let vmName: String
    let state: VMSummary.State
    /// 有进行中的任务（创建、安装、存模板），这时不能改磁盘。
    let busy: Bool
    @State private var snapshots: [Snapshot] = []
    @State private var newName = ""
    @State private var naming = false
    @State private var restoring: Snapshot?
    @State private var deleting: Snapshot?

    var body: some View {
        Section {
            if snapshots.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("没有快照").foregroundStyle(.secondary)
                    Text("快照保存磁盘的当前状态，之后可以随时还原。").font(.caption).foregroundStyle(.tertiary)
                }
            }
            ForEach(snapshots, id: \.name) { snap in
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.name)
                        Text("\(snap.createdAt.formatted(date: .abbreviated, time: .shortened))\(snap.includesMemory ? " · 含内存" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("还原…") { restoring = snap }
                        .controlSize(.small)
                        .disabled(locked)
                        .help(state == .running ? "运行中不能还原，先关机或挂起" : busy ? "任务进行中不能还原" : "")
                    Button { deleting = snap } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(busy)
                        .help(busy ? "任务进行中不能删除快照" : "删除快照")
                }
                .contextMenu {
                    Button("还原…") { restoring = snap }.disabled(locked)
                    Button("删除…", role: .destructive) { deleting = snap }.disabled(busy)
                }
            }
        } header: {
            HStack {
                Text("快照")
                Spacer()
                Button { newName = Self.defaultName(); naming = true } label: { Label("创建快照", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(locked)
                    .help(state == .running ? "运行中不能创建快照，先关机或挂起" : busy ? "任务进行中不能创建快照" : "")
            }
        }
        .task(id: "\(vmName)-\(state)") { reload() }
        .alert("快照名称", isPresented: $naming) {
            TextField("名称", text: $newName)
            Button("创建") {
                perform {
                    try model.requireIdle(vmName)
                    _ = try Snapshot.save($0, name: newName)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("还原到「\(restoring?.name ?? "")」？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("还原", role: .destructive) {
                if let snap = restoring {
                    perform {
                        try model.requireIdle(vmName)
                        try Snapshot.restore($0, name: snap.name)
                    }
                }
            }
        } message: {
            Text("当前未保存为快照的改动会丢失。")
        }
        .confirmationDialog("删除快照「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let snap = deleting { perform { try Snapshot.delete($0, name: snap.name) } }
            }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private var locked: Bool { state == .running || busy }

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
