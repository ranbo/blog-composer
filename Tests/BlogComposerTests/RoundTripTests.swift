// Copyright © 2026 Randy Wilson. All rights reserved.

import XCTest
import AppKit
@testable import BlogComposerCore

@MainActor
final class RoundTripTests: XCTestCase {

    // Returns the URL of a named fixture folder inside Tests/BlogComposerTests/Fixtures/
    private func fixtureURL(_ folderName: String) throws -> URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            throw XCTestError(.failureWhileWaiting, userInfo: [NSLocalizedDescriptionKey: "No resource bundle URL"])
        }
        return resourceURL
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(folderName)
            .appendingPathComponent("index.html")
    }

    // Build an imageMap from the entry's image items (filename → filename).
    private func imageMap(for entry: BlogEntry) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for item in entry.items {
            if case .image(let img) = item {
                map[img.id] = img.filename
            }
        }
        return map
    }

    func testDebugTextContent() async throws {
        let htmlURL = try fixtureURL("2026-03-26_unit-test")
        let entry = BlogEntry()
        try await HTMLParser.load(from: htmlURL, into: entry)
        for (i, item) in entry.items.enumerated() {
            if case .text(let t) = item {
                let escaped = t.attributedContent.string
                    .replacingOccurrences(of: "\n", with: "\\n")
                print("TextItem[\(i)]: \"\(escaped)\"")
                // Also print first 5 font sizes
                var pos = 0
                while pos < min(t.attributedContent.length, 100) {
                    var r = NSRange()
                    let attrs = t.attributedContent.attributes(at: pos, longestEffectiveRange: &r, in: NSRange(location: 0, length: t.attributedContent.length))
                    let font = attrs[.font] as? NSFont
                    let end = r.location + r.length
                    let sub = (t.attributedContent.string as NSString).substring(with: r)
                    print("  [\(r.location)-\(end)]: font=\(font?.pointSize ?? 0)pt, text=\(sub.prefix(20).replacingOccurrences(of: "\n", with: "\\n"))")
                    pos = end
                }
            }
        }
    }

    func testUnitTestHTMLRoundTrips() async throws {
        let htmlURL = try fixtureURL("2026-03-26_unit-test")

        // Load
        let entry = BlogEntry()
        try await HTMLParser.load(from: htmlURL, into: entry)

        // Convert back
        let output = HTMLConverter.convert(
            entry: entry,
            imageMap: imageMap(for: entry),
            domain: "adventuresandstuff.com"
        )

        // Compare with original
        let original = try String(contentsOf: htmlURL, encoding: .utf8)

        if output != original {
            // Produce a line-by-line diff for easy reading in test output
            let origLines = original.components(separatedBy: "\n")
            let outLines  = output.components(separatedBy: "\n")
            let maxLines  = max(origLines.count, outLines.count)
            var diffs: [String] = []
            for i in 0..<maxLines {
                let o = i < origLines.count ? origLines[i] : "<missing>"
                let n = i < outLines.count  ? outLines[i]  : "<missing>"
                if o != n {
                    diffs.append("Line \(i + 1):")
                    diffs.append("  EXPECTED: \(o)")
                    diffs.append("  GOT:      \(n)")
                }
            }
            XCTFail("Round-trip produced different HTML:\n" + diffs.joined(separator: "\n"))
        }
    }
}
