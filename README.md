# ReelFlow

A simple Mac video editor that turns long recordings into captioned clips
for Instagram Reels, TikTok, YouTube Shorts and the rest. Import your takes,
trim, auto-subtitle on-device, pick a frame shape and style, export.

ReelFlow started as the Peeky Video tab inside MyClicky and is now its own app.

## Build and run

```
scripts/build-app.sh
```

builds a release binary, packages `ReelFlow.app`, installs it to
`/Applications` and launches it. For a quick dev run without packaging:

```
swift run ReelFlow
```

Tests:

```
swift test
```

## Layout

- `Sources/ReelFlow/ReelFlowApp.swift` — the app: one window hosting the editor.
- `Sources/ReelFlow/Editor/` — the editor: project model, view, transcriber,
  exporter, subtitle styles, frame formats.
- `Tests/ReelFlowTests/` — unit tests for the project model and editor math.
- `Resources/Info.plist` — bundle identity and privacy usage strings.

Projects are saved under `~/Movies/ReelFlow Projects`.

Requires macOS 14 or later.
