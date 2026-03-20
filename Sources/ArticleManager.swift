// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation

// Represents a single article entry (draft or published)
struct ArticleEntry: Identifiable {
    let id = UUID()
    let folderURL: URL
    var title: String
    var dateString: String   // "YYYY-MM-DD" or ""
    var isDraft: Bool

    var date: Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: dateString)
    }

    var htmlURL: URL {
        folderURL.appendingPathComponent("index.html")
    }

    var displayTitle: String {
        title.isEmpty ? "(untitled)" : title
    }
}

// Scans Drafts/ and TravelBlog/ to produce a sorted article list
class ArticleManager: ObservableObject {
    static let draftsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Journal/Drafts")
    static let travelBlogDir = TravelBlogPublisher.travelBlogDir

    @Published var articles: [ArticleEntry] = []

    func refresh() {
        var found: [ArticleEntry] = []
        found += scan(directory: ArticleManager.draftsDir, isDraft: true)
        found += scan(directory: ArticleManager.travelBlogDir, isDraft: false)

        // Sort: by dateString descending, undated articles last
        found.sort { a, b in
            if a.dateString.isEmpty && b.dateString.isEmpty { return a.title < b.title }
            if a.dateString.isEmpty { return false }
            if b.dateString.isEmpty { return true }
            return a.dateString > b.dateString
        }

        articles = found
    }

    private func scan(directory: URL, isDraft: Bool) -> [ArticleEntry] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var entries: [ArticleEntry] = []
        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folderName = url.lastPathComponent
            guard folderName != "util" else { continue }

            // Must contain index.html or legacy <folderName>.html
            let indexURL = url.appendingPathComponent("index.html")
            let legacyURL = url.appendingPathComponent("\(folderName).html")
            guard FileManager.default.fileExists(atPath: indexURL.path) ||
                  FileManager.default.fileExists(atPath: legacyURL.path) else { continue }

            // Extract date prefix from folder name (optional)
            let dateString: String
            if folderName.count >= 10,
               folderName.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
                dateString = String(folderName.prefix(10))
            } else {
                dateString = ""
            }

            // Read title from HTML file
            let htmlToRead = FileManager.default.fileExists(atPath: indexURL.path) ? indexURL : legacyURL
            let title = readTitle(from: htmlToRead) ?? folderName

            entries.append(ArticleEntry(
                folderURL: url,
                title: title,
                dateString: dateString,
                isDraft: isDraft
            ))
        }
        return entries
    }

    private func readTitle(from htmlURL: URL) -> String? {
        guard let content = try? String(contentsOf: htmlURL, encoding: .utf8) else { return nil }
        guard let start = content.range(of: "<title>"),
              let end = content.range(of: "</title>", range: start.upperBound..<content.endIndex) else {
            return nil
        }
        let raw = String(content[start.upperBound..<end.lowerBound])
        return raw.isEmpty ? nil : ArticleManager.unescapeHTML(raw)
    }

    /// Decode HTML entities in a string (e.g. &#39; → ', &amp; → &).
    static func unescapeHTML(_ s: String) -> String {
        var result = s
        // Named entities
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                ("&quot;", "\""), ("&apos;", "'")] {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // Decimal numeric entities: &#NNN;
        if let re = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            for match in re.matches(in: result, range: NSRange(result.startIndex..., in: result))
                            .reversed() {
                guard let full = Range(match.range, in: result),
                      let numR = Range(match.range(at: 1), in: result),
                      let cp   = UInt32(result[numR]),
                      let sc   = Unicode.Scalar(cp) else { continue }
                result.replaceSubrange(full, with: String(sc))
            }
        }
        // Hex numeric entities: &#xHHH;
        if let re = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#,
                                              options: .caseInsensitive) {
            for match in re.matches(in: result, range: NSRange(result.startIndex..., in: result))
                            .reversed() {
                guard let full = Range(match.range, in: result),
                      let hexR = Range(match.range(at: 1), in: result),
                      let cp   = UInt32(result[hexR], radix: 16),
                      let sc   = Unicode.Scalar(cp) else { continue }
                result.replaceSubrange(full, with: String(sc))
            }
        }
        return result
    }

    // MARK: - Slug generation

    /// Convert a title into a URL-friendly slug.
    ///
    /// Rules:
    ///  - Apostrophes/quotes are removed silently (no separator inserted).
    ///  - A period directly between two letters is dropped (e.g. "D.C." → "dc").
    ///  - The **first** ":" maps to "_" (priority separator); subsequent ":" map to "-".
    ///  - All other non-alphanumeric characters produce a "-" separator.
    ///  - Runs of separators collapse to one; leading/trailing separators are stripped.
    ///
    /// Examples:
    ///   "Thailand 3: Cooking - Chiang Mai!" → "thailand-3_cooking-chiang-mai"
    ///   "St. Patrick's Day"                 → "st-patricks-day"
    ///   "Pi Day: 3/14/15 9:26:53"           → "pi-day_3-14-15-9-26-53"
    ///   "Fun: Visiting Washington, D.C."     → "fun_visiting-washington-dc"
    static func slugify(_ title: String) -> String {
        // Pass 1: remove apostrophes/quotes; drop periods between two letters
        let chars = Array(title)
        var preprocessed = ""
        for i in 0..<chars.count {
            let c = chars[i]
            // Drop apostrophes and quote characters silently
            if c == "'" || c == "\u{2019}" || c == "\"" || c == "\u{201C}" || c == "\u{201D}" {
                continue
            }
            // Drop a period that sits directly between two letters
            if c == "." {
                let prevIsLetter = i > 0 && chars[i - 1].isLetter
                let nextIsLetter = i + 1 < chars.count && chars[i + 1].isLetter
                if prevIsLetter && nextIsLetter { continue }
            }
            preprocessed.append(c)
        }

        // Pass 2: build slug
        var result = ""
        var pendingSep: Character? = nil   // nil, "-", or "_"
        var seenColon = false

        for char in preprocessed {
            if char.isLetter || char.isNumber {
                if let sep = pendingSep {
                    result.append(sep)
                    pendingSep = nil
                }
                result.append(contentsOf: char.lowercased().folding(options: .diacriticInsensitive, locale: .current))
            } else if char == ":" && !seenColon {
                // First colon → "_" (higher priority than "-")
                if pendingSep != "_" { pendingSep = "_" }
                seenColon = true
            } else {
                // All other non-alphanumeric (including subsequent colons) → "-"
                if pendingSep == nil { pendingSep = "-" }
                // Don't downgrade "_" to "-"
            }
        }
        // Trailing pending separator is discarded
        return result.isEmpty ? "untitled" : result
    }

    /// Build a draft folder name from a date string and title.
    /// date: "YYYY-MM-DD" or "".  Example: "2026-01-20" + "My Article" → "2026-01-20_my-article"
    static func folderName(date: String, title: String) -> String {
        let slug = slugify(title)
        if date.isEmpty { return slug }
        return "\(date)_\(slug)"
    }
}