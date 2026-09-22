import AppKit
import SwiftUI

/// ReelFlow: a simple Mac video editor that turns long recordings into
/// captioned clips for Reels, TikTok, Shorts and the rest. This is the
/// editor that began life as the Peeky Video tab of MyClicky, now a normal
/// windowed app of its own.
@main
struct ReelFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = VideoEditorModel()

    /// The brand colour the editor's controls are tinted with.
    static let accent = Color(red: 0.40, green: 0.70, blue: 1.0)

    var body: some Scene {
        WindowGroup("ReelFlow") {
            VideoEditorView(model: model, accent: Self.accent)
                .frame(minWidth: 960, minHeight: 700)
                .background(Color(red: 0.094, green: 0.094, blue: 0.098))
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Clips…") { model.chooseClips() }
                    .keyboardShortcut("i", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A package-built app launched from Finder or `open` starts behind
        // whatever was in front; a video editor wants its window up.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
