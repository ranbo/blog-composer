import Foundation
import ImageIO

class TravelBlogPublisher {

    static let travelBlogDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Journal/TravelBlog")

    // MARK: - Publish Entry

    /// Publishes the entry to TravelBlog.
    /// - If the entry is a draft (in Drafts/): moves the folder to TravelBlog/ and returns the new URL.
    /// - If the entry is already in TravelBlog/: regenerates web images and index without moving.
    /// Returns the URL of the published HTML file.
    static func publish(entry: BlogEntry, date: Date, domain: String? = nil) throws -> URL {
        guard let filePath = entry.filePath else {
            throw PublishError.noFilePath
        }
        let baseURL = filePath.deletingLastPathComponent()
        let draftFolderName = baseURL.lastPathComponent

        // Check if already published (lives in TravelBlog/)
        let isInTravelBlog = baseURL.deletingLastPathComponent().standardized.path
            == travelBlogDir.standardized.path
        if isInTravelBlog {
            // Already in TravelBlog — just regenerate
            try generateMissingWebImages(in: baseURL)
            try ensureUtilFiles()
            try regenerateIndex(domain: domain)
            return filePath
        }

        // Draft: build destination folder name (add date prefix if not already present)
        let destFolderName: String
        if draftFolderName.range(of: #"^\d{4}-\d{2}-\d{2}_"#, options: .regularExpression) != nil {
            destFolderName = draftFolderName
        } else {
            let dateStr = formatDate(date)
            destFolderName = "\(dateStr)_\(draftFolderName)"
        }

        let destDir = travelBlogDir.appendingPathComponent(destFolderName)
        try FileManager.default.createDirectory(at: travelBlogDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destDir.path) {
            // Destination already exists: merge then remove draft
            try updatePublished(from: baseURL, to: destDir,
                                draftFolderName: draftFolderName)
            try FileManager.default.removeItem(at: baseURL)
        } else {
            // First publish: MOVE the draft folder to TravelBlog
            try FileManager.default.moveItem(at: baseURL, to: destDir)
            // Migrate legacy <draftFolderName>.html → index.html if needed
            let legacyHTML = destDir.appendingPathComponent("\(draftFolderName).html")
            let indexHTML = destDir.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: legacyHTML.path)
                && !FileManager.default.fileExists(atPath: indexHTML.path) {
                try FileManager.default.moveItem(at: legacyHTML, to: indexHTML)
            }
        }

        try generateMissingWebImages(in: destDir)
        try ensureUtilFiles()
        try regenerateIndex(domain: domain)

