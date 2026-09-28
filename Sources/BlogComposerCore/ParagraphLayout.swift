// Copyright © 2026 Randy Wilson. All rights reserved.

import AppKit

/// The editor's paragraph model, matching what the browser shows:
///  * "\n" ends a paragraph — a `<p>` — and the editor draws the browser's gap after it
///    as paragraph spacing, so no blank line needs typing.
///  * U+2028 (Shift-Return) is a line break inside a paragraph — a `<br>` — with no gap,
///    for poems and addresses.
/// The spacing is display-only; the HTML converter ignores paragraph styles.
enum ParagraphLayout {
    static let lineBreak: Character = "\u{2028}"

    /// Gap after a body paragraph, about the browser's 1em `<p>` margin.
    static let paragraphGap: CGFloat = kBodyFontSize
    /// Headings keep the spacing they have always had.
    static let headingGap: CGFloat = 14

    static func isListLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("• ")
            || t.range(of: "^\\d+\\. ", options: .regularExpression) != nil
            || t.range(of: "^[a-z]\\) ", options: .regularExpression) != nil
            || t.range(of: "^[ivx]+\\. ", options: .regularExpression) != nil
    }

    /// A copy of `text` with paragraph spacing applied.
    static func applied(to text: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: text)
        apply(to: m)
        return m
    }

    /// Sets each paragraph's spacing from what it is: heading, list item or body text.
    /// Only touches paragraphs whose spacing is wrong, so running it on every keystroke
    /// leaves the text alone.
    static func apply(to text: NSMutableAttributedString) {
        let ns = text.string as NSString
        guard ns.length > 0 else { return }

        // Paragraph ranges including their "\n" terminator.  NSString's paragraphRange also
        // splits at U+2028, which is exactly the break that must *not* start a paragraph.
        var ranges: [NSRange] = []
        var start = 0
        for i in 0..<ns.length where ns.character(at: i) == 10 {
            ranges.append(NSRange(location: start, length: i + 1 - start))
            start = i + 1
        }
        if start < ns.length { ranges.append(NSRange(location: start, length: ns.length - start)) }

        let lines = ranges.map { ns.substring(with: $0).trimmingCharacters(in: .newlines) }
        let isList = lines.map(isListLine)

        text.beginEditing()
        for (k, range) in ranges.enumerated() {
            let attrs = text.attributes(at: range.location, effectiveRange: nil)
            let isHeading = !lines[k].isEmpty
                && ((attrs[.font] as? NSFont)?.pointSize ?? kBodyFontSize) > kBodyFontSize

            let before: CGFloat
            let after: CGFloat
            if isHeading {
                before = headingGap; after = headingGap
            } else if isList[k] {
                // Items sit together like <li>s; the list as a whole is followed by a gap.
                let nextIsList = k + 1 < ranges.count && isList[k + 1]
                before = 0; after = nextIsList ? 0 : paragraphGap
            } else {
                before = 0; after = paragraphGap
            }

            let current = attrs[.paragraphStyle] as? NSParagraphStyle ?? .default
            var uniform = true
            text.enumerateAttribute(.paragraphStyle, in: range) { value, _, stop in
                let s = value as? NSParagraphStyle ?? .default
                if s.paragraphSpacing != after || s.paragraphSpacingBefore != before {
                    uniform = false; stop.pointee = true
                }
            }
            if uniform { continue }

            let style = (current.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.paragraphSpacing = after
            style.paragraphSpacingBefore = before
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
        text.endEditing()
    }
}
