import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        r = (int >> 16) & 0xFF
        g = (int >> 8) & 0xFF
        b = int & 0xFF
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}

struct ContentView: View {
    @StateObject private var entry = BlogEntry()
    @State private var showVideoDialog = false
    @State private var selectedItemId: UUID? = nil
    @State private var focusedTextItemId: UUID? = nil
    @State private var selectedItemIds: Set<UUID> = []
    @State private var clipboard: [EntryItem] = []
    @State private var focusedTextView: CustomNSTextView? = nil
    @State private var activeFormats: Set<FormattingType> = []

    var body: some View {
        VStack(spacing: 0) {
            // Formatting toolbar
            FormattingToolbar(
                activeFormats: activeFormats,
                onHeading1: { applyFormatting(.heading1) },
                onHeading2: { applyFormatting(.heading2) },
                onHeading3: { applyFormatting(.heading3) },
                onBold: { applyFormatting(.bold) },
                onItalic: { applyFormatting(.italic) },
                onUnderline: { applyFormatting(.underline) },
                onBulletList: { applyFormatting(.bulletList) },
                onNumberedList: { applyFormatting(.numberedList) }
            )

            Divider()

            // Title bar
            HStack {
                TextField("Entry Title", text: $entry.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.title)

                Spacer()

                Button("Add Video") {
                    showVideoDialog = true
                }

                Button("Export HTML") {
                    exportHTML()
                }

                Button("Send Email") {
                    sendEmail()
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Main content area
            EntryContentView(
                entry: entry,
                selectedItemId: $selectedItemId,
                focusedTextItemId: $focusedTextItemId,
                selectedItemIds: $selectedItemIds,
                onNavigateUp: navigateUp,
                onNavigateDown: navigateDown,
                onDrop: handleDrop,
                onDelete: handleDelete,
                onArrowKey: handleArrowKey,
                onImageTap: handleImageTap,
                onVideoTap: handleVideoTap,
                onPaste: handlePaste,
                onTextViewFocusChanged: { textView in
                    focusedTextView = textView
                    updateActiveFormats()
                },
                onSelectionChanged: {
                    updateActiveFormats()
                }
            )
        }
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $showVideoDialog) {
            VideoDialogView(entry: entry)
        }
        .background(CutPasteHandler(
            canCut: canCut(),
            canPaste: canPaste(),
            onCut: handleCut,
            onPaste: handlePaste
        ))
    }

    private func handleDrop(providers: [NSItemProvider]) {
        // This is now handled by per-item drops
        // Keep for backwards compatibility but shouldn't be called
    }

    private func exportHTML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(entry.title.isEmpty ? "untitled" : entry.title).html"
        panel.allowedContentTypes = [.html]

        if panel.runModal() == .OK, let url = panel.url {
            // TODO: Generate and save HTML
            print("Would save to: \(url)")
        }
    }

    private func sendEmail() {
        // TODO: Open Mail with populated message
        print("Would open Mail")
    }

    private func canCut() -> Bool {
        return !selectedItemIds.isEmpty || selectedItemId != nil
    }

    private func canPaste() -> Bool {
        return !clipboard.isEmpty
    }

    private func handleCut() {
        let itemsToCut: [UUID]

        if !selectedItemIds.isEmpty {
            // Multi-select: cut range
            itemsToCut = Array(selectedItemIds)
        } else if let singleId = selectedItemId {
            // Single selection
            itemsToCut = [singleId]
        } else {
            return
        }

        // Find indices of items to cut
        var indicesToCut: [Int] = []
        for id in itemsToCut {
            if let index = entry.items.firstIndex(where: { $0.id == id }) {
                indicesToCut.append(index)
            }
        }

        guard !indicesToCut.isEmpty else { return }
        indicesToCut.sort()

        // Store items in clipboard
        clipboard = indicesToCut.map { entry.items[$0] }

        // Find text items before first and after last cut item
        let firstIndex = indicesToCut.first!
        let lastIndex = indicesToCut.last!

        var textBefore = ""
        var textAfter = ""

        if firstIndex > 0, case .text(let beforeItem) = entry.items[firstIndex - 1] {
            textBefore = beforeItem.content
        }

        if lastIndex < entry.items.count - 1, case .text(let afterItem) = entry.items[lastIndex + 1] {
            textAfter = afterItem.content
        }

        // Combine text
        let combined = if !textBefore.isEmpty && !textAfter.isEmpty {
            textBefore + "\n\n" + textAfter
        } else {
            textBefore + textAfter
        }

        // Remove cut items and adjacent text items
        var toRemove = indicesToCut
        if firstIndex > 0, case .text = entry.items[firstIndex - 1] {
            toRemove.insert(firstIndex - 1, at: 0)
        }
        if lastIndex < entry.items.count - 1, case .text = entry.items[lastIndex + 1] {
            toRemove.append(lastIndex + 1)
        }

        // Remove in reverse order
        for index in toRemove.sorted(by: >) {
            entry.items.remove(at: index)
        }

        // Insert combined text
        let insertIndex = toRemove.min()!
        entry.addText(combined, at: insertIndex)

        // Clear selection
        selectedItemId = nil
        selectedItemIds.removeAll()
    }

    private func handlePaste() {
        guard !clipboard.isEmpty else { return }

        // Determine where to paste
        if let focusedId = focusedTextItemId,
           let focusedIndex = entry.items.firstIndex(where: { $0.id == focusedId }),
           case .text(let textItem) = entry.items[focusedIndex] {
            // Paste into text area at cursor position
            pasteIntoText(at: focusedIndex, textItem: textItem)
        } else if let selectedId = selectedItemId,
                  let selectedIndex = entry.items.firstIndex(where: { $0.id == selectedId }) {
            // Paste before selected image
            pasteBeforeItem(at: selectedIndex)
        }
    }

    private func pasteIntoText(at index: Int, textItem: TextItem) {
        // Split text at cursor position
        let cursorPos = textItem.currentCursorPosition
        let content = textItem.content
        let splitPos = min(cursorPos, content.count)

        // Find end of line
        var endOfLine = splitPos
        let contentNS = content as NSString
        while endOfLine < content.count {
            let char = contentNS.character(at: endOfLine)
            if char == 0x000A {
                endOfLine += 1
                break
            }
            endOfLine += 1
        }

        var textBefore = String(content.prefix(endOfLine))
        var textAfter = String(content.suffix(content.count - endOfLine))

        textBefore = textBefore.replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
        textAfter = textAfter.replacingOccurrences(of: "^\\n+", with: "", options: .regularExpression)

        textItem.content = textBefore

        // Insert clipboard items
        var insertIndex = index + 1
        for item in clipboard {
            entry.items.insert(item, at: insertIndex)
            insertIndex += 1
        }

        // Handle the remaining text
        if !textAfter.isEmpty {
            // Check if the last clipboard item is a text item
            if let lastItem = clipboard.last, case .text = lastItem {
                // Append to the last pasted text item
                if insertIndex - 1 < entry.items.count, case .text(let pastedTextItem) = entry.items[insertIndex - 1] {
                    pastedTextItem.content = pastedTextItem.content + (pastedTextItem.content.isEmpty ? "" : "\n\n") + textAfter
                }
            } else {
                // Add new text item with remaining text
                entry.addText(textAfter, at: insertIndex)
            }
        }

        entry.ensureTextItemsExist()
    }

    private func pasteBeforeItem(at index: Int) {
        // Insert clipboard items before the selected item
        for (offset, item) in clipboard.enumerated() {
            entry.items.insert(item, at: index + offset)
        }

        entry.ensureTextItemsExist()
    }

    private func handleImageTap(imageItem: ImageItem, index: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let firstId = selectedItemId {
            // Shift-click: select range
            guard let firstIndex = entry.items.firstIndex(where: { $0.id == firstId }) else { return }

            let rangeStart = min(firstIndex, index)
            let rangeEnd = max(firstIndex, index)

            selectedItemIds.removeAll()
            for i in rangeStart...rangeEnd {
                selectedItemIds.insert(entry.items[i].id)
            }

            focusedTextItemId = nil
        } else {
            // Regular click: single select
            selectedItemId = imageItem.id
            selectedItemIds.removeAll()
            focusedTextItemId = nil
        }
    }

