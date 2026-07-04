# NikonFieldMonitor — iOS native layer

This directory contains the iOS Swift/Metal implementation of the
`nikon_field_monitor/render` and `nikon_field_monitor/usb_ptp` platform
channels. The Dart side lives in `lib/native_bridge/`; the Android
counterparts live in `android/app/src/main/kotlin/com/nikonfieldmonitor/`.

> **Build host OS:** iOS builds **require macOS** with Xcode 15+ and the
> Flutter SDK (3.19+). **Linux and Windows cannot build iOS** — there is no
> cross-compiler. If you are developing on Linux, edit the Swift files here
> but run the build on a macOS machine (or a CI runner such as
> GitHub Actions `macos-latest`).

The iOS port uses **Metal** (iOS does not permit OpenGL ES for new apps).
The 5-pass LiveView GPU pipeline is a 1:1 port of the Android GL pipeline —
see `Runner/LiveViewRenderer.swift` and the comments in
`Runner/Shaders/*.metal` for the pass-by-pass parity notes.

---

## File map

| File | Purpose |
| --- | --- |
| `Runner/AppDelegate.swift` | App entry point. Registers `GeneratedPluginRegistrant` (pub plugins) + our two custom plugins (`RenderPlugin`, `UsbPtpPlugin`). |
| `Runner/RenderPlugin.swift` | `FlutterPlugin` + `FlutterStreamHandler` for `nikon_field_monitor/render` + `/render/events`. Owns the Metal device + command queue + render dispatch queue. One `RendererEntry` (conforms to `FlutterTexture`) per `createTexture()` call. Toggles `UIApplication.isIdleTimerDisabled` while LiveView is active. |
| `Runner/LiveViewRenderer.swift` | The 5-pass Metal pipeline (JPEG decode → LUT/FalseColor → Peaking → Zebra → Present). Ping-pong RGBA8Unorm intermediates; final pass swizzles RGBA→BGRA into the Flutter CVPixelBuffer. `MonitorAssistSettings` struct mirrors Dart's `toBridgeMap()`. |
| `Runner/ShaderProgram.swift` | Wraps one `MTLRenderPipelineState` per pass. Loads `default.metallib` (compiled by the Metal Run Script build phase, see below). |
| `Runner/UsbPtpPlugin.swift` | iOS stub for `nikon_field_monitor/usb_ptp`. `getPlatformVersion` returns the iOS version; every USB method returns `FlutterError(code: "platformVersion", message: "not-supported", ...)`. iOS USB-C camera access requires MFi + ExternalAccessory framework. |
| `Runner/Shaders/passthrough_vertex.metal` | Vertex shader. Pulls interleaved `(x,y,u,v)` from a `device const VertexIn*` buffer by `[[vertex_id]]`. `uFlipY` in `[[buffer(1)]]` (kept identical to the GLSL uniform name). |
| `Runner/Shaders/lut_fragment.metal` | 3D LUT (2D-packed, trilinear along B) + `passthrough_fragment` (RGBA→RGBA) + `present_fragment` (RGBA→BGRA swizzle for the Flutter CVPixelBuffer). |
| `Runner/Shaders/peaking_fragment.metal` | Sobel 3×3 focus peaking. Threshold mapping 0→0.18 / 1→0.10 / 2→0.05 (identical to GLSL). |
| `Runner/Shaders/zebra_fragment.metal` | IRE banding with 45° diagonal stripes (`fmod(px.x + px.y, 8.0)`). |
| `Runner/Shaders/falsecolor_fragment.metal` | Anchor-point false-color palette (purple→green→magenta→yellow→red). |
| `Runner/Info.plist` | Bundle + privacy keys. Includes `NSLocalNetworkUsageDescription` (PTP-IP UDP broadcast on port 15740), `NSBonjourServices`, `MinimumOSVersion: 14.0`, `ITSAppUsesNonExemptEncryption: false`. |
| `Runner/Base.lproj/LaunchScreen.storyboard` | Launch screen with a pure-black background (no flash transition into the LiveView UI). |
| `Runner/Runner-Bridging-Header.h` | Empty. The project is pure-Swift; no ObjC sources in Runner. |
| `Podfile` | `platform :ios, '14.0'` + standard Flutter pod helper (`flutter_install_all_ios_pods`). |
| `Flutter/AppFrameworkInfo.plist` | Flutter framework info plist, `MinimumOSVersion: 14.0`. |

---

## Build instructions (from a clean checkout)

