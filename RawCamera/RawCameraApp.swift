import AVFoundation
import AVKit
import CoreMotion
import SwiftUI

@main
struct RawCameraApp: App {
    @StateObject private var camera = Camera()
    var body: some Scene {
        WindowGroup { Viewfinder(camera: camera) }
    }
}

private enum GridMode: String, CaseIterable {
    case off = "Off"
    case thirds = "Rule of Thirds"
    case golden = "Golden Ratio"

    var divisions: [CGFloat] {
        switch self {
        case .off: return []
        case .thirds: return [1.0 / 3, 2.0 / 3]
        case .golden: return [0.38196601125, 0.61803398875]
        }
    }
}

private final class MotionLevel: ObservableObject {
    @Published private var gravity: CMAcceleration?
    private let motion = CMMotionManager()

    func setActive(_ active: Bool) {
        guard active, motion.isDeviceMotionAvailable else {
            motion.stopDeviceMotionUpdates()
            gravity = nil
            return
        }
        guard !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            self?.gravity = data?.gravity
        }
    }

    func roll(for orientation: UIInterfaceOrientation) -> Double? {
        guard let gravity, hypot(gravity.x, gravity.y) > 0.2 else { return nil }
        let reference: Double
        switch orientation {
        case .landscapeLeft: reference = .pi / 2
        case .landscapeRight: reference = -.pi / 2
        case .portraitUpsideDown: reference = .pi
        default: reference = 0
        }
        let angle = atan2(gravity.x, -gravity.y) - reference
        return atan2(sin(angle), cos(angle))
    }
}

private struct LevelDisplay: View {
    let roll: Double?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Rectangle().fill(.white.opacity(0.6)).frame(width: 100, height: 1)
                if let roll {
                    Rectangle()
                        .fill(abs(roll) < .pi / 180 ? Color.yellow : Color.white)
                        .frame(width: 72, height: 3)
                        .rotationEffect(.radians(-roll))
                }
            }
            .frame(width: 108, height: 40)
            Text(roll.map { String(format: "%.1f°", abs($0) * 180 / .pi) } ?? "Level unavailable")
                .font(.caption.monospacedDigit())
                .padding(4)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera level")
        .accessibilityValue(roll.map { String(format: "%.1f degrees", abs($0) * 180 / .pi) } ?? "Unavailable. Hold the phone upright.")
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onFocus: ((CGPoint) -> Void)?
    var focusEnabled = false
    var grid = GridMode.off
    private let gridLayer = CAShapeLayer()
    private let focusRing = CALayer()
    var focusPoint = CGPoint(x: 0.5, y: 0.5)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        focusRing.borderWidth = 1.5
        focusRing.borderColor = UIColor.systemYellow.cgColor
        gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        gridLayer.lineWidth = 0.75
        gridLayer.fillColor = nil
        layer.addSublayer(gridLayer)
        layer.addSublayer(focusRing)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let imageRect = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)).intersection(bounds)
        let path = UIBezierPath()
        if !imageRect.isNull {
            for fraction in grid.divisions {
                let x = imageRect.minX + imageRect.width * fraction
                let y = imageRect.minY + imageRect.height * fraction
                path.move(to: CGPoint(x: x, y: imageRect.minY))
                path.addLine(to: CGPoint(x: x, y: imageRect.maxY))
                path.move(to: CGPoint(x: imageRect.minX, y: y))
                path.addLine(to: CGPoint(x: imageRect.maxX, y: y))
            }
        }
        gridLayer.path = path.cgPath
        positionFocusRing()
    }

    private func positionFocusRing() {
        let point = preview.layerPointConverted(fromCaptureDevicePoint: focusPoint)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusRing.frame = CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60)
        CATransaction.commit()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard focusEnabled else { return }
        let point = gesture.location(in: self)
        let imageRect = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard imageRect.contains(point) else { return }
        focusPoint = preview.captureDevicePointConverted(fromLayerPoint: point)
        onFocus?(focusPoint)
        positionFocusRing()
    }
}

private final class PreviewController: UIViewController {
    let previewView = PreviewView()
    var onOrientation: ((UIInterfaceOrientation, AVCaptureConnection) -> Void)?
    private var orientation = UIInterfaceOrientation.unknown
    private weak var orientedConnection: AVCaptureConnection?
    private var transitioning = false

    override func loadView() { view = previewView }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateOrientation()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        transitioning = true
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.transitioning = false
            self?.updateOrientation()
        }
    }

    func updateOrientation() {
        guard !transitioning,
              let current = view.window?.windowScene?.interfaceOrientation, current != .unknown,
              let connection = previewView.preview.connection else { return }
        guard orientation != current || orientedConnection !== connection else { return }
        orientation = current
        orientedConnection = connection
        onOrientation?(current, connection)
    }
}