    private func handleVideoTap(videoItem: VideoItem, index: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let firstId = selectedItemId {
            // Shift-click: select range
            guard let firstIndex = entry.items.firstIndex(where: { $0.id == firstId }) else { return }

            let rangeStart = min(firstIndex, index)
            let rangeEnd = max(firstIndex, index)

            selectedItemIds.removeAll()
            for i in rangeStart...rangeEnd {
                selectedItemIds.insert(entry.items[i].id)
            }

            focusedTextItemId = nil
        } else {
            // Regular click: single select
            selectedItemId = videoItem.id
            selectedItemIds.removeAll()
            focusedTextItemId = nil
        }
    }

    private func applyFormatting(_ formatting: FormattingType) {
        guard let textView = focusedTextView else {
            print("No focused text view")
            return
        }

        // Store the current selection
        let savedRange = textView.selectedRange()

        guard let textStorage = textView.textStorage else { return }

        switch formatting {
        case .bold:
            if savedRange.length > 0 {
                textView.applyFontTrait(.boldFontMask, range: savedRange)
            } else {
                // Toggle bold in typing attributes
                toggleTypingAttribute(.boldFontMask, textView: textView)
            }
            updateActiveFormats()
        case .italic:
            if savedRange.length > 0 {
                textView.applyFontTrait(.italicFontMask, range: savedRange)
            } else {
                // Toggle italic in typing attributes
                toggleTypingAttribute(.italicFontMask, textView: textView)
            }
            updateActiveFormats()
        case .underline:
            if savedRange.length > 0 {
                let attrs = textStorage.attributes(at: savedRange.location, effectiveRange: nil)
                if attrs[.underlineStyle] != nil {
                    // Remove underline
                    textStorage.removeAttribute(.underlineStyle, range: savedRange)
                } else {
                    // Add underline
                    textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: savedRange)
                }
            } else {
                // Toggle underline in typing attributes
                var attrs = textView.typingAttributes
                if attrs[.underlineStyle] != nil {
                    attrs.removeValue(forKey: .underlineStyle)
                } else {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                textView.typingAttributes = attrs
            }
            updateActiveFormats()
        case .heading1:
            applyHeading(textView: textView, savedRange: savedRange, level: 1)
        case .heading2:
            applyHeading(textView: textView, savedRange: savedRange, level: 2)
        case .heading3:
            applyHeading(textView: textView, savedRange: savedRange, level: 3)
        case .bulletList:
            applyListStyle(textView: textView, savedRange: savedRange, ordered: false)
            return  // Don't restore selection - applyListStyle handles it
        case .numberedList:
            applyListStyle(textView: textView, savedRange: savedRange, ordered: true)
            return  // Don't restore selection - applyListStyle handles it
        }

        // Restore focus and selection
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            // Make sure the saved range is still valid after potential text changes
            let validLocation = min(savedRange.location, textStorage.length)
            let validLength = min(savedRange.length, textStorage.length - validLocation)
            let validRange = NSRange(location: validLocation, length: validLength)
            textView.setSelectedRange(validRange)
        }
    }

    private func applyHeading(textView: NSTextView, savedRange: NSRange, level: Int) {
        guard let textStorage = textView.textStorage else { return }

        // If text is completely empty, we can't apply formatting - just set typing attributes
        if textStorage.length == 0 {
            let baseSize: CGFloat = 14
            let headingSizes: [Int: CGFloat] = [1: 24, 2: 20, 3: 16]
            let targetFontSize = headingSizes[level] ?? baseSize
            let font = NSFont.boldSystemFont(ofSize: targetFontSize)
            textView.typingAttributes = [.font: font]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.updateActiveFormats()
            }
            return
        }

        // Find the paragraph range
        let paragraphRange = (textStorage.string as NSString).paragraphRange(for: savedRange)

        textStorage.beginEditing()

        // Check if this heading level is already applied
        let checkLocation = min(paragraphRange.location, max(0, textStorage.length - 1))
        let currentFont = textStorage.attribute(.font, at: checkLocation, effectiveRange: nil) as? NSFont
        let baseSize: CGFloat = 14
        let headingSizes: [Int: CGFloat] = [1: 24, 2: 20, 3: 16]
        let targetFontSize = headingSizes[level] ?? baseSize

        var isAlreadyThisHeading = false
        if let font = currentFont {
            isAlreadyThisHeading = font.pointSize == targetFontSize &&
                                   NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }

        if isAlreadyThisHeading {
            // Remove heading - revert to normal text
            let font = NSFont.systemFont(ofSize: baseSize)
            textStorage.addAttribute(.font, value: font, range: paragraphRange)
            textView.typingAttributes = [.font: font]
        } else {
            // Apply heading
            let font = NSFont.boldSystemFont(ofSize: targetFontSize)
            textStorage.addAttribute(.font, value: font, range: paragraphRange)
            textView.typingAttributes = [.font: font]
        }

        textStorage.endEditing()

        // Trigger text change notification
        textView.didChangeText()

        // Update active formats after view updates settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.updateActiveFormats()
        }
    }

    private func applyListStyle(textView: NSTextView, savedRange: NSRange, ordered: Bool) {
        guard let textStorage = textView.textStorage else { return }

        textStorage.beginEditing()

        // Find the paragraph range
        let paragraphRange = (textStorage.string as NSString).paragraphRange(for: savedRange)

        // Get the paragraph text
        let paragraphText = (textStorage.string as NSString).substring(with: paragraphRange).trimmingCharacters(in: .newlines)

        // Check for existing indentation
        let indentation = String(paragraphText.prefix(while: { $0 == " " }))

        // Create list marker
        let marker = ordered ? "1. " : "• "

        // Check if the paragraph already starts with a marker (after indentation)
        let trimmedText = paragraphText.trimmingCharacters(in: .whitespaces)
        let hasBullet = trimmedText.hasPrefix("• ")
        let hasNumber = trimmedText.range(of: "^\\d+\\. ", options: .regularExpression) != nil ||
                       trimmedText.range(of: "^[a-z]\\) ", options: .regularExpression) != nil ||
                       trimmedText.range(of: "^[ivxlcdm]+\\. ", options: .regularExpression) != nil

        var newCursorPosition = savedRange.location

        if hasBullet || hasNumber {
            // Remove the marker
            if let markerRange = paragraphText.range(of: "^(  )*(•|\\d+\\.|[a-z]\\)|[ivxlcdm]+\\.) ", options: .regularExpression) {
                let markerLength = paragraphText.distance(from: markerRange.lowerBound, to: markerRange.upperBound)
                let cursorOffsetInParagraph = savedRange.location - paragraphRange.location
                textStorage.replaceCharacters(in: NSRange(location: paragraphRange.location, length: markerLength), with: indentation)
                // Adjust cursor position relative to text removed
                newCursorPosition = paragraphRange.location + max(indentation.count, cursorOffsetInParagraph - markerLength + indentation.count)
            }
        } else {
            // Add the marker at the beginning (after any indentation)
            let insertPos = paragraphRange.location + indentation.count
            let cursorOffsetInParagraph = savedRange.location - paragraphRange.location

            // Get font attributes to preserve them
            var attrs: [NSAttributedString.Key: Any] = [:]
            if insertPos < textStorage.length {
                attrs = textStorage.attributes(at: insertPos, effectiveRange: nil)
            } else if textStorage.length > 0 {
                attrs = textStorage.attributes(at: textStorage.length - 1, effectiveRange: nil)
            }
            // Ensure we have a font
            if attrs[.font] == nil {
                attrs[.font] = NSFont.systemFont(ofSize: 14)
            }

            let markerAttr = NSAttributedString(string: marker, attributes: attrs)
            textStorage.insert(markerAttr, at: insertPos)

            // Position cursor: if it was at the start, move it after the marker
            // If it was elsewhere, shift it by the marker length
            if cursorOffsetInParagraph <= indentation.count {
                newCursorPosition = insertPos + marker.count
            } else {
                newCursorPosition = savedRange.location + marker.count
            }
        }

        textStorage.endEditing()

        // Set cursor position immediately after editing
        textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))

        // Trigger text change notification
        textView.didChangeText()

        // Maintain focus and update active formats after view updates settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            textView.window?.makeFirstResponder(textView)
            self.updateActiveFormats()
        }
    }

    private func toggleTypingAttribute(_ trait: NSFontTraitMask, textView: NSTextView) {
        var attrs = textView.typingAttributes

        // Get current font or use default
        let currentFont = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        let fontManager = NSFontManager.shared

        // Check if trait is currently set
        let currentTraits = fontManager.traits(of: currentFont)
        let newFont: NSFont

        if currentTraits.contains(trait) {
            // Remove the trait
            newFont = fontManager.convert(currentFont, toNotHaveTrait: trait)
        } else {
            // Add the trait
            newFont = fontManager.convert(currentFont, toHaveTrait: trait)
        }

        attrs[.font] = newFont
        textView.typingAttributes = attrs
    }

    private func updateActiveFormats() {
        guard let textView = focusedTextView else {
            activeFormats = []
            return
        }

        guard let textStorage = textView.textStorage else {
            activeFormats = []
            return
        }

        let selectedRange = textView.selectedRange()
        var formats: Set<FormattingType> = []

        // If there's no text or cursor is at/past end, check typing attributes
        let attrs: [NSAttributedString.Key: Any]
        if textStorage.length == 0 || selectedRange.location >= textStorage.length {
            attrs = textView.typingAttributes
        } else {
            // Check font attributes at cursor position
            let location = selectedRange.location > 0 ? selectedRange.location - 1 : 0
            attrs = textStorage.attributes(at: location, effectiveRange: nil)
        }

        // Check for bold, italic
        if let font = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) {
                // Check if it's a heading by font size
                let fontSize = font.pointSize
                if fontSize >= 24 {
                    formats.insert(.heading1)
                } else if fontSize >= 20 {
                    formats.insert(.heading2)
                } else if fontSize >= 16 {
                    formats.insert(.heading3)
                } else {
                    formats.insert(.bold)
                }
            }
            if traits.contains(.italicFontMask) {
                formats.insert(.italic)
            }
        }

        // Check for underline
        if attrs[.underlineStyle] != nil {
            formats.insert(.underline)
        }

        // Check for list markers (with optional even indentation) - only if there's text
        if textStorage.length > 0 {
            let paragraphRange = (textStorage.string as NSString).paragraphRange(for: selectedRange)
            let paragraphText = (textStorage.string as NSString).substring(with: paragraphRange)

            // Count leading spaces
            let leadingSpaces = paragraphText.prefix(while: { $0 == " " }).count

            // Check if it's a valid list (0 or even number of leading spaces)
            if leadingSpaces % 2 == 0 {
                let trimmed = paragraphText.trimmingCharacters(in: .whitespaces)
                // Check for bullet (with or without text after)
                if trimmed.hasPrefix("•") {
                    formats.insert(.bulletList)
                } else if trimmed.range(of: "^(\\d+\\.|[a-z]\\)|[ivxlcdm]+\\.)", options: .regularExpression) != nil {
                    formats.insert(.numberedList)
                }
            }
        }

        activeFormats = formats
    }

    private func navigateUp(from index: Int) {
        guard index > 0 else { return }
        let prevItem = entry.items[index - 1]

        switch prevItem {
        case .text(let textItem):
            focusedTextItemId = textItem.id
            selectedItemId = nil
        case .image(let imageItem):
            selectedItemId = imageItem.id
            focusedTextItemId = nil
        case .video(let videoItem):
            selectedItemId = videoItem.id
            focusedTextItemId = nil
        }
    }

    private func navigateDown(from index: Int) {
        guard index < entry.items.count - 1 else { return }
        let nextItem = entry.items[index + 1]

        switch nextItem {
        case .text(let textItem):
            focusedTextItemId = textItem.id
            selectedItemId = nil
        case .image(let imageItem):
            selectedItemId = imageItem.id
            focusedTextItemId = nil
        case .video(let videoItem):
            selectedItemId = videoItem.id
            focusedTextItemId = nil
        }
    }

    private func handleArrowKey(isUp: Bool) {
        guard let selectedId = selectedItemId else { return }

        // Find the selected item index
        guard let selectedIndex = entry.items.firstIndex(where: { $0.id == selectedId }) else { return }

        if isUp {
            navigateUp(from: selectedIndex)
        } else {
            navigateDown(from: selectedIndex)
        }
    }

    private func handleDelete() {
        guard let selectedId = selectedItemId else { return }

        // Find the selected item index
        guard let selectedIndex = entry.items.firstIndex(where: { $0.id == selectedId }) else { return }

        // Check if it's an image or video
        let item = entry.items[selectedIndex]
        switch item {
        case .image, .video:
            // Capture state for undo
            var itemsBefore: [EntryItem] = []
            var textBeforeItem: TextItem?
            var textAfterItem: TextItem?

            if selectedIndex > 0, case .text(let beforeItem) = entry.items[selectedIndex - 1] {
                textBeforeItem = beforeItem
            }
            if selectedIndex < entry.items.count - 1, case .text(let afterItem) = entry.items[selectedIndex + 1] {
                textAfterItem = afterItem
            }

            // Store items to restore on undo
            if let before = textBeforeItem {
                itemsBefore.append(.text(before))
            }
            itemsBefore.append(item)
            if let after = textAfterItem {
                itemsBefore.append(.text(after))
            }

            // Merge adjacent text items
            let textBefore = textBeforeItem?.content ?? ""
            let textAfter = textAfterItem?.content ?? ""

            // Combine text with blank line if both have content
            let combined: String
            let cursorPos: Int
            if !textBefore.isEmpty && !textAfter.isEmpty {
                combined = textBefore + "\n\n" + textAfter
                cursorPos = textBefore.count + 1 // Position at the first newline
            } else {
                combined = textBefore + textAfter
                cursorPos = textBefore.count
            }

            // Remove the selected item and adjacent text items
            var indicesToRemove = [selectedIndex]
            if selectedIndex > 0, case .text = entry.items[selectedIndex - 1] {
                indicesToRemove.append(selectedIndex - 1)
            }
            if selectedIndex < entry.items.count - 1, case .text = entry.items[selectedIndex + 1] {
                indicesToRemove.append(selectedIndex + 1)
            }

            let insertIndex = indicesToRemove.min() ?? 0

            // Remove items in reverse order (don't register undo for individual removes)
            for index in indicesToRemove.sorted(by: >) {
                entry.removeItem(at: index, registerUndo: false)
            }

            // Add combined text item at the position
            entry.addText(combined, at: insertIndex)

            // Set focus and cursor position
            selectedItemId = nil
            if case .text(let newTextItem) = entry.items[insertIndex] {
                focusedTextItemId = newTextItem.id
                newTextItem.cursorPosition = cursorPos
            }
        case .text:
            break
        }
    }
}

