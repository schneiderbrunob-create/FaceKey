//
//  FaceUnlockCoordinator.swift
//  FaceKey
//
//  Adapted from Glance (MIT, © 2026 Jonathan Zhou). Connects lock/wake events to a camera scan and, on a match that
//  also passes liveness, to typing the stored password.
//
//  Changed from Glance:
//  - No space-key trigger. The notch overlay is driven as in Glance, except that the coordinator closes it when a
//    scan ends instead of relying on the overlay's own timer, because a scan here can outlast the scan limit.
//  - Added a rejected-password guard: if the Mac is still locked after the password was typed, that counts as a
//    failure, and after two in a row face unlock switches itself off rather than keep typing a wrong password.
//  - Added a short activity log, since there is nothing to look at while a scan runs.
//  - A scan whose face already matches is given extra time for the liveness proof instead of ending at the scan
//    limit, and the app asks macOS not to throttle it while a scan runs (it has no window on the lock screen).
//
//  Known limitation (same as Glance): liveness defeats a photo but not a replayed video of the owner.
//

import Foundation
import CoreGraphics
import Observation
import AVFoundation

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let credentials: CredentialController
    let pipeline: FaceRecognitionPipeline
    let lockMonitor = LockMonitor()
    let camera = CameraManager()

    /// Persisted. Switching off cancels any scan in flight.
    var isEnabled: Bool {
        didSet {
            AppSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled { cancelScanning() }
        }
    }

    private(set) var statusMessage = "Idle"
    /// Newest first, capped. Timestamps are baked into the text.
    private(set) var activityLog: [String] = []

    private var scanWindowDuration: TimeInterval { TimeInterval(AppSettings.shared.scanSeconds) }
    /// A wake often catches the owner still looking away, so only a sustained non-match counts as a wrong face.
    private let wrongFaceGraceDuration: Duration = .seconds(2)
    /// Extra time granted past the scan limit while the face in view matches and only the liveness proof is missing.
    private let livenessGraceDuration: TimeInterval = 7

    private var hasArmedForCurrentLock = false
    /// One-shot per lock, so a retry cannot itself retry and run the camera for the whole time the Mac is locked.
    private var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`; a cycle stops touching shared state once superseded.
    private var scanGeneration = 0
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open fires several wake signals within a few hundred ms; anything inside this window is the same wake.
    private let rearmDebounce: Duration = .seconds(2)
    private var autoRetryTask: Task<Void, Never>?
    private let retryDelay: Duration = .seconds(1)

    /// When off there is nothing on screen at all; every overlay call below is conditioned on this.
    private var showsUI: Bool { AppSettings.shared.showUnlockAnimation }

    /// Passwords typed that did not unlock the Mac, in a row.
    private var rejectedPasswordCount = 0
    private let maxRejectedPasswords = 2
    private var verificationTask: Task<Void, Never>?

    init(credentials: CredentialController, pipeline: FaceRecognitionPipeline) {
        self.credentials = credentials
        self.pipeline = pipeline
        self.isEnabled = AppSettings.shared.isFaceUnlockEnabled
        observeLockAndWakeEvents()
    }

    private func log(_ message: String) {
        statusMessage = message
        DebugLog.write("unlock: \(message)")
        let stamp = Date().formatted(date: .omitted, time: .standard)
        activityLog.insert("\(stamp)  \(message)", at: 0)
        if activityLog.count > 40 { activityLog.removeLast(activityLog.count - 40) }
    }

    /// Re-subscribes on every change, since `withObservationTracking` fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLockAndWakeEvents()
                // CGSession's reported state can lag the true state right after wake.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.evaluateTrigger()
            }
        }
    }

    private func evaluateTrigger() {
        guard LockMonitor.isScreenActuallyLocked() else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            cancelScanning()
            return
        }
        guard !lockMonitor.isSleeping else { return }

        // A wake is an explicit "let me back in", so it clears the one-shot guard, unless it is part of the same burst.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        guard isEnabled, !hasArmedForCurrentLock else { return }
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else { return }
        // A deselected trigger means "do not scan by itself". With the animation on, the notch still appears so
        // that moving the pointer onto it can start a scan by hand.
        let shouldAutoScan = AppSettings.shared.unlockTriggers.contains(signal)
        guard showsUI || shouldAutoScan else { return }

        guard SecureCredentialManager.isSessionUnlocked else {
            log("Face unlock is on, but the session is locked. Authenticate once from the FaceKey menu.")
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            log("Face unlock is on, but no password is stored yet.")
            return
        }
        guard !FaceEnrollmentStore.shared.activeIdentities.isEmpty else {
            log("Face unlock is on, but no face is enrolled.")
            return
        }
        // On the lock screen the camera permission dialog cannot be answered, so a scan there would just hang.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            log("Face unlock is on, but this build has no camera permission yet. Run “Test recognition” once and allow the camera.")
            return
        }
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            log("Face unlock is on, but Accessibility is not granted, so the password cannot be typed.")
            return
        }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        Task { [weak self] in
            // Brief buffer past the login window's entrance.
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.arm(autoScan: shouldAutoScan)
        }
    }

    /// Shows the closed notch silhouette (when the animation is on) and starts scanning if this trigger is selected.
    private func arm(autoScan: Bool) {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        guard showsUI else {
            startScanCycle()
            return
        }
        NotchOverlayController.shared.arm { [weak self] in
            self?.startScanCycle()
        }
        if autoScan {
            startScanCycle()
        }
    }

    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// nil for signals that should not start anything, including the nil `lastEvent` of the very first observation.
    private func requiredTrigger(for event: LockEventKind?) -> UnlockTrigger? {
        switch event {
        case .wake: return .onWake
        case .screenLocked: return .onLock
        case .screenUnlocked, .willSleep, nil: return nil
        }
    }

    private func cancelScanning() {
        scanTask?.cancel()
        scanTask = nil
        // Makes any cycle still suspended at `await camera.start()` inert.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        camera.stop()
        NotchOverlayController.shared.disarm()
    }

    private func startScanCycle() {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }

    /// `generation` keeps overlapping cycles from stepping on each other: cancellation is cooperative, so a superseded
    /// cycle still runs to the end of this function, and its `camera.stop()` would otherwise kill the newer cycle's camera.
    private func runScanCycle(generation: Int) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }

        await camera.start()
        guard generation == scanGeneration else { return }

        if let error = camera.errorMessage {
            log(error)
            camera.stop()
            return
        }

        let showsUI = self.showsUI
        if showsUI {
            NotchOverlayController.shared.beginScanning()
        }
        log("Looking for your face…")
        // Without this, macOS throttles a windowless background app's timers, which halved the scan's frame rate
        // on the lock screen (13 frames a second against 29 in the settings window).
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Face unlock scan"
        )
        let outcome = await observeScanWindow(
            deadline: Date().addingTimeInterval(scanWindowDuration), requireOverlayScanning: showsUI
        )
        ProcessInfo.processInfo.endActivity(activity)

        // A newer cycle now owns the camera and the overlay.
        guard generation == scanGeneration else { return }
        camera.stop()

        let overlay = NotchOverlayController.shared
        let retryAfterFailure = showsUI ? overlay.failureHoldDuration : retryDelay
        switch outcome {
        case .matched(let detail):
            log(detail)
            if showsUI { overlay.finish(success: true) }
            verifyUnlockSoon()
        case .typingFailed:
            // CredentialController already recorded why.
            log(credentials.statusMessage)
            if showsUI { overlay.finish(success: false) }
        case .consistentlyWrongFace(let detail):
            log("Face not recognized. \(detail)")
            if showsUI { overlay.finish(success: false) }
            scheduleAutoRetryIfEnabled(after: retryAfterFailure)
        case .spoofSuspected(let reason):
            log("Could not confirm a live face. \(reason)")
            if showsUI { overlay.finish(success: false) }
            scheduleAutoRetryIfEnabled(after: retryAfterFailure)
        case .livenessNotConfirmed(let detail):
            log("Recognized you, but saw no proof of a live face (a blink or a small head movement) in time. \(detail)")
            if showsUI { overlay.finish(success: false) }
            scheduleAutoRetryIfEnabled(after: retryAfterFailure)
        case .noResolution(let detail):
            log("No match before the scan timed out. \(detail)")
            // Nobody there is not a failure worth an animation; the panel just closes.
            if showsUI { await overlay.collapse() }
            scheduleAutoRetryIfEnabled(after: retryDelay)
        }
    }

    /// The lock screen gives no result back, so the only way to learn whether the typed password was accepted is to
    /// look again a few seconds later.
    private func verifyUnlockSoon() {
        verificationTask?.cancel()
        verificationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            if LockMonitor.isScreenActuallyLocked() {
                self.rejectedPasswordCount += 1
                if self.rejectedPasswordCount >= self.maxRejectedPasswords {
                    self.isEnabled = false
                    self.log("Face unlock switched itself off: the stored password was typed \(self.rejectedPasswordCount) times and the Mac stayed locked. Save your current password again in FaceKey.")
                } else {
                    self.log("The password was typed but the Mac stayed locked.")
                }
            } else {
                self.rejectedPasswordCount = 0
            }
        }
    }

    /// `delay` waits out whatever the overlay is still showing, so the retry does not start underneath it.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard AppSettings.shared.autoRetryOnce, !hasAutoRetriedForCurrentLock else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // The user may have unlocked by hand, or retried by hovering the notch, while this waited.
            guard LockMonitor.isScreenActuallyLocked(), self.isEnabled else { return }
            if self.showsUI {
                guard NotchOverlayController.shared.phase == .closed else { return }
            }
            self.startScanCycle()
        }
    }

    private enum ScanOutcome {
        case matched(String)
        case typingFailed
        case consistentlyWrongFace(String)
        /// A deny cue (glare, device rectangle) fired: rejected as a spoof regardless of match.
        case spoofSuspected(String)
        case noResolution(String)
        /// The face matched but no confirm cue fired before the extended deadline.
        case livenessNotConfirmed(String)
    }

    /// Recognition and liveness run side by side and each latches when it succeeds, so the unlock fires the moment the
    /// second one lands. Liveness never fails the scan by staying undecided; it just keeps scanning until `deadline`.
    /// `requireOverlayScanning` ends the scan if the overlay leaves its scanning state by itself.
    private func observeScanWindow(deadline: Date, requireOverlayScanning: Bool) async -> ScanOutcome {
        let settings = AppSettings.shared
        let livenessEnabled = settings.livenessChecksEnabled
        let matchThreshold = settings.matchThreshold
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { AppSettings.shared.livenessMode }
        liveness.tuningProvider = { .faceKey }

        var wrongFaceStartedAt: ContinuousClock.Instant?
        /// Cleared the moment a detected face fails to match, so a latched match cannot be handed to whoever steps in next.
        var readyMatch: ScoredIdentity?
        var livenessConfirmed = !livenessEnabled
        /// Last frame's selected face, passed back so selection stays on the same person.
        var lastFaceBoundingBox: CGRect?
        /// Tells "no new camera frame yet" from "fresh frame"; a repeated frame would corrupt the liveness motion signal.
        var lastProcessedFrameID: UInt64?
        var statistics = ScanStatistics()
        let scanStartedAt = Date()
        var firstMatchAfter: TimeInterval?
        let minimumFaceWidth = settings.minimumFaceWidth
        func summary() -> String {
            let matchNote = firstMatchAfter.map { String(format: "first match at %.1fs", $0) } ?? "never matched"
            return "\(statistics.summary(minimumFaceWidth: minimumFaceWidth, threshold: matchThreshold)) \(matchNote); \(statistics.eyeNote)."
        }

        let extendedDeadline = deadline.addingTimeInterval(livenessGraceDuration)
        // Past the normal limit the scan continues only while the face in view is a match.
        while !Task.isCancelled, Date() < deadline || (readyMatch != nil && Date() < extendedDeadline),
              !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning {
            guard LockMonitor.isScreenActuallyLocked() else { return .noResolution("The screen was unlocked another way.") }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let analysis = await Task.detached(priority: .userInitiated) {
                FrameAnalyzer.analyze(frame, pipeline: pipeline, preferNear: previousBoundingBox)
            }.value
            statistics.record(analysis)

            guard let result = analysis.result, let livenessFrame = analysis.livenessFrame else {
                wrongFaceStartedAt = nil
                lastFaceBoundingBox = nil
                readyMatch = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Fed regardless of match, so liveness stays an independent gate.
            var confirmingCue: LivenessCue?
            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    // Overrides everything, including a match and any earlier confirmation.
                    return .spoofSuspected("\(snapshot.decision.denialReason ?? "") (\(statistics.deviceNote))")
                case .confirmed(let cue):
                    livenessConfirmed = true
                    confirmingCue = cue
                case .pending:
                    break
                }
            }

            // `activeIdentities`: someone switched off stays enrolled but must not unlock.
            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold)
            if let top = scored.first { statistics.record(similarity: top.centroidSimilarity) }

            if let matched {
                wrongFaceStartedAt = nil
                readyMatch = matched
                if firstMatchAfter == nil { firstMatchAfter = Date().timeIntervalSince(scanStartedAt) }
            } else {
                readyMatch = nil
                if wrongFaceStartedAt == nil {
                    wrongFaceStartedAt = .now
                }
                if let started = wrongFaceStartedAt, ContinuousClock.now - started >= wrongFaceGraceDuration {
                    return .consistentlyWrongFace(summary())
                }
            }

            if let readyMatch, livenessConfirmed {
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                let detail = String(
                    format: "Matched %@ at %.3f after %.1fs (first match at %.1fs), %@. Password typed.",
                    readyMatch.identity.name, readyMatch.centroidSimilarity,
                    Date().timeIntervalSince(scanStartedAt), firstMatchAfter ?? 0, livenessNote
                )
                let typed = await credentials.typeStoredPasswordOnLockScreen()
                return typed ? .matched(detail) : .typingFailed
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return readyMatch != nil ? .livenessNotConfirmed(summary()) : .noResolution(summary())
    }
}