The repo does not ship a generated `Runner.xcodeproj` (Xcode project files
are machine-specific and noisy in diffs). Scaffold it from the Flutter
template, then drop the hand-written files in.

### 0. Prerequisites

- **macOS** (Ventura 13.5 or later). Linux/Windows cannot build iOS.
- **Xcode 15+** with the iOS 17 SDK installed. Install command-line tools:
  `xcode-select --install`.
- **Flutter SDK 3.19+** on your `PATH`. Verify with `flutter doctor` — all
  green for iOS toolchain.
- **CocoaPods 1.13+** (`sudo gem install cocoapods` or `brew install cocoapods`).
- An Apple Developer account (free account works for simulator + a personal
  device; a paid team is required for App Store / TestFlight distribution).

### 1. Scaffold the iOS project

From the **repo root** (`/workspace/nikon_field_monitor/` — the directory
that contains `pubspec.yaml`):

```bash
cd /workspace/nikon_field_monitor
flutter pub get
flutter create --platforms=ios --org com.nikonfieldmonitor .
```

`flutter create` will:
- Create `ios/Runner.xcodeproj`, `ios/Runner.xcworkspace`, and the supporting
  files (`GeneratedPluginRegistrant.h/.m`, `Runner/Generated.xcconfig`, etc.)
  that the hand-written files in this directory reference.
- Leave your existing `pubspec.yaml` and `lib/` untouched.
- Leave the existing `ios/Runner/*.swift` and `ios/Runner/Shaders/*.metal`
  files **alone** (it does not overwrite files that already exist on disk),
  but it will **not** automatically add them to the new Xcode project.

### 2. Reconcile the scaffolded files with the hand-written ones

The hand-written files in this directory are the source of truth. After
`flutter create`, do the following for any file that exists in **both** the
scaffold and this directory:

```bash
# From the repo root. These hand-written files override the scaffold defaults.
cd /workspace/nikon_field_monitor

# Overwrite the scaffolded defaults with our hand-written versions.
# (The files in this directory are the source of truth — git already tracks
# them, so this step is a no-op if you ran `flutter create` inside an
# existing checkout. It only matters if `flutter create` regenerated them.)

# Verify the four Swift files + Info.plist + storyboard + bridging header
# + Podfile + AppFrameworkInfo.plist are present:
ls ios/Runner/AppDelegate.swift \
   ios/Runner/RenderPlugin.swift \
   ios/Runner/LiveViewRenderer.swift \
   ios/Runner/ShaderProgram.swift \
   ios/Runner/UsbPtpPlugin.swift \
   ios/Runner/Info.plist \
   ios/Runner/Base.lproj/LaunchScreen.storyboard \
   ios/Runner/Runner-Bridging-Header.h \
   ios/Runner/Shaders/*.metal \
   ios/Podfile \
   ios/Flutter/AppFrameworkInfo.plist
```

If `flutter create` overwrote `Info.plist`, `AppDelegate.swift`,
`LaunchScreen.storyboard`, `Runner-Bridging-Header.h`, `Podfile`, or
`Flutter/AppFrameworkInfo.plist` with its defaults, restore them from git:

```bash
git checkout -- ios/Runner/AppDelegate.swift \
                  ios/Runner/Info.plist \
                  ios/Runner/Base.lproj/LaunchScreen.storyboard \
                  ios/Runner/Runner-Bridging-Header.h \
                  ios/Podfile \
                  ios/Flutter/AppFrameworkInfo.plist
```

### 3. Add the Swift + Metal sources to the Xcode project

Open the workspace:

```bash
open ios/Runner.xcworkspace
```

In Xcode's Project Navigator (left pane):

1. **Add the Swift files** — drag each of these into the `Runner` group
   (the yellow folder icon), and in the "Choose options for adding these
   files" dialog check **Copy items if needed: NO** (they're already in the
   right place on disk) and **Add to targets: Runner**:
   - `RenderPlugin.swift`
   - `LiveViewRenderer.swift`
   - `ShaderProgram.swift`
   - `UsbPtpPlugin.swift`

   (`AppDelegate.swift` already exists in the scaffold — **replace** its
   contents with ours rather than adding a second copy, otherwise you'll get
   a duplicate-symbol error from `@main`.)

2. **Add the Metal shaders** — first create a group called `Shaders` under
   `Runner` (File → New → Group). Then drag all five `.metal` files into it,
   again with **Copy items if needed: NO** and **Add to targets: Runner**:
   - `passthrough_vertex.metal`
   - `lut_fragment.metal`
   - `peaking_fragment.metal`
   - `zebra_fragment.metal`
   - `falsecolor_fragment.metal`

