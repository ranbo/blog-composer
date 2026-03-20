// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation
import AppKit

// Snapshot of a single entry item
enum ItemSnapshot {
    case text(NSAttributedString)
    case image(NSImage?, String, URL?)  // resizedImage (may be nil if lazy), filename, smallURL
    case video(String, String?)         // youtubeURL, title
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
class UndoCoordinator: ObservableObject {
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    @Published var undoActionName: String = ""
    @Published var redoActionName: String = ""

    private var undoStack: [(before: EntrySnapshot, after: EntrySnapshot)] = []
    private var redoStack: [(before: EntrySnapshot, after: EntrySnapshot)] = []

    private var pendingSnapshot: EntrySnapshot?
    var isRestoring: Bool = false

    // Typing grouping: only snapshot on the first keystroke of a typing session
    var needsTypingSnapshot: Bool = true

    // MARK: - Clear

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        pendingSnapshot = nil
        needsTypingSnapshot = true
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
                return .video(videoItem.youtubeURL, videoItem.title)
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
        updateState()
    }

    // MARK: - Typing Grouping

    // Called on every textDidChange. Only takes a snapshot on the first keystroke.
    func handleTyping(
        entry: BlogEntry,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) {
        guard !isRestoring else { return }
        if needsTypingSnapshot {
            takeSnapshot(
                entry: entry,
                actionName: "Typing",
                focusedTextItemId: focusedTextItemId,
                selectedItemId: selectedItemId
            )
            needsTypingSnapshot = false
        }
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
        }
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
            case .video(let url, let title):
                let videoItem = VideoItem(youtubeURL: url, title: title)
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