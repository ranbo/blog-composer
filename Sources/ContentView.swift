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

    var body: some View {
        VStack(spacing: 0) {
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
                onNavigateUp: navigateUp,
                onNavigateDown: navigateDown,
                onDrop: handleDrop,
                onDelete: handleDelete,
                onArrowKey: handleArrowKey
            )
        }
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $showVideoDialog) {
            VideoDialogView(entry: entry)
        }
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

struct TextItemView: View {
    @ObservedObject var textItem: TextItem
    @State private var textHeight: CGFloat = 20
    let isFocused: Bool
    let onNavigateUp: () -> Void
    let onNavigateDown: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onImageDrop: ([(NSImage, String)]) -> Void

    var body: some View {
        // Padding above and below depends on whether text is empty
        VStack(spacing: 0) {
            if !textItem.content.isEmpty {
                Spacer()
                    .frame(height: 16)
            }

            MacTextEditor(
                text: $textItem.content,
                height: $textHeight,
                isFocused: isFocused,
                textItem: textItem,
                onNavigateUp: onNavigateUp,
                onNavigateDown: onNavigateDown,
                onFocusChanged: onFocusChanged,
                onImageDrop: onImageDrop
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
    @Binding var text: String
    @Binding var height: CGFloat
    let isFocused: Bool
    @ObservedObject var textItem: TextItem
    let onNavigateUp: () -> Void
    let onNavigateDown: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onImageDrop: ([(NSImage, String)]) -> Void

    func makeNSView(context: Context) -> CustomNSTextView {
        let textView = CustomNSTextView()
        textView.coordinator = context.coordinator
        textView.onImageDrop = context.coordinator.handleImageDrop

        textView.delegate = context.coordinator
        textView.isRichText = false
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
        if textView.string != text {
            textView.string = text
        }

        // Handle focus and cursor position
        if isFocused && textView.window?.firstResponder != textView {
            textView.window?.makeFirstResponder(textView)

            // Set cursor position if specified
            if let cursorPos = textItem.cursorPosition {
                let clampedPos = min(cursorPos, text.count)
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
            parent.text = textView.string

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
        }

        func handleImageDrop(_ images: [(NSImage, String)]) {
            parent.onImageDrop(images)
        }
    }
}

// Custom NSTextView to handle arrow key navigation
class CustomNSTextView: NSTextView {
    weak var coordinator: MacTextEditor.Coordinator?
    var onImageDrop: ([(NSImage, String)]) -> Void = { _ in }
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
        return super.becomeFirstResponder()
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

        super.keyDown(with: event)
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
}

// Entry content view extracted to avoid compiler complexity issues
struct EntryContentView: View {
    @ObservedObject var entry: BlogEntry
    @Binding var selectedItemId: UUID?
    @Binding var focusedTextItemId: UUID?
    let onNavigateUp: (Int) -> Void
    let onNavigateDown: (Int) -> Void
    let onDrop: ([NSItemProvider]) -> Void
    let onDelete: () -> Void
    let onArrowKey: (Bool) -> Void
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
                }
            )
        case .image(let imageItem):
            ImageItemView(
                imageItem: imageItem,
                isSelected: selectedItemId == imageItem.id,
                onTap: {
                    selectedItemId = imageItem.id
                    focusedTextItemId = nil
                }
            )
        case .video(let videoItem):
            VideoItemView(
                videoItem: videoItem,
                isSelected: selectedItemId == videoItem.id,
                onTap: {
                    selectedItemId = videoItem.id
                    focusedTextItemId = nil
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
    let onTap: () -> Void

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
        .onTapGesture {
            onTap()
        }
    }
}

struct VideoItemView: View {
    let videoItem: VideoItem
    let isSelected: Bool
    let onTap: () -> Void

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
        .onTapGesture {
            onTap()
        }
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
