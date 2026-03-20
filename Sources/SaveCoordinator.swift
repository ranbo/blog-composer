import Foundation
import AppKit

class SaveCoordinator {
    private static let lastFilePathKey = "LastFilePath"
    enum SaveError: Error, LocalizedError {
        case noFilePath
        case directoryCreationFailed
        case imageSaveFailed(String)
        case htmlSaveFailed

        var errorDescription: String? {
            switch self {
            case .noFilePath:
                return "No file path specified for saving"
            case .directoryCreationFailed:
                return "Failed to create directory structure"
            case .imageSaveFailed(let filename):
                return "Failed to save image: \(filename)"
            case .htmlSaveFailed:
                return "Failed to save HTML file"
            }
        }
    }

    // Save entry to disk
    static func save(entry: BlogEntry, isManualSave: Bool, domain: String? = nil) throws {
        guard let filePath = entry.filePath else {
            throw SaveError.noFilePath
        }

        let baseURL = filePath.deletingLastPathComponent()
        let htmlURL = filePath

        // 1. Ensure directory structure exists
        do {
            try FileManager.default.createBlogDirectoryStructure(at: baseURL)
        } catch {
            throw SaveError.directoryCreationFailed
        }

        // 2. Build image map from filenames (images are already on disk from the import pipeline)
        var imageMap: [UUID: String] = [:]
        for item in entry.items {
            if case .image(let imageItem) = item {
                imageMap[imageItem.id] = imageItem.filename
            }
        }

        // 3. Convert entry to HTML
        let html = HTMLConverter.convert(entry: entry, imageMap: imageMap, domain: domain)

        // 4. Create snapshot if manual save
        if isManualSave {
            let snapshotURL = baseURL.appendingPathComponent("snapshot.html")
            do {
                try FileManager.default.atomicSave(content: html, to: snapshotURL)
            } catch {
                // Don't fail the save if snapshot fails
                print("Warning: Failed to create snapshot: \(error)")
            }
        }

        // 5. Atomic save HTML file
        do {
            try FileManager.default.atomicSave(content: html, to: htmlURL)
        } catch {
            throw SaveError.htmlSaveFailed
        }

        // 6. Update entry state
        entry.isDirty = false

        // 7. Save path to UserDefaults
        saveLastFilePath(htmlURL)
    }

    // Save the last used file path to UserDefaults
    static func saveLastFilePath(_ path: URL) {
        UserDefaults.standard.set(path.path, forKey: lastFilePathKey)
    }

    // Load the last used file path from UserDefaults
    static func loadLastFilePath() -> URL? {
        guard let pathString = UserDefaults.standard.string(forKey: lastFilePathKey) else {
            return nil
        }
        return URL(fileURLWithPath: pathString)
    }

    // Initialize entry with a default file path
    static func initializeDefaultPath(for entry: BlogEntry) {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Journal/Drafts/untitled")

        let htmlPath = defaultPath.appendingPathComponent("index.html")
        entry.filePath = htmlPath

        // Create directory structure
        try? FileManager.default.createBlogDirectoryStructure(at: defaultPath)

        // Create empty HTML file if it doesn't exist
        if !FileManager.default.fileExists(atPath: htmlPath.path) {
            let emptyHTML = HTMLConverter.convert(entry: entry, imageMap: [:])
            try? FileManager.default.atomicSave(content: emptyHTML, to: htmlPath)
        }

        // Save path to UserDefaults
        saveLastFilePath(htmlPath)
    }

    // Update entry path to a new folder name
    static func updatePath(for entry: BlogEntry, newFolderName: String) throws {
        let sanitized = FileManager.sanitizeFolderName(newFolderName)

        guard let currentPath = entry.filePath else {
            // If no current path, initialize with the new name
            let newPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Journal/Drafts/\(sanitized)")
            let htmlPath = newPath.appendingPathComponent("index.html")

            entry.filePath = htmlPath
            try FileManager.default.createBlogDirectoryStructure(at: newPath)

            entry.isDirty = true
            return
        }

        let oldBaseURL = currentPath.deletingLastPathComponent()
        let oldFolderName = oldBaseURL.lastPathComponent

        // If the name hasn't changed, do nothing
        if oldFolderName == sanitized {
            return
        }

        // Rename the folder (also migrates legacy <name>.html → index.html)
        let newBaseURL = try FileManager.default.renameBlogEntry(
            from: oldBaseURL,
            to: sanitized
        )

        // Update entry's file path (always index.html)
        let newHTMLPath = newBaseURL.appendingPathComponent("index.html")
        entry.filePath = newHTMLPath

        // Save path to UserDefaults
        saveLastFilePath(newHTMLPath)

        // Mark as dirty so it gets saved
        entry.isDirty = true
    }
}
