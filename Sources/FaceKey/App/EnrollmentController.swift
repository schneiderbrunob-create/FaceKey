//
//  EnrollmentController.swift
//  FaceKey
//
//  Guided face enrolment: five poses, two samples each. Each sample is turned into an embedding by Glance's
//  recognition pipeline and the camera frame is discarded. Nothing is stored until `save()`.
//

import Foundation
import CoreGraphics
import Observation

@Observable
@MainActor
final class EnrollmentController {
    struct Step {
        let pose: String
        let instruction: String
    }

    static let steps: [Step] = [
        Step(pose: "center", instruction: "Look straight at the camera."),
        Step(pose: "side-a", instruction: "Turn your head a little to one side."),
        Step(pose: "side-b", instruction: "Now turn a little to the other side."),
        Step(pose: "tilt-a", instruction: "Face the camera and tilt your chin slightly up."),
        Step(pose: "tilt-b", instruction: "Now tilt your chin slightly down."),
    ]
    static let samplesPerStep = 2

    let camera = CameraManager()
    private let pipeline: FaceRecognitionPipeline

    var name: String = ""
    private(set) var stepIndex = 0
    private(set) var samples: [FaceSample] = []
    private(set) var hint = ""
    private(set) var detectedFaces: [DetectedFace] = []
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    var isComplete: Bool { stepIndex >= Self.steps.count }
    var currentInstruction: String {
        isComplete ? "All poses captured." : Self.steps[stepIndex].instruction
    }
    var progress: Double {
        Double(samples.count) / Double(Self.steps.count * Self.samplesPerStep)
    }

    private var captureTask: Task<Void, Never>?
    private var forceCaptureRequested = false
    /// Sign of the yaw captured in the first side step, so the second one can ask for the opposite side
    /// without depending on which direction Vision calls positive.
    private var firstSideSign: Float?
    private var basePitch: Float?
    private var firstTiltSign: Float?

    init(pipeline: FaceRecognitionPipeline) {
        self.pipeline = pipeline
    }

    func start() {
        guard !isRunning else { return }
        stepIndex = 0
        samples = []
        hint = ""
        errorMessage = nil
        firstSideSign = nil
        basePitch = nil
        firstTiltSign = nil
        isRunning = true
        captureTask = Task { [weak self] in await self?.run() }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        camera.stop()
        isRunning = false
        detectedFaces = []
    }

    /// Takes the next frame with a face in it for the current pose, whatever the pose check says.
    func captureAnyway() {
        forceCaptureRequested = true
    }

    /// Writes the captured samples as a new identity. Needs an unlocked session.
    func save() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try FaceEnrollmentStore.shared.commitEnrollment(
            replacing: nil, name: trimmed, samples: samples, embedder: pipeline.embedder
        )
    }

    // MARK: - Capture loop

    private func run() async {
        await camera.start()
        if let error = camera.errorMessage {
            errorMessage = error
            isRunning = false
            return
        }

        var lastFrameID: UInt64?
        var lastCaptureAt = ContinuousClock.now - .seconds(1)
        var samplesInStep = 0

        while !Task.isCancelled, !isComplete {
            guard let frame = camera.currentFrame, frame.id != lastFrameID else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            lastFrameID = frame.id

            let faces = await Task.detached(priority: .userInitiated) {
                (try? FaceDetector.detectFaces(in: frame.image)) ?? []
            }.value
            guard !Task.isCancelled else { break }

            guard let face = FaceRecognitionPipeline.largestFace(in: faces) else {
                detectedFaces = []
                hint = "No face in view."
                continue
            }
            detectedFaces = [face]

            guard face.normalizedBoundingBox.width >= CGFloat(FaceRecognitionPipeline.minimumProminentFaceWidth) else {
                hint = "Move closer to the camera."
                continue
            }

            let forced = forceCaptureRequested
            if !forced {
                if let poseHint = poseHint(for: face) {
                    hint = poseHint
                    continue
                }
                guard ContinuousClock.now - lastCaptureAt >= .milliseconds(450) else { continue }
                if let quality = face.quality, quality < 0.3 {
                    hint = "The image is too dark or blurry. Add some light and hold still."
                    continue
                }
            }

            let pipeline = self.pipeline
            let result = await Task.detached(priority: .userInitiated) {
                try? pipeline.recognize(face, in: frame.image)
            }.value
            guard !Task.isCancelled else { break }
            guard let result else {
                hint = "Hold still for a moment."
                continue
            }
            if !forced, result.alignmentTier != .fivePoint {
                hint = "Turn back toward the camera a little."
                continue
            }

            forceCaptureRequested = false
            samples.append(FaceSample(
                embedding: result.embedding,
                pose: Self.steps[stepIndex].pose,
                capturedAt: Date(),
                quality: result.quality
            ))
            recordBaselines(from: face)
            lastCaptureAt = .now
            hint = "Captured."
            samplesInStep += 1
            if samplesInStep >= Self.samplesPerStep {
                samplesInStep = 0
                stepIndex += 1
            }
        }

        camera.stop()
        detectedFaces = []
        isRunning = false
        if isComplete { hint = "" }
    }

    /// nil when the face is in the pose the current step asks for; otherwise what to tell the user. Angles are radians.
    /// A missing angle counts as "in pose" so enrolment still finishes when Vision cannot estimate it.
    private func poseHint(for face: DetectedFace) -> String? {
        let instruction = Self.steps[stepIndex].instruction
        switch stepIndex {
        case 0:
            guard let yaw = face.yaw else { return nil }
            return abs(yaw) <= 0.15 ? nil : instruction
        case 1:
            guard let yaw = face.yaw else { return nil }
            if abs(yaw) > 0.6 { return "Not quite that far." }
            return abs(yaw) >= 0.2 ? nil : instruction
        case 2:
            guard let yaw = face.yaw else { return nil }
            if abs(yaw) > 0.6 { return "Not quite that far." }
            guard abs(yaw) >= 0.2 else { return instruction }
            if let firstSideSign, yaw.sign == firstSideSign.sign { return instruction }
            return nil
        case 3:
            guard let pitch = face.pitch, let basePitch else { return nil }
            let delta = pitch - basePitch
            if abs(delta) > 0.45 { return "Not quite that far." }
            return abs(delta) >= 0.1 ? nil : instruction
        default:
            guard let pitch = face.pitch, let basePitch else { return nil }
            let delta = pitch - basePitch
            if abs(delta) > 0.45 { return "Not quite that far." }
            guard abs(delta) >= 0.1 else { return instruction }
            if let firstTiltSign, delta.sign == firstTiltSign.sign {
                return "Tilt your chin the other way."
            }
            return nil
        }
    }

    private func recordBaselines(from face: DetectedFace) {
        switch stepIndex {
        case 0:
            if let pitch = face.pitch { basePitch = pitch }
        case 1:
            if firstSideSign == nil, let yaw = face.yaw { firstSideSign = yaw }
        case 3:
            if firstTiltSign == nil, let pitch = face.pitch, let basePitch { firstTiltSign = pitch - basePitch }
        default:
            break
        }
    }
}
