// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation
import ImageIO

public class TravelBlogPublisher {

    public static let travelBlogDir = FileManager.default.homeDirectoryForCurrentUser
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

    /// Paths rsync must never upload, as one comma-separated value.
    ///
    /// Two things make this fiddly, and both have bitten us:
    ///   * `--exclude` takes a *list*; passing the flag twice keeps only the last one, so
    ///     the earlier pattern is silently dropped.  That put 12,000+ full-resolution
    ///     originals in the bucket while the code looked correct.
    ///   * The pattern is full-matched against the path *relative to the source*.  With the
    ///     TravelBlog root as source that is `entry/full/x.jpg`, but syncing a single
    ///     article it is just `full/x.jpg` — so `.*/full/` misses the second case, and a
    ///     trailing `.*` is needed because the match is not a prefix search.
    private static let rsyncExcludes = [
        "(.*/)?full/.*",        // full-resolution originals stay local
        "(.*/)?snapshot\\.html", // the editor's manual-save backups
        "(.*/)?\\.DS_Store",     // Finder droppings
        // Published to the same bucket but maintained outside TravelBlog.  Without this
        // the root sync's --delete-unmatched-destination-objects treats the whole section
        // as orphaned and deletes it, because nothing under TravelBlog corresponds to it.
        "bob/.*",
        // The welcome blurb is a source file baked into index.html at generate time —
        // there is nothing for a reader to open at /welcome.html.
        "(.*/)?welcome\\.html"
    ].joined(separator: ",")

