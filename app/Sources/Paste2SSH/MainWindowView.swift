import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Thread-safe collector for file URLs gathered from concurrent NSItemProvider callbacks.
private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

struct MainWindowView: View {
    @Bindable var state: AppState
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            appBackground

            HStack(spacing: 0) {
                sidebar
                pageContent
            }

            firstSuccessToast
            hostPickerOverlay
            dragOverlay
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: state.activePanel)
        .animation(.easeInOut(duration: 0.22), value: state.selectedPage)
        .animation(.easeInOut(duration: 0.22), value: state.connectionPhase)
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var dragOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.40), lineWidth: 2)
                .padding(6)
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(9)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let relevant = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !relevant.isEmpty else {
            return false
        }

        let group = DispatchGroup()
        let collector = DroppedURLCollector()
        for provider in relevant {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    collector.add(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.all
            if !urls.isEmpty {
                state.uploadDroppedFiles(urls)
            }
        }
        return true
    }

    @ViewBuilder
    private var firstSuccessToast: some View {
        if state.showFirstSuccess {
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.green)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("You’re set.")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Paste in your terminal with ⌘ + V.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.64))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: state.connectionPhase == .on
                                ? [Color(red: 0.12, green: 0.34, blue: 0.34).opacity(0.92), Color(red: 0.05, green: 0.08, blue: 0.18).opacity(0.92)]
                                : [Color(red: 0.16, green: 0.09, blue: 0.32).opacity(0.92), Color.black.opacity(0.62)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.12))
                    }
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                }
                Spacer()
            }
            .padding(.top, 22)
            .padding(.trailing, 22)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(8)
            .allowsHitTesting(false)
        }
    }

    private var appBackground: some View {
        LinearGradient(
            colors: state.connectionPhase == .on
                ? [Color(red: 0.28, green: 0.66, blue: 0.58), Color(red: 0.07, green: 0.11, blue: 0.24)]
                : [Color(red: 0.32, green: 0.08, blue: 0.55), Color(red: 0.05, green: 0.03, blue: 0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 52)

            SidebarButton(title: "Paste", systemImage: "power.circle", isSelected: state.selectedPage == .paste) {
                state.selectedPage = .paste
                state.activePanel = nil
            }

            SidebarButton(title: "Hosts", systemImage: "server.rack", isSelected: state.selectedPage == .hosts) {
                state.selectedPage = .hosts
                state.activePanel = nil
            }

            Spacer()

            if AppController.shared.updater.updateAvailable {
                UpdateSidebarButton(phase: state.connectionPhase) {
                    AppController.shared.updater.checkForUpdates()
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            SidebarButton(title: "Feedback", systemImage: "bubble.left.and.bubble.right", isSelected: state.selectedPage == .feedback) {
                state.selectedPage = .feedback
                state.activePanel = nil
            }

            SidebarButton(title: "Settings", systemImage: "slider.horizontal.3", isSelected: state.selectedPage == .settings) {
                state.selectedPage = .settings
                state.activePanel = nil
            }
        }
        .padding(.bottom, 22)
        .frame(width: 86)
        .background(Color.black.opacity(0.20))
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: AppController.shared.updater.updateAvailable)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch state.selectedPage {
        case .paste:
            PastePage(state: state)
        case .hosts:
            HostsPage(state: state)
        case .settings:
            SettingsPage(state: state)
        case .feedback:
            FeedbackPage()
        }
    }

    private var hostPickerOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                Rectangle()
                    .fill(Color.black.opacity(state.activePanel == nil ? 0 : 0.50))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if state.activePanel != nil {
                            state.activePanel = nil
                        }
                    }

                ZStack {
                    panelBackground
                    rightPanelContent
                }
                .frame(width: panelWidth)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.vertical, 12)
                .padding(.trailing, 12)
                .shadow(color: .black.opacity(0.35), radius: 24)
                .opacity(state.activePanel == nil ? 0 : 1)
                .offset(x: state.activePanel == nil ? panelWidth + 24 : 0)
            }
        }
        .zIndex(10)
        .allowsHitTesting(state.activePanel != nil)
    }

    private var panelWidth: CGFloat {
        switch state.activePanel {
        case .addHost, .editHost, .recentUploads:
            420
        case .hostPicker, .none:
            360
        }
    }

    @ViewBuilder
    private var rightPanelContent: some View {
        switch state.activePanel {
        case .hostPicker:
            HostPickerPanel(state: state)
        case .addHost:
            HostEditorPanel(
                state: state,
                mode: .add,
                onClose: { state.activePanel = nil },
                onMessage: { state.statusText = $0 }
            )
        case .editHost(let host):
            HostEditorPanel(
                state: state,
                mode: .edit(host),
                onClose: { state.activePanel = nil },
                onMessage: { state.statusText = $0 }
            )
        case .recentUploads:
            RecentUploadsPanel(state: state)
        case .none:
            EmptyView()
        }
    }

    private var panelBackground: some View {
        ZStack {
            LinearGradient(
                colors: state.connectionPhase == .on
                    ? [
                        Color(red: 0.14, green: 0.36, blue: 0.35),
                        Color(red: 0.05, green: 0.07, blue: 0.17)
                    ]
                    : [
                        Color(red: 0.12, green: 0.08, blue: 0.28),
                        Color(red: 0.05, green: 0.04, blue: 0.15)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    (state.connectionPhase == .on
                        ? Color(red: 0.27, green: 0.68, blue: 0.58)
                        : Color(red: 0.27, green: 0.12, blue: 0.48)).opacity(0.55),
                    .clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 360
            )
        }
    }
}

