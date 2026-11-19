import AVFoundation
import Photos
import SwiftUI

struct Lens: Identifiable, Equatable {
    let id: String
    let name: String
}

struct Panel {
    var lenses: [Lens] = []
    var lens = ""
    var ready = false
    var busy = false
    var burst = false
    var canFocus = false
    var canTrack = false
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
final class Camera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published private(set) var panel = Panel()
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
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
        state.busy = pressed || !inFlight.isEmpty
        state.ready = active && !interrupted && session.isRunning && rawFormat != nil
        let snapshot = state
        DispatchQueue.main.async { self.panel = snapshot }
    }

    func setActive(_ value: Bool) {
        queue.async {
            self.active = value
            if value {
                self.requestAccess()
            } else {
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
            state.lenses = devices.map { Lens(id: $0.uniqueID, name: $0.localizedName) }
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
            guard !self.pressed, self.inFlight.isEmpty, let device = self.devices.first(where: { $0.uniqueID == id }), device.uniqueID != self.state.lens else { return }
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
            state.canExpose = device.isExposureModeSupported(.custom)
            state.canBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
            state.manualExposure = device.exposureMode == .custom
            state.manualBalance = device.whiteBalanceMode == .locked && state.canBalance
            state.manualFocus = device.focusMode == .locked && state.canFocus
            refreshRawFormat()
        } catch { state.message = error.localizedDescription }
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
            guard !self.pressed, self.inFlight.isEmpty, let device = self.input?.device else { return }
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
            guard self.state.ready, !self.state.saveFailed, !self.pressed, !self.restoreFocus else { return }
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
            if single { self.capture(burst: false) }
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
        guard occupied < capacity, inFlight.count < 3, output.captureReadiness == .ready else {
            if !burst { state.message = "Camera busy. Tap again." }
            return
        }
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(rotation) {
            connection.videoRotationAngle = rotation
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        settings.photoQualityPrioritization = .speed
        inFlight.insert(settings.uniqueID)
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
                self.state.message = error?.localizedDescription ?? "Could not create DNG."
                self.endHold()
                self.publish()
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        queue.async {
            let id = resolvedSettings.uniqueID
            guard self.inFlight.remove(id) != nil else { return }
            let data = self.representations.removeValue(forKey: id)
            if let data { self.pending.append(data) }
            if let error {
                self.state.message = error.localizedDescription
                self.endHold()
            }
            self.restoreIfFinished()
            self.drain()
            self.publish()
        }
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
                    self.state.message = error?.localizedDescription ?? "Photos could not save this file."
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
            self.endHold()
            self.state.message = "Camera interrupted."
            self.publish()
        }
    }

    @objc private func resumed(_ note: Notification) {
        queue.async {
            self.interrupted = false
            self.state.message = ""
            self.start()
            self.publish()
        }
    }

    @objc private func runtimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        queue.async {
            self.endHold()
            self.state.message = error?.localizedDescription ?? "Camera session failed."
            if error?.code == AVError.Code.mediaServicesWereReset.rawValue { self.start() }
            self.publish()
        }
    }
}
