// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation
import AppKit

class HTMLParser {
    enum ParseError: Error, LocalizedError {
        case fileNotFound
        case invalidHTML
        case parsingFailed

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return "HTML file not found"
            case .invalidHTML:
                return "Invalid HTML content"
            case .parsingFailed:
                return "Failed to parse HTML"
            }
        }
    }

    // Load a BlogEntry from an HTML file
    @MainActor
    static func load(from url: URL, into entry: BlogEntry) async throws {
        // Suspend change tracking during loading
        entry.suspendChangeTracking()
        defer {
            // Always resume change tracking when done
            entry.resumeChangeTracking()
        }

        // Read HTML file
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParseError.fileNotFound
        }

        let htmlString = try String(contentsOf: url, encoding: .utf8)

        // Parse HTML
        guard let htmlData = htmlString.data(using: .utf8) else {
            throw ParseError.invalidHTML
        }

        // Use XMLDocument to parse
        let doc = try XMLDocument(data: htmlData, options: [.documentTidyHTML])

        // Extract title
        if let titleNode = try doc.nodes(forXPath: "//h1").first {
            entry.title = titleNode.stringValue ?? ""
        } else if let titleNode = try doc.nodes(forXPath: "//title").first {
            entry.title = titleNode.stringValue ?? ""
        }

        // Extract body content
        guard let bodyNode = try doc.nodes(forXPath: "//body").first as? XMLElement else {
            throw ParseError.parsingFailed
        }

        // Clear existing items
        entry.items.removeAll()

        // Parse body children
        let baseURL = url.deletingLastPathComponent()
        var currentTextContent = NSMutableAttributedString()

        // Pre-build full/ filename map: baseName → filename with extension (one scan for all images)
        let fullDir = baseURL.appendingPathComponent("full")
        var fullFilenameMap: [String: String] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(atPath: fullDir.path) {
            for file in files {
                let fileBase = (file as NSString).deletingPathExtension
                fullFilenameMap[fileBase] = file
            }
        }

        var skippedTitleH1 = false
        var lastNonEmptyWasHeading = false
        for child in bodyNode.children ?? [] {
            guard let element = child as? XMLElement else { continue }

            switch element.name?.lowercased() {
            case "h1":
                // The first <h1> is the article title (already loaded above) — skip it.
                // Any subsequent <h1> is body content and should be parsed normally.
                if !skippedTitleH1 {
                    skippedTitleH1 = true
                    continue
                }
                fallthrough

            case "p":
                // Scan for embedded images (Blogger format: <p><a href="full/..."><img src="small/...">)
                // before falling back to text treatment.
                var foundMedia = false
                for child in element.children ?? [] {
                    guard let childEl = child as? XMLElement else { continue }
                    switch childEl.name?.lowercased() {
                    case "table":
                        // Caption table nested inside <p> (before tidy extraction)
                        let tableClass = childEl.attribute(forName: "class")?.stringValue ?? ""
                        guard tableClass.contains("tr-caption-container"),
                              let imgEl = (try? childEl.nodes(forXPath: ".//img"))?.first as? XMLElement
                        else { continue }
                        if !foundMedia {
                            appendTextItem(from: currentTextContent, into: entry)
                            currentTextContent = NSMutableAttributedString()
                            foundMedia = true
                        }
                        var captionText: String? = nil
                        if let tds = try? childEl.nodes(forXPath: ".//td") {
                            for tdNode in tds {
                                guard let td = tdNode as? XMLElement else { continue }
                                if (td.attribute(forName: "class")?.stringValue ?? "").contains("tr-caption") {
                                    let t = extractCaptionText(td).trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !t.isEmpty && t.lowercased() != "default" { captionText = t }
                                    break
                                }
                            }
                        }
                        if var imageItem = loadImage(from: imgEl, baseURL: baseURL, fullFilenameMap: fullFilenameMap) {
                            imageItem.caption = captionText
                            entry.items.append(.image(imageItem))
                        }

                    case "a":
                        // Image anchor: <a href="..."><img src="..."></a>
                        if let imgEl = childEl.elements(forName: "img").first {
                            if !foundMedia {
                                appendTextItem(from: currentTextContent, into: entry)
                                currentTextContent = NSMutableAttributedString()
                                foundMedia = true
                            }
                            if let imageItem = loadImage(from: imgEl, baseURL: baseURL, fullFilenameMap: fullFilenameMap) {
                                entry.items.append(.image(imageItem))
                            }
                        } else if let href = childEl.attribute(forName: "href")?.stringValue,
                                  href.contains("youtube.com") || href.contains("youtu.be") {
                            // YouTube link without image thumbnail — treat as video
                            if !foundMedia {
                                appendTextItem(from: currentTextContent, into: entry)
                                currentTextContent = NSMutableAttributedString()
                                foundMedia = true
                            }
                            let title = childEl.stringValue
                            let videoItem = VideoItem(youtubeURL: href, title: title?.isEmpty == true ? nil : title)
                            entry.items.append(.video(videoItem))
                        }

                    case "img":
                        // Bare image inside <p> (no anchor wrapper)
                        if !foundMedia {
                            appendTextItem(from: currentTextContent, into: entry)
                            currentTextContent = NSMutableAttributedString()
                            foundMedia = true
                        }
                        if let imageItem = loadImage(from: childEl, baseURL: baseURL, fullFilenameMap: fullFilenameMap) {
                            entry.items.append(.image(imageItem))
                        }

                    default:
                        break
                    }
                }
                if !foundMedia {
                    // Pure text paragraph — accumulate normally
                    let attributed = try parseElement(element, baseURL: baseURL)
                    let isH1 = element.name?.lowercased() == "h1"
                    if !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if isH1 {
                            // Strip any trailing blank line immediately before a heading
                            if currentTextContent.length > 0,
                               (currentTextContent.string as NSString).character(at: currentTextContent.length - 1) == 10 {
                                currentTextContent.deleteCharacters(in: NSRange(location: currentTextContent.length - 1, length: 1))
                            }
                        }
                        if currentTextContent.length > 0 {
                            currentTextContent.append(NSAttributedString(string: "\n"))
                        }
                        currentTextContent.append(attributed)
                        lastNonEmptyWasHeading = isH1
                    } else if currentTextContent.length > 0 && !lastNonEmptyWasHeading {
                        // Empty <p></p> represents a blank line — skip if last element was a heading
                        let lastChar = (currentTextContent.string as NSString).character(at: currentTextContent.length - 1)
                        if lastChar != 10 {
                            currentTextContent.append(NSAttributedString(string: "\n"))
                        }
                    }
                }

            case "h2", "h3", "ul", "ol":
                // Skip Blogger structural elements — the app shows date/title in its own UI
                let elementClass = element.attribute(forName: "class")?.stringValue ?? ""
                if elementClass.contains("date-header") || elementClass.contains("entry-title") {
                    continue
                }
                let isHeading = element.name?.lowercased() == "h2" || element.name?.lowercased() == "h3"
                let attributed = try parseElement(element, baseURL: baseURL)
                if !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if isHeading {
                        // Strip any trailing blank line immediately before a heading
                        if currentTextContent.length > 0,
                           (currentTextContent.string as NSString).character(at: currentTextContent.length - 1) == 10 {
                            currentTextContent.deleteCharacters(in: NSRange(location: currentTextContent.length - 1, length: 1))
                        }
                    }
                    if currentTextContent.length > 0 {
                        currentTextContent.append(NSAttributedString(string: "\n"))
                    }
                    currentTextContent.append(attributed)
                    lastNonEmptyWasHeading = isHeading
                }

            case "a":
                // Check if it's an image wrapper
                if let imgElement = element.elements(forName: "img").first {
                    // Flush accumulated text
                    appendTextItem(from: currentTextContent, into: entry)
                    currentTextContent = NSMutableAttributedString()

                    // Load thumbnail from small/ (fast — already 640px JPEG, no resize needed)
                    if let imageItem = loadImage(from: imgElement, baseURL: baseURL, fullFilenameMap: fullFilenameMap) {
                        entry.items.append(.image(imageItem))
                    }
                } else if let href = element.attribute(forName: "href")?.stringValue,
                          href.contains("youtube.com") || href.contains("youtu.be") {
                    // Flush accumulated text
                    appendTextItem(from: currentTextContent, into: entry)
                    currentTextContent = NSMutableAttributedString()

                    // Add video
                    let title = element.stringValue
                    let videoItem = VideoItem(youtubeURL: href, title: title)
                    entry.items.append(.video(videoItem))
                }

            case "div":
                // Check for embedded YouTube iframe (our iframe output format)
                if let iframeElement = element.elements(forName: "iframe").first,
                   let src = iframeElement.attribute(forName: "src")?.stringValue,
                   src.contains("youtube.com") || src.contains("youtu.be") {
                    appendTextItem(from: currentTextContent, into: entry)
                    currentTextContent = NSMutableAttributedString()
                    let videoItem = VideoItem(youtubeURL: src, title: nil)
                    entry.items.append(.video(videoItem))
                }

            case "iframe":
                // Bare iframe in body (in case tidy removes the wrapping div)
                if let src = element.attribute(forName: "src")?.stringValue,
                   src.contains("youtube.com") || src.contains("youtu.be") {
                    appendTextItem(from: currentTextContent, into: entry)
                    currentTextContent = NSMutableAttributedString()
                    let videoItem = VideoItem(youtubeURL: src, title: nil)
                    entry.items.append(.video(videoItem))
                }

            case "table":
                // Blogger caption tables: <table class="tr-caption-container">
                let tableClass = element.attribute(forName: "class")?.stringValue ?? ""
                guard tableClass.contains("tr-caption-container"),
                      let imgElement = (try? element.nodes(forXPath: ".//img"))?.first as? XMLElement
                else { break }

                appendTextItem(from: currentTextContent, into: entry)
                currentTextContent = NSMutableAttributedString()

                // Extract caption text from <td class="tr-caption">
                var captionText: String? = nil
                if let tds = try? element.nodes(forXPath: ".//td") {
                    for tdNode in tds {
                        guard let td = tdNode as? XMLElement else { continue }
                        let tdClass = td.attribute(forName: "class")?.stringValue ?? ""
                        if tdClass.contains("tr-caption") {
                            let text = extractCaptionText(td)
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && trimmed.lowercased() != "default" { captionText = text }
                            break
                        }
                    }
                }

                if var imageItem = loadImage(from: imgElement, baseURL: baseURL, fullFilenameMap: fullFilenameMap) {
                    imageItem.caption = captionText
                    entry.items.append(.image(imageItem))
                }

            default:
                break
            }
        }

        // Flush remaining text
        appendTextItem(from: currentTextContent, into: entry)

        // Ensure text items exist between all images/videos (fixes articles saved without <p></p> separators)
        entry.ensureTextItemsExist()

        // Ensure there's at least one text item
        if entry.items.isEmpty {
            entry.items.append(.text(TextItem()))
        }

        // Set the file path
        entry.filePath = url

        // Clear dirty flag since we just loaded
        entry.isDirty = false
    }

    // Parse an HTML element into NSAttributedString
    private static func parseElement(_ element: XMLElement, baseURL: URL) throws -> NSAttributedString {
        let result = NSMutableAttributedString()

        switch element.name?.lowercased() {
        case "p", "h1", "h2", "h3":
            let raw = try parseInlineContent(element)
            // Trim trailing whitespace/newlines that libxml2 tidy inserts into text nodes
            var trimLen = raw.length
            while trimLen > 0 {
                let ch = (raw.string as NSString).character(at: trimLen - 1)
                if ch == 10 || ch == 13 || ch == 32 || ch == 9 { trimLen -= 1 } else { break }
            }
            let trimmed = trimLen < raw.length
                ? raw.attributedSubstring(from: NSRange(location: 0, length: trimLen))
                : raw

            // Check for heading sizes
            if element.name?.lowercased() == "h1" {
                // Strip internal newlines — headings are single-line
                let clean = NSMutableAttributedString(attributedString: trimmed)
                var i = clean.length - 1
                while i >= 0 {
                    let ch = (clean.string as NSString).character(at: i)
                    if ch == 10 || ch == 13 { clean.deleteCharacters(in: NSRange(location: i, length: 1)) }
                    i -= 1
                }
                result.append(applyHeadingSize(clean, size: kHeadingSizes[1]!))
            } else if element.name?.lowercased() == "h2" {
                let clean = NSMutableAttributedString(attributedString: trimmed)
                var i = clean.length - 1
                while i >= 0 {
                    let ch = (clean.string as NSString).character(at: i)
                    if ch == 10 || ch == 13 { clean.deleteCharacters(in: NSRange(location: i, length: 1)) }
                    i -= 1
                }
                result.append(applyHeadingSize(clean, size: kHeadingSizes[2]!))
            } else if element.name?.lowercased() == "h3" {
                let clean = NSMutableAttributedString(attributedString: trimmed)
                var i = clean.length - 1
                while i >= 0 {
                    let ch = (clean.string as NSString).character(at: i)
                    if ch == 10 || ch == 13 { clean.deleteCharacters(in: NSRange(location: i, length: 1)) }
                    i -= 1
                }
                result.append(applyHeadingSize(clean, size: kHeadingSizes[3]!))
            } else {
                result.append(trimmed)
            }

        case "ul", "ol":
            let raw = try parseList(element, level: 0, isNumbered: element.name?.lowercased() == "ol")
            // Trim trailing newline that parseList adds after the last item
            var trimLen = raw.length
            while trimLen > 0 {
                let ch = (raw.string as NSString).character(at: trimLen - 1)
                if ch == 10 || ch == 13 { trimLen -= 1 } else { break }
            }
            result.append(trimLen < raw.length
                ? raw.attributedSubstring(from: NSRange(location: 0, length: trimLen))
                : raw)

        default:
            break
        }

        return result
    }

    // Parse inline content (text with formatting)
    private static func parseInlineContent(_ element: XMLElement) throws -> NSAttributedString {
        let result = NSMutableAttributedString()

        for child in element.children ?? [] {
            if child.kind == .text {
                // Plain text — always stamp the body font so NSTextView
                // doesn't fall back to Helvetica for unformatted runs.
                if let content = child.stringValue {
                    result.append(NSAttributedString(string: content,
                                                     attributes: [.font: bodyFont()]))
                }
            } else if let childElement = child as? XMLElement {
                let childContent = try parseInlineContent(childElement)

                switch childElement.name?.lowercased() {
                case "b", "strong":
                    result.append(applyBold(childContent))
                case "i", "em":
                    result.append(applyItalic(childContent))
                case "u":
                    result.append(applyUnderline(childContent))
                default:
                    result.append(childContent)
                }
            }
        }

        return result
    }

    // Parse a list (ul or ol)
    private static func parseList(_ element: XMLElement, level: Int, isNumbered: Bool) throws -> NSAttributedString {
        let result = NSMutableAttributedString()
        let indent = String(repeating: "  ", count: level)

        // Determine marker style based on type attribute and level
        let listType = element.attribute(forName: "type")?.stringValue?.lowercased()
        var itemNumber = 1

        for child in element.children ?? [] {
            guard let li = child as? XMLElement, li.name?.lowercased() == "li" else { continue }

            // Generate appropriate list marker
            let marker: String
            if !isNumbered {
                marker = "• "
            } else {
                // For ordered lists, use type attribute or default based on level
                switch listType {
                case "a":
                    // Lower alpha: a) b) c)
                    let letter = Character(UnicodeScalar(96 + itemNumber)!)
                    marker = "\(letter)) "
                case "i":
                    // Lower roman: i. ii. iii.
                    marker = "\(romanNumeral(itemNumber)). "
                default:
                    // Decimal: 1. 2. 3.
                    marker = "\(itemNumber). "
                }
                itemNumber += 1
            }

            result.append(NSAttributedString(string: indent + marker,
                                             attributes: [.font: bodyFont()]))

            // Parse list item content
            var hasNestedList = false
            for liChild in li.children ?? [] {
                if liChild.kind == .text {
                    // Skip purely-whitespace nodes (tidy indentation), but preserve the
                    // original content verbatim for non-empty nodes so that meaningful
                    // leading spaces (e.g. the space in "</b> word") are not stripped.
                    if let content = liChild.stringValue,
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.append(NSAttributedString(string: content,
                                                         attributes: [.font: bodyFont()]))
                    }
                } else if let childElement = liChild as? XMLElement {
                    if childElement.name?.lowercased() == "ul" || childElement.name?.lowercased() == "ol" {
                        // Nested list
                        hasNestedList = true
                        result.append(NSAttributedString(string: "\n",
                                                         attributes: [.font: bodyFont()]))
                        result.append(try parseList(childElement, level: level + 1, isNumbered: childElement.name?.lowercased() == "ol"))
                    } else {
                        // Inline formatting
                        let childContent = try parseInlineContent(childElement)

                        switch childElement.name?.lowercased() {
                        case "b", "strong":
                            result.append(applyBold(childContent))
                        case "i", "em":
                            result.append(applyItalic(childContent))
                        case "u":
                            result.append(applyUnderline(childContent))
                        default:
                            result.append(childContent)
                        }
                    }
                }
            }

            // Only add newline if this item didn't end with a nested list
            // (nested lists already end with a newline from their last item)
            if !hasNestedList {
                result.append(NSAttributedString(string: "\n"))
            }
        }

        return result
    }

    // Append a text item from accumulated content, trimming trailing newlines.
    // parseList adds \n after every item including the last, which would otherwise
    // show as a blank line at the bottom of the text view.
    private static func appendTextItem(from text: NSMutableAttributedString, into entry: BlogEntry) {
        guard text.length > 0 else { return }
        var len = text.length
        while len > 0 && (text.string as NSString).character(at: len - 1) == 10 { len -= 1 }
        guard len > 0 else { return }
        let content = len < text.length
            ? NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: 0, length: len)))
            : text
        // NSLayoutManager uses the paragraph terminator's (\\n) paragraph style, not the
        // text characters'. Move paragraphSpacing from heading text chars onto their \\n
        // terminator so rendering is consistent between first creation and reload.
        applyHeadingParagraphSpacingToTerminators(in: content)
        entry.items.append(.text(TextItem(attributedContent: content)))
    }

    // For each heading run, copy its paragraphSpacing onto the \\n that follows it.
    private static func applyHeadingParagraphSpacingToTerminators(in text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        var fixes: [NSRange] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length), options: []) { value, subRange, _ in
            guard let font = value as? NSFont,
                  font.pointSize >= kHeadingSizes[3]!,
                  NSFontManager.shared.traits(of: font).contains(.boldFontMask) else { return }
            let nextPos = subRange.location + subRange.length
            if nextPos < text.length,
               (text.string as NSString).character(at: nextPos) == 10 {
                fixes.append(NSRange(location: nextPos, length: 1))
            }
        }
        guard !fixes.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 14
        for range in fixes {
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    // Returns a lazy ImageItem for an image found during HTML parsing.
    // The NSImage is NOT loaded here — ImageItemView loads it on demand from smallURL.
    private static func loadImage(from imgElement: XMLElement, baseURL: URL, fullFilenameMap: [String: String]) -> ImageItem? {
        guard let srcAttr = imgElement.attribute(forName: "src")?.stringValue else {
            return nil
        }

        // src attribute already points to small/filename.jpg
        let smallURL = URL(fileURLWithPath: srcAttr, relativeTo: baseURL).standardizedFileURL
        let baseFilename = (smallURL.lastPathComponent as NSString).deletingPathExtension

        // Look up the original filename (with its extension) from the pre-built full/ map
        guard let originalFilename = fullFilenameMap[baseFilename] else {
            return nil
        }

        return ImageItem(filename: originalFilename, smallURL: smallURL)
    }

    // Extract plain text from a caption <td>, converting <br> to newlines
    private static func extractCaptionText(_ element: XMLElement) -> String {
        var parts: [String] = []
        for child in element.children ?? [] {
            if child.kind == .text {
                if let text = child.stringValue { parts.append(text) }
            } else if let childEl = child as? XMLElement {
                if childEl.name?.lowercased() == "br" {
                    parts.append("\n")
                } else {
                    parts.append(extractCaptionText(childEl))
                }
            }
        }
        return parts.joined()
    }

    // Convert number to lowercase roman numeral
    private static func romanNumeral(_ num: Int) -> String {
        let values = [(10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var result = ""
        var remaining = num

        for (value, numeral) in values {
            while remaining >= value {
                result += numeral
                remaining -= value
            }
        }

        return result
    }

    // Apply bold formatting
    private static func applyBold(_ attrString: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attrString)
        let range = NSRange(location: 0, length: result.length)

        result.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let font = value as? NSFont ?? NSFont(name: "Times New Roman", size: 17) ?? NSFont.systemFont(ofSize: 17)
            let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            result.addAttribute(.font, value: boldFont, range: subRange)
        }

        return result
    }

    // Apply italic formatting
    private static func applyItalic(_ attrString: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attrString)
        let range = NSRange(location: 0, length: result.length)

        result.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let font = value as? NSFont ?? NSFont(name: "Times New Roman", size: 17) ?? NSFont.systemFont(ofSize: 17)
            let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            result.addAttribute(.font, value: italicFont, range: subRange)
        }

        return result
    }

    // Apply underline formatting
    private static func applyUnderline(_ attrString: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attrString)
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        return result
    }

    // Apply heading size
    private static func applyHeadingSize(_ attrString: NSAttributedString, size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attrString)
        let range = NSRange(location: 0, length: result.length)

        result.enumerateAttribute(.font, in: range) { value, subRange, _ in
            var font = value as? NSFont ?? NSFont(name: "Times New Roman", size: 17) ?? NSFont.systemFont(ofSize: 17)
            font = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
            // Also make it bold
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            result.addAttribute(.font, value: font, range: subRange)
        }

        // Add spacing above and below the heading (display only — not written to HTML)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 14
        style.paragraphSpacing = 14
        result.addAttribute(.paragraphStyle, value: style, range: range)

        return result
    }
}