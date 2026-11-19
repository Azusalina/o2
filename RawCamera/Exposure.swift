import Foundation

enum ExposureMode: String, CaseIterable {
    case automatic = "Auto"
    case manual = "Manual"
    case shutterPriority = "Shutter priority"
    case isoPriority = "ISO priority"

    var isPriority: Bool { self == .shutterPriority || self == .isoPriority }
}

struct ExposureValues: Equatable {
    let duration: Double
    let iso: Double

    func meteredAdjustment(mode: ExposureMode, offset: Double, durations: ClosedRange<Double>, isos: ClosedRange<Double>) -> ExposureValues? {
        guard mode.isPriority, offset.isFinite, abs(offset) > 0.1,
              duration.isFinite, duration > 0, iso.isFinite, iso > 0 else { return nil }
        // Positive meter offsets mean overexposure. Dampen corrections and limit
        // each update to one stop so delayed metering cannot cause large jumps.
        let factor = exp2(min(1, max(-1, -offset * 0.6)))
        switch mode {
        case .shutterPriority:
            let nextISO = min(isos.upperBound, max(isos.lowerBound, iso * factor))
            guard abs(log2(nextISO / iso)) > 0.01 else { return nil }
            return ExposureValues(duration: duration, iso: nextISO)
        case .isoPriority:
            let nextDuration = min(durations.upperBound, max(durations.lowerBound, duration * factor))
            guard abs(log2(nextDuration / duration)) > 0.01 else { return nil }
            return ExposureValues(duration: nextDuration, iso: iso)
        default:
            return nil
        }
    }
}
