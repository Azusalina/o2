import AVFoundation
import Photos
import SwiftUI

struct Lens: Identifiable, Equatable {
    let id: String
    let name: String
    let magnification: String
}

struct Panel {
    var lenses: [Lens] = []
    var lens = ""
    var ready = false
    var busy = false
    var burst = false
    var canFocus = false
    var canTrack = false
    var canTapFocus = false
    var canExpose = false
    var canBalance = false
    var manualFocus = false
    var manualExposure = false
    var manualBalance = false
    var focus = 0.5
    var duration = 1.0 / 125
    var iso = 100.0
    var kelvin = 5000.0
    var durations = (1.0 / 8000)...1.0
    var isos = 25.0...1600.0
    var used = 0
    var saved = 0
    var saveFailed = false
    var message = "Requesting access…"
}

// All capture state and reservations belong to queue. Only the published snapshot
// and the preview layer are consumed on the main thread.
final class Camera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureSessionControlsDelegate {
    @Published private(set) var panel = Panel()
    @Published private(set) var histogram: [Double] = []
    @Published private(set) var cameraControlFullscreen = false
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let histogramQueue = DispatchQueue(label: "camera.histogram", qos: .utility)
    // Accessed only on histogramQueue. No preview pixel buffers are retained.
    private var histogramUpdatePending = false
    private var lastHistogramTime = -Double.infinity
    private var shutterControl: AVCaptureIndexPicker?
    private var shutterDurations: [Double] = []
    private var isoControl: AVCaptureSlider?
    private var balanceControl: AVCaptureSlider?
    private var focusControl: AVCaptureSlider?
    private var lensControl: AVCaptureIndexPicker?
    private var state = Panel()
    private var devices: [AVCaptureDevice] = []
    private var input: AVCaptureDeviceInput?
    private var rawFormat: OSType?
    private var active = false
    private var authorized = false
    private var requesting = false
    private var interrupted = false
    private var hold: DispatchWorkItem?
    private var pulse: DispatchSourceTimer?
    private var pressed = false
    private var longPress = false
    private var restoreFocus = false
    private var rotation: CGFloat = 90
    private var inFlight = Set<Int64>()
    private var representations: [Int64: Data] = [:]
    private var captureErrors: [Int64: Error] = [:]
    private var singleCaptureID: Int64?
    private var singleRetry: DispatchWorkItem?
    private var singleAttempts = 0
    private var consecutiveFailures = 0
    private var nextCaptureTime = DispatchTime.now()
    private var pending: [Data] = []
    private var writing = false
    private let capacity = 30
    private var occupied: Int { inFlight.count + pending.count }

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interruption(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(resumed(_:)), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(runtimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    private func publish() {
        state.used = occupied
        state.burst = pulse != nil
        state.busy = pressed || !inFlight.isEmpty || singleRetry != nil
        state.ready = active && !interrupted && session.isRunning && rawFormat != nil
        syncHardwareControls()
        let snapshot = state
        DispatchQueue.main.async { self.panel = snapshot }
    }

    func setActive(_ value: Bool) {
        queue.async {
            self.active = value
            if value {
                self.requestAccess()
            } else {
                self.cancelSingleRetry()
                self.endHold()
                if self.session.isRunning { self.session.stopRunning() }
                self.publish()
            }
        }
    }

    private func requestAccess() {
        guard !requesting else { return }
        requesting = true
        AVCaptureDevice.requestAccess(for: .video) { cameraOK in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                self.queue.async {
                    self.requesting = false
                    self.authorized = cameraOK && (status == .authorized || status == .limited)
                    if self.authorized && self.active {
                        self.start()
                    } else if !self.authorized {
                        self.state.message = "Allow Camera and Photos add access in Settings."
                        self.publish()
                    }
                }
            }
        }
    }

    private func start() {
        guard active, authorized, !interrupted else { return }
        if input == nil {
            devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
            devices.sort { $0.activeFormat.videoFieldOfView > $1.activeFormat.videoFieldOfView }
            let wideFOV = devices.first(where: { $0.deviceType == .builtInWideAngleCamera })?.activeFormat.videoFieldOfView ?? 60
            state.lenses = devices.map {
                let ratio = tan(Double(wideFOV) * .pi / 360) / tan(Double($0.activeFormat.videoFieldOfView) * .pi / 360)
                let label = $0.deviceType == .builtInWideAngleCamera ? "1×" : String(format: "%g×", (ratio * 10).rounded() / 10)
                return Lens(id: $0.uniqueID, name: $0.localizedName, magnification: label)
            }
            guard let first = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
                state.message = "No rear camera found."
                publish()
                return
            }
            configure(first)
        }
        if input != nil && !session.isRunning { session.startRunning() }
        if session.isRunning { refreshRawFormat() }
        publish()
    }

