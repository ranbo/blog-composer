// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation
import AppKit

// Snapshot of a single entry item
enum ItemSnapshot {
    case text(NSAttributedString)
    case image(NSImage?, String, URL?)  // resizedImage (may be nil if lazy), filename, smallURL
    case video(String, String?, Int, Int)  // youtubeURL, title, aspectWidth, aspectHeight
}

// Full snapshot of the entry state at a point in time
struct EntrySnapshot {
    let title: String
    let items: [ItemSnapshot]
    let focusedTextItemId: UUID?
    let selectedItemId: UUID?
    let actionName: String
}

// Manages undo/redo via whole-entry snapshots
public class UndoCoordinator: ObservableObject {
    @Published public var canUndo: Bool = false
    @Published public var canRedo: Bool = false
    @Published public var undoActionName: String = ""
    @Published public var redoActionName: String = ""

    private var undoStack: [(before: EntrySnapshot, after: EntrySnapshot)] = []
    private var redoStack: [(before: EntrySnapshot, after: EntrySnapshot)] = []

    private var pendingSnapshot: EntrySnapshot?
    var isRestoring: Bool = false

    // Typing grouping: only snapshot on the first keystroke of a typing session
    var needsTypingSnapshot: Bool = true
    private var lastTypingTime: Date?
    private var lastTypedCharForGrouping: Character?
    private var pendingGroupBreak = false

    /// A typing run becomes its own undo step once the keyboard has been quiet this long.
    /// Checking the gap only on the *next* keystroke (as this used to) left the group open
    /// indefinitely during a pause, and charged the character that resumed typing to the
    /// run that had already ended.  A timer closes the group when the pause happens.
    var typingIdleInterval: TimeInterval = 1.0
    private var idleCommit: DispatchWorkItem?

    // The idle commit needs the same arguments the keystroke gave us.  Holding them here
    // rather than in a callback keeps ContentView (and so this coordinator) out of the
    // closure, which would otherwise retain itself through the view's @StateObject.
    private weak var typingEntry: BlogEntry?
    private var typingFocusedItemId: UUID?
    private var typingSelectedItemId: UUID?

