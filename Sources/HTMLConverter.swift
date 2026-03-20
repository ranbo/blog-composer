import Foundation
import AppKit

class HTMLConverter {
    // Convert a BlogEntry to HTML
    static func convert(entry: BlogEntry, imageMap: [UUID: String], domain: String? = nil) -> String {
        // Derive formatted date from folder name (e.g. "2026-01-17_slug" → "Sunday, January 17, 2026")
        var formattedDate = ""
        if let filePath = entry.filePath {
            let folderName = filePath.deletingLastPathComponent().lastPathComponent
            let parseFmt = DateFormatter()
            parseFmt.locale = Locale(identifier: "en_US_POSIX")
            parseFmt.dateFormat = "yyyy-MM-dd"
            if let date = parseFmt.date(from: String(folderName.prefix(10))) {
                let displayFmt = DateFormatter()
                displayFmt.locale = Locale(identifier: "en_US")
                displayFmt.dateFormat = "EEEE, MMMM d, yyyy"
                formattedDate = displayFmt.string(from: date)
            }
        }

        var html = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(entry.title))</title>
          <link rel="stylesheet" href="../util/lightbox.css">
          <link rel="stylesheet" href="../blog.css">
        </head>
        <body>

        """

        // Build self-link for published (date-prefixed) articles when a domain is provided
        let selfLink: String? = {
            guard let domain = domain, !domain.isEmpty,
                  let filePath = entry.filePath else { return nil }
            let folder = filePath.deletingLastPathComponent().lastPathComponent
            guard folder.range(of: #"^\d{4}-\d{2}-\d{2}_"#, options: .regularExpression) != nil else { return nil }
            return "https://\(domain)/\(folder)/"
        }()

        if !formattedDate.isEmpty {
            html += "  <h3 class=\"date-header\">\(escapeHTML(formattedDate))</h3>\n"
        }
        if let link = selfLink {
            html += "  <h1><a href=\"\(link)\">\(escapeHTML(entry.title))</a></h1>\n\n"
        } else {
            html += "  <h1>\(escapeHTML(entry.title))</h1>\n\n"
        }

        // Convert each item
        for (index, item) in entry.items.enumerated() {
            switch item {
            case .text(let textItem):
                let textHTML = convertAttributedText(textItem.attributedContent)
                let prevIsMedia: Bool = {
                    guard index > 0 else { return false }
                    switch entry.items[index - 1] {
                    case .image, .video: return true
                    case .text: return false
                    }
                }()
                let nextIsMedia: Bool = {
                    guard index < entry.items.count - 1 else { return false }
                    switch entry.items[index + 1] {
                    case .image, .video: return true
                    case .text: return false
                    }
                }()
                if textHTML.isEmpty {
                    // Empty text between two media items → single separator
                    if prevIsMedia && nextIsMedia {
                        html += "  <p></p>\n"
                    }
                    // At document start/end adjacent to media → output nothing
                } else {
                    if prevIsMedia {
                        html += "  <p></p>\n"
                    }
                    html += textHTML
                    if nextIsMedia {
                        html += "  <p></p>\n"
                    }
                }
            case .image(let imageItem):
                if let filename = imageMap[imageItem.id] {
                    let baseFilename = (filename as NSString).deletingPathExtension
                    let caption = imageItem.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !caption.isEmpty {
                        let captionHTML = escapeHTML(caption).replacingOccurrences(of: "\n", with: "<br>")
                        html += "  <table class=\"tr-caption-container\" style=\"margin: auto;\"><tbody><tr>\n"
                        html += "    <td style=\"text-align: center;\"><a href=\"web/\(escapeHTML(baseFilename)).jpg\" class=\"lightbox-link\"><img src=\"small/\(escapeHTML(baseFilename)).jpg\" loading=\"lazy\" alt=\"\(escapeHTML(baseFilename))\"></a></td>\n"
                        html += "  </tr><tr>\n"
                        html += "    <td class=\"tr-caption\" style=\"text-align: center;\">\(captionHTML)</td>\n"
                        html += "  </tr></tbody></table>\n\n"
                    } else {
                        html += """
                          <a href="web/\(escapeHTML(baseFilename)).jpg" class="lightbox-link"><img src="small/\(escapeHTML(baseFilename)).jpg" loading="lazy" alt="\(escapeHTML(baseFilename))"></a>

