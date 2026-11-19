import Foundation

@main
struct ExposureChecks {
    static func main() {
        let durations = (1.0 / 8000)...1.0
        let isos = 25.0...1600.0
        let initial = ExposureValues(duration: 1.0 / 125, iso: 100)

        for mode in [ExposureMode.shutterPriority, .isoPriority] {
            for offset in [-3.0, 3.0] {
                let next = initial.meteredAdjustment(mode: mode, offset: offset, durations: durations, isos: isos)!
                if mode == .shutterPriority {
                    precondition(next.duration == initial.duration, "Shutter priority changed the pinned shutter")
                    precondition(offset > 0 ? next.iso < initial.iso : next.iso > initial.iso, "ISO correction has wrong sign")
                } else {
                    precondition(next.iso == initial.iso, "ISO priority changed the pinned ISO")
                    precondition(offset > 0 ? next.duration < initial.duration : next.duration > initial.duration, "Shutter correction has wrong sign")
                }
                precondition(durations.contains(next.duration) && isos.contains(next.iso), "Correction exceeds device limits")
            }

            for brightness in [0.25, 0.5, 2.0, 4.0] {
                var current = initial
                let target = initial.duration * initial.iso
                for _ in 0..<30 {
                    let offset = log2(current.duration * current.iso * brightness / target)
                    if let next = current.meteredAdjustment(mode: mode, offset: offset, durations: durations, isos: isos) {
                        current = next
                    }
                }
                precondition(abs(log2(current.duration * current.iso * brightness / target)) <= 0.1, "Meter did not converge")
                precondition(mode == .shutterPriority ? current.duration == initial.duration : current.iso == initial.iso, "Convergence changed pinned value")
            }
        }

        for mode in [ExposureMode.shutterPriority, .isoPriority] {
            for compensation in [-1.0, 0.0, 1.0] {
                for brightness in [0.5, 1.0, 2.0] {
                    var current = initial
                    let target = initial.duration * initial.iso
                    for _ in 0..<30 {
                        let offset = log2(current.duration * current.iso * brightness / target)
                        if let next = current.meteredAdjustment(mode: mode, offset: offset, compensation: compensation, durations: durations, isos: isos) {
                            current = next
                        }
                    }
                    let achieved = log2(current.duration * current.iso * brightness / target)
                    precondition(abs(achieved - compensation) <= 0.1, "Meter did not reach the compensated target")
                    precondition(mode == .shutterPriority ? current.duration == initial.duration : current.iso == initial.iso, "Compensation changed pinned value")
                }
                precondition(initial.meteredAdjustment(mode: mode, offset: compensation, compensation: compensation, durations: durations, isos: isos) == nil, "Meter changed a settled compensated exposure")
            }
            for compensation in [Double.infinity, Double.nan] {
                precondition(initial.meteredAdjustment(mode: mode, offset: 0, compensation: compensation, durations: durations, isos: isos) == nil)
            }
        }

        let high = ExposureValues(duration: 0.75, iso: 1200)
        precondition(high.meteredAdjustment(mode: .shutterPriority, offset: -100, durations: durations, isos: isos)?.iso == isos.upperBound)
        precondition(high.meteredAdjustment(mode: .isoPriority, offset: -100, durations: durations, isos: isos)?.duration == durations.upperBound)
        let low = ExposureValues(duration: durations.lowerBound, iso: isos.lowerBound)
        precondition(low.meteredAdjustment(mode: .shutterPriority, offset: 3, durations: durations, isos: isos) == nil)
        precondition(low.meteredAdjustment(mode: .isoPriority, offset: 3, durations: durations, isos: isos) == nil)
        for offset in [0.0, 0.05, -0.05, Double.infinity, Double.nan] {
            precondition(initial.meteredAdjustment(mode: .shutterPriority, offset: offset, durations: durations, isos: isos) == nil)
        }
        for mode in [ExposureMode.automatic, .manual] {
            precondition(initial.meteredAdjustment(mode: mode, offset: 2, durations: durations, isos: isos) == nil)
        }
        print("Exposure checks passed: pinned values, correction direction, compensated convergence, limits, and invalid readings.")
    }
}
