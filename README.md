# RAW Camera

An iPhone camera for iOS 18 and later. Open `RawCamera.xcodeproj` in Xcode 16 or later, select the RawCamera target, choose your signing team and a unique bundle identifier under Signing & Capabilities, then run the RawCamera scheme on an iPhone. Grant Camera and Photos add access.

Choose a physical rear lens using the circular magnification buttons at the bottom of the viewfinder. Tap a subject in the viewfinder to move the autofocus point. Tap-to-focus exits manual focus and tracks at that point. Focus taps and lens changes are disabled during capture. Each lens reports its own Bayer RAW and manual-control capabilities. Use **Exposure** to set shutter duration and ISO together, **WB** to set color temperature, and **Focus** to set lens position. The viewfinder shows the whole frame. The interface and preview rotate between portrait and landscape, and captures use the interface orientation.

Tap the shutter for one DNG. Hold it for at least 0.25 seconds for repeated captures using continuous autofocus. Release to stop requesting frames. If manual focus was selected, the app restores its position after outstanding captures finish. A lens without continuous autofocus supports single shots if it provides Bayer RAW.

The buffer meter counts outstanding requests, queued DNGs, and the photo currently being saved. The app reserves one of 30 slots before each request and saves into the system Photos library in capture-completion order. A full buffer pauses new requests until a save completes. The burst rate depends on the lens, shutter duration, capture readiness, and Photos write speed. After a save error, keep the app open and tap **Retry saving** once the issue is resolved. Queued DNGs live in memory until saved.

## On-device checks

- Take single DNGs with different ISO and shutter settings. Inspect the originals and exposure metadata in a RAW viewer.
- Select a physical lens and move close to a subject. Confirm framing stays on the chosen lens.
- Set manual focus, hold the shutter, and alternate between near and far subjects. Check AF tracking during the burst and the return to the selected focus position on release.
- Hold for more than 30 total frames. Watch the buffer count, release, and wait for it to reach zero. Compare the saved count with the new DNG assets in Photos.

## Automatic releases

Every push to master builds on macOS and publishes a new unsigned IPA with a unique tag of the form v1.0.<GitHub run number>. Manual workflow runs also publish a release. Rerunning a workflow replaces the asset for that same build. The app version and build number match the workflow run. Sign the downloaded IPA using your sideloading tool before installation.

RAW requests are serialized while the burst timer continues polling capture readiness. Continuous autofocus stays enabled throughout a burst. Temporary AVFoundation capture failures back off for 250 ms and allow up to three consecutive retries. Single shots also wait briefly for capture readiness. Errors include their operation, domain, code, and underlying error when available.

Test tap-to-focus on near and far subjects, lens changes, and a held burst while moving between subjects on an iPhone. The CI build validates compilation and packaging. Autofocus behavior and the reported capture failure require on-device verification.

## Histogram and Camera Control

The exposure histogram shows sampled live-preview luminance in 64 bins, with shadows on the left and highlights on the right. It updates about six times per second. Its brightness and clipping reflect the preview rendering, so RAW headroom can differ.

While the app is open with the camera running, Camera Control presses take a single photo and holds start a burst. Cancellation stops capture requests. On supported hardware, a light press opens system controls for physical lens selection, shutter speed, ISO, white balance, and focus, subject to the device's supported controls. Hardware adjustments switch the corresponding setting into manual mode. During bursts, continuous autofocus takes over and adjustment controls are disabled until capture finishes.

Verify the histogram by moving between dark and bright scenes and changing manual exposure. On an iPhone with Camera Control, check press, hold, release, cancellation, light-press adjustments, and switching lenses. Backgrounding the app should stop capture and disable hardware adjustments.

## Viewfinder options

Use the sliders icon in the navigation bar to choose Off, Rule of Thirds, or Golden Ratio for the grid and to toggle the level. Choices persist between launches. The golden ratio grid divides each axis at approximately 38.2% and 61.8%. Grids follow the camera image area, including when the viewfinder has letterboxing.

The compact histogram sits in the top-right corner of the viewfinder. The level shows the horizon relative to the current interface orientation, with a yellow indicator within one degree of level. Motion updates run only while the level is enabled and the app is active. The level shows unavailable when motion data is unavailable or the phone is too flat for a reliable horizon.

Check portrait and both landscape directions, including rotation during a burst. Confirm the preview and saved DNG orientation match, the focus square remains at the selected subject point after rotation, both grids align to the image, and the level reads near zero with a horizontal horizon. Rotation follows the system's orientation behavior.