    // MARK: - Clear

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        pendingSnapshot = nil
        needsTypingSnapshot = true
        lastTypingTime = nil
        lastTypedCharForGrouping = nil
        pendingGroupBreak = false
        cancelIdleCommit()
        canUndo = false
        canRedo = false
        undoActionName = ""
        redoActionName = ""
    }

    // MARK: - Snapshot Capture

    func captureSnapshot(
        entry: BlogEntry,
        actionName: String,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) -> EntrySnapshot {
        let itemSnapshots = entry.items.map { item -> ItemSnapshot in
            switch item {
            case .text(let textItem):
                // Deep copy the attributed string
                return .text(NSAttributedString(attributedString: textItem.attributedContent))
            case .image(let imageItem):
                // Preserve both the loaded image (if any) and the lazy-load URL
                return .image(imageItem.resizedImage, imageItem.filename, imageItem.smallURL)
            case .video(let videoItem):
                return .video(videoItem.youtubeURL, videoItem.title,
                              videoItem.aspectWidth, videoItem.aspectHeight)
            }
        }
        return EntrySnapshot(
            title: entry.title,
            items: itemSnapshots,
            focusedTextItemId: focusedTextItemId,
            selectedItemId: selectedItemId,
            actionName: actionName
        )
    }

    // Take a "before" snapshot in preparation for an undoable action
    func takeSnapshot(
        entry: BlogEntry,
        actionName: String,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) {
        guard !isRestoring else { return }
        pendingSnapshot = captureSnapshot(
            entry: entry,
            actionName: actionName,
            focusedTextItemId: focusedTextItemId,
            selectedItemId: selectedItemId
        )
    }

    // Commit: capture the "after" state and push onto undo stack
    func commitAction(
        entry: BlogEntry,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) {
        guard !isRestoring else { return }
        guard let before = pendingSnapshot else { return }

        let after = captureSnapshot(
            entry: entry,
            actionName: before.actionName,
            focusedTextItemId: focusedTextItemId,
            selectedItemId: selectedItemId
        )

        undoStack.append((before: before, after: after))
        redoStack.removeAll()
        pendingSnapshot = nil
        cancelIdleCommit()
        updateState()
    }

    /// Number of committed actions; pass to `refreshLatestAfter(ifDepthIs:)`.
    var actionCount: Int { undoStack.count }

    /// Re-captures the "after" side of the most recent action.  An action whose result is
    /// refined asynchronously — the video aspect lookup — would otherwise leave redo
    /// reproducing the placeholder rather than the corrected state.  The depth check makes
    /// this a no-op once anything else has been done in the meantime.
    func refreshLatestAfter(
        entry: BlogEntry,
        ifDepthIs depth: Int,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) {
        guard !isRestoring, undoStack.count == depth, let last = undoStack.last else { return }
        let after = captureSnapshot(
            entry: entry,
            actionName: last.after.actionName,
            focusedTextItemId: focusedTextItemId,
            selectedItemId: selectedItemId
        )
        undoStack[undoStack.count - 1] = (before: last.before, after: after)
    }

    private func scheduleIdleCommit() {
        cancelIdleCommit()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isRestoring, let entry = self.typingEntry else { return }
            self.commitTypingIfNeeded(
                entry: entry,
                focusedTextItemId: self.typingFocusedItemId,
                selectedItemId: self.typingSelectedItemId
            )
        }
        idleCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + typingIdleInterval, execute: work)
    }

    private func cancelIdleCommit() {
        idleCommit?.cancel()
        idleCommit = nil
    }

    // MARK: - Typing Grouping

    // Called on every textDidChange. Groups typing by time and sentence boundaries.
    func handleTyping(
        entry: BlogEntry,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?,
        lastTypedChar: Character?
    ) {
        guard !isRestoring else { return }
        let now = Date()

        // Break the current group on timeout (2.5s pause) or sentence boundary
        if !needsTypingSnapshot && pendingSnapshot != nil {
            let timedOut = lastTypingTime.map { now.timeIntervalSince($0) > typingIdleInterval } ?? false
            if timedOut || pendingGroupBreak {
                commitAction(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
                needsTypingSnapshot = true
                pendingGroupBreak = false
            }
        }

        // Take a "before" snapshot at the start of each new group
        if needsTypingSnapshot {
            takeSnapshot(entry: entry, actionName: "Typing", focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
            needsTypingSnapshot = false
        }

        // Schedule a break after the space/newline that follows a sentence-ending character
        if let prev = lastTypedCharForGrouping, ".!?".contains(prev),
           let curr = lastTypedChar, curr == " " || curr == "\n" {
            pendingGroupBreak = true
        }
        lastTypedCharForGrouping = lastTypedChar
        lastTypingTime = now
        typingEntry = entry
        typingFocusedItemId = focusedTextItemId
        typingSelectedItemId = selectedItemId
        scheduleIdleCommit()
    }

    // Commit pending typing action (called before non-typing actions)
    func commitTypingIfNeeded(
        entry: BlogEntry,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) {
        guard !isRestoring else { return }
        if !needsTypingSnapshot && pendingSnapshot != nil {
            commitAction(
                entry: entry,
                focusedTextItemId: focusedTextItemId,
                selectedItemId: selectedItemId
            )
            needsTypingSnapshot = true
            lastTypingTime = nil
            lastTypedCharForGrouping = nil
            pendingGroupBreak = false
        }
        cancelIdleCommit()
    }

    // MARK: - Undo / Redo

    struct RestoreResult {
        let focusedTextItemId: UUID?
        let selectedItemId: UUID?
    }

    @discardableResult
    func undo(
        into entry: BlogEntry,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) -> RestoreResult? {
        // Commit any pending typing first
        commitTypingIfNeeded(
            entry: entry,
            focusedTextItemId: focusedTextItemId,
            selectedItemId: selectedItemId
        )

        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)

        let result = restore(snapshot: action.before, into: entry)
        updateState()
        return result
    }

    @discardableResult
    func redo(
        into entry: BlogEntry,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) -> RestoreResult? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)

        let result = restore(snapshot: action.after, into: entry)
        updateState()
        return result
    }

    // MARK: - Restore

    private func restore(snapshot: EntrySnapshot, into entry: BlogEntry) -> RestoreResult {
        isRestoring = true
        defer {
            isRestoring = false
            needsTypingSnapshot = true
            lastTypingTime = nil
            lastTypedCharForGrouping = nil
            pendingGroupBreak = false
        }

        entry.suspendChangeTracking()

        entry.title = snapshot.title

        // Rebuild items from snapshot
        var newItems: [EntryItem] = []
        for itemSnapshot in snapshot.items {
            switch itemSnapshot {
            case .text(let attrString):
                let textItem = TextItem(attributedContent: NSAttributedString(attributedString: attrString))
                newItems.append(.text(textItem))
            case .image(let resizedImage, let filename, let smallURL):
                let imageItem: ImageItem
                if let img = resizedImage {
                    imageItem = ImageItem(resizedImage: img, filename: filename)
                } else if let url = smallURL {
                    imageItem = ImageItem(filename: filename, smallURL: url)
                } else {
                    imageItem = ImageItem(resizedImage: NSImage(), filename: filename)
                }
                newItems.append(.image(imageItem))
            case .video(let url, let title, let aspectW, let aspectH):
                let videoItem = VideoItem(youtubeURL: url, title: title,
                                          aspectWidth: aspectW, aspectHeight: aspectH)
                newItems.append(.video(videoItem))
            }
        }

        entry.items = newItems
        entry.resumeChangeTracking()
        entry.isDirty = true

        return RestoreResult(
            focusedTextItemId: snapshot.focusedTextItemId,
            selectedItemId: snapshot.selectedItemId
        )
    }

    // MARK: - URL Remapping

    /// After a folder rename, update all smallURL values in snapshots so undo/redo still works.
    func remapSmallURLs(from oldBase: URL, to newBase: URL) {
        let oldPrefix = oldBase.path + "/"
        undoStack = undoStack.map { pair in
            (before: remapSnapshot(pair.before, oldPrefix: oldPrefix, newBase: newBase),
             after:  remapSnapshot(pair.after,  oldPrefix: oldPrefix, newBase: newBase))
        }
        redoStack = redoStack.map { pair in
            (before: remapSnapshot(pair.before, oldPrefix: oldPrefix, newBase: newBase),
             after:  remapSnapshot(pair.after,  oldPrefix: oldPrefix, newBase: newBase))
        }
    }

    private func remapSnapshot(_ snapshot: EntrySnapshot, oldPrefix: String, newBase: URL) -> EntrySnapshot {
        let newItems = snapshot.items.map { item -> ItemSnapshot in
            guard case .image(let img, let filename, let smallURL) = item,
                  let url = smallURL,
                  url.path.hasPrefix(oldPrefix) else { return item }
            let relative = String(url.path.dropFirst(oldPrefix.count))
            return .image(img, filename, newBase.appendingPathComponent(relative))
        }
        return EntrySnapshot(
            title: snapshot.title,
            items: newItems,
            focusedTextItemId: snapshot.focusedTextItemId,
            selectedItemId: snapshot.selectedItemId,
            actionName: snapshot.actionName
        )
    }

    // MARK: - State

    private func updateState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoActionName = undoStack.last?.before.actionName ?? ""
        redoActionName = redoStack.last?.after.actionName ?? ""
    }
}