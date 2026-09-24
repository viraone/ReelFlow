import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ReelFlow: a simple Mac video editor that turns long recordings into
/// captioned clips for Reels, TikTok, Shorts and the rest. This is the
/// editor that began life as the Peeky Video tab of MyClicky, now a normal
/// windowed app of its own.
@main
struct ReelFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = VideoEditorModel()

    /// The colour the editor's controls are tinted with: the accent colour
    /// the user picked in System Settings › Appearance, so selection, links
    /// and the play button match the rest of their Mac. Blue for most
    /// people; purple, pink, red, orange, yellow, green or graphite for the
    /// rest, and it follows live if they change it. Solid fills of it carry
    /// black text and glyphs, which read on every one of those. The tool
    /// rail's tints are fixed system colours and don't follow.
    static let accent = Color(nsColor: .controlAccentColor)

    @State private var dropTargeted = false

    var body: some Scene {
        WindowGroup("ReelFlow") {
            VideoEditorView(model: model, accent: Self.accent)
                .frame(minWidth: 960, minHeight: 700)
                .background(Color(red: 0.094, green: 0.094, blue: 0.098))
                .overlay {
                    if dropTargeted { dropHint }
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    DroppedFiles.collect(providers) { urls in model.drop(urls) }
                }
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
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
            }
        }
    }
}

extension ReelFlowApp {
    /// Shown while files are held over the window.
    private var dropHint: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 44, weight: .light))
                Text("Drop to add")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                Text("Videos become clips · a song becomes the music · a picture goes over the video")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(red: 0.094, green: 0.094, blue: 0.098)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(Self.accent))
        }
        .allowsHitTesting(false)
    }
}

/// Reads the file URLs out of a drop, then hands them over on the main
/// thread once every provider has answered.
enum DroppedFiles {
    @discardableResult
    static func collect(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { done(urls) }
        }
        return true
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
