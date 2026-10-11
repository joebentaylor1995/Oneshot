# Oneshot

A native Mac screen recorder in the spirit of Screen Studio. Record, and the result already looks polished: your screen sits on a background with padding, rounded corners and a shadow, the cursor is re-rendered smooth and sharp, and the camera zooms in automatically where you click.

This is phase 1 (the core look). Camera, captions, transcript editing and share links are planned for later phases.

## What's in it

**Recording**
- Area, window or full display (menu bar, or **⌘⇧2** from anywhere)
- Microphone and system audio, each on its own track
- 3, 2, 1 countdown (toggle in the menu)
- Stop from the menu bar (shows elapsed time) or **⌘⇧2** again
- The cursor is *not* baked into the video. Its position, clicks and shape are recorded separately, so everything about it can be changed afterwards.

**Look**
- Backgrounds: gradients, the macOS wallpapers, a solid colour or your own image
- Padding, corner radius, shadow strength and size
- Aspect ratio: Auto, 16:9, 4:3, 1:1, 9:16

**Cursor**
- Size (sharp at any size, captured at 4×), smoothing, motion blur
- Click effect: ripple or circle
- Hides when idle, fades back when it moves

**Zoom**
- Automatic zooms built from your clicks when a recording opens
- Add zooms by double-clicking the zoom track or pressing **Z**
- Per zoom: level (1.2× to 4×), follow cursor or a fixed focus point you click to set
- Eased zoom in/out, camera smoothness setting

**Timeline**
- Trim start and end (yellow handles)
- Cuts (**C**) and speed-ups (**S**, 1.25× to 8×), drag to move, drag edges to resize
- **Space** play/pause, **← / →** step a frame, **⌫** delete selected, click/drag the ruler or filmstrip to scrub
- Everything autosaves; reopen any recording from **Open Recent**

**Export** (**⌘E**)
- MP4: 720p, 1080p or 4K at 24, 30, 60 or 120 fps (H.264; 4K uses HEVC)
- GIF: 480p, 720p or 1080p at 15, 20 or 30 fps
- Drag the finished file into Slack, Finder, Mail, Figma…, or Copy / Show in Finder

## Requirements

- macOS 15 Sequoia or later (needed for ScreenCaptureKit microphone capture)
- Xcode 16 or later (or its Command Line Tools) for `swift build`

## Build and install

```bash
cd oneshot-app
chmod +x build.sh
./build.sh install
```

That compiles, assembles `Oneshot.app`, signs it ad-hoc, copies it to `/Applications` and launches it. Look for the record icon in the menu bar.

**Permissions.** First recording asks for Screen Recording (and Microphone if you picked one). Allow Oneshot in System Settings › Privacy & Security, then quit and reopen Oneshot.

**Rebuilding.** With ad-hoc signing macOS treats each build as a new app, so Screen Recording needs re-allowing. Toggle Oneshot off and on in that settings pane, or run:

```bash
tccutil reset ScreenCapture com.joebentaylor.oneshot
```

Signing with an Apple Development certificate avoids this (see the top of `build.sh`).

## Where things go

```
~/Movies/Oneshot/
  Recording 2026-10-10 at 00.12.33.mp4      exports
  Projects/
    Recording 2026-10-10 at 00.12.33/
      screen.mov       raw video + audio tracks
      cursor.json      cursor positions, clicks, shape changes
      cursors/*.png    cursor images captured during recording
      recording.json   size, scale, duration
      edits.json       your edits (autosaved)
```

## How it works

| File | Role |
| --- | --- |
| `AppDelegate.swift` | Menu bar, recording flow, mic / audio / countdown settings, recent projects |
| `RegionSelector.swift` | Area / window / display picker overlays and the recording outline |
| `ScreenRecorder.swift` | ScreenCaptureKit → HEVC `.mov` with system audio and mic tracks, cursor hidden |
| `CursorRecorder.swift` | 120 Hz cursor + click sampling, cursor shape capture |
| `HotKey.swift`, `Countdown.swift` | ⌘⇧2 global shortcut, 3-2-1 overlay |
| `Project.swift` | Data model and project folders |
| `TimeMapping.swift` | Trim / cuts / speed → AVComposition, source ↔ output time |
| `Motion.swift` | Spring-smoothed cursor path, zoom camera, auto zoom from clicks |
| `Compositor.swift`, `Backgrounds.swift` | Core Image renderer used by both preview and export |
| `EditorModel.swift`, `EditorView.swift`, `EditorTimeline.swift`, `InspectorView.swift` | Editor |
| `ExportModel.swift`, `ExportView.swift`, `ShareViews.swift` | MP4 / GIF export, drag and drop |

One Core Image video composition renders every frame for the live preview *and* the export, so what you see is exactly what you get. Zooms, cursor data and clicks are stored in recording time, so cutting or speeding up sections never knocks them out of place.

## Known gaps vs Screen Studio (planned)

- Window mode records the window's area at the moment you start; it doesn't follow the window if you move it
- No pause/resume yet
- No webcam, captions/transcript editing, keyboard shortcut overlay, masks, noise reduction, background music or share links yet
- The timeline shows recording time (cuts appear as red regions) rather than collapsing them