enum FormattingType: Hashable {
    case heading1, heading2, heading3
    case bold, italic, underline
    case bulletList, numberedList
}

struct TextItemView: View {
    @ObservedObject var textItem: TextItem
    @State private var textHeight: CGFloat = 20
    let isFocused: Bool
    let onNavigateUp: () -> Void
    let onNavigateDown: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onImageDrop: ([(NSImage, String)]) -> Void
    let onPaste: () -> Void
    let onTextViewFocusChanged: (CustomNSTextView?) -> Void
    let onSelectionChanged: () -> Void

    var body: some View {
        // Padding above and below depends on whether text is empty
        VStack(spacing: 0) {
            if !textItem.content.isEmpty {
                Spacer()
                    .frame(height: 16)
            }

            MacTextEditor(
                textItem: textItem,
                height: $textHeight,
                isFocused: isFocused,
                onNavigateUp: onNavigateUp,
                onNavigateDown: onNavigateDown,
                onFocusChanged: onFocusChanged,
                onImageDrop: onImageDrop,
                onPaste: onPaste,
                onTextViewFocusChanged: onTextViewFocusChanged,
                onSelectionChanged: onSelectionChanged
            )
            .frame(height: textHeight)
            .frame(maxWidth: .infinity)
            .background(textItem.content.isEmpty ? Color(hex: "eeeeee") : Color(hex: "ffffee"))

            if !textItem.content.isEmpty {
                Spacer()
                    .frame(height: 16)
            }
        }
    }
}

// Native NSTextView wrapper for better keyboard handling
struct MacTextEditor: NSViewRepresentable {
    @ObservedObject var textItem: TextItem
    @Binding var height: CGFloat
    let isFocused: Bool
    let onNavigateUp: () -> Void
    let onNavigateDown: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onImageDrop: ([(NSImage, String)]) -> Void
    let onPaste: () -> Void
    let onTextViewFocusChanged: (CustomNSTextView?) -> Void
    let onSelectionChanged: () -> Void

