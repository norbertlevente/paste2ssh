import AppKit
import Foundation
import Observation

enum StatusKind {
    case ready
    case working
    case success
    case error
}

enum ActivePanel: Equatable {
    case hostPicker
    case addHost
    case editHost(String)
    case recentUploads
}

enum AppPage {
    case paste
    case hosts
    case settings
    case feedback
}

enum ConnectionPhase {
    case off
    case connecting
    case on
}

enum ReadinessStatus: Equatable {
    case unknown
    case checking
    case ready
    case failed(String)
}

struct LastUpload: Codable, Identifiable, Equatable {
    let id: UUID
    let localName: String
    let remotePath: String
    let host: String
    let date: Date

    init(id: UUID = UUID(), localName: String, remotePath: String, host: String, date: Date) {
        self.id = id
        self.localName = localName
        self.remotePath = remotePath
        self.host = host
        self.date = date
    }
}

struct SSHConnectionDetails: Equatable {
    var alias: String
    var hostName: String
    var user: String
    var port: String
    var remoteDir: String
}

@MainActor
@Observable
final class AppState {
    var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.isOnKey)
            isOn ? startWatchers() : stopWatchers()
        }
    }

    var statusText = "Ready."
    var statusKind: StatusKind = .ready
    var lastUpload: LastUpload?
    var recentUploads: [LastUpload] = []
    var settings: Settings {
        didSet {
            settings.save()
            if isOn && !suppressSettingsRestart {
                restartWatchers()
            }
        }
    }
    var testResult = ""
    var isTestingConnection = false
    var sshHosts: [String] = []
    var activePanel: ActivePanel?
    var selectedPage: AppPage = .paste
    var readinessByHost: [String: ReadinessStatus] = [:]
    var showFirstSuccess = false
    var transferPulseID = 0
    var menuBarPulsing = false
    var launchAtLoginError: String?
    var connectionPhase: ConnectionPhase {
        if isConnecting {
            return .connecting
        }
        return isOn ? .on : .off
    }
    var isConnecting = false

    @ObservationIgnored private static let isOnKey = "Paste2SSH.isOn.v1"
    @ObservationIgnored private static let recentUploadsKey = "Paste2SSH.recentUploads.v1"
    @ObservationIgnored private static let firstSuccessHostsKey = "Paste2SSH.firstSuccessHosts.v1"
    @ObservationIgnored private let uploader = SSHUploader()
    @ObservationIgnored private var clipboardWatcher: ClipboardWatcher?
    @ObservationIgnored private var screenshotWatcher: ScreenshotWatcher?
    @ObservationIgnored private var activeUploads = Set<String>()
    @ObservationIgnored private var suppressSettingsRestart = false

    init() {
        settings = Settings.load()
        let shouldRestoreOn = UserDefaults.standard.bool(forKey: Self.isOnKey)
        isOn = false
        recentUploads = Self.loadRecentUploads()
        lastUpload = recentUploads.first
        reloadSSHHosts()
        let loginEnabled = LoginItem.isEnabled
        if settings.launchAtLogin != loginEnabled {
            suppressSettingsRestart = true
            settings.launchAtLogin = loginEnabled
            suppressSettingsRestart = false
        }
        if shouldRestoreOn {
            Task { @MainActor in
                setOn(true)
            }
        }
    }

    func setOn(_ value: Bool) {
        guard value else {
            isConnecting = false
            isOn = false
            lastUpload = nil
            let snapshot = settings
            Task { await uploader.closeMaster(settings: snapshot) }
            return
        }
        guard !isOn, !isConnecting else {
            return
        }
        guard !value || !settings.normalizedHost.isEmpty else {
            setError("Pick an SSH host first.")
            return
        }
        settings.monitorScreenshots = false
        settings.monitorClipboard = true
        settings.autoCopyPath = true
        isConnecting = true
        statusText = "Connecting to \(settings.normalizedHost)..."
        statusKind = .working

        let snapshot = settings
        Task {
            let result = await uploader.testConnection(settings: snapshot)
            isConnecting = false
            testResult = result
            if result == "Connection OK." {
                statusText = "Connected. Copy a screenshot, then paste the remote path."
                statusKind = .success
                isOn = true
            } else {
                isOn = false
                statusText = result
                statusKind = .error
            }
        }
    }

    func selectHost(_ host: String) {
        let previousHost = settings.normalizedHost
        let shouldRemainOn = isOn
        isConnecting = false
        if shouldRemainOn {
            stopWatchers()
        }

        if !previousHost.isEmpty, previousHost != host.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Snapshot still holds the old host; close its multiplexed connection.
            let oldSnapshot = settings
            Task { await uploader.closeMaster(settings: oldSnapshot) }
        }

        suppressSettingsRestart = true
        settings.host = host
        suppressSettingsRestart = false
        lastUpload = nil

        guard !host.isEmpty else {
            if shouldRemainOn {
                isOn = false
            }
            testResult = ""
            statusText = "Pick an SSH host first."
            statusKind = .ready
            return
        }

        testResult = ""

        if shouldRemainOn {
            isConnecting = true
            statusText = "Switching to \(host)..."
            statusKind = .working

            let snapshot = settings
            Task {
                let result = await uploader.testConnection(settings: snapshot)
                isConnecting = false
                testResult = result
                readinessByHost[snapshot.normalizedHost] = result == "Connection OK." ? .ready : .failed(result)
                if result == "Connection OK." {
                    statusText = "Connected to \(snapshot.normalizedHost)."
                    statusKind = .success
                    startWatchers()
                } else {
                    isOn = false
                    statusText = result
                    statusKind = .error
                }
            }
        } else {
            statusText = "Ready for \(host)."
            statusKind = .ready
            silentlyCheckHost(host)
        }
    }

    func requestAddHost() {
        selectedPage = .hosts
        activePanel = .addHost
    }

    func remoteDir(for host: String) -> String {
        settings.remoteDir(for: host)
    }

    func setRemoteDir(_ remoteDir: String, for host: String) {
        let key = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            settings.remoteDir = remoteDir
            return
        }
        let trimmed = remoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == settings.remoteDir {
            settings.remoteDirsByHost.removeValue(forKey: key)
        } else {
            settings.remoteDirsByHost[key] = trimmed
        }
    }

    func reloadSSHHosts() {
        sshHosts = SSHConfigHosts.load()
    }

    func connectionDetails(for host: String) -> SSHConnectionDetails {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let configURL = ensureSSHConfig()
        let remoteDir = remoteDir(for: target)

        guard let text = try? String(contentsOf: configURL, encoding: .utf8),
              let block = hostBlock(for: target, in: text.components(separatedBy: .newlines)) else {
            return SSHConnectionDetails(alias: target, hostName: "", user: "", port: "", remoteDir: remoteDir)
        }

        var details = SSHConnectionDetails(alias: target, hostName: "", user: "", port: "", remoteDir: remoteDir)
        for line in block.lines.dropFirst() {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else {
                continue
            }
            let key = parts[0].lowercased()
            let value = parts.dropFirst().joined(separator: " ")
            if key == "hostname" {
                details.hostName = value
            } else if key == "user" {
                details.user = value
            } else if key == "port" {
                details.port = value
            }
        }
        return details
    }

    func saveSSHConnection(originalHost: String?, alias rawAlias: String, hostName rawHostName: String, user rawUser: String, port rawPort: String, remoteDir rawRemoteDir: String) -> String {
        let alias = sanitizeAlias(rawAlias)
        let hostName = rawHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = rawUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = rawPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteDir = rawRemoteDir.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !alias.isEmpty, !hostName.isEmpty else {
            return "Name and server are required."
        }
        if originalHost != alias, sshHosts.contains(alias) {
            return "A Host named \(alias) already exists."
        }
        if !port.isEmpty && Int(port) == nil {
            return "Port must be a number."
        }

        let configURL = ensureSSHConfig()
        let newBlock = sshConfigBlock(alias: alias, hostName: hostName, user: user, port: port, preservingFrom: originalHost)

        do {
            if let originalHost {
                let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
                var lines = text.components(separatedBy: .newlines)
                guard let block = hostBlock(for: originalHost, in: lines) else {
                    return "Could not find Host \(originalHost) in ~/.ssh/config."
                }
                lines.replaceSubrange(block.range, with: newBlock.components(separatedBy: .newlines))
                try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
                if originalHost != alias {
                    settings.remoteDirsByHost.removeValue(forKey: originalHost)
                }
            } else {
                let handle = try FileHandle(forWritingTo: configURL)
                defer {
                    try? handle.close()
                }
                try handle.seekToEnd()
                if let data = ("\n" + newBlock + "\n").data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            }

            setRemoteDir(remoteDir.isEmpty ? settings.remoteDir : remoteDir, for: alias)
            reloadSSHHosts()
            selectHost(alias)
            return originalHost == nil ? "Added \(alias)." : "Saved \(alias)."
        } catch {
            return error.localizedDescription
        }
    }

    func openSSHConfig() {
        NSWorkspace.shared.open(ensureSSHConfig())
    }

    func deleteSSHConnection(host: String) -> String {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return "No host selected."
        }

        let configURL = ensureSSHConfig()
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return "Could not read ~/.ssh/config."
        }

        let lines = text.components(separatedBy: .newlines)
        var output: [String] = []
        var removed = false
        var skipping = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let isHostLine = parts.first?.lowercased() == "host"

            if isHostLine {
                if parts.dropFirst().contains(target) {
                    skipping = true
                    removed = true
                    continue
                } else {
                    skipping = false
                }
            }

            if !skipping {
                output.append(line)
            }
        }

        guard removed else {
            return "Could not find Host \(target) in ~/.ssh/config."
        }

        do {
            try output.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
            settings.remoteDirsByHost.removeValue(forKey: target)
            if settings.normalizedHost == target {
                settings.host = ""
                isOn = false
                lastUpload = nil
            }
            reloadSSHHosts()
            return "Deleted \(target)."
        } catch {
            return error.localizedDescription
        }
    }

    func uploadClipboardNow() {
        Task {
            do {
                let data = try ImageSource.clipboardPNGData()
                await uploadPipeline(.pngData(data, suggestedName: settings.generatedFilename()))
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    func uploadLatestScreenshotNow() {
        Task {
            do {
                let url = try ImageSource.latestScreenshot(in: settings.screenshotFolderURL)
                await uploadPipeline(.localFile(url))
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    func copyLastRemotePath() {
        guard let remotePath = lastUpload?.remotePath else {
            setError("No upload yet.")
            return
        }
        copyRemotePath(remotePath)
    }

    func copyRemotePath(_ remotePath: String) {
        copyToClipboard(remotePath)
        statusText = "Copied remote path."
        statusKind = .success
    }

    func testConnection() {
        isTestingConnection = true
        testResult = "Testing..."
        statusText = "Testing SSH connection..."
        statusKind = .working

        let snapshot = settings
        Task {
            let result = await uploader.testConnection(settings: snapshot)
            isTestingConnection = false
            testResult = result
            statusText = result
            statusKind = result == "Connection OK." ? .success : .error
            readinessByHost[snapshot.normalizedHost] = result == "Connection OK." ? .ready : .failed(result)
        }
    }

    func applyCleanupPolicy() {
        guard !settings.normalizedHost.isEmpty else {
            return
        }
        statusText = "Updating remote cleanup..."
        statusKind = .working
        let snapshot = settings
        Task {
            let result = await uploader.updateCleanupPolicy(settings: snapshot)
            statusText = result
            statusKind = result.hasPrefix("Remote cleanup") ? .success : .error
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        suppressSettingsRestart = true
        settings.launchAtLogin = on
        suppressSettingsRestart = false

        if let error = LoginItem.setEnabled(on) {
            launchAtLoginError = error
            statusText = "Couldn’t \(on ? "enable" : "disable") launch at login: \(error)"
            statusKind = .error
            // Reconcile the toggle to reality so the UI doesn't lie.
            let actual = LoginItem.isEnabled
            if settings.launchAtLogin != actual {
                suppressSettingsRestart = true
                settings.launchAtLogin = actual
                suppressSettingsRestart = false
            }
        } else {
            launchAtLoginError = nil
        }
    }

    private func remoteFilename(for input: ImageInput) -> String {
        switch input {
        case .localFile, .pngData:
            return settings.generatedFilename()
        case .rawFile(let url):
            return ImageSource.sanitizedRemoteName(for: url)
        }
    }

    func uploadPipeline(_ input: ImageInput, force: Bool = false) async {
        guard isOn || force else {
            return
        }
        let filename = remoteFilename(for: input)

        do {
            let prepared = try ImageSource.prepare(input, filename: filename)
            let uploadKey = prepared.localURL.path
            guard !activeUploads.contains(uploadKey) else {
                return
            }
            activeUploads.insert(uploadKey)
            defer {
                activeUploads.remove(uploadKey)
            }

            statusText = "Uploading \(prepared.displayName)..."
            statusKind = .working

            let snapshot = settings
            let result = try await uploader.upload(
                localURL: prepared.localURL,
                filename: filename,
                settings: snapshot
            )

            if settings.autoCopyPath {
                copyToClipboard(result.remotePath)
                statusText = "Uploaded and copied remote path."
            } else {
                statusText = "Uploaded."
            }

            statusKind = .success
            let upload = LastUpload(
                localName: prepared.displayName,
                remotePath: result.remotePath,
                host: snapshot.normalizedHost,
                date: Date()
            )
            lastUpload = upload
            addRecentUpload(upload)
            showFirstSuccessIfNeeded(for: snapshot.normalizedHost)
            transferPulseID += 1
            pulseMenuBar()
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func pulseMenuBar() {
        menuBarPulsing = true
        let token = transferPulseID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if transferPulseID == token {
                menuBarPulsing = false
            }
        }
    }

    func uploadDroppedFiles(_ urls: [URL]) {
        guard !settings.normalizedHost.isEmpty else {
            setError("Pick an SSH host first.")
            return
        }
        guard !isConnecting else {
            setError("Connecting… try again in a moment.")
            return
        }

        var files: [URL] = []
        var skipped = 0
        for url in urls {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists && !isDir.boolValue {
                files.append(url)
            } else {
                skipped += 1
            }
        }

        guard !files.isEmpty else {
            setError(skipped > 0 ? "Folders can't be uploaded. Drop files instead." : "Nothing to upload.")
            return
        }

        Task {
            var paths: [String] = []
            for url in files {
                let before = lastUpload?.remotePath
                await uploadPipeline(.rawFile(url), force: true)
                if let path = lastUpload?.remotePath, path != before {
                    paths.append(path)
                }
            }

            guard !paths.isEmpty else {
                return
            }

            if settings.autoCopyPath {
                copyToClipboard(paths.joined(separator: "\n"))
            }
            statusKind = .success
            if paths.count == 1 {
                statusText = settings.autoCopyPath ? "Uploaded and copied remote path." : "Uploaded."
            } else {
                statusText = settings.autoCopyPath
                    ? "Uploaded \(paths.count) files and copied their paths."
                    : "Uploaded \(paths.count) files."
            }
            if skipped > 0 {
                statusText += " Skipped \(skipped) folder\(skipped == 1 ? "" : "s")."
            }
        }
    }

    func silentlyCheckHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        readinessByHost[trimmed] = .checking
        var snapshot = settings
        snapshot.host = trimmed
        Task {
            let result = await uploader.testConnection(settings: snapshot)
            readinessByHost[trimmed] = result == "Connection OK." ? .ready : .failed(result)
        }
    }

    func readiness(for host: String) -> ReadinessStatus {
        readinessByHost[host.trimmingCharacters(in: .whitespacesAndNewlines)] ?? .unknown
    }

    private func startWatchers() {
        stopWatchers()

        if settings.monitorClipboard {
            let watcher = ClipboardWatcher { [weak self] data in
                Task { @MainActor in
                    await self?.uploadPipeline(.pngData(data, suggestedName: self?.settings.generatedFilename() ?? "clipboard.png"))
                }
            }
            watcher.start()
            clipboardWatcher = watcher
        }

        if settings.monitorScreenshots {
            let watcher = ScreenshotWatcher(folder: settings.screenshotFolderURL) { [weak self] url in
                Task { @MainActor in
                    await self?.uploadPipeline(.localFile(url))
                }
            }
            watcher.start()
            screenshotWatcher = watcher
        }

        statusText = "On. Copy a screenshot, then paste the remote path."
        statusKind = .ready
    }

    private func stopWatchers() {
        clipboardWatcher?.stop()
        clipboardWatcher = nil
        screenshotWatcher?.stop()
        screenshotWatcher = nil
        statusText = "Paused."
        statusKind = .ready
    }

    private func restartWatchers() {
        startWatchers()
    }

    private func addRecentUpload(_ upload: LastUpload) {
        recentUploads.removeAll { $0.remotePath == upload.remotePath }
        recentUploads.insert(upload, at: 0)
        if recentUploads.count > 100 {
            recentUploads.removeLast(recentUploads.count - 100)
        }
        saveRecentUploads()
    }

    private static func loadRecentUploads() -> [LastUpload] {
        guard let data = UserDefaults.standard.data(forKey: recentUploadsKey),
              let uploads = try? JSONDecoder().decode([LastUpload].self, from: data) else {
            return []
        }
        return uploads.sorted { $0.date > $1.date }
    }

    private func saveRecentUploads() {
        guard let data = try? JSONEncoder().encode(recentUploads) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.recentUploadsKey)
    }

    private func showFirstSuccessIfNeeded(for host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        var hosts = Set(UserDefaults.standard.stringArray(forKey: Self.firstSuccessHostsKey) ?? [])
        guard !hosts.contains(trimmed) else {
            return
        }
        hosts.insert(trimmed)
        UserDefaults.standard.set(Array(hosts), forKey: Self.firstSuccessHostsKey)
        showFirstSuccess = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            showFirstSuccess = false
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func setError(_ message: String) {
        statusText = message
        statusKind = .error
    }

    private func ensureSSHConfig() -> URL {
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let configURL = sshDir.appendingPathComponent("config")
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: configURL.path) {
            FileManager.default.createFile(atPath: configURL.path, contents: nil)
        }
        return configURL
    }

    private struct SSHHostBlock {
        let range: Range<Int>
        let lines: [String]
    }

    private func hostBlock(for host: String, in lines: [String]) -> SSHHostBlock? {
        var start: Int?
        var end = lines.count

        for index in lines.indices {
            let parts = lines[index]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            let isHostLine = parts.first?.lowercased() == "host"

            if isHostLine {
                if let startIndex = start {
                    end = index
                    return SSHHostBlock(range: startIndex..<end, lines: Array(lines[startIndex..<end]))
                }
                if parts.dropFirst().contains(host) {
                    start = index
                }
            }
        }

        guard let start else {
            return nil
        }
        return SSHHostBlock(range: start..<end, lines: Array(lines[start..<end]))
    }

    private func sshConfigBlock(alias: String, hostName: String, user: String, port: String, preservingFrom originalHost: String?) -> String {
        var preserved: [String] = []
        if let originalHost,
           let text = try? String(contentsOf: ensureSSHConfig(), encoding: .utf8),
           let block = hostBlock(for: originalHost, in: text.components(separatedBy: .newlines)) {
            for line in block.lines.dropFirst() {
                let key = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first?
                    .lowercased()
                if key != "hostname" && key != "user" && key != "port" && key != nil {
                    preserved.append(line)
                }
            }
        }

        var lines = ["Host \(alias)", "    HostName \(hostName)"]
        if !user.isEmpty {
            lines.append("    User \(user)")
        }
        if !port.isEmpty {
            lines.append("    Port \(port)")
        }
        lines.append(contentsOf: preserved)
        return lines.joined(separator: "\n")
    }

    private func sanitizeAlias(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { char in
                if char.isLetter || char.isNumber || char == "-" || char == "_" || char == "." {
                    return char
                }
                return "-"
            }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }
}