    static func sync(bucketName: String,
                     onProgress: @escaping (SyncProgressUpdate) -> Void) async throws {
        try await runGcloudWithProgress([
            "storage", "rsync",
            travelBlogDir.path,
            "gs://\(bucketName)",
            "--recursive",
            "--delete-unmatched-destination-objects",
            "--exclude=\(rsyncExcludes)",
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
    /// Uploads only one article's index.html.  Used for a neighbour whose "Next episode"
    /// link changed because something newer was published — its images are already up.
    static func uploadIndexHTML(folder: String, bucketName: String) async throws {
        let file = travelBlogDir.appendingPathComponent(folder).appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try await runGcloud([
            "storage", "cp",
            "--cache-control=no-cache",
            file.path,
            "gs://\(bucketName)/\(folder)/index.html"
        ])
    }

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
            "--exclude=\(rsyncExcludes)",
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

        // 3b. Shared files at the TravelBlog root: blog.css, contact.js and the banner
        // images every episode's header links to.  Without this they only ever reached the
        // bucket on a full Sync, so a publish could put up a page whose stylesheet, banner
        // or contact address was stale.  No --recursive, so this is just the top-level
        // files; rsync compares them and uploads only what actually differs.
        try await runGcloud([
            "storage", "rsync",
            travelBlogDir.path,
            "gs://\(bucketName)",
            "--exclude=\(rsyncExcludes)",
            "--cache-control=no-cache"
        ])

        // 4. Sync util/ (lightbox assets)
        let utilDir = travelBlogDir.appendingPathComponent("util")
        if FileManager.default.fileExists(atPath: utilDir.path) {
            try await runGcloud([
                "storage", "rsync",
                utilDir.path,
                "gs://\(bucketName)/util",
                "--recursive",
                "--exclude=\(rsyncExcludes)",
                "--cache-control=no-cache"
            ])
        }
    }

    // MARK: - Locating gcloud

    /// Absolute path to the `gcloud` executable, or `nil` if it can't be found.
    ///
    /// An app bundle launched from Finder inherits launchd's PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), not the one from your shell profile.
    /// That excludes every directory the Google Cloud SDK installs into, so
    /// `/usr/bin/env gcloud` fails with "No such file or directory" even though
    /// gcloud works fine in Terminal.
    private static let gcloudURL: URL? = {
        let fm = FileManager.default

        // An explicit override wins, for installs in unusual places:
        //   defaults write com.randywilson.blogcomposer GCloudPath /path/to/gcloud
        if let custom = UserDefaults.standard.string(forKey: "GCloudPath"),
           !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }

        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/gcloud",
            "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
            "/usr/local/bin/gcloud",
            "/usr/local/share/google-cloud-sdk/bin/gcloud",
            "\(home)/google-cloud-sdk/bin/gcloud"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // Last resort: a login shell knows whatever PATH the user's profile sets.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: shell)
        probe.arguments = ["-lc", "command -v gcloud"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let found = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fm.isExecutableFile(atPath: found) ? URL(fileURLWithPath: found) : nil
    }()

    private static func resolvedGcloud() throws -> URL {
        guard let url = gcloudURL else {
            throw PublishError.syncFailed(
                "Could not find the gcloud command. Install the Google Cloud SDK, or point "
                + "the app at it with:\n\n    defaults write "
                + "com.randywilson.blogcomposer GCloudPath /path/to/gcloud")
        }
        return url
    }

    /// Environment for a gcloud subprocess.
    ///
    /// gcloud is a launcher script that has to find a Python interpreter. Under
    /// launchd's PATH it finds only macOS's Python 3.9 and refuses to run, so
    /// put its own directory and the usual package prefixes back on PATH.
    private static func gcloudEnvironment(for tool: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let preferred = [tool.deletingLastPathComponent().path,
                         "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (preferred + existing)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return env
    }

    /// Runs a gcloud subcommand, throwing PublishError.syncFailed on non-zero exit.
    private static func runGcloud(_ args: [String]) async throws {
        let process = Process()
        let tool = try resolvedGcloud()
        process.executableURL = tool
        process.arguments = args
        process.environment = gcloudEnvironment(for: tool)
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
        let tool = try resolvedGcloud()
        process.executableURL = tool
        process.arguments = args
        process.environment = gcloudEnvironment(for: tool)

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

// MARK: - Welcome blurb

    static let welcomeFileName = "welcome.html"

    private static let defaultWelcomeHTML = """
    <p class="site-intro">Welcome to Randy Wilson&#39;s travel blog. We love to explore the
    world and meet wonderful people wherever we go! And I&#39;m always on the lookout for
    good ice cream!</p>
    """

    /// Creates `welcome.html` with the default wording if it isn't there yet.  Never
    /// overwrites it: once it exists, the file is the copy that matters.
    static func ensureWelcomeFile() throws {
        let url = travelBlogDir.appendingPathComponent(welcomeFileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try defaultWelcomeHTML.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The blurb shown beside the banner, read from `welcome.html`.
    ///
    /// Anything starting with a tag is used as-is, so it can hold several paragraphs or a
    /// link; plain text is wrapped in the styled paragraph so the file can just be prose.
    static func welcomeHTML() -> String {
        let url = travelBlogDir.appendingPathComponent(welcomeFileName)
        let text = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return defaultWelcomeHTML }
        return text.hasPrefix("<") ? text : "<p class=\"site-intro\">\(text)</p>"
    }

    // MARK: - Shared contact script

    /// Writes `contact.js` at the TravelBlog root.
    ///
    /// The address is emitted as character codes and assembled at click time, so it is
    /// nowhere in any page as text — harvesters parse HTML, they don't run scripts.  Every
    /// page loads this one file, so changing the address in Preferences and re-publishing
    /// updates the whole site.  Any element with `data-contact` becomes a mail link.
// MARK: - Per-episode chrome

    // Both bands are wrapped in <div>, which HTMLParser ignores, so opening an article in
    // the editor never turns them into content.  A re-save drops them and the next
    // regenerateIndex puts them back, which also means they self-heal.
    private static let chromeTopStart = "<!-- episode-chrome-top -->"
    private static let chromeTopEnd = "<!-- /episode-chrome-top -->"
    private static let chromeBottomStart = "<!-- episode-chrome-bottom -->"
    private static let chromeBottomEnd = "<!-- /episode-chrome-bottom -->"

    /// Inserts or refreshes the banner at the top and the next/home links at the bottom.
    /// Returns true when the file changed, so the caller can upload just those articles.
    @discardableResult
    private static func applyEpisodeChrome(
        to htmlFile: URL,
        folder: String,
        next: (folder: String, title: String)?
    ) -> Bool {
        guard var html = try? String(contentsOf: htmlFile, encoding: .utf8) else { return false }
        let original = html

        // The links sit inside the index page's iframe, so they must break out of it.
        let top = """
        \(chromeTopStart)
          <div class="episode-header"><a href="../index.html?e=\(HTMLConverter.urlEncodePath(folder))" target="_top" title="Back to the index"><img src="../AdventuresHeader.png" alt="Adventures and Stuff"></a></div>
        \(chromeTopEnd)
        """

        var bottomLines = ["  <hr>"]
        if let next {
            // Points straight at the episode, so reading an article on its own goes to the
            // next article rather than bouncing through the index.  episode.js intercepts
            // this when we are the index's reading pane and drives the list instead.
            bottomLines.append("  <p class=\"next-episode\">Next episode: "
                + "<a href=\"../\(HTMLConverter.urlEncodePath(next.folder))/\""
                + " data-episode=\"\(escapeHTMLText(next.folder))\">"
                + escapeHTMLText(next.title) + "</a></p>")
        }
        // Carries this episode, so the index opens with it selected and ready for up/down.
        bottomLines.append("  <p class=\"home-link\">Home page: "
            + "<a href=\"../index.html?e=\(HTMLConverter.urlEncodePath(folder))\" target=\"_top\">"
            + "AdventuresAndStuff.com</a></p>")
        bottomLines.append("  <script src=\"../episode.js\"></script>")
        let bottom = """
        \(chromeBottomStart)
        <div class="episode-footer">
        \(bottomLines.joined(separator: "\n"))
        </div>
        \(chromeBottomEnd)
        """

        html = replacingBand(in: html, start: chromeTopStart, end: chromeTopEnd, with: top,
                             fallbackInsertAfter: "<body>")
        html = replacingBand(in: html, start: chromeBottomStart, end: chromeBottomEnd, with: bottom,
                             fallbackInsertBefore: ["<script>", "</body>"])

        guard html != original else { return false }
        try? html.write(to: htmlFile, atomically: true, encoding: .utf8)
        return true
    }

    /// Replaces the text between two markers, or inserts it if the markers aren't there yet.
    private static func replacingBand(
        in html: String,
        start: String,
        end: String,
        with replacement: String,
        fallbackInsertAfter: String? = nil,
        fallbackInsertBefore: [String]? = nil
    ) -> String {
        if let s = html.range(of: start), let e = html.range(of: end) {
            return html.replacingCharacters(in: s.lowerBound..<e.upperBound, with: replacement)
        }
        if let anchor = fallbackInsertAfter, let r = html.range(of: anchor) {
            return html.replacingCharacters(in: r.upperBound..<r.upperBound, with: "\n" + replacement)
        }
        if let anchors = fallbackInsertBefore {
            for anchor in anchors {
                if let r = html.range(of: anchor) {
                    return html.replacingCharacters(in: r.lowerBound..<r.lowerBound,
                                                    with: replacement + "\n")
                }
            }
        }
        return html
    }

    private static func escapeHTMLText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

/// Writes `episode.js` at the TravelBlog root, shared by every episode page.
    ///
    /// It makes the "Next episode" link do the right thing in both places an article is
    /// read: inside the index's reading pane it asks the index to select and load the next
    /// episode, so the list stays in step and the arrow keys carry on; opened on its own it
    /// just follows the link to that episode's page.
    static func writeEpisodeScript() throws {
        let js = """
        // Generated by BlogComposer — do not edit by hand.
        (function () {
          function onClick(e) {
            var a = e.target && e.target.closest ? e.target.closest("a[data-episode]") : null;
            if (!a) return;
            try {
              // Only when we are the index's reading pane; otherwise let the link navigate.
              if (window.parent !== window &&
                  typeof window.parent.selectEpisodeByFolder === "function") {
                if (window.parent.selectEpisodeByFolder(a.getAttribute("data-episode"))) {
                  e.preventDefault();
                }
              }
            } catch (err) {
              // A cross-origin parent throws on access; the plain link is the fallback.
            }
            // Episode links are folder URLs, which only a web server resolves to their
            // index.html; opened from disk, name the file.
            if (!e.defaultPrevented && location.protocol === "file:" && a.href.slice(-1) === "/") {
              e.preventDefault();
              location.href = a.href + "index.html";
            }
          }
          document.addEventListener("click", onClick);
        })();
        """
        let url = travelBlogDir.appendingPathComponent("episode.js")
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == js { return }
        try js.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeContactScript() throws {
        let address = Preferences.contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let codes = address.unicodeScalars.map { String($0.value) }.joined(separator: ",")
        let js = """
        // Generated by BlogComposer from the "Contact" setting — do not edit by hand.
        // The address is stored as character codes so it never appears as text in a page.
        (function () {
          var c = [\(codes)];
          if (!c.length) return;
          function address() {
            var s = "";
            for (var i = 0; i < c.length; i++) { s += String.fromCharCode(c[i]); }
            return s;
          }
          function wire() {
            var els = document.querySelectorAll("[data-contact]");
            for (var i = 0; i < els.length; i++) {
              els[i].addEventListener("click", function (e) {
                e.preventDefault();
                window.location.href = "mail" + "to:" + address();
              });
            }
          }
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", wire);
          } else {
            wire();
          }
        })();
        """
        let url = travelBlogDir.appendingPathComponent("contact.js")
        // Leave the file alone when nothing changed, so rsync has no reason to re-upload it.
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == js { return }
        try js.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Rebuilds the index and every episode's chrome.  Returns the folders whose
    /// article HTML changed, so a publish can upload exactly those.
    @discardableResult
    static func regenerateIndex(domain: String? = nil) throws -> [String] {
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

            // Published from Drafts, the file still points at ../../TravelBlog/ for its
            // stylesheet; from here that is one level above the site root.
            fixAssetPrefix(in: htmlFile)

            // A heading that links to the page you are on is noise; drop the anchor.
            unlinkSelfLinkedHeadings(in: htmlFile, folderName: folderName)

            // Rewrite legacy full/ image hrefs → web/ and non-jpg small/ srcs → .jpg
            fixLegacyImageLinks(in: htmlFile)

            // Strip the inline <style> block that is now covered by blog.css
            removeInlineStyleBlock(in: htmlFile)

            entries.append((folder: folderName, date: dateStr, title: title))
        }

        // Sort newest-first
        entries.sort { $0.date > $1.date }

        // Refresh each episode's banner and next/home links.  Doing it here, from the whole
        // sorted list, means publishing a new article automatically repairs the previous
        // one's "Next episode" link — and that any article that drifted is put right.
        var changedFolders: [String] = []
        for (i, e) in entries.enumerated() {
            // entries is newest-first, so the *next* episode chronologically is the one before.
            let next: (folder: String, title: String)? =
                i == 0 ? nil : (folder: entries[i - 1].folder, title: entries[i - 1].title)
            let dir = travelBlogDir.appendingPathComponent(e.folder)
            let indexURL = dir.appendingPathComponent("index.html")
            let legacyURL = dir.appendingPathComponent("\(e.folder).html")
            let htmlFile = FileManager.default.fileExists(atPath: indexURL.path) ? indexURL : legacyURL
            if applyEpisodeChrome(to: htmlFile, folder: e.folder, next: next) {
                changedFolders.append(e.folder)
            }
        }

        try writeContactScript()
        try writeEpisodeScript()
        try ensureWelcomeFile()

        // Generate index HTML
        let html = buildIndexHTML(entries: entries, welcome: welcomeHTML())
        let indexURL = travelBlogDir.appendingPathComponent("index.html")
        try html.write(to: indexURL, atomically: true, encoding: .utf8)
        return changedFolders
    }

    /// Rewrites the first <h1> in `htmlFile` so it links to the article's canonical URL.
    /// Handles both plain <h1>Title</h1> and Blogger-style <h1><a href="...blogger...">Title</a></h1>.
/// Repoints an article's stylesheet/asset links after it has been published.
    ///
    /// HTMLConverter derives the prefix from where the file sits: a draft reaches the
    /// shared assets via `../../TravelBlog/`, a published article via `../`.  Publishing
    /// saves the HTML *before* moving the folder out of Drafts, so the file arrives with
    /// the draft's prefix — which, served from the bucket root, resolves above it and
    /// 404s.  The page then renders with no stylesheet at all.
    private static func fixAssetPrefix(in htmlFile: URL) {
        guard var content = try? String(contentsOf: htmlFile, encoding: .utf8),
              content.contains("../../TravelBlog/") else { return }
        content = content.replacingOccurrences(of: "\"../../TravelBlog/", with: "\"../")
        content = content.replacingOccurrences(of: "'../../TravelBlog/", with: "'../")
        try? content.write(to: htmlFile, atomically: true, encoding: .utf8)
    }

    /// Removes self-referential links from an article's headings.
    ///
    /// A title that links to the page you are already reading goes nowhere useful.
    /// Downloaded articles linked theirs to the Blogger post and our own output linked it
    /// to itself; worse, the previous version of this matched the first <h1> in the file,
    /// which in an article whose title is an <h2 class='entry-title'> is a body heading —
    /// so section headings like "St. Thomas" ended up linked to the page they sit on.
    /// Keyed on the article's own folder, so a heading that links somewhere else is left
    /// alone. The headings and their text are untouched.
    private static func unlinkSelfLinkedHeadings(in htmlFile: URL, folderName: String) {
        guard var content = try? String(contentsOf: htmlFile, encoding: .utf8) else { return }
        let original = content

        guard let headings = try? NSRegularExpression(
            pattern: #"<h[123][^>]*>[\s\S]*?</h[123]>"#, options: .caseInsensitive),
            let anchor = try? NSRegularExpression(
                pattern: #"<a[^>]*href=['"]([^'"]*)['"][^>]*>([\s\S]*?)</a>"#,
                options: .caseInsensitive)
        else { return }

        let matches = headings.matches(in: content,
                                       range: NSRange(content.startIndex..., in: content))
        for m in matches.reversed() {                    // reversed: earlier ranges stay valid
            guard let range = Range(m.range, in: content) else { continue }
            let heading = String(content[range])
            var rebuilt = heading
            let inner = anchor.matches(in: heading,
                                       range: NSRange(heading.startIndex..., in: heading))
            for a in inner.reversed() {
                guard let whole = Range(a.range, in: heading),
                      let href = Range(a.range(at: 1), in: heading),
                      let text = Range(a.range(at: 2), in: heading) else { continue }
                // Only a link back to this same article counts as self-referential.
                guard heading[href].contains("/\(folderName)/") else { continue }
                rebuilt.replaceSubrange(
                    Range(uncheckedBounds: (whole.lowerBound, whole.upperBound)),
                    with: String(heading[text]))
            }
            if rebuilt != heading { content.replaceSubrange(range, with: rebuilt) }
        }

        guard content != original else { return }
        try? content.write(to: htmlFile, atomically: true, encoding: .utf8)
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

    private static func buildIndexHTML(entries: [(folder: String, date: String, title: String)],
                                       welcome: String) -> String {
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
                // The folder alone, with its trailing slash: the web server serves the
                // index.html inside (a bare "folder" would cost a redirect first).
                let path = "\(e.folder)/"
                rows += "    <tr class='row-\(group.year)' onclick=\"selectRow(this, '\(path)')\"><td class=\"date-cell\">\(e.date)</td><td><a href='\(path)' target='_blank'>\(escapedTitle)</a></td></tr>\n"
            }
        }

        return """
        <html>
        <head>
          <meta charset="UTF-8">
          <title>Adventures and Stuff</title>
          <style>
            /* blog.css is deliberately not linked here: it styles article pages, and its
               800px body cap would squeeze this two-pane layout. */
            body { margin: 0; padding: 0; display: flex; flex-direction: column; height: 100vh;
                   font-family: Georgia, 'Times New Roman', Times, serif; }
            .site-header { display: flex; align-items: center; gap: 22px; padding: 14px 18px;
                           border-bottom: 1px solid #ccc; flex: 0 0 auto; }
            .site-banner { width: 380px; max-width: 42%; height: auto; flex: 0 0 auto; }
            /* The header is a row (banner | blurb); the blurb itself is a column, so a
               welcome.html with several paragraphs stacks instead of spreading sideways. */
            .site-intro-block { flex: 1 1 auto; min-width: 0; }
            .site-intro { margin: 0 0 8px; font-size: 1.05em; line-height: 1.5; }
            .site-intro:last-of-type { margin-bottom: 10px; }
            .site-contact { margin: 0; }
            .site-contact a { color: #36c; }
            .index-footer { padding: 14px 10px 24px; border-top: 1px solid #ddd;
                            margin-top: 10px; text-align: center; }
            .index-footer a { color: #36c; }
            .container { display: flex; flex: 1 1 auto; min-height: 0; }
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
            // Selects an episode by folder name and shows it.  Used by the ?e= bootstrap
            // below and called from the reading pane by episode.js, so a "Next episode"
            // link followed inside the index keeps the list and the pane in step.
            // Returns true when the episode was found and selected.
            function selectEpisodeByFolder(folder) {
              var target = folder + '/';
              var rows = document.querySelectorAll('tr[class*="row-"]:not(.year-row):not(.width-keeper)');
              for (var i = 0; i < rows.length; i++) {
                var onclick = rows[i].getAttribute('onclick') || '';
                if (onclick.indexOf("'" + target + "'") >= 0) {
                  rows[i].classList.remove('hidden');
                  selectRow(rows[i], target);
                  rows[i].scrollIntoView({ block: 'nearest' });
                  return true;
                }
              }
              return false;
            }
            // Episode links are folder URLs ("2026-01-20_x/"), which a web server resolves
            // to the index.html inside.  Opened from disk (file://) there is no server to
            // do that, so the file name is added back.
            function pageURL(path) {
              return location.protocol === 'file:' && path.slice(-1) === '/' ? path + 'index.html' : path;
            }
            function selectRow(row, htmlFile) {
              var selected = document.querySelector('tr.selected');
              if (selected) selected.classList.remove('selected');
              row.classList.add('selected');
              document.getElementById('reading-pane').src = pageURL(htmlFile);
            }
            window.onload = function() {
              var links = document.querySelectorAll('.table-pane a[href]');
              for (var i = 0; i < links.length; i++) {
                links[i].setAttribute('href', pageURL(links[i].getAttribute('href')));
              }
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
                  if (next) { selected.classList.remove('selected'); next.classList.add('selected'); iframe.src = pageURL(next.getAttribute('onclick').match(/'([^']+)'/)[1]); }
                }
              });
            };
          </script>
        </head>
        <body>
        <div class="site-header">
          <img class="site-banner" src="AdventuresAndStuff.png" alt="Adventures and Stuff">
          <div class="site-intro-block">
        \(welcome)
            <p class="site-contact"><a href="#" data-contact>&#9993; Send E-mail</a></p>
          </div>
        </div>
        <div class="container">
          <div class="table-pane">
            <table style="width:100%;border-collapse:collapse;">
        \(rows)
            </table>
            <div class="index-footer">
              <a href="#" data-contact>&#9993; Contact by E-mail</a>
            </div>
          </div>
          <div class="divider" id="divider"></div>
          <div class="iframe-pane">
            <iframe id="reading-pane" style="width:100%;height:100%;border:none;" src=""></iframe>
          </div>
        </div>
        <script src="contact.js"></script>
        <script>
          // An episode's banner links back here as index.html?e=<folder>, so the article it
          // came from is selected and shown, and the arrow keys carry on from there.
          (function () {
            var m = location.search.match(/[?&]e=([^&]+)/);
            if (m && selectEpisodeByFolder(decodeURIComponent(m[1]))) return;
            // Nothing asked for, or it no longer exists: open the newest episode, which is
            // the first row because the list is built newest-first.  Arriving at the site
            // with an empty reading pane looks broken.
            var rows = document.querySelectorAll('tr[class*="row-"]:not(.year-row):not(.width-keeper)');
            if (!rows.length) return;
            var file = (rows[0].getAttribute('onclick') || '').match(/'([^']+)'/);
            if (file) { selectRow(rows[0], file[1]); }
          })();
        </script>
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

        // Deploy blog.css from the app bundle — always overwrite so CSS changes
        // in the repo propagate to disk on the next publish.
        if let bundledCSS = Bundle.module.url(forResource: "blog", withExtension: "css") {
            let destCSS = travelBlogDir.appendingPathComponent("blog.css")
            if FileManager.default.fileExists(atPath: destCSS.path) {
                try FileManager.default.removeItem(at: destCSS)
            }
            try FileManager.default.copyItem(at: bundledCSS, to: destCSS)
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