private struct Preview: UIViewControllerRepresentable {
    let camera: Camera
    let focusEnabled: Bool
    let grid: GridMode
    @Binding var focusPoint: CGPoint
    @Binding var orientation: UIInterfaceOrientation
    func makeUIViewController(context: Context) -> PreviewController {
        let controller = PreviewController()
        controller.previewView.preview.videoGravity = .resizeAspect
        controller.previewView.preview.session = camera.session
        return controller
    }
    func updateUIViewController(_ controller: PreviewController, context: Context) {
        let view = controller.previewView
        view.focusEnabled = focusEnabled
        view.grid = grid
        view.focusPoint = focusPoint
        view.onFocus = {
            focusPoint = $0
            camera.focus(at: $0)
        }
        controller.onOrientation = { [weak controller] direction, connection in
            camera.orient(direction, previewConnection: connection) { [weak controller] in
                orientation = direction
                controller?.previewView.setNeedsLayout()
            }
        }
        view.setNeedsLayout()
        controller.updateOrientation()
    }
}

private final class ShutterButton: UIControl {
    var camera: Camera?
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        camera?.down()
        isHighlighted = true
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        isHighlighted = false
        camera?.up()
    }
    override func cancelTracking(with event: UIEvent?) {
        isHighlighted = false
        camera?.up(cancel: true)
    }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        camera?.down()
        camera?.up()
        return true
    }
    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.68 : 1 }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}

private struct Shutter: UIViewRepresentable {
    let camera: Camera
    let enabled: Bool
    let burst: Bool
    func makeUIView(context: Context) -> ShutterButton {
        let button = ShutterButton()
        button.camera = camera
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityLabel = "Shutter"
        button.accessibilityHint = "Takes a RAW photo."
        button.layer.borderWidth = 4
        button.layer.borderColor = UIColor.darkGray.cgColor
        return button
    }
    func updateUIView(_ button: ShutterButton, context: Context) {
        button.isEnabled = enabled
        button.backgroundColor = enabled ? (burst ? .systemOrange : .white) : .darkGray
    }
}

private enum Adjustment: String, CaseIterable { case exposure = "Exposure", balance = "WB", focus = "Focus" }

private struct ExposureHistogram: View {
    let bins: [Double]
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(live ? "Exposure" : "Paused")
                .font(.system(size: 9))
            Canvas { context, size in
                guard !bins.isEmpty else { return }
                let width = size.width / CGFloat(bins.count)
                var bars = Path()
                for (index, value) in bins.enumerated() {
                    let height = CGFloat(value) * size.height
                    bars.addRect(CGRect(x: CGFloat(index) * width, y: size.height - height, width: width, height: height))
                }
                context.fill(bars, with: .color(.white.opacity(live ? 0.9 : 0.4)))
            }
            .frame(width: 92, height: 30)
        }
        .padding(6)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure histogram, shadows on the left and highlights on the right")
        .accessibilityValue(live && !bins.isEmpty ? "Live preview" : "Waiting for preview")
        .allowsHitTesting(false)
    }
}