private struct PastePage: View {
    @Bindable var state: AppState
    @State private var isPowerHovered = false

    var body: some View {
        VStack(spacing: 14) {
            PageHeader(
                title: "Paste2SSH",
                subtitle: "Screenshot locally. Paste the remote path."
            )

            Spacer(minLength: 0)
            powerButton
            statusBlock
            Spacer(minLength: 0)
            hostCard
            RecentUploadsTray(state: state)
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var powerButton: some View {
        Button {
            state.setOn(state.isConnecting ? false : !state.isOn)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 176, height: 176)

                Circle()
                    .fill(Color.white.opacity(isPowerHovered ? 0.12 : 0.07))
                    .frame(width: 134, height: 134)
                    .overlay {
                        Circle()
                            .stroke(borderColor, lineWidth: isPowerHovered ? 6 : 5)
                    }
                    .shadow(color: borderColor.opacity(isPowerHovered ? 0.38 : 0.24), radius: isPowerHovered ? 32 : 24)
                    .scaleEffect(isPowerHovered ? 1.05 : 1.0)

                if state.isConnecting {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(HoverCardButtonStyle())
        .disabled(state.settings.normalizedHost.isEmpty && !state.isConnecting)
        .onHover { hovering in
            isPowerHovered = hovering && !state.settings.normalizedHost.isEmpty
        }
        .animation(.easeInOut(duration: 0.16), value: isPowerHovered)
    }

    private var borderColor: Color {
        switch state.connectionPhase {
        case .off:
            Color.pink.opacity(0.85)
        case .connecting:
            Color.white.opacity(0.82)
        case .on:
            .cyan
        }
    }

    private var statusBlock: some View {
        VStack(spacing: 6) {
            Text(statusTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text(statusSubtitle)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)

            if state.statusKind == .error {
                StatusMessageView(message: state.statusText)
                    .padding(.top, 4)
            }
        }
    }

    private var hostCard: some View {
        Button {
            state.activePanel = .hostPicker
        } label: {
            HStack(spacing: 14) {
                IconTile(systemImage: "server.rack")

                VStack(alignment: .leading, spacing: 3) {
                    Text(hostCardTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(hostCardSubtitle)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer()

                readinessBadge

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCardButtonStyle())
    }

    private var hostCardTitle: String {
        if !state.settings.normalizedHost.isEmpty {
            return state.settings.normalizedHost
        }
        return state.sshHosts.isEmpty ? "Add a host" : "Choose SSH host"
    }

    private var hostCardSubtitle: String {
        if !state.settings.normalizedHost.isEmpty {
            return state.settings.effectiveRemoteDir
        }
        return state.sshHosts.isEmpty ? "Create your first SSH connection" : "Use an existing ~/.ssh/config alias"
    }

    @ViewBuilder
    private var readinessBadge: some View {
        let host = state.settings.normalizedHost
        if !host.isEmpty {
            switch state.readiness(for: host) {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 1.0, green: 0.52, blue: 0.45))
            case .unknown:
                EmptyView()
            }
        }
    }

    private var statusTitle: String {
        switch state.connectionPhase {
        case .off:
            "Paste mode is off"
        case .connecting:
            "Connecting..."
        case .on:
            "Paste mode is on"
        }
    }

    private var statusSubtitle: String {
        switch state.connectionPhase {
        case .off:
            "Choose an SSH host, then tap the power button."
        case .connecting:
            "Checking SSH and preparing screenshot watching."
        case .on:
            "Copy a screenshot, then press ⌘ + V in your remote agent."
        }
    }
}

private struct TransferPulseView: View {
    @Bindable var state: AppState

    var body: some View {
        if state.statusKind == .working || state.lastUpload != nil {
            HStack(spacing: 10) {
                pulseItem("Clipboard", "doc.on.clipboard")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.white.opacity(0.48))
                pulseItem(state.settings.normalizedHost.isEmpty ? "Host" : state.settings.normalizedHost, "server.rack")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.white.opacity(0.48))
                pulseItem(state.lastUpload == nil ? "Path" : "Copied", state.lastUpload == nil ? "link" : "checkmark.circle.fill")
                    .foregroundStyle(state.lastUpload == nil ? .white.opacity(0.72) : .green)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.14), in: Capsule())
            .id(state.transferPulseID)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private func pulseItem(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.72))
    }
}

private struct RecentUploadsTray: View {
    @Bindable var state: AppState
    @State private var copiedUploadID: UUID?
    @State private var copyFeedbackID = 0

