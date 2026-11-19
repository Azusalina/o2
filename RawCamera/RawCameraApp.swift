import AVFoundation
import SwiftUI

@main
struct RawCameraApp: App {
    @StateObject private var camera = Camera()
    var body: some Scene {
        WindowGroup { Viewfinder(camera: camera) }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct Preview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.videoGravity = .resizeAspect
        view.preview.session = session
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.preview.connection, connection.isVideoRotationAngleSupported(90), connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
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

private struct Viewfinder: View {
    @ObservedObject var camera: Camera
    @Environment(\.scenePhase) private var phase
    @State private var tab = Adjustment.exposure
    private var p: Panel { camera.panel }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Menu {
                    ForEach(p.lenses) { lens in
                        Button { camera.select(lens.id) } label: {
                            if lens.id == p.lens { Label(lens.name, systemImage: "checkmark") }
                            else { Text(lens.name) }
                        }
                    }
                } label: {
                    Label(p.lenses.first(where: { $0.id == p.lens })?.name ?? "Lens", systemImage: "camera.aperture")
                }
                .disabled(p.busy || p.lenses.isEmpty)
                Spacer()
                Text("DNG").font(.caption.bold())
            }
            Preview(session: camera.session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .tint(.orange)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            camera.orient(UIDevice.current.orientation)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            camera.orient(UIDevice.current.orientation)
        }
        .onChange(of: phase, initial: true) { _, value in camera.setActive(value == .active) }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            camera.setActive(false)
        }
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
