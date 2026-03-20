// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation
import AppKit
import Combine

// MARK: - Editor font constants (shared by ContentView, HTMLParser, etc.)
let kBodyFontFamily  = "Times New Roman"
let kBodyFontSize: CGFloat = 17
let kHeadingSizes: [Int: CGFloat] = [1: 28, 2: 22, 3: 18]

func bodyFont(_ size: CGFloat = kBodyFontSize) -> NSFont {
    NSFont(name: kBodyFontFamily, size: size) ?? NSFont.systemFont(ofSize: size)
}
func headingFont(_ size: CGFloat) -> NSFont {
    NSFontManager.shared.convert(bodyFont(size), toHaveTrait: .boldFontMask)
}

// Represents a text block with its content
class TextItem: Identifiable, ObservableObject {
    let id = UUID()
    @Published var attributedContent: NSAttributedString
    @Published var cursorPosition: Int?
    var currentCursorPosition: Int = 0  // Track current cursor for drops

    init(content: String = "") {
        self.attributedContent = NSAttributedString(string: content)
        self.cursorPosition = nil
    }

    init(attributedContent: NSAttributedString) {
        self.attributedContent = attributedContent
        self.cursorPosition = nil
    }

    // Convenience property for plain text access
    var content: String {
        get { attributedContent.string }
        set { attributedContent = NSAttributedString(string: newValue) }
    }
}

// Represents a single item in the blog entry (either text or image or video)
enum EntryItem: Identifiable {
    case text(TextItem)
    case image(ImageItem)
    case video(VideoItem)

    var id: UUID {
        switch self {
        case .text(let item): return item.id
        case .image(let item): return item.id
        case .video(let item): return item.id
        }
    }
}

// Represents an image with its data and metadata
struct ImageItem: Identifiable {
    let id = UUID()
    var resizedImage: NSImage?  // nil until lazily loaded (immediately available for imported images)
    var smallURL: URL?          // file URL of the small/ thumbnail; set by HTMLParser for lazy loading
    var filename: String        // filename in full/ (source of truth for HTML output)
    var caption: String? = nil

    // Used by the async import pipeline — resize already done externally, available immediately
    init(resizedImage: NSImage, filename: String) {
        self.filename = filename
        self.resizedImage = resizedImage
        self.smallURL = nil
    }

    // Used by HTMLParser when loading from disk — image loaded on demand from smallURL
    init(filename: String, smallURL: URL) {
        self.filename = filename
        self.resizedImage = nil
        self.smallURL = smallURL
    }

    // Resize image so largest dimension is maxDimension
    static func resize(image: NSImage, maxDimension: CGFloat) -> NSImage? {
        let size = image.size
        let aspectRatio = size.width / size.height

        var newSize: NSSize
        if size.width > size.height {
            // Landscape or square
            newSize = NSSize(width: maxDimension, height: maxDimension / aspectRatio)
        } else {
            // Portrait
            newSize = NSSize(width: maxDimension * aspectRatio, height: maxDimension)
        }

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()

        return newImage
    }
}

// Represents a video with YouTube URL
struct VideoItem: Identifiable {
    let id = UUID()
    var youtubeURL: String
    var title: String?
}

// The main entry/post
class BlogEntry: ObservableObject {
    @Published var title: String = ""
    @Published var items: [EntryItem] = []
    @Published var filePath: URL?
    @Published var isDirty: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var textItemCancellables = Set<AnyCancellable>()
    private var changeTrackingEnabled = true

    init() {
        // Start with an empty text item
        items.append(.text(TextItem()))

        // Set up change tracking
        $title.sink { [weak self] _ in
            guard let self = self, self.changeTrackingEnabled else { return }
            self.isDirty = true
        }.store(in: &cancellables)

        $items.sink { [weak self] newItems in
            guard let self = self, self.changeTrackingEnabled else { return }
            self.isDirty = true
            // Set up observers for any new TextItems
            self.observeTextItems()
        }.store(in: &cancellables)

        // Observe initial text items
        observeTextItems()
    }

    private func observeTextItems() {
        guard changeTrackingEnabled else { return }

        // Clear old text item observers
        textItemCancellables.removeAll()

        // Observe each TextItem for content changes
        for item in items {
            if case .text(let textItem) = item {
                textItem.objectWillChange.sink { [weak self] _ in
                    guard let self = self, self.changeTrackingEnabled else { return }
                    self.isDirty = true
                }.store(in: &textItemCancellables)
            }
        }
    }