    var body: some View {
        if !state.recentUploads.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.54))
                    Spacer()
                    Button {
                        state.activePanel = .recentUploads
                    } label: {
                        HStack(spacing: 3) {
                            Text("All")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .padding(.vertical, 6)
                        .padding(.leading, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.74))
                    .pointingCursor()
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(state.recentUploads.prefix(6)) { upload in
                        recentCard(upload)
                    }
                }
            }
        }
    }

    private func recentCard(_ upload: LastUpload) -> some View {
        let didCopy = copiedUploadID == upload.id

        return Button {
            copy(upload)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(upload.host)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if didCopy {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Text(didCopy ? "Copied" : compactFilename(upload.remotePath))
                    .font(.system(.caption2, design: didCopy ? .default : .monospaced))
                    .fontWeight(didCopy ? .semibold : .regular)
                    .foregroundStyle(didCopy ? Color.green : Color.white.opacity(0.56))
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(
                LinearGradient(
                    colors: didCopy
                        ? [Color.green.opacity(0.20), Color.black.opacity(0.15)]
                        : [Color.black.opacity(0.18), Color.black.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(didCopy ? Color.green.opacity(0.32) : Color.white.opacity(0.04))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCardButtonStyle())
    }

    private func copy(_ upload: LastUpload) {
        state.copyRemotePath(upload.remotePath)
        copyFeedbackID += 1
        let feedbackID = copyFeedbackID
        copiedUploadID = upload.id

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copyFeedbackID == feedbackID {
                copiedUploadID = nil
            }
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

private struct HostsPage: View {
    @Bindable var state: AppState
    @State private var message = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    PageHeader(title: "Hosts", subtitle: "Use SSH aliases you already have, or add a new one.")
                    Spacer()
                    Button {
                        state.requestAddHost()
                    } label: {
                        Label("Add New", systemImage: "plus")
                            .frame(minWidth: 106, minHeight: 36)
                    }
                    .buttonStyle(ThemedPrimaryButtonStyle(phase: state.connectionPhase))
                }

                SectionTitle("Existing SSH Config Hosts")

                VStack(spacing: 8) {
                    if state.sshHosts.isEmpty {
                        EmptyCard(title: "No hosts found", subtitle: "Add one with the button above or create a Host entry in ~/.ssh/config.")
                    } else {
                        ForEach(state.sshHosts, id: \.self) { host in
                            compactHostRow(host)
                        }
                    }
                }

                HStack {
                    Button {
                        state.reloadSSHHosts()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                            .frame(minWidth: 92, minHeight: 34)
                    }
                    .buttonStyle(HoverCardButtonStyle())

                    Button {
                        state.openSSHConfig()
                    } label: {
                        Label("Open SSH Config", systemImage: "doc")
                            .frame(minWidth: 132, minHeight: 34)
                    }
                    .buttonStyle(HoverCardButtonStyle())
                }

                if !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(message.hasPrefix("Deleted") || message.hasPrefix("Saved") || message.hasPrefix("Added") ? .green : .red)
                }
            }
            .padding(.top, 30)
            .padding(.horizontal, 30)
            .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactHostRow(_ host: String) -> some View {
        HStack(spacing: 12) {
            Button {
                state.selectHost(host)
                state.selectedPage = .paste
            } label: {
                HStack(spacing: 12) {
                    IconTile(systemImage: "server.rack")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(host)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(state.remoteDir(for: host))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                    }

                    Spacer()

                    if host == state.settings.normalizedHost {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverCardButtonStyle())

            Button {
                state.activePanel = .editHost(host)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(IconHoverButtonStyle())
            .help("Edit host")
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(host == state.settings.normalizedHost ? Color.white.opacity(0.14) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

private enum HostEditorMode: Equatable {
    case add
    case edit(String)
}

private struct HostEditorPanel: View {
    @Bindable var state: AppState
    let mode: HostEditorMode
    let onClose: () -> Void
    let onMessage: (String) -> Void

    @State private var alias = ""
    @State private var hostName = ""
    @State private var user = ""
    @State private var port = ""
    @State private var remoteDir = ""
    @State private var localMessage = ""
    @State private var hostPendingDelete: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("SSH config entry and upload folder")
                        .foregroundStyle(.white.opacity(0.60))
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.18))
                .pointingCursor()
            }

            formFields

            Text("Remote folder is per host. Leave it as the default unless this VPS needs a different path.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.60))

            if !localMessage.isEmpty {
                Text(localMessage)
                    .font(.callout)
                    .foregroundStyle(localMessageColor)
            }

            actionRow
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(
            "Delete SSH connection?",
            isPresented: Binding {
                hostPendingDelete != nil
            } set: { isPresented in
                if !isPresented {
                    hostPendingDelete = nil
                }
            },
            titleVisibility: .visible
        ) {
            if let hostPendingDelete {
                Button("Delete \(hostPendingDelete)", role: .destructive) {
                    let result = state.deleteSSHConnection(host: hostPendingDelete)
                    onMessage(result)
                    self.hostPendingDelete = nil
                    onClose()
                }
            }
            Button("Cancel", role: .cancel) {
                hostPendingDelete = nil
            }
        }
        .onAppear(perform: load)
    }

    private var title: String {
        switch mode {
        case .add:
            "Add SSH Connection"
        case .edit:
            "Edit SSH Connection"
        }
    }

    private var saveTitle: String {
        switch mode {
        case .add:
            "Add"
        case .edit:
            "Save"
        }
    }

    private var originalHost: String? {
        if case .edit(let host) = mode {
            return host
        }
        return nil
    }

    private var localMessageColor: Color {
        localMessage.hasPrefix("Saved") || localMessage.hasPrefix("Added") ? .green : .red
    }

    private var formFields: some View {
        VStack(spacing: 10) {
            DarkTextField("Name, e.g. my-vps", text: $alias)
            DarkTextField("Server host or IP", text: $hostName)
            HStack {
                DarkTextField("User (optional)", text: $user)
                DarkTextField("Port", text: $port)
                    .frame(width: 94)
            }
            DarkTextField(state.settings.remoteDir, text: $remoteDir)
        }
    }

    private var actionRow: some View {
        HStack {
            deleteButton
            Spacer()
            Button {
                save()
            } label: {
                Label(saveTitle, systemImage: "checkmark")
                    .frame(minWidth: 90, minHeight: 34)
            }
            .buttonStyle(ThemedPrimaryButtonStyle(phase: state.connectionPhase))
            .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var deleteButton: some View {
        if case .edit(let host) = mode {
            Button(role: .destructive) {
                hostPendingDelete = host
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(minWidth: 86, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .tint(.red.opacity(0.85))
            .pointingCursor()
        }
    }

    private func load() {
        switch mode {
        case .add:
            alias = ""
            hostName = ""
            user = ""
            port = ""
            remoteDir = state.settings.remoteDir
        case .edit(let host):
            let details = state.connectionDetails(for: host)
            alias = details.alias
            hostName = details.hostName
            user = details.user
            port = details.port
            remoteDir = details.remoteDir
        }
    }

    private func save() {
        let result = state.saveSSHConnection(
            originalHost: originalHost,
            alias: alias,
            hostName: hostName,
            user: user,
            port: port,
            remoteDir: remoteDir
        )
        localMessage = result
        onMessage(result)
        if result.hasPrefix("Saved") || result.hasPrefix("Added") {
            onClose()
        }
    }
}

private struct SettingsPage: View {
    @Bindable var state: AppState
    private let fieldColumnWidth: CGFloat = 240
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Settings", subtitle: "Defaults for screenshots and SSH uploads.")

                VStack(spacing: 1) {
                    settingRow(title: "Default remote folder") {
                        DarkTextField("~/.paste2ssh", text: $state.settings.remoteDir)
                            .frame(width: fieldColumnWidth)
                    }

                    Divider().overlay(Color.white.opacity(0.10))

                    settingRow(title: "Filename") {
                        DarkTextField("screenshot-{yyyyMMdd-HHmmss}.png", text: $state.settings.filenamePattern)
                            .frame(width: fieldColumnWidth)
                    }

                    Divider().overlay(Color.white.opacity(0.10))

                    settingRow(title: "Delete remote images automatically after") {
                        Picker("", selection: cleanupBinding) {
                            Text("Never").tag(0)
                            Text("7 days").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                            Text("60 days").tag(60)
                            Text("90 days").tag(90)
                        }
                        .labelsHidden()
                        .pointingCursor()
                        .frame(width: fieldColumnWidth, alignment: .trailing)
                    }

                    Divider().overlay(Color.white.opacity(0.10))

                    settingRow(title: "Launch at login") {
                        Toggle("", isOn: Binding {
                            state.settings.launchAtLogin
                        } set: { state.setLaunchAtLogin($0) })
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                        .pointingCursor()
                        .frame(width: fieldColumnWidth, alignment: .trailing)
                    }

                    Divider().overlay(Color.white.opacity(0.10))

                    settingRow(title: "Version \(appVersion)") {
                        Button("Check for Updates") {
                            AppController.shared.updater.checkForUpdates()
                        }
                        .disabled(!AppController.shared.updater.canCheckForUpdates)
                        .pointingCursor()
                        .frame(width: fieldColumnWidth, alignment: .trailing)
                    }
                }
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                Text("Cleanup is opt-in. When enabled, Paste2SSH installs a marked cleanup script inside the selected remote folder and only deletes image files directly in that folder.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.54))

                SectionTitle("Connection")
                VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        Text("Current SSH target")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                        HostMenuField(
                            selectedHost: state.settings.normalizedHost,
                            hosts: state.sshHosts,
                            onSelect: { state.selectHost($0) }
                        )
                        .frame(width: 180, alignment: .trailing)
                        Button("Test") {
                            state.testConnection()
                        }
                        .frame(minWidth: 72, minHeight: 34)
                        .disabled(state.settings.normalizedHost.isEmpty || state.isTestingConnection)
                        .pointingCursor()
                    }

                    if !state.testResult.isEmpty {
                        StatusMessageView(message: state.testResult)
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.top, 30)
            .padding(.horizontal, 30)
            .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            content()
                .frame(width: fieldColumnWidth, alignment: .trailing)
        }
        .padding(14)
    }

    private var cleanupBinding: Binding<Int> {
        Binding {
            state.settings.cleanupDays
        } set: { value in
            state.settings.cleanupDays = value
            state.applyCleanupPolicy()
        }
    }
}

private struct FeedbackPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Feedback", subtitle: "Tell us what should be better.")

            VStack(spacing: 12) {
                feedbackCard(
                    title: "Leave a Review",
                    subtitle: "A quick review helps shape the app.",
                    systemImage: "star.bubble",
                    url: "https://forms.gle/WbFaWCtfhLU2NCHg7"
                )

                feedbackCard(
                    title: "Bug or Feedback",
                    subtitle: "Report rough edges, broken flows, or ideas.",
                    systemImage: "wrench.and.screwdriver",
                    url: "https://forms.gle/LgwYZmFCMUkRdqFG9"
                )
            }

            Spacer()
        }
        .padding(.top, 30)
        .padding(.horizontal, 30)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feedbackCard(title: String, subtitle: String, systemImage: String, url: String) -> some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 14) {
                IconTile(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.13), Color.white.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCardButtonStyle())
    }
}

private struct RecentUploadsPanel: View {
    @Bindable var state: AppState
    @State private var copiedUploadID: UUID?
    @State private var copyFeedbackID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Paths")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Click any path to copy it again.")
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Button {
                    state.activePanel = nil
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.18))
                .pointingCursor()
            }

            if state.recentUploads.isEmpty {
                EmptyCard(title: "No uploads yet", subtitle: "Uploaded paths will appear here.")
                    .foregroundStyle(.white)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(state.recentUploads) { upload in
                            recentRow(upload)
                        }
                    }
                }
            }
        }
        .padding(22)
    }

    private func recentRow(_ upload: LastUpload) -> some View {
        let didCopy = copiedUploadID == upload.id

        return Button {
            copy(upload)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    if didCopy {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Color.green)
                    } else {
                        Text(upload.host)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text(relativeMinutes(since: upload.date))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.50))
                }
                Text(upload.remotePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(didCopy ? Color.green.opacity(0.82) : .white.opacity(0.62))
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: didCopy
                        ? [Color.green.opacity(0.20), Color.white.opacity(0.07)]
                        : [Color.white.opacity(0.10), Color.white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(didCopy ? Color.green.opacity(0.28) : Color.white.opacity(0.04))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCardButtonStyle())
    }

    private func copy(_ upload: LastUpload) {
        state.copyRemotePath(upload.remotePath)
        copyFeedbackID += 1
        let feedbackID = copyFeedbackID
        copiedUploadID = upload.id

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copyFeedbackID == feedbackID {
                copiedUploadID = nil
            }
        }
    }

    private func relativeMinutes(since date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        return minutes == 0 ? "now" : "\(minutes) min"
    }
}

