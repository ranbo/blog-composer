import Foundation
import AppKit

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
    var originalImage: NSImage
    var resizedImage: NSImage?
    var filename: String

    init(image: NSImage, filename: String) {
        self.originalImage = image
        self.filename = filename
        self.resizedImage = ImageItem.resize(image: image, maxDimension: 640)
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

    init() {
        // Start with an empty text item
        items.append(.text(TextItem()))
    }

    func addImage(_ image: NSImage, filename: String) {
        let imageItem = ImageItem(image: image, filename: filename)
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

    func addVideo(url: String, title: String? = nil) {
        let videoItem = VideoItem(youtubeURL: url, title: title)
        let newItem = EntryItem.video(videoItem)
        items.append(newItem)

        // Always ensure there's a text item after the video
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

    func insertImages(_ images: [(NSImage, String)], at dropIndex: Int, cursorPosition: Int?) {
        // If dropping on a text item, split at end of the line
        var insertIndex = dropIndex
        var textAfterLine = ""

        if let cursorPos = cursorPosition,
           dropIndex < items.count,
           case .text(let textItem) = items[dropIndex] {

            let content = textItem.content
            let startPos = min(cursorPos, content.count)

            // Find the end of the line where the cursor is
            var splitPos = startPos
            let contentNS = content as NSString

            // Advance to the end of the current line (next newline or end of string)
            while splitPos < content.count {
                let char = contentNS.character(at: splitPos)
                if char == 0x000A { // newline character
                    splitPos += 1 // Include the newline
                    break
                }
                splitPos += 1
            }

            // Text up to end of line stays
            var textBefore = String(content.prefix(splitPos))

            // Text after the line
            var remainingText = String(content.suffix(content.count - splitPos))

            // Trim trailing newlines from text before
            textBefore = textBefore.replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)

            // Remove leading newlines from remaining text
            remainingText = remainingText.replacingOccurrences(of: "^\\n+", with: "", options: .regularExpression)

            textItem.content = textBefore

            // Only keep remaining text if it has non-whitespace content
            if remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textAfterLine = ""
            } else {
                textAfterLine = remainingText
            }

            insertIndex = dropIndex + 1
        } else {
            // Drop after the item
            insertIndex = dropIndex + 1
        }

        // Check if there's already a text item at insertIndex (when dropping on images/videos)
        let hasTextItemAtInsert = insertIndex < items.count && isTextItem(items[insertIndex])

        // Insert images with empty text items between them
        for (index, (image, filename)) in images.enumerated() {
            let imageItem = ImageItem(image: image, filename: filename)
            items.insert(.image(imageItem), at: insertIndex + (index * 2))

            // Add text item after image
            let isLastImage = (index == images.count - 1)

            // If this is the last image and there's already a text item, merge with it
            if isLastImage && hasTextItemAtInsert && !textAfterLine.isEmpty {
                // Update the existing text item with the split text
                let existingTextIndex = insertIndex + (index * 2) + 1
                if existingTextIndex < items.count, case .text(let existingTextItem) = items[existingTextIndex] {
                    existingTextItem.content = textAfterLine + (existingTextItem.content.isEmpty ? "" : "\n" + existingTextItem.content)
                }
            } else if isLastImage && hasTextItemAtInsert {
                // Don't add a new text item, one already exists
            } else {
                // Add new text item
                let textContent = isLastImage ? textAfterLine : ""
                items.insert(.text(TextItem(content: textContent)), at: insertIndex + (index * 2) + 1)
            }
        }

        // Clean up: ensure text items exist between all non-text items
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