    // Suspend change tracking temporarily (e.g., during loading)
    func suspendChangeTracking() {
        changeTrackingEnabled = false
    }

    // Resume change tracking and rebuild observers
    func resumeChangeTracking() {
        changeTrackingEnabled = true
        observeTextItems()
    }

    func addImage(_ image: NSImage, filename: String) {
        let resized = ImageItem.resize(image: image, maxDimension: 640) ?? image
        let imageItem = ImageItem(resizedImage: resized, filename: filename)
        let newItem = EntryItem.image(imageItem)
        items.append(newItem)

        // Always ensure there's a text item after the image
        ensureTextItemsExist()
    }

    // Ensure text items exist between all non-text items
    func ensureTextItemsExist() {
        var newItems: [EntryItem] = []

        // Add text item at start if first item isn't text
        if let first = items.first, !isTextItem(first) {
            newItems.append(.text(TextItem()))
        }

        var i = 0
        while i < items.count {
            let item = items[i]

            // Check if this is a text item followed by another text item
            if isTextItem(item) && i < items.count - 1 && isTextItem(items[i + 1]) {
                // Merge the two text items
                if case .text(let textItem1) = item, case .text(let textItem2) = items[i + 1] {
                    let mergedContent = textItem1.content.isEmpty && textItem2.content.isEmpty ? "" :
                                       textItem1.content.isEmpty ? textItem2.content :
                                       textItem2.content.isEmpty ? textItem1.content :
                                       textItem1.content + "\n\n" + textItem2.content
                    let mergedItem = TextItem(content: mergedContent)
                    newItems.append(.text(mergedItem))
                    i += 2  // Skip both items
                    continue
                }
            }

            newItems.append(item)

            // Add text item between consecutive non-text items
            if i < items.count - 1 {
                let nextItem = items[i + 1]
                if !isTextItem(item) && !isTextItem(nextItem) {
                    newItems.append(.text(TextItem()))
                }
            }

            i += 1
        }

        // Add text item at end if last item isn't text
        if let last = newItems.last, !isTextItem(last) {
            newItems.append(.text(TextItem()))
        }

        items = newItems
    }

    private func isTextItem(_ item: EntryItem) -> Bool {
        if case .text = item {
            return true
        }
        return false
    }

    // Split a TextItem's attributed content at the cursor position.
    // - If cursor is at the beginning of a line, split there (so the item after the
    //   split point keeps that line, allowing insert-before-line behaviour).
    // - Otherwise, advance to the end of the current line and split there.
    // Returns (before, after) NSAttributedStrings with surrounding newlines stripped.
    private func splitAtCursor(_ textItem: TextItem, cursorPos: Int) -> (before: NSAttributedString, after: NSAttributedString) {
        let content = textItem.content
        let startPos = min(cursorPos, content.count)
        let contentNS = content as NSString
        let fullAttr = textItem.attributedContent
        let fullLength = fullAttr.length

        // Cursor is at the start of a line when it's at position 0, or immediately
        // after a newline — insert the media BEFORE this line rather than after it.
        let isAtLineStart = startPos == 0 ||
            (startPos > 0 && contentNS.character(at: startPos - 1) == 0x000A)

        let splitPos: Int
        if isAtLineStart {
            splitPos = startPos
        } else {
            // Advance to end of current line (include the newline in "before")
            var pos = startPos
            while pos < content.count {
                if contentNS.character(at: pos) == 0x000A {
                    pos += 1
                    break
                }
                pos += 1
            }
            splitPos = pos
        }

        // Helper: strip trailing newlines from an NSRange end
        func trimTrailingNewlines(end: Int, start: Int = 0) -> Int {
            var e = min(end, fullLength)
            while e > start {
                if fullAttr.attributedSubstring(from: NSRange(location: e - 1, length: 1)).string == "\n" {
                    e -= 1
                } else { break }
            }
            return e
        }

        // Helper: strip leading newlines from an NSRange start
        func trimLeadingNewlines(start: Int, end: Int) -> Int {
            var s = start
            while s < end {
                if fullAttr.attributedSubstring(from: NSRange(location: s, length: 1)).string == "\n" {
                    s += 1
                } else { break }
            }
            return s
        }

        let beforeEnd = trimTrailingNewlines(end: min(splitPos, fullLength))
        let attrBefore: NSAttributedString = beforeEnd > 0
            ? fullAttr.attributedSubstring(from: NSRange(location: 0, length: beforeEnd))
            : NSAttributedString()

        let afterRawStart = min(splitPos, fullLength)
        let afterStart = trimLeadingNewlines(start: afterRawStart, end: fullLength)
        let afterEnd = trimTrailingNewlines(end: fullLength, start: afterStart)
        let attrAfter: NSAttributedString = afterStart < afterEnd
            ? fullAttr.attributedSubstring(from: NSRange(location: afterStart, length: afterEnd - afterStart))
            : NSAttributedString()

        return (before: attrBefore, after: attrAfter)
    }