    func makeNSView(context: Context) -> CustomNSTextView {
        let textView = CustomNSTextView()
        textView.coordinator = context.coordinator
        textView.onImageDrop = context.coordinator.handleImageDrop
        textView.onPaste = onPaste
        textView.onFocusChanged = onTextViewFocusChanged
        textView.onSelectionChanged = onSelectionChanged

        textView.delegate = context.coordinator
        textView.isRichText = true  // Enable rich text
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true

        // Disable undo to avoid crashes (will implement properly later)
        textView.allowsUndo = false

        // Note: CustomNSTextView overrides drag methods to reject file drops

        // Important: disable scrolling and make it grow with content
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // Set up the text container
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        return textView
    }

    func updateNSView(_ textView: CustomNSTextView, context: Context) {
        // Only update attributed text if we're not currently the first responder
        // (i.e., only update when focus changes or external updates occur)
        if textView.window?.firstResponder != textView {
            if textView.attributedString() != textItem.attributedContent {
                textView.textStorage?.setAttributedString(textItem.attributedContent)
            }
        }

        // Handle focus and cursor position
        if isFocused && textView.window?.firstResponder != textView {
            textView.window?.makeFirstResponder(textView)

            // Set cursor position if specified
            if let cursorPos = textItem.cursorPosition {
                let clampedPos = min(cursorPos, textItem.content.count)
                textView.setSelectedRange(NSRange(location: clampedPos, length: 0))
                textItem.cursorPosition = nil // Clear after setting
            }
        }

        // Update height based on content
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let newHeight = max(20, textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 20)

        if abs(height - newHeight) > 1 {
            DispatchQueue.main.async {
                self.height = newHeight
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextEditor

        init(_ parent: MacTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard let textStorage = textView.textStorage else { return }

            // Auto-convert "- " to bullet list
            let selectedRange = textView.selectedRange()
            if selectedRange.location >= 2 {
                // Check if we just typed a space after a dash
                let checkPos = selectedRange.location - 1
                if checkPos < textStorage.length {
                    let charAtCursor = (textStorage.string as NSString).character(at: checkPos)
                    if charAtCursor == 32 { // space character
                        // Check if the character before the space is a dash
                        if checkPos > 0 {
                            let charBeforeSpace = (textStorage.string as NSString).character(at: checkPos - 1)
                            if charBeforeSpace == 45 { // dash character "-"
                                // Check if this dash is at the start of the line (after optional spaces)
                                let paragraphRange = (textStorage.string as NSString).paragraphRange(for: NSRange(location: checkPos - 1, length: 1))
                                let paragraphText = (textStorage.string as NSString).substring(with: paragraphRange)

                                // Count leading spaces
                                var leadingSpaces = 0
                                for char in paragraphText {
                                    if char == " " {
                                        leadingSpaces += 1
                                    } else {
                                        break
                                    }
                                }

                                // Check if the dash is right after the leading spaces
                                let dashPositionInParagraph = checkPos - 1 - paragraphRange.location
                                if dashPositionInParagraph == leadingSpaces {
                                    // Convert "- " to "• "
                                    textStorage.beginEditing()
                                    let dashRange = NSRange(location: checkPos - 1, length: 1)
                                    textStorage.replaceCharacters(in: dashRange, with: "•")
                                    textStorage.endEditing()
                                    // Cursor position stays the same since we replaced 1 char with 1 char
                                }
                            }
                        }
                    }
                }
            }

            // Update the attributed content
            if let attributedString = textStorage.copy() as? NSAttributedString {
                parent.textItem.attributedContent = attributedString
            }

            // Recalculate height when text changes
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let newHeight = max(20, textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 20)

            DispatchQueue.main.async {
                self.parent.height = newHeight
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged(false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.textItem.currentCursorPosition = textView.selectedRange().location

            // Notify about selection change
            if let customTextView = textView as? CustomNSTextView {
                customTextView.onSelectionChanged?()
            }
        }

        func handleImageDrop(_ images: [(NSImage, String)]) {
            parent.onImageDrop(images)
        }
    }
}

// Extension to add font trait toggling
extension NSTextView {
    func applyFontTrait(_ trait: NSFontTraitMask, range: NSRange) {
        guard let textStorage = textStorage else { return }
        guard range.length > 0 else { return }

        textStorage.beginEditing()

        // Check if the trait is already applied
        var hasTraitEverywhere = true
        textStorage.enumerateAttribute(.font, in: range, options: []) { value, subRange, stop in
            if let font = value as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if !traits.contains(trait) {
                    hasTraitEverywhere = false
                    stop.pointee = true
                }
            }
        }

        // Toggle the trait
        textStorage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            if let font = value as? NSFont {
                let newFont: NSFont
                if hasTraitEverywhere {
                    // Remove trait
                    newFont = NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                } else {
                    // Add trait
                    newFont = NSFontManager.shared.convert(font, toHaveTrait: trait)
                }
                textStorage.addAttribute(.font, value: newFont, range: subRange)
            }
        }

        textStorage.endEditing()
    }
}

// Custom NSTextView to handle arrow key navigation
class CustomNSTextView: NSTextView {
    weak var coordinator: MacTextEditor.Coordinator?
    var onImageDrop: ([(NSImage, String)]) -> Void = { _ in }
    var onPaste: (() -> Void)?
    var onFocusChanged: ((CustomNSTextView?) -> Void)?
    var onSelectionChanged: (() -> Void)?
    private var justBecameFirstResponder = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Check if this is a file URL drag
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            // Accept file drops - we'll handle them
            return .copy
        }
        // Allow text drops
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Check if this is a file URL drag
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            // Get the drop location and convert to character index
            let dropPoint = self.convert(sender.draggingLocation, from: nil)
            let dropCharacterIndex = self.getCharacterIndex(at: dropPoint)

            // Store the drop position before processing
            if let coord = self.coordinator {
                coord.parent.textItem.currentCursorPosition = dropCharacterIndex
            }

            // Handle file drops ourselves
            let pasteboard = sender.draggingPasteboard
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
                return false
            }