private struct HostPickerPanel: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose Host")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("From ~/.ssh/config")
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Button {
                    state.activePanel = nil
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.18))
                .pointingCursor()
            }

            if state.sshHosts.isEmpty {
                EmptyCard(title: "No hosts found", subtitle: "Add one from the Hosts page.")
                    .foregroundStyle(.white)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    if state.sshHosts.count >= 7 {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(state.sshHosts, id: \.self) { host in
                                hostGridTile(host)
                            }
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(state.sshHosts, id: \.self) { host in
                                hostListRow(host)
                            }
                        }
                    }
                }
            }

            HStack {
                Button {
                    state.reloadSSHHosts()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .frame(minWidth: 92, minHeight: 34)
                }
                .buttonStyle(HoverCardButtonStyle())
                Spacer()
                Button {
                    state.requestAddHost()
                } label: {
                    Label("Add", systemImage: "plus")
                        .frame(minWidth: 78, minHeight: 34)
                }
                .buttonStyle(ThemedPrimaryButtonStyle(phase: state.connectionPhase))
            }
        }
        .padding(22)
    }

    private func hostListRow(_ host: String) -> some View {
        Button {
            state.selectHost(host)
            state.activePanel = nil
        } label: {
            HStack {
                IconTile(systemImage: "server.rack")
                VStack(alignment: .leading, spacing: 3) {
                    Text(host)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(state.remoteDir(for: host))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                }
                Spacer()
                if host == state.settings.normalizedHost {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(hostBackground(for: host), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCardButtonStyle())
    }

    private func hostGridTile(_ host: String) -> some View {
        Button {
            state.selectHost(host)
            state.activePanel = nil
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    IconTile(systemImage: "server.rack")
                    if host == state.settings.normalizedHost {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .offset(x: 7, y: -6)
                    }
                }
                Text(host)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.76)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(hostBackground(for: host), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCardButtonStyle())
    }

    private func hostBackground(for host: String) -> LinearGradient {
        LinearGradient(
            colors: host == state.settings.normalizedHost
                ? [Color.white.opacity(0.20), Color.white.opacity(0.12)]
                : [Color.white.opacity(0.12), Color.white.opacity(0.07)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.54))
    }
}

private struct EmptyCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StatusMessageView: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            if let url {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.replacingOccurrences(of: url.absoluteString, with: "").trimmingCharacters(in: .whitespacesAndNewlines))
                    Link(url.absoluteString, destination: url)
                        .lineLimit(1)
                }
            } else {
                Text(message)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .foregroundStyle(isSuccess ? Color.green : Color(red: 1.0, green: 0.52, blue: 0.45))
        .lineLimit(3)
    }

    private var isSuccess: Bool {
        message == "Connection OK."
    }

    private var url: URL? {
        guard let range = message.range(of: #"https?://[^\s]+"#, options: .regularExpression) else {
            return nil
        }
        let string = String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
        return URL(string: string)
    }
}

