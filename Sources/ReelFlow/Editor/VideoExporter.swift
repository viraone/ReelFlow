import AppKit
import AVFoundation
import QuartzCore

/// Turns a `VideoProject` into an AVFoundation composition — for the preview
/// player and for the exported file — and writes the finished MP4.
enum VideoExporter {
    /// The Reels frame — what a project renders at unless it picks another
    /// `FrameFormat`. The default for every helper that takes a `render`.
    static let renderSize = FrameFormat.default.renderSize
    static let frameRate: Int32 = 30
    static let timescale: CMTimeScale = 600

    enum Failure: LocalizedError {
        case noVideo
        case noClips
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideo: "Couldn't set up the video track."
            case .noClips: "Add a clip first."
            case .exportFailed(let message): "Export failed: \(message)"
            case .cancelled: "Export cancelled."
            }
        }
    }

    struct Timeline {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        /// The clips' own sound, on the two alternating tracks.
        let clipAudioTracks: [AVCompositionTrack]
        /// The song, when the project has one.
        let musicTrack: AVCompositionTrack?
        let duration: CMTime
    }

    /// The transform that shows a whole source frame inside the render
    /// frame — scaled to fit, centred, bars where the shapes differ. A 9:16
    /// phone take fills the frame exactly; a widescreen screen recording
    /// sits letterboxed in the middle.
    /// `zoom` scales around the centre on top of that: 1 is the fit,
    /// larger crops in — how a landscape clip is made to fill 9:16. `pan`
    /// then moves the picture anywhere, as a share of the frame (right and
    /// down positive), like dragging the video about VEED's canvas; only
    /// its centre is kept inside the frame so it can't be lost.
    static func fitTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, zoom: CGFloat = 1,
                             pan: CGSize = .zero, into render: CGSize = renderSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(oriented.width), height = abs(oriented.height)
        guard width > 0, height > 0 else { return .identity }
        let scale = min(render.width / width, render.height / height) * max(0.1, zoom)
        let dx = clampPan(pan.width) * render.width
        let dy = clampPan(pan.height) * render.height
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (render.width - width * scale) / 2 + dx,
                                             y: (render.height - height * scale) / 2 + dy))
    }

    /// How far the picture may be moved each way: half the frame, so its
    /// centre never leaves the frame.
    static let maxPan: CGFloat = 0.5

    static func clampPan(_ share: CGFloat) -> CGFloat { min(max(-maxPan, share), maxPan) }

    /// The zoom at which a clip just covers the frame — no black bars.
    static func fillZoom(naturalSize: CGSize, preferredTransform: CGAffineTransform, into render: CGSize = renderSize) -> Double {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(oriented.width), height = abs(oriented.height)
        guard width > 0, height > 0 else { return 1 }
        let fit = min(render.width / width, render.height / height)
        let fill = max(render.width / width, render.height / height)
        return Double(fill / fit)
    }

    /// One clip as placed in the composition.
    private struct Placed {
        let clip: EditClip
        let track: Int
        let range: CMTimeRange
        let transform: CGAffineTransform
        /// Footage after the clip's out point carried on under the next
        /// clip for a dissolve, on this clip's own track.
        var tail: CMTimeRange?
    }

    /// The clips laid end to end, each framed for the project's format,
    /// at its speed, with its transition into the next; the clips' sound
    /// and the song on their own tracks. No captions or overlays: those
    /// are drawn by the preview itself, and burned in only on export.
    /// Clips alternate between two video tracks so a dissolve can overlap
    /// the end of one with the start of the next. A clip inserted past the
    /// end of its track leaves an empty edit behind it, as in Apple's own
    /// transition sample — nothing is padded by hand.
    /// `zoomed` false leaves every clip at the fit; the preview zooms live
    /// on its own layer instead, so a zoom never rebuilds the player.
    static func build(_ project: VideoProject, zoomed: Bool = true) async throws -> Timeline {
        let composition = AVMutableComposition()
        let videoTracks = (0..<2).compactMap { _ in
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        guard videoTracks.count == 2 else { throw Failure.noVideo }
        let audioTracks = (0..<2).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        let render = project.renderSize
        let background = project.canvasBackground.cgColor
        let clips = project.clips.filter { $0.duration > 0 }
        var placed: [Placed] = []
        var cursor = CMTime.zero

        for (index, clip) in clips.enumerated() {
            let asset = AVURLAsset(url: clip.source)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let (natural, preferred, trackRange) = try await source.load(.naturalSize, .preferredTransform, .timeRange)
            let wanted = CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: timescale),
                                     duration: CMTime(seconds: clip.sourceLength, preferredTimescale: timescale))
            let range = wanted.intersection(trackRange)
            guard range.duration > .zero else { continue }
            let t = placed.count % 2
            let videoTrack = videoTracks[t]
            // At 1× the clip keeps its own exact length: rounding it to
            // another clock could leave a sliver of the track past the
            // instruction that covers it, and the composition won't play.
            let scaled = clip.speed == 1 ? range.duration
                : CMTime(seconds: range.duration.seconds / max(0.01, clip.speed), preferredTimescale: timescale)
            try videoTrack.insertTimeRange(range, of: source, at: cursor)
            if clip.speed != 1 {
                videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaled)
            }
            if audioTracks.count == 2, let audio = try await asset.loadTracks(withMediaType: .audio).first {
                // Sound no longer than the picture: a file whose audio runs
                // on past its last frame (downloaded reels often do) would
                // otherwise leave a stretch with sound but no picture
                // instruction, and the whole composition draws black.
                let audioRange = range.intersection(try await audio.load(.timeRange))
                if audioRange.duration > .zero {
                    try audioTracks[t].insertTimeRange(audioRange, of: audio, at: cursor)
                    if clip.speed != 1 {
                        let scaledAudio = CMTime(seconds: audioRange.duration.seconds / max(0.01, clip.speed), preferredTimescale: timescale)
                        audioTracks[t].scaleTimeRange(CMTimeRange(start: cursor, duration: audioRange.duration), toDuration: scaledAudio)
                    }
                }
            }
            let transform = fitTransform(naturalSize: natural, preferredTransform: preferred,
                                         zoom: zoomed ? CGFloat(clip.zoom) : 1,
                                         pan: zoomed ? CGSize(width: clip.panX, height: clip.panY) : .zero,
                                         into: render)
            var entry = Placed(clip: clip, track: t, range: CMTimeRange(start: cursor, duration: scaled), transform: transform, tail: nil)
            cursor = cursor + scaled

            // A dissolve carries this clip's footage on past its out point,
            // under the start of the next clip, on this same track (appended
            // right here so nothing later on the track is pushed along).
            if clip.transition == .dissolve, index + 1 < clips.count {
                let wantedLength = transitionLength(from: clip, to: clips[index + 1])
                let handle = CMTimeRange(start: wanted.end,
                                         duration: CMTime(seconds: wantedLength * clip.speed, preferredTimescale: timescale))
                    .intersection(trackRange)
                if handle.duration.seconds > 0.05 {
                    try videoTrack.insertTimeRange(handle, of: source, at: cursor)
                    let tailLength = clip.speed == 1 ? handle.duration
                        : CMTime(seconds: handle.duration.seconds / max(0.01, clip.speed), preferredTimescale: timescale)
                    if clip.speed != 1 {
                        videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: handle.duration), toDuration: tailLength)
                    }
                    entry.tail = CMTimeRange(start: cursor, duration: tailLength)
                }
            }
            placed.append(entry)
        }
        guard !placed.isEmpty else { throw Failure.noClips }
        let total = cursor

        // Instructions: one per clip, split in two where the previous clip
        // dissolves into it — the first stretch shows both.
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (i, entry) in placed.enumerated() {
            let previous = i > 0 ? placed[i - 1] : nil
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[entry.track])
            layer.setTransform(entry.transform, at: entry.range.start)
            var bodyStart = entry.range.start

            if let previous, let tail = previous.tail, tail.duration > .zero {
                // Dissolve in over the previous clip's continuing footage.
                let overlap = CMTimeRange(start: entry.range.start, duration: CMTimeMinimum(tail.duration, entry.range.duration))
                let under = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[previous.track])
                under.setTransform(previous.transform, at: overlap.start)
                let over = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[entry.track])
                over.setTransform(entry.transform, at: overlap.start)
                over.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: overlap)
                let mix = AVMutableVideoCompositionInstruction()
                mix.timeRange = overlap
                mix.backgroundColor = background
                mix.layerInstructions = [over, under]
                instructions.append(mix)
                bodyStart = overlap.end
            } else if let previous, previous.clip.transition == .fade || (previous.clip.transition == .dissolve && previous.tail == nil) {
                // Fade in from black. (A dissolve with no handle to use
                // falls back to this.)
                let length = CMTime(seconds: transitionLength(from: previous.clip, to: entry.clip), preferredTimescale: timescale)
                layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1,
                                     timeRange: CMTimeRange(start: entry.range.start, duration: CMTimeMinimum(length, entry.range.duration)))
            }
            if i + 1 < placed.count, entry.clip.transition == .fade || (entry.clip.transition == .dissolve && entry.tail == nil) {
                // Fade out to black at the end.
                let length = CMTime(seconds: transitionLength(from: entry.clip, to: placed[i + 1].clip), preferredTimescale: timescale)
                let fadeStart = CMTimeMaximum(bodyStart, entry.range.end - length)
                layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0,
                                     timeRange: CMTimeRange(start: fadeStart, end: entry.range.end))
            }
            let body = AVMutableVideoCompositionInstruction()
            body.timeRange = CMTimeRange(start: bodyStart, end: entry.range.end)
            body.backgroundColor = background
            body.layerInstructions = [layer]
            if body.timeRange.duration > .zero { instructions.append(body) }
        }

        // The song, from where the user started it, repeated to the end if
        // it's shorter than the video and looping is on.
        var musicTrack: AVMutableCompositionTrack?
        if let music = project.music, total > .zero {
            let asset = AVURLAsset(url: music.source)
            if let song = try? await asset.loadTracks(withMediaType: .audio).first,
               let songRange = try? await song.load(.timeRange),
               let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                var at = CMTime.zero
                var from = CMTime(seconds: music.startAt, preferredTimescale: timescale)
                var passes = 0
                while at < total, passes < 200 {
                    let available = CMTimeRange(start: from, end: songRange.end).intersection(songRange)
                    guard available.duration.seconds > 0.05 else { break }
                    let take = CMTimeMinimum(available.duration, total - at)
                    try track.insertTimeRange(CMTimeRange(start: available.start, duration: take), of: song, at: at)
                    at = at + take
                    passes += 1
                    guard music.loop else { break }
                    from = songRange.start
                }
                musicTrack = track
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = render
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
        videoComposition.instructions = instructions
        return Timeline(composition: composition, videoComposition: videoComposition,
                        clipAudioTracks: audioTracks, musicTrack: musicTrack, duration: total)
    }

    /// How long the hand-over between two clips runs: the standard length,
    /// or less when either clip is short.
    static func transitionLength(from a: EditClip, to b: EditClip) -> Double {
        max(0.1, min(ClipTransition.length, a.duration / 2, b.duration / 2))
    }

    // MARK: Sound

    /// Volumes for the clips' sound and the song, with the song's fades.
    /// Applied to the preview's player item and to the export alike, and
    /// cheap enough to rebuild on every slider move.
    static func audioMix(for project: VideoProject, timeline: Timeline) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        var inputs: [AVMutableAudioMixInputParameters] = []
        for track in timeline.clipAudioTracks {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = .spectral
            p.setVolume(Float(min(max(0, project.clipVolume), 1)), at: .zero)
            inputs.append(p)
        }
        if let music = project.music, let track = timeline.musicTrack {
            let p = AVMutableAudioMixInputParameters(track: track)
            let volume = Float(min(max(0, music.volume), 1))
            let total = timeline.duration.seconds
            p.setVolume(volume, at: .zero)
            if music.fadeIn > 0.05 {
                let length = min(music.fadeIn, total / 2)
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: timescale)))
            }
            if music.fadeOut > 0.05 {
                let length = min(music.fadeOut, total / 2)
                p.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                timeRange: CMTimeRange(start: CMTime(seconds: total - length, preferredTimescale: timescale),
                                                       duration: CMTime(seconds: length, preferredTimescale: timescale)))
            }
            inputs.append(p)
        }
        mix.inputParameters = inputs
        return mix
    }

    // MARK: Captions

    /// The pill a caption sits in, and where, for a frame of `render`.
    /// `text` is taken as already spelled by the style. With an `anchor`
    /// the pill is centred there (kept inside the frame); without one it
    /// sits where the style puts it.
    static func captionFrame(for text: String, style: CaptionStyle, anchor: CaptionAnchor? = nil,
                             render: CGSize = renderSize) -> (pill: CGRect, textSize: CGSize) {
        let inset = style.strokeColor == nil ? 0 : style.strokeWidth
        let maxWidth = render.width * style.maxWidthShare - style.horizontalPadding * 2 - inset * 2
        let attributes: [NSAttributedString.Key: Any] = [.font: style.font]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let textSize = CGSize(width: ceil(bounds.width) + inset * 2, height: ceil(bounds.height) + inset * 2)
        let pillSize = CGSize(width: textSize.width + style.horizontalPadding * 2,
                              height: textSize.height + style.verticalPadding * 2)
        let centre = anchor.map { CGPoint(x: render.width * $0.x, y: render.height * $0.y) }
            ?? CGPoint(x: render.width / 2, y: render.height * style.centreFromBottom)
        let pill = CGRect(x: min(max(0, centre.x - pillSize.width / 2), max(0, render.width - pillSize.width)),
                          y: min(max(0, centre.y - pillSize.height / 2), max(0, render.height - pillSize.height)),
                          width: pillSize.width, height: pillSize.height)
        return (pill.integral, textSize)
    }

    /// One caption drawn in `style` at its place in a `render`-sized frame:
    /// the box (if any), an outline behind the letters (if any), the letters,
    /// with the `highlight`-th word of the first line in the accent colour.
    /// The same layer serves the export, the preview and the style tiles.
    @MainActor
    static func captionLayer(text raw: String, highlight: Int? = nil, style: CaptionStyle, anchor: CaptionAnchor? = nil,
                             render: CGSize = renderSize) -> CALayer {
        let shown = style.display(raw)
        let (pill, textSize) = captionFrame(for: shown, style: style, anchor: anchor, render: render)
        let container = CALayer()
        container.frame = pill
        container.backgroundColor = (style.pillColor ?? .clear).cgColor
        container.cornerRadius = style.cornerRadius
        container.masksToBounds = false

        let textFrame = CGRect(x: (pill.width - textSize.width) / 2,
                               y: (pill.height - textSize.height) / 2,
                               width: textSize.width, height: textSize.height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fill: [NSAttributedString.Key: Any] = [
            .font: style.font, .foregroundColor: style.textColor, .paragraphStyle: paragraph,
        ]
        let inset = style.strokeColor == nil ? 0 : style.strokeWidth
        // A stroke centred on the outline would eat into the letters, so
        // outlines are their own layer underneath, stroke only.
        var backmost: CALayer?
        if let strokeColor = style.strokeColor, style.strokeWidth > 0 {
            var outline = fill
            outline[.strokeColor] = strokeColor
            outline[.strokeWidth] = style.strokeWidth * 2 / style.fontSize * 100
            // The text box was measured with `inset` of slack on each side
            // for exactly this outline; keep that width, or the stroke on
            // the first and last letters is cut off at the layer's edge.
            let layer = textLayer(shown, attributes: outline, frame: textFrame.insetBy(dx: 0, dy: inset))
            container.addSublayer(layer)
            backmost = layer
        }
        let letters = NSMutableAttributedString(string: shown, attributes: fill)
        if let highlight, let accent = style.accentColor,
           let range = wordRanges(in: shown).dropFirst(highlight).first {
            letters.addAttribute(.foregroundColor, value: accent, range: range)
        }
        let face = textLayer(letters, frame: textFrame.insetBy(dx: 0, dy: inset))
        container.addSublayer(face)
        if let shadowColor = style.shadowColor {
            let target = backmost ?? face
            target.shadowColor = shadowColor.cgColor
            target.shadowOpacity = 1
            target.shadowRadius = style.shadowRadius
            target.shadowOffset = style.shadowOffset
        }
        return container
    }

    private static func textLayer(_ text: String, attributes: [NSAttributedString.Key: Any], frame: CGRect) -> CATextLayer {
        textLayer(NSAttributedString(string: text, attributes: attributes), frame: frame)
    }

    private static func textLayer(_ text: NSAttributedString, frame: CGRect) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = text
        layer.alignmentMode = .center
        layer.isWrapped = true
        layer.contentsScale = 2
        layer.masksToBounds = false
        layer.frame = frame
        // A text layer draws its letters lazily, and the exporter can render
        // its first seconds of frames before that happens — empty pills at
        // the start of the video. Draw now, so the letters are there from
        // the first frame.
        layer.setNeedsDisplay()
        layer.displayIfNeeded()
        return layer
    }

    /// Where each word of the first line sits in `text`, split on spaces
    /// so contractions stay whole.
    static func wordRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let firstLine = ns.range(of: "\n").location
        var ranges: [NSRange] = []
        var index = 0
        let limit = firstLine == NSNotFound ? ns.length : firstLine
        while index < limit {
            while index < limit, ns.character(at: index) == 0x20 { index += 1 }
            let start = index
            while index < limit, ns.character(at: index) != 0x20 { index += 1 }
            if index > start { ranges.append(NSRange(location: start, length: index - start)) }
        }
        return ranges
    }

    /// A layer per caption, each visible only for its own stretch of the
    /// video — or one per *word* when the style follows the speaker. Core
    /// Animation's timeline is the video's, so a plain opacity animation
    /// with a begin time does the scheduling.
    @MainActor
    static func captionOverlay(for cues: [TimelineCue], style: CaptionStyle, anchor: CaptionAnchor? = nil,
                               render: CGSize = renderSize,
                               wordStarts: (TimelineCue) -> [Double] = { _ in [] }) -> CALayer {
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: render)
        for cue in cues where !cue.text.trimmingCharacters(in: .whitespaces).isEmpty && cue.end > cue.start {
            let shown = cue.displayText
            var stretches: [(highlight: Int?, start: Double, end: Double)] = [(nil, cue.start, cue.end)]
            if style.accentColor != nil {
                let starts = wordStarts(cue).filter { $0 >= cue.start && $0 < cue.end }
                if !starts.isEmpty {
                    stretches = starts.indices.map { i in
                        (i, i == 0 ? cue.start : starts[i], i + 1 < starts.count ? starts[i + 1] : cue.end)
                    }
                }
            }
            for stretch in stretches where stretch.end > stretch.start {
                let container = captionLayer(text: shown, highlight: stretch.highlight, style: style,
                                             anchor: cue.anchor ?? anchor, render: render)
                container.opacity = 0
                let show = CABasicAnimation(keyPath: "opacity")
                show.fromValue = 1
                show.toValue = 1
                show.beginTime = stretch.start <= 0 ? AVCoreAnimationBeginTimeAtZero : stretch.start
                show.duration = stretch.end - stretch.start
                show.isRemovedOnCompletion = false
                container.add(show, forKey: "visible")
                overlay.addSublayer(container)
            }
        }
        return overlay
    }

    // MARK: Overlays

    /// One title or picture as it goes on the video, in render space, at
    /// full opacity; the caller sets when it shows. Nil when a picture
    /// can't be read.
    @MainActor
    static func overlayLayer(_ overlay: Overlay, image: NSImage?, render: CGSize = renderSize) -> CALayer? {
        switch overlay.kind {
        case .text:
            let shown = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shown.isEmpty else { return nil }
            let layer = captionLayer(text: shown, style: overlay.captionStyle, anchor: overlay.anchor, render: render)
            layer.opacity = Float(overlay.opacity)
            return layer
        case .image:
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let frame = pictureFrame(for: overlay, image: image, render: render)
            let layer = CALayer()
            layer.contents = cg
            layer.contentsGravity = .resizeAspect
            layer.frame = frame
            layer.opacity = Float(overlay.opacity)
            return layer
        }
    }

    /// Where a picture overlay sits in a `render`-sized frame: `width` of
    /// the frame wide, its own shape, centred on its anchor and kept inside.
    static func pictureFrame(for overlay: Overlay, image: NSImage?, render: CGSize = renderSize) -> CGRect {
        let aspect = (image?.size.width ?? 1) / max(1, image?.size.height ?? 1)
        let width = render.width * CGFloat(overlay.width)
        let height = width / max(0.05, aspect)
        let centre = CGPoint(x: render.width * overlay.anchor.x, y: render.height * overlay.anchor.y)
        return CGRect(x: min(max(0, centre.x - width / 2), max(0, render.width - width)),
                      y: min(max(0, centre.y - height / 2), max(0, render.height - height)),
                      width: width, height: height).integral
    }

    /// Every title and picture, each visible only for its own stretch of
    /// the video, the way `captionOverlay` schedules captions.
    @MainActor
    static func overlaysLayer(for overlays: [Overlay], duration: Double, images: (Overlay) -> NSImage?,
                              render: CGSize = renderSize) -> CALayer {
        let all = CALayer()
        all.frame = CGRect(origin: .zero, size: render)
        for overlay in overlays {
            guard let layer = overlayLayer(overlay, image: images(overlay), render: render) else { continue }
            let start = max(0, overlay.start)
            let end = min(overlay.end ?? duration, duration)
            guard end > start else { continue }
            let wrapper = CALayer()
            wrapper.frame = all.frame
            wrapper.opacity = 0
            wrapper.addSublayer(layer)
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = start <= 0 ? AVCoreAnimationBeginTimeAtZero : start
            show.duration = end - start
            show.isRemovedOnCompletion = false
            wrapper.add(show, forKey: "visible")
            all.addSublayer(wrapper)
        }
        return all
    }

    // MARK: Export

    /// Writes the project as an H.264 MP4 at its format's size, captions,
    /// titles and pictures burned in, the song mixed under. `progress` is
    /// called on the main actor with 0…1.
    @MainActor
    static func export(_ project: VideoProject, style: CaptionStyle, to url: URL,
                       images: @escaping (Overlay) -> NSImage? = { _ in nil },
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        let timeline = try await build(project)
        let render = project.renderSize

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: render)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        parent.addSublayer(captionOverlay(for: project.timelineCues, style: style, anchor: project.captionAnchor,
                                          render: render) { project.wordStarts(for: $0) })
        parent.addSublayer(overlaysLayer(for: project.overlays, duration: project.duration, images: images, render: render))
        timeline.videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        guard let session = AVAssetExportSession(asset: timeline.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed("no export session")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = timeline.videoComposition
        session.audioMix = audioMix(for: project, timeline: timeline)
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true

        let poll = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await session.export()
        poll.cancel()
        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            throw Failure.cancelled
        default:
            throw Failure.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }
}
