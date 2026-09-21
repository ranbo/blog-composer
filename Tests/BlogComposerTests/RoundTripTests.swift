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

    // Regression: posts downloaded from Blogger store videos as
    // <p><iframe src="…/embed/ID"></iframe></p>.  HTMLParser used to ignore iframes
    // nested inside <p>, so every such video was silently dropped on the first
    // load/save round-trip, leaving only an empty <p></p> behind.
    func testDownloadedBloggerVideosSurviveParsing() async throws {
        let htmlURL = try fixtureURL("2018-02-17_downloaded-video")
        let entry = BlogEntry()
        try await HTMLParser.load(from: htmlURL, into: entry)

        let videoIds = entry.items.compactMap { item -> String? in
            guard case .video(let v) = item else { return nil }
            return HTMLConverter.youTubeVideoId(v.youtubeURL)
        }
        XCTAssertEqual(videoIds, ["bdfgIADV4YU", "utboBoHQQO0", "xQJb3IQmvn0"])

        // The videos must also survive the trip back out to HTML.
        let output = HTMLConverter.convert(
            entry: entry,
            imageMap: imageMap(for: entry),
            domain: "adventuresandstuff.com"
        )
        for id in ["bdfgIADV4YU", "utboBoHQQO0", "xQJb3IQmvn0"] {
            XCTAssertTrue(output.contains(id), "Video \(id) missing from converted HTML")
        }
        XCTAssertTrue(output.contains("Clickity-Stickit"), "Surrounding text lost")
    }

    // A YouTube hyperlink in prose is a reference to somebody else's video, not an
    // inclusion of one of ours.  It must stay an inline link: HTMLParser used to promote
    // any such <a> to a VideoItem, which embedded a player AND discarded the sentence the
    // link sat in.  Only <iframe> means "this is my video".
    func testInlineYouTubeLinksStayInline() async throws {
        let htmlURL = try fixtureURL("2014-03-14_inline-youtube-link")
        let entry = BlogEntry()
        try await HTMLParser.load(from: htmlURL, into: entry)

        // Only the iframe counts as a video; the two anchors do not.
        let videoIds = entry.items.compactMap { item -> String? in
            guard case .video(let v) = item else { return nil }
            return HTMLConverter.youTubeVideoId(v.youtubeURL)
        }
        // The iframe is a video; so is our own marked fallback markup.  The two prose
        // anchors are not.
        XCTAssertEqual(videoIds, ["bdfgIADV4YU"])   // compactMap drops the unembeddable one
        XCTAssertEqual(entry.items.filter { if case .video = $0 { return true }; return false }.count, 2)

        let output = HTMLConverter.convert(
            entry: entry,
            imageMap: imageMap(for: entry),
            domain: "adventuresandstuff.com"
        )

        // The prose around each link survives.
        XCTAssertTrue(output.contains("Each year we enjoy visiting the"), "Prose before link lost")
        XCTAssertTrue(output.contains("It&#39;s a catchy little tune."), "Prose between links lost")
        XCTAssertTrue(output.contains("to intimidate their rivals."), "Prose after link lost")

        // Both YouTube links survive as links, and the non-YouTube link is untouched.
        XCTAssertTrue(output.contains("<a href=\"https://www.youtube.com/watch?v=_BwKZEp2K_0\">Mathematical Pi Song</a>"))
        XCTAssertTrue(output.contains("<a href=\"http://pi.ytmnd.com/\">"))

        // A link whose text carries inline formatting stays a single <a>, not one per run.
        XCTAssertTrue(
            output.contains("<a href=\"https://www.youtube.com/watch?v=yiKFYTFJ_kw\">did the <i>haka</i> before each match</a>"),
            "Link spanning several formatting runs was split into multiple anchors"
        )
    }

    // A video's embed box must match its real frame shape, or the player letterboxes.
    // 16:9 -> 640x360, 9:16 (portrait phone clips and Shorts) -> 360x640, 4:3 -> 640x480.
    func testVideoBoxMatchesAspect() {
        func box(_ w: Int, _ h: Int) -> (width: Int, height: Int) {
            VideoItem(youtubeURL: "https://youtu.be/x", title: nil,
                      aspectWidth: w, aspectHeight: h).boxSize
        }
        XCTAssertEqual(box(1280, 720).width,  640)
        XCTAssertEqual(box(1280, 720).height, 360)
        XCTAssertEqual(box(405, 720).width,   360)
        XCTAssertEqual(box(405, 720).height,  640)
        XCTAssertEqual(box(640, 480).width,   640)
        XCTAssertEqual(box(640, 480).height,  480)
        XCTAssertEqual(box(0, 0).width,       640)   // nonsense falls back to 16:9
        XCTAssertEqual(box(0, 0).height,      360)
    }

    // The aspect must survive a save/load round-trip, so the shape is never re-fetched
    // and a portrait video does not silently revert to 16:9.
    func testVideoAspectRoundTrips() async throws {
        for (aw, ah, wantW, wantH) in [(16, 9, 640, 360), (9, 16, 360, 640), (4, 3, 640, 480)] {
            let entry = BlogEntry()
            entry.items = [.text(TextItem(content: "before")),
                           .video(VideoItem(youtubeURL: "https://www.youtube.com/embed/abc123XYZ_-",
                                            title: nil, aspectWidth: aw, aspectHeight: ah)),
                           .text(TextItem(content: "after"))]
            let html = HTMLConverter.convert(entry: entry, imageMap: [:], domain: nil)
            XCTAssertTrue(html.contains("aspect-ratio: \(wantW) / \(wantH);"),
                          "expected aspect-ratio \(wantW)/\(wantH) in output")
            XCTAssertTrue(html.contains("max-width: \(wantW)px;"))
            XCTAssertTrue(html.contains("width=\"\(wantW)\""))
            XCTAssertTrue(html.contains("height=\"\(wantH)\""))

            // Reload it and confirm the shape comes back.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("aspect-\(aw)x\(ah)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("index.html")
            try html.write(to: file, atomically: true, encoding: .utf8)

            let reloaded = BlogEntry()
            try await HTMLParser.load(from: file, into: reloaded)
            let videos = reloaded.items.compactMap { i -> VideoItem? in
                if case .video(let v) = i { return v }; return nil
            }
            XCTAssertEqual(videos.count, 1)
            XCTAssertEqual(videos.first?.boxSize.width,  wantW, "width lost for \(aw):\(ah)")
            XCTAssertEqual(videos.first?.boxSize.height, wantH, "height lost for \(aw):\(ah)")
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
