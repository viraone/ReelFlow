# Notes for Peeky

## Facts

- ReelFlow is a native macOS SwiftUI app built with Swift Package Manager: `swift build` compiles it and `swift run` launches it. Peeky cannot run or see the app, so a cause read from the code is only a hypothesis until the running app confirms it.
- The way to confirm a UI cause is temporary `print("PEEKY-PROBE …")` lines: the user runs `swift run`, does the action, and pastes the lines from Terminal. Remove the probes once the fix is confirmed.
- In `VideoEditorView.swift` the editor is one VStack: header, coach line, the editor row (rail + tool panel + canvas), the timeline grip, then the timeline dock.
- The timeline grip changes `timelineExtra` (persisted in `@AppStorage("reelflowTimelineExtra")`, so a bad value survives relaunch). It drives `clipHeight` and `filmHeight`, so the dock's height follows it directly.
- The editor row cannot shrink below the rail (8 tool buttons × 44pt + spacing ≈ 388pt) or the canvas floor (160pt picture + 44pt bar + 12pt gap). When the dock grows past what is left, SwiftUI overflows the VStack downward and the dock hangs below the window instead of the grip moving.
- The rail item height, spacing and padding and the canvas floor are shared statics on VideoEditorView (`railItemHeight`, `railSpacing`, `railPadding`, `previewMinHeight`, `canvasBarHeight`, `canvasSpacing`); `editorRowMinHeight` is computed from them. Change the rail or canvas sizes through those, never with a new literal.
- Every tool panel's content sits in a `ScrollView(showsIndicators: false)` so no panel can set the row's minimum height. Keep new panels that way.
- Mouse handling for grips and handles is `MouseHandle`, an NSViewRepresentable: `onDrag` receives the translation since mouse-down in view points (y grows downward); hover turns the grip blue and the cursor into the up/down resize arrow.

## Decisions

- The grip's range is measured, not computed from constants: at drag start it is `timelineExtra` plus how much the editor row is taller than `editorRowMinHeight`. The dock checks its own bottom edge against the editor in the "editor" coordinate space and takes back whatever overflows (also on window resize and on launch).
- Dragging the grip down to `minTimelineExtra` (−36) lets the clip strip shrink from 84pt to 48pt; the video keeps roughly 200pt.
- "The grip won't drag" (Sept 2026) was never a broken drag: the drag and the value worked; the timeline grew off the bottom of the window because the Trim panel (no ScrollView) and the rail held the row at 635pt. Two edits to `maxTimelineExtra` and the clamp changed nothing because they were not the cause.
