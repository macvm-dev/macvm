import MacVMModel
import SwiftUI

/// 宿主端口到客户机端口的转发，运行中也可增删。
struct ForwardsSection: View {
    @Environment(AppModel.self) private var model
    let vmName: String
    let config: VMConfig
    @State private var adding = false

    var body: some View {
        Section {
            if config.forwards.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Port Forwards").foregroundStyle(.secondary)
                    Text("Forward a port on your Mac to a port in the guest, so apps can connect to services in the guest through localhost.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            ForEach(config.forwards, id: \.self) { forward in
                row(forward)
            }
        } header: {
            HStack {
                Text("Port Forwarding")
                Spacer()
                Button { adding = true } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        } footer: {
            if !config.forwards.isEmpty {
                Text("Changes take effect right away, even while running. Forwards are active while the virtual machine is running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $adding) {
            AddForwardSheet(taken: config.forwards) { model.addForward(vmName, $0) }
        }
    }

    private func row(_ forward: PortForward) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.arrow.left").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(forward.address):\(forward.hostPort) → \(forward.guestPort)").font(.body.monospaced())
                Text(forward.address == PortForward.defaultAddress ? "This Mac only" : forward.address == PortForward.anyAddress ? "Other devices on the network can connect" : "Listening on \(forward.address)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.removeForward(vmName, forward) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove Port Forward")
        }
    }
}

private struct AddForwardSheet: View {
    @Environment(\.dismiss) private var dismiss
    let taken: [PortForward]
    let add: (PortForward) -> Void
    @State private var hostPort: Int?
    @State private var guestPort: Int?
    @State private var shared = false

    private var forward: PortForward? {
        guard let hostPort, let guestPort, let host = UInt16(exactly: hostPort), let guest = UInt16(exactly: guestPort), host > 0, guest > 0 else { return nil }
        return PortForward(address: shared ? PortForward.anyAddress : PortForward.defaultAddress, hostPort: host, guestPort: guest)
    }

    private var conflict: PortForward? {
        forward.flatMap { new in taken.first { $0.conflicts(with: new) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Port Forward").font(.headline)
            Form {
                TextField("Mac Port", value: $hostPort, format: .number.grouping(.never), prompt: Text(verbatim: "8080"))
                TextField("Guest Port", value: $guestPort, format: .number.grouping(.never), prompt: Text(verbatim: "80"))
                Toggle("Allow other devices on the network to connect", isOn: $shared)
            }
            .formStyle(.columns)
            if let conflict {
                Text("Mac port \(String(conflict.hostPort)) is already forwarded.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let forward { add(forward) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(forward == nil || conflict != nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