            var images: [(NSImage, String)] = []
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    images.append((image, url.lastPathComponent))
                }
            }

            if !images.isEmpty {
                DispatchQueue.main.async {
                    self.onImageDrop(images)
                }
                return true
            }
            return false
        }
        // Allow text drops
        return super.performDragOperation(sender)
    }

    func getCharacterIndex(at point: NSPoint) -> Int {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return string.count
        }

        // Adjust point for text container insets
        var containerPoint = point
        containerPoint.x -= textContainerInset.width
        containerPoint.y -= textContainerInset.height

        // Get the character index at this point
        var fraction: CGFloat = 0
        let charIndex = layoutManager.characterIndex(for: containerPoint, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)

        return min(charIndex, string.count)
    }

    override func becomeFirstResponder() -> Bool {
        justBecameFirstResponder = true
        // Reset the flag after a brief moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.justBecameFirstResponder = false
        }
        onFocusChanged?(self)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        onFocusChanged?(nil)
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // Prevent navigation immediately after becoming first responder
        // to avoid double-navigation when focusing empty text items
        if justBecameFirstResponder {
            super.keyDown(with: event)
            return
        }

        // Check for up arrow
        if event.keyCode == 126 { // Up arrow
            if isOnFirstLine() {
                coordinator?.parent.onNavigateUp()
                return
            }
        }
        // Check for down arrow
        else if event.keyCode == 125 { // Down arrow
            if isOnLastLine() {
                coordinator?.parent.onNavigateDown()
                return
            }
        }
        // Check for Return key
        else if event.keyCode == 36 { // Return
            if handleReturnKey() {
                return
            }
        }
        // Check for Tab key
        else if event.keyCode == 48 { // Tab
            if event.modifierFlags.contains(.shift) {
                if handleShiftTab() {
                    return
                }
            } else {
                if handleTab() {
                    return
                }
            }
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Check for Cmd-V (paste)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            if let onPaste = onPaste {
                onPaste()
                return true
            }
        }

        // Check for Cmd-B (bold)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "b" {
            let selectedRange = self.selectedRange()
            if selectedRange.length > 0 {
                applyFontTrait(.boldFontMask, range: selectedRange)
            } else {
                // Toggle bold in typing attributes
                toggleTypingAttributeForTrait(.boldFontMask)
            }
            onSelectionChanged?()
            return true
        }

        // Check for Cmd-I (italic)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "i" {
            let selectedRange = self.selectedRange()
            if selectedRange.length > 0 {
                applyFontTrait(.italicFontMask, range: selectedRange)
            } else {
                // Toggle italic in typing attributes
                toggleTypingAttributeForTrait(.italicFontMask)
            }
            onSelectionChanged?()
            return true
        }

        // Check for Cmd-U (underline)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "u" {
            let selectedRange = self.selectedRange()
            if selectedRange.length > 0 {
                guard let textStorage = textStorage else { return false }
                let attrs = textStorage.attributes(at: selectedRange.location, effectiveRange: nil)
                if attrs[.underlineStyle] != nil {
                    textStorage.removeAttribute(.underlineStyle, range: selectedRange)
                } else {
                    textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: selectedRange)
                }
            } else {
                // Toggle underline in typing attributes
                var attrs = typingAttributes
                if attrs[.underlineStyle] != nil {
                    attrs.removeValue(forKey: .underlineStyle)
                } else {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                typingAttributes = attrs
            }
            onSelectionChanged?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    private func toggleTypingAttributeForTrait(_ trait: NSFontTraitMask) {
        var attrs = typingAttributes

        // Get current font or use default
        let currentFont = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        let fontManager = NSFontManager.shared

        // Check if trait is currently set
        let currentTraits = fontManager.traits(of: currentFont)
        let newFont: NSFont

        if currentTraits.contains(trait) {
            // Remove the trait
            newFont = fontManager.convert(currentFont, toNotHaveTrait: trait)
        } else {
            // Add the trait
            newFont = fontManager.convert(currentFont, toHaveTrait: trait)
        }

        attrs[.font] = newFont
        typingAttributes = attrs
    }

    private func isOnFirstLine() -> Bool {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return false }

        // Ensure layout is complete
        layoutManager.ensureLayout(for: textContainer)

        let selectedRange = self.selectedRange()

        // Empty text or no selection
        guard selectedRange.location != NSNotFound,
              string.count > 0 else { return true }

        // If at position 0, definitely on first line
        if selectedRange.location == 0 {
            return true
        }

        // Check if there's any newline before the cursor position
        let textBeforeCursor = (string as NSString).substring(to: selectedRange.location)
        return !textBeforeCursor.contains("\n")
    }

    private func isOnLastLine() -> Bool {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return false }

        // Ensure layout is complete
        layoutManager.ensureLayout(for: textContainer)

        let selectedRange = self.selectedRange()

        // Empty text or no selection
        guard selectedRange.location != NSNotFound,
              string.count > 0 else { return true }

        // If at the very end, definitely on last line
        if selectedRange.location == string.count {
            return true
        }

        // Check if there's any newline after the cursor position
        let textAfterCursor = (string as NSString).substring(from: selectedRange.location)
        return !textAfterCursor.contains("\n")
    }

    private func handleReturnKey() -> Bool {
        guard let textStorage = textStorage else { return false }

        let selectedRange = self.selectedRange()
        guard selectedRange.location <= textStorage.length else { return false }

        // Get current paragraph range
        let paragraphRange = (textStorage.string as NSString).paragraphRange(for: selectedRange)
        let paragraphText = (textStorage.string as NSString).substring(with: paragraphRange).trimmingCharacters(in: .newlines)

        // Check if we're in a heading - look at the paragraph's font, not just at cursor
        if paragraphRange.length > 0 {
            let checkLocation = paragraphRange.location
            if checkLocation < textStorage.length {
                let attrs = textStorage.attributes(at: checkLocation, effectiveRange: nil)
                if let font = attrs[.font] as? NSFont {
                    let isHeading = font.pointSize >= 16 && NSFontManager.shared.traits(of: font).contains(.boldFontMask)
                    if isHeading {
                        // Insert newline and reset to normal font
                        textStorage.beginEditing()
                        let normalFont = NSFont.systemFont(ofSize: 14)
                        let newlineAttr = NSAttributedString(string: "\n", attributes: [.font: normalFont])
                        textStorage.insert(newlineAttr, at: selectedRange.location)
                        textStorage.endEditing()
                        self.setSelectedRange(NSRange(location: selectedRange.location + 1, length: 0))
                        self.didChangeText()
                        return true
                    }
                }
            }
        }

        // Check for bullet list
        if let bulletMatch = paragraphText.range(of: "^(  )*• ", options: .regularExpression) {
            return handleBulletReturn(paragraphText: paragraphText, paragraphRange: paragraphRange, bulletMatch: bulletMatch)
        }

        // Check for numbered list
        if let numberMatch = paragraphText.range(of: "^(  )*(\\d+\\.|[a-z]\\)|[ivxlcdm]+\\.) ", options: .regularExpression) {
            return handleNumberedReturn(paragraphText: paragraphText, paragraphRange: paragraphRange, numberMatch: numberMatch)
        }

        return false
    }

    private func handleBulletReturn(paragraphText: String, paragraphRange: NSRange, bulletMatch: Range<String.Index>) -> Bool {
        guard let textStorage = textStorage else { return false }

        let selectedRange = self.selectedRange()
        let bulletPrefix = String(paragraphText[bulletMatch])
        let indentation = String(bulletPrefix.prefix(while: { $0 == " " }))
        let contentAfterBullet = paragraphText[bulletMatch.upperBound...].trimmingCharacters(in: .whitespaces)

        textStorage.beginEditing()

        if contentAfterBullet.isEmpty {
            // Empty line - remove bullet (like shift-tab)
            if indentation.count >= 2 {
                // Unindent
                let newBullet = String(repeating: " ", count: indentation.count - 2) + "• "
                let range = NSRange(location: paragraphRange.location, length: bulletPrefix.count)
                textStorage.replaceCharacters(in: range, with: newBullet)
            } else {
                // Remove bullet completely
                let range = NSRange(location: paragraphRange.location, length: bulletPrefix.count)
                textStorage.replaceCharacters(in: range, with: "")
            }
            textStorage.endEditing()
            self.didChangeText()
            return true
        } else {
            // Non-empty line - add new bullet on next line
            let newBullet = "\n" + indentation + "• "

            // Get font attributes to preserve them
            var attrs: [NSAttributedString.Key: Any] = [:]
            if selectedRange.location < textStorage.length && selectedRange.location > 0 {
                attrs = textStorage.attributes(at: selectedRange.location - 1, effectiveRange: nil)
            } else if textStorage.length > 0 {
                attrs = textStorage.attributes(at: textStorage.length - 1, effectiveRange: nil)
            }
            // Ensure we have a font
            if attrs[.font] == nil {
                attrs[.font] = NSFont.systemFont(ofSize: 14)
            }

            let newBulletAttr = NSAttributedString(string: newBullet, attributes: attrs)
            textStorage.insert(newBulletAttr, at: selectedRange.location)
            textStorage.endEditing()
            self.setSelectedRange(NSRange(location: selectedRange.location + newBullet.count, length: 0))
            self.didChangeText()
            return true
        }
    }

    private func handleNumberedReturn(paragraphText: String, paragraphRange: NSRange, numberMatch: Range<String.Index>) -> Bool {
        guard let textStorage = textStorage else { return false }

        let selectedRange = self.selectedRange()
        let numberPrefix = String(paragraphText[numberMatch])
        let indentation = String(numberPrefix.prefix(while: { $0 == " " }))
        let contentAfterNumber = paragraphText[numberMatch.upperBound...].trimmingCharacters(in: .whitespaces)

        textStorage.beginEditing()

        if contentAfterNumber.isEmpty {
            // Empty line - remove number (like shift-tab)
            if indentation.count >= 2 {
                // Unindent - find the correct number to use
                let currentLevel = indentation.count / 2
                let newLevel = currentLevel - 1
                let targetIndentation = String(repeating: " ", count: newLevel * 2)

                var numberToUse = 1

                // Search backwards from current position to find last item at target level
                let textBeforeCursor = (textStorage.string as NSString).substring(to: paragraphRange.location)
                let lines = textBeforeCursor.components(separatedBy: "\n").reversed()

                for line in lines {
                    let trimmedLine = line.trimmingCharacters(in: .newlines)
                    let lineIndentation = String(trimmedLine.prefix(while: { $0 == " " }))

                    if lineIndentation == targetIndentation {
                        if let match = trimmedLine.range(of: "^(  )*(\\d+\\.|[a-z]\\)|[ivxlcdm]+\\.) ", options: .regularExpression) {
                            let foundMarker = String(trimmedLine[match]).trimmingCharacters(in: .whitespaces)
                            numberToUse = extractNumber(from: foundMarker) + 1
                            break
                        }
                    }
                }

                let newNumber = targetIndentation + getListMarker(level: newLevel, isNumbered: true, number: numberToUse)
                let range = NSRange(location: paragraphRange.location, length: numberPrefix.count)
                textStorage.replaceCharacters(in: range, with: newNumber)
            } else {
                // Remove number completely
                let range = NSRange(location: paragraphRange.location, length: numberPrefix.count)
                textStorage.replaceCharacters(in: range, with: "")
            }
            textStorage.endEditing()
            self.didChangeText()
            return true
        } else {
            // Non-empty line - add new number on next line
            let nextNumber = getNextNumber(from: numberPrefix.trimmingCharacters(in: .whitespaces))
            let newNumber = "\n" + indentation + nextNumber

            // Get font attributes to preserve them
            var attrs: [NSAttributedString.Key: Any] = [:]
            if selectedRange.location < textStorage.length && selectedRange.location > 0 {
                attrs = textStorage.attributes(at: selectedRange.location - 1, effectiveRange: nil)
            } else if textStorage.length > 0 {
                attrs = textStorage.attributes(at: textStorage.length - 1, effectiveRange: nil)
            }
            // Ensure we have a font
            if attrs[.font] == nil {
                attrs[.font] = NSFont.systemFont(ofSize: 14)
            }

            let newNumberAttr = NSAttributedString(string: newNumber, attributes: attrs)
            textStorage.insert(newNumberAttr, at: selectedRange.location)
            textStorage.endEditing()
            self.setSelectedRange(NSRange(location: selectedRange.location + newNumber.count, length: 0))
            self.didChangeText()
            return true
        }
    }

    private func handleTab() -> Bool {
        guard let textStorage = textStorage else { return false }

        let selectedRange = self.selectedRange()
        let paragraphRange = (textStorage.string as NSString).paragraphRange(for: selectedRange)
        let paragraphText = (textStorage.string as NSString).substring(with: paragraphRange).trimmingCharacters(in: .newlines)

        // Check if we're in a bullet list
        if paragraphText.range(of: "^(  )*• ", options: .regularExpression) != nil {
            textStorage.beginEditing()

            // Get the font attributes from the paragraph to preserve them
            var attrs: [NSAttributedString.Key: Any] = [:]
            if paragraphRange.location < textStorage.length {
                attrs = textStorage.attributes(at: paragraphRange.location, effectiveRange: nil)
            } else if textStorage.length > 0 {
                attrs = textStorage.attributes(at: textStorage.length - 1, effectiveRange: nil)
            }
            if attrs[.font] == nil {
                attrs[.font] = NSFont.systemFont(ofSize: 14)
            }

            let spacesAttr = NSAttributedString(string: "  ", attributes: attrs)
            textStorage.insert(spacesAttr, at: paragraphRange.location)
            textStorage.endEditing()
            self.setSelectedRange(NSRange(location: selectedRange.location + 2, length: 0))
            self.didChangeText()
            return true
        }

        // Check if we're in a numbered list
        if let numberMatch = paragraphText.range(of: "^(  )*(\\d+\\.|[a-z]\\)|[ivxlcdm]+\\.) ", options: .regularExpression) {
            textStorage.beginEditing()

            let markerText = String(paragraphText[numberMatch])
            let indentation = String(markerText.prefix(while: { $0 == " " }))
            let currentLevel = indentation.count / 2
            let newLevel = currentLevel + 1

            // Get the font attributes to preserve them
            var attrs: [NSAttributedString.Key: Any] = [:]
            if paragraphRange.location < textStorage.length {
                attrs = textStorage.attributes(at: paragraphRange.location, effectiveRange: nil)
            } else if textStorage.length > 0 {
                attrs = textStorage.attributes(at: textStorage.length - 1, effectiveRange: nil)
            }
            if attrs[.font] == nil {
                attrs[.font] = NSFont.systemFont(ofSize: 14)
            }

            // Replace the marker with the new level marker
            let newIndentation = String(repeating: " ", count: newLevel * 2)
            let newMarker = getListMarker(level: newLevel, isNumbered: true, number: 1)
            let newPrefix = newIndentation + newMarker

            let markerLength = paragraphText.distance(from: numberMatch.lowerBound, to: numberMatch.upperBound)
            let newPrefixAttr = NSAttributedString(string: newPrefix, attributes: attrs)
            textStorage.replaceCharacters(in: NSRange(location: paragraphRange.location, length: markerLength), with: newPrefixAttr)

            textStorage.endEditing()
            let newCursorPos = paragraphRange.location + newPrefix.count + (selectedRange.location - paragraphRange.location - markerLength)
            self.setSelectedRange(NSRange(location: max(paragraphRange.location + newPrefix.count, newCursorPos), length: 0))
            self.didChangeText()
            return true
        }

        return false
    }

    private func handleShiftTab() -> Bool {
        guard let textStorage = textStorage else { return false }

        let selectedRange = self.selectedRange()
        let paragraphRange = (textStorage.string as NSString).paragraphRange(for: selectedRange)
        let paragraphText = (textStorage.string as NSString).substring(with: paragraphRange).trimmingCharacters(in: .newlines)

        // Check if we're in a bullet list with indentation
        if paragraphText.range(of: "^(  )+• ", options: .regularExpression) != nil {
            textStorage.beginEditing()
            let range = NSRange(location: paragraphRange.location, length: 2)
            textStorage.replaceCharacters(in: range, with: "")
            textStorage.endEditing()
            self.setSelectedRange(NSRange(location: max(paragraphRange.location, selectedRange.location - 2), length: 0))
            self.didChangeText()
            return true
        }

        // Check if we're in a numbered list with indentation
        if let numberMatch = paragraphText.range(of: "^(  )+(\\d+\\.|[a-z]\\)|[ivxlcdm]+\\.) ", options: .regularExpression) {
            textStorage.beginEditing()

            let markerText = String(paragraphText[numberMatch])
            let indentation = String(markerText.prefix(while: { $0 == " " }))
            let currentLevel = indentation.count / 2
            let newLevel = currentLevel - 1

            // Find the last item at the new level to determine what number to use
            let targetIndentation = String(repeating: " ", count: newLevel * 2)
            var numberToUse = 1

            // Search backwards from current position
            let textBeforeCursor = (textStorage.string as NSString).substring(to: paragraphRange.location)
            let lines = textBeforeCursor.components(separatedBy: "\n").reversed()

            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .newlines)
                let lineIndentation = String(trimmedLine.prefix(while: { $0 == " " }))

                // Check if this line is at the target level
                if lineIndentation == targetIndentation {
                    // Check if it has a number marker
                    if let match = trimmedLine.range(of: "^(  )*(\\d+\\.|[a-z]\\)|[ivxlcdm]+\\.) ", options: .regularExpression) {
                        let foundMarker = String(trimmedLine[match]).trimmingCharacters(in: .whitespaces)
                        numberToUse = extractNumber(from: foundMarker) + 1
                        break
                    }
                }
            }

            // Get the font attributes to preserve them
            var attrs: [NSAttributedString.Key: Any] = [:]
            if paragraphRange.location < textStorage.length {
                attrs = textStorage.attributes(at: paragraphRange.location, effectiveRange: nil)
            } else if textStorage.length > 0 {
                attrs = textStorage.attributes(at: textStorage.length - 1, effectiveRange: nil)
            }
            if attrs[.font] == nil {
                attrs[.font] = NSFont.systemFont(ofSize: 14)
            }

            // Replace the marker with the new level marker
            let newIndentation = targetIndentation
            let newMarker = getListMarker(level: newLevel, isNumbered: true, number: numberToUse)
            let newPrefix = newIndentation + newMarker

            let markerLength = paragraphText.distance(from: numberMatch.lowerBound, to: numberMatch.upperBound)
            let newPrefixAttr = NSAttributedString(string: newPrefix, attributes: attrs)
            textStorage.replaceCharacters(in: NSRange(location: paragraphRange.location, length: markerLength), with: newPrefixAttr)

            textStorage.endEditing()
            let newCursorPos = paragraphRange.location + newPrefix.count + (selectedRange.location - paragraphRange.location - markerLength)
            self.setSelectedRange(NSRange(location: max(paragraphRange.location + newPrefix.count, newCursorPos), length: 0))
            self.didChangeText()
            return true
        }

        // Check if we're at first level (no indentation) - remove marker entirely
        if let match = paragraphText.range(of: "^(•|\\d+\\.|[a-z]\\)|[ivxlcdm]+\\.) ", options: .regularExpression) {
            let markerLength = paragraphText.distance(from: match.lowerBound, to: match.upperBound)
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: NSRange(location: paragraphRange.location, length: markerLength), with: "")
            textStorage.endEditing()
            self.didChangeText()
            return true
        }

        return false
    }

    private func getNextNumber(from marker: String) -> String {
        let trimmed = marker.trimmingCharacters(in: .whitespaces)

        // Handle "1.", "2.", etc.
        if trimmed.hasSuffix("."), let dotIndex = trimmed.lastIndex(of: ".") {
            let numberPart = String(trimmed[..<dotIndex])
            if let num = Int(numberPart) {
                return "\(num + 1). "
            }
            // Try roman numeral
            let nextRoman = incrementRoman(numberPart)
            return "\(nextRoman). "
        }
        // Handle "a)", "b)", etc.
        if trimmed.hasSuffix(")"), let parenIndex = trimmed.lastIndex(of: ")") {
            let letterPart = String(trimmed[..<parenIndex])
            if let char = letterPart.first, char >= "a" && char <= "z" {
                let nextChar = Character(UnicodeScalar(char.asciiValue! + 1))
                return "\(nextChar)) "
            }
        }

        return marker
    }

    private func incrementRoman(_ roman: String) -> String {
        let romanValues = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        var value = 0
        var prevValue = 0

        for char in roman.reversed() {
            let currentValue = romanValues[String(char)] ?? 0
            if currentValue < prevValue {
                value -= currentValue
            } else {
                value += currentValue
            }
            prevValue = currentValue
        }

        return toRoman(value + 1)
    }

    private func toRoman(_ number: Int) -> String {
        let romanNumerals = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                             (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                             (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var result = ""
        var num = number

        for (value, numeral) in romanNumerals {
            while num >= value {
                result += numeral
                num -= value
            }
        }

        return result
    }

    private func getListMarker(level: Int, isNumbered: Bool, number: Int) -> String {
        if !isNumbered {
            return "• "
        }

        let levelType = level % 3
        switch levelType {
        case 0:
            return "\(number). "
        case 1:
            let char = Character(UnicodeScalar(96 + number)!) // a, b, c...
            return "\(char)) "
        case 2:
            return "\(toRoman(number)). "
        default:
            return "\(number). "
        }
    }

    private func extractNumber(from marker: String) -> Int {
        let trimmed = marker.trimmingCharacters(in: .whitespaces)

        // Handle "1.", "2.", etc.
        if trimmed.hasSuffix("."), let dotIndex = trimmed.lastIndex(of: ".") {
            let numberPart = String(trimmed[..<dotIndex])
            if let num = Int(numberPart) {
                return num
            }
            // Try roman numeral
            return fromRoman(numberPart)
        }

        // Handle "a)", "b)", etc.
        if trimmed.hasSuffix(")"), let parenIndex = trimmed.lastIndex(of: ")") {
            let letterPart = String(trimmed[..<parenIndex])
            if let char = letterPart.first, char >= "a" && char <= "z" {
                return Int(char.asciiValue! - 96) // a=1, b=2, etc.
            }
        }

        return 1
    }

    private func fromRoman(_ roman: String) -> Int {
        let romanValues = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        var value = 0
        var prevValue = 0

        for char in roman.reversed() {
            let currentValue = romanValues[String(char)] ?? 0
            if currentValue < prevValue {
                value -= currentValue
            } else {
                value += currentValue
            }
            prevValue = currentValue
        }

        return value
    }
}

// Entry content view extracted to avoid compiler complexity issues
struct EntryContentView: View {
    @ObservedObject var entry: BlogEntry
    @Binding var selectedItemId: UUID?
    @Binding var focusedTextItemId: UUID?
    @Binding var selectedItemIds: Set<UUID>
    let onNavigateUp: (Int) -> Void
    let onNavigateDown: (Int) -> Void
    let onDrop: ([NSItemProvider]) -> Void
    let onDelete: () -> Void
    let onArrowKey: (Bool) -> Void
    let onImageTap: (ImageItem, Int, NSEvent.ModifierFlags) -> Void
    let onVideoTap: (VideoItem, Int, NSEvent.ModifierFlags) -> Void
    let onPaste: () -> Void
    let onTextViewFocusChanged: (CustomNSTextView?) -> Void
    let onSelectionChanged: () -> Void
    @State private var dropTargetIndex: Int? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    ForEach(Array(entry.items.enumerated()), id: \.element.id) { index, item in
                        Group {
                            itemView(for: item, at: index)
                                .id(item.id)
                        }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            // Only handle drops on images/videos here
                            // Text items handle their own drops via NSTextView
                            if case .image = item {
                                handleItemDrop(providers: providers, at: index)
                                return true
                            } else if case .video = item {
                                handleItemDrop(providers: providers, at: index)
                                return true
                            }
                            return false
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                // Drop on empty space - add to the end
                handleDropAtEnd(providers: providers)
                return true
            }
            .onChange(of: focusedTextItemId) { newId in
                if let id = newId {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onChange(of: selectedItemId) { newId in
                if let id = newId {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .background(KeyboardHandler(
            selectedItemId: $selectedItemId,
            onDelete: onDelete,
            onArrowUp: { onArrowKey(true) },
            onArrowDown: { onArrowKey(false) }
        ))
    }

    private func handleTextItemImageDrop(images: [(NSImage, String)], at index: Int, textItem: TextItem) {
        // Insert at cursor position
        let cursorPos = (focusedTextItemId == textItem.id) ? textItem.currentCursorPosition : nil
        entry.insertImages(images, at: index, cursorPosition: cursorPos)

        // Focus on the text item after the last inserted image
        let newFocusIndex = index + (images.count * 2)
        if newFocusIndex < entry.items.count,
           case .text(let newTextItem) = entry.items[newFocusIndex] {
            focusedTextItemId = newTextItem.id
        }
    }

    private func handleDropAtEnd(providers: [NSItemProvider]) {
        // Collect all images first
        var imagesToAdd: [(NSImage, String)] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (item, error) in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   let image = NSImage(contentsOf: url) {
                    let filename = url.lastPathComponent
                    DispatchQueue.main.async {
                        imagesToAdd.append((image, filename))
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
        }

        // When all images are loaded, insert them at the end
        group.notify(queue: .main) {
            guard !imagesToAdd.isEmpty else { return }

            let lastIndex = entry.items.count - 1
            entry.insertImages(imagesToAdd, at: lastIndex, cursorPosition: nil)

            // Focus on the text item after the last inserted image
            let newFocusIndex = lastIndex + (imagesToAdd.count * 2)
            if newFocusIndex < entry.items.count,
               case .text(let newTextItem) = entry.items[newFocusIndex] {
                focusedTextItemId = newTextItem.id
            }
        }
    }

    private func handleItemDrop(providers: [NSItemProvider], at index: Int) {
        // Collect all images first
        var imagesToAdd: [(NSImage, String)] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (item, error) in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   let image = NSImage(contentsOf: url) {
                    let filename = url.lastPathComponent
                    DispatchQueue.main.async {
                        imagesToAdd.append((image, filename))
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
        }

        // When all images are loaded, insert them
        group.notify(queue: .main) {
            guard !imagesToAdd.isEmpty else { return }

            let item = entry.items[index]
            switch item {
            case .text(let textItem):
                // Insert at cursor position
                // If this is the focused text item, use cursor position
                // Otherwise, insert at the end (after all text)
                let cursorPos = (focusedTextItemId == textItem.id) ? textItem.currentCursorPosition : nil
                entry.insertImages(imagesToAdd, at: index, cursorPosition: cursorPos)

                // Focus on the text item after the last inserted image
                let newFocusIndex = index + (imagesToAdd.count * 2)
                if newFocusIndex < entry.items.count,
                   case .text(let newTextItem) = entry.items[newFocusIndex] {
                    focusedTextItemId = newTextItem.id
                }

            case .image, .video:
                // Insert after this item
                entry.insertImages(imagesToAdd, at: index, cursorPosition: nil)
            }
        }
    }

    @ViewBuilder
    private func itemView(for item: EntryItem, at index: Int) -> some View {
        switch item {
        case .text(let textItem):
            TextItemView(
                textItem: textItem,
                isFocused: focusedTextItemId == textItem.id,
                onNavigateUp: {
                    onNavigateUp(index)
                },
                onNavigateDown: {
                    onNavigateDown(index)
                },
                onFocusChanged: { focused in
                    if focused {
                        focusedTextItemId = textItem.id
                        selectedItemId = nil
                    } else if focusedTextItemId == textItem.id {
                        focusedTextItemId = nil
                    }
                },
                onImageDrop: { images in
                    handleTextItemImageDrop(images: images, at: index, textItem: textItem)
                },
                onPaste: onPaste,
                onTextViewFocusChanged: onTextViewFocusChanged,
                onSelectionChanged: onSelectionChanged
            )
        case .image(let imageItem):
            ImageItemView(
                imageItem: imageItem,
                isSelected: selectedItemId == imageItem.id || selectedItemIds.contains(imageItem.id),
                onTap: { modifiers in
                    onImageTap(imageItem, index, modifiers)
                }
            )
        case .video(let videoItem):
            VideoItemView(
                videoItem: videoItem,
                isSelected: selectedItemId == videoItem.id || selectedItemIds.contains(videoItem.id),
                onTap: { modifiers in
                    onVideoTap(videoItem, index, modifiers)
                }
            )
        }
    }
}

// Keyboard event handler for when items are selected
struct KeyboardHandler: NSViewRepresentable {
    @Binding var selectedItemId: UUID?
    let onDelete: () -> Void
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyHandlingView()
        view.onDelete = onDelete
        view.onArrowUp = onArrowUp
        view.onArrowDown = onArrowDown
        view.selectedItemId = selectedItemId
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let keyView = nsView as? KeyHandlingView {
            keyView.selectedItemId = selectedItemId
            if selectedItemId != nil {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

class KeyHandlingView: NSView {
    var selectedItemId: UUID?
    var onDelete: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?

    override var acceptsFirstResponder: Bool { return selectedItemId != nil }

    override func keyDown(with event: NSEvent) {
        guard selectedItemId != nil else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 51, 117: // Delete or Forward Delete
            onDelete?()
        case 126: // Up arrow
            onArrowUp?()
        case 125: // Down arrow
            onArrowDown?()
        default:
            super.keyDown(with: event)
        }
    }
}

struct ImageItemView: View {
    let imageItem: ImageItem
    let isSelected: Bool
    let onTap: (NSEvent.ModifierFlags) -> Void

    var body: some View {
        Group {
            if let resizedImage = imageItem.resizedImage {
                Image(nsImage: resizedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 640, maxHeight: 640)
            }
        }
        .background(Color(hex: "eeeeff"))
        .overlay(
            Rectangle()
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let event = NSApp.currentEvent {
                onTap(event.modifierFlags)
            } else {
                onTap([])
            }
        }
    }
}

struct VideoItemView: View {
    let videoItem: VideoItem
    let isSelected: Bool
    let onTap: (NSEvent.ModifierFlags) -> Void

    var body: some View {
        VStack {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            if let title = videoItem.title {
                Text(title)
                    .font(.headline)
            }

            Text(videoItem.youtubeURL)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(hex: "eeeeff"))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let event = NSApp.currentEvent {
                onTap(event.modifierFlags)
            } else {
                onTap([])
            }
        }
    }
}

struct FormattingToolbar: View {
    let activeFormats: Set<FormattingType>
    let onHeading1: () -> Void
    let onHeading2: () -> Void
    let onHeading3: () -> Void
    let onBold: () -> Void
    let onItalic: () -> Void
    let onUnderline: () -> Void
    let onBulletList: () -> Void
    let onNumberedList: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FormatButton(label: "H1", tooltip: "Heading 1", isActive: activeFormats.contains(.heading1), action: onHeading1)
            FormatButton(label: "H2", tooltip: "Heading 2", isActive: activeFormats.contains(.heading2), action: onHeading2)
            FormatButton(label: "H3", tooltip: "Heading 3", isActive: activeFormats.contains(.heading3), action: onHeading3)

            Divider()
                .frame(height: 20)

            FormatButton(label: "B", tooltip: "Bold", isBold: true, isActive: activeFormats.contains(.bold), action: onBold)
            FormatButton(label: "I", tooltip: "Italic", isItalic: true, isActive: activeFormats.contains(.italic), action: onItalic)
            FormatButton(label: "U", tooltip: "Underline", isUnderlined: true, isActive: activeFormats.contains(.underline), action: onUnderline)

            Divider()
                .frame(height: 20)

            FormatButton(label: "•", tooltip: "Bulleted list", isActive: activeFormats.contains(.bulletList), action: onBulletList)
            FormatButton(label: "1.", tooltip: "Numbered list", isActive: activeFormats.contains(.numberedList), action: onNumberedList)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct FormatButton: NSViewRepresentable {
    let label: String
    let tooltip: String
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderlined: Bool = false
    var isActive: Bool = false
    let action: () -> Void

    func makeNSView(context: Context) -> FormatNSButton {
        let button = FormatNSButton()
        button.isBordered = true
        button.bezelStyle = .rounded
        button.toolTip = tooltip
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked)

        // Configure font traits
        var traits: NSFontTraitMask = []
        if isBold { traits.insert(.boldFontMask) }
        if isItalic { traits.insert(.italicFontMask) }

        let font: NSFont
        if !traits.isEmpty {
            font = NSFontManager.shared.font(withFamily: "System",
                                              traits: traits,
                                              weight: 0,
                                              size: 11) ?? NSFont.systemFont(ofSize: 11)
        } else {
            font = NSFont.systemFont(ofSize: 11)
        }

        // Handle underline with attributed string
        if isUnderlined {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            button.attributedTitle = NSAttributedString(string: label, attributes: attrs)
        } else {
            button.font = font
            button.title = label
        }

        return button
    }

    func updateNSView(_ button: FormatNSButton, context: Context) {
        button.isActive = isActive
        context.coordinator.action = action

        // Update title if needed
        if !isUnderlined && button.title != label {
            button.title = label
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func buttonClicked() {
            action()
        }
    }
}

class FormatNSButton: NSButton {
    var isActive: Bool = false {
        didSet {
            if isActive != oldValue {
                needsDisplay = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.refusesFirstResponder = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.refusesFirstResponder = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw active background if needed
        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            let backgroundRect = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: backgroundRect, xRadius: 4, yRadius: 4)
            path.fill()
        }
        super.draw(dirtyRect)
    }
}

// CutPasteHandler monitors keyboard events for cut/paste shortcuts
struct CutPasteHandler: NSViewRepresentable {
    let canCut: Bool
    let canPaste: Bool
    let onCut: () -> Void
    let onPaste: () -> Void

    func makeNSView(context: Context) -> CutPasteHandlingView {
        let view = CutPasteHandlingView()
        view.canCut = canCut
        view.canPaste = canPaste
        view.onCut = onCut
        view.onPaste = onPaste
        return view
    }

    func updateNSView(_ nsView: CutPasteHandlingView, context: Context) {
        nsView.canCut = canCut
        nsView.canPaste = canPaste
        nsView.onCut = onCut
        nsView.onPaste = onPaste
    }
}

class CutPasteHandlingView: NSView {
    var canCut: Bool = false
    var canPaste: Bool = false
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Check for Cmd-X (cut)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "x" {
            if canCut {
                onCut?()
                return true
            }
        }
        // Check for Cmd-V (paste)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            if canPaste {
                onPaste?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct VideoDialogView: View {
    @Environment(\.dismiss) var dismiss
    @State private var youtubeURL = ""
    @State private var videoTitle = ""
    let entry: BlogEntry

    var body: some View {
        VStack(spacing: 16) {
            Text("Add YouTube Video")
                .font(.headline)

            TextField("YouTube URL", text: $youtubeURL)
                .textFieldStyle(.roundedBorder)

            TextField("Title (optional)", text: $videoTitle)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Add") {
                    entry.addVideo(url: youtubeURL,
                                 title: videoTitle.isEmpty ? nil : videoTitle)
                    dismiss()
                }
                .disabled(youtubeURL.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
