import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

/// The ReelFlow editor: one open project, its preview player, and the
/// long-running jobs (captioning, export). The panel owns one of these for
/// as long as it lives, so switching tabs doesn't lose the edit.
@MainActor
final class VideoEditorModel: ObservableObject {
    /// Where an Auto-subtitle pass has got to, for the panel to show.
    struct Listening: Equatable {
        var clipName: String
        var index: Int
        var count: Int
        /// Seconds of this take heard so far, and its length.
        var secondsHeard: Double = 0
        var duration: Double
        /// The last few words, so the user can see it working.
        var latestText: String = ""
        var fraction: Double { duration > 0 ? min(1, secondsHeard / duration) : 0 }
    }

    enum Phase: Equatable {
        case idle
        case importing(Int, Int)
        case transcribing(Listening)
        case translating(Int)
        /// Auto-subtitle finished: this many lines are ready.
        case subtitled(Int)
        case exporting(Double)
        case exported(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .importing, .transcribing, .translating, .exporting: true
            default: false
            }
        }
    }

    /// Where projects live: one folder each, alongside the user's other
    /// videos rather than hidden in Application Support — they'll want to
    /// hand the exports to CapCut or a portfolio site.
    static let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/ReelFlow Projects", isDirectory: true)

    @Published private(set) var project: VideoProject? { didSet { publishRemoteState() } }
    @Published private(set) var projectFolder: URL?
    @Published private(set) var recentProjects: [URL] = []
    @Published var selectedClipID: UUID? { didSet { publishRemoteState() } }
    @Published private(set) var phase: Phase = .idle { didSet { publishRemoteState() } }
    @Published private(set) var currentTime: Double = 0 {
        didSet {
            // Thirty updates a second while playing; the phone only needs a
            // few to keep its timecode moving.
            let tick = Int(currentTime * 5)
            if tick != lastPublishedTick { lastPublishedTick = tick; publishRemoteState() }
        }
    }
    @Published private(set) var isPlaying = false { didSet { if isPlaying != oldValue { publishRemoteState() } } }
    /// The last thing worth telling the user, under the toolbar.
    @Published private(set) var note: String? { didSet { if note != oldValue { noteAction = nil } } }
    /// A button beside the note — "Undo" after a removal.
    @Published private(set) var noteAction: NoteAction?
    struct NoteAction {
        let title: String
        let run: () -> Void
    }

    /// Earlier states of the project, newest last, for ⌘Z. Slider moves
    /// (volume, opacity) aren't recorded; cuts, removals, subtitles are.
    private var undoStack: [VideoProject] = []
    private static let undoLimit = 60
    var canUndo: Bool { !undoStack.isEmpty }
    /// The most recent finished export this session, so the step tracker
    /// can show Export as done.
    @Published private(set) var lastExport: URL?
    /// Bumped each time the Subtitles panel should run a translation pass;
    /// the view owns the `TranslationSession`, so it watches this.
    @Published private(set) var translationJob = 0
    /// How subtitles look, from the project's chosen preset.
    var style: CaptionStyle { stylePreset.style }
    var stylePreset: SubtitleStylePreset { project?.stylePreset ?? .default }

    /// A protocol line for the Peeky Remote phone app (VIDEO_STATE).
    var onRemoteLine: ((String) -> Void)?
    private var lastPublishedTick = -1

    let player = AVPlayer()
    /// What the player is showing, kept so a volume change can remix the
    /// sound without rebuilding the whole preview.
    private var previewTimeline: VideoExporter.Timeline?
    /// The title or picture the user is working on, outlined in the preview.
    @Published var selectedOverlayID: UUID?
    private var overlayImages: [String: NSImage] = [:]
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// Watches the current player item so a composition the player can't
    /// play says so in the note instead of sitting black.
    private var itemStatusObserver: NSKeyValueObservation?
    private var previewGeneration = 0

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
                self.isPlaying = self.player.rate != 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        refreshRecentProjects()
    }

    var hasProject: Bool { project != nil }
    var duration: Double { project?.duration ?? 0 }
    var currentCue: TimelineCue? { project?.cue(at: currentTime) }
    var selectedClip: EditClip? {
        guard let selectedClipID else { return nil }
        return project?.clips.first { $0.id == selectedClipID }
    }
    var exportsFolder: URL? { projectFolder?.appendingPathComponent("exports", isDirectory: true) }
    /// The titles and pictures on screen at the playhead.
    var overlaysNow: [Overlay] { project?.overlays(at: currentTime) ?? [] }
    var selectedOverlay: Overlay? {
        guard let selectedOverlayID else { return nil }
        return project?.overlays.first { $0.id == selectedOverlayID }
    }

    // MARK: Projects

    func refreshRecentProjects() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Self.projectsRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        recentProjects = folders
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(VideoProject.fileName).path) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        // How many clips each has, so the list can say which are empty.
        var counts: [URL: Int] = [:]
        for folder in recentProjects {
            counts[folder] = (try? VideoProject.load(from: folder))?.clips.count ?? 0
        }
        recentProjectClipCounts = counts
    }

    /// Clips per recent project folder; an empty project can't be opened
    /// from the list — there's nothing in it to edit.
    @Published private(set) var recentProjectClipCounts: [URL: Int] = [:]

    /// A folder name that's safe on disk and unique under the projects root.
    static func folderName(for name: String, existing: (String) -> Bool) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        if base.isEmpty { base = "Untitled" }
        var candidate = base
        var n = 2
        while existing(candidate) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    func newProject(named name: String) {
        let fm = FileManager.default
        let folderName = Self.folderName(for: name) { fm.fileExists(atPath: Self.projectsRoot.appendingPathComponent($0).path) }
        let folder = Self.projectsRoot.appendingPathComponent(folderName, isDirectory: true)
        let project = VideoProject(name: folderName)
        do {
            try project.save(to: folder)
        } catch {
            phase = .failed("Couldn't create the project folder: \(error.localizedDescription)")
            return
        }
        load(project, from: folder)
        note = "New project — import your takes, or drop them here."
    }

    func open(folder: URL) {
        do {
            let project = try VideoProject.load(from: folder)
            load(project, from: folder)
            let missing = project.clips.filter { !FileManager.default.fileExists(atPath: $0.source.path) }
            note = missing.isEmpty ? nil : "\(missing.count) clip\(missing.count == 1 ? "" : "s") can't be found on disk."
        } catch {
            phase = .failed("Couldn't open that project: \(error.localizedDescription)")
        }
    }

    func closeProject() {
        player.replaceCurrentItem(with: nil)
        project = nil
        projectFolder = nil
        selectedClipID = nil
        selectedOverlayID = nil
        previewTimeline = nil
        overlayImages = [:]
        undoStack = []
        currentTime = 0
        phase = .idle
        note = nil
        waveforms = [:]
        refreshRecentProjects()
    }

    private func load(_ project: VideoProject, from folder: URL) {
        self.project = project
        projectFolder = folder
        selectedClipID = project.clips.first?.id
        selectedOverlayID = nil
        overlayImages = [:]
        undoStack = []
        phase = .idle
        currentTime = 0
        lastExport = nil
        waveforms = [:]
        refreshRecentProjects()
        rebuildPreview(seekTo: 0)
        loadWaveforms()
        loadFilmstrips()
    }

    /// What typing in the panel's input does here: name a new project.
    func submit(_ text: String) {
        if project == nil { newProject(named: text) }
    }

    private func save() {
        guard let project, let projectFolder else { return }
        do { try project.save(to: projectFolder) } catch {
            note = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Change the project, save it, and refresh the preview at `seek`
    /// (or where the playhead is).
    private func edit(seekTo requested: Double? = nil, rebuild: Bool = true, undoable: Bool = true,
                      _ change: (inout VideoProject) -> Void) {
        guard var p = project else { return }
        let before = p
        change(&p)
        guard p != before else { return }
        if undoable {
            undoStack.append(before)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        }
        project = p
        save()
        if rebuild { rebuildPreview(seekTo: requested) }
    }

    /// Put the project back the way it was before the last edit.
    func undo() {
        guard let previous = undoStack.popLast(), project != nil else { return }
        project = previous
        save()
        selectedClipID = previous.clips.first { $0.id == selectedClipID }?.id ?? previous.clips.first?.id
        if let selectedOverlayID, !previous.overlays.contains(where: { $0.id == selectedOverlayID }) { self.selectedOverlayID = nil }
        note = "Undone."
        rebuildPreview(seekTo: nil)
    }

    // MARK: Clips

    static let importableTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video, .audiovisualContent]

    /// The Import button and drop zone: a native picker for the takes.
    func chooseClips() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.importableTypes
        panel.message = "Choose the takes and screen recordings for this video"
        panel.prompt = "Import"
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.importClips(panel.urls)
        }
    }

    /// Files dropped on the window, sorted by what they are: videos join
    /// the timeline (starting a project if there isn't one), a song goes
    /// under the video, pictures go over it.
    func drop(_ urls: [URL]) {
        var videos: [URL] = []
        var songs: [URL] = []
        var pictures: [URL] = []
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension) else { continue }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                videos.append(url)
            } else if type.conforms(to: .audio) {
                songs.append(url)
            } else if type.conforms(to: .image) {
                pictures.append(url)
            }
        }
        if !videos.isEmpty { importClips(videos) }
        if project == nil, videos.isEmpty {
            note = "Drop a video first — then a song or a picture can go with it."
            return
        }
        if let song = songs.first { addMusic(song) }
        for picture in pictures { addPicture(picture) }
    }

    func importClips(_ urls: [URL]) {
        let videos = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .audiovisualContent)
        }
        guard !videos.isEmpty else {
            note = "Those aren't video files."
            return
        }
        if project == nil {
            // Dropping clips onto the start screen starts a project named
            // after the first take, so nothing has to be typed first.
            newProject(named: videos[0].deletingPathExtension().lastPathComponent)
            guard project != nil else { return }
        }
        Task { await importVideos(videos) }
    }

    private func importVideos(_ urls: [URL]) async {
        var added = 0
        var skipped: [String] = []
        for (index, url) in urls.enumerated() {
            phase = .importing(index + 1, urls.count)
            let asset = AVURLAsset(url: url)
            // The clip is as long as its picture. The file's own duration
            // can run a little past the last frame when the sound does.
            guard let video = try? await asset.loadTracks(withMediaType: .video).first,
                  let seconds = try? await video.load(.timeRange).duration.seconds, seconds > 0 else {
                skipped.append(url.lastPathComponent)
                continue
            }
            let clip = EditClip(source: url, sourceDuration: seconds)
            guard var p = project else { return }
            p.append(clip)
            project = p
            selectedClipID = clip.id
            added += 1
        }
        save()
        phase = .idle
        note = skipped.isEmpty
            ? "Added \(added) clip\(added == 1 ? "" : "s")."
            : "Added \(added); couldn't read \(skipped.joined(separator: ", "))."
        rebuildPreview(seekTo: nil)
        loadWaveforms()
        loadFilmstrips()
    }

    // MARK: Waveforms

    /// Loudness peaks per source path, drawn inside the timeline clips.
    /// Read once per file and cached beside the project as
    /// `waveforms.json` so reopening is instant.
    @Published private(set) var waveforms: [String: [Float]] = [:]
    private var waveformTasks: Set<String> = []
    private static let waveformsFile = "waveforms.json"

    private func loadWaveforms() {
        guard let project, let projectFolder else { return }
        if waveforms.isEmpty,
           let data = try? Data(contentsOf: projectFolder.appendingPathComponent(Self.waveformsFile)),
           let cached = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            waveforms = cached
        }
        for url in project.clips.map(\.source) {
            let key = url.path
            guard waveforms[key] == nil, !waveformTasks.contains(key) else { continue }
            waveformTasks.insert(key)
            Task { [weak self] in
                let peaks = try? await AudioWaveform.peaks(for: url)
                guard let self else { return }
                // A silent or audio-less clip still gets an entry so we
                // don't try again on every open.
                self.waveforms[key] = peaks ?? []
                self.waveformTasks.remove(key)
                self.saveWaveforms()
            }
        }
    }

    private func saveWaveforms() {
        guard let projectFolder, let data = try? JSONEncoder().encode(waveforms) else { return }
        try? data.write(to: projectFolder.appendingPathComponent(Self.waveformsFile), options: .atomic)
    }

    /// Bars for one clip at a given pixel width — what the timeline draws.
    func waveformBars(for clip: EditClip, count: Int) -> [Float]? {
        guard let peaks = waveforms[clip.source.path], !peaks.isEmpty else { return nil }
        return AudioWaveform.bars(from: peaks, sourceDuration: clip.sourceDuration,
                                  inPoint: clip.inPoint, outPoint: clip.outPoint, count: count)
    }

    /// Frames per source path for the filmstrip along the top of each
    /// clip, like iMovie's. Small, so they're regenerated on open rather
    /// than saved.
    @Published private(set) var filmstrips: [String: [CGImage]] = [:]
    private var filmstripTasks: Set<String> = []

    private func loadFilmstrips() {
        guard let project else { return }
        for url in project.clips.map(\.source) {
            let key = url.path
            guard filmstrips[key] == nil, !filmstripTasks.contains(key) else { continue }
            filmstripTasks.insert(key)
            Task { [weak self] in
                let frames = try? await Filmstrip.frames(for: url)
                guard let self else { return }
                // An unreadable clip still gets an entry so we don't retry
                // on every open.
                self.filmstrips[key] = frames ?? []
                self.filmstripTasks.remove(key)
            }
        }
    }

    func removeSelectedClip() {
        guard let id = selectedClipID, let p = project, let index = p.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = p.clips[index]
        edit(seekTo: p.clipStarts[index]) { $0.remove(id) }
        selectedClipID = project?.clips[safe: min(index, (project?.clips.count ?? 1) - 1)]?.id
        note = p.clips.count == 1
            ? "Removed the only clip — the timeline is empty."
            : "Removed the \(Self.clock(clip.duration)) piece at \(Self.clock(p.clipStarts[index]))."
        noteAction = NoteAction(title: "Undo") { [weak self] in self?.undo() }
    }

    // MARK: Project menu

    /// Every clip off the timeline; the project, its song, titles and
    /// pictures stay. Undoable.
    func clearTimeline() {
        guard let p = project, !p.clips.isEmpty else { return }
        edit(seekTo: 0) { $0.clips = [] }
        selectedClipID = nil
        note = "Cleared the timeline — \(p.clips.count) clip\(p.clips.count == 1 ? "" : "s") removed."
        noteAction = NoteAction(title: "Undo") { [weak self] in self?.undo() }
    }

    /// Rename the project and its folder on disk.
    func renameProject(to requested: String) {
        guard var p = project, let folder = projectFolder else { return }
        let fm = FileManager.default
        let name = Self.folderName(for: requested) { candidate in
            candidate != folder.lastPathComponent && fm.fileExists(atPath: Self.projectsRoot.appendingPathComponent(candidate).path)
        }
        guard name != p.name else { return }
        let destination = Self.projectsRoot.appendingPathComponent(name, isDirectory: true)
        do {
            try fm.moveItem(at: folder, to: destination)
        } catch {
            note = "Couldn't rename: \(error.localizedDescription)"
            return
        }
        p.name = name
        project = p
        projectFolder = destination
        save()
        refreshRecentProjects()
        note = "Renamed to \(name)."
    }

    /// The project folder goes to the Trash — its settings, subtitles and
    /// exports. The video files it referenced are untouched.
    func deleteProject() {
        guard let folder = projectFolder else { return }
        closeProject()
        deleteProject(at: folder)
    }

    /// Delete a project from the start screen's list.
    func deleteProject(at folder: URL) {
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } catch {
            phase = .failed("Couldn't delete \(folder.lastPathComponent): \(error.localizedDescription)")
        }
        refreshRecentProjects()
    }

    func moveSelectedClip(by offset: Int) {
        guard let id = selectedClipID else { return }
        edit { p in p.move(id, by: offset) }
        // Follow the clip to its new place.
        if let start = project?.start(of: id) { seek(to: start) }
    }

    func splitAtPlayhead() {
        let t = currentTime
        edit(seekTo: t) { p in
            if !p.split(at: t) { self.note = "Too close to the edge of the clip to split there." }
        }
        if let (index, _) = project?.locate(t) { selectedClipID = project?.clips[index].id }
    }

    /// Glue the clip at `index` back onto the one after it — the spatial
    /// undo for a split. The playhead lands on the healed seam.
    func rejoin(after index: Int) {
        guard let p = project, p.canRejoin(after: index) else { return }
        let seam = p.clipStarts[index] + p.clips[index].duration
        edit(seekTo: seam) { $0.rejoin(after: index) }
        selectedClipID = project?.clips[safe: index]?.id
        note = "Rejoined into one clip."
    }

    func trimStartToPlayhead() {
        let t = currentTime
        guard let (index, _) = project?.locate(t), let start = project?.clipStarts[index] else { return }
        edit(seekTo: start) { p in
            if !p.trimStart(at: t) { self.note = "Nothing to trim there." }
        }
    }

    func trimEndToPlayhead() {
        let t = currentTime
        edit(seekTo: max(0, t - 0.05)) { p in
            if !p.trimEnd(at: t) { self.note = "Nothing to trim there." }
        }
    }

    // MARK: Zoom

    /// Zoom the clip under the playhead. The player isn't rebuilt: the
    /// preview scales its own layer to match, smoothly, and the export
    /// bakes the same zoom in.
    func setZoom(_ zoom: Double) {
        guard let id = selectedClipID else { return }
        edit(rebuild: false, undoable: false) { $0.setZoom(zoom, for: id) }
    }

    /// Move the highlighted clip's picture about the frame, in any
    /// direction at any zoom, like dragging the video on VEED's canvas.
    /// `pan` is a share of the frame each way; the picture's centre stays
    /// inside the frame so it can't be lost.
    func setPan(_ pan: CGSize) {
        guard let clip = selectedClip else { return }
        let x = Double(VideoExporter.clampPan(pan.width))
        let y = Double(VideoExporter.clampPan(pan.height))
        guard x != clip.panX || y != clip.panY else { return }
        edit(rebuild: false, undoable: false) { $0.setPan(x: x, y: y, for: clip.id) }
    }

    /// The clip under the playhead, whose zoom the preview shows live.
    var playheadClip: EditClip? {
        guard let project, let (index, _) = project.locate(currentTime) else { return nil }
        return project.clips[safe: index]
    }

    func zoom(by factor: Double) {
        guard let clip = selectedClip else { return }
        setZoom(clip.zoom * factor)
    }

    /// Just enough zoom that the picture covers the whole frame.
    func zoomToFill() {
        guard let clip = selectedClip else { return }
        let render = renderSize
        Task {
            let asset = AVURLAsset(url: clip.source)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (natural, preferred) = try? await track.load(.naturalSize, .preferredTransform) else { return }
            setZoom(VideoExporter.fillZoom(naturalSize: natural, preferredTransform: preferred, into: render))
        }
    }

    // MARK: Speed and transitions

    /// Play the highlighted clip faster or slower. The preview is rebuilt:
    /// the composition itself is stretched.
    func setSpeed(_ speed: Double) {
        guard let clip = selectedClip, abs(clip.speed - speed) > 0.001 else { return }
        let start = project?.start(of: clip.id) ?? currentTime
        edit(seekTo: start) { $0.setSpeed(speed, for: clip.id) }
    }

    /// How the highlighted clip hands over to the one after it.
    func setTransition(_ transition: ClipTransition) {
        guard let clip = selectedClip, clip.transition != transition else { return }
        // Land just before the seam so the change is visible on Play.
        let seam = (project?.start(of: clip.id) ?? 0) + clip.duration
        edit(seekTo: max(0, seam - 1.5)) { $0.setTransition(transition, for: clip.id) }
    }

    // MARK: Music

    static let musicTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .audiovisualContent]

    /// The Add music button: a native picker for a song.
    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.musicTypes
        panel.message = "Choose a song to play under the video"
        panel.prompt = "Add music"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.addMusic(url)
        }
    }

    func addMusic(_ url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            guard let seconds = try? await asset.load(.duration).seconds, seconds > 0,
                  let hasAudio = try? await !asset.loadTracks(withMediaType: .audio).isEmpty, hasAudio else {
                note = "Couldn't read any sound in \(url.lastPathComponent)."
                return
            }
            edit {
                var track = MusicTrack(source: url, duration: seconds)
                if let old = $0.music {
                    track.volume = old.volume
                    track.fadeIn = old.fadeIn
                    track.fadeOut = old.fadeOut
                    track.loop = old.loop
                }
                $0.music = track
                // Voice over music: the clips' own sound comes down a little
                // the first time a song is added, unless the user set it.
                if $0.clipVolume >= 0.999 { $0.clipVolume = 0.8 }
            }
            note = "Added \(url.lastPathComponent) under the video."
        }
    }

    func removeMusic() {
        guard project?.music != nil else { return }
        edit { $0.music = nil }
    }

    /// Volume and fades change the sound mix only; the player keeps playing.
    func setMusicVolume(_ volume: Double) {
        edit(rebuild: false, undoable: false) { $0.setMusic { $0.volume = volume } }
        refreshAudioMix()
    }

    func setMusicFade(in fadeIn: Double? = nil, out fadeOut: Double? = nil) {
        edit(rebuild: false, undoable: false) { $0.setMusic { m in
            if let fadeIn { m.fadeIn = fadeIn }
            if let fadeOut { m.fadeOut = fadeOut }
        } }
        refreshAudioMix()
    }

    /// Where in the song it starts, and whether it repeats — both change
    /// what's on the track, so the preview is rebuilt.
    func setMusicStart(_ seconds: Double) {
        guard let music = project?.music, abs(music.startAt - seconds) > 0.01 else { return }
        edit { $0.setMusic { $0.startAt = seconds } }
    }

    func setMusicLoop(_ loop: Bool) {
        guard let music = project?.music, music.loop != loop else { return }
        edit { $0.setMusic { $0.loop = loop } }
    }

    /// How loud the clips' own sound is.
    func setClipVolume(_ volume: Double) {
        edit(rebuild: false, undoable: false) { $0.clipVolume = min(max(0, volume), 1) }
        refreshAudioMix()
    }

    private func refreshAudioMix() {
        guard let project, let previewTimeline else { return }
        player.currentItem?.audioMix = VideoExporter.audioMix(for: project, timeline: previewTimeline)
    }

    // MARK: Titles and pictures

    static let pictureTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP, .image]

    /// A new title at the top of the video, in the project's subtitle
    /// look, for the whole video — ready to be typed over and dragged.
    func addTitle() {
        guard project != nil else { return }
        let overlay = Overlay.title("Your title here", style: stylePreset)
        edit(rebuild: false) { $0.addOverlay(overlay) }
        selectedOverlayID = overlay.id
    }

    /// The Add picture button: a native picker for a logo or image.
    func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.pictureTypes
        panel.message = "Choose a logo or picture to lay over the video"
        panel.prompt = "Add picture"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.addPicture(url)
        }
    }

    func addPicture(_ url: URL) {
        guard project != nil else { return }
        guard NSImage(contentsOf: url) != nil else {
            note = "Couldn't read \(url.lastPathComponent) as a picture."
            return
        }
        let overlay = Overlay.picture(url)
        edit(rebuild: false) { $0.addOverlay(overlay) }
        selectedOverlayID = overlay.id
    }

    func updateOverlay(_ id: UUID, undoable: Bool = true, _ change: @escaping (inout Overlay) -> Void) {
        edit(rebuild: false, undoable: undoable) { $0.updateOverlay(id, change) }
    }

    /// Dragged in the preview to a new spot.
    func setOverlayAnchor(_ id: UUID, _ anchor: CaptionAnchor) {
        updateOverlay(id) { $0.anchor = anchor }
    }

    func removeOverlay(_ id: UUID) {
        edit(rebuild: false) { $0.removeOverlay(id) }
        if selectedOverlayID == id { selectedOverlayID = nil }
    }

    /// The picture behind an image overlay, read once per file.
    func overlayImage(for overlay: Overlay) -> NSImage? {
        guard overlay.kind == .image, let url = overlay.image else { return nil }
        if let cached = overlayImages[url.path] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        overlayImages[url.path] = image
        return image
    }

    // MARK: Background and banner

    var canvasBackground: CanvasBackground { project?.canvasBackground ?? .default }

    /// The colour behind the picture. The composition draws it, so the
    /// preview is rebuilt.
    func setBackground(_ background: CanvasBackground) {
        guard let p = project, p.canvasBackground != background else { return }
        edit { $0.background = background.rawValue }
    }

    /// Where Instagram lays its own controls over a Reel, as shares of
    /// the frame: the caption and username along the bottom, the status
    /// bar and "Reels" label along the top, the like/share rail down the
    /// right. Anything there is hidden on the phone.
    enum SafeZone {
        static let bottom = 0.16
        static let top = 0.08
        static let right = 0.12
        /// The rail of buttons runs up this stretch of the right edge.
        static let railRange = 0.16...0.58
    }

    /// The picture's place in the frame for a clip, in render space with
    /// y up — from the shape of its filmstrip frame, so nil until that's
    /// been read. What titles snap to.
    func pictureRect(for clip: EditClip) -> CGRect? {
        guard let frame = filmstrips[clip.source.path]?.first, frame.width > 0, frame.height > 0 else { return nil }
        let render = renderSize
        let w = CGFloat(frame.width), h = CGFloat(frame.height)
        let scale = min(render.width / w, render.height / h) * CGFloat(clip.zoom)
        let size = CGSize(width: w * scale, height: h * scale)
        // Pan is right-and-down; render space here is y-up.
        let centre = CGPoint(x: render.width / 2 + CGFloat(clip.panX) * render.width,
                             y: render.height / 2 - CGFloat(clip.panY) * render.height)
        return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }

    /// A promo layout in one click, laid out inside Instagram's safe
    /// area: the picture sits high in the frame on a dark background, a
    /// show title above it, the name and date below it, all clear of the
    /// caption strip. Placeholders, ready to be typed over; the user adds
    /// their logo from Picture.
    func addBanner() {
        guard let p = project, !p.clips.isEmpty else { return }
        let style = stylePreset
        let top = Overlay(kind: .text, text: "LIVE STAND-UP COMEDY", anchor: CaptionAnchor(x: 0.5, y: 0.945),
                          style: style.rawValue, scale: 0.75)
        let name = Overlay(kind: .text, text: "YOUR NAME", anchor: CaptionAnchor(x: 0.5, y: 0.265),
                           style: style.rawValue, scale: 1.05)
        let when = Overlay(kind: .text, text: "JUNE 27 · SEATTLE", anchor: CaptionAnchor(x: 0.5, y: 0.195),
                           style: style.rawValue, scale: 0.7)
        edit(seekTo: nil) { project in
            if project.canvasBackground == .black { project.background = CanvasBackground.charcoal.rawValue }
            for i in project.clips.indices {
                project.clips[i].zoom = 0.58
                project.clips[i].panX = 0
                // Up a little, so the bottom band clears Instagram's caption.
                project.clips[i].panY = -0.12
            }
            project.addOverlay(top)
            project.addOverlay(name)
            project.addOverlay(when)
        }
        selectedOverlayID = name.id
        note = "Banner added — type over the titles, drag them, and add your logo from Picture. ⌘Z takes it all back."
    }

    // MARK: Frame

    /// The shape the video is framed and exported in.
    var frameFormat: FrameFormat { project?.format ?? .default }
    var renderSize: CGSize { frameFormat.renderSize }

    /// Reframe the whole video for another platform. The preview is rebuilt
    /// since the composition's own size changes; zoom and pan are kept.
    func setFrameFormat(_ format: FrameFormat) {
        guard let p = project, p.frameFormat != format.id else { return }
        edit { $0.frameFormat = format.id }
    }

    // MARK: Subtitles

    func setSubtitleStyle(_ preset: SubtitleStylePreset) {
        guard var p = project, p.stylePreset != preset else { return }
        p.subtitleStyle = preset.rawValue
        project = p
        save()
    }

    /// Where the subtitles sit on the video; nil is the style's own spot.
    var captionAnchor: CaptionAnchor? { project?.captionAnchor }

    /// Dragged in the preview. Saved, and the export follows; the player
    /// itself doesn't change, so no preview rebuild.
    func setCaptionAnchor(_ anchor: CaptionAnchor?) {
        guard var p = project, p.captionAnchor != anchor else { return }
        p.captionAnchor = anchor
        project = p
        save()
    }

    func setCueText(_ id: UUID, _ text: String) {
        guard var p = project else { return }
        p.setCueText(id, text)
        project = p
        save()
    }

    func setCueTranslation(_ id: UUID, _ text: String) {
        guard var p = project else { return }
        p.setCueTranslation(id, text)
        project = p
        save()
    }

    func removeCue(_ id: UUID) {
        guard var p = project else { return }
        p.removeCue(id)
        project = p
        save()
    }

    /// A line picked on the timeline — just added, or clicked — for the
    /// Subtitles panel to scroll to and put the cursor in. Cleared once it has.
    @Published var cueToReveal: UUID?

    /// VEED's "+ Add subtitle" on the timeline: a blank line at the playhead
    /// for the user to type. Nothing happens if a line is already there.
    func addCueAtPlayhead() {
        guard var p = project, let id = p.addCue(at: currentTime) else { return }
        project = p
        save()
        cueToReveal = id
    }

    /// A line's start and end typed into the Subtitles panel, in timeline seconds.
    func setCueTiming(_ id: UUID, start: Double, end: Double) {
        guard var p = project else { return }
        p.setCueTiming(id, start: start, end: end)
        project = p
        save()
    }

    /// Where a line sits: its own spot if it's detached, else the shared one.
    func anchor(for cue: TimelineCue) -> CaptionAnchor? { cue.anchor ?? captionAnchor }

    /// Detach a line, as on VEED: it keeps the spot it's in now as its
    /// own, so dragging it on the video moves it alone.
    func detachCue(_ cue: TimelineCue) {
        let spot = anchor(for: cue) ?? CaptionAnchor(x: 0.5, y: Double(style.centreFromBottom))
        setCueAnchor(cue.id, spot)
    }

    func setCueAnchor(_ id: UUID, _ anchor: CaptionAnchor?) {
        guard var p = project else { return }
        p.setCueAnchor(id, anchor)
        project = p
        save()
    }

    /// "0:06.18", "1:02.5" or "6.18" as seconds; nil if it isn't a time.
    nonisolated static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// What the takes are spoken in.
    var spokenLocale: Locale { Locale(identifier: project?.spokenLanguage ?? VideoProject.defaultSpokenLanguage) }

    /// Choose the language the recogniser listens for. Anything already
    /// heard was heard in the old language, so it's forgotten — the next
    /// Auto-subtitle listens again.
    func setSpokenLanguage(_ identifier: String) {
        guard var p = project, p.spokenLanguage != identifier else { return }
        p.spokenLanguage = identifier
        p.transcripts = [:]
        project = p
        save()
        if hasSubtitles { note = "Press Auto-subtitle in \(SubtitleLanguages.name(of: spokenLocale)) to listen again." }
    }

    var hasSubtitles: Bool { !(project?.timelineCues.isEmpty ?? true) }
    var translationEnabled: Bool { project?.translationLanguage != nil }
    var translationLanguage: String? { project?.translationLanguage }

    /// Turn "Add translation" on or off. On translates every subtitle there
    /// is (and every one made later); off drops the translated lines.
    func setTranslationEnabled(_ on: Bool) {
        guard var p = project, on != (p.translationLanguage != nil) else { return }
        if on {
            p.translationLanguage = lastTranslationLanguage ?? SubtitleLanguages.defaultTranslationTarget(for: p.spokenLanguage)
            project = p
            save()
            requestTranslation()
        } else {
            lastTranslationLanguage = p.translationLanguage
            p.translationLanguage = nil
            p.clearTranslations()
            project = p
            save()
            if isTranslating { phase = .idle }
        }
    }

    private var lastTranslationLanguage: String?
    private var isTranslating: Bool { if case .translating = phase { true } else { false } }

    func setTranslationLanguage(_ code: String) {
        guard var p = project, p.translationLanguage != code else { return }
        p.translationLanguage = code
        p.clearTranslations()
        project = p
        save()
        requestTranslation()
    }

    /// The language pair for the next translation pass.
    var translationSource: Locale.Language { spokenLocale.language }
    var translationTarget: Locale.Language? { translationLanguage.map { Locale.Language(identifier: $0) } }

    /// Ask the panel to translate whatever subtitles lack a translated line.
    func requestTranslation() {
        guard let project, project.translationLanguage != nil else { return }
        let pending = project.untranslatedCues.count
        guard pending > 0 else { return }
        guard #available(macOS 15, *) else {
            note = "Translation needs macOS 15 or later."
            return
        }
        phase = .translating(pending)
        translationJob += 1
    }

    /// Run by the panel with a live `TranslationSession`: `translate` takes
    /// the lines in order and returns them translated in the same order.
    func translateMissingCues(using translate: ([String]) async throws -> [String]) async {
        guard let p = project, p.translationLanguage != nil else { phase = .idle; return }
        let pending = p.untranslatedCues
        guard !pending.isEmpty else { phase = .idle; return }
        do {
            let translated = try await translate(pending.map(\.text))
            guard var current = project, current.translationLanguage != nil else { phase = .idle; return }
            var byID: [UUID: String] = [:]
            for (cue, line) in zip(pending, translated) { byID[cue.id] = line }
            current.setTranslations(byID)
            project = current
            save()
            phase = .idle
            note = "Translated \(byID.count) subtitle\(byID.count == 1 ? "" : "s") into \(SubtitleLanguages.name(ofLanguage: current.translationLanguage ?? ""))."
        } catch {
            phase = .failed("Couldn't translate: \(error.localizedDescription)")
        }
    }

    /// Listen to every take that hasn't been heard yet, then lay subtitles
    /// on every clip. Editing the words afterwards is the user's job.
    func generateCaptions() {
        guard let project, !project.clips.isEmpty else {
            note = "Import a clip first."
            return
        }
        guard !phase.isBusy else { return }
        transcription = Task { await transcribeAndCaption() }
    }

    private var transcription: Task<Void, Never>?

    /// Stop an Auto-subtitle pass. Takes already heard stay heard, so
    /// pressing the button again picks up where this left off.
    func stopSubtitling() {
        guard case .transcribing = phase else { return }
        transcription?.cancel()
        transcription = nil
        phase = .idle
        note = "Stopped listening. Press Auto-subtitle to carry on."
    }

    private var transcriptionRun = 0

    private func transcribeAndCaption() async {
        guard var p = project else { return }
        transcriptionRun += 1
        let run = transcriptionRun
        let locale = spokenLocale
        // Transcripts from the older recogniser are thrown away once, so a
        // project it left half-captioned is heard again by the new one.
        if p.transcriptVersion < VideoProject.currentTranscriptVersion {
            p.transcripts = [:]
            p.transcriptVersion = VideoProject.currentTranscriptVersion
            project = p
            save()
        }
        let pending = p.untranscribedSources
        for (index, url) in pending.enumerated() {
            let duration = p.clips.first { $0.source == url }?.sourceDuration ?? 0
            var listening = Listening(clipName: url.lastPathComponent, index: index + 1, count: pending.count, duration: duration)
            phase = .transcribing(listening)
            do {
                let words = try await VideoTranscriber.words(in: url, locale: locale) { [weak self] progress in
                    // A stopped pass can still have a report in flight;
                    // only the live one may draw.
                    guard let self, self.transcriptionRun == run, case .transcribing = self.phase else { return }
                    listening.secondsHeard = progress.secondsHeard
                    listening.latestText = progress.latestText
                    self.phase = .transcribing(listening)
                }
                guard !Task.isCancelled, transcriptionRun == run, var current = project else { return }
                current.transcripts[url.path] = words
                project = current
                p = current
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(error.localizedDescription)
                save()
                return
            }
        }
        p.recaptionAll()
        project = p
        save()
        let cues = p.timelineCues
        if cues.isEmpty {
            phase = .idle
            note = "Didn't hear any words in these clips."
            return
        }
        // Land on the first line so a subtitle is on the video right away.
        if let first = cues.first, project?.cue(at: currentTime) == nil { seek(to: first.start + 0.05) }
        phase = .subtitled(cues.count)
        if translationEnabled { requestTranslation() }
    }

    // MARK: Preview

    private func rebuildPreview(seekTo requested: Double?) {
        guard let project else {
            player.replaceCurrentItem(with: nil)
            return
        }
        previewGeneration += 1
        let generation = previewGeneration
        let wasPlaying = isPlaying
        let target = requested ?? currentTime
        Task { [self] in
            do {
                let timeline = try await VideoExporter.build(project, zoomed: false)
                guard generation == previewGeneration else { return }
                let item = AVPlayerItem(asset: timeline.composition)
                item.videoComposition = timeline.videoComposition
                item.audioMix = VideoExporter.audioMix(for: project, timeline: timeline)
                // Sped-up or slowed clips keep their pitch.
                item.audioTimePitchAlgorithm = .spectral
                previewTimeline = timeline
                itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    let reason = item.error?.localizedDescription ?? "unknown error"
                    let code = (item.error as NSError?)?.code ?? 0
                    Task { @MainActor in self?.note = "Preview can't play: \(reason) (\(code))" }
                }
                player.replaceCurrentItem(with: item)
                seek(to: min(target, max(0, project.duration - 0.05)))
                if wasPlaying { player.play() }
            } catch VideoExporter.Failure.noClips {
                guard generation == previewGeneration else { return }
                player.replaceCurrentItem(with: nil)
                previewTimeline = nil
                currentTime = 0
            } catch {
                guard generation == previewGeneration else { return }
                note = "Preview failed: \(error.localizedDescription) (\((error as NSError).code))"
            }
        }
    }

    func togglePlay() {
        if isPlaying { player.pause() } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(0, duration))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: VideoExporter.timescale),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        // The cut buttons act on the clip under the playhead, so keep the
        // selection following it — no separate "select" step to learn.
        if let (index, _) = project?.locate(clamped), let id = project?.clips[safe: index]?.id {
            selectedClipID = id
        }
    }

    func selectClip(_ id: UUID) {
        selectedClipID = id
        if let start = project?.start(of: id) { seek(to: start) }
    }

    // MARK: Export

    func export() {
        guard let project, let exportsFolder else { return }
        guard !project.clips.isEmpty else {
            note = "Import a clip first."
            return
        }
        player.pause()
        let stamp = Self.stampFormatter.string(from: Date())
        let base = exportsFolder.appendingPathComponent("\(project.name) \(stamp)")
        let movie = base.appendingPathExtension("mp4")
        phase = .exporting(0)
        Task { [self] in
            do {
                try await VideoExporter.export(project, style: style, to: movie,
                                               images: { [weak self] in self?.overlayImage(for: $0) }) { [weak self] p in
                    self?.phase = .exporting(p)
                }
                try? project.srt.write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                try? project.transcript.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                phase = .exported(movie)
                lastExport = movie
                note = "Done! \(movie.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([movie])
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Remote (Peeky Remote on the phone)

    /// One frame at the export rate — the step the phone's dial moves by.
    static let frameStep = 1.0 / 30.0

    /// `VIDEO_STATE <project>\t<NONE|PLAYING|PAUSED>\t<pos>\t<dur>\t<clip name>\t<clip #>\t<clip count>\t<zoom>\t<captions 0|1>\t<phase>`
    func remoteStateLine() -> String {
        let f: (String) -> String = { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        guard let project else { return "VIDEO_STATE \tNONE\t0\t0\t\t0\t0\t1\t0\tIDLE" }
        let clip = selectedClip
        let index = project.clips.firstIndex { $0.id == clip?.id }.map { $0 + 1 } ?? 0
        let phaseName: String
        switch phase {
        case .idle: phaseName = "IDLE"
        case .importing: phaseName = "IMPORTING"
        case .transcribing: phaseName = "TRANSCRIBING"
        case .translating: phaseName = "TRANSLATING"
        case .exporting: phaseName = "EXPORTING"
        case .subtitled: phaseName = "SUBTITLED"
        case .exported: phaseName = "EXPORTED"
        case .failed: phaseName = "FAILED"
        }
        return "VIDEO_STATE " + [f(project.name), isPlaying ? "PLAYING" : "PAUSED",
                                 String(format: "%.2f", currentTime), String(format: "%.2f", duration),
                                 f(clip?.name ?? ""), String(index), String(project.clips.count),
                                 String(format: "%.2f", clip?.zoom ?? 1),
                                 (clip?.cues.isEmpty == false) ? "1" : "0", phaseName].joined(separator: "\t")
    }

    private func publishRemoteState() { onRemoteLine?(remoteStateLine()) }

    /// A command from the phone's Peeky Video pad — the same buttons as the
    /// tab, plus the dial (JOG / TRIM_START / TRIM_END in frames).
    func handleRemote(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let number = parts.count > 1 ? Double(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        switch verb {
        case "PLAYPAUSE": if hasProject { togglePlay() }
        case "START": seek(to: 0)
        case "SKIP": seek(to: currentTime + (number ?? 5))
        case "SEEK": if let number { seek(to: number) }
        case "JOG":
            if isPlaying { player.pause() }
            seek(to: currentTime + (number ?? 1) * Self.frameStep)
        case "TRIM_START": nudgeSelectedClipStart(byFrames: number ?? 1)
        case "TRIM_END": nudgeSelectedClipEnd(byFrames: number ?? 1)
        case "SPLIT": splitAtPlayhead()
        case "CUT_BEFORE": trimStartToPlayhead()
        case "CUT_AFTER": trimEndToPlayhead()
        case "ZOOM_IN": zoom(by: 1.15)
        case "ZOOM_OUT": zoom(by: 1 / 1.15)
        case "FILL": zoomToFill()
        case "FIT": setZoom(1)
        case "EARLIER": moveSelectedClip(by: -1)
        case "LATER": moveSelectedClip(by: 1)
        case "REMOVE": removeSelectedClip()
        case "REJOIN":
            // Heal the seam nearest the playhead, if it's a healable one.
            if let p = project, let (index, _) = p.locate(currentTime) {
                let before = index - 1, after = index
                if p.canRejoin(after: after), !p.canRejoin(after: before) { rejoin(after: after) }
                else if p.canRejoin(after: before), !p.canRejoin(after: after) { rejoin(after: before) }
                else if p.canRejoin(after: before) {
                    let toStart = currentTime - p.clipStarts[index]
                    let toEnd = p.clipStarts[index] + p.clips[index].duration - currentTime
                    rejoin(after: toStart <= toEnd ? before : after)
                }
            }
        case "CAPTIONS": if case .transcribing = phase { stopSubtitling() } else if !phase.isBusy { generateCaptions() }
        case "EXPORT": if !phase.isBusy { export() }
        default: break
        }
    }

    /// Dial in Trim-start mode: slide the selected clip's first frame and
    /// park the playhead on it so the cut is what's on screen.
    func nudgeSelectedClipStart(byFrames frames: Double) {
        guard let id = selectedClipID else { return }
        if isPlaying { player.pause() }
        var moved = false
        edit { p in moved = p.nudgeStart(id, by: frames * Self.frameStep) }
        if moved, let start = project?.start(of: id) { seek(to: start) }
    }

    /// Dial in Trim-end mode: slide the selected clip's last frame.
    func nudgeSelectedClipEnd(byFrames frames: Double) {
        guard let id = selectedClipID else { return }
        if isPlaying { player.pause() }
        var moved = false
        edit { p in moved = p.nudgeEnd(id, by: frames * Self.frameStep) }
        if moved, let start = project?.start(of: id), let clip = selectedClip {
            seek(to: max(start, start + clip.duration - Self.frameStep))
        }
    }

    func revealProject() {
        guard let projectFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([projectFolder])
    }

    func dismissPhase() { phase = .idle }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let m = Int(s / 60)
        let rest = s - Double(m) * 60
        return String(format: "%d:%05.2f", m, rest)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
