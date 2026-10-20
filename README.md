# BlackHoleDelete — "Clear History" as a black hole from the Dynamic Island

When the whole chat history is cleared, the Dynamic Island opens into a black hole with a
light ring, the wallpaper bends towards it, and all visible messages are pulled in along an arc,
stretching near the horizon ("spaghettification"). The hole then lands back into the island with a
small spring, and the regular "Chat cleared" toast appears.

Pure UIKit + Metal, no SwiftUI, no dependencies. iOS 15+.

▶︎ [Media/demo.mp4](Media/demo.mp4) — the effect in the full prototype (selection by two-finger
swipe → Delete All → Delete for me and Ava → black hole → Undo).

## Repository

| Path | What |
|---|---|
| `BlackHoleDelete/` | Drop-in Telegram-iOS module (`submodules/TelegramUI/Components/Chat/BlackHoleDelete`). |
| `BlackHoleDelete/BUILD` | Bazel target; the shader is compiled into `default.metallib` inside a resource bundle. |
| `BlackHoleDelete/Sources/BlackHoleTimeline.swift` | Config, Dynamic Island geometry, timing of a run, hole shape at time `t`. Pure Swift. |
| `BlackHoleDelete/Sources/BlackHoleDeleteAnimator.swift` | Public API: three Metal views + one `CADisplayLink`; renderer and pipelines. |
| `BlackHoleDelete/Resources/BlackHole.metal` | Shaders: backdrop (wallpaper lens, twist, shade, bloom), mesh (messages), overlay (black shape + ring). |
| `BlackHoleDelete/Resources/BlackHoleDisk.png` | Light ring texture (2000×1000; shadow center 1000,451, radius 223 px). |
| `Integration/ChatControllerBlackHoleClear.swift` | Integration into `ChatControllerImpl` (TelegramUI). |
| `Demo/` | Standalone UIKit demo — builds and runs in the simulator without an Xcode project. |
| `Media/demo.mp4` | Recording of the full prototype (1206×2622, 60 fps). |

## How it works

Three full-screen views share one display link and one coordinate space (their superview):

```
wallpaper
  backdropView   opaque copy of the wallpaper snapshot: lens towards the hole, twist, deep shade, bloom
history (hidden)
  meshView       message snapshots on a ~6 pt grid; vertices follow a flow towards the hole
navigation bar   (fade it out while state.presence > 0.12)
  overlayView    black island shape (capsule → circle) and the ring from BlackHoleDisk.png
```

* **Opening / closing.** The island capsule morphs into a circle of `holeRadius` around its own
  center (`BlackHoleState.at`). Closing lands exactly on the island shape and bulges outward with a
  damped spring, like an app flying into the Dynamic Island. At rest the shape is 1.5 pt smaller than
  the system island, so removing the views never shows a jump.
* **Swallowing.** Flow speed is fitted so the farthest message fades exactly after
  `swallowDuration`; upper messages land first. Speed grows near the horizon
  (`pullStrength`, `pullReach`), so messages stretch; near the halo they heat up with the ring's
  light, blur (mip levels) and dissolve.
* **Ring.** The clean upper arc of the texture is mapped around the circle; the brightest band is
  pulled to the horizon (`ringGamma`); fibers spin clockwise, faster near the horizon (`innerBoost`).
* **Time** advances per frame with a capped step (1/30 s): after a dropped frame the animation
  continues from where it was instead of jumping.

## Integration into Telegram-iOS

1. **Module.** Copy the `BlackHoleDelete/` folder to
   `submodules/TelegramUI/Components/Chat/BlackHoleDelete/` as is.
   `apple_resource_bundle` compiles the shader into `default.metallib` inside
   `BlackHoleDeleteResourcesBundle.bundle`; `BlackHoleDeleteAnimator.resourceBundle()` finds it.
2. **TelegramUI.** Add `"//submodules/TelegramUI/Components/Chat/BlackHoleDelete"` to `deps` in
   `submodules/TelegramUI/BUILD` and put `Integration/ChatControllerBlackHoleClear.swift` into
   `submodules/TelegramUI/Sources/Chat/`.