3. **Verify the bridging header is wired** — select the `Runner` target →
   Build Settings → search for `Objective-C Bridging Header`. It should be
   set to `Runner/Runner-Bridging-Header.h` (the file already exists in this
   directory). If blank, set it.

### 4. Add the Metal Run Script build phase

> **Xcode 15+ auto-compiles `.metal` files** that are members of the
> `Compile Sources` phase into `default.metallib` and bundles it
> automatically. **If you added the `.metal` files via Step 3 above, no Run
> Script phase is strictly required** — skip to Step 5 to verify.

If for some reason `device.makeDefaultLibrary()` returns nil at runtime
(`RenderPlugin` will log `"default.metallib not found"`), add an explicit
Run Script build phase:

1. Select the `Runner` target → Build Phases → **+** → New Run Script Phase.
2. Drag the new phase **above** `Link Binary With Libraries` (or at least
   above `Copy Bundle Resources`).
3. Name it `Compile Metal Shaders`.
4. Set the shell script to (leave the shell as `/bin/sh`):

   ```bash
   set -e
   # Locate the Metal compiler for the target SDK.
   METAL="$XCRUN --find metal"
   METALLIB="$XCRUN --find metallib"

   SHADER_DIR="$SRCROOT/Runner/Shaders"
   BUILD_DIR="$DERIVED_FILE_DIR/MetalBuild"
   mkdir -p "$BUILD_DIR"

   for src in "$SHADER_DIR"/*.metal; do
     "$METAL" -sdk "$PLATFORM_NAME" -target "$METAL_TARGET" \
       -I "$SHADER_DIR" -c "$src" -o "$BUILD_DIR/$(basename "${src%.metal}").air"
   done

   "$METALLIB" "$BUILD_DIR"/*.air -o "$BUILT_PRODUCTS_DIR/default.metallib"
   ```

5. Add the output `default.metallib` to **Copy Bundle Resources** if it's
   not picked up automatically (it usually is, because the file lands in
   `$BUILT_PRODUCTS_DIR`).

### 5. Configure signing

1. Select the `Runner` target → Signing & Capabilities.
2. Check **Automatically manage signing**.
3. Team: pick your Apple Developer team.
4. Bundle Identifier: `com.nikonfieldmonitor` (must match the
   `applicationId` in `android/app/build.gradle.kts`).
5. Repeat for any test targets if present.

### 6. Install pods and build

From the repo root:

```bash
cd /workspace/nikon_field_monitor
flutter clean           # optional, but recommended after scaffolding
flutter pub get
cd ios && pod install --repo-update && cd ..
```

Then either:

```bash
# Run on a connected device (recommended — Metal on the simulator is
# limited and the LiveView pipeline runs much better on real silicon):
flutter run --release

# Or build an IPA for distribution:
flutter build ipa --release
# Output: build/ios/ipa/nikon_field_monitor.ipa
```

For opening in Xcode directly (e.g. to attach the Metal debugger):

```bash
open ios/Runner.xcworkspace
# In Xcode: select the Runner scheme + a device, then Cmd+R.
```

---

## Verifying the Metal pipeline at runtime

The EventChannel `nikon_field_monitor/render/events` emits
`frameStats` events (~1/sec) once frames are flowing. In the Xcode console
you should see no `"[RenderPlugin] default.metallib not found"` and no
`"[RendererEntry] init failed"` messages. If `default.metallib` is missing,
revisit Step 4.

To capture a GPU frame for debugging: Xcode → Debug → Capture GPU Work
(if the device supports Metal GPU frame capture) — each render pass is
labelled (`LiveViewRenderer.lut`, `.peaking`, `.zebra`, `.present`, etc.)
via `enc.pushDebugGroup`.

---

## Architecture notes

### Why Metal (not OpenGL ES)

iOS does not allow OpenGL ES for new apps since iOS 12 / Xcode 14. The
Android counterpart (`LiveViewRenderer.kt`) uses GL ES 2.0 with FBO
ping-pong; the iOS port replicates the same 5-pass pipeline in Metal. The
shader math is identical (uniform names preserved across the port —
`uTexture`, `uLut`, `uLutSize`, `uEnabled`, `uTexelSize`, `uOverlayColor`,
`uSensitivity`, `uResolution`, `uLowerIre`, `uUpperIre`, `uFlipY`) so the
renderer logic matches Android 1:1.

### Ping-pong textures

