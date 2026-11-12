//
//  LivenessScoring.swift
//  glance
//
//  `LivenessFrame` plus the two cross-frame confirm cues that read it directly:
//  `poseDepthConsistency` and `blinkDynamics`. No `import Vision`/AppKit, so it
//  compiles standalone for `tools/liveness_selftest.swift`.
//

import Foundation
import CoreGraphics

/// One frame's worth of liveness-relevant measurements — already normalized, no Vision needed.
/// Populated by `LivenessFeatureExtractor.extract(from:)` from a real camera frame, or built
/// directly from synthetic data by `tools/liveness_selftest.swift`.
struct LivenessFrame {
    let timestamp: Date
    /// Every landmark point Vision found this frame, tagged by region — see `LandmarkGeometry.allPoints`.
    let landmarks: [LandmarkPoint]
    /// Distance between the two eye centers — the normalization scale for every ratio below.
    let interocularDistance: CGFloat?
    let yaw: Float?
    let leftEyeAspectRatio: CGFloat?
    let rightEyeAspectRatio: CGFloat?
    /// `(noseCentroid.x - eyeMidpoint.x) / interocularDistance` — tracks `tan(yaw)` on a real
    /// 3D face but stays constant on any flat presentation. See `poseDepthConsistency` below.
    let noseOffsetRatio: CGFloat?
    /// Whether landmarks came from full 5-point detection rather than a degraded fallback;
    /// cues that need precision skip frames where this is false.
    let hasReliableLandmarks: Bool
    /// Fraction of the face bounding box covered by a detected device-shaped rectangle;
    /// `nil` when detection wasn't run or found nothing. Read by the `deviceDetected` deny cue.
    let deviceOverlapFraction: CGFloat?
    /// Specular-highlight measurements from a native-resolution face crop; `nil` when no crop
    /// was available, in which case the `glossGlare` deny cue abstains.
    let glare: GlareSample?

    /// Explicit init so `glare` can default to `nil` — a defaulted `let` property is otherwise
    /// excluded from Swift's synthesized memberwise init rather than becoming optional.
    init(
        timestamp: Date,
        landmarks: [LandmarkPoint],
        interocularDistance: CGFloat?,
        yaw: Float?,
        leftEyeAspectRatio: CGFloat?,
        rightEyeAspectRatio: CGFloat?,
        noseOffsetRatio: CGFloat?,
        hasReliableLandmarks: Bool,
        deviceOverlapFraction: CGFloat?,
        glare: GlareSample? = nil
    ) {
        self.timestamp = timestamp
        self.landmarks = landmarks
        self.interocularDistance = interocularDistance
        self.yaw = yaw
        self.leftEyeAspectRatio = leftEyeAspectRatio
        self.rightEyeAspectRatio = rightEyeAspectRatio
        self.noseOffsetRatio = noseOffsetRatio
        self.hasReliableLandmarks = hasReliableLandmarks
        self.deviceOverlapFraction = deviceOverlapFraction
        self.glare = glare
    }
}