private struct Viewfinder: View {
    @ObservedObject var camera: Camera
    @Environment(\.scenePhase) private var phase
    @State private var tab = Adjustment.exposure
    @State private var focusPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var orientation = UIInterfaceOrientation.portrait
    @StateObject private var level = MotionLevel()
    @AppStorage("viewfinderGrid") private var gridSelection = GridMode.off.rawValue
    @AppStorage("viewfinderLevel") private var showLevel = false
    private var p: Panel { camera.panel }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 10))
            VStack(spacing: 10) {
                navigation
                // AnyLayout preserves the preview controller and session attachment.
                layout {
                    viewfinder
                    ViewThatFits(in: .vertical) {
                        captureControls.fixedSize(horizontal: false, vertical: true)
                        ScrollView { captureControls }
                    }
                    .frame(width: landscape ? min(280, geometry.size.width * 0.36) : nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .tint(.orange)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onCameraCaptureEvent(isEnabled: p.ready && !p.saveFailed) { event in
            switch event.phase {
            case .began: camera.down()
            case .ended: camera.up()
            case .cancelled: camera.up(cancel: true)
            @unknown default: camera.up(cancel: true)
            }
        }
        .onChange(of: phase, initial: true) { _, value in
            camera.setActive(value == .active)
            level.setActive(showLevel && value == .active)
        }
        .onChange(of: showLevel) { _, enabled in
            level.setActive(enabled && phase == .active)
        }
        .onDisappear {
            level.setActive(false)
            camera.setActive(false)
        }
    }

    private var navigation: some View {
        HStack {
            Text(p.lenses.first(where: { $0.id == p.lens })?.name ?? "Lens")
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Text("DNG").font(.caption.bold())
            Menu {
                Picker("Grid", selection: $gridSelection) {
                    ForEach(GridMode.allCases, id: \.rawValue) { grid in
                        Text(grid.rawValue).tag(grid.rawValue)
                    }
                }
                Toggle("Level", isOn: $showLevel)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Viewfinder options")
        }
        .opacity(camera.cameraControlFullscreen ? 0 : 1)
    }

    private var viewfinder: some View {
        ZStack(alignment: .bottom) {
            Preview(camera: camera, focusEnabled: p.ready && !p.busy && p.canTapFocus, grid: GridMode(rawValue: gridSelection) ?? .off, focusPoint: $focusPoint, orientation: $orientation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                ForEach(p.lenses) { lens in
                    Button { camera.select(lens.id) } label: {
                        Text(lens.magnification)
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(lens.id == p.lens ? .yellow : .white)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(.black.opacity(0.7), in: Circle())
                            .overlay(Circle().stroke(lens.id == p.lens ? Color.yellow : Color.clear))
                    }
                    .accessibilityLabel(lens.name)
                    .accessibilityValue(lens.id == p.lens ? "Selected" : "")
                }
            }
            .disabled(p.busy)
            .opacity(camera.cameraControlFullscreen ? 0 : 1)
            .padding(.bottom, 12)
        }
        .overlay(alignment: .topTrailing) {
            ExposureHistogram(bins: camera.histogram, live: p.ready)
                .padding(8)
                .opacity(camera.cameraControlFullscreen ? 0 : 1)
        }
        .overlay {
            if showLevel && !camera.cameraControlFullscreen {
                LevelDisplay(roll: level.roll(for: orientation))
            }
        }
    }

    private var captureControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(p.burst ? (p.used == 30 ? "Buffer full · AF-C" : "Burst · AF-C") : "Buffer")
                Text("\(p.used)/30")
                Spacer()
                Text("\(p.saved) saved")
            }
            .font(.caption.monospacedDigit())
            if !p.message.isEmpty {
                Text(p.message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            }
            if p.saveFailed { Button("Retry saving", action: camera.retry) }
            Picker("Adjustment", selection: $tab) {
                ForEach(Adjustment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            controls
                .disabled(!p.ready || p.busy)
            Shutter(camera: camera, enabled: p.ready && !p.saveFailed, burst: p.burst)
                .frame(width: 66, height: 66)
            Text("Tap for one photo · Hold for burst").font(.caption)
        }
        .opacity(camera.cameraControlFullscreen ? 0 : 1)
        .allowsHitTesting(!camera.cameraControlFullscreen)
    }

    @ViewBuilder private var controls: some View {
        switch tab {
        case .exposure:
            Toggle("Manual exposure", isOn: Binding(get: { p.manualExposure }, set: { camera.control(.exposure, manual: $0) }))
                .disabled(!p.canExpose)
            if p.manualExposure {
                slider("Shutter", value: p.duration < 0.5 ? "1/\(Int((1 / p.duration).rounded())) s" : String(format: "%.2f s", p.duration),
                       current: log2(p.duration), range: log2(p.durations.lowerBound)...log2(p.durations.upperBound)) {
                    camera.control(.exposure, manual: true, value: exp2($0))
                }
                slider("ISO", value: "\(Int(p.iso))", current: log2(p.iso), range: log2(p.isos.lowerBound)...log2(p.isos.upperBound)) {
                    camera.control(.exposure, manual: true, iso: exp2($0))
                }
            }
        case .balance:
            Toggle("Manual white balance", isOn: Binding(get: { p.manualBalance }, set: { camera.control(.balance, manual: $0) }))
                .disabled(!p.canBalance)
            if p.manualBalance {
                slider("Temp", value: "\(Int(p.kelvin)) K", current: p.kelvin, range: 2500...10000) {
                    camera.control(.balance, manual: true, value: $0)
                }
            }
        case .focus:
            Toggle("Manual focus", isOn: Binding(get: { p.manualFocus && !p.burst }, set: { camera.control(.focus, manual: $0) }))
                .disabled(!p.canFocus)
            if p.manualFocus && !p.burst {
                slider("Position", value: String(format: "%.2f", p.focus), current: p.focus, range: 0...1) {
                    camera.control(.focus, manual: true, value: $0)
                }
            } else if p.burst {
                Text("Continuous autofocus").font(.caption)
            }
        }
    }

    private func slider(_ label: String, value: String, current: Double, range: ClosedRange<Double>, change: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 56, alignment: .leading)
            if range.lowerBound < range.upperBound {
                Slider(value: Binding(get: { current }, set: change), in: range)
                    .accessibilityLabel(label)
                    .accessibilityValue(value)
            }
            Text(value).frame(minWidth: 68, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit())
    }
}
