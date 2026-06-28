import CryptoKit
import Foundation

struct UploadResult: Sendable {
    let remotePath: String
    let filename: String
}

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum SSHUploaderError: LocalizedError {
    case missingHost
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHost:
            "Enter an SSH host in Settings first."
        case .commandFailed(let message):
            message
        }
    }
}

actor SSHUploader {
    private var cachedHome: [String: String] = [:]
    private var ensuredDirs: Set<String> = []

    func upload(localURL: URL, filename: String, settings: Settings) async throws -> UploadResult {
        guard !settings.normalizedHost.isEmpty else {
            throw SSHUploaderError.missingHost
        }

        let remoteDir = try await resolveRemoteDir(settings: settings)
        let ensureKey = "\(settings.displayTarget)|\(remoteDir)"
        if !ensuredDirs.contains(ensureKey) {
            try await ensureDir(remoteDir, settings: settings)
            ensuredDirs.insert(ensureKey)
        }
        if settings.cleanupDays > 0 {
            // Best-effort: a cron hiccup must never block the actual upload.
            _ = try? await configureCleanup(remoteDir: remoteDir, settings: settings)
        }
        let remotePath = joinRemote(remoteDir, filename)
        do {
            try await scp(localURL: localURL, remotePath: remotePath, settings: settings)
        } catch {
            // The remote dir may have been removed mid-session; re-verify next time.
            ensuredDirs.remove(ensureKey)
            throw error
        }
        if settings.cleanupDays > 0 {
            try? await runCleanupOnce(remoteDir: remoteDir, settings: settings)
        }
        return UploadResult(remotePath: remotePath, filename: filename)
    }

    func testConnection(settings: Settings) async -> String {
        guard !settings.normalizedHost.isEmpty else {
            return "Enter an SSH host first."
        }

        do {
            let result = try await run(
                executable: "/usr/bin/ssh",
                arguments: sshBaseArgs(settings: settings) + [settings.hostTarget, "--", "true"]
            )
            if result.status == 0 {
                do {
                    let remoteDir = try await resolveRemoteDir(settings: settings)
                    try await ensureDir(remoteDir, settings: settings)
                    ensuredDirs.insert("\(settings.displayTarget)|\(remoteDir)")
                    if settings.cleanupDays > 0 {
                        // Cleanup is auxiliary; don't fail the check over it.
                        _ = try? await configureCleanup(remoteDir: remoteDir, settings: settings)
                    }
                } catch {
                    return error.localizedDescription
                }
                return "Connection OK."
            }
            return mapError(status: result.status, stderr: combinedOutput(result))
        } catch {
            return error.localizedDescription
        }
    }

    func updateCleanupPolicy(settings: Settings) async -> String {
        guard !settings.normalizedHost.isEmpty else {
            return "Enter an SSH host first."
        }

        do {
            let remoteDir = try await resolveRemoteDir(settings: settings)
            try await ensureDir(remoteDir, settings: settings)
            ensuredDirs.insert("\(settings.displayTarget)|\(remoteDir)")
            let outcome = try await configureCleanup(remoteDir: remoteDir, settings: settings)
            if settings.cleanupDays > 0 {
                return outcome == .cronUnavailable
                    ? "Remote cleanup saved, but this host has no cron service, so scheduled deletion won't run automatically."
                    : "Remote cleanup enabled for files older than \(settings.cleanupDays) days."
            }
            return "Remote cleanup disabled."
        } catch {
            return error.localizedDescription
        }
    }

    private func resolveRemoteDir(settings: Settings) async throws -> String {
        let configured = settings.effectiveRemoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.hasPrefix("/") {
            return normalizeRemotePath(configured)
        }

        let cacheKey = "\(settings.displayTarget)"
        let home: String
        if let cached = cachedHome[cacheKey] {
            home = cached
        } else {
            let result = try await run(
                executable: "/usr/bin/ssh",
                arguments: sshBaseArgs(settings: settings) + [settings.hostTarget, "--", "printf", "%s", "$HOME"]
            )
            guard result.status == 0 else {
                throw SSHUploaderError.commandFailed(mapError(status: result.status, stderr: combinedOutput(result)))
            }
            let resolved = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else {
                throw SSHUploaderError.commandFailed("Could not resolve the remote home directory.")
            }
            cachedHome[cacheKey] = resolved
            home = resolved
        }

        let cleaned: String
        if configured == "~" {
            cleaned = ""
        } else if configured.hasPrefix("~/") {
            cleaned = String(configured.dropFirst(2))
        } else {
            cleaned = configured
        }
        return normalizeRemotePath(joinRemote(home, cleaned.isEmpty ? "paste2ssh" : cleaned))
    }

    private func ensureDir(_ remoteDir: String, settings: Settings) async throws {
        let command = "/bin/mkdir -p -- \(shellQuote(remoteDir))"
        let result = try await run(
            executable: "/usr/bin/ssh",
            arguments: sshBaseArgs(settings: settings) + [
                settings.hostTarget,
                "--",
                command
            ]
        )
        guard result.status == 0 else {
            throw SSHUploaderError.commandFailed(mapError(status: result.status, stderr: combinedOutput(result)))
        }
    }

    private func scp(localURL: URL, remotePath: String, settings: Settings) async throws {
        let remoteTarget = "\(settings.hostTarget):\(remotePath)"
        // Large screenshots over a slow uplink need more headroom than the
        // quick control commands; the connection itself is bounded by ConnectTimeout.
        let transferTimeout: TimeInterval = 120
        let result = try await run(
            executable: "/usr/bin/scp",
            arguments: scpBaseArgs(settings: settings) + [localURL.path, remoteTarget],
            timeout: transferTimeout
        )
        if result.status == 0 {
            return
        }

        // Modern scp speaks SFTP. Some servers (dropbear, or no sftp-server
        // installed) only support the legacy transfer protocol, so retry with -O.
        let lower = combinedOutput(result).lowercased()
        let looksLikeProtocol = lower.contains("subsystem")
            || lower.contains("sftp")
            || lower.contains("protocol")
            || lower.contains("expand-path")
        if looksLikeProtocol {
            let legacy = try await run(
                executable: "/usr/bin/scp",
                arguments: ["-O"] + scpBaseArgs(settings: settings) + [localURL.path, remoteTarget],
                timeout: transferTimeout
            )
            if legacy.status == 0 {
                return
            }
            throw SSHUploaderError.commandFailed(mapError(status: legacy.status, stderr: combinedOutput(legacy)))
        }

        throw SSHUploaderError.commandFailed(mapError(status: result.status, stderr: combinedOutput(result)))
    }

    private enum CleanupOutcome {
        case applied
        case cronUnavailable
    }

    @discardableResult
    private func configureCleanup(remoteDir: String, settings: Settings) async throws -> CleanupOutcome {
        let days = settings.cleanupDays
        let marker = cleanupMarker(settings: settings, remoteDir: remoteDir)
        let scriptPath = joinRemote(remoteDir, ".paste2ssh-cleanup.sh")
        let command = days > 0
            ? installCleanupCommand(remoteDir: remoteDir, scriptPath: scriptPath, days: days, marker: marker)
            : removeCleanupCommand(scriptPath: scriptPath, marker: marker)
        let result = try await run(
            executable: "/usr/bin/ssh",
            arguments: sshBaseArgs(settings: settings) + [settings.hostTarget, "--", command]
        )
        guard result.status == 0 else {
            throw SSHUploaderError.commandFailed(mapError(status: result.status, stderr: combinedOutput(result)))
        }
        return result.stdout.contains("PASTE2SSH_CRON_MISSING") ? .cronUnavailable : .applied
    }

    private func runCleanupOnce(remoteDir: String, settings: Settings) async throws {
        let scriptPath = joinRemote(remoteDir, ".paste2ssh-cleanup.sh")
        let result = try await run(
            executable: "/usr/bin/ssh",
            arguments: sshBaseArgs(settings: settings) + [settings.hostTarget, "--", "/bin/sh -- \(shellQuote(scriptPath))"]
        )
        guard result.status == 0 else {
            throw SSHUploaderError.commandFailed(mapError(status: result.status, stderr: combinedOutput(result)))
        }
    }

    /// Private, app-owned dir for SSH ControlMaster sockets. Re-created on every use
    /// (createDirectory is a no-op when it already exists): macOS can purge
    /// ~/Library/Caches at any time, and if we only created it once per launch a
    /// purge would make every ssh/scp fail the socket bind with "No such file or
    /// directory" until the app restarted. Kept short (under Caches) for the
    /// ~104-char unix-socket path limit; 0700 because ssh refuses world-writable
    /// ControlPath dirs.
    private func controlSocketDirectory() -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Paste2SSH/cm", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return dir
        } catch {
            return nil
        }
    }

    /// Connection-multiplexing options shared by ssh and scp. We compute a short
    /// 8-hex token ourselves (instead of ssh's `%C`, which is 40 chars) so the
    /// socket path stays well under the ~104-char Unix limit even for long home
    /// dirs — and identical across ssh + scp for the same target. Returns [] if the
    /// cache dir can't be made, so uploads still work (just non-multiplexed).
    /// NOTE: an over-long ControlPath makes ssh hard-fail (exit 255), not fall back,
    /// so keeping this short is correctness, not just tidiness.
    private func controlArgs(settings: Settings) -> [String] {
        guard let path = controlPath(for: settings) else {
            return []
        }
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(path)",
            "-o", "ControlPersist=120"
        ]
    }

    private func controlPath(for settings: Settings) -> String? {
        guard let dir = controlSocketDirectory() else {
            return nil
        }
        let token = SHA256.hash(data: Data(settings.displayTarget.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        return dir.appendingPathComponent("cm-\(token)").path
    }

    private func sshBaseArgs(settings: Settings) -> [String] {
        var args = controlArgs(settings: settings) + [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if let port = settings.port {
            args += ["-p", String(port)]
        }
        return args
    }

    private func scpBaseArgs(settings: Settings) -> [String] {
        var args = controlArgs(settings: settings) + [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if let port = settings.port {
            args += ["-P", String(port)]
        }
        return args
    }

    /// Closes a host's multiplexed master connection (best-effort) and forgets its
    /// "dir ensured" cache, so a later session re-verifies. Called when switching
    /// hosts or turning Paste Mode off.
    func closeMaster(settings: Settings) async {
        guard !settings.normalizedHost.isEmpty else {
            return
        }
        ensuredDirs = ensuredDirs.filter { !$0.hasPrefix("\(settings.displayTarget)|") }
        _ = try? await run(
            executable: "/usr/bin/ssh",
            arguments: sshBaseArgs(settings: settings) + ["-O", "exit", settings.hostTarget],
            timeout: 5
        )
    }

    private func run(executable: String, arguments: [String], timeout: TimeInterval = 20) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    let semaphore = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in
                        semaphore.signal()
                    }

                    try process.run()
                    let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
                    if timedOut {
                        process.terminate()
                        _ = semaphore.wait(timeout: .now() + 2)
                    }

                    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: ProcessResult(status: timedOut ? 124 : process.terminationStatus, stdout: stdout, stderr: stderr))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func mapError(status: Int32, stderr: String) -> String {
        let lower = stderr.lowercased()
        let firstLine = stderr
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? "No error output."

        if lower.contains("unix_listener") || lower.contains("mux_client") || lower.contains("control socket") || lower.contains("controlpath") {
            // Local connection-multiplexing failure (e.g. the ControlPath socket dir
            // was purged). Prints "No such file or directory" but is unrelated to the
            // remote folder — must be caught before the "not writable" branch.
            return "Local SSH connection setup failed. Please try again."
        }
        if lower.contains("remote host identification has changed") || lower.contains("possible dns spoofing") {
            return "The host key changed since you last connected. If you trust this host, run ssh-keygen -R for it in Terminal, then reconnect."
        }
        if lower.contains("host key verification failed") {
            return "Host key verification failed. Try connecting once in Terminal with ssh."
        }
        if lower.contains("tailscale ssh requires an additional check") || lower.contains("login.tailscale.com") {
            if let url = extractFirstURL(from: stderr) {
                return "Tailscale SSH needs approval: \(url)"
            }
            return "Tailscale SSH needs approval. Connect to this host once in Terminal and approve the login request."
        }
        if lower.contains("permission denied") || lower.contains("publickey") {
            return "SSH authentication failed. Confirm your key or agent works in Terminal."
        }
        if lower.contains("connection refused") {
            return "Connection refused. Check the host and SSH port."
        }
        if lower.contains("no route") || lower.contains("could not resolve") || lower.contains("name or service not known") {
            return "Could not reach that SSH host. Check the hostname or network."
        }
        if lower.contains("timed out") || lower.contains("operation timed out") {
            return "SSH connection timed out."
        }
        if status == 124 {
            return "SSH command timed out."
        }
        if lower.contains("too many authentication failures") {
            return "The server rejected too many keys. Add IdentitiesOnly yes for this host in ~/.ssh/config."
        }
        if lower.contains("no space left") {
            return "The remote disk is full. Free up space on the server, then try again."
        }
        if lower.contains("kex_exchange_identification") || lower.contains("connection closed by remote host") {
            return "The server closed the connection. It may be blocking your IP (firewall/fail2ban) or not running SSH on this port."
        }
        if lower.contains("missing operand") {
            return "Could not create the remote upload folder."
        }
        if lower.contains("not writable") || lower.contains("read-only file system") || lower.contains("cannot create directory") {
            return "The remote upload directory is not writable."
        }
        if lower.contains("subsystem") || lower.contains("protocol") || lower.contains("expand-path") {
            return "SFTP upload failed. Check that the server supports SFTP."
        }
        if lower.contains("connection reset") || lower.contains("connection lost") || lower.contains("broken pipe") || lower.contains("client_loop") {
            return "The SSH connection dropped. Check your network or VPN (e.g. Tailscale), then try again."
        }

        return "SSH error (code \(status)): \(firstLine)"
    }

    private func joinRemote(_ base: String, _ component: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedComponent.isEmpty {
            return "/\(trimmedBase)"
        }
        return "/\(trimmedBase)/\(trimmedComponent)"
    }

    private func normalizeRemotePath(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : "/\(path)"
        var parts: [String] = []
        for part in absolute.split(separator: "/") {
            if part == "." || part.isEmpty {
                continue
            }
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(String(part))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private func cleanupMarker(settings: Settings, remoteDir: String) -> String {
        let raw = "\(settings.displayTarget)-\(remoteDir)"
        let sanitized = raw.map { char -> Character in
            if char.isLetter || char.isNumber || char == "-" || char == "_" {
                return char
            }
            return "-"
        }
        return String(sanitized).prefix(80).description
    }

    private func installCleanupCommand(remoteDir: String, scriptPath: String, days: Int, marker: String) -> String {
        let begin = "# Paste2SSH cleanup begin \(marker)"
        let end = "# Paste2SSH cleanup end \(marker)"
        let safeDays = max(1, min(days, 3650))
        let script = """
        #!/bin/sh
        set -eu
        DIR=\(shellQuote(remoteDir))
        DAYS=\(safeDays)
        [ -d "$DIR" ] || exit 0
        find "$DIR" -maxdepth 1 -type f \\( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.gif' -o -name '*.webp' \\) -mtime +"$DAYS" -delete
        """
        return """
        set -eu
        mkdir -p -- \(shellQuote(remoteDir))
        cat > \(shellQuote(scriptPath)) <<'PASTE2SSH_CLEANUP'
        \(script)
        PASTE2SSH_CLEANUP
        chmod 700 -- \(shellQuote(scriptPath))
        if command -v crontab >/dev/null 2>&1; then
          existing="$(crontab -l 2>/dev/null || true)"
          filtered="$(printf '%s\\n' "$existing" | awk -v begin=\(shellQuote(begin)) -v end=\(shellQuote(end)) 'BEGIN{skip=0} $0==begin{skip=1; next} $0==end{skip=0; next} skip==0{print}')"
          {
            printf '%s\\n' "$filtered" | sed '/^[[:space:]]*$/d'
            printf '%s\\n' \(shellQuote(begin))
            printf '%s\\n' "17 3 * * * /bin/sh \(shellQuote(scriptPath)) >/dev/null 2>&1"
            printf '%s\\n' \(shellQuote(end))
          } | crontab -
        else
          printf '%s\\n' PASTE2SSH_CRON_MISSING
        fi
        """
    }

    private func removeCleanupCommand(scriptPath: String, marker: String) -> String {
        let begin = "# Paste2SSH cleanup begin \(marker)"
        let end = "# Paste2SSH cleanup end \(marker)"
        return """
        set -eu
        if command -v crontab >/dev/null 2>&1; then
          existing="$(crontab -l 2>/dev/null || true)"
          filtered="$(printf '%s\\n' "$existing" | awk -v begin=\(shellQuote(begin)) -v end=\(shellQuote(end)) 'BEGIN{skip=0} $0==begin{skip=1; next} $0==end{skip=0; next} skip==0{print}')"
          if [ -n "$(printf '%s\\n' "$filtered" | sed '/^[[:space:]]*$/d')" ]; then
            printf '%s\\n' "$filtered" | crontab -
          else
            crontab -r 2>/dev/null || true
          fi
        fi
        rm -f -- \(shellQuote(scriptPath))
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func combinedOutput(_ result: ProcessResult) -> String {
        [result.stderr, result.stdout]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func extractFirstURL(from text: String) -> String? {
        guard let range = text.range(of: #"https?://[^\s]+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
    }
}