                        """
                    }
                }
            case .video(let videoItem):
                if let videoId = youTubeVideoId(videoItem.youtubeURL) {
                    html += "  <div style=\"max-width: 640px;\"><iframe allowfullscreen=\"\" class=\"BLOG_video_class\" height=\"480\" src=\"https://www.youtube.com/embed/\(videoId)\" width=\"640\" style=\"display: block; max-width: 100%;\" youtube-src-id=\"\(videoId)\"></iframe></div>\n\n"
                } else {
                    html += "  <p><a href=\"\(escapeHTML(videoItem.youtubeURL))\">\(escapeHTML(videoItem.title ?? videoItem.youtubeURL))</a></p>\n\n"
                }
            }
        }

        html += """
        <script>
        // YouTube iframes require an HTTP/HTTPS origin and won't work from file://.
        // When previewing locally, replace each iframe with a clickable thumbnail.
        if (location.protocol === 'file:') {
          document.querySelectorAll('iframe.BLOG_video_class').forEach(function(fr) {
            var id = fr.getAttribute('youtube-src-id');
            var a = document.createElement('a');
            a.href = 'https://www.youtube.com/watch?v=' + id;
            a.target = '_blank';
            a.style.display = 'inline-block';
            var img = document.createElement('img');
            img.src = 'https://img.youtube.com/vi/' + id + '/sddefault.jpg';
            img.style.width = '640px';
            img.style.height = 'auto';
            img.style.cursor = 'pointer';
            img.style.display = 'block';
            a.appendChild(img);
            var cap = document.createElement('div');
            cap.style.marginTop = '4px';
            cap.style.color = '#555';
            cap.style.fontSize = '13px';
            cap.textContent = '\\u25B6 Watch on YouTube';
            a.appendChild(cap);
            fr.parentNode.replaceChild(a, fr);
          });
        }
        </script>
        <script src="../util/lightbox.js"></script>
        </body>
        </html>
        """

        return html
    }

    // Convert NSAttributedString to HTML with formatting
    static func convertAttributedText(_ attributedText: NSAttributedString) -> String {
        let text = attributedText.string
        guard !text.isEmpty else { return "" }

        var html = ""
        var lines = text.components(separatedBy: "\n")
        var currentPosition = 0

        // Trim trailing empty lines (prevents spurious <p></p> from list trailing newlines
        // and NSTextView's automatic trailing newline)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return "" }

        // Group consecutive list items
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let lineLength = (line as NSString).length

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                html += "  <p></p>\n"
                currentPosition += lineLength + 1
                i += 1
                continue
            }

            // Check if this line is a list item
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isList = trimmed.hasPrefix("• ") ||
                         trimmed.range(of: "^\\d+\\. ", options: .regularExpression) != nil ||
                         trimmed.range(of: "^[a-z]\\) ", options: .regularExpression) != nil ||
                         trimmed.range(of: "^[ivx]+\\. ", options: .regularExpression) != nil

            if isList {
                // Gather consecutive list items
                var listLines: [(line: String, position: Int, length: Int)] = []
                var j = i

                while j < lines.count {
                    let nextLine = lines[j]
                    let nextLength = (nextLine as NSString).length
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)

                    let isNextList = nextTrimmed.hasPrefix("• ") ||
                                    nextTrimmed.range(of: "^\\d+\\. ", options: .regularExpression) != nil ||
                                    nextTrimmed.range(of: "^[a-z]\\) ", options: .regularExpression) != nil ||
                                    nextTrimmed.range(of: "^[ivx]+\\. ", options: .regularExpression) != nil

                    if !isNextList && !nextTrimmed.isEmpty {
                        break
                    }

                    if isNextList {
                        listLines.append((nextLine, currentPosition, nextLength))
                    }

                    currentPosition += nextLength + 1
                    j += 1
                }

                // Convert list lines to HTML
                html += convertListLines(listLines, attributedText: attributedText)

                i = j
            } else {
                // Regular paragraph - enumerate through all attribute runs
                let lineRange = NSRange(location: currentPosition, length: lineLength)
                let formatted = convertRunsToHTML(attributedText, inRange: lineRange)

                // Determine if it's a heading based on first character's font
                if lineLength > 0 && currentPosition < attributedText.length {
                    let attrs = attributedText.attributes(at: currentPosition, effectiveRange: nil)
                    if let font = attrs[.font] as? NSFont {
                        let size = font.pointSize
                        // H1=28, H2=22, H3=18, body=17
                        if size >= 25 {  // 28 (H1)
                            html += "  <h1>\(convertRunsToHTML(attributedText, inRange: lineRange, isHeading: true))</h1>\n"
                        } else if size >= 20 {  // 22 (H2)
                            html += "  <h2>\(convertRunsToHTML(attributedText, inRange: lineRange, isHeading: true))</h2>\n"
                        } else if size > kBodyFontSize {  // 18 (H3), body=17
                            html += "  <h3>\(convertRunsToHTML(attributedText, inRange: lineRange, isHeading: true))</h3>\n"
                        } else {
                            html += "  <p>\(formatted)</p>\n"
                        }
                    } else {
                        html += "  <p>\(formatted)</p>\n"
                    }
                } else {
                    html += "  <p>\(formatted)</p>\n"
                }

                currentPosition += lineLength + 1
                i += 1
            }
        }

        return html
    }

    // Convert consecutive list lines to nested HTML lists
    private static func convertListLines(_ listLines: [(line: String, position: Int, length: Int)], attributedText: NSAttributedString) -> String {
        struct ListItem {
            let content: String
            let contentRange: NSRange
            let level: Int
            let type: ListType
        }

        enum ListType {
            case bullet
            case decimal      // 1. 2. 3.
            case lowerAlpha   // a) b) c)
            case lowerRoman   // i. ii. iii.
        }

        var listItems: [ListItem] = []

        for (line, position, _) in listLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Count leading spaces
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let level = leadingSpaces / 2

            // Check for list markers
            if trimmed.hasPrefix("• ") {
                let content = String(trimmed.dropFirst(2))
                let contentRange = NSRange(location: position + leadingSpaces + 2, length: (content as NSString).length)
                listItems.append(ListItem(content: content, contentRange: contentRange, level: level, type: .bullet))
            } else if let match = trimmed.range(of: "^\\d+\\. ", options: .regularExpression) {
                // Decimal: 1. 2. 3.
                let markerLength = trimmed.distance(from: trimmed.startIndex, to: match.upperBound)
                let content = String(trimmed.dropFirst(markerLength))
                let contentRange = NSRange(location: position + leadingSpaces + markerLength, length: (content as NSString).length)
                listItems.append(ListItem(content: content, contentRange: contentRange, level: level, type: .decimal))
            } else if let match = trimmed.range(of: "^[a-z]\\) ", options: .regularExpression) {
                // Lower alpha: a) b) c)
                let markerLength = trimmed.distance(from: trimmed.startIndex, to: match.upperBound)
                let content = String(trimmed.dropFirst(markerLength))
                let contentRange = NSRange(location: position + leadingSpaces + markerLength, length: (content as NSString).length)
                listItems.append(ListItem(content: content, contentRange: contentRange, level: level, type: .lowerAlpha))
            } else if let match = trimmed.range(of: "^[ivx]+\\. ", options: .regularExpression) {
                // Lower roman: i. ii. iii.
                let markerLength = trimmed.distance(from: trimmed.startIndex, to: match.upperBound)
                let content = String(trimmed.dropFirst(markerLength))
                let contentRange = NSRange(location: position + leadingSpaces + markerLength, length: (content as NSString).length)
                listItems.append(ListItem(content: content, contentRange: contentRange, level: level, type: .lowerRoman))
            }
        }

        // Build nested HTML with proper structure
        // Each <li> that contains a nested list should be: <li>content<ul>...</ul></li>
        var html = ""
        var openListStack: [(type: ListType, level: Int)] = []
        var openLiStack: [Int] = [] // Track which levels have open <li> tags

        for (index, item) in listItems.enumerated() {
            let nextItem = index + 1 < listItems.count ? listItems[index + 1] : nil
            let nextLevel = nextItem?.level ?? -1

            // Close lists when going back up levels
            while !openListStack.isEmpty && openListStack.last!.level > item.level {
                let closing = openListStack.removeLast()
                let indent = String(repeating: "  ", count: closing.level + 1)
                let tag = closing.type == .bullet ? "ul" : "ol"

                // Close the list
                html += "\(indent)</\(tag)>\n"

                // Close the parent <li> that contained this nested list
                if let parentLiLevel = openLiStack.last, parentLiLevel == closing.level - 1 {
                    openLiStack.removeLast()
                    let liIndent = String(repeating: "  ", count: closing.level)
                    html += "\(liIndent)</li>\n"
                }
            }

            // Open new list if needed (first item or going deeper)
            if openListStack.isEmpty || openListStack.last!.level < item.level {
                let indent = String(repeating: "  ", count: item.level + 1)

                // Generate tag with type attribute for ordered lists
                switch item.type {
                case .bullet:
                    html += "\(indent)<ul>\n"
                case .decimal:
                    html += "\(indent)<ol>\n"
                case .lowerAlpha:
                    html += "\(indent)<ol type=\"a\">\n"
                case .lowerRoman:
                    html += "\(indent)<ol type=\"i\">\n"
                }

                openListStack.append((type: item.type, level: item.level))
            }

            // Add the list item
            let formatted = convertRunsToHTML(attributedText, inRange: item.contentRange)
            let indent = String(repeating: "  ", count: item.level + 2)

            if nextLevel > item.level {
                // Next item is deeper - this <li> will contain a nested list
                // Don't close the <li> yet - it will be closed after the nested list
                html += "\(indent)<li>\(formatted)\n"
                openLiStack.append(item.level)
            } else {
                // Next item is same level or shallower - close this <li> now
                html += "\(indent)<li>\(formatted)</li>\n"
            }
        }

        // Close all remaining open lists and <li> tags
        while !openListStack.isEmpty {
            let closing = openListStack.removeLast()
            let indent = String(repeating: "  ", count: closing.level + 1)
            let tag = closing.type == .bullet ? "ul" : "ol"

            // Close the list
            html += "\(indent)</\(tag)>\n"

            // Close parent <li> if there is one
            if let parentLiLevel = openLiStack.last, parentLiLevel == closing.level - 1 {
                openLiStack.removeLast()
                let liIndent = String(repeating: "  ", count: closing.level)
                html += "\(liIndent)</li>\n"
            }
        }

        return html
    }

    // Convert attribute runs to HTML, properly handling mixed formatting.
    // Pass isHeading: true when the caller will wrap the result in <h1>/<h2>/<h3> — this
    // suppresses redundant <b> tags (heading elements are already bold in HTML/CSS).
    private static func convertRunsToHTML(_ attributedText: NSAttributedString, inRange range: NSRange, isHeading: Bool = false) -> String {
        guard range.length > 0, range.location < attributedText.length else {
            return ""
        }

        var html = ""

        // Enumerate through attribute runs
        attributedText.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            // Get the substring
            let effectiveRange = NSIntersectionRange(subRange, range)
            guard effectiveRange.length > 0 else { return }

            let substring = (attributedText.string as NSString).substring(with: effectiveRange)
            var formatted = escapeHTML(substring)

            // Check for underline (innermost)
            if let underlineStyle = attrs[.underlineStyle] as? Int, underlineStyle > 0 {
                formatted = "<u>\(formatted)</u>"
            }

            // Check for bold and italic
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits

                // Apply italic
                if traits.contains(.italic) {
                    formatted = "<i>\(formatted)</i>"
                }

                // Apply bold (outermost) — skip for headings: <h1>/<h2>/<h3> already implies bold
                if traits.contains(.bold) && !isHeading {
                    formatted = "<b>\(formatted)</b>"
                }
            }

            html += formatted
        }

        return html
    }

    // Extract the video ID from common YouTube URL formats:
    //   https://www.youtube.com/watch?v=VIDEO_ID
    //   https://youtu.be/VIDEO_ID
    //   https://www.youtube.com/embed/VIDEO_ID
    //   https://www.youtube.com/shorts/VIDEO_ID
    static func youTubeVideoId(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        let host = components.host ?? ""

        if host.hasSuffix("youtu.be") {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.isEmpty ? nil : String(path.prefix(while: { $0 != "?" && $0 != "&" }))
        }

        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }

        let parts = components.path.components(separatedBy: "/").filter { !$0.isEmpty }
        for keyword in ["embed", "shorts"] {
            if let idx = parts.firstIndex(of: keyword), idx + 1 < parts.count {
                return parts[idx + 1]
            }
        }

        return nil
    }

    // Escape HTML special characters and encode non-ASCII code points as numeric
    // entities.  Keeping the file ASCII-only means libxml2's encoding detection
    // (which defaults to Windows-1252 for HTML) can never corrupt curly quotes,
    // em-dashes, or other multi-byte UTF-8 sequences on reload.
    private static func escapeHTML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x26: result += "&amp;"
            case 0x3C: result += "&lt;"
            case 0x3E: result += "&gt;"
            case 0x22: result += "&quot;"
            case 0x27: result += "&#39;"
            case 0x00...0x7E: result.unicodeScalars.append(scalar)  // plain ASCII
            default:   result += "&#\(scalar.value);"               // non-ASCII → numeric entity
            }
        }
        return result
    }
}
