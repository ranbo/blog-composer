// Copyright © 2026 Randy Wilson. All rights reserved.

import XCTest
@testable import BlogComposerCore

@MainActor
final class UndoTests: XCTestCase {

    private func makeEntry(_ text: String = "hello") -> BlogEntry {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: text))]
        return e
    }
    private func videoCount(_ e: BlogEntry) -> Int {
        e.items.filter { if case .video = $0 { return true }; return false }.count
    }
    private func firstText(_ e: BlogEntry) -> String {
        for i in e.items { if case .text(let t) = i { return t.content } }
        return ""
    }

    /// The reported bug: typing, then adding a video, then one undo removed BOTH.  The video
    /// path committed without taking a "before", so it inherited the typing run's snapshot.
    func testAddingVideoDoesNotSwallowTheTypingRun() {
        let entry = makeEntry("")
        let undo = UndoCoordinator()

        // Start a typing run.
        undo.handleTyping(entry: entry, focusedTextItemId: nil, selectedItemId: nil, lastTypedChar: "a")
        if case .text(let t) = entry.items[0] { t.content = "my comment" }

        // Add a video the way ContentView does it now.
        undo.commitTypingIfNeeded(entry: entry, focusedTextItemId: nil, selectedItemId: nil)
        undo.takeSnapshot(entry: entry, actionName: "Add Video", focusedTextItemId: nil, selectedItemId: nil)
        entry.insertVideo(url: "https://youtu.be/aaaaaaaaaaa", title: nil, at: 0, cursorPosition: nil)
        undo.commitAction(entry: entry, focusedTextItemId: nil, selectedItemId: nil)

        XCTAssertEqual(videoCount(entry), 1)

        // First undo removes only the video; the typed text must survive.
        undo.undo(into: entry, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(videoCount(entry), 0, "undo should remove the video")
        XCTAssertEqual(firstText(entry), "my comment", "undo must not also revert the typing")

        // A second undo then reverts the typing.
        undo.undo(into: entry, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(firstText(entry), "", "second undo should revert the typing run")
    }

    /// Two videos added in a row must be two separate undo steps.
    func testEachVideoIsItsOwnUndoStep() {
        let entry = makeEntry("")
        let undo = UndoCoordinator()
        for id in ["https://youtu.be/aaaaaaaaaaa", "https://youtu.be/bbbbbbbbbbb"] {
            undo.commitTypingIfNeeded(entry: entry, focusedTextItemId: nil, selectedItemId: nil)
            undo.takeSnapshot(entry: entry, actionName: "Add Video", focusedTextItemId: nil, selectedItemId: nil)
            entry.insertVideo(url: id, title: nil, at: 0, cursorPosition: nil)
            undo.commitAction(entry: entry, focusedTextItemId: nil, selectedItemId: nil)
        }
        XCTAssertEqual(videoCount(entry), 2)
        undo.undo(into: entry, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(videoCount(entry), 1, "one undo should remove one video")
        undo.undo(into: entry, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(videoCount(entry), 0)
    }

    /// A video's frame shape has to survive undo/redo, or portrait clips silently
    /// revert to 16:9 whenever anything is undone.
    func testUndoRedoPreservesVideoAspect() {
        let entry = BlogEntry()
        entry.items = [.text(TextItem(content: "a")),
                       .video(VideoItem(youtubeURL: "https://youtu.be/ccccccccccc", title: "t",
                                        aspectWidth: 405, aspectHeight: 720)),
                       .text(TextItem(content: "b"))]
        let undo = UndoCoordinator()
        undo.takeSnapshot(entry: entry, actionName: "Edit", focusedTextItemId: nil, selectedItemId: nil)
        if case .text(let t) = entry.items[0] { t.content = "changed" }
        undo.commitAction(entry: entry, focusedTextItemId: nil, selectedItemId: nil)

        undo.undo(into: entry, focusedTextItemId: nil, selectedItemId: nil)
        guard case .video(let v1) = entry.items[1] else { return XCTFail("video lost on undo") }
        XCTAssertEqual(v1.boxSize.width, 360)
        XCTAssertEqual(v1.boxSize.height, 640)

        undo.redo(into: entry, focusedTextItemId: nil, selectedItemId: nil)
        guard case .video(let v2) = entry.items[1] else { return XCTFail("video lost on redo") }
        XCTAssertEqual(v2.boxSize.width, 360, "redo must not reset the aspect to 16:9")
        XCTAssertEqual(v2.boxSize.height, 640)
    }

    /// Changing the URL clears the old shape (a different video is a different shape);
    /// changing only the title leaves it alone.
    func testUpdateVideoReportsWhatChanged() {
        let entry = BlogEntry()
        let v = VideoItem(youtubeURL: "https://youtu.be/aaaaaaaaaaa", title: "old",
                          aspectWidth: 405, aspectHeight: 720)
        entry.items = [.text(TextItem()), .video(v), .text(TextItem())]

        var r = entry.updateVideo(id: v.id, url: v.youtubeURL, title: "new title")
        XCTAssertTrue(r.changed); XCTAssertFalse(r.urlChanged)
        guard case .video(let afterTitle) = entry.items[1] else { return XCTFail() }
        XCTAssertEqual(afterTitle.title, "new title")
        XCTAssertEqual(afterTitle.aspectHeight, 720, "title edit must not disturb the aspect")

        r = entry.updateVideo(id: v.id, url: "https://youtu.be/zzzzzzzzzzz", title: "new title")
        XCTAssertTrue(r.changed); XCTAssertTrue(r.urlChanged)
        guard case .video(let afterURL) = entry.items[1] else { return XCTFail() }
        XCTAssertEqual(afterURL.aspectWidth, 16, "a new URL resets to 16:9 pending lookup")
        XCTAssertEqual(afterURL.aspectHeight, 9)

        r = entry.updateVideo(id: v.id, url: "https://youtu.be/zzzzzzzzzzz", title: "new title")
        XCTAssertFalse(r.changed, "a no-op edit should not report a change")
    }

    /// An asynchronous refinement updates the latest action's redo state, but only while
    /// that action is still the most recent one.
    func testRefreshLatestAfterRespectsDepth() {
        let entry = BlogEntry()
        entry.items = [.text(TextItem(content: "x"))]
        let undo = UndoCoordinator()
        undo.takeSnapshot(entry: entry, actionName: "Add Video", focusedTextItemId: nil, selectedItemId: nil)
        entry.insertVideo(url: "https://youtu.be/ddddddddddd", title: nil, at: 0, cursorPosition: nil)
        undo.commitAction(entry: entry, focusedTextItemId: nil, selectedItemId: nil)
        let depth = undo.actionCount

        // The lookup lands: correct the aspect and refresh redo.
        let vid = entry.items.compactMap { i -> UUID? in
            if case .video(let v) = i { return v.id }; return nil
        }.first!
        entry.setVideoAspect(id: vid, width: 405, height: 720)
        undo.refreshLatestAfter(entry: entry, ifDepthIs: depth, focusedTextItemId: nil, selectedItemId: nil)

        undo.undo(into: entry, focusedTextItemId: nil, selectedItemId: nil)
        undo.redo(into: entry, focusedTextItemId: nil, selectedItemId: nil)
        guard case .video(let v) = entry.items.first(where: { if case .video = $0 { return true }; return false })!
        else { return XCTFail() }
        XCTAssertEqual(v.aspectHeight, 720, "redo should reproduce the corrected aspect")

        // Stale depth must be ignored.
        undo.takeSnapshot(entry: entry, actionName: "Other", focusedTextItemId: nil, selectedItemId: nil)
        if case .text(let t) = entry.items[0] { t.content = "y" }
        undo.commitAction(entry: entry, focusedTextItemId: nil, selectedItemId: nil)
        let before = undo.actionCount
        undo.refreshLatestAfter(entry: entry, ifDepthIs: depth, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(undo.actionCount, before, "stale refresh must not disturb the stack")
    }
}

@MainActor
final class UndoGroupingTests: XCTestCase {
    private func text(_ e: BlogEntry, _ i: Int = 0) -> String {
        if case .text(let t) = e.items[i] { return t.content }
        return ""
    }
    private func setText(_ e: BlogEntry, _ s: String, _ i: Int = 0) {
        if case .text(let t) = e.items[i] { t.content = s }
    }
    /// One keystroke the way the editor reports it: coordinator first, then the model.
    private func type(_ u: UndoCoordinator, _ e: BlogEntry, _ result: String,
                      edit: TypingEdit = .keystroke) {
        u.handleTyping(entry: e, focusedTextItemId: e.items[0].id, selectedItemId: nil,
                       lastTypedChar: result.last, edit: edit)
        setText(e, result)
    }

    /// The reported bug.  Bold calls didChangeText, which reported as typing *inside* the
    /// Bold action; that overwrote the action's "before" and left the typing tracker
    /// stuck, so nothing typed afterwards was recorded.  Undo then jumped back past all
    /// of it, and redo offered the old action instead of what was just undone.
    func testTypingAfterFormattingIsRecorded() {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: "one"))]
        let u = UndoCoordinator()

        u.takeSnapshot(entry: e, actionName: "bold", focusedTextItemId: nil, selectedItemId: nil)
        type(u, e, "ONE")   // the didChangeText echo from inside the action
        u.commitAction(entry: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(u.undoActionName, "bold")

        type(u, e, "ONE t")
        type(u, e, "ONE tw")
        XCTAssertEqual(u.undoActionName, "Typing", "the new run must be undoable")

        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e), "ONE", "undo reverts only the latest typing")
        XCTAssertEqual(u.redoActionName, "Typing", "redo offers what was just undone")

        u.redo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e), "ONE tw", "redo brings the typing back")

        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e), "one", "second undo reverts the formatting")
    }

    /// An action that changes nothing must not leave a step to be "undone".
    func testNoOpActionLeavesNoStep() {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: "x"))]
        let u = UndoCoordinator()
        u.takeSnapshot(entry: e, actionName: "bold", focusedTextItemId: nil, selectedItemId: nil)
        u.commitAction(entry: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertFalse(u.canUndo)
    }

    /// Brackets nest; the outer action records one step and typing resumes afterwards.
    func testNestedActionsRecordOnce() {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: "a"))]
        let u = UndoCoordinator()
        u.takeSnapshot(entry: e, actionName: "Hyperlink", focusedTextItemId: nil, selectedItemId: nil)
        u.takeSnapshot(entry: e, actionName: "Remove Hyperlink", focusedTextItemId: nil, selectedItemId: nil)
        setText(e, "b")
        u.commitAction(entry: e, focusedTextItemId: nil, selectedItemId: nil)
        u.commitAction(entry: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(u.actionCount, 1)
        XCTAssertFalse(u.isActionOpen)
        type(u, e, "bc")
        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e), "b")
    }

    /// Paste, cut and deleting a selection are each their own step, and nothing typed
    /// after them joins them.
    func testDiscreteEditsAreTheirOwnSteps() {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: ""))]
        let u = UndoCoordinator()
        type(u, e, "a")
        type(u, e, "ab")
        type(u, e, "ab PASTED", edit: .discrete("Paste"))
        XCTAssertEqual(u.undoActionName, "Paste")
        type(u, e, "ab PASTEDc")

        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e), "ab PASTED")
        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e), "ab")
        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e), "")
    }

    /// Typing over a selection starts a new run, so undo restores the selected text
    /// without also removing what was typed before it.
    func testReplacingSelectionStartsNewRun() {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: ""))]
        let u = UndoCoordinator()
        type(u, e, "hello world")
        type(u, e, "hello X", edit: .replaceSelection)
        type(u, e, "hello XY")
        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e), "hello world")
    }

    /// Typing in a different block is a different run.
    func testSwitchingBlocksBreaksTheRun() {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: "")), .text(TextItem(content: ""))]
        let u = UndoCoordinator()
        u.handleTyping(entry: e, focusedTextItemId: e.items[0].id, selectedItemId: nil, lastTypedChar: "a")
        setText(e, "a", 0)
        u.handleTyping(entry: e, focusedTextItemId: e.items[1].id, selectedItemId: nil, lastTypedChar: "b")
        setText(e, "b", 1)
        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e, 0), "a")
        XCTAssertEqual(text(e, 1), "")
    }

    /// Undo used to rebuild images from a few hand-picked fields and dropped captions,
    /// so undoing anything wiped every caption in the article.
    func testUndoKeepsImageCaptions() {
        let e = BlogEntry()
        var img = ImageItem(filename: "a.jpg", smallURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        img.caption = "Sunset"
        e.items = [.text(TextItem(content: "x")), .image(img), .text(TextItem(content: ""))]
        let u = UndoCoordinator()
        type(u, e, "xy")
        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        guard case .image(let restored) = e.items[1] else { return XCTFail() }
        XCTAssertEqual(restored.caption, "Sunset")
    }

    /// Restored text items are new objects, so focus is carried by position.
    func testUndoRestoresCaretBlock() {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: "first")), .text(TextItem(content: "second"))]
        let u = UndoCoordinator()
        let target = e.items[1].id
        u.handleTyping(entry: e, focusedTextItemId: target, selectedItemId: nil, lastTypedChar: "!")
        setText(e, "second!", 1)
        let r = u.undo(into: e, focusedTextItemId: target, selectedItemId: nil)
        XCTAssertNotNil(r?.focusedTextItemId)
        XCTAssertEqual(r?.focusedTextItemId, e.items[1].id, "caret returns to the edited block")
    }

    /// Typing after an undo discards redo immediately; a redo pressed mid-run must not
    /// overwrite the new text.
    func testTypingAfterUndoClearsRedo() {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: ""))]
        let u = UndoCoordinator()
        type(u, e, "a")
        u.undo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertTrue(u.canRedo)
        type(u, e, "b")
        XCTAssertFalse(u.canRedo)
        u.redo(into: e, focusedTextItemId: nil, selectedItemId: nil)
        XCTAssertEqual(text(e), "b")
    }
}

