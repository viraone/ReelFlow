import AVKit
import SwiftUI

/// The ReelFlow editor, built for someone who has never edited video.
/// A four-step tracker across the top says where you are and what to do
/// next; every control is a labelled button; the preview is big. The
/// editor is laid out like VEED's: a rail of tools on the left, the open
/// tool's panel beside it, the video on a canvas, the timeline docked
/// along the bottom.
struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    let accent: Color
    @State private var newProjectName = ""
    /// Which tool panel sits open beside the rail. Nil until the user
    /// picks one, so the panel follows the current step at first.
    @State private var chosenTool: Tool?
    @State private var panelHidden = false
    /// The rail entry the pointer is over, for the hover lift.
    @State private var hoveredTool: Tool?
    /// For resolving a system colour to numbers (the open tile's glyph).
    @Environment(\.self) private var environment
    /// The Trim panel's side of the video. Dragged there by its body; it
    /// snaps flush to whichever edge it's let go nearest, never floating.
    @AppStorage("reelflowTrimOnRight") private var trimOnRight = false
    /// Where the panel is mid-drag, relative to its docked spot.
    @State private var panelDrag: CGSize?
    @State private var editorWidth: CGFloat = 0
    @State private var trimPanelWidth: CGFloat = 0
    /// The video picture's frame in the editor row; the Trim panel lines
    /// its top up with it.
    @State private var videoRect: CGRect = .zero
    /// The Trim panel's left edge where it was last let go, or nil for its
    /// slot. Clamped at layout so it stays beside the picture, on screen.
    @State private var trimRestMinX: CGFloat?

    var body: some View {
        Group {
            if model.hasProject { editor } else { start }
        }
        .font(.system(size: 13, design: .monospaced))
        // The panel can be squeezed very short; whatever doesn't fit must
        // stay inside this tab rather than draw over the header above.
        .clipped()
    }

    // MARK: - Start screen

    private var start: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(accent)
                    Text("ReelFlow")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("Turn your takes into a subtitled video for Reels, TikTok, YouTube and your portfolio.")
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                // The one big thing to do.
                Button { model.chooseClips() } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 30, weight: .regular))
                        Text("Import your video clips")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                        Text("Click to choose files — or drop them anywhere on this tab")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: 520)
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(accent.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                            .foregroundStyle(accent.opacity(0.7))
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 520)

                HStack(spacing: 8) {
                    TextField("Or name a project first…", text: $newProjectName)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        .onSubmit(createProject)
                    pillButton("Create", icon: "plus", action: createProject)
                        .opacity(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
                .frame(maxWidth: 520)

                if !model.recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("RECENT PROJECTS")
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(model.recentProjects, id: \.self) { folder in
                                    let clips = model.recentProjectClipCounts[folder] ?? 0
                                    let empty = clips == 0
                                    HStack(spacing: 6) {
                                        Button { model.open(folder: folder) } label: {
                                            HStack {
                                                Image(systemName: "folder.fill").foregroundStyle(accent.opacity(empty ? 0.3 : 0.8))
                                                Text(folder.lastPathComponent)
                                                Spacer()
                                                Text(empty ? "no clips" : "\(clips) clip\(clips == 1 ? "" : "s")")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(.white.opacity(0.4))
                                                Image(systemName: "chevron.right")
                                                    .foregroundStyle(.white.opacity(empty ? 0 : 0.3))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(empty ? 0.03 : 0.06)))
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.white.opacity(empty ? 0.4 : 0.85))
                                        .disabled(empty)
                                        .help(empty ? "This project has no clips in it — drop a video on the window to start a new one"
                                                    : "Open this project")
                                        Button { deletingProject = folder } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(Color.red.opacity(0.75))
                                                .frame(width: 30, height: 34)
                                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .help("Delete this project (its video files stay)")
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                    .frame(maxWidth: 520)
                }

                if case .failed(let message) = model.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 520)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("Delete \u{201C}\(deletingProject?.lastPathComponent ?? "")\u{201D}?",
                            isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }),
                            titleVisibility: .visible) {
            Button("Delete project", role: .destructive) {
                if let folder = deletingProject { model.deleteProject(at: folder) }
                deletingProject = nil
            }
            Button("Keep it", role: .cancel) { deletingProject = nil }
        } message: {
            Text("The project folder — its settings, subtitles and exports — goes to the Trash. Your original video files are not touched.")
        }
    }

    @State private var deletingProject: URL?

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.newProject(named: name)
        newProjectName = ""
    }

    // MARK: - Editor

    /// VEED's editor shape: a rail of tools down the left, the open tool's
    /// panel beside it, the video on a canvas in the middle with a floating
    /// bar of quick actions under it, and the timeline docked along the
    /// bottom. ReelFlow's colours and coaching throughout.
    private var editor: some View {
        GeometryReader { geo in
            let showPanel = !panelHidden && geo.size.width >= 640
            let panelWidth = min(320, max(230, geo.size.width * 0.27))
            // Trim alone may sit on the far side of the video; the rest stay by the rail.
            let onRight = activeTool == .trim && trimOnRight
            // Trim rests where it was let go, its top on the picture's top.
            let hug = activeTool == .trim ? trimRestOffset(panelWidth: panelWidth) : .zero
            let panelOffset = CGSize(width: hug.width + (panelDrag?.width ?? 0),
                                     height: hug.height + (panelDrag?.height ?? 0))
            VStack(alignment: .leading, spacing: 10) {
                header
                if showsCoachLine { coachLine }
                HStack(alignment: .top, spacing: 10) {
                    rail
                    if showPanel && !onRight {
                        toolPanel(activeTool)
                            .frame(width: panelWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .offset(panelOffset)
                            .zIndex(1)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    canvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showPanel && onRight {
                        toolPanel(activeTool)
                            .frame(width: panelWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .offset(panelOffset)
                            .zIndex(1)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .coordinateSpace(name: "editorRow")
                .frame(maxHeight: .infinity)
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.size.height, initial: true) { _, height in editorRowHeight = height }
                })
                // Lifts the dragged panel over the timeline below.
                .zIndex(1)
                .onChange(of: geo.size.width, initial: true) { _, width in
                    editorWidth = width
                    trimPanelWidth = panelWidth
                }
                timelineGrip
                    .padding(.bottom, -6)
                timelineDock
                    // The row above can't shrink below the rail or the picture's
                    // floor, so a timeline that no longer fits (pulled tall in a
                    // big window, opened in a small one) would hang below the
                    // window's edge. Whatever hangs below is taken back.
                    .background(GeometryReader { g in
                        Color.clear.onChange(of: g.frame(in: .named("editor")).maxY, initial: true) { _, bottom in
                            let overflow = bottom - geo.size.height
                            if overflow > 0.5 {
                                timelineExtra = max(Double(Self.minTimelineExtra), timelineExtra - Double(overflow))
                            }
                        }
                    })
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .coordinateSpace(name: "editor")
        }
        // Hosts the on-device translator; it has to be somewhere that's
        // always on screen while a project is open.
        .background(translationRunner)
        .onChange(of: model.projectFolder) { _, _ in
            chosenTool = nil
            panelHidden = false
        }
        // Removing a piece is instant — ⌘Z or the Undo pill brings it
        // back. Only the last clip asks, since that empties the project.
        .confirmationDialog("Remove the whole video?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove the whole video", role: .destructive) { model.removeSelectedClip() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This is the only clip on the timeline. Removing it leaves the project empty — the file stays on your Mac, and ⌘Z brings the clip back.")
        }
    }

    private func removeSelectedClip() {
        if (model.project?.clips.count ?? 0) <= 1 { confirmingRemove = true } else { model.removeSelectedClip() }
    }

    @State private var confirmingRemove = false

    // MARK: Tools

    /// The rail's entries: one panel per job, like VEED's left rail.
    private enum Tool: String, CaseIterable, Identifiable {
        case clips, trim, subtitles, style, text, picture, music, export
        var id: String { rawValue }

        var title: String {
            switch self {
            case .clips: "Clips"
            case .trim: "Trim"
            case .subtitles: "Subtitles"
            case .style: "Style"
            case .text: "Text"
            case .picture: "Picture"
            case .music: "Music"
            case .export: "Export"
            }
        }

        var icon: String {
            switch self {
            case .clips: "film.stack"
            case .trim: "scissors"
            case .subtitles: "captions.bubble"
            case .style: "textformat"
            case .text: "textbox"
            case .picture: "photo"
            case .music: "music.note"
            case .export: "square.and.arrow.up"
            }
        }

        /// Each tool's own colour: the glyph wears it, and the open tool's
        /// tile fills with it. These are Apple's system colours, the ones
        /// in Finder tags and the Settings sidebar, so the rail reads like
        /// the rest of the Mac. The app is always dark, so the dark
        /// variants show; they also follow Increase Contrast on their own.
        var tint: Color {
            switch self {
            case .clips: .blue         // the primary tool
            case .trim: .red           // cutting, the same red as Remove
            case .subtitles: .yellow   // the classic subtitle colour
            case .style: .purple
            case .text: .orange
            case .picture: .pink
            case .music: .teal
            case .export: .green       // go
            }
        }

        var help: String {
            switch self {
            case .clips: "The takes in this video, in the order they play"
            case .trim: "Cut at the playhead, set the speed, zoom the picture, pick the transition"
            case .subtitles: "Transcribe the takes and fix any words"
            case .style: "Pick the look of the subtitles"
            case .text: "Titles laid over the video — a hook at the top, a name, a caption"
            case .picture: "A logo or picture laid over the video"
            case .music: "A song under the video, with its volume and fades"
            case .export: "Save the finished MP4"
            }
        }
    }

    /// Until the user picks a tool, the panel shows the step they're on.
    private var activeTool: Tool {
        if let chosenTool { return chosenTool }
        switch currentStep {
        case .importClips: return .clips
        case .trim: return .trim
        case .captions: return .subtitles
        case .export: return .export
        }
    }

    /// A rail click: open that tool, or fold the panel away if it's open.
    private func toggle(_ tool: Tool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if tool == activeTool && !panelHidden {
                panelHidden = true
            } else {
                chosenTool = tool
                panelHidden = false
            }
        }
    }

    private func open(_ tool: Tool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            chosenTool = tool
            panelHidden = false
        }
    }

    private var rail: some View {
        VStack(spacing: Self.railSpacing) {
            ForEach(Tool.allCases) { tool in railItem(tool) }
            Spacer(minLength: 0)
        }
        .padding(Self.railPadding)
        .frame(width: 66)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func railItem(_ tool: Tool) -> some View {
        let open = tool == activeTool && !panelHidden
        let hovered = hoveredTool == tool && !open
        let available = tool == .clips || hasClips
        let tint = tool.tint
        let done: Bool = switch tool {
            case .clips: hasClips
            case .subtitles: hasCaptions
            case .export: hasExport
            case .music: model.project?.music != nil
            case .text: model.project?.overlays.contains { $0.kind == .text } ?? false
            case .picture: model.project?.overlays.contains { $0.kind == .image } ?? false
            case .trim, .style: false
        }
        // The glyph sits in a small tile of the tool's colour: a soft wash
        // at rest, a touch brighter under the pointer, solid when open.
        // On the solid tile the glyph goes black on the light colours
        // (yellow, green, teal, orange) and white on the deep ones (blue,
        // red, purple, pink), judged by the colour's actual luminance so
        // it stays right if the system retunes a colour.
        let tile = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let openGlyph = Self.glyphColor(on: tint, in: environment)
        return Button { toggle(tool) } label: {
            VStack(spacing: 4) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(open ? openGlyph : tint)
                    .frame(width: 30, height: 22)
                    .background(
                        tile.fill(open
                                  ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(tint.opacity(hovered ? 0.30 : 0.18)))
                    )
                    .overlay(tile.strokeBorder(open ? Color.white.opacity(0.25) : tint.opacity(hovered ? 0.5 : 0.28), lineWidth: 1))
                    .shadow(color: tint.opacity(open ? 0.45 : 0), radius: 8, y: 2)
                    .overlay(alignment: .topTrailing) {
                        if done {
                            Circle()
                                .fill(open ? Color.white : tint)
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1.5))
                                .frame(width: 8, height: 8)
                                .offset(x: 3, y: -3)
                        }
                    }
                Text(tool.title)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(open ? tint : Color.white.opacity(hovered ? 0.95 : 0.72))
            }
            .frame(width: 54, height: Self.railItemHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(open ? tint.opacity(0.10) : Color.white.opacity(hovered ? 0.05 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(open ? tint.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.15), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredTool = tool } else if hoveredTool == tool { hoveredTool = nil }
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .saturation(available ? 1 : 0)
        .help(tool.help)
    }

    /// Black or white, whichever reads better on a solid fill of `tint`:
    /// black once the fill's relative luminance passes 0.3, white below.
    private static func glyphColor(on tint: Color, in environment: EnvironmentValues) -> Color {
        let rgb = tint.resolve(in: environment)
        let luminance = 0.2126 * Double(rgb.linearRed) + 0.7152 * Double(rgb.linearGreen) + 0.0722 * Double(rgb.linearBlue)
        return luminance > 0.3 ? Color.black.opacity(0.85) : .white
    }

    @ViewBuilder private func toolPanel(_ tool: Tool) -> some View {
        switch tool {
        case .clips: clipsPanel
        case .trim: trimPanel
        case .subtitles: subtitlesPanel
        case .style: stylePanel
        case .text: textPanel
        case .picture: picturePanel
        case .music: musicPanel
        case .export: exportPanel
        }
    }

    // MARK: Header

    /// One slim row: project on the left, the mode pill (Home · Edit) in
    /// the middle like VEED's, Import / Export on the right.
    private var header: some View {
        HStack(spacing: 10) {
            Text(model.project?.name ?? "")
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            Button { model.revealProject() } label: { Image(systemName: "folder").font(.system(size: 15)) }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
                .help("Show this project's folder in Finder")
            projectMenu
            Spacer(minLength: 8)
            modePill
            Spacer(minLength: 8)
            pillButton("Import clips", icon: "square.and.arrow.down") { model.chooseClips() }
                .help("Add more takes or screen recordings")
            pillButton("Export video", icon: "square.and.arrow.up", prominent: true) { model.export() }
                .disabled(!hasClips)
                .opacity(hasClips ? 1 : 0.45)
                .help("Save the finished MP4 at \(model.frameFormat.pixels) with subtitles burned in")
        }
        .disabled(model.phase.isBusy)
    }

    // MARK: Project menu

    @State private var renamingProject = false
    @State private var renameText = ""
    @State private var confirmingClear = false
    @State private var confirmingDelete = false

    /// Everything about the project as a whole, kept away from the
    /// editing controls: rename it, find it, empty it, or delete it.
    private var projectMenu: some View {
        Menu {
            Button {
                renameText = model.project?.name ?? ""
                renamingProject = true
            } label: { Label("Rename project…", systemImage: "pencil") }
            Button { model.revealProject() } label: { Label("Show in Finder", systemImage: "folder") }
            Divider()
            Button(role: .destructive) { confirmingClear = true } label: {
                Label("Clear timeline…", systemImage: "rectangle.dashed")
            }
            .disabled(!hasClips)
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete project…", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rename, find, clear or delete this project")
        .alert("Rename project", isPresented: $renamingProject) {
            TextField("Project name", text: $renameText)
            Button("Rename") { model.renameProject(to: renameText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The project's folder in Movies › ReelFlow Projects is renamed too.")
        }
        .confirmationDialog("Clear the timeline?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear timeline", role: .destructive) { model.clearTimeline() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Every clip comes off the timeline, with its cuts and subtitles. The project, its song, titles and pictures stay, and ⌘Z brings the clips back.")
        }
        .confirmationDialog("Delete \u{201C}\(model.project?.name ?? "this project")\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete project", role: .destructive) { model.deleteProject() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The project folder — its settings, subtitles and exports — goes to the Trash. Your original video files are not touched.")
        }
    }

    // MARK: Steps

    /// Where the user is in the job, from what the project holds. It picks
    /// the tool the panel opens on and the coach line's advice; nothing
    /// draws it any more.
    private enum Step: Int, CaseIterable {
        case importClips, trim, captions, export
    }

    private var hasClips: Bool { !(model.project?.clips.isEmpty ?? true) }
    private var hasCaptions: Bool { !(model.project?.timelineCues.isEmpty ?? true) }
    private var hasExport: Bool { model.lastExport != nil }

    private var currentStep: Step {
        if !hasClips { return .importClips }
        if !hasCaptions { return .trim }
        if !hasExport { return .export }
        return .export
    }

    // MARK: Mode pill

    /// VEED's centre pill: Home on the left, then the modes. Home leaves
    /// the editor for the project list; Edit is the only mode for now, so
    /// it's always the selected one.
    private var modePill: some View {
        HStack(spacing: 2) {
            Button { model.closeProject() } label: {
                Image(systemName: "house")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(homeHover ? 1 : 0.8))
                    .frame(width: 36, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(homeHover ? 0.08 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { homeHover = $0 }
            .animation(.easeOut(duration: 0.15), value: homeHover)
            .help("Home: back to your projects")
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 5)
            modeTab("Edit", selected: true)
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .fixedSize()
    }

    @State private var homeHover = false

    private func modeTab(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(selected ? .white : .white.opacity(0.6))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.white.opacity(0.10) : .clear))
    }

    // MARK: Coach line

    /// One line about what's happening: progress, a result, an error, or
    /// a note with its undo. It isn't there at all when there's nothing to
    /// say; the tools explain themselves.
    private var showsCoachLine: Bool {
        if case .idle = model.phase { return model.note != nil }
        return true
    }

    private var coachLine: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .importing(let i, let n):
                ProgressView().controlSize(.small).tint(accent)
                coachText("Reading clip \(i) of \(n)…")
            case .transcribing(let l):
                ProgressView(value: l.fraction).frame(width: 160).tint(accent)
                coachText(l.count > 1
                          ? "Listening to take \(l.index) of \(l.count) — \(VideoEditorModel.clock(l.secondsHeard)) of \(VideoEditorModel.clock(l.duration)) heard. Words appear below as it goes."
                          : "Listening — \(VideoEditorModel.clock(l.secondsHeard)) of \(VideoEditorModel.clock(l.duration)) heard. Words appear below as it goes.")
            case .translating(let n):
                ProgressView().controlSize(.small).tint(accent)
                coachText("Translating \(n) subtitle\(n == 1 ? "" : "s") into \(SubtitleLanguages.name(ofLanguage: model.translationLanguage ?? ""))…")
            case .exporting(let p):
                ProgressView(value: p).frame(width: 160).tint(accent)
                coachText("Exporting your video… \(Int(p * 100))%")
            case .subtitled(let n):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                coachText("Done! \(n) subtitle\(n == 1 ? "" : "s") ready — they're on the video and in the Subtitles panel. Click a word there to fix it, then press Export video.")
                Spacer()
                dismissButton
            case .exported(let url):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                coachText("Done! \(url.lastPathComponent)")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.plain).foregroundStyle(accent).fontWeight(.semibold)
                Spacer()
                dismissButton
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(.orange).lineLimit(2)
                Spacer()
                dismissButton
            case .idle:
                Image(systemName: "lightbulb.fill").foregroundStyle(accent.opacity(0.9))
                coachText(model.note ?? "")
                if let action = model.noteAction {
                    Button(action.title, action: action.run)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(accent))
                        .help("Put it back (⌘Z)")
                }
            }
            if !isTerminal(model.phase) { Spacer() }
        }
        .font(.system(size: 14, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func isTerminal(_ phase: VideoEditorModel.Phase) -> Bool {
        switch phase {
        case .subtitled, .exported, .failed: true
        default: false
        }
    }

    private func coachText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var dismissButton: some View {
        Button { model.dismissPhase() } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.4))
            .help("Dismiss")
    }
    // MARK: Preview

    private func preview(height: CGFloat) -> some View {
        let format = model.frameFormat
        let width = height * format.aspect
        let render = format.renderSize
        return ZStack {
            VideoEditorSurface(player: model.player,
                               zoom: CGFloat(model.playheadClip?.zoom ?? 1),
                               pan: dragPan ?? model.playheadClip.map { CGSize(width: $0.panX, height: $0.panY) } ?? .zero,
                               clipID: model.playheadClip?.id)
            if hasClips { panHandle(width: width, height: height) }
            if !hasClips {
                VStack(spacing: 10) {
                    Image(systemName: format.isPortrait ? "iphone" : "rectangle.on.rectangle").font(.system(size: 36, weight: .thin))
                    Text("Your video shows here").font(.system(size: 12, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.35))
            } else if !model.isPlaying {
                // A big, obvious play button while paused.
                Button { model.togglePlay() } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if let cue = model.currentCue {
                // The export's own caption layer, so the preview is exact.
                CaptionLayerView(text: cue.displayText,
                                 highlight: model.style.accentColor == nil ? nil : model.project?.wordIndex(in: cue, at: model.currentTime),
                                 style: model.style, anchor: dragAnchor ?? model.anchor(for: cue), placement: .onVideo, render: render)
                    .frame(width: width, height: height)
                    .allowsHitTesting(false)
                captionHandle(for: cue, width: width, height: height)
            }
            ForEach(model.overlaysNow) { overlay in
                overlayPreview(overlay, width: width, height: height)
            }
            if showSafeZone && hasClips { safeZoneShade(width: width, height: height) }
            ForEach(snapGuides, id: \.self) { guide in
                snapGuideLine(guide, width: width, height: height)
            }
            if hasClips && !showSafeZone {
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Spacer()
                        if let zoom = model.selectedClip?.zoom, zoom > 1.01 {
                            badge(String(format: "%.1f×", zoom), tint: accent)
                        }
                        badge(format.ratio, tint: .white.opacity(0.5))
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: width, height: height)
        .background(canvasColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    /// The picture's spot while it's being dragged, and where the drag began.
    @State private var dragPan: CGSize?
    @State private var dragPanStart: CGSize?

    /// The whole picture is a grab area, as on VEED's canvas: drag the
    /// picture anywhere, at any zoom, pinch to zoom, click to play or
    /// pause, double-click to put the picture back in the middle.
    private func panHandle(width: CGFloat, height: CGFloat) -> some View {
        let clip = model.selectedClip
        return MouseHandle(
            cursor: .openHand,
            onTap: { model.selectedOverlayID = nil; model.togglePlay() },
            onDrag: { translation in
                guard let clip else { return }
                let from = dragPanStart ?? CGSize(width: clip.panX, height: clip.panY)
                if dragPanStart == nil { dragPanStart = from }
                dragPan = CGSize(width: VideoExporter.clampPan(from.width + translation.width / width),
                                 height: VideoExporter.clampPan(from.height + translation.height / height))
            },
            onEnd: {
                if let dragPan { model.setPan(dragPan) }
                dragPan = nil
                dragPanStart = nil
            },
            onReset: { model.setPan(.zero) },
            onMagnify: { factor in model.zoom(by: factor) }
        )
        .help("Drag to move the picture anywhere in the frame; double-click to centre it. Pinch to zoom.")
    }
    /// The subtitle's spot while it's being dragged, and where the drag began.
    @State private var dragAnchor: CaptionAnchor?
    @State private var dragStart: CGPoint?
    @State private var captionHover = false

    /// A grab area over the subtitle: drag it anywhere on the video and the
    /// export follows. A dashed outline shows on hover so it reads as
    /// movable; double-click puts it back where the style keeps it. The
    /// mouse work is AppKit's (`CaptionDragHandle`): the panel moves when
    /// its background is dragged, and only a real view can refuse that.
    private func captionHandle(for cue: TimelineCue, width: CGFloat, height: CGFloat) -> some View {
        let style = model.style
        let render = model.renderSize
        let scale = width / render.width
        let pill = VideoExporter.captionFrame(for: style.display(cue.displayText), style: style,
                                              anchor: dragAnchor ?? model.anchor(for: cue), render: render).pill
        let detached = cue.anchor != nil
        // Render space has its origin at the bottom; the preview's is at the top.
        let centre = CGPoint(x: pill.midX * scale, y: height - pill.midY * scale)
        let active = captionHover || dragAnchor != nil
        return RoundedRectangle(cornerRadius: style.cornerRadius * scale + 3, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(accent.opacity(active ? 0.9 : 0))
            .frame(width: pill.width * scale + 8, height: pill.height * scale + 8)
            .overlay(
                MouseHandle(
                    cursor: .openHand,
                    onHover: { captionHover = $0 },
                    onTap: { model.selectedOverlayID = nil },
                    onDrag: { translation in
                        let from = dragStart ?? centre
                        if dragStart == nil { dragStart = centre }
                        let to = CGPoint(x: from.x + translation.width, y: from.y + translation.height)
                        dragAnchor = CaptionAnchor(x: min(max(0, to.x / width), 1),
                                                   y: min(max(0, (height - to.y) / height), 1))
                    },
                    onEnd: {
                        // A detached line moves alone; the rest move together.
                        if detached { model.setCueAnchor(cue.id, dragAnchor) } else { model.setCaptionAnchor(dragAnchor) }
                        dragAnchor = nil
                        dragStart = nil
                    },
                    onReset: {
                        if detached { model.setCueAnchor(cue.id, nil) } else { model.setCaptionAnchor(nil) }
                    }
                )
            )
            .position(centre)
            .help(detached
                  ? "This line has its own spot — drag to move just this line; double-click to rejoin the others"
                  : "Drag to move the subtitles anywhere on the video — double-click to put them back")
    }

    /// A title or picture as it will be on the video, with a grab area:
    /// drag to move it, click to pick it in its panel.
    @State private var dragOverlayID: UUID?
    @State private var dragOverlayAnchor: CaptionAnchor?
    @State private var dragOverlayStart: CGPoint?
    @State private var hoverOverlayID: UUID?

    /// The overlay where the mouse has it mid-drag, or where it is.
    private func dragged(_ overlay: Overlay) -> Overlay {
        guard dragOverlayID == overlay.id, let dragOverlayAnchor else { return overlay }
        var moved = overlay
        moved.anchor = dragOverlayAnchor
        return moved
    }

    @ViewBuilder
    private func overlayPreview(_ overlay: Overlay, width: CGFloat, height: CGFloat) -> some View {
        let render = model.renderSize
        let scale = width / render.width
        let shown = dragged(overlay)
        let image = model.overlayImage(for: overlay)
        let frame = overlayRect(shown)
        let centre = CGPoint(x: frame.midX * scale, y: height - frame.midY * scale)
        let selected = overlay.id == model.selectedOverlayID
        let active = selected || hoverOverlayID == overlay.id || dragOverlayID == overlay.id
        let snapped = dragOverlayID == overlay.id && !snapGuides.isEmpty

        if overlay.kind == .text {
            CaptionLayerView(text: shown.text, highlight: nil, style: shown.captionStyle, anchor: shown.anchor,
                             placement: .onVideo, render: render)
                .frame(width: width, height: height)
                .opacity(shown.opacity)
                .allowsHitTesting(false)
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: frame.width * scale, height: frame.height * scale)
                .opacity(shown.opacity)
                .position(centre)
                .allowsHitTesting(false)
        }
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: snapped ? 2 : selected ? 1.5 : 1, dash: snapped ? [] : [4, 3]))
            .foregroundStyle(snapped ? Self.snapColor : accent.opacity(active ? 0.9 : 0))
            .frame(width: frame.width * scale + 8, height: frame.height * scale + 8)
            .overlay(
                MouseHandle(
                    cursor: .openHand,
                    onHover: { hoverOverlayID = $0 ? overlay.id : (hoverOverlayID == overlay.id ? nil : hoverOverlayID) },
                    onTap: { model.selectedOverlayID = overlay.id; open(overlay.kind == .text ? .text : .picture) },
                    onDrag: { translation in
                        let from = dragOverlayStart ?? centre
                        if dragOverlayStart == nil {
                            dragOverlayStart = centre
                            dragOverlayID = overlay.id
                            model.selectedOverlayID = overlay.id
                        }
                        let to = CGPoint(x: from.x + translation.width, y: from.y + translation.height)
                        let free = CaptionAnchor(x: min(max(0, to.x / width), 1),
                                                 y: min(max(0, (height - to.y) / height), 1))
                        let (anchor, guides) = snap(free, for: overlay)
                        dragOverlayAnchor = anchor
                        snapGuides = guides
                    },
                    onEnd: {
                        if let dragOverlayAnchor { model.setOverlayAnchor(overlay.id, dragOverlayAnchor) }
                        dragOverlayID = nil
                        dragOverlayAnchor = nil
                        dragOverlayStart = nil
                        snapGuides = []
                    }
                )
            )
            .position(centre)
            .help(overlay.kind == .text ? "Drag to move this title; click to edit it" : "Drag to move this picture; click to size it")
    }

    // MARK: Snapping and the safe zone

    /// Where a title or picture sits in render space (y up).
    private func overlayRect(_ overlay: Overlay) -> CGRect {
        let render = model.renderSize
        switch overlay.kind {
        case .text:
            return VideoExporter.captionFrame(for: overlay.captionStyle.display(overlay.text), style: overlay.captionStyle,
                                              anchor: overlay.anchor, render: render).pill
        case .image:
            return VideoExporter.pictureFrame(for: overlay, image: model.overlayImage(for: overlay), render: render)
        }
    }

    /// A line the dragged title has locked onto, in render space (y up).
    private enum SnapGuide: Hashable {
        case horizontal(CGFloat)
        case vertical(CGFloat)
    }

    @State private var snapGuides: [SnapGuide] = []
    /// System green for the guide lines when a dragged title snaps.
    private static let snapColor = Color.green
    @AppStorage("reelflowSafeZone") private var showSafeZone = false

    /// Pull a dragged title or picture onto the spots that matter: snug
    /// under or above the video, the middle of the frame, and the edge
    /// of Instagram's safe area. Returns where it lands and the guides
    /// to light up.
    private func snap(_ free: CaptionAnchor, for overlay: Overlay) -> (CaptionAnchor, [SnapGuide]) {
        let render = model.renderSize
        var moved = overlay
        moved.anchor = free
        let rect = overlayRect(moved)
        let tolerance = render.width * 0.018
        let gap = render.height * 0.012
        var anchor = free
        var guides: [SnapGuide] = []

        // Sideways: the middle of the frame, or another title's middle or edges.
        var sideways: [(edge: CGFloat, target: CGFloat, guide: CGFloat)] = [(rect.midX, render.width / 2, render.width / 2)]
        for other in model.overlaysNow where other.id != overlay.id {
            let o = overlayRect(other)
            sideways.append((rect.midX, o.midX, o.midX))
            sideways.append((rect.minX, o.minX, o.minX))
            sideways.append((rect.maxX, o.maxX, o.maxX))
        }
        if let best = sideways.min(by: { abs($0.edge - $0.target) < abs($1.edge - $1.target) }), abs(best.edge - best.target) < tolerance {
            anchor.x = Double((rect.midX + (best.target - best.edge)) / render.width)
            guides.append(.vertical(best.guide))
        }
        // Whichever horizontal target is nearest wins.
        var targets: [(edge: CGFloat, top: CGFloat, guide: CGFloat)] = []   // where rect.minY should land, or rect.maxY
        if let picture = model.playheadClip.flatMap({ model.pictureRect(for: $0) }) {
            targets.append((edge: rect.maxY, top: picture.minY - gap, guide: picture.minY))   // snug under the picture
            targets.append((edge: rect.minY, top: picture.maxY + gap, guide: picture.maxY))   // snug above it
        }
        let safeBottom = render.height * VideoEditorModel.SafeZone.bottom
        targets.append((edge: rect.minY, top: safeBottom, guide: safeBottom))
        let safeTop = render.height * (1 - VideoEditorModel.SafeZone.top)
        targets.append((edge: rect.maxY, top: safeTop, guide: safeTop))
        // The other titles and pictures on screen: stack snug under or
        // above one, or line up with its edges.
        for other in model.overlaysNow where other.id != overlay.id {
            let o = overlayRect(other)
            targets.append((edge: rect.maxY, top: o.minY - gap, guide: o.minY))
            targets.append((edge: rect.minY, top: o.maxY + gap, guide: o.maxY))
            targets.append((edge: rect.minY, top: o.minY, guide: o.minY))
            targets.append((edge: rect.maxY, top: o.maxY, guide: o.maxY))
        }
        if let best = targets.min(by: { abs($0.edge - $0.top) < abs($1.edge - $1.top) }), abs(best.edge - best.top) < tolerance {
            let shift = best.top - best.edge
            anchor.y = Double((rect.midY + shift) / render.height)
            guides.append(.horizontal(best.guide))
        }
        return (anchor, guides)
    }

    private func snapGuideLine(_ guide: SnapGuide, width: CGFloat, height: CGFloat) -> some View {
        let scale = width / model.renderSize.width
        return Group {
            switch guide {
            case .horizontal(let y):
                Rectangle().fill(Self.snapColor).frame(width: width, height: 1.5)
                    .position(x: width / 2, y: height - y * scale)
            case .vertical(let x):
                Rectangle().fill(Self.snapColor).frame(width: 1.5, height: height)
                    .position(x: x * scale, y: height / 2)
            }
        }
        .allowsHitTesting(false)
    }

    /// Shades the parts of the frame Instagram covers with its own UI.
    private func safeZoneShade(width: CGFloat, height: CGFloat) -> some View {
        let bottom = height * max(VideoEditorModel.SafeZone.bottom, VideoEditorModel.SafeZone.feedCrop)
        let top = height * max(VideoEditorModel.SafeZone.top, VideoEditorModel.SafeZone.feedCrop)
        let right = width * VideoEditorModel.SafeZone.right
        let rail = VideoEditorModel.SafeZone.railRange
        let shade = Color.red.opacity(0.28)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(shade).frame(width: width, height: top)
                .position(x: width / 2, y: top / 2)
            Rectangle().fill(shade).frame(width: width, height: bottom)
                .position(x: width / 2, y: height - bottom / 2)
            Rectangle().fill(shade).frame(width: right, height: height * (rail.upperBound - rail.lowerBound))
                .position(x: width - right / 2, y: height * (1 - (rail.lowerBound + rail.upperBound) / 2))
            Text("Instagram covers or crops the red")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.7)))
                .position(x: width / 2, y: height - bottom / 2)
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// The project's background as a SwiftUI colour.
    private var canvasColor: Color { Self.color(of: model.canvasBackground) }

    private static func color(of background: CanvasBackground) -> Color {
        let (r, g, b) = background.rgb
        return Color(red: r, green: g, blue: b)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    // MARK: Canvas

    /// The video, centred like VEED's canvas, with the quick-action bar
    /// floating under it: the frame shape, picture zoom and the subtitle
    /// style. Auto-subtitle lives in the Subtitles panel.
    private var canvas: some View {
        GeometryReader { geo in
            let barHeight = Self.canvasBarHeight
            // As tall as the panel allows, but never wider than the canvas.
            let height = max(Self.previewMinHeight, min(geo.size.height - barHeight - Self.canvasSpacing, (geo.size.width - 16) / model.frameFormat.aspect))
            VStack(spacing: Self.canvasSpacing) {
                Spacer(minLength: 0)
                preview(height: height)
                    .background(GeometryReader { frame in
                        Color.clear.onChange(of: frame.frame(in: .named("editorRow")), initial: true) { _, rect in
                            videoRect = rect
                        }
                    })
                canvasBar
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // A click on the empty canvas lets go of whichever title was picked.
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.selectedOverlayID = nil })
        }
    }

    private var canvasBar: some View {
        ViewThatFits(in: .horizontal) {
            canvasBarContent(full: true)
            canvasBarContent(full: false)
        }
        .disabled(!hasClips)
        .opacity(hasClips ? 1 : 0.45)
    }

    /// The frame picker's popover, open or not.
    @State private var showFramePicker = false

    private func canvasBarContent(full: Bool) -> some View {
        let preset = model.stylePreset
        let format = model.frameFormat
        let zoom = model.selectedClip?.zoom ?? 1
        
        // Use custom ring for Instagram portrait formats, otherwise use default symbol
        let icon = canvasBarIcon(for: format)
        
        return HStack(spacing: 2) {
            barButton(icon, full ? format.name : format.ratio, chevron: true,
                      help: "Frame: \(format.name) · exports at \(format.pixels) — click to resize for another platform") {
                showFramePicker.toggle()
            }
            .popover(isPresented: $showFramePicker, arrowEdge: .top) {
                FrameFormatPicker(selected: format) { chosen in
                    model.setFrameFormat(chosen)
                    showFramePicker = false
                }
            }
            barDivider
            HStack(spacing: 2) {
                barButton("minus.magnifyingglass", help: "Zoom the picture out (or pinch on the video)") { model.zoom(by: 1 / 1.15) }
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(zoom > 1.01 ? accent : Color.white.opacity(0.7))
                    .frame(width: 40)
                barButton("plus.magnifyingglass", help: "Zoom the picture in — crops from the centre (or pinch on the video)") { model.zoom(by: 1.15) }
                barButton("rectangle.arrowtriangle.2.inward", full ? "Fill" : nil,
                          help: "Zoom just enough that the picture fills the whole \(format.ratio) frame with no black bars") { model.zoomToFill() }
                barButton("rectangle.arrowtriangle.2.outward", full ? "Fit" : nil,
                          help: "Show the whole picture (black bars where the shapes differ)") { model.setZoom(1) }
            }
            barDivider
            barButton("textformat", full ? preset.name : nil, chevron: true,
                      help: "Subtitle style: \(preset.name) · \(preset.category.rawValue) — click to change") { open(.style) }
            barDivider
            barButton(showSafeZone ? "eye.fill" : "eye", full ? "Safe zone" : nil,
                      help: showSafeZone ? "Hide the parts of the frame Instagram covers with its caption and buttons"
                                         : "Show the parts of the frame Instagram covers with its caption and buttons — keep titles out of them") {
                showSafeZone.toggle()
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .fixedSize()
    }

    private var barDivider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func barButton(_ icon: some View, _ title: String? = nil, chevron: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
                }
                if chevron {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, title == nil ? 7 : 9)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Helper for String symbols - wraps them in an Image with the same styling as before
    private func barButton(_ symbol: String, _ title: String? = nil, chevron: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        let icon = Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
        return self.barButton(icon, title, chevron: chevron, help: help, action: action)
    }

    /// Returns the icon to show for a format in the canvas bar.
    /// Instagram portrait formats get a custom broken ring; others use their symbol.
    private func canvasBarIcon(for format: FrameFormat) -> some View {
        Group {
            if format.brand == .instagram && format.isPortrait {
                // Broken ring for Instagram portrait formats (Reel, Story)
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color(red: 0.99, green: 0.73, blue: 0.27),   // orange
                                Color(red: 0.87, green: 0.18, blue: 0.44),   // pink
                                Color(red: 0.51, green: 0.23, blue: 0.71),   // purple
                                Color(red: 0.99, green: 0.73, blue: 0.27)    // orange (again to close the seam)
                            ],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [4, 3])
                    )
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: format.symbol).font(.system(size: 13, weight: .semibold))
            }
        }
    }

    // MARK: Timeline

    // The editor row (rail, panel, canvas) sits between the header and the
    // timeline. It can't be shorter than the rail with every tool showing,
    // nor than the picture at its floor with the bar under it; the grip's
    // range is whatever the row is taller than that right now.
    static let railItemHeight: CGFloat = 44
    static let railSpacing: CGFloat = 8
    static let railPadding: CGFloat = 6
    static let previewMinHeight: CGFloat = 160
    static let canvasBarHeight: CGFloat = 44
    static let canvasSpacing: CGFloat = 12
    static var railMinHeight: CGFloat {
        let count = CGFloat(Tool.allCases.count)
        return count * railItemHeight + (count - 1) * railSpacing + 2 * railPadding
    }
    static var editorRowMinHeight: CGFloat { max(railMinHeight, previewMinHeight + canvasBarHeight + canvasSpacing) }
    /// Dragging down past the rest position lets the clip strip shrink from 84pt to 48pt.
    static let minTimelineExtra: CGFloat = -36

    /// VEED's split between the canvas and the timeline: pull it up for a
    /// taller timeline (bigger frames, a taller sound strip), down for more
    /// video. The whole line is the handle, not just the pill: the grab
    /// band runs the full width and well above and below the line. Double-
    /// click puts it back.
    private var timelineGrip: some View {
        let active = gripHover || gripDragStart != nil
        return ZStack {
            Rectangle()
                .fill(active ? accent : Color.white.opacity(0.12))
                .frame(height: active ? 2 : 1)
            VStack(spacing: 1.5) {
                Triangle().frame(width: 8, height: 4).rotationEffect(.degrees(180))
                Rectangle().frame(width: 12, height: 1.5)
                Rectangle().frame(width: 12, height: 1.5)
                Triangle().frame(width: 8, height: 4)
            }
            .foregroundStyle(active ? accent : Color.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .overlay(Capsule().strokeBorder(active ? accent.opacity(0.8) : Color.white.opacity(0.15), lineWidth: 1))
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .overlay(
            MouseHandle(
                cursor: .resizeUpDown,
                onHover: { gripHover = $0 },
                onDrag: { translation in
                    if gripDragStart == nil {
                        gripDragStart = CGFloat(timelineExtra)
                        // The row above gives up what it has over its floor; past
                        // that the timeline would only grow below the window.
                        gripDragMax = CGFloat(timelineExtra) + max(0, editorRowHeight - Self.editorRowMinHeight)
                    }
                    let from = gripDragStart ?? CGFloat(timelineExtra)
                    // Up is a negative translation, and up means taller.
                    timelineExtra = Double(min(max(Self.minTimelineExtra, from - translation.height), gripDragMax))
                },
                onEnd: { gripDragStart = nil },
                onReset: { timelineExtra = 0 }
            )
            // Taller than the strip it sits on, so a hand near the line
            // catches it without aiming at the pixel.
            .frame(height: 28)
        )
        // Over the dock below, which otherwise covers the band's lower half.
        .zIndex(1)
        .animation(.easeOut(duration: 0.12), value: active)
        .help("Drag up for a taller timeline, down for more video — double-click to put it back")
    }

    /// Docked along the bottom like VEED's: the transport row, then a time
    /// ruler, the subtitles track and the clips with their sound.
    private var timelineDock: some View {
        card(title: nil, trailing: nil) {
            VStack(alignment: .leading, spacing: 8) {
                transportRow
                if hasClips {
                    tracks
                } else {
                    emptyRow(icon: "square.and.arrow.down",
                             text: "Your clips will line up here in the order they'll play. Press Import clips, or drop video files anywhere on this tab.")
                }
            }
        }
    }

    /// Play in the middle, the highlighted clip's moves on the right. Split
    /// and the cuts live in the Trim panel. Labels drop off when the panel
    /// is narrow.
    private var transportRow: some View {
        ViewThatFits(in: .horizontal) {
            transportContent(labels: true)
            transportContent(labels: false)
        }
        .disabled(!hasClips || model.phase.isBusy)
        .opacity(hasClips ? 1 : 0.4)
    }

    private func transportContent(labels: Bool) -> some View {
        // The play cluster sits at the true centre whatever is on the right.
        ZStack {
            HStack(spacing: 6) {
                transportButton("backward.end.fill", nil, help: "Jump to the beginning") { model.seek(to: 0) }
                transportButton("gobackward.5", nil, help: "Go back five seconds") { model.seek(to: model.currentTime - 5) }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(accent))
                }
                .buttonStyle(.plain)
                .help(model.isPlaying ? "Pause" : "Play")
                transportButton("goforward.5", nil, help: "Go forward five seconds") { model.seek(to: model.currentTime + 5) }
                HStack(spacing: 4) {
                    Text(VideoEditorModel.clock(model.currentTime))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                    Text("/ \(VideoEditorModel.clock(model.duration))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .padding(.leading, 4)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                if labels, let clip = model.selectedClip {
                    Label(clip.name, systemImage: "film")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
                transportButton("arrow.left", labels ? "Earlier" : nil,
                                help: "Move the highlighted clip one place earlier") { model.moveSelectedClip(by: -1) }
                transportButton("arrow.right", labels ? "Later" : nil,
                                help: "Move the highlighted clip one place later") { model.moveSelectedClip(by: 1) }
                transportButton("trash", labels ? "Remove" : nil, destructive: true,
                                help: "Take the highlighted clip out of the video (the file stays on disk)") { removeSelectedClip() }
            }
        }
    }

    private func transportButton(_ symbol: String, _ title: String?, destructive: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                if let title {
                    Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                }
            }
            .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.white.opacity(0.9))
            .padding(.horizontal, title == nil ? 8 : 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// How much taller than its slimmest the timeline has been pulled, in
    /// points. Remembered between launches, like VEED's split.
    @AppStorage("reelflowTimelineExtra") private var timelineExtra: Double = 0
    @State private var gripHover = false
    @State private var gripDragStart: CGFloat?
    @State private var gripDragMax: CGFloat = 0
    @State private var editorRowHeight: CGFloat = 0

    /// Ruler 22 + gap 4 + subtitles 22 + gap 4 + clips.
    private var tracksHeight: CGFloat { 22 + 4 + Self.subtitleLaneHeight + 4 + clipHeight }
    private static let subtitleLaneHeight: CGFloat = 30
    /// A clip is iMovie's shape: frames along the top, sound underneath.
    /// Pulling the timeline taller grows both, the frames faster.
    private var clipHeight: CGFloat { 84 + CGFloat(timelineExtra) }
    private var filmHeight: CGFloat { 56 + CGFloat(timelineExtra) * 0.7 }
    /// System yellow for the loud bits, the way iMovie marks them.
    private static let loud = Color.yellow

    /// Ruler, subtitles and clips share one width, so one playhead runs
    /// through all of them and one drag scrubs anywhere.
    private var tracks: some View {
        GeometryReader { geo in
            let total = max(model.duration, 0.001)
            let width = geo.size.width
            let x = width * min(model.currentTime / total, 1)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    ruler(width: width, total: total)
                    subtitlesTrack(width: width, total: total)
                    timelineStrip
                }
                VStack(spacing: 0) {
                    Triangle().fill(accent).frame(width: 10, height: 6)
                    Rectangle().fill(accent).frame(width: 2)
                }
                .frame(height: tracksHeight)
                .offset(x: x - 5)
                .shadow(color: accent.opacity(0.7), radius: 3)
                .allowsHitTesting(false)
            }
            .frame(width: width, height: tracksHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            // One gesture covers both a click (jump there) and a drag (scrub),
            // anywhere on the ruler or a track. The clip under the new time
            // becomes the selected clip.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.seek(to: total * min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { value in
                        model.seek(to: total * min(max(value.location.x / width, 0), 1))
                    }
            )
        }
        .frame(height: tracksHeight)
    }

    /// Time along the top, like VEED's: a label every few seconds (the gap
    /// chosen so labels never crowd) and finer ticks between.
    private func ruler(width: CGFloat, total: Double) -> some View {
        let step = Self.rulerStep(for: total, width: width)
        let minor = step / 5
        return Canvas { context, size in
            let scale = size.width / total
            var i = 0
            var t = 0.0
            while t <= total + 0.0001 {
                let x = t * scale
                let isMajor = i % 5 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height))
                tick.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? 6 : 3)))
                context.stroke(tick, with: .color(Color.white.opacity(isMajor ? 0.35 : 0.18)), lineWidth: 1)
                if isMajor && x + 44 < size.width {
                    let label = Text(Self.rulerLabel(t))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.7))
                    context.draw(label, at: CGPoint(x: x + 4, y: 7), anchor: .leading)
                }
                i += 1
                t = Double(i) * minor
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(base, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
        }
        .frame(width: width, height: 22)
        .allowsHitTesting(false)
    }

    /// The label spacing in seconds: the first that keeps labels 80 pt apart.
    private static func rulerStep(for total: Double, width: CGFloat) -> Double {
        let options: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return options.first { CGFloat($0 / total) * width >= 80 } ?? 600
    }

    private static func rulerLabel(_ t: Double) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s % 60 == 0 { return "\(s / 60)m" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// VEED's subtitles lane: a block for every line with its words inside,
    /// the live one lit. Click a block to jump to it and open that line in
    /// the Subtitles panel; with the playhead in a gap, "+ Add subtitle"
    /// offers a blank line to type. Before the first subtitles the lane is
    /// one button that takes you to Auto-subtitle.
    private func subtitlesTrack(width: CGFloat, total: Double) -> some View {
        let cues = model.project?.timelineCues ?? []
        let now = model.currentTime
        let inGap = !cues.isEmpty && model.currentCue == nil && hasClips
        let height = Self.subtitleLaneHeight
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(cues.isEmpty ? Color.white.opacity(0.05) : accent.opacity(0.12))
            if cues.isEmpty {
                // The whole lane is the hint, and the hint is the way in.
                Button { open(.subtitles) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "captions.bubble.fill")
                        Text(hasClips ? "No subtitles yet — click here, then press Auto-subtitle" : "Subtitles appear here once your clips are transcribed")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(Color.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasClips)
                .help("Open the Subtitles panel")
            } else {
                Canvas { context, size in
                    let scale = size.width / total
                    for cue in cues {
                        let live = now >= cue.start && now < cue.end
                        let rect = CGRect(x: cue.start * scale, y: 4,
                                          width: max(2, (cue.end - cue.start) * scale - 2), height: size.height - 8)
                        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(accent.opacity(live ? 0.95 : 0.45)))
                        guard rect.width > 24 else { continue }
                        // The words, clipped to the block: the lane reads like a script.
                        context.drawLayer { layer in
                            layer.clip(to: Path(rect.insetBy(dx: 5, dy: 0)))
                            let words = Text(cue.text.isEmpty ? "(empty — type it in the panel)" : cue.text)
                                .font(.system(size: 10.5, weight: live ? .bold : .medium, design: .monospaced))
                                .foregroundStyle(live ? Color.black : Color.white.opacity(0.95))
                            layer.draw(words, at: CGPoint(x: rect.minX + 6, y: rect.midY), anchor: .leading)
                        }
                    }
                }
                .allowsHitTesting(false)
                // A click on a block: go there and open that line to edit.
                ForEach(cues) { cue in
                    let x = width * cue.start / total
                    let w = max(2, width * (cue.end - cue.start) / total - 2)
                    Button {
                        model.seek(to: cue.start)
                        model.cueToReveal = cue.id
                        open(.subtitles)
                    } label: {
                        Color.clear.frame(width: w, height: height).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: x)
                    .help("“\(cue.text)” — click to jump here and edit this line")
                }
            }
        }
        .frame(width: width, height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(cues.isEmpty ? Color.white.opacity(0.12) : accent.opacity(0.35), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if inGap {
                // Always the same pill, floating just above the lane beside
                // the playhead, so it never sits on a neighbour's words and
                // looks the same wherever you click.
                let pillWidth: CGFloat = 150
                addSubtitlePill
                    .frame(width: pillWidth)
                    .offset(x: min(max(0, width * now / total - pillWidth / 2), width - pillWidth), y: -(Self.addPillHeight + 2))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: inGap)
    }

    private static let addPillHeight: CGFloat = 22

    /// The one button that lives on the tracks: it wins over the scrub
    /// gesture beneath, so a click adds a line instead of jumping.
    private var addSubtitlePill: some View {
        Button {
            model.addCueAtPlayhead()
            open(.subtitles)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .black))
                Text("Add subtitle here").font(.system(size: 10.5, weight: .bold, design: .monospaced)).lineLimit(1)
            }
            .foregroundStyle(Color.black)
            .frame(height: Self.addPillHeight)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(accent))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(model.phase.isBusy)
        .help("Add a blank subtitle at the playhead and type it in the Subtitles panel")
    }

    /// The clips in play order, each with its sound drawn inside.
    private var timelineStrip: some View {
        GeometryReader { geo in
            let total = max(model.duration, 0.001)
            ZStack(alignment: .leading) {
                HStack(spacing: 3) {
                    if let project = model.project {
                        ForEach(project.clips) { clip in
                            clipBlock(clip, width: max(6, geo.size.width * clip.duration / total - 3))
                        }
                    }
                }

                // Seams that can be healed: a faint stitch mark always, and
                // a Rejoin pill when the mouse rests near one.
                if let project = model.project {
                    ForEach(healableSeams(in: project), id: \.self) { index in
                        let seamX = geo.size.width * project.clipStarts[index + 1] / total
                        let near = hoverX.map { abs($0 - seamX) < 16 } ?? false
                        if near {
                            rejoinPill(index: index)
                                .position(x: seamX, y: clipHeight / 2)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        } else {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                                .position(x: seamX, y: clipHeight / 2)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(height: clipHeight)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop(); hoverX = nil }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .animation(.easeOut(duration: 0.12), value: hoverX == nil)
        }
        .frame(height: clipHeight)
    }

    /// Where the mouse is over the timeline strip, for the Rejoin pill.
    @State private var hoverX: CGFloat?

    /// Indices i where clip i and clip i+1 are the same footage back to back.
    private func healableSeams(in project: VideoProject) -> [Int] {
        project.clips.indices.dropLast().filter { project.canRejoin(after: $0) }
    }

    /// Straddles a healed-able seam: one click glues the two halves back.
    private func rejoinPill(index: Int) -> some View {
        Button { model.rejoin(after: index) } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .black))
                Text("Rejoin").font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(accent))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help("These two pieces are the same footage back to back — click to make them one clip again")
    }

    private func clipBlock(_ clip: EditClip, width: CGFloat) -> some View {
        let selected = clip.id == model.selectedClipID
        return ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    filmstrip(for: clip, width: width)
                    waveform(for: clip, width: width)
                }
                HStack(spacing: 5) {
                    Text(clip.name)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Text(VideoEditorModel.clock(clip.duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                    if !clip.cues.isEmpty {
                        Image(systemName: "captions.bubble.fill").font(.system(size: 9))
                            .foregroundStyle(accent.opacity(0.9))
                    }
                    if clip.zoom > 1.01 {
                        Text(String(format: "%.1f×", clip.zoom))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                    }
                    if abs(clip.speed - 1) > 0.01 {
                        Label(Self.speedLabel(clip.speed), systemImage: clip.speed < 1 ? "tortoise.fill" : "hare.fill")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                    }
                    if clip.transition != .none {
                        Image(systemName: clip.transition.icon).font(.system(size: 9))
                            .foregroundStyle(accent.opacity(0.9))
                            .help("\(clip.transition.name) into the next clip")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(5)
                .frame(maxWidth: width, alignment: .leading)
            }
            .frame(width: width, height: clipHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? accent.opacity(0.32) : Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? accent : Color.white.opacity(0.14), lineWidth: selected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.white.opacity(0.9))
            .help("\(clip.source.path)\nClick anywhere on the timeline to jump there; drag to scrub.")
    }

    /// iMovie's filmstrip: one frame per tile along the clip, each the
    /// frame from that moment, at the picture's own shape.
    @ViewBuilder
    private func filmstrip(for clip: EditClip, width: CGFloat) -> some View {
        let height = filmHeight
        if let frames = model.filmstrips[clip.source.path], let first = frames.first {
            let tileWidth = max(12, height * CGFloat(first.width) / CGFloat(max(1, first.height)))
            Canvas { context, size in
                var x: CGFloat = 0
                while x < size.width {
                    let visible = min(tileWidth, size.width - x)
                    // Source seconds along the clip, whatever its speed.
                    let offset = clip.sourceLength * Double((x + visible / 2) / size.width)
                    if let frame = Filmstrip.frame(in: frames, at: clip.inPoint + offset, sourceDuration: clip.sourceDuration) {
                        var tile = context
                        tile.clip(to: Path(CGRect(x: x, y: 0, width: visible, height: height)))
                        tile.draw(Image(decorative: frame, scale: 1), in: CGRect(x: x, y: 0, width: tileWidth, height: height))
                    }
                    x += tileWidth
                }
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
        } else {
            Color.clear.frame(width: width, height: height)
        }
    }

    /// iMovie's sound strip: loudness rises from the bottom in blue and the
    /// loudest moments tip over into yellow. What's already played is
    /// brighter so the playhead has a trail.
    @ViewBuilder
    private func waveform(for clip: EditClip, width: CGFloat) -> some View {
        let height = clipHeight - filmHeight
        let step: CGFloat = 2
        let count = max(2, Int(width / step))
        if let raw = model.waveformBars(for: clip, count: count) {
            let bars = smoothed(raw)
            let played = playedFraction(of: clip)
            Canvas { context, size in
                let amp = size.height - 3
                var shape = Path()
                shape.move(to: CGPoint(x: 0, y: size.height))
                for (i, level) in bars.enumerated() {
                    shape.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height - max(1.5, CGFloat(level) * amp)))
                }
                shape.addLine(to: CGPoint(x: CGFloat(bars.count - 1) * step, y: size.height))
                shape.closeSubpath()
                let loudLine = size.height - 0.72 * amp

                func paint(_ ctx: GraphicsContext, body: Color, cap: Color) {
                    ctx.fill(shape, with: .color(body))
                    var caps = ctx
                    caps.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: loudLine)))
                    caps.fill(shape, with: .color(cap))
                }
                paint(context, body: accent.opacity(0.55), cap: Self.loud.opacity(0.7))
                if played > 0 {
                    var trail = context
                    trail.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * played, height: size.height)))
                    paint(trail, body: accent.opacity(0.95), cap: Self.loud)
                }
            }
            .frame(width: width, height: height)
            .background(accent.opacity(0.12))
            .allowsHitTesting(false)
        } else if model.waveforms[clip.source.path] == nil {
            HStack {
                Spacer()
                ProgressView().controlSize(.mini).opacity(0.5)
                Spacer()
            }
            .frame(width: width, height: height)
        } else {
            Color.clear.frame(width: width, height: height)
        }
    }

    /// Three-tap average so the shape rolls instead of spiking.
    private func smoothed(_ bars: [Float]) -> [Float] {
        guard bars.count > 2 else { return bars }
        return bars.indices.map { i in
            let a = bars[max(0, i - 1)], b = bars[i], c = bars[min(bars.count - 1, i + 1)]
            return (a + 2 * b + c) / 4
        }
    }

    /// How much of this clip is behind the playhead, 0…1.
    private func playedFraction(of clip: EditClip) -> CGFloat {
        guard let start = model.project?.start(of: clip.id), clip.duration > 0 else { return 0 }
        return CGFloat(min(max((model.currentTime - start) / clip.duration, 0), 1))
    }

    // MARK: Control bits

    private func controlGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.4))
            // Wraps when the panel is narrow instead of pushing it wider.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66, maximum: 66), spacing: 6)], alignment: .leading, spacing: 6) {
                content()
            }
        }
    }

    private func tile(_ symbol: String, _ title: String, help: String, selected: Bool = false, destructive: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(destructive ? Color.red.opacity(0.9) : selected ? accent : .white.opacity(0.9))
            .frame(width: 66, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? accent.opacity(0.18) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Panels

    /// A tool's panel beside the rail: a card that takes the full height
    /// and scrolls inside itself. The caret in its corner folds the panel
    /// away (as clicking its rail icon does); the rail brings it back.
    private func toolCard<Content: View>(title: String, trailing: String?, movable: Bool = false,
                                         @ViewBuilder content: () -> Content) -> some View {
        card(title: title, trailing: trailing,
             accessory: { if movable { collapseCaret } },
             header: { if movable { panelDragHandle } },
             content: content)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Laid over the whole panel: drag it anywhere on the screen. It
    /// follows the mouse, then slides up level with the picture's top on
    /// whichever side of the video it was let go, keeping its left/right spot.
    private var panelDragHandle: some View {
        MouseHandle(
            cursor: .openHand,
            onDrag: { panelDrag = $0 },
            onEnd: {
                guard let drag = panelDrag else { return }
                let rest = trimRestOffset(panelWidth: trimPanelWidth)
                let landedMinX = trimSlotMinX(panelWidth: trimPanelWidth) + rest.width + drag.width
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    trimOnRight = landedMinX + trimPanelWidth / 2 > editorWidth / 2
                    trimRestMinX = landedMinX
                    panelDrag = nil
                }
            }
        )
        .help("Drag this panel anywhere beside the video")
    }

    /// The panel's left edge in its layout slot: after the rail (66) and
    /// gap (10), or against the right edge.
    private func trimSlotMinX(panelWidth: CGFloat) -> CGFloat {
        trimOnRight ? editorWidth - panelWidth : 66 + 10
    }

    /// How far the Trim panel moves from its slot to rest where it was let
    /// go — kept beside the picture, never over it or off screen — with its
    /// top on the picture's top. Zero until the video is laid out.
    private func trimRestOffset(panelWidth: CGFloat) -> CGSize {
        guard videoRect.width > 0, editorWidth > 0 else { return .zero }
        let gap: CGFloat = 10
        let slotMinX = trimSlotMinX(panelWidth: panelWidth)
        let zone: ClosedRange<CGFloat> = trimOnRight
            ? (videoRect.maxX + gap)...max(videoRect.maxX + gap, editorWidth - panelWidth)
            : min(66 + gap, videoRect.minX - gap - panelWidth)...(videoRect.minX - gap - panelWidth)
        let restMinX = min(max(trimRestMinX ?? slotMinX, zone.lowerBound), zone.upperBound)
        return CGSize(width: restMinX - slotMinX, height: max(0, videoRect.minY))
    }

    private var collapseCaret: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { panelHidden = true }
        } label: {
            Image(systemName: trimOnRight ? "chevron.right" : "chevron.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide this panel for more video — click \(activeTool.title) on the left to bring it back")
    }

    /// The takes in play order; click one to jump to it.
    private var clipsPanel: some View {
        let clips = model.project?.clips ?? []
        return toolCard(title: "CLIPS", trailing: clips.isEmpty ? nil : "\(clips.count) · \(VideoEditorModel.clock(model.duration))") {
            VStack(alignment: .leading, spacing: 10) {
                pillButton("Import clips", icon: "square.and.arrow.down") { model.chooseClips() }
                    .help("Add more takes or screen recordings — or drop files anywhere on this tab")
                if clips.isEmpty {
                    emptyRow(icon: "square.and.arrow.down", text: "Your clips will line up here in the order they'll play.")
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(Array(clips.enumerated()), id: \.element.id) { item in
                                clipRow(item.element, index: item.offset)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Divider().overlay(Color.white.opacity(0.08))
                    controlGroup("HIGHLIGHTED CLIP") {
                        tile("arrow.left", "Earlier", help: "Move the highlighted clip one place earlier") { model.moveSelectedClip(by: -1) }
                        tile("arrow.right", "Later", help: "Move the highlighted clip one place later") { model.moveSelectedClip(by: 1) }
                        tile("trash", "Remove", help: "Take the highlighted clip out of the video (the file stays on disk)", destructive: true) { removeSelectedClip() }
                    }
                    .disabled(model.selectedClip == nil || model.phase.isBusy)
                }
            }
        }
    }

    private func clipRow(_ clip: EditClip, index: Int) -> some View {
        let selected = clip.id == model.selectedClipID
        return Button { model.selectClip(clip.id) } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(selected ? accent : Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Text("\(VideoEditorModel.clock(clip.inPoint))–\(VideoEditorModel.clock(clip.outPoint)) · \(VideoEditorModel.clock(clip.duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                Spacer(minLength: 4)
                if !clip.cues.isEmpty {
                    Image(systemName: "captions.bubble.fill").font(.system(size: 10)).foregroundStyle(accent.opacity(0.9))
                }
                if clip.zoom > 1.01 {
                    Text(String(format: "%.1f×", clip.zoom))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? accent.opacity(0.18) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("\(clip.source.path)\nClick to jump to this clip")
    }

    /// The cuts and the picture zoom, with the words that explain them.
    private static func transitionHelp(_ transition: ClipTransition) -> String {
        switch transition {
        case .none: "A straight cut into the next clip"
        case .dissolve: "The next clip fades in over this one's last moments"
        case .fade: "Dip to black between this clip and the next"
        }
    }

    private static func speedIcon(_ speed: Double) -> String {
        speed < 1 ? "tortoise.fill" : speed == 1 ? "figure.walk" : "hare.fill"
    }

    private static func speedHelp(_ speed: Double) -> String {
        if speed == 1 { return "Play the highlighted clip as it was shot" }
        return speed < 1 ? "Slow motion — the clip takes longer" : "Speed the clip up — the voice keeps its pitch"
    }

    private static func speedLabel(_ speed: Double) -> String {
        String(format: speed == speed.rounded() ? "%.0f×" : "%.2g×", speed)
    }

    private var trimPanel: some View {
        let zoom = model.selectedClip?.zoom ?? 1
        let speed = model.selectedClip?.speed ?? 1
        let transition = model.selectedClip?.transition ?? .none
        return toolCard(title: "TRIM", trailing: model.selectedClip.map { "\($0.name) · \(VideoEditorModel.clock($0.duration))" }, movable: true) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Press Play and stop where you want to cut. Everything here works on the highlighted clip, at the playhead.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                    controlGroup("CUT AT THE PLAYHEAD") {
                        tile("scissors", "Split", help: "Cut the clip into two at the playhead — then remove the half you don't want") { model.splitAtPlayhead() }
                        tile("arrow.right.to.line", "Cut before", help: "Throw away everything in this clip before the playhead") { model.trimStartToPlayhead() }
                        tile("arrow.left.to.line", "Cut after", help: "Throw away everything in this clip after the playhead") { model.trimEndToPlayhead() }
                    }
                    controlGroup("SPEED  \(Self.speedLabel(speed))") {
                        ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { choice in
                            tile(Self.speedIcon(choice), Self.speedLabel(choice), help: Self.speedHelp(choice),
                                 selected: abs(speed - choice) < 0.01) { model.setSpeed(choice) }
                        }
                    }
                    controlGroup("TRANSITION TO THE NEXT CLIP") {
                        ForEach(ClipTransition.allCases, id: \.self) { choice in
                            tile(choice.icon, choice.name, help: Self.transitionHelp(choice),
                                 selected: transition == choice) { model.setTransition(choice) }
                        }
                    }
                    controlGroup("PICTURE ZOOM  \(String(format: "%.1f×", zoom))") {
                        tile("minus.magnifyingglass", "Out", help: "Zoom out (or pinch on the video)") { model.zoom(by: 1 / 1.15) }
                        tile("plus.magnifyingglass", "In", help: "Zoom in — crops from the centre (or pinch on the video)") { model.zoom(by: 1.15) }
                        tile("rectangle.arrowtriangle.2.inward", "Fill", help: "Zoom just enough that the picture fills the whole \(model.frameFormat.ratio) frame with no black bars") { model.zoomToFill() }
                        tile("rectangle.arrowtriangle.2.outward", "Fit", help: "Show the whole picture (background where the shapes differ)") { model.setZoom(1) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BACKGROUND  \(model.canvasBackground.name.uppercased())")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .kerning(1)
                            .foregroundStyle(.white.opacity(0.4))
                        HStack(spacing: 8) {
                            ForEach(CanvasBackground.allCases) { choice in
                                Button { model.setBackground(choice) } label: {
                                    Circle()
                                        .fill(Self.color(of: choice))
                                        .frame(width: 24, height: 24)
                                        .overlay(Circle().strokeBorder(choice == model.canvasBackground ? accent : Color.white.opacity(0.25),
                                                                       lineWidth: choice == model.canvasBackground ? 2.5 : 1))
                                }
                                .buttonStyle(.plain)
                                .help("\(choice.name) behind the picture — the bars beside a landscape clip, or the bands when it's zoomed out")
                            }
                        }
                        Text("Zoom Out past 1× shrinks the picture and leaves bands above and below in this colour. Posted to the feed, Instagram crops a 9:16 video to 4:5, so bands mostly get cut off.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The bars on the timeline are the sound: tall where you're talking, flat in the gaps — cut in a gap. Click anywhere on the timeline to jump there, or drag to scrub. Two halves of the same take show a Rejoin pill on their seam.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!hasClips || model.phase.isBusy)
            }
        }
    }

    /// VEED's Subtitles panel, at home in ReelFlow: pick the spoken language,
    /// optionally a translation, press the green button, then fix any
    /// words in the list.
    private var subtitlesPanel: some View {
        let count = model.project?.timelineCues.count ?? 0
        return toolCard(title: "SUBTITLES", trailing: hasCaptions ? "\(count) line\(count == 1 ? "" : "s")" : nil) {
            VStack(alignment: .leading, spacing: 12) {
                if hasClips {
                    subtitleSettings
                } else {
                    emptyRow(icon: "captions.bubble",
                             text: "Import clips first — then ReelFlow can transcribe them into subtitles.")
                }
                if let cues = model.project?.timelineCues, !cues.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    styleRow
                    Text("Click a time to jump there; click words to fix them.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.65))
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 4) {
                                ForEach(cues) { cue in cueRow(cue).id(cue.id) }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        // A line just added from the timeline: scroll to it
                        // and put the cursor in it, ready to type. The panel
                        // may have been opened by that same click, so the
                        // first appearance checks too.
                        .onChange(of: model.cueToReveal) { _, _ in revealCue(proxy) }
                        .onAppear { revealCue(proxy) }
                    }
                }
            }
        }
    }

    /// Every look on VEED's shelves, with the current one marked.
    private var stylePanel: some View {
        let preset = model.stylePreset
        return toolCard(title: "SUBTITLE STYLE", trailing: "\(preset.name) · \(preset.category.rawValue)") {
            styleShelf
        }
    }

    /// The finished video, and where the last one went.
    private var exportPanel: some View {
        toolCard(title: "EXPORT", trailing: nil) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Saves an MP4 at \(model.frameFormat.pixels) (\(model.frameFormat.name)) with the subtitles burned in, plus the .srt and a transcript, in this project's exports folder. Change the shape with the frame button under the video.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                pillButton("Export video", icon: "square.and.arrow.up", prominent: true) { model.export() }
                    .disabled(!hasClips || model.phase.isBusy)
                    .opacity(hasClips ? 1 : 0.45)
                if case .exporting(let progress) = model.phase {
                    ProgressView(value: progress).tint(accent)
                }
                if !hasCaptions && hasClips {
                    emptyRow(icon: "captions.bubble",
                             text: "No subtitles yet — you can export without them, or press Auto-subtitle first.")
                }
                if let url = model.lastExport {
                    Divider().overlay(Color.white.opacity(0.08))
                    sectionLabel("LAST EXPORT")
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        pillButton("Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        pillButton("Open", icon: "play.rectangle") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    // MARK: Music

    private var musicPanel: some View {
        let music = model.project?.music
        let clipVolume = model.project?.clipVolume ?? 1
        return toolCard(title: "MUSIC", trailing: music?.name) {
            VStack(alignment: .leading, spacing: 12) {
                if let music {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(music.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text(VideoEditorModel.clock(music.duration))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer(minLength: 4)
                        pillButton("Change", icon: "arrow.triangle.2.circlepath") { model.chooseMusic() }
                    }
                    sliderRow("MUSIC VOLUME", value: music.volume, in: 0...1, label: Self.percent) { model.setMusicVolume($0) }
                    sliderRow("CLIP SOUND", value: clipVolume, in: 0...1, label: Self.percent) { model.setClipVolume($0) }
                    sliderRow("FADE IN", value: music.fadeIn, in: 0...8, label: Self.seconds) { model.setMusicFade(in: $0) }
                    sliderRow("FADE OUT", value: music.fadeOut, in: 0...8, label: Self.seconds) { model.setMusicFade(out: $0) }
                    HStack(spacing: 10) {
                        TimingField(label: "Start in song", value: music.startAt, accent: accent) { model.setMusicStart($0) }
                        Toggle("Repeat", isOn: Binding(get: { music.loop }, set: { model.setMusicLoop($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(accent)
                            .font(.system(size: 11, design: .monospaced))
                            .help("Play the song again when it ends before the video does")
                    }
                    Text("The song plays under every clip, fading in at the start and out at the end. Turn the clip sound down to keep the voice on top.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                    pillButton("Remove music", icon: "trash") { model.removeMusic() }
                } else {
                    Text("Add a song under the whole video — a track you own or have a licence for. Its volume, fades and where it starts are set here.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                    pillButton("Add music", icon: "music.note.list", prominent: true) { model.chooseMusic() }
                        .disabled(!hasClips)
                        .opacity(hasClips ? 1 : 0.45)
                    sliderRow("CLIP SOUND", value: clipVolume, in: 0...1, label: Self.percent) { model.setClipVolume($0) }
                }
            }
            .disabled(model.phase.isBusy)
        }
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    /// A labelled slider that shows its value; every move goes straight
    /// to the model.
    private func sliderRow(_ title: String, value: Double, in range: ClosedRange<Double>,
                           label: @escaping (Double) -> String, commit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(1)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text(label(value))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }
            Slider(value: Binding(get: { value }, set: commit), in: range)
                .tint(accent)
                .controlSize(.small)
        }
    }

    // MARK: Titles and pictures

    private var textPanel: some View {
        let titles = model.project?.overlays.filter { $0.kind == .text } ?? []
        return toolCard(title: "TEXT", trailing: titles.isEmpty ? nil : "\(titles.count) title\(titles.count == 1 ? "" : "s")") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    pillButton("Add title", icon: "plus", prominent: true) { model.addTitle() }
                        .help("One title, at the top of the video, in the subtitle style")
                    pillButton("Add banner", icon: "rectangle.split.3x1") { model.addBanner() }
                        .help("Promo layout: the picture fills the frame, with a show title over the top and the name and date over the bottom, clear of Instagram's crop and caption")
                }
                .disabled(!hasClips)
                .opacity(hasClips ? 1 : 0.45)
                if titles.isEmpty {
                    emptyRow(icon: "textbox", text: "A hook at the top of the video, a name, a punchline. Add one, type over it, then drag it anywhere on the video.")
                } else {
                    Text("Click a title to edit it; drag it on the video to move it.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.65))
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(titles) { overlayRow($0) }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var picturePanel: some View {
        let pictures = model.project?.overlays.filter { $0.kind == .image } ?? []
        return toolCard(title: "PICTURE", trailing: pictures.isEmpty ? nil : "\(pictures.count)") {
            VStack(alignment: .leading, spacing: 12) {
                pillButton("Add picture", icon: "photo.badge.plus", prominent: true) { model.choosePicture() }
                    .disabled(!hasClips)
                    .opacity(hasClips ? 1 : 0.45)
                if pictures.isEmpty {
                    emptyRow(icon: "photo", text: "A logo in the corner, your handle, a sticker. PNGs with a see-through background work best. Drag it anywhere on the video.")
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(pictures) { overlayRow($0) }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    /// One title or picture in its panel: its name (a title is typed right
    /// here), and when it's the chosen one, its size, opacity and timing.
    private func overlayRow(_ overlay: Overlay) -> some View {
        let selected = overlay.id == model.selectedOverlayID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: overlay.kind == .text ? "textbox" : "photo")
                    .foregroundStyle(selected ? accent : .white.opacity(0.6))
                if overlay.kind == .text {
                    TextField("Title", text: Binding(get: { overlay.text },
                                                     set: { text in model.updateOverlay(overlay.id) { $0.text = text } }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.95))
                        .onTapGesture { model.selectedOverlayID = overlay.id }
                } else {
                    Text(overlay.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(VideoEditorModel.clock(overlay.start))–\(overlay.end.map(VideoEditorModel.clock) ?? "end")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Button { model.removeOverlay(overlay.id) } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.red.opacity(0.85))
                .help("Take this off the video")
            }
            if selected {
                if overlay.kind == .text {
                    overlayStyleMenu(overlay)
                    sliderRow("SIZE", value: overlay.scale, in: 0.3...3, label: { String(format: "%.1f×", $0) }) { v in
                        model.updateOverlay(overlay.id) { $0.scale = v }
                    }
                } else {
                    sliderRow("SIZE", value: overlay.width, in: 0.04...1, label: Self.percent) { v in
                        model.updateOverlay(overlay.id) { $0.width = v }
                    }
                }
                sliderRow("OPACITY", value: overlay.opacity, in: 0.05...1, label: Self.percent) { v in
                    model.updateOverlay(overlay.id) { $0.opacity = v }
                }
                overlayTiming(overlay)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? accent.opacity(0.14) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? accent.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedOverlayID = overlay.id
            if !overlay.isShowing(at: model.currentTime, duration: model.duration) { model.seek(to: overlay.start + 0.05) }
        }
    }

    /// The look of a title: any of the subtitle styles.
    private func overlayStyleMenu(_ overlay: Overlay) -> some View {
        Menu {
            ForEach(SubtitleStylePreset.Category.allCases) { category in
                Section(category.rawValue) {
                    ForEach(category.presets) { preset in
                        Button {
                            model.updateOverlay(overlay.id) { $0.style = preset.rawValue }
                        } label: {
                            if preset == overlay.stylePreset { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "textformat").font(.system(size: 11, weight: .semibold))
                Text("Style: \(overlay.stylePreset.name)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// When a title or picture is on screen: from a time to a time, or the
    /// whole video.
    private func overlayTiming(_ overlay: Overlay) -> some View {
        let whole = overlay.start <= 0.001 && overlay.end == nil
        return HStack(spacing: 6) {
            TimingField(label: "From", value: overlay.start, accent: accent) { v in
                model.updateOverlay(overlay.id) { $0.start = v }
            }
            TimingField(label: "To", value: overlay.end ?? model.duration, accent: accent) { v in
                let duration = model.duration
                model.updateOverlay(overlay.id) { $0.end = v >= duration - 0.05 ? nil : v }
            }
            Spacer(minLength: 0)
            if !whole {
                pillButton("Whole video", icon: "arrow.left.and.right") {
                    model.updateOverlay(overlay.id) { $0.start = 0; $0.end = nil }
                }
            }
        }
    }

    // MARK: Subtitle styles

    /// The current look, with a way in to VEED's style shelf.
    private var styleRow: some View {
        let preset = model.stylePreset
        return HStack(spacing: 10) {
            styleTile(preset, selected: false, compact: true)
                .frame(width: 92, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Subtitle style")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(preset.name) · \(preset.category.rawValue)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button("Change") { open(.style) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(accent.opacity(0.14)))
                .help("Pick a different look for every subtitle")
        }
    }

    /// Every preset, on VEED's shelves. Click one and the video, the export
    /// and the list all switch at once.
    private var styleShelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SubtitleStylePreset.Category.allCases) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.rawValue)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(category.presets) { preset in
                                Button { model.setSubtitleStyle(preset) } label: {
                                    styleTile(preset, selected: preset == model.stylePreset, compact: false)
                                        .aspectRatio(1.75, contentMode: .fit)
                                }
                                .buttonStyle(.plain)
                                .help(preset.name)
                            }
                        }
                    }
                }
                Text("Styles that colour a word follow your voice, word by word.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: .infinity)
    }

    private func styleTile(_ preset: SubtitleStylePreset, selected: Bool, compact: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .fill(Color.gray)
            CaptionLayerView(text: SubtitleStylePreset.sampleText, highlight: preset.sampleHighlight,
                             style: preset.style, placement: .fitted)
                .allowsHitTesting(false)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, accent)
                    .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .strokeBorder(selected ? accent : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var subtitleSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What language is being spoken?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            spokenLanguagePicker

            HStack(spacing: 10) {
                Text("Add translation")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if model.translationEnabled {
                    translationLanguagePicker
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.translationEnabled },
                    set: { model.setTranslationEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accent)
                .help("Put a second, translated line under every subtitle")
            }
            .frame(minHeight: 28)

            if case .transcribing(let listening) = model.phase {
                listeningPanel(listening)
            } else {
                autoSubtitleButton
            }
        }
    }

    /// What replaces the green button while ReelFlow listens: how far it is,
    /// the words as they arrive, and a way to stop.
    private func listeningPanel(_ l: VideoEditorModel.Listening) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(accent)
                Text(l.count > 1 ? "Listening to \(l.clipName) — take \(l.index) of \(l.count)" : "Listening to \(l.clipName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer()
                Text("\(VideoEditorModel.clock(l.secondsHeard)) / \(VideoEditorModel.clock(l.duration))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                Text("\(Int(l.fraction * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, alignment: .trailing)
            }
            ProgressView(value: l.fraction)
                .tint(accent)
                .frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 2)
                Text(l.latestText.isEmpty ? "Warming up — the first words take a few seconds…" : "…\(l.latestText)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(l.latestText.isEmpty ? .white.opacity(0.45) : .white.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.15), value: l.latestText)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            HStack(spacing: 10) {
                Text("ReelFlow is turning the speech into text on this Mac — nothing is uploaded. It runs about as fast as the clip plays; you can keep trimming meanwhile.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                pillButton("Stop", icon: "stop.fill") { model.stopSubtitling() }
                    .help("Stop listening. What's been heard so far is kept, so you can carry on later.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.opacity(0.35), lineWidth: 1))
    }

    private var spokenLanguagePicker: some View {
        let locale = model.spokenLocale
        return HStack(spacing: 10) {
            Text(SubtitleLanguages.regionChip(of: locale))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12)))
            Text(SubtitleLanguages.name(of: locale))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Text(SubtitleLanguages.fullName(of: locale))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer()
            Text("Change")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .overlay(invisibleMenu {
            ForEach(VideoTranscriber.supportedLocales, id: \.identifier) { option in
                Button {
                    model.setSpokenLanguage(option.identifier)
                } label: {
                    HStack {
                        Text("\(SubtitleLanguages.name(of: option)) — \(SubtitleLanguages.fullName(of: option))")
                        if option.identifier == locale.identifier { Image(systemName: "checkmark") }
                    }
                }
            }
        })
        .help("The language ReelFlow listens for when it transcribes — click to change")
    }

    private var translationLanguagePicker: some View {
        let current = model.translationLanguage ?? ""
        return HStack(spacing: 5) {
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
            Text(SubtitleLanguages.name(ofLanguage: current))
                .font(.system(size: 12, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(accent.opacity(0.14)))
        .overlay(invisibleMenu {
            ForEach(SubtitleLanguages.translationTargets, id: \.self) { code in
                Button {
                    model.setTranslationLanguage(code)
                } label: {
                    HStack {
                        Text(SubtitleLanguages.name(ofLanguage: code))
                        if code == current { Image(systemName: "checkmark") }
                    }
                }
            }
        })
        .help("The language to translate every subtitle into — click to change")
    }

    /// A menu that fills whatever it's laid over and draws nothing itself.
    /// macOS collapses a `Menu`'s custom label to its first piece of text,
    /// so the visible row is drawn separately and this catches the click.
    private func invisibleMenu<Items: View>(@ViewBuilder items: () -> Items) -> some View {
        Menu(content: items) { Color.clear.contentShape(Rectangle()) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(model.phase.isBusy)
    }

    /// The big action, "Auto-subtitle in English": a pill the size of the
    /// header's Import and Export buttons, not a full-width bar, in the
    /// same system yellow as the Subtitles tool on the rail.
    private var autoSubtitleButton: some View {
        let language = SubtitleLanguages.name(of: model.spokenLocale)
        let title = hasCaptions ? "Re-subtitle in \(language)" : "Auto-subtitle in \(language)"
        return Button { model.generateCaptions() } label: {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.yellow))
        }
        .buttonStyle(.plain)
        .disabled(model.phase.isBusy)
        .opacity(model.phase.isBusy ? 0.5 : 1)
        .help(hasCaptions
              ? "Listen again to any take that hasn't been heard in \(language) and rewrite the subtitles"
              : "Listen to every take and write word-timed subtitles in \(language)")
    }

    /// Hosts Apple's on-device translator. It has to live in a view, so the
    /// model asks for a pass by bumping `translationJob` and this runs it.
    @ViewBuilder private var translationRunner: some View {
        if #available(macOS 15, *) {
            SubtitleTranslationRunner(model: model)
        }
    }

    /// Which lines have their start and end fields open.
    @State private var timingRows: Set<UUID> = []
    /// The line whose text field has the cursor.
    @FocusState private var focusedCue: UUID?

    private func revealCue(_ proxy: ScrollViewProxy) {
        guard let id = model.cueToReveal else { return }
        model.cueToReveal = nil
        // Let the row land in the list before asking for it.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            focusedCue = id
        }
    }

    private func cueRow(_ cue: TimelineCue) -> some View {
        let live = model.currentTime >= cue.start && model.currentTime < cue.end
        let showTimings = timingRows.contains(cue.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                Button { model.seek(to: cue.start) } label: {
                    Text(VideoEditorModel.clock(cue.start))
                        .font(.system(size: 11, weight: live ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(live ? accent : .white.opacity(0.5))
                        .frame(width: 58, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Jump to this moment")
                VStack(alignment: .leading, spacing: 2) {
                    TextField(cue.text.isEmpty ? "Type the subtitle…" : "", text: Binding(
                        get: { cue.text },
                        set: { model.setCueText(cue.id, $0) }
                    ))
                    .textFieldStyle(.plain)
                    .focused($focusedCue, equals: cue.id)
                    .font(.system(size: 13, weight: live ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    if model.translationEnabled {
                        TextField(cue.translation == nil ? "translating…" : "", text: Binding(
                            get: { cue.translation ?? "" },
                            set: { model.setCueTranslation(cue.id, $0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.85))
                        .disabled(cue.translation == nil)
                    }
                }
                if cue.anchor != nil {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(accent.opacity(0.85))
                        .help("Detached: this line has its own spot on the video")
                }
                cueMenu(cue, showTimings: showTimings)
            }
            if showTimings {
                timingFields(cue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(live ? accent.opacity(0.18) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(live ? accent.opacity(0.6) : .clear, lineWidth: 1)
        )
    }

    /// VEED's three dots on a line: Detach (or Reattach), Delete, Show timings.
    private func cueMenu(_ cue: TimelineCue, showTimings: Bool) -> some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .bold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .overlay(invisibleMenu {
                if cue.anchor == nil {
                    Button { model.detachCue(cue) } label: {
                        Label("Detach", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    }
                } else {
                    Button { model.setCueAnchor(cue.id, nil) } label: { Label("Reattach", systemImage: "link") }
                }
                Button(role: .destructive) { model.removeCue(cue.id) } label: { Label("Delete", systemImage: "trash") }
                Button {
                    if showTimings { timingRows.remove(cue.id) } else { timingRows.insert(cue.id) }
                } label: {
                    Label(showTimings ? "Hide timings" : "Show timings", systemImage: "stopwatch")
                }
            })
            .help("Detach this line so it can sit somewhere of its own, delete it, or show its timings")
    }

    /// Start and end under a line, typed as 1:02.50 or plain seconds.
    private func timingFields(_ cue: TimelineCue) -> some View {
        HStack(spacing: 6) {
            TimingField(label: "Start", value: cue.start, accent: accent) { model.setCueTiming(cue.id, start: $0, end: cue.end) }
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
            TimingField(label: "End", value: cue.end, accent: accent) { model.setCueTiming(cue.id, start: cue.start, end: $0) }
            Text(String(format: "%.2f s", cue.end - cue.start))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
        }
        .padding(.leading, 68)
    }

    // MARK: - Bits

    private func card<Content: View>(title: String?, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        card(title: title, trailing: trailing, accessory: { EmptyView() }, header: { EmptyView() }, content: content)
    }

    /// `accessory` sits at the far right of the header, after `trailing`;
    /// `header` is laid over the header's text (a grab area), under
    /// `accessory`, and again behind the whole card so any empty spot in
    /// the panel — padding, gaps between controls — grabs too.
    private func card<Accessory: View, Header: View, Content: View>(title: String?, trailing: String?,
                                                                    @ViewBuilder accessory: () -> Accessory,
                                                                    @ViewBuilder header: () -> Header,
                                                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        sectionLabel(title)
                        Spacer()
                        if let trailing {
                            Text(trailing)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                    .overlay(header())
                    accessory()
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.035))
                header()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .kerning(1.2)
            .foregroundStyle(.white.opacity(0.45))
    }

    private func emptyRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.white.opacity(0.35))
            Text(text)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pillButton(_ title: String, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? accent.opacity(0.28) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(prominent ? accent.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.92))
    }
}

/// One editable time under a subtitle line. Commits on Return or when
/// focus leaves; anything that isn't a time snaps back.
private struct TimingField: View {
    let label: String
    let value: Double
    let accent: Color
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .frame(width: 60)
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { _, now in if !now { apply() } }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
        .onAppear { text = VideoEditorModel.clock(value) }
        .onChange(of: value) { _, now in text = VideoEditorModel.clock(now) }
        .help("Type a time like 1:02.50 and press Return")
    }

    private func apply() {
        if let seconds = VideoEditorModel.seconds(from: text) {
            commit(seconds)
            text = VideoEditorModel.clock(seconds)
        } else {
            text = VideoEditorModel.clock(value)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// The mouse side of a grab area on the preview — the subtitle, or the
/// picture itself. AppKit asks the view under the mouse whether a drag
/// should move the window (the panel says yes for its background), so
/// this view says no and tracks the drag itself, reporting in window
/// points so its own movement mid-drag doesn't matter.
private struct MouseHandle: NSViewRepresentable {
    /// Shown over the area, or nil for the plain arrow.
    var cursor: NSCursor? = nil
    var onHover: ((Bool) -> Void)? = nil
    /// A click that didn't turn into a drag.
    var onTap: (() -> Void)? = nil
    /// How far the mouse has moved since it went down, in view points
    /// (y grows downwards, as in SwiftUI).
    var onDrag: (CGSize) -> Void
    var onEnd: () -> Void
    /// A double-click.
    var onReset: (() -> Void)? = nil
    /// A trackpad pinch, as the factor to multiply the zoom by.
    var onMagnify: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> Handle {
        let handle = Handle()
        update(handle)
        return handle
    }

    func updateNSView(_ handle: Handle, context: Context) { update(handle) }

    private func update(_ handle: Handle) {
        handle.cursor = cursor
        handle.onHover = onHover
        handle.onTap = onTap
        handle.onDrag = onDrag
        handle.onEnd = onEnd
        handle.onReset = onReset
        handle.onMagnify = onMagnify
    }

    final class Handle: NSView {
        var cursor: NSCursor? {
            didSet { if cursor !== oldValue { window?.invalidateCursorRects(for: self) } }
        }
        var onHover: ((Bool) -> Void)?
        var onTap: (() -> Void)?
        var onDrag: ((CGSize) -> Void)?
        var onEnd: (() -> Void)?
        var onReset: (() -> Void)?
        var onMagnify: ((CGFloat) -> Void)?
        private var origin: NSPoint?
        private var moved = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // AppKit owns the cursor rectangle, so an area that vanishes under
        // the mouse (a subtitle whose line ends) can't leave a hand behind.
        override func resetCursorRects() {
            if let cursor { addCursorRect(visibleRect, cursor: cursor) }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                origin = nil
                onReset?()
                return
            }
            origin = event.locationInWindow
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let now = event.locationInWindow
            // Window coordinates grow upwards; the preview's grow downwards.
            let delta = CGSize(width: now.x - origin.x, height: origin.y - now.y)
            // A twitch during a click isn't a drag.
            if !moved, abs(delta.width) < 2, abs(delta.height) < 2 { return }
            moved = true
            onDrag?(delta)
        }

        override func mouseUp(with event: NSEvent) {
            if moved { onEnd?() } else if origin != nil { onTap?() }
            origin = nil
            moved = false
        }

        override func magnify(with event: NSEvent) {
            onMagnify?(1 + event.magnification)
        }
    }
}

/// The preview player without AVKit's own controls; the transport is ours.
/// The clip under the playhead's zoom is a scale on the player's layer:
/// a zoom on the same clip glides there, a cut to another clip is a hard
/// switch, and the player itself is never rebuilt for either.
private struct VideoEditorSurface: NSViewRepresentable {
    let player: AVPlayer
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var clipID: UUID? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var clipID: UUID?
    }

    func makeNSView(context: Context) -> ZoomingPlayerView {
        let view = ZoomingPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.set(zoom: zoom, pan: pan, animated: false)
        context.coordinator.clipID = clipID
        return view
    }

    func updateNSView(_ view: ZoomingPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        let sameClip = context.coordinator.clipID == clipID
        context.coordinator.clipID = clipID
        view.set(zoom: zoom, pan: pan, animated: sameClip)
    }
}

/// An AVPlayerView that scales its picture about the centre and shifts it
/// by the pan — the same crop the export makes. A zoom glides; a pan
/// (the user's own drag) follows the mouse as it is.
private final class ZoomingPlayerView: AVPlayerView {
    private var zoom: CGFloat = 1
    private var pan: CGSize = .zero

    func set(zoom target: CGFloat, pan newPan: CGSize, animated: Bool) {
        let clamped = max(0.1, target)
        let zoomChanged = abs(clamped - zoom) > 0.0005
        let panChanged = abs(newPan.width - pan.width) > 0.00005 || abs(newPan.height - pan.height) > 0.00005
        guard zoomChanged || panChanged else { return }
        zoom = clamped
        pan = newPan
        guard let layer else { return }
        let to = transform(for: zoom)
        // Start from wherever the picture is *now*, so a second click
        // mid-glide carries on rather than snapping.
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to
        if animated && zoomChanged {
            let glide = CABasicAnimation(keyPath: "transform")
            glide.fromValue = from
            glide.toValue = to
            glide.duration = 0.32
            glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            layer.add(glide, forKey: "zoom")
        } else {
            layer.removeAnimation(forKey: "zoom")
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // The centre moved with the size; re-aim the scale at it, silently.
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform(for: zoom)
        CATransaction.commit()
    }

    private func transform(for zoom: CGFloat) -> CATransform3D {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // The pan is "right and down"; this layer's y may grow upwards.
        let down: CGFloat = isFlipped ? 1 : -1
        var t = CATransform3DMakeTranslation(centre.x + pan.width * bounds.width,
                                             centre.y + down * pan.height * bounds.height, 0)
        t = CATransform3DScale(t, zoom, zoom, 1)
        return CATransform3DTranslate(t, -centre.x, -centre.y, 0)
    }
}

/// VEED's frame picker: a search box over every social-media preset, the
/// current one ticked, and the export size on the footer. Choosing a row
/// reframes the whole video.
private struct FrameFormatPicker: View {
    let selected: FrameFormat
    let choose: (FrameFormat) -> Void
    @State private var query = ""
    @State private var hovered: FrameFormat.ID?
    @FocusState private var searching: Bool

    private var shown: [FrameFormat] { FrameFormat.matching(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { if let first = shown.first { choose(first) } }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if shown.isEmpty {
                            Text("No preset matches “\(query)”")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                        ForEach(shown) { format in row(format) }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
                .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                Text("Resize for social media · exports at \(selected.pixels)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: 40)
        }
        .frame(width: 320)
        .onAppear { searching = true }
    }

    private func row(_ format: FrameFormat) -> some View {
        let current = format.id == selected.id
        let lit = current || hovered == format.id
        return Button { choose(format) } label: {
            HStack(spacing: 10) {
                brandTile(format)
                Text(format.platform).font(.system(size: 13, weight: .medium))
                Text(format.ratio).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if current {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(lit ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(format.id)
        .onHover { hovered = $0 ? format.id : (hovered == format.id ? nil : hovered) }
        .help("Reframe the video for \(format.name) — \(format.pixels)")
    }

    /// The platform's mark: its symbol in white on a tile of its colour.
    private func brandTile(_ format: FrameFormat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Self.fill(for: format.brand))
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: format.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(format.brand == .snapchat ? Color.black : Color.white)
            )
    }

    private static func fill(for brand: FrameFormat.Brand) -> AnyShapeStyle {
        switch brand {
        case .instagram:
            AnyShapeStyle(LinearGradient(colors: [Color(red: 0.99, green: 0.73, blue: 0.27),
                                                  Color(red: 0.87, green: 0.18, blue: 0.44),
                                                  Color(red: 0.51, green: 0.23, blue: 0.71)],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
        case .tiktok: AnyShapeStyle(Color(red: 0.06, green: 0.06, blue: 0.06))
        case .youtube: AnyShapeStyle(Color(red: 1.0, green: 0.0, blue: 0.0))
        case .linkedin: AnyShapeStyle(Color(red: 0.04, green: 0.40, blue: 0.71))
        case .x: AnyShapeStyle(Color.black)
        case .facebook: AnyShapeStyle(Color(red: 0.09, green: 0.47, blue: 0.95))
        case .pinterest: AnyShapeStyle(Color(red: 0.90, green: 0.0, blue: 0.14))
        case .snapchat: AnyShapeStyle(Color(red: 1.0, green: 0.99, blue: 0.0))
        }
    }
}
