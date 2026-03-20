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

struct LoadProgressOverlay: View {
    let current: Int
    let total: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 12) {
                Text("Loading images…")
                    .font(.headline)
                ProgressView(value: Double(current), total: Double(max(total, 1)))
                    .frame(width: 280)
                Text("\(current) of \(total)")
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
    }
}

struct ImportProgressOverlay: View {
    let current: Int
    let total: Int
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 12) {
                Text("Importing images…")
                    .font(.headline)
                ProgressView(value: Double(current), total: Double(max(total, 1)))
                    .frame(width: 280)
                Text("\(current) of \(total)")
                    .foregroundColor(.secondary)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
    }
}

// Registry mapping TextItem IDs → their live NSTextView instances.
// Used by the find bar to apply highlights directly without routing through SwiftUI state.
class FindRegistry: ObservableObject {
    var textViews: [UUID: CustomNSTextView] = [:]
}

struct FindBarView: View {
    @Binding var query: String
    let focusToken: Int
    let matchCount: Int
    let currentIndex: Int  // -1 when no matches
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            TextField("Find…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($fieldFocused)
                .onSubmit { onNext() }

            if !query.isEmpty {
                if matchCount == 0 {
                    Text("No matches")
                        .foregroundColor(.red)
                        .font(.caption)
                } else {
                    Text("\(currentIndex + 1) of \(matchCount)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .frame(minWidth: 64, alignment: .leading)
                }
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .help("Find Previous (⌘⇧G)")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .help("Find Next (⌘G)")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear { fieldFocused = true }
        .onChange(of: focusToken) { _, _ in fieldFocused = true }
    }
}

struct ContentView: View {
    @StateObject private var entry = BlogEntry()
    @StateObject private var undoCoordinator = UndoCoordinator()
    @State private var showVideoDialog = false
    @State private var pendingVideoDropIndex: Int = 0
    @State private var pendingVideoCursorPosition: Int? = nil
    @State private var selectedItemId: UUID? = nil
    @State private var captionEditingId: UUID? = nil
    @State private var focusedTextItemId: UUID? = nil
    @State private var previousTitle: String = ""
    @State private var selectedItemIds: Set<UUID> = []
    @State private var clipboard: [EntryItem] = []
    @State private var clipboardPasteboardCount: Int = -1 // NSPasteboard changeCount when clipboard was last populated
    @State private var focusedTextView: CustomNSTextView? = nil
    @State private var activeFormats: Set<FormattingType> = []
    @StateObject private var articleManager = ArticleManager()

    // Save functionality state
    @FocusState private var titleFieldFocused: Bool
    @State private var isLoadingArticle = false   // suppresses triggerFolderRename during programmatic changes
    @State private var showUrlUpdateAlert = false
    @State private var pendingFolderName = ""
    @State private var pendingOldGCSFolder = ""
    @State private var autoSaveTimer: Timer?
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""

    // Publish state
    enum PublishState { case idle, publishing, success(URL), failure(String) }
    @State private var publishState: PublishState = .idle
    @State private var articleDate = Date()
    @State private var gcsBucket: String = UserDefaults.standard.string(forKey: "GCSBucket") ?? ""
    @State private var showSyncError = false
    @State private var syncErrorMessage = ""
    @State private var isSyncing = false
    @State private var showRegenerateIndexError = false
    @State private var regenerateIndexErrorMessage = ""
    @State private var syncProgressCompleted: Int = 0
    @State private var syncProgressTotal: Int? = nil
    @State private var syncProgressFiles: [String] = []
    @State private var showSyncProgress = false

    // Import state
    @State private var importProgress: (current: Int, total: Int)? = nil
    @State private var importTask: Task<Void, Never>? = nil

    // Load state
    @State private var loadProgress: (current: Int, total: Int)? = nil

    // Find state
    @StateObject private var findRegistry = FindRegistry()
    @State private var showFindBar = false
    @State private var findFocusToken = 0
    @State private var findQuery = ""
    @State private var findMatches: [(itemId: UUID, range: NSRange, isCaption: Bool)] = []
    @State private var currentMatchIndex = -1
    @State private var findScrollTargetId: UUID? = nil

    @ViewBuilder private var editorPanel: some View {
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
            VStack(spacing: 8) {
                HStack {
                    TextField("Entry Title", text: Binding(
                        get: { entry.title },
                        set: { newValue in
                            if !undoCoordinator.isRestoring && previousTitle != newValue {
                                undoCoordinator.commitTypingIfNeeded(
                                    entry: entry,
                                    focusedTextItemId: focusedTextItemId,
                                    selectedItemId: selectedItemId
                                )
                                undoCoordinator.takeSnapshot(
                                    entry: entry,
                                    actionName: "Title Change",
                                    focusedTextItemId: focusedTextItemId,
                                    selectedItemId: selectedItemId
                                )
                                entry.title = newValue
                                undoCoordinator.commitAction(
                                    entry: entry,
                                    focusedTextItemId: focusedTextItemId,
                                    selectedItemId: selectedItemId
                                )
                                previousTitle = newValue
                            } else {
                                entry.title = newValue
                            }
                        }
                    ))
                        .focused($titleFieldFocused)
                        .textFieldStyle(.roundedBorder)
                        .font(.title)
                        .onSubmit { triggerFolderRename() }

                    Spacer()

                    Button("Save") {
                        saveEntry(isManualSave: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(entry.isDirty ?
                          Color(red: 200/255, green: 200/255, blue: 236/255) :
                          Color(red: 200/255, green: 236/255, blue: 200/255))

                    Button("Add Video") {
                        // Capture cursor position before the sheet steals focus
                        if let id = focusedTextItemId,
                           let idx = entry.items.firstIndex(where: { $0.id == id }),
                           case .text(let textItem) = entry.items[idx] {
                            pendingVideoDropIndex = idx
                            pendingVideoCursorPosition = textItem.currentCursorPosition
                        } else {
                            pendingVideoDropIndex = max(0, entry.items.count - 1)
                            pendingVideoCursorPosition = nil
                        }
                        // Resign first responder now so that when insertVideo mutates
                        // textItem.content the updateNSView guard (firstResponder != textView)
                        // allows the NSTextView to be updated from the model.
                        focusedTextView?.window?.makeFirstResponder(nil)
                        showVideoDialog = true
                    }

                    Button("Preview") {
                        previewEntry()
                    }

                    // Publish / Update button
                    Group {
                        if case .publishing = publishState {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text(isPublished ? "Updating…" : "Publishing…")
                                    .foregroundColor(.secondary)
                            }
                        } else if case .success(let url) = publishState {
                            Button(isPublished ? "Updated ✓" : "Published ✓") {
                                // For published articles with a bucket, open the live remote URL.
                                // For drafts just promoted to TravelBlog, open the local file.
                                if isPublished,
                                   !gcsBucket.isEmpty,
                                   let folder = entry.filePath?.deletingLastPathComponent().lastPathComponent,
                                   let remoteURL = URL(string: "https://\(gcsBucket)/\(folder)/") {
                                    NSWorkspace.shared.open(remoteURL)
                                } else {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .foregroundColor(.green)
                        } else if isPublished {
                            Button("Update") {
                                Task { await updateToGCS() }
                            }
                            .disabled(gcsBucket.isEmpty)
                            .help(gcsBucket.isEmpty
                                  ? "Enter a GCS bucket name to enable Update"
                                  : "Regenerate images, update index, and sync this article to GCS")
                        } else {
                            Button("Publish") {
                                Task { await publishToTravelBlog(date: articleDate) }
                            }
                        }
                    }

                }

                // Date + folder name + GCS bucket
                HStack(spacing: 6) {
                    DatePicker("", selection: $articleDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .onChange(of: articleDate) { _, _ in
                            triggerFolderRename()
                        }

                    Text("•").foregroundColor(.secondary)

                    Text(currentFolderName)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(mediaCount == 1 ? "1 image" : "\(mediaCount) images")
                        .foregroundColor(.secondary)

                    Text("GCS:")
                        .foregroundColor(.secondary)
                    TextField("bucket-name", text: $gcsBucket)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .onChange(of: gcsBucket) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "GCSBucket")
                        }
                }
                .font(.caption)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if showFindBar {
                FindBarView(
                    query: $findQuery,
                    focusToken: findFocusToken,
                    matchCount: findMatches.count,
                    currentIndex: currentMatchIndex,
                    onPrevious: findPrevious,
                    onNext: findNext,
                    onClose: closeFindBar
                )
                .onChange(of: findQuery) { _, _ in computeFindMatches() }
                Divider()
            }

            // Main content area
            EntryContentView(
                entry: entry,
                selectedItemId: $selectedItemId,
                captionEditingId: $captionEditingId,
                focusedTextItemId: $focusedTextItemId,
                selectedItemIds: $selectedItemIds,
                findScrollTargetId: $findScrollTargetId,
                onNavigateUp: navigateUp,
                onNavigateDown: navigateDown,
                onDrop: handleDrop,
                onDelete: handleDelete,
                onArrowKey: handleArrowKey,
                onEnterKey: handleEnterKey,
                onEscapeKey: {
                    if showFindBar {
                        closeFindBar()
                    } else {
                        selectedItemId = nil
                        selectedItemIds.removeAll()
                    }
                },
                onUpdateCaption: updateImageCaption,
                onImageTap: handleImageTap,
                onVideoTap: handleVideoTap,
                onPaste: handlePaste,
                onTextViewFocusChanged: { textView in
                    focusedTextView = textView
                    updateActiveFormats()
                },
                onSelectionChanged: {
                    updateActiveFormats()
                },
                onImageURLsDrop: { urls, index, cursorPos in
                    importImages(urls: urls, at: index, cursorPosition: cursorPos)
                },
                onTextDidChange: {
                    undoCoordinator.handleTyping(
                        entry: entry,
                        focusedTextItemId: focusedTextItemId,
                        selectedItemId: selectedItemId
                    )
                },
                onUndo: performUndo,
                onRedo: performRedo
            )
            .overlay {
                if let progress = importProgress {
                    ImportProgressOverlay(current: progress.current, total: progress.total) {
                        importTask?.cancel()
                    }
                } else if let progress = loadProgress {
                    LoadProgressOverlay(current: progress.current, total: progress.total)
                }
            }
        }
    }

    var body: some View {
        mainLayout
            .focusedValue(\.undoCoordinator, undoCoordinator)
            .focusedValue(\.undoAction, performUndo)
            .focusedValue(\.redoAction, performRedo)
            .focusedValue(\.syncAction, gcsBucket.isEmpty || isSyncing ? nil : syncToGCSSync)
            .focusedValue(\.regenerateIndexAction, regenerateIndex)
            .focusedValue(\.applyFormattingAction, applyFormatting)
            .focusedValue(\.findAction, openFind)
            .focusedValue(\.findNextAction, findNext)
            .focusedValue(\.findPreviousAction, findPrevious)
            .focusedValue(\.newEntryAction, createNewArticle)
    }

    private var mediaCount: Int {
        entry.items.filter {
            if case .image = $0 { return true }
            if case .video = $0 { return true }
            return false
        }.count
    }

    private var mainLayout: some View {
        HSplitView {
            ArticleSidebarView(
                articles: articleManager.articles,
                selectedFolderURL: entry.filePath?.deletingLastPathComponent(),
                onSelect: loadArticle,
                onNew: createNewArticle
            )
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 350)

            editorPanel
        }
        .frame(minWidth: 900, minHeight: 600)
        .environmentObject(findRegistry)
        .sheet(isPresented: $showVideoDialog) {
            VideoDialogView(onAdd: { url, title in
                entry.insertVideo(url: url, title: title,
                                  at: pendingVideoDropIndex,
                                  cursorPosition: pendingVideoCursorPosition)
                // Move focus to the text item that follows the new video
                let newFocusIndex = pendingVideoDropIndex + 2
                if newFocusIndex < entry.items.count,
                   case .text(let nextText) = entry.items[newFocusIndex] {
                    focusedTextItemId = nextText.id
                }
                undoCoordinator.commitAction(entry: entry,
                                             focusedTextItemId: focusedTextItemId,
                                             selectedItemId: selectedItemId)
            })
        }
        .alert("Sync Failed", isPresented: $showSyncError) {
            Button("OK") { showSyncError = false }
        } message: {
            Text(syncErrorMessage)
        }
        .sheet(isPresented: $showSyncProgress) {
            SyncProgressSheet(
                completed: syncProgressCompleted,
                total: syncProgressTotal,
                recentFiles: syncProgressFiles
            )
        }
        .background(CutPasteHandler(
            canCut: canCut(),
            canPaste: canPaste(),
            canUndo: undoCoordinator.canUndo,
            canRedo: undoCoordinator.canRedo,
            onCut: handleCut,
            onPaste: { _ = handlePaste() },
            onUndo: performUndo,
            onRedo: performRedo
        ))
        .task {
            // Set up auto-save timer
            autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
                if entry.isDirty {
                    saveEntry(isManualSave: false)
                }
            }

            // Load from last saved path — try stored path, then fall back to index.html in same folder
            let urlToLoad: URL?
            if let lastPath = SaveCoordinator.loadLastFilePath() {
                if FileManager.default.fileExists(atPath: lastPath.path) {
                    urlToLoad = lastPath
                } else {
                    // Legacy path may point to <name>.html; try index.html in the same folder
                    let indexURL = lastPath.deletingLastPathComponent()
                        .appendingPathComponent("index.html")
                    urlToLoad = FileManager.default.fileExists(atPath: indexURL.path) ? indexURL : nil
                }
            } else {
                urlToLoad = nil
            }

            if let url = urlToLoad {
                do {
                    // Backfill missing small/ JPEGs before populating entry so ImageItemViews
                    // always find the files ready on their first onAppear.
                    let startFolder = url.deletingLastPathComponent()
                    await Task.detached(priority: .userInitiated) {
                        TravelBlogPublisher.generateMissingSmallImages(in: startFolder)
                    }.value
                    try await HTMLParser.load(from: url, into: entry)
                    previousTitle = entry.title
                    print("Loaded from: \(url.path)")
                    await generateMissingWebImages(baseURL: url.deletingLastPathComponent())
                } catch {
                    print("Failed to load HTML: \(error)")
                    SaveCoordinator.initializeDefaultPath(for: entry)
                }
            } else {
                SaveCoordinator.initializeDefaultPath(for: entry)
            }
            loadProgress = nil
            previousTitle = entry.title

            // Set articleDate from the loaded folder's date prefix (suppress rename trigger)
            let folderName = entry.filePath?.deletingLastPathComponent().lastPathComponent ?? ""
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            if folderName.count >= 10, let d = dateFmt.date(from: String(folderName.prefix(10))) {
                isLoadingArticle = true
                articleDate = d
                await Task.yield()   // let the onChange fire while flag is still set
                isLoadingArticle = false
            }

            // Populate the article sidebar
            articleManager.refresh()
        }
        .onDisappear {
            // Clean up timer
            autoSaveTimer?.invalidate()
            autoSaveTimer = nil
        }
        .alert("Update URL?", isPresented: $showUrlUpdateAlert) {
            Button("Update URL") { performFolderRenameAndMoveGCS() }
            Button("Keep as-is", role: .cancel) { }
        } message: {
            Text("Rename folder to '\(pendingFolderName)'? Existing links to this article may break.")
        }
        .alert("Save Error", isPresented: $showSaveError) {
            Button("OK") {
                showSaveError = false
            }
        } message: {
            Text(saveErrorMessage)
        }
        .alert("Publish Failed", isPresented: Binding(
            get: { if case .failure = publishState { return true } else { return false } },
            set: { if !$0 { publishState = .idle } }
        )) {
            Button("OK") { publishState = .idle }
        } message: {
            if case .failure(let msg) = publishState { Text(msg) }
        }
        .alert("Index Generation Failed", isPresented: $showRegenerateIndexError) {
            Button("OK") { showRegenerateIndexError = false }
        } message: {
            Text(regenerateIndexErrorMessage)
        }
        .onChange(of: entry.isDirty) { _, isDirty in
            if isDirty, case .success = publishState {
                publishState = .idle
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        // This is now handled by per-item drops
        // Keep for backwards compatibility but shouldn't be called
    }

    private func importImages(urls: [URL], at dropIndex: Int, cursorPosition: Int?) {
        guard let filePath = entry.filePath else { return }
        let baseURL = filePath.deletingLastPathComponent()

        try? FileManager.default.createBlogDirectoryStructure(at: baseURL)

        undoCoordinator.commitTypingIfNeeded(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
        undoCoordinator.takeSnapshot(entry: entry, actionName: "Import Images", focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)

        importProgress = (0, urls.count)

        importTask = Task {
            defer { Task { @MainActor in importProgress = nil; importTask = nil } }

            var processed: [ImageItem] = []

            for (i, url) in urls.enumerated() {
                if Task.isCancelled { break }

                let filename = url.lastPathComponent
                let fullDir = baseURL.appendingPathComponent("full")
                let tempURL = fullDir.appendingPathComponent(".tmp_\(UUID().uuidString)_\(filename)")

                do {
                    // Copy raw bytes to avoid re-encoding — preserves original quality
                    let data = try Data(contentsOf: url)
                    try data.write(to: tempURL)

                    if Task.isCancelled {
                        try? FileManager.default.removeItem(at: tempURL)
                        break
                    }

                    // Atomic rename to final location
                    let finalURL = fullDir.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)

                    // Save 640px small/ JPEG via ImageIO (handles HEIC, JPG, etc. reliably)
                    try FileManager.default.saveSmallImage(at: finalURL, filename: filename, to: baseURL)

                    // Resize for in-memory display — full-res NSImage released when this scope exits
                    guard let fullImage = NSImage(contentsOf: finalURL),
                          let resized = ImageItem.resize(image: fullImage, maxDimension: 640) else {
                        continue
                    }
                    // Generate 1600px web/ JPEG for browser-compatible lightbox display
                    try? FileManager.default.saveWebImage(at: finalURL, filename: filename, to: baseURL)
                    var imageItem = ImageItem(resizedImage: resized, filename: filename)
                    imageItem.caption = FileManager.readCaption(at: finalURL)
                    processed.append(imageItem)

                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                    print("Import failed for \(filename): \(error)")
                }

                let count = i + 1
                await MainActor.run { importProgress = (count, urls.count) }
            }

            if !processed.isEmpty {
                await MainActor.run {
                    entry.insertImages(processed, at: dropIndex, cursorPosition: cursorPosition)
                    // Always clear selection after import so KeyHandlingView doesn't steal focus
                    selectedItemId = nil
                    selectedItemIds.removeAll()
                    // Focus the text item after the last inserted image
                    let newFocusIndex = dropIndex + (processed.count * 2)
                    if newFocusIndex < entry.items.count,
                       case .text(let textItem) = entry.items[newFocusIndex] {
                        focusedTextItemId = textItem.id
                    }
                    undoCoordinator.commitAction(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
                }
            }
        }
    }

    private func previewEntry() {
        saveEntry(isManualSave: false)
        guard let filePath = entry.filePath else { return }
        NSWorkspace.shared.open(filePath)
    }

    private func publishToTravelBlog(date: Date) async {
        saveEntry(isManualSave: false)
        publishState = .publishing
        do {
            let publishedURL = try TravelBlogPublisher.publish(entry: entry, date: date, domain: gcsBucket.isEmpty ? nil : gcsBucket)
            // Update entry path if the article was moved (draft → TravelBlog)
            if entry.filePath?.path != publishedURL.path {
                let oldBase = entry.filePath?.deletingLastPathComponent()
                entry.filePath = publishedURL
                // Remap in-memory smallURLs (including clipboard) to the new folder location
                if let old = oldBase, let newBase = entry.filePath?.deletingLastPathComponent() {
                    remapImageSmallURLs(from: old, to: newBase)
                }
                entry.isDirty = false
                SaveCoordinator.saveLastFilePath(publishedURL)
            }
            articleManager.refresh()
            // Sync to GCS if a bucket is configured
            if !gcsBucket.isEmpty {
                let articleDir = publishedURL.deletingLastPathComponent()
                try await TravelBlogPublisher.syncArticle(folderURL: articleDir, bucketName: gcsBucket)
            }
            publishState = .success(publishedURL)
        } catch {
            publishState = .failure(error.localizedDescription)
        }
    }

    /// Called when the article is already in TravelBlog/: regenerates local files
    /// then pushes just this article folder (plus root index.html and util/) to GCS.
    private func updateToGCS() async {
        guard !gcsBucket.isEmpty else { return }
        saveEntry(isManualSave: false)
        publishState = .publishing
        do {
            // Regenerate web/ images and rebuild root index.html
            let publishedURL = try TravelBlogPublisher.publish(entry: entry, date: Date(), domain: gcsBucket.isEmpty ? nil : gcsBucket)
            // Sync the article folder (rsync skips unchanged files; new images are included)
            guard let filePath = entry.filePath else {
                publishState = .failure("Lost file path after publish")
                return
            }
            let articleDir = filePath.deletingLastPathComponent()
            try await TravelBlogPublisher.syncArticle(folderURL: articleDir, bucketName: gcsBucket)
            publishState = .success(publishedURL)
        } catch {
            publishState = .failure(error.localizedDescription)
        }
    }

    // MARK: - Find

    private func openFind() {
        // If there's a text selection in the focused text view, pre-fill query with it
        if let textView = focusedTextView {
            let sel = textView.selectedRange()
            if sel.length > 0, let str = textView.textStorage?.mutableString {
                let selectedText = str.substring(with: sel)
                if !selectedText.isEmpty {
                    findQuery = selectedText
                }
            }
        }
        showFindBar = true
        findFocusToken += 1   // always re-focus the search field, even if bar was already open
        computeFindMatches()
    }

    private func closeFindBar() {
        showFindBar = false
        findQuery = ""
        findMatches = []
        currentMatchIndex = -1
        findScrollTargetId = nil
    }

    private func computeFindMatches() {
        guard !findQuery.isEmpty else {
            findMatches = []
            currentMatchIndex = -1
            return
        }
        var results: [(itemId: UUID, range: NSRange, isCaption: Bool)] = []

        func searchString(_ str: NSString, itemId: UUID, isCaption: Bool) {
            var searchRange = NSRange(location: 0, length: str.length)
            while searchRange.length > 0 {
                let range = str.range(of: findQuery,
                                      options: [.caseInsensitive, .diacriticInsensitive],
                                      range: searchRange)
                if range.location == NSNotFound { break }
                results.append((itemId: itemId, range: range, isCaption: isCaption))
                let next = range.location + range.length
                searchRange = NSRange(location: next, length: str.length - next)
            }
        }

        for item in entry.items {
            switch item {
            case .text(let textItem):
                searchString(textItem.attributedContent.string as NSString,
                             itemId: textItem.id, isCaption: false)
            case .image(let imageItem):
                if let caption = imageItem.caption, !caption.isEmpty {
                    searchString(caption as NSString, itemId: imageItem.id, isCaption: true)
                }
            case .video:
                break
            }
        }
        findMatches = results
        if results.isEmpty {
            currentMatchIndex = -1
        } else {
            currentMatchIndex = 0
            applyFindMatch(at: 0)
        }
    }

    private func applyFindMatch(at index: Int) {
        guard index >= 0, index < findMatches.count else { return }
        let match = findMatches[index]
        if match.isCaption {
            // Open the caption editor so the match is visible, then scroll to the image
            captionEditingId = match.itemId
        } else if let textView = findRegistry.textViews[match.itemId] {
            let len = textView.textStorage?.length ?? 0
            let loc = min(match.range.location, len)
            let length = min(match.range.length, max(0, len - loc))
            if length > 0 {
                let clampedRange = NSRange(location: loc, length: length)
                textView.setSelectedRange(clampedRange)
                textView.showFindIndicator(for: clampedRange)
            }
        }
        findScrollTargetId = match.itemId
    }

    private func findNext() {
        if !showFindBar { showFindBar = true; computeFindMatches(); return }
        guard !findMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % findMatches.count
        applyFindMatch(at: currentMatchIndex)
    }

    private func findPrevious() {
        if !showFindBar { showFindBar = true; computeFindMatches(); return }
        guard !findMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + findMatches.count) % findMatches.count
        applyFindMatch(at: currentMatchIndex)
    }

    private func syncToGCSSync() {
        Task { await syncToGCS() }
    }

    private func syncToGCS() async {
        guard !gcsBucket.isEmpty else { return }
        isSyncing = true

        // Phase 1: generate missing small/ and web/ images for every published article.
        // Runs on a background thread; progress shown via LoadProgressOverlay.
        let dirs = TravelBlogPublisher.articleDirectories
        if !dirs.isEmpty {
            loadProgress = (0, dirs.count)
            for (i, dir) in dirs.enumerated() {
                await Task.detached(priority: .userInitiated) {
                    TravelBlogPublisher.generateMissingSmallImages(in: dir)
                    try? TravelBlogPublisher.generateMissingWebImages(in: dir)
                }.value
                loadProgress = (i + 1, dirs.count)
            }
            loadProgress = nil
        }

        // Phase 2: regenerate index.html and util/ so rsync doesn't delete them.
        // (--delete-unmatched-destination-objects would remove any GCS file missing locally.)
        try? TravelBlogPublisher.regenerateIndex(domain: gcsBucket.isEmpty ? nil : gcsBucket)
        try? TravelBlogPublisher.ensureUtilFiles()

        // Phase 3: rsync everything to GCS.
        syncProgressCompleted = 0
        syncProgressTotal = nil
        syncProgressFiles = []
        showSyncProgress = true

        do {
            try await TravelBlogPublisher.sync(bucketName: gcsBucket) { update in
                self.syncProgressCompleted = update.completed
                self.syncProgressTotal = update.total
                if let file = update.lastFile {
                    self.syncProgressFiles.append(file)
                    // Cap the list so memory stays bounded on a huge first sync
                    if self.syncProgressFiles.count > 500 {
                        self.syncProgressFiles.removeFirst()
                    }
                }
            }
        } catch {
            syncErrorMessage = error.localizedDescription
            showSyncError = true
        }

        showSyncProgress = false
        isSyncing = false
    }

    private func regenerateIndex() {
        Task {
            // Repair missing small/ and web/ images for every article (Drafts + TravelBlog).
            let dirs = articleManager.articles.map { $0.folderURL }
            if !dirs.isEmpty {
                loadProgress = (0, dirs.count)
                for (i, dir) in dirs.enumerated() {
                    let d = dir
                    await Task.detached(priority: .userInitiated) {
                        TravelBlogPublisher.generateMissingSmallImages(in: d)
                        try? TravelBlogPublisher.generateMissingWebImages(in: d)
                    }.value
                    loadProgress = (i + 1, dirs.count)
                }
                loadProgress = nil
            }
            do {
                try TravelBlogPublisher.regenerateIndex(domain: gcsBucket.isEmpty ? nil : gcsBucket)
                articleManager.refresh()
            } catch {
                regenerateIndexErrorMessage = error.localizedDescription
                showRegenerateIndexError = true
            }
        }
    }

    /// Returns the desired folder name derived from the current articleDate + title slug.
    private func computeDesiredFolderName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: articleDate)
        let slug = ArticleManager.slugify(entry.title)
        return slug.isEmpty ? dateStr : "\(dateStr)_\(slug)"
    }

    /// Triggers a folder rename if the desired name differs from the current one.
    /// For unpublished articles, renames immediately. For published, shows an alert.
    private func triggerFolderRename() {
        guard !isLoadingArticle else { return }
        let desired = computeDesiredFolderName()
        guard desired != currentFolderName else { return }

        if isPublished {
            pendingFolderName = desired
            pendingOldGCSFolder = currentFolderName
            showUrlUpdateAlert = true
        } else {
            performFolderRename(newFolderName: desired)
        }
    }

    /// Renames the local folder to `newFolderName`.
    private func performFolderRename(newFolderName: String) {
        let oldBase = entry.filePath?.deletingLastPathComponent()
        do {
            try SaveCoordinator.updatePath(for: entry, newFolderName: newFolderName)
            if let old = oldBase, let newBase = entry.filePath?.deletingLastPathComponent(), old != newBase {
                remapImageSmallURLs(from: old, to: newBase)
            }
            saveEntry(isManualSave: false)
            articleManager.refresh()
        } catch {
            saveErrorMessage = error.localizedDescription
            showSaveError = true
        }
    }

    /// Renames the local folder and moves GCS objects to match (for published articles).
    private func performFolderRenameAndMoveGCS() {
        let oldFolder = pendingOldGCSFolder
        let newFolderName = pendingFolderName
        let oldBase = entry.filePath?.deletingLastPathComponent()

        do {
            try SaveCoordinator.updatePath(for: entry, newFolderName: newFolderName)
            if let old = oldBase, let newBase = entry.filePath?.deletingLastPathComponent(), old != newBase {
                remapImageSmallURLs(from: old, to: newBase)
            }
            saveEntry(isManualSave: false)
            articleManager.refresh()
        } catch {
            saveErrorMessage = error.localizedDescription
            showSaveError = true
            return
        }

        guard !gcsBucket.isEmpty else { return }
        let bucket = gcsBucket
        Task {
            do {
                try await TravelBlogPublisher.moveGCSFolder(
                    oldFolder: oldFolder, newFolder: newFolderName, bucketName: bucket)
            } catch {
                await MainActor.run {
                    saveErrorMessage = "Folder renamed locally, but GCS move failed: \(error.localizedDescription)"
                    showSaveError = true
                }
            }
        }
    }

    /// After a folder rename, repoints all imageItem.smallURL values (in entry.items, clipboard,
    /// and undo/redo snapshots) to the new folder so lazy-load and undo still work.
    private func remapImageSmallURLs(from oldBase: URL, to newBase: URL) {
        let oldPrefix = oldBase.path + "/"
        for i in entry.items.indices {
            if case .image(var imageItem) = entry.items[i],
               let url = imageItem.smallURL,
               url.path.hasPrefix(oldPrefix) {
                let relative = String(url.path.dropFirst(oldPrefix.count))
                imageItem.smallURL = newBase.appendingPathComponent(relative)
                entry.items[i] = .image(imageItem)
            }
        }
        clipboard = clipboard.map { item in
            guard case .image(var imageItem) = item,
                  let url = imageItem.smallURL,
                  url.path.hasPrefix(oldPrefix) else { return item }
            let relative = String(url.path.dropFirst(oldPrefix.count))
            imageItem.smallURL = newBase.appendingPathComponent(relative)
            return .image(imageItem)
        }
        undoCoordinator.remapSmallURLs(from: oldBase, to: newBase)
    }

    // MARK: - Image backfill

    /// Generates web/ (1600px JPEG) for any image in full/ referenced by the entry
    /// that doesn't already have a web/ version. Runs encoding off the main thread.
    private func generateMissingWebImages(baseURL: URL) async {
        let fullDir = baseURL.appendingPathComponent("full")
        let webDir  = baseURL.appendingPathComponent("web")

        let needed: [(filename: String, sourceURL: URL)] = entry.items.compactMap { item in
            guard case .image(let img) = item else { return nil }
            let base = (img.filename as NSString).deletingPathExtension
            let webFile = webDir.appendingPathComponent("\(base).jpg")
            guard !FileManager.default.fileExists(atPath: webFile.path) else { return nil }
            let src = fullDir.appendingPathComponent(img.filename)
            guard FileManager.default.fileExists(atPath: src.path) else { return nil }
            return (img.filename, src)
        }
        guard !needed.isEmpty else { return }

        loadProgress = (0, needed.count)
        for (done, (filename, sourceURL)) in needed.enumerated() {
            // Encode on a background thread so the UI stays responsive
            let b = baseURL, f = filename, s = sourceURL
            await Task.detached(priority: .userInitiated) {
                try? FileManager.default.saveWebImage(at: s, filename: f, to: b)
            }.value
            loadProgress = (done + 1, needed.count)
        }
    }

    // MARK: - Save functionality

    /// True when the currently loaded article lives in TravelBlog/ (already published).
    private var isPublished: Bool {
        guard let filePath = entry.filePath else { return false }
        let articleDir = filePath.deletingLastPathComponent()
        return articleDir.deletingLastPathComponent().standardized.path
            == TravelBlogPublisher.travelBlogDir.standardized.path
    }

    private var currentFolderName: String {
        guard let filePath = entry.filePath else {
            return "untitled"
        }
        return filePath.deletingLastPathComponent().lastPathComponent
    }

    private func saveEntry(isManualSave: Bool) {
        do {
            try SaveCoordinator.save(entry: entry, isManualSave: isManualSave, domain: gcsBucket.isEmpty ? nil : gcsBucket)

            if isManualSave {
                print("Entry saved successfully")
            }
        } catch {
            saveErrorMessage = error.localizedDescription
            showSaveError = true
            print("Save failed: \(error)")
        }
    }

    private func canCut() -> Bool {
        return !selectedItemIds.isEmpty || selectedItemId != nil
    }

    private func canPaste() -> Bool {
        guard !clipboard.isEmpty else { return false }
        // If the system pasteboard changed after our cut (user did native copy/cut),
        // let NSTextView handle Cmd-V natively instead of using our internal clipboard.
        guard NSPasteboard.general.changeCount == clipboardPasteboardCount else { return false }
        return focusedTextItemId != nil || selectedItemId != nil
    }

    private func handleCut() {
        undoCoordinator.commitTypingIfNeeded(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
        undoCoordinator.takeSnapshot(entry: entry, actionName: "Cut", focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)

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
        clipboardPasteboardCount = NSPasteboard.general.changeCount

        // Find text items before first and after last cut item
        let firstIndex = indicesToCut.first!
        let lastIndex = indicesToCut.last!

        var attrBefore: NSAttributedString? = nil
        var attrAfter: NSAttributedString? = nil

        if firstIndex > 0, case .text(let beforeItem) = entry.items[firstIndex - 1] {
            if beforeItem.attributedContent.length > 0 { attrBefore = beforeItem.attributedContent }
        }

        if lastIndex < entry.items.count - 1, case .text(let afterItem) = entry.items[lastIndex + 1] {
            if afterItem.attributedContent.length > 0 { attrAfter = afterItem.attributedContent }
        }

        // Combine attributed strings, preserving all formatting (headings, bold, etc.)
        let combinedAttr: NSAttributedString = {
            switch (attrBefore, attrAfter) {
            case (let b?, let a?):
                let m = NSMutableAttributedString(attributedString: b)
                m.append(NSAttributedString(string: "\n\n"))
                m.append(a)
                return m
            case (let b?, nil): return b
            case (nil, let a?): return a
            case (nil, nil):    return NSAttributedString()
            }
        }()

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

        // Insert combined text item, preserving attributed formatting
        let insertIndex = toRemove.min()!
        entry.items.insert(.text(TextItem(attributedContent: combinedAttr)), at: insertIndex)

        // Clear selection
        selectedItemId = nil
        selectedItemIds.removeAll()

        undoCoordinator.commitAction(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
    }

    @discardableResult
    private func handlePaste() -> Bool {
        guard !clipboard.isEmpty else { return false }
        guard NSPasteboard.general.changeCount == clipboardPasteboardCount else { return false }

        undoCoordinator.commitTypingIfNeeded(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
        undoCoordinator.takeSnapshot(entry: entry, actionName: "Paste", focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)

        // Determine where to paste
        if let focusedId = focusedTextItemId,
           let focusedIndex = entry.items.firstIndex(where: { $0.id == focusedId }),
           case .text(let textItem) = entry.items[focusedIndex] {
            // Paste into text area at cursor position
            selectedItemId = nil
            selectedItemIds.removeAll()
            pasteIntoText(at: focusedIndex, textItem: textItem)
        } else if let selectedId = selectedItemId,
                  let selectedIndex = entry.items.firstIndex(where: { $0.id == selectedId }) {
            // Paste after selected image (matching drag-and-drop behavior), then clear selection
            selectedItemId = nil
            selectedItemIds.removeAll()
            pasteBeforeItem(at: selectedIndex + 1)
        }

        undoCoordinator.commitAction(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
        return true
    }

    private func pasteIntoText(at index: Int, textItem: TextItem) {
        // Split text at cursor position
        let cursorPos = textItem.currentCursorPosition
        let content = textItem.content
        let splitPos = min(cursorPos, content.count)
        let contentNS = content as NSString

        // If cursor is at the start of a line (position 0 or immediately after \n),
        // split right there. Otherwise advance to the end of the current line,
        // stopping BEFORE the newline character.
        let isAtLineStart = splitPos == 0 ||
            (splitPos > 0 && contentNS.character(at: splitPos - 1) == 0x000A)

        let finalSplitPos: Int
        if isAtLineStart {
            finalSplitPos = splitPos
        } else {
            var pos = splitPos
            while pos < content.count && contentNS.character(at: pos) != 0x000A {
                pos += 1
            }
            finalSplitPos = pos
        }

        let textBefore = String(content.prefix(finalSplitPos))
        let textAfter = String(content.suffix(content.count - finalSplitPos))
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
        captionEditingId = nil
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
        captionEditingId = nil
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
        undoCoordinator.commitTypingIfNeeded(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
        undoCoordinator.takeSnapshot(entry: entry, actionName: "\(formatting)", focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)

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
                textView.didChangeText()  // sync model so updateNSView doesn't overwrite formatting
            } else {
                // Toggle bold in typing attributes
                toggleTypingAttribute(.boldFontMask, textView: textView)
            }
            updateActiveFormats()
        case .italic:
            if savedRange.length > 0 {
                textView.applyFontTrait(.italicFontMask, range: savedRange)
                textView.didChangeText()  // sync model so updateNSView doesn't overwrite formatting
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
                textView.didChangeText()  // sync model so updateNSView doesn't overwrite formatting
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
            undoCoordinator.commitAction(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
            return  // Don't restore selection - applyListStyle handles it
        case .numberedList:
            applyListStyle(textView: textView, savedRange: savedRange, ordered: true)
            undoCoordinator.commitAction(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
            return  // Don't restore selection - applyListStyle handles it
        }

        undoCoordinator.commitAction(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)

        // Restore focus and selection
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            // Only restore an explicit selection — with no selection (cursor only),
            // calling setSelectedRange triggers textViewDidChangeSelection which
            // re-syncs typingAttributes from textStorage, wiping the typing-mode toggle.
            if savedRange.length > 0 {
                let validLocation = min(savedRange.location, textStorage.length)
                let validLength = min(savedRange.length, textStorage.length - validLocation)
                let validRange = NSRange(location: validLocation, length: validLength)
                textView.setSelectedRange(validRange)
            }
        }
    }

    private func applyHeading(textView: NSTextView, savedRange: NSRange, level: Int) {
        guard let textStorage = textView.textStorage else { return }

        // If text is completely empty, we can't apply formatting - just set typing attributes
        if textStorage.length == 0 {
            let baseSize: CGFloat = kBodyFontSize
            let headingSizes: [Int: CGFloat] = kHeadingSizes
            let targetFontSize = headingSizes[level] ?? baseSize
            let font = headingFont(targetFontSize)
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
        let baseSize: CGFloat = kBodyFontSize
        let headingSizes: [Int: CGFloat] = kHeadingSizes
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
            textStorage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: paragraphRange)
            textView.typingAttributes = [.font: font, .paragraphStyle: NSParagraphStyle.default]
        } else {
            // Apply heading
            let font = headingFont(targetFontSize)
            let style = NSMutableParagraphStyle(); style.paragraphSpacing = 14
            textStorage.addAttribute(.font, value: font, range: paragraphRange)
            textStorage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            textView.typingAttributes = [.font: font, .paragraphStyle: style]
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
                attrs[.font] = bodyFont()
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
        let currentFont = attrs[.font] as? NSFont ?? bodyFont()
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
            if !activeFormats.isEmpty { activeFormats = [] }
            return
        }

        guard let textStorage = textView.textStorage else {
            if !activeFormats.isEmpty { activeFormats = [] }
            return
        }

        let selectedRange = textView.selectedRange()
        var formats: Set<FormattingType> = []

        // If there's no selection (cursor only), check typing attributes
        // If there's a selection, check the attributes of the selected text
        let attrs: [NSAttributedString.Key: Any]
        if selectedRange.length == 0 {
            // No selection - check typing attributes for what WILL be typed
            attrs = textView.typingAttributes
        } else if textStorage.length == 0 || selectedRange.location >= textStorage.length {
            // Edge case: no text or past end
            attrs = textView.typingAttributes
        } else {
            // Selection exists - check attributes at selection start
            attrs = textStorage.attributes(at: selectedRange.location, effectiveRange: nil)
        }

        // Check for bold, italic
        if let font = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) {
                // Check if it's a heading by font size
                let fontSize = font.pointSize
                if fontSize >= kHeadingSizes[1]! {
                    formats.insert(.heading1)
                } else if fontSize >= kHeadingSizes[2]! {
                    formats.insert(.heading2)
                } else if fontSize >= kHeadingSizes[3]! {
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

        // Check for list markers — only if NOT in a heading paragraph
        let isHeading = formats.contains(.heading1) || formats.contains(.heading2) || formats.contains(.heading3)
        if !isHeading && textStorage.length > 0 {
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

        // Only update (and trigger a re-render) when formatting actually changed
        if formats != activeFormats {
            activeFormats = formats
        }
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

    private func handleEnterKey() {
        guard let selectedId = selectedItemId,
              let index = entry.items.firstIndex(where: { $0.id == selectedId }),
              case .image = entry.items[index] else { return }
        captionEditingId = selectedId
    }

    private func updateImageCaption(id: UUID, caption: String?) {
        guard let index = entry.items.firstIndex(where: { $0.id == id }),
              case .image(var imageItem) = entry.items[index] else { return }
        imageItem.caption = caption
        entry.items[index] = .image(imageItem)
    }

    private func handleDelete() {
        guard let selectedId = selectedItemId else { return }

        undoCoordinator.commitTypingIfNeeded(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
        undoCoordinator.takeSnapshot(entry: entry, actionName: "Delete", focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)

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

        undoCoordinator.commitAction(entry: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId)
    }

    // MARK: - Undo / Redo

    private func performUndo() {
        if let result = undoCoordinator.undo(into: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId) {
            applyRestoreResult(result)
        }
    }

    private func performRedo() {
        if let result = undoCoordinator.redo(into: entry, focusedTextItemId: focusedTextItemId, selectedItemId: selectedItemId) {
            applyRestoreResult(result)
        }
    }

    private func applyRestoreResult(_ result: UndoCoordinator.RestoreResult) {
        focusedTextItemId = result.focusedTextItemId
        selectedItemId = result.selectedItemId
        selectedItemIds.removeAll()
        previousTitle = entry.title
    }

    // MARK: - Article management

    private func loadArticle(_ article: ArticleEntry) {
        let currentFolder = entry.filePath?.deletingLastPathComponent()
        if currentFolder?.path == article.folderURL.path { return }

        if entry.isDirty { saveEntry(isManualSave: false) }
        closeFindBar()
        undoCoordinator.clear()
        publishState = .idle
        selectedItemId = nil
        selectedItemIds.removeAll()
        captionEditingId = nil
        focusedTextItemId = nil
        showUrlUpdateAlert = false
        pendingFolderName = ""
        pendingOldGCSFolder = ""

        isLoadingArticle = true   // suppress rename triggers while loading
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        articleDate = article.dateString.isEmpty ? Date() : (fmt.date(from: article.dateString) ?? Date())

        // Prefer index.html; fall back to legacy <folderName>.html
        let loadURL: URL
        if FileManager.default.fileExists(atPath: article.htmlURL.path) {
            loadURL = article.htmlURL
        } else {
            let legacyName = article.folderURL.lastPathComponent
            let legacyURL = article.folderURL.appendingPathComponent("\(legacyName).html")
            guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
            loadURL = legacyURL
        }

        Task {
            defer { isLoadingArticle = false }
            do {
                // Backfill missing small/ JPEGs before populating entry so ImageItemViews
                // always find the files ready on their first onAppear.
                let loadFolder = loadURL.deletingLastPathComponent()
                await Task.detached(priority: .userInitiated) {
                    TravelBlogPublisher.generateMissingSmallImages(in: loadFolder)
                }.value
                try await HTMLParser.load(from: loadURL, into: entry)
                previousTitle = entry.title
                SaveCoordinator.saveLastFilePath(entry.filePath ?? loadURL)
                await generateMissingWebImages(baseURL: loadURL.deletingLastPathComponent())
            } catch {
                print("Failed to load article: \(error)")
            }
            loadProgress = nil
        }
    }

    private func createNewArticle() {
        if entry.isDirty { saveEntry(isManualSave: false) }

        isLoadingArticle = true   // suppress rename while we set up the new entry
        articleDate = Date()

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())

        let draftsDir = ArticleManager.draftsDir
        var folderName = "\(today)_untitled"
        var counter = 1
        while FileManager.default.fileExists(
            atPath: draftsDir.appendingPathComponent(folderName).path
        ) {
            folderName = "\(today)_untitled-\(counter)"
            counter += 1
        }

        let newFolderURL = draftsDir.appendingPathComponent(folderName)
        let newHTMLURL = newFolderURL.appendingPathComponent("index.html")

        do {
            try FileManager.default.createBlogDirectoryStructure(at: newFolderURL)

            // Reset entry without triggering change tracking
            entry.suspendChangeTracking()
            entry.title = ""
            entry.items = [.text(TextItem())]
            entry.filePath = newHTMLURL
            entry.isDirty = false
            entry.resumeChangeTracking()

            undoCoordinator.clear()
            publishState = .idle
            previousTitle = ""
            focusedTextItemId = nil
            selectedItemId = nil

            let html = HTMLConverter.convert(entry: entry, imageMap: [:])
            try FileManager.default.atomicSave(content: html, to: newHTMLURL)
            SaveCoordinator.saveLastFilePath(newHTMLURL)

            articleManager.refresh()
        } catch {
            print("Failed to create new article: \(error)")
        }
        // Defer the flag reset so the onChange for articleDate fires while it is still set
        DispatchQueue.main.async { self.isLoadingArticle = false }
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
    let onImageDrop: ([URL]) -> Void
    let onPaste: () -> Bool
    let onTextViewFocusChanged: (CustomNSTextView?) -> Void
    let onSelectionChanged: () -> Void
    let onTextDidChange: () -> Void
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onEscapeKey: (() -> Void)?

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
                onSelectionChanged: onSelectionChanged,
                onTextDidChange: onTextDidChange,
                onUndo: onUndo,
                onRedo: onRedo,
                onEscapeKey: onEscapeKey
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
    @EnvironmentObject var findRegistry: FindRegistry
    @ObservedObject var textItem: TextItem
    @Binding var height: CGFloat
    let isFocused: Bool
    let onNavigateUp: () -> Void
    let onNavigateDown: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onImageDrop: ([URL]) -> Void
    let onPaste: () -> Bool
    let onTextViewFocusChanged: (CustomNSTextView?) -> Void
    let onSelectionChanged: () -> Void
    let onTextDidChange: () -> Void
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onEscapeKey: (() -> Void)?

    func makeNSView(context: Context) -> CustomNSTextView {
        let textView = CustomNSTextView()
        textView.coordinator = context.coordinator
        textView.onImageDrop = context.coordinator.handleImageDrop
        textView.onPaste = onPaste
        textView.onFocusChanged = onTextViewFocusChanged
        textView.onSelectionChanged = onSelectionChanged
        textView.onUndo = onUndo
        textView.onRedo = onRedo
        textView.onEscapeKey = onEscapeKey

        // Register for find bar highlighting
        context.coordinator.findRegistry = findRegistry
        findRegistry.textViews[textItem.id] = textView

        textView.delegate = context.coordinator
        textView.isRichText = true  // Enable rich text
        textView.font = bodyFont()
        textView.typingAttributes = [.font: bodyFont(), .foregroundColor: NSColor.textColor]
        textView.textColor = NSColor.textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true

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
        // Keep callbacks fresh so SwiftUI state changes are reflected
        textView.onUndo = onUndo
        textView.onRedo = onRedo
        textView.onFocusChanged = onTextViewFocusChanged
        textView.onSelectionChanged = onSelectionChanged
        textView.onEscapeKey = onEscapeKey
        context.coordinator.parent = self
        context.coordinator.findRegistry = findRegistry

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

    static func dismantleNSView(_ nsView: CustomNSTextView, coordinator: Coordinator) {
        coordinator.findRegistry?.textViews.removeValue(forKey: coordinator.parent.textItem.id)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextEditor
        weak var findRegistry: FindRegistry?

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

            // Notify about text change (for undo typing grouping — snapshot before model update)
            parent.onTextDidChange()

            // Update the attributed content (triggers SwiftUI re-render, which calls
            // updateNSView where height is recalculated — no need to do it here too)
            if let attributedString = textStorage.copy() as? NSAttributedString {
                parent.textItem.attributedContent = attributedString
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

            // Sync typing attributes with the text at the cursor position.
            // applyFontTrait modifies textStorage directly (bypassing NSTextView's normal
            // editing path), so NSTextView doesn't auto-update typingAttributes after
            // selection-based bold/italic/underline. We do it here so the toolbar
            // always reflects the formatting under the cursor.
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                let sel = textView.selectedRange()
                let checkPos: Int
                if sel.length > 0 {
                    checkPos = min(sel.location, textStorage.length - 1)
                } else if sel.location > 0 {
                    checkPos = min(sel.location - 1, textStorage.length - 1)
                } else {
                    checkPos = 0
                }
                let textAttrs = textStorage.attributes(at: checkPos, effectiveRange: nil)
                var typingAttrs = textView.typingAttributes
                if let font = textAttrs[.font] as? NSFont {
                    typingAttrs[.font] = font
                }
                if let underline = textAttrs[.underlineStyle] {
                    typingAttrs[.underlineStyle] = underline
                } else {
                    typingAttrs.removeValue(forKey: .underlineStyle)
                }
                textView.typingAttributes = typingAttrs
            }

            // Notify about selection change
            if let customTextView = textView as? CustomNSTextView {
                customTextView.onSelectionChanged?()
            }
        }

        func handleImageDrop(_ urls: [URL]) {
            parent.onImageDrop(urls)
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
    var onImageDrop: ([URL]) -> Void = { _ in }
    var onPaste: (() -> Bool)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onFocusChanged: ((CustomNSTextView?) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onEscapeKey: (() -> Void)?
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

            let imageURLs = urls.filter { Self.isImageURL($0) }
            if !imageURLs.isEmpty {
                DispatchQueue.main.async {
                    self.onImageDrop(imageURLs)
                }
                return true
            }
            return false
        }
        // Allow text drops
        return super.performDragOperation(sender)
    }

    static func isImageURL(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "webp", "tiff", "tif"]
            .contains(url.pathExtension.lowercased())
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
        // Set focusedTextItemId immediately on click, not just on first keystroke.
        // Without this, clicking a text area without typing leaves focusedTextItemId nil,
        // causing "Add Video" (and other cursor-dependent actions) to fall back to the end.
        coordinator?.parent.onFocusChanged(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        onFocusChanged?(nil)
        coordinator?.parent.onFocusChanged(false)
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
        // Escape: close find bar if open, then let NSTextView handle (e.g. dismiss autocomplete)
        else if event.keyCode == 53 { // Escape
            onEscapeKey?()
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let char = event.charactersIgnoringModifiers ?? ""
        let isCmd = event.modifierFlags.contains(.command)
        let isShift = event.modifierFlags.contains(.shift)

        // Handle Cmd-Z (undo) and Cmd-Shift-Z (redo)
        if isCmd && char == "z" {
            if isShift {
                onRedo?()
            } else {
                onUndo?()
            }
            return true
        }

        // Check for Cmd-V (paste) — only intercept if our handler actually consumed it
        if isCmd && char == "v" {
            if let onPaste = onPaste, onPaste() {
                return true
            }
            // onPaste returned false (or wasn't set) — fall through to NSTextView default text paste
        }

        // B/I/U are handled exclusively by the Format menu (via applyFormattingAction).
        // Do NOT intercept them here — on macOS 14+ SwiftUI fires its .commands shortcuts
        // at the app level, so double-handling would apply then immediately undo the style.

        return super.performKeyEquivalent(with: event)
    }

    // Implement standard NSResponder actions for Format menu
    // Apply (or toggle off) a heading level for the current paragraph
    private func applyHeadingLevel(_ level: Int) {
        guard let textStorage = self.textStorage else { return }
        let selectedRange = self.selectedRange()

        let headingSizes: [Int: CGFloat] = kHeadingSizes
        let targetSize = headingSizes[level]!

        if textStorage.length == 0 {
            // Empty text view — just set typing attributes
            let font = headingFont(targetSize)
            typingAttributes = [.font: font]
            onSelectionChanged?()
            return
        }

        let paragraphRange = (textStorage.string as NSString).paragraphRange(for: selectedRange)
        let checkLoc = min(paragraphRange.location, textStorage.length - 1)
        let currentFont = textStorage.attribute(.font, at: checkLoc, effectiveRange: nil) as? NSFont
        let isAlready = currentFont.map {
            $0.pointSize == targetSize && NSFontManager.shared.traits(of: $0).contains(.boldFontMask)
        } ?? false

        let newFont = isAlready ? bodyFont() : headingFont(targetSize)
        let paraStyle: NSParagraphStyle = {
            if isAlready { return .default }
            let s = NSMutableParagraphStyle(); s.paragraphSpacing = 14; return s
        }()

        textStorage.beginEditing()
        textStorage.addAttribute(.font, value: newFont, range: paragraphRange)
        textStorage.addAttribute(.paragraphStyle, value: paraStyle, range: paragraphRange)
        textStorage.endEditing()
        typingAttributes = [.font: newFont, .paragraphStyle: paraStyle]
        didChangeText()
        onSelectionChanged?()
    }

    @objc func heading1(_ sender: Any?) { applyHeadingLevel(1) }
    @objc func heading2(_ sender: Any?) { applyHeadingLevel(2) }
    @objc func heading3(_ sender: Any?) { applyHeadingLevel(3) }

    @objc func bold(_ sender: Any?) {
        let selectedRange = self.selectedRange()
        if selectedRange.length > 0 {
            applyFontTrait(.boldFontMask, range: selectedRange)
        } else {
            toggleTypingAttributeForTrait(.boldFontMask)
        }
        onSelectionChanged?()
        didChangeText()
    }

    @objc func italic(_ sender: Any?) {
        let selectedRange = self.selectedRange()
        if selectedRange.length > 0 {
            applyFontTrait(.italicFontMask, range: selectedRange)
        } else {
            toggleTypingAttributeForTrait(.italicFontMask)
        }
        onSelectionChanged?()
        didChangeText()
    }

    @objc override func underline(_ sender: Any?) {
        let selectedRange = self.selectedRange()
        if selectedRange.length > 0 {
            guard let textStorage = textStorage else { return }
            let attrs = textStorage.attributes(at: selectedRange.location, effectiveRange: nil)
            if attrs[.underlineStyle] != nil {
                textStorage.removeAttribute(.underlineStyle, range: selectedRange)
            } else {
                textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: selectedRange)
            }
        } else {
            var attrs = typingAttributes
            if attrs[.underlineStyle] != nil {
                attrs.removeValue(forKey: .underlineStyle)
            } else {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            typingAttributes = attrs
        }
        onSelectionChanged?()
        didChangeText()
    }

    private func toggleTypingAttributeForTrait(_ trait: NSFontTraitMask) {
        var attrs = typingAttributes

        // Get current font or use default
        let currentFont = attrs[.font] as? NSFont ?? bodyFont()
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
                    let isHeading = font.pointSize >= kHeadingSizes[3]! && NSFontManager.shared.traits(of: font).contains(.boldFontMask)
                    if isHeading {
                        // Insert newline and reset to normal font
                        textStorage.beginEditing()
                        let normalFont = bodyFont()
                        let newlineAttr = NSAttributedString(string: "\n", attributes: [.font: normalFont])
                        textStorage.insert(newlineAttr, at: selectedRange.location)
                        textStorage.endEditing()
                        self.setSelectedRange(NSRange(location: selectedRange.location + 1, length: 0))
                        // Explicitly reset typing attributes so the next line is body text,
                        // not a continuation of the heading font.
                        self.typingAttributes = [.font: normalFont, .foregroundColor: NSColor.textColor,
                                                 .paragraphStyle: NSParagraphStyle.default]
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
                attrs[.font] = bodyFont()
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
                attrs[.font] = bodyFont()
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
                attrs[.font] = bodyFont()
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
                attrs[.font] = bodyFont()
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
                attrs[.font] = bodyFont()
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
    @Binding var captionEditingId: UUID?
    @Binding var focusedTextItemId: UUID?
    @Binding var selectedItemIds: Set<UUID>
    @Binding var findScrollTargetId: UUID?
    let onNavigateUp: (Int) -> Void
    let onNavigateDown: (Int) -> Void
    let onDrop: ([NSItemProvider]) -> Void
    let onDelete: () -> Void
    let onArrowKey: (Bool) -> Void
    let onEnterKey: () -> Void
    let onEscapeKey: () -> Void
    let onUpdateCaption: (UUID, String?) -> Void
    let onImageTap: (ImageItem, Int, NSEvent.ModifierFlags) -> Void
    let onVideoTap: (VideoItem, Int, NSEvent.ModifierFlags) -> Void
    let onPaste: () -> Bool
    let onTextViewFocusChanged: (CustomNSTextView?) -> Void
    let onSelectionChanged: () -> Void
    let onImageURLsDrop: ([URL], Int, Int?) -> Void
    let onTextDidChange: () -> Void
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
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
            .onChange(of: focusedTextItemId) { _, newId in
                if let id = newId {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onChange(of: selectedItemId) { _, newId in
                if let id = newId {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onChange(of: findScrollTargetId) { _, newId in
                if let id = newId {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    findScrollTargetId = nil
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .background(KeyboardHandler(
            selectedItemId: $selectedItemId,
            captionEditingId: captionEditingId,
            onDelete: onDelete,
            onArrowUp: { onArrowKey(true) },
            onArrowDown: { onArrowKey(false) },
            onEnter: onEnterKey,
            onEscape: onEscapeKey
        ))
    }

    private func handleTextItemImageDrop(urls: [URL], at index: Int, textItem: TextItem) {
        let cursorPos = (focusedTextItemId == textItem.id) ? textItem.currentCursorPosition : nil
        onImageURLsDrop(urls, index, cursorPos)
    }

    private func handleDropAtEnd(providers: [NSItemProvider]) {
        Task {
            let urls = await loadFileURLs(from: providers).filter { CustomNSTextView.isImageURL($0) }
            guard !urls.isEmpty else { return }
            let lastIndex = await MainActor.run { entry.items.count - 1 }
            await MainActor.run { onImageURLsDrop(urls, lastIndex, nil) }
        }
    }

    private func handleItemDrop(providers: [NSItemProvider], at index: Int) {
        Task {
            let urls = await loadFileURLs(from: providers).filter { CustomNSTextView.isImageURL($0) }
            guard !urls.isEmpty else { return }
            await MainActor.run {
                switch entry.items[index] {
                case .text(let textItem):
                    let cursorPos = (focusedTextItemId == textItem.id) ? textItem.currentCursorPosition : nil
                    onImageURLsDrop(urls, index, cursorPos)
                case .image, .video:
                    onImageURLsDrop(urls, index, nil)
                }
            }
        }
    }

    // Collect file URLs from NSItemProviders in original order
    private func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (i, provider) in providers.enumerated() {
                group.addTask {
                    await withCheckedContinuation { cont in
                        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                            if let data = item as? Data,
                               let url = URL(dataRepresentation: data, relativeTo: nil) {
                                cont.resume(returning: (i, url))
                            } else {
                                cont.resume(returning: (i, nil))
                            }
                        }
                    }
                }
            }
            var results: [(Int, URL)] = []
            for await (i, url) in group {
                if let url = url { results.append((i, url)) }
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
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
                onImageDrop: { urls in
                    handleTextItemImageDrop(urls: urls, at: index, textItem: textItem)
                },
                onPaste: onPaste,
                onTextViewFocusChanged: onTextViewFocusChanged,
                onSelectionChanged: onSelectionChanged,
                onTextDidChange: onTextDidChange,
                onUndo: onUndo,
                onRedo: onRedo,
                onEscapeKey: onEscapeKey
            )
        case .image(let imageItem):
            ImageItemView(
                imageItem: imageItem,
                isSelected: selectedItemId == imageItem.id || selectedItemIds.contains(imageItem.id),
                isEditingCaption: captionEditingId == imageItem.id,
                onTap: { modifiers in
                    onImageTap(imageItem, index, modifiers)
                },
                onTapCaption: {
                    captionEditingId = imageItem.id
                },
                onCaptionCommit: { newCaption in
                    onUpdateCaption(imageItem.id, newCaption)
                    captionEditingId = nil
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
    var captionEditingId: UUID?
    let onDelete: () -> Void
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyHandlingView()
        view.onDelete = onDelete
        view.onArrowUp = onArrowUp
        view.onArrowDown = onArrowDown
        view.onEnter = onEnter
        view.onEscape = onEscape
        view.selectedItemId = selectedItemId
        view.captionEditingId = captionEditingId
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let keyView = nsView as? KeyHandlingView {
            // Steal focus when first selecting an item (nil → non-nil),
            // or when caption editing ends while an item is still selected
            // (caption's TextEditor had focus; we need to reclaim it).
            let prevId = keyView.selectedItemId
            let prevCaptionId = keyView.captionEditingId
            keyView.selectedItemId = selectedItemId
            keyView.captionEditingId = captionEditingId
            keyView.onEnter = onEnter
            keyView.onEscape = onEscape
            let justSelected = selectedItemId != nil && prevId == nil
            let captionJustEnded = selectedItemId != nil && prevCaptionId != nil && captionEditingId == nil
            if justSelected || captionJustEnded {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

class KeyHandlingView: NSView {
    var selectedItemId: UUID?
    var captionEditingId: UUID?
    var onDelete: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { return selectedItemId != nil }

    override func keyDown(with event: NSEvent) {
        guard selectedItemId != nil else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 51, 117: // Delete or Forward Delete
            onDelete?()
        case 36: // Return/Enter
            onEnter?()
        case 53: // Escape
            onEscape?()
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
    let isEditingCaption: Bool
    let onTap: (NSEvent.ModifierFlags) -> Void
    let onTapCaption: () -> Void
    let onCaptionCommit: (String?) -> Void

    @FocusState private var captionFocused: Bool
    @State private var captionDraft: String = ""
    @State private var captionCommitted = false
    @State private var loadedImage: NSImage? = nil
    @State private var loadFailed = false

    private var displayImage: NSImage? { imageItem.resizedImage ?? loadedImage }

    private func commitCaption() {
        guard !captionCommitted else { return }
        captionCommitted = true
        let trimmed = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onCaptionCommit(trimmed.isEmpty ? nil : trimmed)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let img = displayImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 640, maxHeight: 640)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let event = NSApp.currentEvent {
                            onTap(event.modifierFlags)
                        } else {
                            onTap([])
                        }
                    }
            } else {
                // Placeholder shown while the image loads lazily (or if it failed)
                Rectangle()
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 640, height: 480)
                    .overlay {
                        if loadFailed {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text(imageItem.smallURL?.lastPathComponent ?? imageItem.filename)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            ProgressView()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let event = NSApp.currentEvent {
                            onTap(event.modifierFlags)
                        } else {
                            onTap([])
                        }
                    }
            }

            if isEditingCaption {
                TextEditor(text: $captionDraft)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 36, maxHeight: 80)
                    .focused($captionFocused)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .onKeyPress(.escape) {
                        commitCaption()
                        return .handled
                    }
            } else if let caption = imageItem.caption,
                      !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(caption)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { onTapCaption() }
            }
        }
        .background(Color(hex: "eeeeff"))
        .overlay(
            Rectangle()
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
        )
        .onChange(of: isEditingCaption) { _, editing in
            if editing {
                captionDraft = imageItem.caption ?? ""
                captionCommitted = false
                DispatchQueue.main.async { captionFocused = true }
            } else {
                // Editing ended externally (e.g. clicking another image) — commit the draft
                commitCaption()
            }
        }
        .onChange(of: captionFocused) { _, focused in
            guard isEditingCaption, !focused else { return }
            commitCaption()
        }
        .onAppear {
            if isEditingCaption {
                captionDraft = imageItem.caption ?? ""
                captionCommitted = false
                DispatchQueue.main.async { captionFocused = true }
            }
            // Lazy-load the thumbnail if not already in memory
            guard displayImage == nil, let smallURL = imageItem.smallURL else { return }
            Task.detached(priority: .userInitiated) {
                let img = NSImage(contentsOf: smallURL)
                await MainActor.run {
                    if let img {
                        loadedImage = img
                    } else {
                        loadFailed = true
                    }
                }
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

// CutPasteHandler monitors keyboard events for cut/paste/undo/redo shortcuts
struct CutPasteHandler: NSViewRepresentable {
    let canCut: Bool
    let canPaste: Bool
    let canUndo: Bool
    let canRedo: Bool
    let onCut: () -> Void
    let onPaste: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void

    func makeNSView(context: Context) -> CutPasteHandlingView {
        let view = CutPasteHandlingView()
        view.canCut = canCut
        view.canPaste = canPaste
        view.canUndo = canUndo
        view.canRedo = canRedo
        view.onCut = onCut
        view.onPaste = onPaste
        view.onUndo = onUndo
        view.onRedo = onRedo
        return view
    }

    func updateNSView(_ nsView: CutPasteHandlingView, context: Context) {
        nsView.canCut = canCut
        nsView.canPaste = canPaste
        nsView.canUndo = canUndo
        nsView.canRedo = canRedo
        nsView.onCut = onCut
        nsView.onPaste = onPaste
        nsView.onUndo = onUndo
        nsView.onRedo = onRedo
    }
}

class CutPasteHandlingView: NSView {
    var canCut: Bool = false
    var canPaste: Bool = false
    var canUndo: Bool = false
    var canRedo: Bool = false
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let char = event.charactersIgnoringModifiers ?? ""
        let isCmd = event.modifierFlags.contains(.command)
        let isShift = event.modifierFlags.contains(.shift)

        // Handle Cmd-Z (undo) and Cmd-Shift-Z (redo)
        if isCmd && char == "z" {
            if isShift && canRedo {
                onRedo?()
                return true
            } else if !isShift && canUndo {
                onUndo?()
                return true
            }
        }

        // Only handle cut/paste, let other shortcuts pass through
        if isCmd && char == "x" && canCut {
            onCut?()
            return true
        }
        if isCmd && char == "v" && canPaste {
            onPaste?()
            return true
        }

        // Don't intercept formatting shortcuts - let them pass through to text view
        return super.performKeyEquivalent(with: event)
    }
}

struct VideoDialogView: View {
    @Environment(\.dismiss) var dismiss
    @State private var youtubeURL = ""
    @State private var videoTitle = ""
    let onAdd: (String, String?) -> Void

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
                    onAdd(youtubeURL, videoTitle.isEmpty ? nil : videoTitle)
                    dismiss()
                }
                .disabled(youtubeURL.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Article Sidebar

struct ArticleSidebarView: View {
    let articles: [ArticleEntry]
    let selectedFolderURL: URL?
    let onSelect: (ArticleEntry) -> Void
    let onNew: () -> Void

    // Stable selection key: standardized folder path string (survives articleManager.refresh())
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selectedFolderURL?.standardized.path },
            set: { newPath in
                guard let path = newPath,
                      let article = articles.first(where: { $0.folderURL.standardized.path == path })
                else { return }
                onSelect(article)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List(articles, id: \.folderURL, selection: selectionBinding) { article in
                ArticleRowView(article: article)
                    .tag(article.folderURL.standardized.path)
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .help("New article")
                Spacer()
            }
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

struct ArticleRowView: View {
    let article: ArticleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if !article.dateString.isEmpty {
                    Text(article.dateString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if article.isDraft {
                    Text("Draft")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
                Spacer()
            }
            Text(article.displayTitle)
                .font(.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