    // Insert a video with the same cursor-aware text-splitting logic as insertImages.
    func insertVideo(url: String, title: String?, at dropIndex: Int, cursorPosition: Int?) {
        var insertIndex = dropIndex
        var attrAfter = NSAttributedString()

        if let cursorPos = cursorPosition,
           dropIndex < items.count,
           case .text(let textItem) = items[dropIndex] {

            let split = splitAtCursor(textItem, cursorPos: cursorPos)
            textItem.attributedContent = split.before
            attrAfter = split.after
            insertIndex = dropIndex + 1
        } else {
            insertIndex = dropIndex + 1
        }

        let videoItem = VideoItem(youtubeURL: url, title: title)
        let hasTextItemAtInsert = insertIndex < items.count && isTextItem(items[insertIndex])

        items.insert(.video(videoItem), at: insertIndex)

        let hasAfterContent = !attrAfter.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasTextItemAtInsert && hasAfterContent {
            let existingIdx = insertIndex + 1
            if existingIdx < items.count, case .text(let existing) = items[existingIdx] {
                let combined = NSMutableAttributedString(attributedString: attrAfter)
                if !existing.attributedContent.string.isEmpty {
                    combined.append(NSAttributedString(string: "\n"))
                    combined.append(existing.attributedContent)
                }
                existing.attributedContent = combined
            }
        } else if !hasTextItemAtInsert {
            items.insert(.text(TextItem(attributedContent: attrAfter)), at: insertIndex + 1)
        }

        ensureTextItemsExist()
    }

    func addText(_ text: String = "", at index: Int? = nil) {
        let textItem = TextItem(content: text)
        if let index = index {
            items.insert(.text(textItem), at: index)
        } else {
            items.append(.text(textItem))
        }
    }

    func insertImages(_ imageItems: [ImageItem], at dropIndex: Int, cursorPosition: Int?) {
        var insertIndex = dropIndex
        var attrAfter = NSAttributedString()

        if let cursorPos = cursorPosition,
           dropIndex < items.count,
           case .text(let textItem) = items[dropIndex] {

            let split = splitAtCursor(textItem, cursorPos: cursorPos)
            textItem.attributedContent = split.before
            attrAfter = split.after
            insertIndex = dropIndex + 1
        } else {
            insertIndex = dropIndex + 1
        }

        // Check if there's already a text item at insertIndex (when dropping on images/videos)
        let hasTextItemAtInsert = insertIndex < items.count && isTextItem(items[insertIndex])
        let hasAfterContent = !attrAfter.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Insert images with empty text items between them
        for (index, imageItem) in imageItems.enumerated() {
            items.insert(.image(imageItem), at: insertIndex + (index * 2))

            let isLastImage = (index == imageItems.count - 1)

            if isLastImage && hasTextItemAtInsert && hasAfterContent {
                let existingTextIndex = insertIndex + (index * 2) + 1
                if existingTextIndex < items.count, case .text(let existingTextItem) = items[existingTextIndex] {
                    let combined = NSMutableAttributedString(attributedString: attrAfter)
                    if !existingTextItem.attributedContent.string.isEmpty {
                        combined.append(NSAttributedString(string: "\n"))
                        combined.append(existingTextItem.attributedContent)
                    }
                    existingTextItem.attributedContent = combined
                }
            } else if isLastImage && hasTextItemAtInsert {
                // Don't add a new text item, one already exists
            } else {
                let afterAttr = isLastImage ? attrAfter : NSAttributedString()
                items.insert(.text(TextItem(attributedContent: afterAttr)), at: insertIndex + (index * 2) + 1)
            }
        }

        ensureTextItemsExist()
    }

    func removeItem(at index: Int, registerUndo: Bool = true) {
        guard index >= 0 && index < items.count else { return }
        items.remove(at: index)
    }

    func replaceItem(at index: Int, with newItem: EntryItem, registerUndo: Bool = true) {
        guard index >= 0 && index < items.count else { return }
        items[index] = newItem
    }
}