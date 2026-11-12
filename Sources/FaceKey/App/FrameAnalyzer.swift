//
//  FrameAnalyzer.swift
//  FaceKey
//
//  One camera frame through detection, selection, recognition and liveness feature extraction, keeping what was
//  seen even when no face qualified, so a failed scan can say why (nobody there, or somebody too far away).
//  Also the plain-text activity log used to diagnose scans that happen on the lock screen.
//

import Foundation
import CoreGraphics

nonisolated struct FrameAnalysis {
    /// Every face Vision found, including ones too small to count.
    let faces: [DetectedFace]
    /// Width of the widest face as a fraction of the frame width, or nil when no face was found.
    let widestFaceFraction: CGFloat?
    /// Set only when a face was prominent enough and could be aligned and embedded.
    let result: FaceRecognitionResult?
    let livenessFrame: LivenessFrame?
}

nonisolated enum FrameAnalyzer {
    /// CPU-bound; call from a background task.
    static func analyze(_ frame: CameraFrame, pipeline: FaceRecognitionPipeline, preferNear previous: CGRect?) -> FrameAnalysis {
        let faces = (try? FaceDetector.detectFaces(in: frame.image)) ?? []
        let widest = faces.map(\.normalizedBoundingBox.width).max()
        guard let face = FaceRecognitionPipeline.selectDominantFace(in: faces, preferNear: previous),
              let result = try? pipeline.recognize(face, in: frame.image)
        else {
            return FrameAnalysis(faces: faces, widestFaceFraction: widest, result: nil, livenessFrame: nil)
        }
        let crop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
        let livenessFrame = LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: crop)
        return FrameAnalysis(faces: faces, widestFaceFraction: widest, result: result, livenessFrame: livenessFrame)
    }
}

extension LivenessTuning {
    /// Glance's defaults with a stricter "device detected" cue. Glance rejects a scan when any large rectangle covers
    /// 15% of the face box in 3 frames, which a door, window or picture behind a real person does easily (seen in
    /// testing on this Mac). Here the face must sit almost entirely inside the rectangle, as it does when it is
    /// shown on a phone or tablet, and for twice as many frames. Trade-off: something rectangular directly behind
    /// the whole head can still trigger it, and a device whose edges are only partly in view is less likely to.
    nonisolated static let faceKey: LivenessTuning = {
        var tuning = LivenessTuning.default
        tuning.deviceLevel = 0.9
        tuning.deviceFrames = 6
        return tuning
    }()
}

/// Running totals for one scan, turned into a one-line explanation when the scan ends without a match.
nonisolated struct ScanStatistics {
    var frames = 0
    var framesWithAnyFace = 0
    var framesWithUsableFace = 0
    var widestFaceFraction: CGFloat = 0
    var widestFacePixels: CGFloat = 0
    var bestSimilarity: Float?
    /// Frames where a large rectangle touched the face box at all, and where it held nearly all of it.
    var framesWithRectangleNearFace = 0
    var framesWithFaceInsideRectangle = 0
    var largestRectangleOverlap: CGFloat = 0

    /// Average eye openness of every frame, for the log. A real blink takes this well below half of the typical value.
    private var eyeOpenness: [CGFloat] = []

    var eyeNote: String {
        guard eyeOpenness.count >= 6 else { return "too few eye measurements" }
        let typical = LivenessScoring.median(eyeOpenness)
        guard typical > 0, let lowest = eyeOpenness.min(), let highest = eyeOpenness.max() else { return "no eye measurements" }
        let sorted = eyeOpenness.sorted()
        let tenth = sorted[sorted.count / 10]
        return String(
            format: "eye openness vs typical: lowest %.0f%%, 10th percentile %.0f%%, highest %.0f%% (a blink needs under %.0f%%)",
            lowest / typical * 100, tenth / typical * 100, highest / typical * 100, LivenessScoring.blinkDipLevel * 100
        )
    }

    /// For the log: how often the "device detected" cue had something to look at.
    var deviceNote: String {
        guard framesWithRectangleNearFace > 0 else { return "no rectangle near the face" }
        return "rectangle near the face in \(framesWithRectangleNearFace) frames, face inside it in \(framesWithFaceInsideRectangle), largest overlap \(Int((largestRectangleOverlap * 100).rounded()))%"
    }

    mutating func record(_ analysis: FrameAnalysis) {
        frames += 1
        if let widest = analysis.widestFaceFraction {
            framesWithAnyFace += 1
            widestFaceFraction = max(widestFaceFraction, widest)
            widestFacePixels = max(widestFacePixels, analysis.faces.map(\.boundingBox.width).max() ?? 0)
        }
        if analysis.result != nil { framesWithUsableFace += 1 }
        if let left = analysis.livenessFrame?.leftEyeAspectRatio, let right = analysis.livenessFrame?.rightEyeAspectRatio {
            eyeOpenness.append((left + right) / 2)
        }
        if let overlap = analysis.livenessFrame?.deviceOverlapFraction, overlap > 0.01 {
            framesWithRectangleNearFace += 1
            if overlap >= CGFloat(LivenessTuning.faceKey.deviceLevel) { framesWithFaceInsideRectangle += 1 }
            largestRectangleOverlap = max(largestRectangleOverlap, overlap)
        }
    }

    mutating func record(similarity: Float) {
        bestSimilarity = max(bestSimilarity ?? -1, similarity)
    }

    func summary(minimumFaceWidth: Float, threshold: Float) -> String {
        if frames == 0 { return "The camera delivered no frames." }
        if framesWithAnyFace == 0 { return "\(frames) frames, no face in any of them." }
        let widthPercent = Int((widestFaceFraction * 100).rounded())
        let neededPercent = Int((minimumFaceWidth * 100).rounded())
        if framesWithUsableFace == 0 {
            return "\(frames) frames; a face was seen but was too far away: \(widthPercent)% of the frame width at most (\(Int(widestFacePixels)) px), needs \(neededPercent)%."
        }
        let similarity = bestSimilarity.map { String(format: "%.3f", $0) } ?? "none"
        return "\(frames) frames, \(framesWithUsableFace) with a usable face (widest \(widthPercent)%, \(Int(widestFacePixels)) px); best similarity \(similarity), needs \(String(format: "%.2f", threshold))."
    }
}

/// Appends scan outcomes to a small text file. Holds timestamps, counts and similarity scores only: no images,
/// no embeddings, no password.
nonisolated enum DebugLog {
    static let url = SecureCredentialManager.storageDirectory.appendingPathComponent("activity.log")
    private static let lock = NSLock()
    private static let maxBytes = 200_000

    static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(Date().formatted(.iso8601))  \(message)\n"
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            try? manager.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
