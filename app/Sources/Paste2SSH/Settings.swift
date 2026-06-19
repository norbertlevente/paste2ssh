import Foundation

struct Settings: Codable, Equatable {
    var host: String
    var username: String
    var port: Int?
    var remoteDir: String
    var screenshotFolder: String
    var filenamePattern: String
    var monitorClipboard: Bool
    var monitorScreenshots: Bool
    var showNotifications: Bool
    var autoCopyPath: Bool
    var remoteDirsByHost: [String: String]
    var cleanupDays: Int
    var launchAtLogin: Bool

    enum CodingKeys: String, CodingKey {
        case host
        case username
        case port
        case remoteDir
        case screenshotFolder
        case filenamePattern
        case monitorClipboard
        case monitorScreenshots
        case showNotifications
        case autoCopyPath
        case remoteDirsByHost
        case cleanupDays
        case launchAtLogin
    }

    static let storageKey = "Paste2SSH.settings.v1"

    static var defaults: Settings {
        Settings(
            host: "",
            username: "",
            port: nil,
            remoteDir: "~/.paste2ssh",
            screenshotFolder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path,
            filenamePattern: "screenshot-{yyyyMMdd-HHmmss}.png",
            monitorClipboard: true,
            monitorScreenshots: false,
            showNotifications: false,
            autoCopyPath: true,
            remoteDirsByHost: [:],
            cleanupDays: 0,
            launchAtLogin: false
        )
    }

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return .defaults
        }

        do {
            var settings = try JSONDecoder().decode(Settings.self, from: data)
            if settings.remoteDir == "~/paste2ssh" {
                settings.remoteDir = "~/.paste2ssh"
                settings.save()
            }
            settings.showNotifications = false
            settings.monitorClipboard = true
            settings.monitorScreenshots = false
            return settings
        } catch {
            return .defaults
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    init(
        host: String,
        username: String,
        port: Int?,
        remoteDir: String,
        screenshotFolder: String,
        filenamePattern: String,
        monitorClipboard: Bool,
        monitorScreenshots: Bool,
        showNotifications: Bool,
        autoCopyPath: Bool,
        remoteDirsByHost: [String: String],
        cleanupDays: Int,
        launchAtLogin: Bool
    ) {
        self.host = host
        self.username = username
        self.port = port
        self.remoteDir = remoteDir
        self.screenshotFolder = screenshotFolder
        self.filenamePattern = filenamePattern
        self.monitorClipboard = monitorClipboard
        self.monitorScreenshots = monitorScreenshots
        self.showNotifications = showNotifications
        self.autoCopyPath = autoCopyPath
        self.remoteDirsByHost = remoteDirsByHost
        self.cleanupDays = cleanupDays
        self.launchAtLogin = launchAtLogin
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        remoteDir = try container.decodeIfPresent(String.self, forKey: .remoteDir) ?? defaults.remoteDir
        screenshotFolder = try container.decodeIfPresent(String.self, forKey: .screenshotFolder) ?? defaults.screenshotFolder
        filenamePattern = try container.decodeIfPresent(String.self, forKey: .filenamePattern) ?? defaults.filenamePattern
        monitorClipboard = try container.decodeIfPresent(Bool.self, forKey: .monitorClipboard) ?? defaults.monitorClipboard
        monitorScreenshots = try container.decodeIfPresent(Bool.self, forKey: .monitorScreenshots) ?? defaults.monitorScreenshots
        showNotifications = try container.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? defaults.showNotifications
        autoCopyPath = try container.decodeIfPresent(Bool.self, forKey: .autoCopyPath) ?? defaults.autoCopyPath
        remoteDirsByHost = try container.decodeIfPresent([String: String].self, forKey: .remoteDirsByHost) ?? defaults.remoteDirsByHost
        cleanupDays = try container.decodeIfPresent(Int.self, forKey: .cleanupDays) ?? defaults.cleanupDays
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
    }

    var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedUsername: String? {
        let value = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var hostTarget: String {
        guard let normalizedUsername else {
            return normalizedHost
        }
        return "\(normalizedUsername)@\(normalizedHost)"
    }

    var displayTarget: String {
        let portText = port.map { ":\($0)" } ?? ""
        return "\(hostTarget)\(portText)"
    }

    var effectiveRemoteDir: String {
        remoteDir(for: normalizedHost)
    }

    func remoteDir(for host: String) -> String {
        let key = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostDir = remoteDirsByHost[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultDir = remoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostDir.isEmpty ? (defaultDir.isEmpty ? "~/.paste2ssh" : defaultDir) : hostDir
    }

    var screenshotFolderURL: URL {
        URL(fileURLWithPath: NSString(string: screenshotFolder).expandingTildeInPath)
    }

    func generatedFilename(date: Date = Date()) -> String {
        var output = filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            output = "screenshot-{yyyyMMdd-HHmmss}.png"
        }

        let matches = output.matches(of: /\{([^}]+)\}/)
        for match in matches.reversed() {
            let format = String(match.1)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            output.replaceSubrange(match.range, with: formatter.string(from: date))
        }

        let sanitized = output.map { char -> Character in
            if char.isLetter || char.isNumber || char == "." || char == "_" || char == "-" {
                return char
            }
            return "-"
        }

        var filename = String(sanitized)
        while filename.contains("--") {
            filename = filename.replacingOccurrences(of: "--", with: "-")
        }
        filename = filename.trimmingCharacters(in: CharacterSet(charactersIn: "-."))

        if filename.isEmpty {
            filename = "screenshot-\(Int(date.timeIntervalSince1970)).png"
        }
        if URL(fileURLWithPath: filename).pathExtension.isEmpty {
            filename += ".png"
        }
        return filename
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