private struct IconTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white.opacity(0.84))
            .frame(width: 44, height: 44)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DarkTextField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(.white)
            .tint(.white)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isFocused ? 0.16 : 0.10),
                        Color.white.opacity(isFocused ? 0.10 : 0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isFocused ? Color.white.opacity(0.34) : Color.white.opacity(0.12), lineWidth: 1)
            }
            .focused($isFocused)
    }
}

private struct ThemedPrimaryButtonStyle: ButtonStyle {
    let phase: ConnectionPhase

    func makeBody(configuration: Configuration) -> some View {
        ThemedPrimaryButton(configuration: configuration, phase: phase)
    }
}

private struct ThemedPrimaryButton: View {
    let configuration: ButtonStyle.Configuration
    let phase: ConnectionPhase
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(.white)
            .background(background(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.14))
            }
            .shadow(color: accent.opacity(configuration.isPressed ? 0.10 : (isHovered ? 0.32 : 0.22)), radius: configuration.isPressed ? 5 : (isHovered ? 16 : 12), y: 6)
            .brightness(isHovered ? 0.04 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : (isHovered ? 1.025 : 1.0))
            .animation(.easeInOut(duration: 0.14), value: isHovered)
            .pointingCursor { isHovered = $0 }
    }

    private var accent: Color {
        switch phase {
        case .on:
            Color(red: 0.35, green: 0.86, blue: 0.78)
        case .connecting:
            Color.white.opacity(0.86)
        case .off:
            Color(red: 0.72, green: 0.34, blue: 0.92)
        }
    }

    private func background(isPressed: Bool) -> LinearGradient {
        let opacity = isPressed ? 0.78 : 1.0
        let colors: [Color]
        switch phase {
        case .on:
            colors = [
                Color(red: 0.30, green: 0.72, blue: 0.66).opacity(opacity),
                Color(red: 0.18, green: 0.42, blue: 0.58).opacity(opacity)
            ]
        case .connecting:
            colors = [
                Color.white.opacity(isPressed ? 0.16 : 0.22),
                Color.white.opacity(isPressed ? 0.10 : 0.14)
            ]
        case .off:
            colors = [
                Color(red: 0.56, green: 0.25, blue: 0.86).opacity(opacity),
                Color(red: 0.36, green: 0.24, blue: 0.68).opacity(opacity)
            ]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct HoverCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCardButton(configuration: configuration)
    }
}

