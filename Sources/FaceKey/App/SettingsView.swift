//
//  SettingsView.swift
//  FaceKey
//
//  The one settings window: setup checklist, password, faces, recognition tuning, a safe test, and the activity log.
//

import SwiftUI
import AppKit
import AVFoundation

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @LocalState private var settings = AppSettings.shared
    @LocalState private var faces = FaceEnrollmentStore.shared
    @LocalState private var tester: RecognitionTester?
    @LocalState private var isEnrolling = false
    @LocalState private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @LocalState private var cameras = CameraDeviceCatalog.availableDevices()
    @LocalState private var launchAtLogin = LaunchAtLogin.isEnabled
    @LocalState private var generalError: String?
    @LocalState private var confirmErase = false
    @LocalState private var typingTestText = ""
    @LocalState private var typingTestResult = ""
    @FocusState private var typingTestFocused: Bool

    var body: some View {
        let credentials = environment.credentials
        let coordinator = environment.coordinator

        Form {
            Section("Status") {
                checklistRow("Session unlocked with Touch ID", done: credentials.isSessionUnlocked)
                checklistRow("Accessibility permission (to type on the lock screen)", done: credentials.accessibilityGranted)
                checklistRow("Camera permission", done: cameraStatus == .authorized)
                checklistRow("Mac password stored", done: credentials.hasStoredPassword)
                checklistRow("Face enrolled", done: !faces.activeIdentities.isEmpty)

                Toggle("Unlock this Mac with my face", isOn: Binding(
                    get: { coordinator.isEnabled },
                    set: { coordinator.isEnabled = $0 }
                ))
                .disabled(!environment.isSetUp)

                Text("FaceKey is a convenience, not a security upgrade. A laptop camera sees a flat image, so a video of you can fool it, and anyone it accepts gets your password typed for them. Touch ID stays the safer way in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Session") {
                if credentials.isSessionUnlocked {
                    LabeledContent("Unlocked. The key is held in memory until you lock it, quit, or it sits unused.") {
                        Button("Lock") { credentials.lockSession() }
                    }
                } else {
                    LabeledContent("Locked. Nothing can be read, saved, or typed.") {
                        Button("Authenticate…") { Task { await credentials.unlockSession() } }
                    }
                }
                if let error = credentials.sessionError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if credentials.accessibilityGranted {
                        Text("Granted").foregroundStyle(.secondary)
                    } else {
                        Button("Ask macOS…") { credentials.requestAccessibility() }
                    }
                }
                LabeledContent("Camera") {
                    switch cameraStatus {
                    case .authorized:
                        Text("Granted").foregroundStyle(.secondary)
                    case .notDetermined:
                        Button("Ask macOS…") {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .video)
                                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                            }
                        }
                    default:
                        Text("Denied — enable FaceKey under Privacy & Security › Camera").foregroundStyle(.red)
                    }
                }
            }

            Section("Mac password") {
                if credentials.hasStoredPassword {
                    LabeledContent("A password is stored, encrypted.") {
                        Button("Remove", role: .destructive) { credentials.deletePassword() }
                    }
                }
                HStack {
                    SecureField(
                        credentials.hasStoredPassword ? "Replace with new password" : "Your Mac login password",
                        text: Binding(get: { credentials.passwordInput }, set: { credentials.passwordInput = $0 })
                    )
                    .textContentType(.password)
                    .onSubmit { Task { await credentials.savePassword() } }
                    Button("Save") { Task { await credentials.savePassword() } }
                        .disabled(credentials.passwordInput.isEmpty)
                }
                .disabled(!credentials.isSessionUnlocked)
                if !credentials.statusMessage.isEmpty {
                    Text(credentials.statusMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Text("FaceKey cannot check this against your real password. If it is wrong, the first unlock attempt will fail and, after two failures, face unlock turns itself off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Faces") {
                if faces.isLocked {
                    Text("Authenticate to see enrolled faces.").foregroundStyle(.secondary)
                } else if let failure = faces.loadFailure {
                    Text("Enrolled faces could not be read: \(failure)").foregroundStyle(.red)
                } else if faces.identities.isEmpty {
                    Text("No face enrolled yet.").foregroundStyle(.secondary)
                }
                ForEach(faces.identities) { identity in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { identity.isEnabled },
                            set: { newValue in attempt { try faces.setEnabled(newValue, for: identity.id) } }
                        )) {
                            VStack(alignment: .leading) {
                                Text(identity.name)
                                Text("\(identity.samples.count) samples · \(identity.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) {
                            attempt { try faces.delete(identity) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this face")
                    }
                }
                Button("Enroll a face…") { isEnrolling = true }
                    .disabled(!credentials.isSessionUnlocked || faces.loadFailure != nil)
            }

            Section("Recognition") {
                LabeledContent("Match strictness: \(String(format: "%.2f", settings.matchThreshold))") {
                    Slider(
                        value: Binding(get: { settings.matchThreshold }, set: { settings.matchThreshold = $0 }),
                        in: AppSettings.matchThresholdRange,
                        step: 0.01
                    )
                    .frame(width: 220)
                }
                Picker("Detection distance", selection: Binding(
                    get: { DetectionDistance.nearest(to: settings.minimumFaceWidth) },
                    set: { settings.minimumFaceWidth = $0.minimumFaceWidth }
                )) {
                    ForEach(DetectionDistance.allCases) { level in
                        Text("\(level.title) — face at least \(Int(level.minimumFaceWidth * 100))% of the frame width").tag(level)
                    }
                }
                Toggle("Liveness checks (reject photos and screens)", isOn: Binding(
                    get: { settings.livenessChecksEnabled }, set: { settings.livenessChecksEnabled = $0 }
                ))
                Picker("Liveness mode", selection: Binding(
                    get: { settings.livenessMode }, set: { settings.livenessMode = $0 }
                )) {
                    ForEach(LivenessMode.allCases) { mode in
                        Text("\(mode.title) — \(mode.summary)").tag(mode)
                    }
                }
                .disabled(!settings.livenessChecksEnabled)
                Stepper(
                    "Scan for up to \(settings.scanSeconds) seconds",
                    value: Binding(get: { settings.scanSeconds }, set: { settings.scanSeconds = $0 }),
                    in: AppSettings.scanSecondsRange
                )
                Toggle("Try once more after a failed scan", isOn: Binding(
                    get: { settings.autoRetryOnce }, set: { settings.autoRetryOnce = $0 }
                ))
                ForEach(UnlockTrigger.allCases) { trigger in
                    Toggle("Scan: \(trigger.title)", isOn: Binding(
                        get: { settings.unlockTriggers.contains(trigger) },
                        set: { isOn in
                            if isOn { settings.unlockTriggers.insert(trigger) } else { settings.unlockTriggers.remove(trigger) }
                        }
                    ))
                }
                Picker("Camera", selection: Binding(get: { settings.cameraID }, set: { settings.cameraID = $0 })) {
                    Text("Built-in camera").tag(String?.none)
                    ForEach(cameras) { camera in
                        Text(camera.name).tag(String?.some(camera.id))
                    }
                }
                if environment.pipeline.usingFallbackEmbedder {
                    Text("The face model failed to load, so a much weaker fallback is in use. Do not rely on it. \(environment.pipeline.fallbackReason ?? "")")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Lock-screen animation") {
                Toggle("Show an animation at the notch while scanning", isOn: Binding(
                    get: { settings.showUnlockAnimation }, set: { settings.showUnlockAnimation = $0 }
                ))
                Picker("Style", selection: Binding(
                    get: { settings.unlockAnimationStyle }, set: { settings.unlockAnimationStyle = $0 }
                )) {
                    ForEach(UnlockAnimationStyle.selectableCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .disabled(!settings.showUnlockAnimation)
                Toggle("Point at the notch to scan again", isOn: Binding(
                    get: { settings.retryOnHover }, set: { settings.retryOnHover = $0 }
                ))
                .disabled(!settings.showUnlockAnimation)
                Toggle("Trackpad haptics", isOn: Binding(
                    get: { settings.hapticFeedbackEnabled }, set: { settings.hapticFeedbackEnabled = $0 }
                ))
                .disabled(!settings.showUnlockAnimation)
                HStack {
                    Button("Preview success") { previewAnimation(success: true) }
                    Button("Preview failure") { previewAnimation(success: false) }
                }
                .disabled(!settings.showUnlockAnimation)
            }

            Section("Try it safely") {
                Text("Runs a real scan with the screen unlocked. Nothing is typed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let tester {
                    if tester.isRunning {
                        CameraPreviewView(session: tester.camera.session, faces: tester.detectedFaces)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tester.faceLine)
                        if !tester.matchLine.isEmpty { Text(tester.matchLine) }
                        if !tester.livenessLine.isEmpty { Text(tester.livenessLine) }
                        if !tester.verdictLine.isEmpty {
                            Text(tester.verdictLine)
                                .bold()
                                .foregroundStyle(tester.wouldUnlock ? .green : .primary)
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
                Button(tester?.isRunning == true ? "Stop test" : "Test recognition") {
                    if tester == nil { tester = RecognitionTester(pipeline: environment.pipeline) }
                    if tester?.isRunning == true { tester?.stop() } else { tester?.start() }
                }
                .disabled(faces.activeIdentities.isEmpty)

                HStack {
                    TextField("Typing test field", text: $typingTestText)
                        .focused($typingTestFocused)
                    Button("Test typing") { runTypingTest() }
                        .disabled(!credentials.accessibilityGranted)
                }
                if !typingTestResult.isEmpty {
                    Text(typingTestResult).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Activity") {
                if coordinator.activityLog.isEmpty {
                    Text("No scans yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(coordinator.activityLog.prefix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote).monospacedDigit()
                    }
                }
            }

            Section("General") {
                Toggle("Open FaceKey at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        attempt { try LaunchAtLogin.setEnabled(newValue) }
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                Picker("Ask for Touch ID again after", selection: Binding(
                    get: { settings.autoLockDays }, set: { settings.autoLockDays = $0 }
                )) {
                    ForEach(AppSettings.autoLockDayChoices, id: \.self) { days in
                        Text(days == 1 ? "1 day unused" : "\(days) days unused").tag(days)
                    }
                }
                Button("Erase everything…", role: .destructive) { confirmErase = true }
                if let generalError {
                    Text(generalError).font(.footnote).foregroundStyle(.red)
                }
                Text("Face recognition, liveness checks and lock-screen typing are adapted from Glance by Jonathan Zhou (MIT licence).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
        .sheet(isPresented: $isEnrolling) {
            EnrollmentView(pipeline: environment.pipeline)
        }
        .confirmationDialog(
            "Erase the stored password, all enrolled faces, and the encryption key?",
            isPresented: $confirmErase
        ) {
            Button("Erase everything", role: .destructive) { eraseEverything() }
        } message: {
            Text("This cannot be undone. Face unlock will be switched off.")
        }
        .task {
            // Permission changes happen in System Settings, outside this app, so poll while the window is open.
            while !Task.isCancelled {
                credentials.refreshAccessibilityStatus()
                credentials.refreshCredentialStatus()
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                cameras = CameraDeviceCatalog.availableDevices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { tester?.stop() }
    }

    /// Plays the notch animation with the screen unlocked: a short scan, then the chosen ending.
    private func previewAnimation(success: Bool) {
        let overlay = NotchOverlayController.shared
        overlay.present()
        Task {
            try? await Task.sleep(for: .milliseconds(1_600))
            overlay.finish(success: success)
        }
    }

    private func checklistRow(_ title: String, done: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
            generalError = nil
        } catch {
            generalError = error.localizedDescription
        }
    }

    private func eraseEverything() {
        environment.coordinator.isEnabled = false
        attempt { try SecureCredentialManager.eraseEverything() }
        faces.deleteAll()
        environment.credentials.refreshCredentialStatus()
    }

    /// Sends harmless sample text through the same keystroke path the lock screen gets, into this window's own field,
    /// to prove that Accessibility is granted and synthetic typing works on this macOS version.
    private func runTypingTest() {
        typingTestText = ""
        typingTestResult = ""
        typingTestFocused = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            // Only type if the keystrokes will land in this window's text field.
            guard NSApp.isActive, typingTestFocused, NSApp.keyWindow?.firstResponder is NSTextView else {
                typingTestResult = "Skipped: the test field is not focused."
                return
            }
            let sample = "FaceKey typing works"
            do {
                try await Task.detached { try KeystrokeInjector.typeAndReturn(Data(sample.utf8)) }.value
                try? await Task.sleep(for: .milliseconds(300))
                typingTestResult = typingTestText == sample
                    ? "Typing works: the field received the sample text."
                    : "Keystrokes were sent, but the field shows “\(typingTestText)”."
            } catch {
                typingTestResult = error.localizedDescription
            }
        }
    }
}
