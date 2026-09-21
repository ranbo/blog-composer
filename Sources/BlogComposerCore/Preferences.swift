// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation

/// Settings stored in `UserDefaults`.
public enum Preferences {

    /// The domain used before the executable was wrapped in an app bundle.
    ///
    /// `UserDefaults.standard` is keyed by the main bundle's identifier. Run as a
    /// bare Swift Package executable there is no identifier, so preferences went to
    /// a domain named after the process; once bundled, they go to
    /// `CFBundleIdentifier` instead. Same app, different store — every setting
    /// silently reverted to its default the first time the bundle was launched.
    private static let legacyDomain = "BlogComposer"
    private static let migrationKey = "DidMigrateLegacyPreferenceDomain"

    /// Copies anything set under the old domain that isn't set under the current
    /// one. Runs once, and never overwrites a value already present.
    public static func migrateLegacyDomainIfNeeded() {
        let defaults = UserDefaults.standard

        // Unbundled, the current domain *is* the legacy one; nothing to do.
        guard let identifier = Bundle.main.bundleIdentifier,
              identifier != legacyDomain,
              !defaults.bool(forKey: migrationKey) else { return }

        defer { defaults.set(true, forKey: migrationKey) }

        guard let legacy = defaults.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
