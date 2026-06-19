import Foundation

enum SSHConfigHosts {
    static func load() -> [String] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
            .appendingPathComponent("config")

        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }

        var hosts: [String] = []
        let ignoredPatterns = CharacterSet(charactersIn: "*?")

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard line.lowercased().hasPrefix("host ") else {
                continue
            }

            let aliases = line.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\t" })
            for alias in aliases {
                let value = String(alias)
                guard value.rangeOfCharacter(from: ignoredPatterns) == nil else {
                    continue
                }
                hosts.append(value)
            }
        }

        return Array(Set(hosts)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