@MainActor
final class UndoTimerTests: XCTestCase {
    /// A pause in typing should close the run on its own, without waiting for the next
    /// keystroke — otherwise a long pause leaves the group open and the character that
    /// resumes typing gets charged to the run that already ended.
    func testTypingRunClosesAfterIdlePause() async throws {
        let entry = BlogEntry()
        entry.items = [.text(TextItem(content: ""))]
        let undo = UndoCoordinator()
        undo.typingIdleInterval = 0.15

        undo.handleTyping(entry: entry, focusedTextItemId: nil, selectedItemId: nil, lastTypedChar: "a")
        if case .text(let t) = entry.items[0] { t.content = "first" }
        XCTAssertEqual(undo.actionCount, 0, "run is still open while typing")

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(undo.actionCount, 1, "the pause should have committed the run")
        XCTAssertTrue(undo.canUndo)

        // Typing again starts a separate run.
        undo.handleTyping(entry: entry, focusedTextItemId: nil, selectedItemId: nil, lastTypedChar: "b")
        if case .text(let t) = entry.items[0] { t.content = "first second" }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(undo.actionCount, 2, "second run is its own undo step")

        undo.undo(into: entry, focusedTextItemId: nil, selectedItemId: nil)
        var text = ""
        for i in entry.items { if case .text(let t) = i { text = t.content; break } }
        XCTAssertEqual(text, "first", "one undo should revert only the second run")
    }
}

