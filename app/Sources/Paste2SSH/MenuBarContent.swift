import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading) {
            Label(menuTitle, systemImage: menuIcon)

            Toggle(state.isOn ? "Turn Off" : "Turn On", isOn: Binding {
                state.isOn
            } set: { value in
                state.setOn(value)
            })
            .disabled(state.settings.normalizedHost.isEmpty || state.isConnecting)

            Divider()

            Menu {
                if state.sshHosts.isEmpty {
                    Button("No SSH config hosts found") {}
                        .disabled(true)
                } else {
                    ForEach(state.sshHosts, id: \.self) { host in
                        Button {
                            state.selectHost(host)
                        } label: {
                            if state.settings.normalizedHost == host {
                                Label(host, systemImage: "checkmark")
                            } else {
                                Text(host)
                            }
                        }
                    }
                }

                Divider()

                Button("Reload SSH Config") {
                    state.reloadSSHHosts()
                }

                Button("Add SSH Connection...") {
                    AppController.shared.showMainWindow()
                    state.requestAddHost()
                }
            } label: {
                Label(state.settings.normalizedHost.isEmpty ? "Choose Host" : state.settings.normalizedHost, systemImage: "server.rack")
            }

            if let upload = state.lastUpload {
                Button("Copy Last Path") {
                    state.copyLastRemotePath()
                }
                Text(compactFilename(upload.remotePath))
                    .font(.caption)
                    .lineLimit(1)
            }

            Divider()

            Button("Open Paste2SSH...") {
                NSApp.setActivationPolicy(.regular)
                AppController.shared.showMainWindow()
            }

            Button("Settings...") {
                AppController.shared.showSettingsWindow()
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
    }

    private var menuTitle: String {
        switch state.connectionPhase {
        case .off:
            "Paste2SSH is off"
        case .connecting:
            "Connecting..."
        case .on:
            "Paste2SSH is on"
        }
    }

    private var menuIcon: String {
        switch state.connectionPhase {
        case .off:
            "power"
        case .connecting:
            "arrow.triangle.2.circlepath"
        case .on:
            "bolt.fill"
        }
    }

    private func compactFilename(_ path: String) -> String {
        let filename = path.split(separator: "/").last.map(String.init) ?? path
        if filename.hasPrefix("screenshot-") {
            return String(filename.dropFirst("screenshot-".count))
        }
        return filename
    }
}
