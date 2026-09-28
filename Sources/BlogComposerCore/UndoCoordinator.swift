// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation
import AppKit

// Snapshot of a single entry item
enum ItemSnapshot {
    case text(NSAttributedString)
    // Images and videos are value types, so the item itself is the snapshot — caption,
    // aspect and all.  (Listing fields by hand here once dropped every caption on undo.)
    case image(ImageItem)
    case video(VideoItem)

    func hasSameContent(as other: ItemSnapshot) -> Bool {
        switch (self, other) {
        case (.text(let a), .text(let b)):
            return a.isEqual(to: b)
        case (.image(let a), .image(let b)):
            guard a.id == b.id, a.filename == b.filename, a.caption == b.caption else { return false }
            return a.smallURL == b.smallURL && a.resizedImage === b.resizedImage
        case (.video(let a), .video(let b)):
            guard a.id == b.id, a.youtubeURL == b.youtubeURL, a.title == b.title else { return false }
            return a.aspectWidth == b.aspectWidth && a.aspectHeight == b.aspectHeight
        default:
            return false
        }
    }
}

// Full snapshot of the entry state at a point in time
struct EntrySnapshot {
    let title: String
    let items: [ItemSnapshot]
    // Where the caret and selection were, by position.  Restoring builds fresh text items
    // (so their NSTextViews reload), which makes the old item ids meaningless.
    let focusedIndex: Int?
    let cursorPosition: Int?
    let selectedIndex: Int?
    let actionName: String

    func hasSameContent(as other: EntrySnapshot) -> Bool {
        title == other.title
            && items.count == other.items.count
            && zip(items, other.items).allSatisfy { $0.hasSameContent(as: $1) }
    }
}

/// How a text change should be grouped with the typing around it.
enum TypingEdit: Equatable {
    /// An ordinary keystroke; joins the current run.
    case keystroke
    /// Typing over a selection: the replacement starts a fresh run.
    case replaceSelection
    /// A self-contained edit (paste, cut, deleting a selection) that is its own undo step.
    case discrete(String)
}

// Manages undo/redo via whole-entry snapshots.
//
// Two kinds of change are recorded, and they are kept apart so one can never overwrite the
// other's "before" state:
//  * Typing runs — opened by `handleTyping`, closed after `typingIdleInterval` of quiet, at
//    a sentence boundary, on a caret jump, or when anything else happens.
//  * Explicit actions — bracketed by `takeSnapshot` / `commitAction`.  Text changes made
//    inside the bracket (formatting calls `didChangeText`, which reports as typing) belong
//    to the action, so typing is not tracked while one is open.
public class UndoCoordinator: ObservableObject {
    @Published public var canUndo: Bool = false
    @Published public var canRedo: Bool = false
    @Published public var undoActionName: String = ""
    @Published public var redoActionName: String = ""

    private var undoStack: [(before: EntrySnapshot, after: EntrySnapshot)] = []
    private var redoStack: [(before: EntrySnapshot, after: EntrySnapshot)] = []

    var isRestoring: Bool = false

    // Explicit action in progress.  Brackets nest; only the outermost one records.
    private var actionBefore: EntrySnapshot?
    private var actionDepth = 0

    /// True while an explicit action is open (e.g. an image import still running).
    var isActionOpen: Bool { actionDepth > 0 }

    // Typing run in progress: its "before" state and the block being typed into.
    private var typingBefore: EntrySnapshot?
    private var typingTarget: UUID?
    private var lastTypedCharForGrouping: Character?
    private var pendingGroupBreak = false

    /// Typing into the title field is grouped separately from typing into any text block.
    static let titleTarget = UUID()