@MainActor
final class VideoTitleTests: XCTestCase {
    /// A title typed in the dialog used to vanish on save: the converter never wrote it
    /// and the parser always read nil, so the editor could never show one.
    func testVideoTitleSurvivesSaveAndReload() async throws {
        let entry = BlogEntry()
        entry.items = [.text(TextItem(content: "before")),
                       .video(VideoItem(youtubeURL: "https://www.youtube.com/embed/abc123XYZ_-",
                                        title: "Rubén y Papá Tocan las Guitarras",
                                        aspectWidth: 405, aspectHeight: 720)),
                       .text(TextItem(content: "after"))]

        let html = HTMLConverter.convert(entry: entry, imageMap: [:], domain: nil)
        // The converter keeps its output ASCII-only (numeric entities) so libxml2's
        // encoding detection can't corrupt accents on reload.
        XCTAssertTrue(html.contains("title=\"Rub&#233;n y Pap&#225; Tocan las Guitarras\""),
                      "the title must be written to the iframe")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtitle-\(UUID().uuidString)")
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
        XCTAssertEqual(videos.first?.title, "Rubén y Papá Tocan las Guitarras")
        XCTAssertEqual(videos.first?.boxSize.height, 640, "aspect must still round-trip too")
    }

    /// A title, when present, is shown under the clip as a caption — not just carried
    /// invisibly on the iframe.  And the box is centred inline, like images are.
    func testTitleRendersAsCaptionAndBoxIsCentred() {
        let entry = BlogEntry()
        entry.items = [.text(TextItem()),
                       .video(VideoItem(youtubeURL: "https://youtu.be/abc123XYZ_-", title: "Poi Ball")),
                       .text(TextItem())]
        let html = HTMLConverter.convert(entry: entry, imageMap: [:], domain: nil)
        XCTAssertTrue(html.contains("<div class=\"video-caption\">Poi Ball</div>"),
                      "the title should render below the clip")
        XCTAssertTrue(html.contains("margin-left: auto; margin-right: auto;"),
                      "the video box should be centred inline")
        // The caption belongs inside the box so it is as wide as the clip, not the page.
        XCTAssertTrue(html.contains("</iframe><div class=\"video-caption\">Poi Ball</div></div>"))
    }

