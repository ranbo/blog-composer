// Copyright © 2026 Randy Wilson. All rights reserved.

import XCTest
import AppKit
@testable import BlogComposerCore

/// Return makes a paragraph (<p>, with the browser's gap); Shift-Return makes a line break
/// (<br>, no gap); indentation survives as non-breaking spaces.
@MainActor
final class ParagraphTests: XCTestCase {
    private let br = String(ParagraphLayout.lineBreak)

    private func body(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: bodyFont()])
    }

    private func load(_ bodyHTML: String) async throws -> BlogEntry {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("para-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.html")
        let html = "<html><head><title>T</title></head><body><h1>T</h1>\(bodyHTML)</body></html>"
        try html.write(to: file, atomically: true, encoding: .utf8)
        let entry = BlogEntry()
        try await HTMLParser.load(from: file, into: entry)
        return entry
    }

    private func firstText(_ e: BlogEntry) -> String {
        for i in e.items { if case .text(let t) = i { return t.content } }
        return ""
    }

    func testPoemBecomesOneParagraphWithBreaksAndIndents() {
        let poem = body("Roses are red\(br)  violets are blue\(br)    sugar is  sweet")
        let html = HTMLConverter.convertAttributedText(poem)
        XCTAssertEqual(html,
            "  <p>Roses are red<br>&#160;&#160;violets are blue<br>&#160;&#160;&#160;&#160;sugar is&#160; sweet</p>\n")
    }

    func testParagraphsNeedNoBlankLine() {
        let html = HTMLConverter.convertAttributedText(body("one\ntwo"))
        XCTAssertEqual(html, "  <p>one</p>\n  <p>two</p>\n")
    }

    func testIntentionalEmptyParagraphIsVisible() {
        let html = HTMLConverter.convertAttributedText(body("one\n\ntwo"))
        XCTAssertEqual(html, "  <p>one</p>\n  <p>&nbsp;</p>\n  <p>two</p>\n")
    }

    /// Older articles have an empty <p></p> for every blank line typed between
    /// paragraphs.  The browser never showed them, so the editor drops them too.
    func testLegacyBlankParagraphsAreDropped() async throws {
        let e = try await load("<p>one</p><p></p><p>two</p>")
        XCTAssertEqual(firstText(e), "one\ntwo")
    }

    func testPoemRoundTrips() async throws {
        let text = "one\n\nRoses are red\(br)  violets are blue\ntwo"
        let html = HTMLConverter.convertAttributedText(body(text))
        let e = try await load(html)
        XCTAssertEqual(firstText(e), text)
    }

    func testLeadingEmptyParagraphRoundTrips() async throws {
        let e = try await load("<p>&nbsp;</p><p>after</p>")
        XCTAssertEqual(firstText(e), "\nafter")
    }

    /// Runs of plain spaces collapse in a browser, so they collapse on load as well.
    func testPlainSpaceRunsCollapseOnLoad() async throws {
        let e = try await load("<p>a    b</p>")
        XCTAssertEqual(firstText(e), "a b")
    }

    func testSpacingByParagraphKind() {
        let t = NSMutableAttributedString(string: "Body\n• a\n• b\nMore",
                                          attributes: [.font: bodyFont()])
        t.append(NSAttributedString(string: "\nHead", attributes: [.font: headingFont(22)]))
        ParagraphLayout.apply(to: t)
        func after(_ loc: Int) -> CGFloat {
            (t.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle)?
                .paragraphSpacing ?? NSParagraphStyle.default.paragraphSpacing
        }
        let s = t.string as NSString
        XCTAssertEqual(after(0), ParagraphLayout.paragraphGap, "body paragraph gets the gap")
        XCTAssertEqual(after(s.range(of: "• a").location), 0, "list items sit together")
        XCTAssertEqual(after(s.range(of: "• b").location), ParagraphLayout.paragraphGap,
                       "the list is followed by a gap")
        XCTAssertEqual(after(s.range(of: "Head").location), ParagraphLayout.headingGap)
    }

    /// A line break must not start a new paragraph (NSString's paragraphRange would).
    func testLineBreakDoesNotGetParagraphGap() {
        let t = NSMutableAttributedString(string: "a\(br)b\nc", attributes: [.font: bodyFont()])
        ParagraphLayout.apply(to: t)
        var range = NSRange()
        _ = t.attribute(.paragraphStyle, at: 0, effectiveRange: &range)
        XCTAssertGreaterThanOrEqual(range.length, 4, "a<br>b is one paragraph with one style")
    }
}
