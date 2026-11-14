# System Screen Recorder

A macOS GUI screen recorder that saves the main display and system audio to an MP4 file. It does not record microphone input. Start and stop recording from the window; recording time is not capped. Each recording prompts for a save location, and existing files are not overwritten.

Requires macOS 13 or later and Swift 5.9 or later. The first run may require granting Screen Recording access to the app in **System Settings → Privacy & Security → Screen & System Audio Recording**.

To build a drag-and-drop disk image containing the app bundle and an Applications shortcut:

```sh
./scripts/build-dmg.sh
```

The disk image is written to `dist/System Screen Recorder.dmg`. The app is ad-hoc signed, not Developer ID signed or notarized, so macOS may require approval before opening it.

```sh
swift run system-screen-recorder
```