    /// An untitled video renders no caption element at all.
    func testUntitledVideoRendersNoCaption() {
        let entry = BlogEntry()
        entry.items = [.text(TextItem()),
                       .video(VideoItem(youtubeURL: "https://youtu.be/abc123XYZ_-", title: nil)),
                       .text(TextItem())]
        let html = HTMLConverter.convert(entry: entry, imageMap: [:], domain: nil)
        XCTAssertFalse(html.contains("video-caption"))
        XCTAssertTrue(html.contains("margin-left: auto; margin-right: auto;"),
                      "centring applies with or without a caption")
    }

    /// No title means no attribute at all, so untitled videos don't gain noise in the HTML.
    func testUntitledVideoWritesNoTitleAttribute() {
        let entry = BlogEntry()
        entry.items = [.text(TextItem()),
                       .video(VideoItem(youtubeURL: "https://youtu.be/abc123XYZ_-", title: nil)),
                       .text(TextItem())]
        let html = HTMLConverter.convert(entry: entry, imageMap: [:], domain: nil)
        XCTAssertFalse(html.contains(" title=\""), "expected no title attribute")

        entry.items[1] = .video(VideoItem(youtubeURL: "https://youtu.be/abc123XYZ_-", title: "   "))
        let blank = HTMLConverter.convert(entry: entry, imageMap: [:], domain: nil)
        XCTAssertFalse(blank.contains(" title=\""), "a whitespace-only title is not a title")
    }
}

