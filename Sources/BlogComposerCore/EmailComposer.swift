// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation
import AppKit
import ImageIO

struct EmailAttachment {
    let filename: String
    let contentID: String   // value only, no angle brackets
    let data: Data
}

class EmailComposer {

    // MARK: - HTML

    /// Produces a self-contained HTML body with cid: image refs suitable for email.
    /// Plain text paragraphs with inline images; only bold, italic, and underline are
    /// preserved. Headings become bold paragraphs. Elements separated by a <br> blank line.
    static func buildEmailHTML(entry: BlogEntry, imageMap: [UUID: String]) -> String {
        var blocks: [String] = []

        for item in entry.items {
            switch item {
            case .text(let t):
                let raw = HTMLConverter.convertAttributedText(t.attributedContent)
                blocks.append(contentsOf: extractEmailBlocks(raw))
            case .image(let img):
                guard let filename = imageMap[img.id] else { break }
                let base = (filename as NSString).deletingPathExtension
                let cid  = contentID(for: base)
                let cap  = img.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var block = "<img src=\"cid:\(cid)\" alt=\"\(esc(base))\">"
                if !cap.isEmpty {
                    block += "<br><em>\(esc(cap))</em>"
                }
                blocks.append(block)
            case .video(let v):
                let title = v.title ?? v.youtubeURL
                if let vid = HTMLConverter.youTubeVideoId(v.youtubeURL) {
                    let url = "https://www.youtube.com/watch?v=\(vid)"
                    blocks.append("&#9654; <a href=\"\(url)\">\(esc(title))</a>")
                } else {
                    blocks.append("<a href=\"\(esc(v.youtubeURL))\">\(esc(title))</a>")
                }
            }
        }

        let body = blocks.joined(separator: "\n<br>\n")

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="UTF-8">
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Splits HTML from convertAttributedText into individual block-level elements.
    /// Empty blocks are discarded; headings become bold paragraphs; no style attributes added.
    private static func extractEmailBlocks(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(
            pattern: #"<(p|h[123]|ul|ol)([^>]*)>([\s\S]*?)</(p|h[123]|ul|ol)>"#
        ) else { return [] }

        let matches = re.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var result: [String] = []

        for m in matches {
            guard let tagR     = Range(m.range(at: 1), in: html),
                  let attrsR   = Range(m.range(at: 2), in: html),
                  let contentR = Range(m.range(at: 3), in: html) else { continue }

            let tag   = String(html[tagR])
            let attrs = String(html[attrsR])
            let inner = content(html, contentR).trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip empty blocks
            let bare = inner.replacingOccurrences(of: "&nbsp;", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bare.isEmpty else { continue }

            switch tag {
            case "h1", "h2", "h3":
                result.append("<p><strong>\(inner)</strong></p>")
            case "ul", "ol":
                result.append("<\(tag)\(attrs)>\(inner)</\(tag)>")
            default:
                // Plain paragraph, no style attribute
                result.append("<p>\(inner)</p>")
            }
        }

        return result
    }

    private static func content(_ html: String, _ r: Range<String.Index>) -> String {
        String(html[r])
    }

    // MARK: - Attachments

    /// Reads small/ images for each image item, resampling to 600 px at 0.72 quality for email.
    /// Gmail's IMAP APPEND limit is ~34 MB; staying well under that requires compact images.
    static func buildAttachments(entry: BlogEntry, imageMap: [UUID: String]) -> [EmailAttachment] {
        guard let filePath = entry.filePath else { return [] }
        let baseDir  = filePath.deletingLastPathComponent()
        let smallDir = baseDir.appendingPathComponent("small")
        let fullDir  = baseDir.appendingPathComponent("full")

        var seen = Set<String>()
        var result: [EmailAttachment] = []

        for item in entry.items {
            guard case .image(let img) = item,
                  let filename = imageMap[img.id] else { continue }
            let base = (filename as NSString).deletingPathExtension
            guard !seen.contains(base) else { continue }
            seen.insert(base)

            // Prefer small/ (already 640 px); fall back to full/ if small doesn't exist yet.
            let smallSrc = smallDir.appendingPathComponent("\(base).jpg")
            let fullSrc  = fullDir.appendingPathComponent(filename)
            let src = FileManager.default.fileExists(atPath: smallSrc.path) ? smallSrc : fullSrc
            guard FileManager.default.fileExists(atPath: src.path),
                  let imgData = resizedJPEGData(from: src, maxDim: 600, quality: 0.72) else { continue }

            result.append(EmailAttachment(
                filename: "\(base).jpg",
                contentID: contentID(for: base),
                data: imgData
            ))
        }
        return result
    }

    // MARK: - MIME message

    static func buildMIMEMessage(
        from: String,
        subject: String,
        htmlBody: String,
        attachments: [EmailAttachment]
    ) -> Data {
        let boundary = "Bnd_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var out = Data()

        func w(_ s: String) { out.append(contentsOf: s.utf8) }

        w("From: \(from)\r\n")
        w("To: \(from)\r\n")
        w("Subject: \(mimeSubject(subject))\r\n")
        w("MIME-Version: 1.0\r\n")

        let htmlData = htmlBody.data(using: .utf8) ?? Data()

        if attachments.isEmpty {
            w("Content-Type: text/html; charset=UTF-8\r\n")
            w("Content-Transfer-Encoding: base64\r\n")
            w("\r\n")
            appendBase64(htmlData, to: &out)
        } else {
            w("Content-Type: multipart/related; boundary=\"\(boundary)\"\r\n")
            w("\r\n")
            w("--\(boundary)\r\n")
            w("Content-Type: text/html; charset=UTF-8\r\n")
            w("Content-Transfer-Encoding: base64\r\n")
            w("\r\n")
            appendBase64(htmlData, to: &out)
            w("\r\n")
            for att in attachments {
                w("--\(boundary)\r\n")
                w("Content-Type: image/jpeg\r\n")
                w("Content-Transfer-Encoding: base64\r\n")
                w("Content-ID: <\(att.contentID)>\r\n")
                w("Content-Disposition: inline; filename=\"\(att.filename)\"\r\n")
                w("\r\n")
                appendBase64(att.data, to: &out)
                w("\r\n")
            }
            w("--\(boundary)--\r\n")
        }

        return out
    }

    // MARK: - Helpers

    private static func appendBase64(_ input: Data, to out: inout Data) {
        var b64 = input.base64EncodedString(options: .lineLength76Characters)
        b64 = b64.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\n", with: "\r\n")
        out.append(contentsOf: b64.utf8)
        if !b64.hasSuffix("\r\n") { out.append(contentsOf: "\r\n".utf8) }
    }

    // Stable, filesystem-safe content ID derived from the image base name
    private static func contentID(for base: String) -> String {
        let safe = base
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        return "img.\(safe)@blogcomposer"
    }

    private static func resizedJPEGData(from url: URL, maxDim: Int, quality: Double = 0.85) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let dest = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { return nil }
        return dest as Data
    }

    private static func mimeSubject(_ s: String) -> String {
        guard !s.allSatisfy({ $0.isASCII }) else { return s }
        let b64 = s.data(using: .utf8)?.base64EncodedString() ?? s
        return "=?UTF-8?B?\(b64)?="
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