    /// A typing run becomes its own undo step once the keyboard has been quiet this long.
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
        actionBefore = nil
        actionDepth = 0
        resetTypingRun()
        updateState()
    }

    // MARK: - Snapshot Capture

    func captureSnapshot(
        entry: BlogEntry,
        actionName: String,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) -> EntrySnapshot {
        var focusedIndex: Int?
        var cursorPosition: Int?
        var selectedIndex: Int?
        let itemSnapshots = entry.items.enumerated().map { index, item -> ItemSnapshot in
            if item.id == selectedItemId { selectedIndex = index }
            switch item {
            case .text(let textItem):
                if textItem.id == focusedTextItemId {
                    focusedIndex = index
                    cursorPosition = textItem.currentCursorPosition
                }
                // Deep copy the attributed string
                return .text(NSAttributedString(attributedString: textItem.attributedContent))
            case .image(let imageItem):
                return .image(imageItem)
            case .video(let videoItem):
                return .video(videoItem)
            }
        }
        return EntrySnapshot(
            title: entry.title,
            items: itemSnapshots,
            focusedIndex: focusedIndex,
            cursorPosition: cursorPosition,
            selectedIndex: selectedIndex,
            actionName: actionName
        )
    }

    // MARK: - Explicit actions

    /// Opens an undoable action, recording the "before" state.  Closes any typing run first,
    /// so the action is always its own step.  Every call must be paired with `commitAction`.
    func takeSnapshot(
        entry: BlogEntry,
        actionName: String,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) {
        guard !isRestoring else { return }
        if actionDepth == 0 {
            commitTypingIfNeeded(entry: entry, focusedTextItemId: focusedTextItemId,
                                 selectedItemId: selectedItemId)
            actionBefore = captureSnapshot(entry: entry, actionName: actionName,
                                           focusedTextItemId: focusedTextItemId,
                                           selectedItemId: selectedItemId)
        }
        actionDepth += 1
    }

    /// Closes the action opened by `takeSnapshot`.  An action that changed nothing (bold
    /// with no selection, a declined paste) leaves no undo step behind.
    func commitAction(
        entry: BlogEntry,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) {
        guard !isRestoring, actionDepth > 0 else { return }
        actionDepth -= 1
        guard actionDepth == 0, let before = actionBefore else { return }
        actionBefore = nil
        push(before: before, entry: entry, focusedTextItemId: focusedTextItemId,
             selectedItemId: selectedItemId)
    }

    private func push(before: EntrySnapshot, entry: BlogEntry,
                      focusedTextItemId: UUID?, selectedItemId: UUID?) {
        let after = captureSnapshot(entry: entry, actionName: before.actionName,
                                    focusedTextItemId: focusedTextItemId,
                                    selectedItemId: selectedItemId)
        if !after.hasSameContent(as: before) {
            undoStack.append((before: before, after: after))
            redoStack.removeAll()
        }
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
        guard !isRestoring, typingBefore == nil, actionDepth == 0,
              undoStack.count == depth, let last = undoStack.last else { return }
        let after = captureSnapshot(
            entry: entry,
            actionName: last.after.actionName,
            focusedTextItemId: focusedTextItemId,
            selectedItemId: selectedItemId
        )
        undoStack[undoStack.count - 1] = (before: last.before, after: after)
    }

    // MARK: - Typing Grouping

    /// Called for every text change, *before* the model is updated with it, so the first
    /// call of a run captures the state the run started from.
    func handleTyping(
        entry: BlogEntry,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?,
        lastTypedChar: Character?,
        target: UUID? = nil,
        edit: TypingEdit = .keystroke
    ) {
        // Inside an explicit action the change is part of that action.
        guard !isRestoring, actionDepth == 0 else { return }
        let target = target ?? focusedTextItemId

        // Close the current run if this change doesn't belong to it.
        if typingBefore != nil && (pendingGroupBreak || target != typingTarget || edit != .keystroke) {
            commitTypingIfNeeded(entry: entry, focusedTextItemId: typingFocusedItemId,
                                 selectedItemId: typingSelectedItemId)
        }

        if typingBefore == nil {
            let name: String
            if case .discrete(let n) = edit { name = n } else { name = "Typing" }
            typingBefore = captureSnapshot(entry: entry, actionName: name,
                                           focusedTextItemId: focusedTextItemId,
                                           selectedItemId: selectedItemId)
            typingTarget = target
            // New work makes the redo history unreachable; drop it now rather than at the
            // commit, or a redo pressed mid-run would overwrite what was just typed.
            redoStack.removeAll()
            updateState()
        }

        if case .discrete = edit {
            // Nothing else joins a paste or a cut.
            pendingGroupBreak = true
        } else if let prev = lastTypedCharForGrouping, ".!?".contains(prev),
                  let curr = lastTypedChar, curr == " " || curr == "\n" || curr == ParagraphLayout.lineBreak {
            // Break after the space/newline that follows a sentence-ending character
            pendingGroupBreak = true
        }
        lastTypedCharForGrouping = lastTypedChar
        typingEntry = entry
        typingFocusedItemId = focusedTextItemId
        typingSelectedItemId = selectedItemId
        scheduleIdleCommit()
    }

    /// Closes the open typing run, if any, as one undo step.  Called when typing pauses,
    /// the caret jumps, focus moves, or another action starts.
    func commitTypingIfNeeded(
        entry: BlogEntry,
        focusedTextItemId: UUID?,
        selectedItemId: UUID?
    ) {
        guard !isRestoring else { return }
        let before = typingBefore
        resetTypingRun()
        if let before {
            push(before: before, entry: entry, focusedTextItemId: focusedTextItemId,
                 selectedItemId: selectedItemId)
        }
    }

    private func resetTypingRun() {
        typingBefore = nil
        typingTarget = nil
        lastTypedCharForGrouping = nil
        pendingGroupBreak = false
        cancelIdleCommit()
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
        // An action still in flight (an image import) would land on top of the restored state.
        guard actionDepth == 0 else { return nil }
        // The typing in progress is the most recent change, so it is what gets undone.
        commitTypingIfNeeded(entry: entry, focusedTextItemId: focusedTextItemId,
                             selectedItemId: selectedItemId)

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
        guard actionDepth == 0 else { return nil }
        commitTypingIfNeeded(entry: entry, focusedTextItemId: focusedTextItemId,
                             selectedItemId: selectedItemId)

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
            resetTypingRun()
        }

        entry.suspendChangeTracking()

        entry.title = snapshot.title

        // Text items are rebuilt as new objects so SwiftUI makes fresh NSTextViews for
        // them; the focused view would otherwise ignore the restored text (updateNSView
        // leaves a first-responder view alone so it can't clobber typing).
        var focusedId: UUID?
        let newItems: [EntryItem] = snapshot.items.enumerated().map { index, itemSnapshot in
            switch itemSnapshot {
            case .text(let attrString):
                let textItem = TextItem(attributedContent: NSAttributedString(attributedString: attrString))
                if index == snapshot.focusedIndex {
                    focusedId = textItem.id
                    let pos = min(snapshot.cursorPosition ?? attrString.length, attrString.length)
                    textItem.cursorPosition = pos
                    textItem.currentCursorPosition = pos
                }
                return .text(textItem)
            case .image(let imageItem):
                return .image(imageItem)
            case .video(let videoItem):
                return .video(videoItem)
            }
        }

        entry.items = newItems
        entry.resumeChangeTracking()
        entry.isDirty = true

        let selectedId = snapshot.selectedIndex.flatMap { newItems.indices.contains($0) ? newItems[$0].id : nil }
        return RestoreResult(focusedTextItemId: focusedId, selectedItemId: selectedId)
    }

    // MARK: - URL Remapping

    /// After a folder rename, update all smallURL values in snapshots so undo/redo still works.
    func remapSmallURLs(from oldBase: URL, to newBase: URL) {
        let oldPrefix = oldBase.path + "/"
        let remap = { (s: EntrySnapshot) in self.remapSnapshot(s, oldPrefix: oldPrefix, newBase: newBase) }
        undoStack = undoStack.map { (before: remap($0.before), after: remap($0.after)) }
        redoStack = redoStack.map { (before: remap($0.before), after: remap($0.after)) }
        actionBefore = actionBefore.map(remap)
        typingBefore = typingBefore.map(remap)
    }

    private func remapSnapshot(_ snapshot: EntrySnapshot, oldPrefix: String, newBase: URL) -> EntrySnapshot {
        let newItems = snapshot.items.map { item -> ItemSnapshot in
            guard case .image(var img) = item,
                  let url = img.smallURL,
                  url.path.hasPrefix(oldPrefix) else { return item }
            let relative = String(url.path.dropFirst(oldPrefix.count))
            img.smallURL = newBase.appendingPathComponent(relative)
            return .image(img)
        }
        return EntrySnapshot(
            title: snapshot.title,
            items: newItems,
            focusedIndex: snapshot.focusedIndex,
            cursorPosition: snapshot.cursorPosition,
            selectedIndex: snapshot.selectedIndex,
            actionName: snapshot.actionName
        )
    }

    // MARK: - State

    private func updateState() {
        // An open typing run is undoable too, and the menu should say so.
        let newCanUndo = typingBefore != nil || !undoStack.isEmpty
        let newCanRedo = !redoStack.isEmpty
        let newUndoName = typingBefore?.actionName ?? undoStack.last?.before.actionName ?? ""
        let newRedoName = redoStack.last?.after.actionName ?? ""
        // Assign only on change: every @Published write re-renders ContentView, and this
        // runs on keystrokes.
        if canUndo != newCanUndo { canUndo = newCanUndo }
        if canRedo != newCanRedo { canRedo = newCanRedo }
        if undoActionName != newUndoName { undoActionName = newUndoName }
        if redoActionName != newRedoName { redoActionName = newRedoName }
    }
}
