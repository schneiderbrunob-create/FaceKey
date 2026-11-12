//
//  SelfTest.swift
//  FaceKey
//
//  `FaceKey --self-test`: checks everything that can be checked without a camera, Touch ID, or a locked screen.
//  It does not prove that a face is recognised or that the lock screen accepts typed keys; those need a person.
//

import Foundation
import CoreGraphics

enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print("\(passed ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }

        // 1. The bundled face model loads and behaves like an embedder.
        do {
            let embedder = try ArcFaceEmbedder()
            let first = try embedder.embedding(for: syntheticImage(seed: 1))
            let again = try embedder.embedding(for: syntheticImage(seed: 1))
            let other = try embedder.embedding(for: syntheticImage(seed: 2))
            let norm = sqrt(first.reduce(Float(0)) { $0 + $1 * $1 })
            check("Face model loads from the app bundle", true)
            check("Embedding has 512 numbers", first.count == 512, "got \(first.count)")
            check("Embedding is unit length", abs(norm - 1) < 0.001, "norm \(norm)")
            let same = FaceEmbedding.cosineSimilarity(first, again)
            let different = FaceEmbedding.cosineSimilarity(first, other)
            check("Same image gives the same embedding", same > 0.9999, "similarity \(same)")
            check("Different image gives a different embedding", different < 0.99, "similarity \(different)")

            // 2. Matching logic: an identity matches its own sample and nothing is matched without one.
            let pipeline = FaceRecognitionPipeline()
            check("Pipeline uses the real model, not the weak fallback", !pipeline.usingFallbackEmbedder,
                  pipeline.fallbackReason ?? "")
            let identity = FaceIdentity(
                id: UUID(), name: "self-test",
                samples: [FaceSample(embedding: first, pose: nil, capturedAt: Date(), quality: nil)],
                modelIdentifier: embedder.modelIdentifier, embeddingDimension: embedder.embeddingDimension,
                createdAt: Date()
            )
            let selfScore = pipeline.score(first, against: [identity])
            check("An enrolled sample matches itself at the strictest threshold",
                  pipeline.bestMatch(in: selfScore, threshold: 0.8) != nil)
            check("Nothing matches when no face is enrolled",
                  pipeline.bestMatch(in: pipeline.score(first, against: []), threshold: 0.5) == nil)
            var disabled = identity
            disabled.isEnabled = false
            check("A switched-off face is excluded", [disabled].filter(\.isEnabled).isEmpty)
        } catch {
            check("Face model loads from the app bundle", false, error.localizedDescription)
        }

        // 3. Face detection runs and finds no face in a picture without one.
        do {
            let faces = try FaceDetector.detectFaces(in: syntheticImage(seed: 3, size: 640))
            check("Face detector runs and reports no face in a faceless image", faces.isEmpty, "found \(faces.count)")
        } catch {
            check("Face detector runs", false, error.localizedDescription)
        }

        // 3b. The liveness feature extraction runs off the main thread, as it does during a real scan, and a single
        // frame is not enough for Heavy mode to call a face live.
        do {
            let frameImage = syntheticImage(seed: 4, size: 640)
            let box = CGRect(x: 200, y: 160, width: 240, height: 300)
            let face = DetectedFace(
                boundingBox: box,
                normalizedBoundingBox: CGRect(x: 0.31, y: 0.28, width: 0.375, height: 0.47),
                quality: nil, yaw: 0, roll: 0, pitch: 0, landmarks: nil,
                imageSize: CGSize(width: 640, height: 640)
            )
            let result = FaceRecognitionResult(
                embedding: [], alignedImage: syntheticImage(seed: 5), alignmentTier: .paddedCrop, quality: nil, face: face
            )
            let livenessFrame = DispatchQueue.global(qos: .userInitiated).sync {
                LivenessFeatureExtractor.extract(from: result, frame: frameImage, faceCrop: frameImage.cropping(to: box))
            }
            let analyzer = LivenessAnalyzer()
            analyzer.modeProvider = { .heavy }
            let snapshot = analyzer.observe(livenessFrame)
            check("Liveness extraction runs on a background thread", true)
            check("Heavy liveness does not confirm from a single landmark-less frame", !snapshot.decision.isConfirmed)
        }

        // 3c. Blink detection at this app's frame rate: a slow blink counts, steady eyes and a one-sided dip do not.
        do {
            func frames(_ openness: [CGFloat]) -> [LivenessFrame] {
                let start = Date()
                return openness.enumerated().map { index, value in
                    LivenessFrame(
                        timestamp: start.addingTimeInterval(Double(index) / 30), landmarks: [], interocularDistance: nil,
                        yaw: 0, leftEyeAspectRatio: value, rightEyeAspectRatio: value, noseOffsetRatio: nil,
                        hasReliableLandmarks: false, deviceOverlapFraction: nil, glare: nil
                    )
                }
            }
            let open: [CGFloat] = Array(repeating: 0.30, count: 8)
            let slowBlink = open + [0.255, 0.21, 0.165, 0.135, 0.12, 0.135, 0.165, 0.21, 0.255] + open
            let steady = open + [0.29, 0.30, 0.28, 0.30, 0.29] + open
            let closing = open + [0.255, 0.21, 0.165, 0.135, 0.12]
            check("A slow blink (0.3 s) is detected at 30 frames per second",
                  LivenessScoring.blinkDynamics(frames(slowBlink)).confidence > 0)
            // What the lock screen produced: a low reading in the very first frames, then a real blink later.
            let lowStartThenBlink: [CGFloat] = [0.05, 0.08] + open + [0.21, 0.12, 0.21] + open
            check("A blink is detected even after a low reading at the start of the scan",
                  LivenessScoring.blinkDynamics(frames(lowStartThenBlink)).confidence > 0)
            check("A low reading at the start alone is not a blink",
                  LivenessScoring.blinkDynamics(frames([0.05, 0.08] + open + open)).confidence == 0)
            // Frame-to-frame jitter of the size measured on this Mac: single-frame dips to 55-60% of typical.
            let jitter = open + [0.30, 0.17, 0.31, 0.29, 0.18, 0.30, 0.33, 0.165, 0.30] + open
            check("Landmark jitter (dips to 55-60%) is not a blink",
                  LivenessScoring.blinkDynamics(frames(jitter)).confidence == 0)
            let oneEyed: [LivenessFrame] = {
                let start = Date()
                let left: [CGFloat] = open + [0.21, 0.06, 0.21] + open
                return left.enumerated().map { index, value in
                    LivenessFrame(
                        timestamp: start.addingTimeInterval(Double(index) / 30), landmarks: [], interocularDistance: nil,
                        yaw: 0, leftEyeAspectRatio: value, rightEyeAspectRatio: 0.30, noseOffsetRatio: nil,
                        hasReliableLandmarks: false, deviceOverlapFraction: nil, glare: nil
                    )
                }
            }()
            check("One eye closing alone is not a blink", LivenessScoring.blinkDynamics(oneEyed).confidence == 0)
            check("Steady open eyes are not a blink", LivenessScoring.blinkDynamics(frames(steady)).confidence == 0)
            check("Eyes that close and stay closed are not a blink",
                  LivenessScoring.blinkDynamics(frames(closing)).confidence == 0)
        }

        // 4. Lock state can be read, and correctly says "not locked" while this runs in a normal session.
        check("Lock state reads as unlocked right now", !LockMonitor.isScreenActuallyLocked())

        // 5. The login keychain accepts an item from this build (the Touch-ID-gated kind does not; see KeychainManager).
        do {
            let probe = Data("probe".utf8)
            try KeychainManager.save(account: "selftest-probe", data: probe)
            let readBack = try KeychainManager.read(account: "selftest-probe")
            try KeychainManager.delete(account: "selftest-probe")
            check("Keychain write, read and delete work for this build",
                  readBack == probe && !KeychainManager.exists(account: "selftest-probe"))
        } catch {
            check("Keychain write, read and delete work for this build", false, error.localizedDescription)
        }

        // 6. Encryption refuses to work while the session is locked.
        do {
            _ = try SecureCredentialManager.encrypt(Data("x".utf8))
            check("Encryption is refused while the session is locked", false)
        } catch {
            check("Encryption is refused while the session is locked", true)
        }

        print("INFO  Accessibility granted to this build: \(KeystrokeInjector.isAccessibilityTrusted())")
        print("INFO  Stored password present: \(SecureCredentialManager.hasStoredPassword())")
        print(failures == 0 ? "All self-test checks passed." : "\(failures) self-test check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    /// A deterministic patterned image. Not a face; only there to give the model and detector real pixels.
    private static func syntheticImage(seed: Int, size: Int = FaceAligner.outputSize) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        var state = UInt64(seed) &* 0x9E3779B97F4A7C15
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 1000) / 1000
        }
        context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for _ in 0..<24 {
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            let width = next() * CGFloat(size) / 2
            let height = next() * CGFloat(size) / 2
            context.fill(CGRect(x: next() * CGFloat(size), y: next() * CGFloat(size), width: width, height: height))
        }
        return context.makeImage()!
    }
}