private struct HoverCardButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .brightness(isHovered ? 0.045 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : (isHovered ? 1.012 : 1.0))
            .animation(.easeInOut(duration: 0.14), value: isHovered)
            .pointingCursor { isHovered = $0 }
    }
}

private struct IconHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconHoverButton(configuration: configuration)
    }
}

private struct IconHoverButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(
                Color.white.opacity(isHovered ? 0.20 : 0.10),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(isHovered ? 0.30 : 0.12))
            }
            .brightness(isHovered ? 0.05 : 0)
            .scaleEffect(configuration.isPressed ? 0.94 : (isHovered ? 1.06 : 1.0))
            .animation(.easeInOut(duration: 0.14), value: isHovered)
            .pointingCursor { isHovered = $0 }
    }
}

private struct PointingCursorModifier: ViewModifier {
    var onHoverChange: ((Bool) -> Void)?

    func body(content: Content) -> some View {
        content.onHover { isHovered in
            onHoverChange?(isHovered)
            if isHovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private extension View {
    func pointingCursor(_ onHoverChange: ((Bool) -> Void)? = nil) -> some View {
        modifier(PointingCursorModifier(onHoverChange: onHoverChange))
    }
}

private struct HostMenuField: View {
    let selectedHost: String
    let hosts: [String]
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            Button("Choose host") {
                onSelect("")
            }
            if !hosts.isEmpty {
                Divider()
            }
            ForEach(hosts, id: \.self) { host in
                Button {
                    onSelect(host)
                } label: {
                    if host == selectedHost {
                        Label(host, systemImage: "checkmark")
                    } else {
                        Text(host)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(selectedHost.isEmpty ? "Choose host" : selectedHost)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 10)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .frame(width: 180, height: 42)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.14), Color.white.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.12))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointingCursor()
    }
}

private struct UpdateSidebarButton: View {
    let phase: ConnectionPhase
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                Text("Update")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .frame(width: 76, height: 62)
            .background(
                LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.18))
            }
            .shadow(color: accentColor.opacity(isHovered ? 0.42 : 0.26), radius: isHovered ? 14 : 9, y: 3)
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("A new version is available — click to update")
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .pointingCursor { isHovered = $0 }
    }

    // Match the app's mode colors: teal when Paste Mode is on, purple otherwise.
    private var gradientColors: [Color] {
        phase == .on
            ? [Color(red: 0.30, green: 0.72, blue: 0.66), Color(red: 0.18, green: 0.42, blue: 0.58)]
            : [Color(red: 0.56, green: 0.25, blue: 0.86), Color(red: 0.36, green: 0.24, blue: 0.68)]
    }

    private var accentColor: Color {
        phase == .on
            ? Color(red: 0.35, green: 0.86, blue: 0.78)
            : Color(red: 0.72, green: 0.34, blue: 0.92)
    }
}

private struct SidebarButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 23, weight: .medium))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(isHovered ? 0.74 : 0.48))
            .frame(width: 76, height: 72)
            .background(sidebarBackground, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .scaleEffect(isHovered ? 1.035 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .pointingCursor { isHovered = $0 }
    }

    private var sidebarBackground: Color {
        if isSelected {
            return Color.white.opacity(isHovered ? 0.16 : 0.12)
        }
        return Color.white.opacity(isHovered ? 0.07 : 0)
    }
}
