// Copyright © 2026 Randy Wilson. All rights reserved.

import SwiftUI
import AppKit

// Focused value keys for undo/redo state
struct UndoCoordinatorKey: FocusedValueKey {
    typealias Value = UndoCoordinator
}

struct UndoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct RedoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct SyncActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct RegenerateIndexActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ApplyFormattingKey: FocusedValueKey {
    typealias Value = (FormattingType) -> Void
}

struct FindActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct FindNextActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct FindPreviousActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct NewEntryActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var undoCoordinator: UndoCoordinator? {
        get { self[UndoCoordinatorKey.self] }
        set { self[UndoCoordinatorKey.self] = newValue }
    }
    var undoAction: (() -> Void)? {
        get { self[UndoActionKey.self] }
        set { self[UndoActionKey.self] = newValue }
    }
    var redoAction: (() -> Void)? {
        get { self[RedoActionKey.self] }
        set { self[RedoActionKey.self] = newValue }
    }
    var syncAction: (() -> Void)? {
        get { self[SyncActionKey.self] }
        set { self[SyncActionKey.self] = newValue }
    }
    var regenerateIndexAction: (() -> Void)? {
        get { self[RegenerateIndexActionKey.self] }
        set { self[RegenerateIndexActionKey.self] = newValue }
    }
    var applyFormattingAction: ((FormattingType) -> Void)? {
        get { self[ApplyFormattingKey.self] }
        set { self[ApplyFormattingKey.self] = newValue }
    }
    var findAction: (() -> Void)? {
        get { self[FindActionKey.self] }
        set { self[FindActionKey.self] = newValue }
    }
    var findNextAction: (() -> Void)? {
        get { self[FindNextActionKey.self] }
        set { self[FindNextActionKey.self] = newValue }
    }
    var findPreviousAction: (() -> Void)? {
        get { self[FindPreviousActionKey.self] }
        set { self[FindPreviousActionKey.self] = newValue }
    }
    var newEntryAction: (() -> Void)? {
        get { self[NewEntryActionKey.self] }
        set { self[NewEntryActionKey.self] = newValue }
    }
}

@main
struct BlogComposerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.undoCoordinator) var undoCoordinator
    @FocusedValue(\.undoAction) var undoAction
    @FocusedValue(\.redoAction) var redoAction
    @FocusedValue(\.syncAction) var syncAction
    @FocusedValue(\.regenerateIndexAction) var regenerateIndexAction
    @FocusedValue(\.applyFormattingAction) var applyFormattingAction
    @FocusedValue(\.findAction) var findAction
    @FocusedValue(\.findNextAction) var findNextAction
    @FocusedValue(\.findPreviousAction) var findPreviousAction
    @FocusedValue(\.newEntryAction) var newEntryAction

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Activate the app and bring windows to front
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo \(undoCoordinator?.undoActionName ?? "")") {
                    undoAction?()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoCoordinator?.canUndo != true)

                Button("Redo \(undoCoordinator?.redoActionName ?? "")") {
                    redoAction?()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(undoCoordinator?.canRedo != true)
            }
            CommandGroup(after: .pasteboard) {
                Button("Find…") {
                    findAction?()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(findAction == nil)

                Button("Find Next") {
                    findNextAction?()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(findNextAction == nil)

                Button("Find Previous") {
                    findPreviousAction?()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(findPreviousAction == nil)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Entry") {
                    newEntryAction?()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newEntryAction == nil)
            }
            CommandMenu("Publish") {
                Button("Regenerate Article Index") {
                    regenerateIndexAction?()
                }
                .disabled(regenerateIndexAction == nil)

                Button("Preview Article Index") {
                    let url = TravelBlogPublisher.travelBlogDir
                        .appendingPathComponent("index.html")
                    NSWorkspace.shared.open(url)
                }

                Divider()

                Button("Sync TravelBlog to GCS") {
                    syncAction?()
                }
                .disabled(syncAction == nil)
            }
            CommandMenu("Format") {
                Button("Heading 1") {
                    applyFormattingAction?(.heading1)
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(applyFormattingAction == nil)

                Button("Heading 2") {
                    applyFormattingAction?(.heading2)
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(applyFormattingAction == nil)

                Button("Heading 3") {
                    applyFormattingAction?(.heading3)
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(applyFormattingAction == nil)

                Divider()

                Button("Bold") {
                    applyFormattingAction?(.bold)
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(applyFormattingAction == nil)

                Button("Italic") {
                    applyFormattingAction?(.italic)
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(applyFormattingAction == nil)

                Button("Underline") {
                    applyFormattingAction?(.underline)
                }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(applyFormattingAction == nil)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make sure the app can receive focus
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Initialize default directory structure
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Journal/Drafts/untitled")

        do {
            // Create directory structure if it doesn't exist
            try FileManager.default.createDirectory(
                at: defaultPath,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: defaultPath.appendingPathComponent("full"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: defaultPath.appendingPathComponent("small"),
                withIntermediateDirectories: true
            )

            // Create empty HTML file if it doesn't exist
            let htmlPath = defaultPath.appendingPathComponent("index.html")
            if !FileManager.default.fileExists(atPath: htmlPath.path) {
                try "".write(to: htmlPath, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Warning: Failed to initialize default directory structure: \(error)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}