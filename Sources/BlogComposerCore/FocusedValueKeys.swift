// Copyright © 2026 Randy Wilson. All rights reserved.

import SwiftUI

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

struct SaveActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

public extension FocusedValues {
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
    var saveAction: (() -> Void)? {
        get { self[SaveActionKey.self] }
        set { self[SaveActionKey.self] = newValue }
    }
}
