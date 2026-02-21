import SwiftUI
import AppKit

@main
struct BlogComposerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Activate the app and bring windows to front
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Entry") {
                    // TODO: Create new entry
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make sure the app can receive focus
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
