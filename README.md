# RAW Camera

An iPhone camera for iOS 18 and later. Open `RawCamera.xcodeproj` in Xcode 16 or later, select the RawCamera target, choose your signing team and a unique bundle identifier under Signing & Capabilities, then run the RawCamera scheme on an iPhone. Grant Camera and Photos add access.

Choose a physical rear lens from the top menu. Each lens reports its own Bayer RAW and manual-control capabilities. Use **Exposure** to set shutter duration and ISO together, **WB** to set color temperature, and **Focus** to set lens position. The portrait viewfinder shows the whole frame. The app uses the phone orientation to set the capture orientation.

Tap the shutter for one DNG. Hold it for at least 0.25 seconds for repeated captures using continuous autofocus. Release to stop requesting frames. If manual focus was selected, the app restores its position after outstanding captures finish. A lens without continuous autofocus supports single shots if it provides Bayer RAW.

The buffer meter counts outstanding requests, queued DNGs, and the photo currently being saved. The app reserves one of 30 slots before each request and saves into the system Photos library in capture-completion order. A full buffer pauses new requests until a save completes. The burst rate depends on the lens, shutter duration, capture readiness, and Photos write speed. After a save error, keep the app open and tap **Retry saving** once the issue is resolved. Queued DNGs live in memory until saved.

## On-device checks

- Take single DNGs with different ISO and shutter settings. Inspect the originals and exposure metadata in a RAW viewer.
- Select a physical lens and move close to a subject. Confirm framing stays on the chosen lens.
- Set manual focus, hold the shutter, and alternate between near and far subjects. Check AF tracking during the burst and the return to the selected focus position on release.
- Hold for more than 30 total frames. Watch the buffer count, release, and wait for it to reach zero. Compare the saved count with the new DNG assets in Photos.