@MainActor
final class BlockSelectionTests: XCTestCase {
    /// Cut/copy act on `selectedItemIds`, so a shift-click range has to land there —
    /// and it must cover every item between the two blocks, media included.
    private func article() -> BlogEntry {
        let e = BlogEntry()
        e.items = [.text(TextItem(content: "one")),
                   .image(ImageItem(filename: "a.jpg", smallURL: URL(fileURLWithPath: "/tmp/a.jpg"))),
                   .text(TextItem(content: "two")),
                   .video(VideoItem(youtubeURL: "https://youtu.be/abc123XYZ_-", title: nil)),
                   .text(TextItem(content: "three"))]
        return e
    }

    /// The range between two block indices, as the handler computes it.
    private func range(_ e: BlogEntry, _ a: Int, _ b: Int) -> Set<UUID> {
        let lo = min(a, b), hi = max(a, b)
        return Set(e.items[lo...hi].map { $0.id })
    }

    func testRangeSpansInterveningMedia() {
        let e = article()
        let sel = range(e, 0, 4)
        XCTAssertEqual(sel.count, 5, "every item between the two text blocks is included")
        XCTAssertTrue(sel.contains(e.items[1].id), "the image between them is selected")
        XCTAssertTrue(sel.contains(e.items[3].id), "the video between them is selected")
    }

    func testRangeIsOrderIndependent() {
        let e = article()
        XCTAssertEqual(range(e, 4, 2), range(e, 2, 4),
                       "shift-clicking upwards selects the same items as downwards")
    }

    func testSingleBlockRangeIsJustThatBlock() {
        let e = article()
        XCTAssertEqual(range(e, 2, 2), Set([e.items[2].id]))
    }

    /// Selecting the whole article is what the second Cmd-A does.
    func testWholeArticleCoversEveryItem() {
        let e = article()
        XCTAssertEqual(Set(e.items.map { $0.id }).count, e.items.count)
        XCTAssertEqual(Set(e.items.map { $0.id }), range(e, 0, e.items.count - 1))
    }
}
