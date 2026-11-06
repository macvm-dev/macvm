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
                    Text("No Snapshots").foregroundStyle(.secondary)
                    Text("A snapshot saves the disk's current state so you can go back to it at any time.").font(.caption).foregroundStyle(.tertiary)
                }
            }
            ForEach(snapshots, id: \.name) { snap in
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.name)
                        Text("\(snap.createdAt.formatted(date: .abbreviated, time: .shortened))\(snap.includesMemory ? String(l10n: " · Includes memory") : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { restoring = snap }
                        .controlSize(.small)
                        .disabled(locked)
                        .help(state == .running ? "Shut down or suspend the virtual machine to restore a snapshot" : busy ? "Can't restore snapshots while a task is in progress" : "")
                    Button { deleting = snap } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(busy)
                        .help(busy ? "Can't delete snapshots while a task is in progress" : "Delete Snapshot")
                }
                .contextMenu {
                    Button("Restore…") { restoring = snap }.disabled(locked)
                    Button("Delete…", role: .destructive) { deleting = snap }.disabled(busy)
                }
            }
        } header: {
            HStack {
                Text("Snapshots")
                Spacer()
                Button { newName = Self.defaultName(); naming = true } label: { Label("Take Snapshot", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(locked)
                    .help(state == .running ? "Shut down or suspend the virtual machine to take a snapshot" : busy ? "Can't take snapshots while a task is in progress" : "")
            }
        }
        .task(id: "\(vmName)-\(state)") { reload() }
        .alert("Snapshot Name", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                perform {
                    try model.requireIdle(vmName)
                    _ = try Snapshot.save($0, name: newName)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Restore Snapshot “\(restoring?.name ?? "")”?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Restore", role: .destructive) {
                if let snap = restoring {
                    perform {
                        try model.requireIdle(vmName)
                        try Snapshot.restore($0, name: snap.name)
                    }
                }
            }
        } message: {
            Text("Any changes that aren't saved in a snapshot will be lost.")
        }
        .confirmationDialog("Delete Snapshot “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let snap = deleting { perform { try Snapshot.delete($0, name: snap.name) } }
            }
        } message: {
            Text("This can't be undone.")
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
