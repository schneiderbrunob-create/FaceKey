//
//  RecognitionTester.swift
//  FaceKey
//
//  Runs the same recognition and liveness checks as a real unlock, with the screen unlocked and nothing typed,
//  so the match threshold, detection distance and liveness mode can be tried out safely. Unlike a real scan it
//  says why nothing happened: no face, a face too far away, or a similarity below the threshold.
//
//  It ends the way a real scan ends: at the first moment a match and liveness are both satisfied (the password
//  would be typed then), or as soon as a liveness deny cue fires (the scan would be abandoned then).
//

import Foundation
import CoreGraphics
import Observation

@Observable
@MainActor
final class RecognitionTester {
    let camera = CameraManager()
    private let pipeline: FaceRecognitionPipeline

    private(set) var isRunning = false
    /// Every face Vision sees, including ones too far away to count, so the preview always shows what was detected.
    private(set) var detectedFaces: [DetectedFace] = []
    private(set) var faceLine = "Not started."
    private(set) var matchLine = ""
    private(set) var livenessLine = ""
    private(set) var verdictLine = ""
    private(set) var wouldUnlock = false

    private var task: Task<Void, Never>?
    private let maxDuration: TimeInterval = 20

    init(pipeline: FaceRecognitionPipeline) {
        self.pipeline = pipeline
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        wouldUnlock = false
        faceLine = "Starting camera…"
        matchLine = ""
        livenessLine = ""
        verdictLine = ""
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        camera.stop()
        detectedFaces = []
        isRunning = false
    }

    private func run() async {
        await camera.start()
        if let error = camera.errorMessage {
            faceLine = error
            DebugLog.write("test: camera error: \(error)")
            isRunning = false
            return
        }

        let settings = AppSettings.shared
        let livenessEnabled = settings.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { AppSettings.shared.livenessMode }
        liveness.tuningProvider = { .faceKey }
        let threshold = settings.matchThreshold
        let minimumWidth = settings.minimumFaceWidth

        var livenessConfirmed = !livenessEnabled
        var livenessNote = livenessEnabled ? "not confirmed" : "off"
        var deniedBy: LivenessCue?
        var statistics = ScanStatistics()
        var lastFaceBoundingBox: CGRect?
        var lastFrameID: UInt64?
        var frameSize = ""
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(maxDuration)
        var firstMatchAfter: TimeInterval?
        livenessLine = livenessEnabled ? "Liveness: waiting…" : "Liveness: switched off."
        DebugLog.write(String(
            format: "test: started; threshold %.2f, minimum face width %.0f%%, liveness %@",
            threshold, minimumWidth * 100, livenessEnabled ? settings.livenessMode.rawValue : "off"
        ))

        while Date() < deadline, !Task.isCancelled, !wouldUnlock, deniedBy == nil {
            guard let frame = camera.currentFrame, frame.id != lastFrameID else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFrameID = frame.id
            frameSize = "\(Int(frame.sourceSize.width))x\(Int(frame.sourceSize.height)) scanned at \(frame.image.width)x\(frame.image.height)"

            let pipeline = self.pipeline
            let previous = lastFaceBoundingBox
            let analysis = await Task.detached(priority: .userInitiated) {
                FrameAnalyzer.analyze(frame, pipeline: pipeline, preferNear: previous)
            }.value
            guard !Task.isCancelled else { break }
            statistics.record(analysis)
            detectedFaces = analysis.faces

            guard let result = analysis.result, let livenessFrame = analysis.livenessFrame else {
                lastFaceBoundingBox = nil
                if let widest = analysis.widestFaceFraction {
                    faceLine = String(
                        format: "Face seen, but too far away: it fills %.0f%% of the frame width and needs %.0f%%. Move closer, or pick a farther detection distance above.",
                        widest * 100, minimumWidth * 100
                    )
                } else {
                    faceLine = "No face in view."
                }
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox
            faceLine = String(
                format: "Face found: %.0f%% of the frame width (%.0f pixels), alignment %@.",
                result.face.normalizedBoundingBox.width * 100, result.face.boundingBox.width, result.alignmentTier.rawValue
            )

            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied(let cue):
                    deniedBy = cue
                    livenessNote = "rejected by \(cue.title)"
                    livenessLine = "Liveness: rejected (\(cue.title)). \(snapshot.decision.denialReason ?? "")"
                case .confirmed(let cue):
                    if !livenessConfirmed {
                        livenessNote = "passed" + (cue.map { " via \($0.title)" } ?? "")
                    }
                    livenessConfirmed = true
                    livenessLine = "Liveness: passed" + (cue.map { " (\($0.title))" } ?? "") + "."
                case .pending:
                    if !livenessConfirmed {
                        livenessLine = "Liveness: waiting for a blink or a small head movement…"
                    }
                }
            }

            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            if let top = scored.first {
                statistics.record(similarity: top.centroidSimilarity)
                let matched = pipeline.bestMatch(in: scored, threshold: threshold) != nil
                matchLine = String(
                    format: "%@: similarity %.3f now, %.3f best (needs %.2f) — %@",
                    top.identity.name, top.centroidSimilarity, statistics.bestSimilarity ?? 0, threshold,
                    matched ? "match" : "no match"
                )
                if matched, firstMatchAfter == nil {
                    firstMatchAfter = Date().timeIntervalSince(startedAt)
                }
                // Same order as a real scan: a deny cue on this frame wins over a match on this frame.
                if matched, livenessConfirmed, deniedBy == nil {
                    wouldUnlock = true
                }
            } else {
                matchLine = "No enrolled face to compare against."
            }
        }

        camera.stop()
        detectedFaces = []
        isRunning = false
        guard !Task.isCancelled else { return }

        let elapsed = Date().timeIntervalSince(startedAt)
        let summary = statistics.summary(minimumFaceWidth: minimumWidth, threshold: threshold)
        if wouldUnlock {
            verdictLine = String(format: "This scan would have unlocked the Mac after %.1f seconds.", elapsed)
        } else if let deniedBy {
            verdictLine = String(format: "This scan would NOT unlock: after %.1f seconds the %@ check judged it a possible photo or screen.", elapsed, deniedBy.title)
        } else {
            verdictLine = "This scan would NOT unlock: no match with liveness confirmed within \(Int(maxDuration)) seconds."
            faceLine = summary
        }
        let matchNote = firstMatchAfter.map { String(format: "first match after %.1fs", $0) } ?? "never matched"
        DebugLog.write(String(
            format: "test: ended after %.1fs; would unlock: %@; liveness %@; %@; %@; %@; camera %@; %@",
            elapsed, wouldUnlock ? "YES" : "no", livenessNote, statistics.eyeNote, statistics.deviceNote, matchNote, frameSize, summary
        ))
    }
}