        return destDir.appendingPathComponent("index.html")
    }

    /// Merges changes from a draft folder into an already-published TravelBlog folder.
    private static func updatePublished(from src: URL, to dest: URL,
                                        draftFolderName: String) throws {
        // Overwrite the HTML file (prefer index.html, fall back to legacy)
        let srcIndex = src.appendingPathComponent("index.html")
        let srcLegacy = src.appendingPathComponent("\(draftFolderName).html")
        let srcHTML = FileManager.default.fileExists(atPath: srcIndex.path) ? srcIndex : srcLegacy

        let destHTML = dest.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: destHTML.path) {
            try FileManager.default.removeItem(at: destHTML)
        }
        try FileManager.default.copyItem(at: srcHTML, to: destHTML)

        // Copy any new image files into full/, small/, web/
        for subdir in ["full", "small", "web"] {
            let srcDir = src.appendingPathComponent(subdir)
            let destSubdir = dest.appendingPathComponent(subdir)
            guard FileManager.default.fileExists(atPath: srcDir.path) else { continue }
            try? FileManager.default.createDirectory(at: destSubdir, withIntermediateDirectories: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: srcDir, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let destFile = destSubdir.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destFile.path) {
                    try? FileManager.default.copyItem(at: file, to: destFile)
                }
            }
        }
    }

    /// Returns all YYYY-MM-DD_* article directories in TravelBlog/.
    static var articleDirectories: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: travelBlogDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)) ?? []
        return contents.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
            let name = url.lastPathComponent
            return name != "util" && name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
        }
    }

    /// Renames any *.JPG (or other uppercase variants) to *.jpg in `dir`.
    /// GCS is case-sensitive, so uppercase extensions break web links that reference *.jpg.
    private static func normalizeJpegExtensions(in dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for fileURL in files {
            let ext = fileURL.pathExtension
            guard ext != "jpg", ext.lowercased() == "jpg" else { continue }
            let lowered = fileURL.deletingPathExtension().appendingPathExtension("jpg")
            // On a case-insensitive FS this is a real rename (updates directory entry case).
            try? FileManager.default.moveItem(at: fileURL, to: lowered)
        }
    }

    /// Generates small/ JPEG (640px) for any image in full/ that lacks a small/<base>.jpg.
    /// Repairs articles where full/ files were incorrectly stored in small/ with their original extension.
    static func generateMissingSmallImages(in folderURL: URL) {
        let fullDir  = folderURL.appendingPathComponent("full")
        let smallDir = folderURL.appendingPathComponent("small")
        guard FileManager.default.fileExists(atPath: fullDir.path) else { return }
        try? FileManager.default.createDirectory(at: smallDir, withIntermediateDirectories: true)
        normalizeJpegExtensions(in: smallDir)

        let fullFiles = (try? FileManager.default.contentsOfDirectory(
            at: fullDir, includingPropertiesForKeys: nil)) ?? []

        for fileURL in fullFiles {
            let base = (fileURL.lastPathComponent as NSString).deletingPathExtension
            let smallFile = smallDir.appendingPathComponent("\(base).jpg")
            guard !FileManager.default.fileExists(atPath: smallFile.path) else { continue }

            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { continue }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { continue }
            let dest = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            try? (dest as Data).write(to: smallFile)
        }
    }

    /// Generates web/ JPEG (1600px) for any image in full/ that lacks one.
    static func generateMissingWebImages(in folderURL: URL) throws {
        let fullDir = folderURL.appendingPathComponent("full")
        let webDir = folderURL.appendingPathComponent("web")
        guard FileManager.default.fileExists(atPath: fullDir.path) else { return }
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        normalizeJpegExtensions(in: webDir)

        let fullFiles = (try? FileManager.default.contentsOfDirectory(
            at: fullDir, includingPropertiesForKeys: nil)) ?? []

        for fileURL in fullFiles {
            let base = (fileURL.lastPathComponent as NSString).deletingPathExtension
            let webFile = webDir.appendingPathComponent("\(base).jpg")
            guard !FileManager.default.fileExists(atPath: webFile.path) else { continue }

            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { continue }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { continue }
            let dest = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.90] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            try? (dest as Data).write(to: webFile)
        }
    }

    // MARK: - GCS Sync

    /// Progress update emitted while a full sync is running.
    struct SyncProgressUpdate: Sendable {
        /// Files transferred so far.
        let completed: Int
        /// Total files to transfer; nil while gcloud is still scanning.
        let total: Int?
        /// Relative path of the file just copied (nil for pure [N/M] updates).
        let lastFile: String?
    }

    /// Syncs the entire TravelBlog folder to a GCS bucket, streaming progress.
    static func sync(bucketName: String,
                     onProgress: @escaping (SyncProgressUpdate) -> Void) async throws {
        try await runGcloudWithProgress([
            "storage", "rsync",
            travelBlogDir.path,
            "gs://\(bucketName)",
            "--recursive",
            "--delete-unmatched-destination-objects",
            "--exclude=.*/full/",
            "--exclude=snapshot\\.html$",
            "--cache-control=no-cache"
        ], bucketName: bucketName, onProgress: onProgress)
    }

    /// Uploads only the article's index.html and the root index.html — no image scanning.
    /// Used by "Update" for fast HTML-only pushes; run a full Sync to upload new images.
    static func uploadArticleHTML(folderURL: URL, bucketName: String) async throws {
        let folderName = folderURL.lastPathComponent

        let articleIndex = folderURL.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: articleIndex.path) {
            try await runGcloud([
                "storage", "cp",
                "--cache-control=no-cache",
                articleIndex.path,
                "gs://\(bucketName)/\(folderName)/index.html"
            ])
        }

        let rootIndex = travelBlogDir.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: rootIndex.path) {
            try await runGcloud([
                "storage", "cp",
                "--cache-control=no-cache",
                rootIndex.path,
                "gs://\(bucketName)/index.html"
            ])
        }
    }

    /// Moves all objects under `oldFolder/` to `newFolder/` within GCS (server-side copy+delete).
    static func moveGCSFolder(oldFolder: String, newFolder: String, bucketName: String) async throws {
        try await runGcloud([
            "storage", "mv",
            "gs://\(bucketName)/\(oldFolder)",
            "gs://\(bucketName)/\(newFolder)",
            "--recursive"
        ])
    }

    /// Syncs a single published article folder to GCS, then uploads the root
    /// index.html and util/ so the index stays current.
    static func syncArticle(folderURL: URL, bucketName: String) async throws {
        let folderName = folderURL.lastPathComponent

        // 1. Always explicitly upload index.html — rsync uses checksum comparison and
        //    can incorrectly skip a file whose GCS-side metadata hasn't been invalidated.
        let articleIndex = folderURL.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: articleIndex.path) {
            try await runGcloud([
                "storage", "cp",
                "--cache-control=no-cache",
                articleIndex.path,
                "gs://\(bucketName)/\(folderName)/index.html"
            ])
        }

        // 2. Sync the rest of the article folder (images, etc.; skip full-resolution originals)
        try await runGcloud([
            "storage", "rsync",
            folderURL.path,
            "gs://\(bucketName)/\(folderName)",
            "--recursive",
            "--exclude=.*/full/",
            "--cache-control=no-cache"
        ])

        // 3. Upload the root index.html
        let rootIndex = travelBlogDir.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: rootIndex.path) {
            try await runGcloud([
                "storage", "cp",
                "--cache-control=no-cache",
                rootIndex.path,
                "gs://\(bucketName)/index.html"
            ])
        }

        // 4. Sync util/ (lightbox assets)
        let utilDir = travelBlogDir.appendingPathComponent("util")
        if FileManager.default.fileExists(atPath: utilDir.path) {
            try await runGcloud([
                "storage", "rsync",
                utilDir.path,
                "gs://\(bucketName)/util",
                "--recursive",
                "--cache-control=no-cache"
            ])
        }
    }

    /// Runs a gcloud subcommand, throwing PublishError.syncFailed on non-zero exit.
    private static func runGcloud(_ args: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gcloud"] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Drain both pipes concurrently on background threads. Without this, gcloud can
        // stall when its output exceeds the OS pipe buffer (~64 KB), causing a deadlock
        // where the process blocks on write while this side blocks waiting for termination.
        let outTask = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        let errData = await errTask.value
        _ = await outTask.value

        if process.terminationStatus != 0 {
            let output = String(data: errData, encoding: .utf8) ?? "(no output)"
            throw PublishError.syncFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Runs a gcloud rsync subcommand, streaming stderr line-by-line to `onProgress`.
    /// Parses "[N/M files]" lines for determinate progress and "Copying …" lines for filenames.
    private static func runGcloudWithProgress(
        _ args: [String],
        bucketName: String,
        onProgress: @escaping (SyncProgressUpdate) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gcloud"] + args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        // All mutable state accessed only while holding this lock.
        let parser = GCloudOutputParser(bucketName: bucketName, onProgress: onProgress)

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            parser.append(data)
        }
        // Discard stdout to prevent the pipe buffer from filling and blocking gcloud.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try process.run()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                // Stop readabilityHandler, then drain any remaining bytes on the main queue
                // (after all previously queued readabilityHandler dispatches have run).
                errPipe.fileHandleForReading.readabilityHandler = nil
                let tail = errPipe.fileHandleForReading.readDataToEndOfFile()
                DispatchQueue.main.async {
                    if !tail.isEmpty { parser.append(tail) }
                    parser.flush()
                    continuation.resume()
                }
            }
        }

        if process.terminationStatus != 0 {
            throw PublishError.syncFailed(parser.collectedOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? "(no output)" : parser.collectedOutput)
        }
    }

    // MARK: - GCloudOutputParser

    /// Thread-safe parser for gcloud stderr output.
    /// All `onProgress` callbacks are dispatched to the main queue.
    private final class GCloudOutputParser: @unchecked Sendable {
        private let lock = NSLock()
        private var lineBuffer = ""
        private var completed  = 0
        private var total: Int? = nil
        private(set) var collectedOutput = ""

        private let bucketName: String
        private let onProgress: (SyncProgressUpdate) -> Void

        init(bucketName: String, onProgress: @escaping (SyncProgressUpdate) -> Void) {  // called on main queue
            self.bucketName = bucketName
            self.onProgress = onProgress
        }

        func append(_ data: Data) {
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            lineBuffer      += chunk
            collectedOutput += chunk
            let lines = drainLines()
            lock.unlock()
            for line in lines { dispatch(line: line) }
        }

        func flush() {
            lock.lock()
            let remaining = lineBuffer.trimmingCharacters(in: .whitespaces)
            lineBuffer = ""
            lock.unlock()
            if !remaining.isEmpty { dispatch(line: remaining) }
        }

        // Called while lock is held; returns complete lines.
        private func drainLines() -> [String] {
            var out: [String] = []
            while let idx = lineBuffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
                let line = String(lineBuffer[..<idx])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: idx)...])
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(line) }
            }
            return out
        }

        private func dispatch(line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }

            // "[3/50 files][  1.5 MiB/20.3 MiB]   7% Done"
            if let (n, m) = parseFileCounts(trimmed) {
                lock.lock(); completed = n; total = m; lock.unlock()
                let u = SyncProgressUpdate(completed: n, total: m, lastFile: nil)
                DispatchQueue.main.async { self.onProgress(u) }
                return
            }

            // "Copying file:///…/TravelBlog/article/web/img.jpg to gs://bucket/article/web/img.jpg"
            if trimmed.lowercased().hasPrefix("copying ") {
                let relPath = extractRelativePath(from: trimmed)
                lock.lock(); completed += 1; let c = completed; let t = total; lock.unlock()
                let u = SyncProgressUpdate(completed: c, total: t, lastFile: relPath)
                DispatchQueue.main.async { self.onProgress(u) }
            }
        }

        /// Parses "[N/M files]" → (N, M).
        private func parseFileCounts(_ s: String) -> (Int, Int)? {
            guard let r = s.range(of: #"\[(\d+)/(\d+)\s*files\]"#, options: .regularExpression) else { return nil }
            let nums = String(s[r]).components(separatedBy: CharacterSet.decimalDigits.inverted)
                .filter { !$0.isEmpty }
            guard nums.count >= 2, let n = Int(nums[0]), let m = Int(nums[1]) else { return nil }
            return (n, m)
        }

        /// Extracts a short relative path from a "Copying src to gs://bucket/path" line.
        private func extractRelativePath(from line: String) -> String {
            // Try to get the GCS destination path and strip "gs://bucket/"
            let parts = line.components(separatedBy: " to ")
            if parts.count >= 2 {
                let dest = parts[1].trimmingCharacters(in: .whitespaces)
                let prefix = "gs://\(bucketName)/"
                if dest.hasPrefix(prefix) {
                    return String(dest.dropFirst(prefix.count))
                }
                return (dest as NSString).lastPathComponent
            }
            // Fallback: last path component of the source
            let src = line.replacingOccurrences(of: "(?i)^copying\\s+", with: "",
                                                 options: .regularExpression)
                .components(separatedBy: " to ").first ?? line
            return (src.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        }
    }

    // MARK: - Index Generation

    /// Scans TravelBlog/ and regenerates index.html from all YYYY-MM-DD_* folders.
    /// When `domain` is provided, also rewrites each article's <h1> title to link to its
    /// canonical URL (https://domain/folder/).
    static func regenerateIndex(domain: String? = nil) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: travelBlogDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)

        // Collect entries: [(folderName, date, title)]
        var entries: [(folder: String, date: String, title: String)] = []
        let datePattern = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2})_"#)

        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folderName = url.lastPathComponent
            guard folderName != "util" else { continue }

            // Must start with YYYY-MM-DD_
            let range = NSRange(folderName.startIndex..., in: folderName)
            guard let match = datePattern.firstMatch(in: folderName, range: range) else { continue }

            let dateStr = (folderName as NSString).substring(with: match.range(at: 1))

            // Read title from the HTML file (prefer index.html, fall back to legacy)
            let indexURL = url.appendingPathComponent("index.html")
            let legacyURL = url.appendingPathComponent("\(folderName).html")
            let htmlFile = FileManager.default.fileExists(atPath: indexURL.path) ? indexURL : legacyURL
            let title = readTitle(from: htmlFile) ?? folderName

            // Fix the article's <h1> self-link if a domain is provided
            if let domain = domain, !domain.isEmpty {
                fixTitleLink(in: htmlFile, folderName: folderName, domain: domain)
            }

            // Rewrite legacy full/ image hrefs → web/ and non-jpg small/ srcs → .jpg
            fixLegacyImageLinks(in: htmlFile)

            // Strip the inline <style> block that is now covered by blog.css
            removeInlineStyleBlock(in: htmlFile)

            entries.append((folder: folderName, date: dateStr, title: title))
        }

        // Sort newest-first
        entries.sort { $0.date > $1.date }

        // Generate index HTML
        let html = buildIndexHTML(entries: entries)
        let indexURL = travelBlogDir.appendingPathComponent("index.html")
        try html.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    /// Rewrites the first <h1> in `htmlFile` so it links to the article's canonical URL.
    /// Handles both plain <h1>Title</h1> and Blogger-style <h1><a href="...blogger...">Title</a></h1>.
    private static func fixTitleLink(in htmlFile: URL, folderName: String, domain: String) {
        guard var content = try? String(contentsOf: htmlFile, encoding: .utf8) else { return }
        let targetURL = "https://\(domain)/\(folderName)/"

        guard let h1Regex = try? NSRegularExpression(pattern: #"<h1[^>]*>([\s\S]*?)</h1>"#) else { return }
        let fullRange = NSRange(content.startIndex..., in: content)
        guard let match = h1Regex.firstMatch(in: content, range: fullRange) else { return }

        // Strip inner tags to get the plain-text (but HTML-entity-preserved) title
        let innerRange = Range(match.range(at: 1), in: content)!
        let innerHTML = String(content[innerRange])
        guard let stripTagsRegex = try? NSRegularExpression(pattern: "<[^>]+>") else { return }
        let titleText = stripTagsRegex.stringByReplacingMatches(
            in: innerHTML,
            range: NSRange(innerHTML.startIndex..., in: innerHTML),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !titleText.isEmpty else { return }

        // Skip if the <h1> already links to the correct URL
        let existingH1 = (content as NSString).substring(with: match.range)
        if existingH1.contains("href=\"\(targetURL)\"") || existingH1.contains("href='\(targetURL)'") { return }

        let newH1 = "<h1><a href=\"\(targetURL)\" style=\"text-decoration: none; color: inherit;\">\(titleText)</a></h1>"
        if let matchRange = Range(match.range, in: content) {
            content.replaceSubrange(matchRange, with: newH1)
            try? content.write(to: htmlFile, atomically: true, encoding: .utf8)
        }
    }

    /// Patches legacy image links in-place:
    /// - `<a href="full/foo.ext"...>` → `href="web/foo.jpg" class="lightbox-link"` (adds class if absent)
    /// - `src="small/foo.ext"` (non-jpg) → `src="small/foo.jpg"`
    private static func fixLegacyImageLinks(in htmlFile: URL) {
        guard var content = try? String(contentsOf: htmlFile, encoding: .utf8) else { return }
        var changed = false

        // Fix <a ...href="full/foo.ext"...> — remap href to web/, add class="lightbox-link" if absent
        if let re = try? NSRegularExpression(pattern: #"<a\b([^>]*)href="full/([^"]+)"([^>]*)>"#) {
            let matches = re.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches.reversed() {
                guard let fullRange  = Range(match.range,       in: content),
                      let preRange   = Range(match.range(at: 1), in: content),
                      let fileRange  = Range(match.range(at: 2), in: content),
                      let postRange  = Range(match.range(at: 3), in: content) else { continue }
                let pre      = String(content[preRange])
                let filename = String(content[fileRange])
                let post     = String(content[postRange])
                let base     = (filename as NSString).deletingPathExtension
                let hasClass = pre.contains("class=") || post.contains("class=")
                let classAttr = hasClass ? "" : " class=\"lightbox-link\""
                content.replaceSubrange(fullRange,
                    with: "<a\(pre)href=\"web/\(base).jpg\"\(classAttr)\(post)>")
                changed = true
            }
        }

        // Fix src="small/foo.ext" (non-jpg) → src="small/foo.jpg"
        if let re = try? NSRegularExpression(pattern: #"src="small/([^"]+)""#) {
            let matches = re.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches.reversed() {
                guard let fullRange  = Range(match.range,       in: content),
                      let fileRange  = Range(match.range(at: 1), in: content) else { continue }
                let filename = String(content[fileRange])
                guard (filename as NSString).pathExtension != "jpg" else { continue }
                let base = (filename as NSString).deletingPathExtension
                content.replaceSubrange(fullRange, with: "src=\"small/\(base).jpg\"")
                changed = true
            }
        }

        if changed {
            try? content.write(to: htmlFile, atomically: true, encoding: .utf8)
        }
    }

    /// Removes the app-generated inline <style> block from `htmlFile` if present.
    /// Identified by the distinctive `body { font-family: Georgia` signature.
    /// Safe to run on legacy Blogger articles — they don't contain this block.
    private static func removeInlineStyleBlock(in htmlFile: URL) {
        guard var content = try? String(contentsOf: htmlFile, encoding: .utf8) else { return }
        guard let re = try? NSRegularExpression(
            pattern: #"[ \t]*<style>\s*body \{ font-family: Georgia[\s\S]*?</style>\n?"#)
        else { return }
        let range = NSRange(content.startIndex..., in: content)
        let stripped = re.stringByReplacingMatches(in: content, range: range, withTemplate: "")
        if stripped != content {
            try? stripped.write(to: htmlFile, atomically: true, encoding: .utf8)
        }
    }

    private static func readTitle(from htmlURL: URL) -> String? {
        guard let content = try? String(contentsOf: htmlURL, encoding: .utf8) else { return nil }
        guard let start = content.range(of: "<title>"),
              let end = content.range(of: "</title>", range: start.upperBound..<content.endIndex) else {
            return nil
        }
        let raw = String(content[start.upperBound..<end.lowerBound])
        return raw.isEmpty ? nil : ArticleManager.unescapeHTML(raw)
    }

    private static func buildIndexHTML(entries: [(folder: String, date: String, title: String)]) -> String {
        // Group by year
        var yearGroups: [(year: String, entries: [(folder: String, date: String, title: String)])] = []
        var currentYear = ""
        for entry in entries {
            let year = String(entry.date.prefix(4))
            if year != currentYear {
                currentYear = year
                yearGroups.append((year: year, entries: []))
            }
            yearGroups[yearGroups.count - 1].entries.append(entry)
        }

        var rows = ""
        for group in yearGroups {
            rows += "    <tr class='year-row' data-year='\(group.year)' onclick='toggleYear(\"\(group.year)\")'><td colspan=2>\(group.year)</td></tr>\n"
            rows += "    <tr class='width-keeper row-\(group.year)'><td class='date-cell'>9999-99-99</td><td>placeholder</td></tr>\n"
            for e in group.entries {
                let escapedTitle = e.title
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "'", with: "&#39;")
                let path = "\(e.folder)/index.html"
                rows += "    <tr class='row-\(group.year)' onclick=\"selectRow(this, '\(path)')\"><td class=\"date-cell\">\(e.date)</td><td><a href='\(path)' target='_blank'>\(escapedTitle)</a></td></tr>\n"
            }
        }

        return """
        <html>
        <head>
          <meta charset="UTF-8">
          <title>Travel Blog</title>
          <style>
            body { margin: 0; padding: 0; }
            .container { display: flex; height: 100vh; }
            .table-pane { flex-basis: 550px; flex-shrink: 0; flex-grow: 0; min-width: 200px; overflow-y: auto; }
            .divider { width: 5px; background: #ccc; cursor: ew-resize; position: relative; z-index: 10; }
            .iframe-pane { flex: 1 1 0; overflow-y: auto; }
            .year-row { background: #eee; font-weight: bold; cursor: pointer; }
            .width-keeper { visibility: collapse; height: 0 !important; padding: 0 !important; border: none !important; }
            .hidden { display: none; }
            a { text-decoration: none; }
            tr.selected { background: #d0eaff; }
            .date-cell { width: 80px; white-space: nowrap; }
          </style>
          <script>
            function toggleYear(year) {
              var rows = document.querySelectorAll('.row-' + year);
              var hidden = false;
              for (var i = 0; i < rows.length; i++) {
                if (!rows[i].classList.contains('hidden')) { hidden = true; break; }
              }
              for (var i = 0; i < rows.length; i++) {
                if (hidden) rows[i].classList.add('hidden'); else rows[i].classList.remove('hidden');
              }
            }
            function selectRow(row, htmlFile) {
              var selected = document.querySelector('tr.selected');
              if (selected) selected.classList.remove('selected');
              row.classList.add('selected');
              document.getElementById('reading-pane').src = htmlFile;
            }
            window.onload = function() {
              var divider = document.getElementById('divider');
              var container = document.querySelector('.container');
              var tablePane = document.querySelector('.table-pane');
              var isDragging = false, startX, startWidth;
              var overlay = document.createElement('div');
              overlay.style.cssText = 'position:fixed;top:0;left:0;width:100vw;height:100vh;z-index:9999;cursor:ew-resize';
              divider.addEventListener('mousedown', function(e) {
                isDragging = true; startX = e.clientX; startWidth = tablePane.offsetWidth;
                document.body.appendChild(overlay); e.preventDefault();
              });
              document.addEventListener('mousemove', function(e) {
                if (!isDragging) return;
                var newWidth = Math.min(Math.max(startWidth + e.clientX - startX, 200), container.offsetWidth - 200);
                tablePane.style.flexBasis = newWidth + 'px';
              });
              document.addEventListener('mouseup', function() {
                if (isDragging) { isDragging = false; if (overlay.parentNode) overlay.parentNode.removeChild(overlay); }
              });
              document.addEventListener('keydown', function(e) {
                var iframe = document.getElementById('reading-pane');
                var selected = document.querySelector('tr.selected');
                if (e.key === 'Escape') { if (selected) selected.classList.remove('selected'); iframe.src = ''; }
                else if ((e.key === 'ArrowUp' || e.key === 'ArrowDown') && selected) {
                  e.preventDefault();
                  var rows = Array.from(document.querySelectorAll('tr[class*="row-"]:not(.year-row):not(.width-keeper):not(.hidden)'));
                  var idx = rows.indexOf(selected);
                  var next = e.key === 'ArrowUp' ? rows[idx - 1] : rows[idx + 1];
                  if (next) { selected.classList.remove('selected'); next.classList.add('selected'); iframe.src = next.getAttribute('onclick').match(/'([^']+)'/)[1]; }
                }
              });
            };
          </script>
        </head>
        <body>
        <div class="container">
          <div class="table-pane">
            <table style="width:100%;border-collapse:collapse;">
        \(rows)
            </table>
          </div>
          <div class="divider" id="divider"></div>
          <div class="iframe-pane">
            <iframe id="reading-pane" style="width:100%;height:100%;border:none;" src=""></iframe>
          </div>
        </div>
        </body>
        </html>
        """
    }

    // MARK: - Util files (lightbox)

    static func ensureUtilFiles() throws {
        let utilDir = travelBlogDir.appendingPathComponent("util")
        try FileManager.default.createDirectory(at: utilDir, withIntermediateDirectories: true)

        let cssURL = utilDir.appendingPathComponent("lightbox.css")
        let jsURL = utilDir.appendingPathComponent("lightbox.js")

        if !FileManager.default.fileExists(atPath: cssURL.path) {
            try lightboxCSS.write(to: cssURL, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: jsURL.path) {
            try lightboxJS.write(to: jsURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private static func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    // MARK: - Errors

    enum PublishError: Error, LocalizedError {
        case noFilePath
        case syncFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFilePath:
                return "No file path — save the entry first"
            case .syncFailed(let msg):
                return "GCS sync failed: \(msg)"
            }
        }
    }
}

// MARK: - Lightbox assets (embedded)

private let lightboxCSS = """
#lb-overlay {
  display: none;
  position: fixed;
  inset: 0;
  background: rgba(0,0,0,0.88);
  z-index: 9999;
  align-items: center;
  justify-content: center;
}
#lb-img {
  max-width: 90vw;
  max-height: 90vh;
  object-fit: contain;
  display: block;
  user-select: none;
}
#lb-prev, #lb-next {
  position: fixed;
  top: 50%;
  transform: translateY(-50%);
  background: rgba(255,255,255,0.15);
  border: none;
  color: white;
  font-size: 3rem;
  line-height: 1;
  padding: 0.15em 0.5em;
  cursor: pointer;
  user-select: none;
  z-index: 10000;
  border-radius: 4px;
  transition: background 0.15s;
}
#lb-prev { left: 1rem; }
#lb-next { right: 1rem; }
#lb-prev:hover, #lb-next:hover { background: rgba(255,255,255,0.35); }
#lb-counter {
  position: fixed;
  bottom: 1.5rem;
  left: 50%;
  transform: translateX(-50%);
  color: rgba(255,255,255,0.7);
  font-family: -apple-system, sans-serif;
  font-size: 0.9rem;
  pointer-events: none;
}
#lb-close {
  position: fixed;
  top: 1rem;
  right: 1rem;
  background: rgba(255,255,255,0.15);
  border: none;
  color: white;
  font-size: 1.4rem;
  cursor: pointer;
  border-radius: 50%;
  width: 2.2rem;
  height: 2.2rem;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: background 0.15s;
}
#lb-close:hover { background: rgba(255,255,255,0.35); }
"""

private let lightboxJS = """
(function () {
  var overlay, img, counter, prevBtn, nextBtn;
  var links = [];
  var current = 0;

  function build() {
    overlay = document.createElement('div');
    overlay.id = 'lb-overlay';

    prevBtn = document.createElement('button');
    prevBtn.id = 'lb-prev';
    prevBtn.innerHTML = '&#8249;';

    nextBtn = document.createElement('button');
    nextBtn.id = 'lb-next';
    nextBtn.innerHTML = '&#8250;';

    img = document.createElement('img');
    img.id = 'lb-img';

    counter = document.createElement('div');
    counter.id = 'lb-counter';

    var closeBtn = document.createElement('button');
    closeBtn.id = 'lb-close';
    closeBtn.innerHTML = '&#10005;';

    overlay.appendChild(prevBtn);
    overlay.appendChild(img);
    overlay.appendChild(nextBtn);
    overlay.appendChild(counter);
    overlay.appendChild(closeBtn);
    document.body.appendChild(overlay);

    prevBtn.addEventListener('click', function (e) { e.stopPropagation(); navigate(-1); });
    nextBtn.addEventListener('click', function (e) { e.stopPropagation(); navigate(1); });
    closeBtn.addEventListener('click', close);
    overlay.addEventListener('click', function (e) { if (e.target === overlay) close(); });

    // Touch: tap left half = prev, right half = next
    overlay.addEventListener('touchend', function (e) {
      if (e.target === img) {
        navigate(e.changedTouches[0].clientX < window.innerWidth / 2 ? -1 : 1);
      }
    });

    document.addEventListener('keydown', function (e) {
      if (overlay.style.display !== 'flex') return;
      if (e.key === 'ArrowLeft') navigate(-1);
      else if (e.key === 'ArrowRight') navigate(1);
      else if (e.key === 'Escape') close();
    });
  }

  function open(index) {
    current = index;
    if (!overlay) build();
    overlay.style.display = 'flex';
    show();
  }

  function show() {
    img.src = links[current].getAttribute('href');
    counter.textContent = (current + 1) + ' / ' + links.length;
    prevBtn.style.visibility = links.length > 1 ? 'visible' : 'hidden';
    nextBtn.style.visibility = links.length > 1 ? 'visible' : 'hidden';
  }

  function navigate(dir) {
    current = (current + dir + links.length) % links.length;
    show();
  }

  function close() {
    overlay.style.display = 'none';
    img.src = '';
  }

  window.addEventListener('DOMContentLoaded', function () {
    links = Array.from(document.querySelectorAll('a.lightbox-link'));
    links.forEach(function (link, i) {
      link.addEventListener('click', function (e) {
        e.preventDefault();
        open(i);
      });
    });
  });
})();
"""
