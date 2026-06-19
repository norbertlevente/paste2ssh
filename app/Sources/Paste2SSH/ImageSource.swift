import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum ImageInput: Sendable {
    case localFile(URL)
    case pngData(Data, suggestedName: String)
    case rawFile(URL)
}

struct PreparedImage: Sendable {
    let localURL: URL
    let displayName: String
}

enum ImageSourceError: LocalizedError {
    case noImageOnClipboard
    case couldNotEncodeImage
    case noScreenshotFound

    var errorDescription: String? {
        switch self {
        case .noImageOnClipboard:
            "No image found on the clipboard."
        case .couldNotEncodeImage:
            "Could not convert the image to PNG."
        case .noScreenshotFound:
            "No screenshot image found in the selected folder."
        }
    }
}

enum ImageSource {
    static func clipboardHasImage() -> Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil {
            return true
        }
        if NSImage(pasteboard: pasteboard) != nil {
            return true
        }
        return clipboardImageFileURL() != nil
    }

    static func clipboardPNGData() throws -> Data {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) {
            return data
        }
        if let fileURL = clipboardImageFileURL(), let image = NSImage(contentsOf: fileURL) {
            return try pngData(from: image)
        }
        if let tiff = pasteboard.data(forType: .tiff), let image = NSImage(data: tiff) {
            return try pngData(from: image)
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return try pngData(from: image)
        }
        throw ImageSourceError.noImageOnClipboard
    }

    static func latestScreenshot(in folder: URL) throws -> URL {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            throw ImageSourceError.noScreenshotFound
        }

        var newest: (url: URL, date: Date)?
        let allowed = Set(["png", "jpg", "jpeg", "heic"])

        for case let url as URL in enumerator {
            guard allowed.contains(url.pathExtension.lowercased()) else {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            let modified = values.contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.date {
                newest = (url, modified)
            }
        }

        guard let newest else {
            throw ImageSourceError.noScreenshotFound
        }
        return newest.url
    }

    static func prepare(_ input: ImageInput, filename: String) throws -> PreparedImage {
        switch input {
        case .localFile(let url), .rawFile(let url):
            return PreparedImage(localURL: url, displayName: url.lastPathComponent)
        case .pngData(let data, let suggestedName):
            let safeName = suggestedName.isEmpty ? filename : suggestedName
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Paste2SSH", isDirectory: true)
                .appendingPathComponent(safeName)
            try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: tempURL, options: .atomic)
            return PreparedImage(localURL: tempURL, displayName: safeName)
        }
    }

    static func hash(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Sanitized remote name for an arbitrary dropped file: keeps the original stem
    /// (letters/digits/`.`/`_`/`-`, others mapped to `-`) and original extension.
    /// Unlike `Settings.generatedFilename`, it does NOT force a `.png` extension.
    static func sanitizedRemoteName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let sanitized = stem.map { char -> Character in
            if char.isLetter || char.isNumber || char == "." || char == "_" || char == "-" {
                return char
            }
            return "-"
        }
        var name = String(sanitized)
        while name.contains("--") {
            name = name.replacingOccurrences(of: "--", with: "-")
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if name.isEmpty {
            name = "file-\(Int(Date().timeIntervalSince1970))"
        }

        let safeExt = url.pathExtension.filter { $0.isLetter || $0.isNumber }
        return safeExt.isEmpty ? name : "\(name).\(safeExt)"
    }

    private static func clipboardImageFileURL() -> URL? {
        let pasteboard = NSPasteboard.general
        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        return pasteboard.readObjects(forClasses: classes, options: options)?.first as? URL
    }

    private static func pngData(from image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageSourceError.couldNotEncodeImage
        }
        return png
    }
}
