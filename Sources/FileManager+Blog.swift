import Foundation
import AppKit
import ImageIO

extension FileManager {
    // Atomically save content to a file
    func atomicSave(content: String, to url: URL) throws {
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp_\(UUID().uuidString).html")

        // Write to temporary file
        try content.write(to: tmpURL, atomically: true, encoding: .utf8)

        // Replace original file with temporary file
        if fileExists(atPath: url.path) {
            _ = try replaceItemAt(url, withItemAt: tmpURL)
        } else {
            try moveItem(at: tmpURL, to: url)
        }
    }

    // Save a 640px-resized image to small/ as JPEG thumbnail (ImageIO path — handles HEIC, JPG, etc.)
    func saveSmallImage(at sourceURL: URL, filename: String, to baseURL: URL) throws {
        let smallDir = baseURL.appendingPathComponent("small")
        try createDirectory(at: smallDir, withIntermediateDirectories: true)

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }

        let dest = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }

        let baseFilename = (filename as NSString).deletingPathExtension
        let smallPath = smallDir.appendingPathComponent("\(baseFilename).jpg")
        try (dest as Data).write(to: smallPath)
    }

    // Save a 1600px-resized image to web/ as JPEG — browser-compatible version for lightbox
    func saveWebImage(at sourceURL: URL, filename: String, to baseURL: URL) throws {
        let webDir = baseURL.appendingPathComponent("web")
        try createDirectory(at: webDir, withIntermediateDirectories: true)

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }

        let dest = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.90] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }

        let baseFilename = (filename as NSString).deletingPathExtension
        let webPath = webDir.appendingPathComponent("\(baseFilename).jpg")
        try (dest as Data).write(to: webPath)
    }

    // Create directory structure for blog entry
    func createBlogDirectoryStructure(at baseURL: URL) throws {
        try createDirectory(at: baseURL, withIntermediateDirectories: true)
        try createDirectory(at: baseURL.appendingPathComponent("full"), withIntermediateDirectories: true)
        try createDirectory(at: baseURL.appendingPathComponent("small"), withIntermediateDirectories: true)
        try createDirectory(at: baseURL.appendingPathComponent("web"), withIntermediateDirectories: true)
    }

    // Rename blog entry folder. HTML file is always index.html so no rename needed.
    // If a legacy <oldName>.html exists, it is renamed to index.html.
    func renameBlogEntry(from oldURL: URL, to newFolderName: String) throws -> URL {
        let parentDir = oldURL.deletingLastPathComponent()
        let newURL = parentDir.appendingPathComponent(newFolderName)

        // Check if new directory already exists
        if fileExists(atPath: newURL.path) {
            throw NSError(domain: "BlogComposer", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "A folder with that name already exists"])
        }

        // Rename the folder
        try moveItem(at: oldURL, to: newURL)

        // Migrate legacy <oldFolderName>.html → index.html if index.html doesn't exist yet
        let oldFilename = oldURL.lastPathComponent
        let legacyHTMLPath = newURL.appendingPathComponent("\(oldFilename).html")
        let indexHTMLPath = newURL.appendingPathComponent("index.html")

        if fileExists(atPath: legacyHTMLPath.path) && !fileExists(atPath: indexHTMLPath.path) {
            try moveItem(at: legacyHTMLPath, to: indexHTMLPath)
        }

        return newURL
    }

    // Read caption from image file's IPTC or XMP metadata.
    // Tries IPTC Caption/Abstract first, then XMP dc:description.
    static func readCaption(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // IPTC Caption/Abstract
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any],
           let caption = iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String {
            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.lowercased() != "default" { return trimmed }
        }

        // XMP dc:description — try plain string, then first element of alt-text array
        // Note: some cameras/apps write "default" as a placeholder (leaking the XMP
        // xml:lang="x-default" language qualifier); treat it the same as empty.
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            let paths = ["dc:description", "dc:description[1]"]
            for path in paths {
                if let value = CGImageMetadataCopyStringValueWithPath(
                    metadata, nil, path as CFString) as String? {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed.lowercased() != "default" { return trimmed }
                }
            }
        }

        return nil
    }

    // Sanitize folder name
    static func sanitizeFolderName(_ name: String) -> String {
        var sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Replace invalid characters with underscores
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        sanitized = sanitized.components(separatedBy: invalidChars).joined(separator: "_")

        // Ensure it's not empty
        if sanitized.isEmpty {
            sanitized = "untitled"
        }

        return sanitized
    }
}
