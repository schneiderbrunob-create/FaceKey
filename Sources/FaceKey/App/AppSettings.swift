//
//  AppSettings.swift
//  FaceKey
//
//  User preferences, written straight through to UserDefaults. Modelled on Glance's GlanceSettings,
//  reduced to what FaceKey uses.
//

import Foundation
import Observation

/// How the lock-screen animation looks. From Glance.
enum UnlockAnimationStyle: String, CaseIterable, Identifiable {
    case none
    /// A small lock glyph beside the notch.
    case minimal
    /// The notch expands into a panel that plays the scan, success and failure animations.
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .original: return "Full"
        }
    }

    static let selectableCases: [UnlockAnimationStyle] = [.original, .minimal]
}

/// What starts a face scan on the lock screen.
enum UnlockTrigger: String, CaseIterable, Identifiable {
    /// The display came back on: lid opened, key pressed after sleep, or the screen saver stopped.
    case onWake
    /// The screen has just been locked. Off by default, since it would undo a lock you asked for while still sitting there.
    case onLock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onWake: return "When the Mac wakes"
        case .onLock: return "Right after the screen locks"
        }
    }
}

/// How far from the camera a face may be and still count. Stored as the minimum face width, as a fraction of the
/// frame width. Glance's levels stop at 15%; these go lower because frames are now scanned at full resolution,
/// so a small face still has enough pixels to recognise.
enum DetectionDistance: String, CaseIterable, Identifiable {
    case close, normal, far, farthest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .close: return "Close"
        case .normal: return "Normal"
        case .far: return "Far"
        case .farthest: return "Farthest"
        }
    }

    var minimumFaceWidth: Float {
        switch self {
        case .close: return 0.19
        case .normal: return 0.13
        case .far: return 0.09
        case .farthest: return 0.06
        }
    }

    static func nearest(to width: Float) -> DetectionDistance {
        allCases.min { abs($0.minimumFaceWidth - width) < abs($1.minimumFaceWidth - width) } ?? .far
    }
}

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let isFaceUnlockEnabled = "isFaceUnlockEnabled"
        static let matchThreshold = "matchThreshold"
        static let livenessChecksEnabled = "livenessChecksEnabled"
        static let livenessMode = "livenessMode"
        static let minimumFaceWidth = "minimumFaceWidth"
        static let unlockTriggers = "unlockTriggers"
        static let scanSeconds = "scanSeconds"
        static let autoRetryOnce = "autoRetryOnce"
        static let autoLockDays = "autoLockDays"
        static let cameraID = "cameraID"
        static let showUnlockAnimation = "showUnlockAnimation"
        static let unlockAnimationStyle = "unlockAnimationStyle"
        static let retryOnHover = "retryOnHover"
        static let hapticFeedbackEnabled = "hapticFeedbackEnabled"
    }

    static let matchThresholdRange: ClosedRange<Float> = 0.55...0.80
    static let scanSecondsRange = 3...10
    static let autoLockDayChoices = [1, 7, 14, 30]

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Off until the user switches it on, after enrolling and trying the recognition test.
    var isFaceUnlockEnabled: Bool {
        didSet { defaults.set(isFaceUnlockEnabled, forKey: Key.isFaceUnlockEnabled) }
    }
    /// Cosine similarity a face must reach against an enrolled identity. Higher is stricter.
    var matchThreshold: Float {
        didSet { defaults.set(matchThreshold, forKey: Key.matchThreshold) }
    }
    /// Off means recognition alone decides an unlock, so a photo of you would pass.
    var livenessChecksEnabled: Bool {
        didSet { defaults.set(livenessChecksEnabled, forKey: Key.livenessChecksEnabled) }
    }
    /// Light only rejects obvious spoofs; Heavy also needs a positive sign of a real face (blink, depth, head turn).
    var livenessMode: LivenessMode {
        didSet { defaults.set(livenessMode.rawValue, forKey: Key.livenessMode) }
    }
    /// Faces narrower than this fraction of the frame are treated as bystanders.
    var minimumFaceWidth: Float {
        didSet {
            defaults.set(minimumFaceWidth, forKey: Key.minimumFaceWidth)
            FaceRecognitionPipeline.minimumProminentFaceWidth = minimumFaceWidth
        }
    }
    var unlockTriggers: Set<UnlockTrigger> {
        didSet {
            if unlockTriggers.isEmpty {
                unlockTriggers = [.onWake]
                return
            }
            defaults.set(unlockTriggers.map(\.rawValue), forKey: Key.unlockTriggers)
        }
    }
    /// How long one scan keeps the camera on before giving up.
    var scanSeconds: Int {
        didSet {
            let clamped = min(max(scanSeconds, Self.scanSecondsRange.lowerBound), Self.scanSecondsRange.upperBound)
            guard clamped == scanSeconds else {
                scanSeconds = clamped
                return
            }
            defaults.set(scanSeconds, forKey: Key.scanSeconds)
        }
    }
    /// One extra scan after a failed one, per lock.
    var autoRetryOnce: Bool {
        didSet { defaults.set(autoRetryOnce, forKey: Key.autoRetryOnce) }
    }
    /// Days of not being used before the session re-locks and needs Touch ID again.
    var autoLockDays: Int {
        didSet { defaults.set(autoLockDays, forKey: Key.autoLockDays) }
    }
    /// `AVCaptureDevice.uniqueID` of the chosen camera, or nil for the built-in one.
    var cameraID: String? {
        didSet { defaults.set(cameraID, forKey: Key.cameraID) }
    }

    // MARK: - Lock-screen animation (read by Glance's notch overlay)

    /// Off means scans run with nothing on screen.
    var showUnlockAnimation: Bool {
        didSet { defaults.set(showUnlockAnimation, forKey: Key.showUnlockAnimation) }
    }
    var unlockAnimationStyle: UnlockAnimationStyle {
        didSet { defaults.set(unlockAnimationStyle.rawValue, forKey: Key.unlockAnimationStyle) }
    }
    var effectiveUnlockAnimationStyle: UnlockAnimationStyle {
        showUnlockAnimation ? unlockAnimationStyle : .none
    }
    /// Moving the pointer onto the notch on the lock screen starts another scan.
    var retryOnHover: Bool {
        didSet { defaults.set(retryOnHover, forKey: Key.retryOnHover) }
    }
    var hapticFeedbackEnabled: Bool {
        didSet { defaults.set(hapticFeedbackEnabled, forKey: Key.hapticFeedbackEnabled) }
    }
    /// The overlay closes itself after this long. It is deliberately longer than any scan can run, so the
    /// unlock coordinator, not this timer, decides when a scan is over.
    var faceDetectionSeconds: Int { scanSeconds + 9 }
    /// FaceKey always shows the animation on the built-in display's notch, or the main display without one.
    var preferredDisplayID: String? { nil }

    private init() {
        showUnlockAnimation = defaults.object(forKey: Key.showUnlockAnimation) as? Bool ?? true
        unlockAnimationStyle = defaults.string(forKey: Key.unlockAnimationStyle)
            .flatMap(UnlockAnimationStyle.init(rawValue:)).flatMap { $0 == .none ? nil : $0 } ?? .original
        retryOnHover = defaults.object(forKey: Key.retryOnHover) as? Bool ?? true
        hapticFeedbackEnabled = defaults.object(forKey: Key.hapticFeedbackEnabled) as? Bool ?? true
        isFaceUnlockEnabled = defaults.object(forKey: Key.isFaceUnlockEnabled) as? Bool ?? false
        matchThreshold = defaults.object(forKey: Key.matchThreshold) as? Float ?? 0.66
        livenessChecksEnabled = defaults.object(forKey: Key.livenessChecksEnabled) as? Bool ?? true
        // Heavy by default: Light lets a printed photo through. Glance ships Light as its default.
        livenessMode = defaults.string(forKey: Key.livenessMode).flatMap(LivenessMode.init(rawValue:)) ?? .heavy
        minimumFaceWidth = defaults.object(forKey: Key.minimumFaceWidth) as? Float ?? DetectionDistance.far.minimumFaceWidth
        let storedTriggers = (defaults.array(forKey: Key.unlockTriggers) as? [String])?
            .compactMap(UnlockTrigger.init(rawValue:))
        unlockTriggers = storedTriggers.map(Set.init).flatMap { $0.isEmpty ? nil : $0 } ?? [.onWake]
        scanSeconds = (defaults.object(forKey: Key.scanSeconds) as? Int)
            .map { min(max($0, Self.scanSecondsRange.lowerBound), Self.scanSecondsRange.upperBound) } ?? 5
        autoRetryOnce = defaults.object(forKey: Key.autoRetryOnce) as? Bool ?? true
        autoLockDays = defaults.object(forKey: Key.autoLockDays) as? Int ?? 7
        cameraID = defaults.string(forKey: Key.cameraID)

        // The pipeline reads this from background tasks, so it keeps its own copy.
        FaceRecognitionPipeline.minimumProminentFaceWidth = minimumFaceWidth
    }
}