3. **Hook.** In `ChatControllerImpl.beginClearHistory(type:)` (`ChatController.swift`), capture before
   the selection is reset and the history is hidden, and show the toast through the animation:

   ```swift
   public func beginClearHistory(type: InteractiveHistoryClearingType) {
       guard case let .peer(peerId) = self.chatLocation else {
           return
       }
       // Snapshots must be taken before the selection is reset and the history is hidden.
       let runBlackHoleClearAnimation = self.prepareBlackHoleClearAnimation()
       self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
       self.chatDisplayNode.historyNode.historyAppearsCleared = true
       ...
       let presentUndo: () -> Void = { ... /* existing UndoOverlayController code */ }

       if let runBlackHoleClearAnimation {
           runBlackHoleClearAnimation(presentUndo)
       } else {
           presentUndo()
       }
   }
   ```
4. **Prewarm (recommended).** The first run compiles pipelines and allocates full-screen drawables
   (~0.1 s). Create the animator when the chat opens and call `prewarm()` after its views are in the
   hierarchy, or at least call `prewarm()` when the clear-history sheet is shown.

### What the integration does

* Snapshots every visible message node with `layer.render(in:)` (only the node's own layers;
  `drawHierarchy` would also capture the navigation bar above the history) and the wallpaper node.
* Freezes the history with `snapshotView(afterScreenUpdates: false)` until the first animated frame
  (textures are prepared off the main thread, ~tens of ms).
* Inserts the three views into `historyNodeContainer.superview`: backdrop above `backgroundNode`,
  mesh above the history, overlay on top (above the navigation bar).
* `presence > 0.12`: fades the navigation bar out and hides the status bar
  (`statusBar.updateStatusBarStyle(.Hide, …)`); when it drops — brings both back
  (`updateStatusBarPresentation`) and presents the "Chat cleared" undo toast at the same moment.

### Status bar

The hole covers the status bar area, so the status bar has to go while it is open. Every toggle of
the system status bar costs UIKit a dropped frame; doing it at the bar threshold (beginning of the
opening, end of the closing) keeps the drops outside the fast part of the motion.

## Standalone demo

```sh
Demo/build-demo.sh "iPhone 18 Pro"     # builds with swiftc + metal, installs, launches
xcrun simctl launch --terminate-running-process "iPhone 18 Pro" demo.blackholedelete.kit -autoplay YES
```

Tap "Clear History" (or `-autoplay YES` to repeat every 5 s). `BLACKHOLE_DEBUG_FRAMES=1` in the
environment logs frames longer than 25 ms.

## Parameters

`BlackHoleConfig` — defaults are the tuned values from the prototype:

| Parameter | Default | Meaning |
|---|---|---|
| `holeRadius` | 90 pt | Radius of the open hole |
| `emergeDuration` / `collapseDuration` | 0.8 / 0.3 s | Opening / closing |
| `collapseBounce`, `settleDuration` | 0.35, 0.34 s | Island bulge after landing |
| `swallowDuration` | 1.15 s | How long the swallowing lasts |
| `swallowLead` | 0.1 | Swallowing starts at this fraction of the opening |
| `pullStrength`, `pullReach` | 3, 0.8 r | Acceleration near the horizon |
| `flowRamp`, `flowAccel` | 0.35 s, 8 | Smooth start, acceleration over time |
| `arcShape` | 1 | 1 — straight edges, > 1 — edges wrap the arc |
| `fadeOuter`, `fadeInner`, `fadeBlur` | 1.6 r, 1.03 r, 14 pt | Fade and blur near the horizon |
| `ringBrightness`, `ringSpeed`, `innerBoost` | 1.03, 2, 4.5 | Ring light and spin |
| `ringSqueeze`, `ringGamma`, `ringSoftness` | 0.7, 0.75, 1.2 | Ring width, bright band position, fiber softness |
| `glow`, `lensStrength` | 0.82, 1.5 | Bloom, wallpaper lens |
| `spaceDarkness`, `spaceSize` | 0.55, 2 r | Wallpaper shade around the hole |
| `backgroundSwirl`, `backgroundSpin` | 0.9 rad, 0.8 rad/s | Wallpaper twist |

## Notes and limits

* Dynamic Island frames are measured on simulator screenshots (iPhone 14 Pro … 18 Pro). Prefer the
  real frame from device metrics if available. Devices without an island: the hole grows from a
  capsule just above the screen.
* Snapshots are static: animated stickers and videos are frozen on the frame at the start.
* Reduce Motion: the integration returns nil and the regular clearing is used.
* Secret chats: skipped (same as the snapshot policy of the history container).