nonisolated enum LivenessScoring {
    // MARK: - Depth/pose consistency (confirm cue)

    /// Correlates nose-offset-from-eye-midline against tan(yaw): tracks yaw on a real face,
    /// stays constant on a flat presentation. Abstains at small yaw ranges where the
    /// predicted displacement is below Vision's landmark noise floor.
    static func poseDepthConsistency(_ window: [LivenessFrame]) -> CueReading {
        let pairs = window.compactMap { frame -> (CGFloat, CGFloat)? in
            guard let offset = frame.noseOffsetRatio, let yaw = frame.yaw, frame.hasReliableLandmarks else { return nil }
            return (offset, CGFloat(tan(yaw)))
        }
        guard pairs.count >= 4 else { return .none }

        let yaws = pairs.map(\.1)
        guard let minYaw = yaws.min(), let maxYaw = yaws.max() else { return .none }
        let yawRange = abs(atan(maxYaw) - atan(minYaw))
        // Below ~12 degrees the predicted displacement is sub-pixel — matches
        // `GeometryTuning.minYawRangeDegrees`, which gates on the same underlying limit.
        let minMeasurableRange: CGFloat = 12 * .pi / 180
        guard yawRange > minMeasurableRange else { return .none }

        guard let correlation = pearsonCorrelation(pairs.map(\.0), pairs.map(\.1)) else { return .none }
        let level = Float(clamp((correlation + 1) / 2, 0, 1))
        // Confidence ramps in over the next ~15 degrees past the minimum —
        // more rotation observed, more trustworthy the correlation is.
        let confidence = Float(clamp((yawRange - minMeasurableRange) / (15 * .pi / 180), 0, 1))
        return CueReading(level: level, confidence: confidence)
    }

    private static func pearsonCorrelation(_ xs: [CGFloat], _ ys: [CGFloat]) -> CGFloat? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = CGFloat(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var covariance: CGFloat = 0, varX: CGFloat = 0, varY: CGFloat = 0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX, dy = ys[i] - meanY
            covariance += dx * dy
            varX += dx * dx
            varY += dy * dy
        }
        guard varX > 0, varY > 0 else { return nil }
        return covariance / (varX.squareRoot() * varY.squareRoot())
    }

    // MARK: - Blink dynamics (confirm cue)

    /// Looks for a dip-and-recovery in eye-aspect-ratio. Never mandatory — a short window
    /// often contains no blink at all, which abstains rather than fails. Thresholds are loose
    /// because Vision's landmark model doesn't fully collapse the eyelid contour during a real
    /// blink; recovery is checked within a radius since a blink can span several frames at ~20fps.
    ///
    /// Changed from Glance, after measurements on this Mac:
    /// - Every dip in the window is considered, not only its single lowest point. Glance looks at the lowest value
    ///   alone, so one low reading without an open-eye frame before it (the first frames after the camera starts,
    ///   or looking down while waking the Mac) hid every real blink until it aged out of the 2-second window.
    /// - Because every dip now counts, a dip has to be a convincing one. Openness is compared with the window's
    ///   median (the typical open eye) instead of its maximum (one noisy frame), the average must fall below half
    ///   of that, both eyes must close together, and the eyes must be back above 80% on each side of the dip.
    ///   Glance's 65% of maximum sits inside the frame-to-frame jitter seen here (dips to 40-60% with no blink),
    ///   while real blinks reached 17-33%.
    /// - Recovery is accepted within a time span around the dip as well as within 3 frames, since the frame rate
    ///   here (~29 fps) differs from the ~20 fps the 3-frame radius was tuned for.
    static func blinkDynamics(_ window: [LivenessFrame]) -> CueReading {
        let samples = window.compactMap { frame -> (left: CGFloat, right: CGFloat, both: CGFloat, time: Date)? in
            guard let l = frame.leftEyeAspectRatio, let r = frame.rightEyeAspectRatio else { return nil }
            return (l, r, (l + r) / 2, frame.timestamp)
        }
        guard samples.count >= 6 else { return .none }

        let typicalBoth = median(samples.map(\.both))
        let typicalLeft = median(samples.map(\.left))
        let typicalRight = median(samples.map(\.right))
        guard typicalBoth > 0, typicalLeft > 0, typicalRight > 0 else { return .none }

        let recoveryRadius = 3
        let recoverySpan: TimeInterval = 0.18

        for index in 1..<(samples.count - 1) {
            let dip = samples[index]
            guard dip.both < blinkDipLevel * typicalBoth,
                  dip.left < blinkPerEyeLevel * typicalLeft, dip.right < blinkPerEyeLevel * typicalRight,
                  dip.both <= samples[index - 1].both, dip.both <= samples[index + 1].both
            else { continue }
            let before = samples[..<index]
            let after = samples[(index + 1)...]
            let openLevel = blinkOpenLevel * typicalBoth
            let openBefore = before.suffix(recoveryRadius).contains { $0.both > openLevel }
                || before.contains { dip.time.timeIntervalSince($0.time) <= recoverySpan && $0.both > openLevel }
            let openAfter = after.prefix(recoveryRadius).contains { $0.both > openLevel }
                || after.contains { $0.time.timeIntervalSince(dip.time) <= recoverySpan && $0.both > openLevel }
            if openBefore && openAfter {
                return CueReading(level: 1, confidence: 1)
            }
        }
        return .none
    }

    /// Fractions of the typical (median) eye openness. Shared with the scan statistics so the log speaks the same terms.
    /// Each can be overridden with `defaults write local.facekey <name> <value>`, so they can be calibrated
    /// against real scans without rebuilding the app (a rebuild resets its permissions).
    static var blinkDipLevel: CGFloat { tunable("blinkDipLevel", 0.5) }
    static var blinkPerEyeLevel: CGFloat { tunable("blinkPerEyeLevel", 0.6) }
    static var blinkOpenLevel: CGFloat { tunable("blinkOpenLevel", 0.8) }

    private static func tunable(_ name: String, _ fallback: CGFloat) -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: name)
        return stored > 0 && stored < 1 ? CGFloat(stored) : fallback
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }
}
