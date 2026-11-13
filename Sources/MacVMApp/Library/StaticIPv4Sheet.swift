import MacVMModel
import SwiftUI

/// 桥接网卡在客户机里的 IPv4：DHCP 或手动填写的静态地址。
struct StaticIPv4Sheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vmName: String
    let os: GuestOS
    @State private var manual: Bool
    @State private var cidr: String
    @State private var gateway: String
    /// 逗号分隔；为空时用网关。
    @State private var dns: String
    @State private var error: String?

    init(vmName: String, os: GuestOS, current: StaticIPv4?) {
        self.vmName = vmName
        self.os = os
        _manual = State(initialValue: current != nil)
        _cidr = State(initialValue: current?.cidr ?? "")
        _gateway = State(initialValue: current?.gateway ?? "")
        _dns = State(initialValue: current?.dns.joined(separator: ", ") ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Configure IPv4", selection: $manual) {
                    Text("DHCP").tag(false)
                    Text("Manual").tag(true)
                }
                if manual {
                    TextField("Address", text: $cidr, prompt: Text(verbatim: "192.168.1.10/24"))
                    TextField("Gateway", text: $gateway, prompt: Text(verbatim: "192.168.1.1"))
                    TextField("DNS Servers", text: $dns, prompt: Text("Optional, uses the gateway if empty"))
                }
                Section {
                    if manual {
                        Text("Enter the address with its prefix length. Separate up to \(StaticIPv4.maxDNSServers) DNS servers with commas. Pick an address outside the router's DHCP range so it doesn't clash with other devices.")
                    }
                    Text(guestHint)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(manual && (cidr.isEmpty || gateway.isEmpty))
            }
            .padding()
        }
        .frame(width: 460)
        .onChange(of: [cidr, gateway, dns]) { error = nil }
        .onChange(of: manual) { error = nil }
        .reportsErrors()
    }

    private var guestHint: String {
        switch os {
        case .macOS:
            String(l10n: "The guest agent applies this in the guest right away if the virtual machine is running, otherwise the next time it starts. Changing it on a macOS guest needs the guest password saved in the virtual machine.")
        case .linux, .windows:
            String(l10n: "The guest agent applies this in the guest right away if the virtual machine is running, otherwise the next time it starts. The guest needs NetworkManager or systemd-networkd.")
        }
    }

    /// 填写有误时把原因留在 sheet 里，不关闭。
    private func save() {
        do {
            let servers = dns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let value = manual ? try StaticIPv4(cidr: cidr, gateway: gateway, dns: servers) : nil
            if model.setStaticIPv4(vmName, value) { dismiss() }
        } catch {
            self.error = ReportedError(error).message
        }
    }
}
