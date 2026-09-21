// Copyright © 2026 Randy Wilson. All rights reserved.

import AppKit

/// The app's icon, an antique sepia world globe.
///
/// A Swift Package executable has no bundle to read `CFBundleIconFile` from, so
/// the Dock icon is set explicitly at launch. Regenerate the artwork with
/// `swift Tools/MakeAppIcon.swift`; `Icons/AppIcon.icns` is the same image for
/// when the executable is wrapped in a real `.app`.
public enum AppIcon {

    /// The 1024pt icon bundled with `BlogComposerCore`, or `nil` if missing.
    public static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    /// Sets the icon shown in the Dock and the about panel.
    public static func applyToDock() {
        guard let image else { return }
        NSApplication.shared.applicationIconImage = image
    }
}