    func select(_ id: String) {
        queue.async {
            guard !self.state.busy, let device = self.devices.first(where: { $0.uniqueID == id }), device.uniqueID != self.state.lens else { return }
            self.configure(device)
            self.publish()
        }
    }

    private func configure(_ device: AVCaptureDevice) {
        do {
            let next = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .photo
            let previous = input
            if let previous { session.removeInput(previous) }
            guard session.canAddInput(next) else {
                if let previous, session.canAddInput(previous) { session.addInput(previous) }
                session.commitConfiguration()
                state.message = "Cannot connect this lens."
                return
            }
            session.addInput(next)
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else {
                    session.removeInput(next)
                    session.commitConfiguration()
                    state.message = "Photo output unavailable."
                    return
                }
                session.addOutput(output)
            }
            if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.automaticallyConfiguresOutputBufferDimensions = false
                videoOutput.deliversPreviewSizedOutputBuffers = true
                videoOutput.setSampleBufferDelegate(self, queue: histogramQueue)
                session.addOutput(videoOutput)
            }
            let formats = videoOutput.availableVideoPixelFormatTypes
            if let format = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].first(where: { formats.contains($0) }) {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            }
            session.commitConfiguration()
            input = next
            state.lens = device.uniqueID
            let format = device.activeFormat
            state.durations = format.minExposureDuration.seconds...format.maxExposureDuration.seconds
            state.isos = Double(format.minISO)...Double(format.maxISO)
            state.duration = clamp(device.exposureDuration.seconds, state.durations)
            state.iso = clamp(Double(device.iso), state.isos)
            state.focus = Double(device.lensPosition)
            state.canFocus = device.isLockingFocusWithCustomLensPositionSupported
            state.canTrack = device.isFocusModeSupported(.continuousAutoFocus)
            state.canTapFocus = device.isFocusPointOfInterestSupported && state.canTrack
            state.canExpose = device.isExposureModeSupported(.custom)
            state.canBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
            state.manualExposure = device.exposureMode == .custom
            state.manualBalance = device.whiteBalanceMode == .locked && state.canBalance
            state.manualFocus = device.focusMode == .locked && state.canFocus
            refreshRawFormat()
            configureHardwareControls()
        } catch { state.message = error.localizedDescription }
    }

    private func configureHardwareControls() {
        guard session.supportsControls else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for control in session.controls { session.removeControl(control) }
        shutterControl = nil
        isoControl = nil
        balanceControl = nil
        focusControl = nil
        lensControl = nil
        session.setControlsDelegate(self, queue: queue)

        if state.lenses.count > 1 {
            let lensIDs = state.lenses.map(\.id)
            let picker = AVCaptureIndexPicker("Lens", symbolName: "camera.aperture", localizedIndexTitles: state.lenses.map(\.magnification))
            picker.setActionQueue(queue) { [weak self] index in
                guard lensIDs.indices.contains(index) else { return }
                self?.select(lensIDs[index])
            }
            if session.canAddControl(picker) {
                session.addControl(picker)
                lensControl = picker
            }
        }
        if state.canExpose {
            let stops = [1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 0.25, 0.5, 1, 2, 4, 8, 15, 30]
            let durations = Array(Set(stops.filter { state.durations.contains($0) } + [state.durations.lowerBound, state.durations.upperBound])).sorted()
            shutterDurations = durations
            let titles = durations.map { $0 < 0.5 ? "1/\(Int((1 / $0).rounded())) s" : String(format: "%g s", $0) }
            let shutter = AVCaptureIndexPicker("Shutter", symbolName: "shutter.speed", localizedIndexTitles: titles)
            shutter.setActionQueue(queue) { [weak self] index in
                guard durations.indices.contains(index) else { return }
                self?.control(.exposure, manual: true, value: durations[index])
            }
            if session.canAddControl(shutter) {
                session.addControl(shutter)
                shutterControl = shutter
            }
            let iso = AVCaptureSlider("ISO", symbolName: "camera", in: Float(state.isos.lowerBound)...Float(state.isos.upperBound))
            iso.setActionQueue(queue) { [weak self] value in
                self?.control(.exposure, manual: true, iso: Double(value))
            }
            if session.canAddControl(iso) {
                session.addControl(iso)
                isoControl = iso
            }
        }
        if state.canBalance {
            let balance = AVCaptureSlider("White balance", symbolName: "thermometer.medium", in: 2500...10000, step: 100)
            balance.localizedValueFormat = "%@ K"
            balance.setActionQueue(queue) { [weak self] value in
                self?.control(.balance, manual: true, value: Double(value))
            }
            if session.canAddControl(balance) {
                session.addControl(balance)
                balanceControl = balance
            }
        }
        if state.canFocus {
            let focus = AVCaptureSlider("Focus", symbolName: "viewfinder", in: 0...1)
            focus.setActionQueue(queue) { [weak self] value in
                self?.control(.focus, manual: true, value: Double(value))
            }
            if session.canAddControl(focus) {
                session.addControl(focus)
                focusControl = focus
            }
        }
        syncHardwareControls()
    }

    private func syncHardwareControls() {
        if let nearest = shutterDurations.indices.min(by: {
            abs(log2(shutterDurations[$0] / state.duration)) < abs(log2(shutterDurations[$1] / state.duration))
        }) {
            shutterControl?.selectedIndex = nearest
        }
        isoControl?.value = Float(state.iso)
        balanceControl?.value = Float(state.kelvin)
        focusControl?.value = Float(state.focus)
        if let index = state.lenses.firstIndex(where: { $0.id == state.lens }) {
            lensControl?.selectedIndex = index
        }
        for control in session.controls {
            control.isEnabled = active && !interrupted && !state.busy
        }
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        DispatchQueue.main.async { self.cameraControlFullscreen = false }
    }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        DispatchQueue.main.async { self.cameraControlFullscreen = true }
    }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        DispatchQueue.main.async { self.cameraControlFullscreen = false }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard !histogramUpdatePending, timestamp.isFinite,
              timestamp < lastHistogramTime || timestamp - lastHistogramTime >= 0.15,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let format = CVPixelBufferGetPixelFormatType(pixels)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixels) > 0,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        let limitedRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var bins = [Int](repeating: 0, count: 64)
        for y in stride(from: 0, to: height, by: max(1, height / 120)) {
            for x in stride(from: 0, to: width, by: max(1, width / 160)) {
                let luma = Int(bytes[y * rowBytes + x])
                let normalized = limitedRange ? min(255, max(0, (luma - 16) * 255 / 219)) : luma
                bins[normalized / 4] += 1
            }
        }
        let peak = Double(bins.max() ?? 1)
        let values = bins.map { Double($0) / max(1, peak) }
        lastHistogramTime = timestamp
        histogramUpdatePending = true
        DispatchQueue.main.async {
            self.histogram = values
            self.histogramQueue.async { self.histogramUpdatePending = false }
        }
    }

    private func refreshRawFormat() {
        rawFormat = output.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
        if !state.saveFailed {
            state.message = rawFormat == nil ? "This lens has no Bayer RAW output." : ""
        }
    }

    enum Control { case exposure, balance, focus }
    func control(_ control: Control, manual: Bool, value: Double? = nil, iso: Double? = nil) {
        queue.async {
            guard !self.state.busy, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                switch control {
                case .exposure:
                    if manual && self.state.canExpose {
                        let seconds = self.clamp(value ?? (self.state.manualExposure ? self.state.duration : device.exposureDuration.seconds), self.state.durations)
                        let sensitivity = self.clamp(iso ?? (self.state.manualExposure ? self.state.iso : Double(device.iso)), self.state.isos)
                        let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
                        let format = device.activeFormat
                        device.setExposureModeCustom(duration: CMTimeMinimum(format.maxExposureDuration, CMTimeMaximum(format.minExposureDuration, duration)), iso: Float(sensitivity), completionHandler: nil)
                        self.state.duration = seconds
                        self.state.iso = sensitivity
                    } else if !manual && device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else { return }
                    self.state.manualExposure = manual
                case .balance:
                    if manual && self.state.canBalance {
                        let kelvin = self.clamp(value ?? self.state.kelvin, 2500...10000)
                        var gains = device.deviceWhiteBalanceGains(for: .init(temperature: Float(kelvin), tint: 0))
                        let limit = device.maxWhiteBalanceGain
                        gains.redGain = min(limit, max(1, gains.redGain))
                        gains.greenGain = min(limit, max(1, gains.greenGain))
                        gains.blueGain = min(limit, max(1, gains.blueGain))
                        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                        self.state.kelvin = kelvin
                    } else if !manual && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    } else { return }
                    self.state.manualBalance = manual
                case .focus:
                    if manual && self.state.canFocus {
                        let point = self.clamp(value ?? (self.state.manualFocus ? self.state.focus : Double(device.lensPosition)), 0...1)
                        device.setFocusModeLocked(lensPosition: Float(point), completionHandler: nil)
                        self.state.focus = point
                    } else if !manual && self.state.canTrack {
                        device.focusMode = .continuousAutoFocus
                    } else { return }
                    self.state.manualFocus = manual
                }
            } catch { self.state.message = error.localizedDescription }
            self.publish()
        }
    }

    private func clamp(_ n: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, n))
    }

    func focus(at point: CGPoint) {
        queue.async {
            guard self.state.ready, !self.state.busy, self.state.canTapFocus,
                  let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
                self.state.manualFocus = false
            } catch {
                self.state.message = self.describe(error, operation: "Focus")
            }
            self.publish()
        }
    }

    func orient(_ orientation: UIDeviceOrientation) {
        queue.async {
            switch orientation {
            case .landscapeLeft: self.rotation = 0
            case .landscapeRight: self.rotation = 180
            case .portrait: self.rotation = 90
            case .portraitUpsideDown: self.rotation = 270
            default: break
            }
        }
    }

    func down() {
        queue.async {
            guard self.state.ready, !self.state.saveFailed, !self.state.busy, !self.restoreFocus else { return }
            self.pressed = true
            self.longPress = false
            let work = DispatchWorkItem { [weak self] in self?.beginBurst() }
            self.hold = work
            self.queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
            self.publish()
        }
    }

    func up(cancel: Bool = false) {
        queue.async {
            guard self.pressed else { return }
            let single = !cancel && !self.longPress
            self.endHold()
            if single {
                self.singleAttempts = 0
                self.consecutiveFailures = 0
                self.captureSingle()
            }
            self.publish()
        }
    }

    private func beginBurst() {
        guard pressed, let device = input?.device else { return }
        longPress = true
        guard state.canTrack else {
            state.message = "This lens cannot burst with continuous autofocus."
            publish()
            return
        }
        do {
            try device.lockForConfiguration()
            device.focusMode = AVCaptureDevice.FocusMode.continuousAutoFocus
            device.unlockForConfiguration()
            restoreFocus = state.manualFocus
            consecutiveFailures = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            pulse = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.capture(burst: true) }
            timer.resume()
        } catch { state.message = error.localizedDescription }
        publish()
    }

    private func endHold() {
        hold?.cancel()
        hold = nil
        pulse?.cancel()
        pulse = nil
        pressed = false
        restoreIfFinished()
    }

    private func restoreIfFinished() {
        guard restoreFocus, pulse == nil, inFlight.isEmpty, let device = input?.device else { return }
        restoreFocus = false
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: Float(state.focus), completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            state.manualFocus = false
            state.message = error.localizedDescription
        }
    }

    private func capture(burst: Bool) {
        guard active, session.isRunning, !interrupted, !state.saveFailed, let rawFormat else { return }
        if burst && (pulse == nil || input?.device.focusMode != .continuousAutoFocus) { return }
        // A physical RAW pipeline can reject overlapping captures while AF moves.
        // The timer still polls rapidly, with only one hardware request outstanding.
        guard occupied < capacity, inFlight.isEmpty, DispatchTime.now() >= nextCaptureTime, output.captureReadiness == .ready else {
            if !burst { state.message = "Camera busy. Tap again." }
            return
        }
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(rotation) {
            connection.videoRotationAngle = rotation
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        settings.isAutoStillImageStabilizationEnabled = false
        settings.photoQualityPrioritization = .speed
        inFlight.insert(settings.uniqueID)
        if !burst { singleCaptureID = settings.uniqueID }
        state.message = ""
        output.capturePhoto(with: settings, delegate: self)
        publish()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let data = error == nil && photo.isRawPhoto ? photo.fileDataRepresentation() : nil
        queue.async {
            guard self.inFlight.contains(id) else { return }
            self.representations[id] = data
            if data == nil {
                self.captureErrors[id] = error ?? NSError(domain: "RawCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create DNG."])
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        queue.async {
            let id = resolvedSettings.uniqueID
            guard self.inFlight.remove(id) != nil else { return }
            let wasSingle = self.singleCaptureID == id
            if wasSingle { self.singleCaptureID = nil }
            let data = self.representations.removeValue(forKey: id)
            let failure = self.captureErrors.removeValue(forKey: id) ?? error
            if let data {
                self.pending.append(data)
                self.consecutiveFailures = 0
                if !self.state.saveFailed { self.state.message = "" }
            } else if let failure {
                self.consecutiveFailures += 1
                self.nextCaptureTime = .now() + .milliseconds(250)
                if self.isTransientCaptureError(failure) && self.consecutiveFailures <= 3 {
                    self.state.message = "Camera recovering…"
                    if wasSingle { self.scheduleSingleRetry() }
                } else {
                    self.state.message = self.describe(failure, operation: "Capture")
                    self.endHold()
                }
            }
            self.restoreIfFinished()
            self.drain()
            self.publish()
        }
    }

    private func captureSingle() {
        guard active, !interrupted, !state.saveFailed else { return }
        if output.captureReadiness != .ready || DispatchTime.now() < nextCaptureTime {
            scheduleSingleRetry()
        } else {
            capture(burst: false)
        }
    }

    private func scheduleSingleRetry() {
        guard active, !interrupted, !state.saveFailed, singleAttempts < 8 else {
            state.message = "Camera busy. Tap again."
            return
        }
        singleAttempts += 1
        singleRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.singleRetry = nil
            self.captureSingle()
            self.publish()
        }
        singleRetry = work
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func cancelSingleRetry() {
        singleRetry?.cancel()
        singleRetry = nil
    }

    private func isTransientCaptureError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == AVFoundationErrorDomain && error.code == AVError.Code.unknown.rawValue
    }

    private func describe(_ error: Error, operation: String) -> String {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let detail = underlying.map { " / \($0.domain) \($0.code)" } ?? ""
        return "\(operation): \(error.localizedDescription) (\(error.domain) \(error.code)\(detail))"
    }

    private func drain() {
        guard !writing, !state.saveFailed, let data = pending.first else { return }
        writing = true
        PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "RAW-\(UUID().uuidString).dng"
            options.uniformTypeIdentifier = "com.adobe.raw-image"
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
        } completionHandler: { success, error in
            self.queue.async {
                self.writing = false
                if success {
                    self.pending.removeFirst()
                    self.state.saved += 1
                    self.drain()
                } else {
                    self.state.saveFailed = true
                    self.state.message = error.map { self.describe($0, operation: "Save") } ?? "Photos could not save this file."
                    self.cancelSingleRetry()
                    self.endHold()
                }
                self.publish()
            }
        }
    }

    func retry() {
        queue.async {
            self.state.saveFailed = false
            self.state.message = ""
            self.drain()
            self.publish()
        }
    }

    @objc private func interruption(_ note: Notification) {
        queue.async {
            self.interrupted = true
            self.cancelSingleRetry()
            self.endHold()
            self.state.message = "Camera interrupted."
            self.publish()
        }
    }

    @objc private func resumed(_ note: Notification) {
        queue.async {
            self.cancelSingleRetry()
            self.interrupted = false
            self.state.message = ""
            self.start()
            self.publish()
        }
    }

    @objc private func runtimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        queue.async {
            self.cancelSingleRetry()
            self.endHold()
            self.state.message = error.map { self.describe($0, operation: "Camera") } ?? "Camera session failed."
            if error?.code == AVError.Code.mediaServicesWereReset.rawValue { self.start() }
            self.publish()
        }
    }
}