Metal forbids reading from and writing to the same `MTLTexture` in a single
render pass (unlike GL's FBO self-read, which is undefined behaviour that
happens to work on most Android drivers). `LiveViewRenderer` keeps two
intermediate RGBA8Unorm textures (`texA`, `texB`) and swaps between them
after each assist pass.

### Final BGRA swizzle

Flutter's iOS `Texture` widget samples `kCVPixelFormatType_32BGRA`. The
pipeline keeps everything in RGBA8Unorm internally, then the `present`
pass (`present_fragment` in `lut_fragment.metal`) swizzles RGBA→BGRA on
the way out so the displayed pixel is R=src.r, G=src.g, B=src.b.

### Coordinate convention

Metal textures are top-left origin (vs GL's bottom-left). The vertex
shader (`passthrough_vertex.metal`) honours a `uFlipY` uniform — the
renderer passes `uFlipY=1` on every pass so the image stays right-side-up
across the ping-pong chain. The uniform name + semantics are kept identical
to the GLSL original.

### USB PTP on iOS

iOS does not expose USB-C camera access to third-party apps without MFi
enrolment + the ExternalAccessory framework, and Nikon Z-series bodies are
not MFi-certified for this app's case. `UsbPtpPlugin.swift` is therefore a
stub: `getPlatformVersion` returns the iOS version string; every other
method returns `FlutterError(code: "platformVersion",
message: "not-supported", ...)`. The Dart side
(`lib/native_bridge/usb_ptp_bridge.dart`) catches the `PlatformException`
and presents an "unsupported on iOS" UI. PTP-IP (Wi-Fi) is the only
supported camera transport on iOS — see `lib/ptp/ptp_ip_client.dart`.

### LiveView keep-awake

`RenderPlugin.register(with:)` installs an `onLiveViewActiveChanged`
closure that flips `UIApplication.shared.isIdleTimerDisabled` whenever the
count of active LiveView textures transitions between zero and non-zero.
This mirrors Android's `FLAG_KEEP_SCREEN_ON` (handled in
`RenderPlugin.kt`). No additional configuration is needed in
`AppDelegate.swift`.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `default.metallib not found` in the Xcode console | The `.metal` files were not added to the `Runner` target's Compile Sources (Step 3) OR the Run Script phase (Step 4) didn't run. Re-add them. |
| `Vertex function 'passthrough_vertex' not found` | The `.metal` file is in the project but not in Compile Sources. Check Build Phases → Compile Sources. |
| `CVMetalTextureCacheCreateTextureFromImage failed` | The CVPixelBuffer pool wasn't created with `kCVPixelBufferMetalCompatibilityKey: true` — already set in `RenderPlugin.swift`; if you see this, the device is too old (pre-A7, i.e. pre-iPhone 5s). Bump MinimumOSVersion or use a newer device. |
| `pod install` fails with `MinimumOSVersion` mismatch | Run `pod install --repo-update` and ensure `platform :ios, '14.0'` is in `Podfile`. |
| Local network prompt never appears / discovery finds nothing | On iOS 14+ the user must accept the local-network permission prompt the first time `discoverPtpIpCameras()` runs. If they decline, settings → Privacy → Local Network → re-enable for NikonFieldMonitor. |
| Black Texture widget on simulator | The iOS simulator's Metal support is incomplete on some macOS versions. Run on a physical device. |
| `EXCLUDED_ARCHS` / `arm64` simulator linker error | You're on an older Flutter template that still excludes arm64 from the simulator. Delete the `EXCLUDED_ARCHS[sdk=iphonesimulator*]` line from the Podfile post_install block — our Podfile does not include it (Xcode 15+ supports Apple Silicon simulators natively). |

---

## Cross-references

- Android counterparts: `android/app/src/main/kotlin/com/nikonfieldmonitor/render/`
  (`RenderPlugin.kt`, `LiveViewRenderer.kt`, `ShaderProgram.kt`) and
  `android/app/src/main/kotlin/com/nikonfieldmonitor/usb/UsbPtpPlugin.kt`.
- Dart bridges: `lib/native_bridge/native_render_bridge.dart`,
  `lib/native_bridge/usb_ptp_bridge.dart`.
- Settings model: `lib/models/monitor_assist_settings.dart` (the `toBridgeMap()`
  keys are mirrored verbatim in `MonitorAssistSettings` inside
  `LiveViewRenderer.swift`).
- GLSL originals (for shader port verification): `shaders/passthrough.vert`,
  `shaders/lut.frag`, `shaders/peaking.frag`, `shaders/zebra.frag`,
  `shaders/falsecolor.frag`.
