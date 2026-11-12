//
//  FaceKeyApp.swift
//  FaceKey
//
//  Menu-bar app entry point. Owns the long-lived controllers so every window shares one instance of each.
//

import SwiftUI
import AppKit
import AVFoundation

@Observable
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let credentials = CredentialController()
    let pipeline = FaceRecognitionPipeline()
    let coordinator: FaceUnlockCoordinator
    /// Held, not just constructed: it owns a repeating timer.
    let autoLocker: SessionAutoLocker

    private init() {
        coordinator = FaceUnlockCoordinator(credentials: credentials, pipeline: pipeline)
        autoLocker = SessionAutoLocker(credentials: credentials)
    }

    /// Everything a face unlock needs, besides the on/off switch.
    var isSetUp: Bool {
        let faces = FaceEnrollmentStore.shared
        // While the session is locked the faces cannot be decrypted, so fall back to whether the file exists.
        let hasFaces = faces.isLocked ? SecureFaceStore.exists : !faces.identities.isEmpty
        return credentials.hasStoredPassword && hasFaces
    }
}

/// The settings window, owned by AppKit rather than a SwiftUI `Window` scene, so it can be shown from the app
/// delegate: at launch while setup is unfinished, and whenever the app is opened again while already running.
/// A menu-bar-only app has no Dock icon, and its menu-bar icon can be hidden behind the notch, so reopening the
/// app must always be enough to get this window back.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(AppEnvironment.shared))
            let created = NSWindow(contentViewController: hosting)
            created.title = "FaceKey"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Renders the overlay window's own content into PNG files at each stage of the animation.
@MainActor
enum OverlaySnapshot {
    static func run(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let overlay = NotchOverlayController.shared
        Task {
            overlay.present()
            try? await Task.sleep(for: .milliseconds(1_500))
            save("1-scanning", into: folder)
            overlay.finish(success: true)
            try? await Task.sleep(for: .milliseconds(1_300))
            save("2-success", into: folder)
            try? await Task.sleep(for: .milliseconds(1_800))
            overlay.present()
            try? await Task.sleep(for: .milliseconds(1_200))
            overlay.finish(success: false)
            try? await Task.sleep(for: .milliseconds(1_500))
            save("3-failure", into: folder)
            NSApp.terminate(nil)
        }
    }

    private static func save(_ name: String, into folder: URL) {
        guard let window = NSApp.windows.first(where: { $0 is NotchWindow }), let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            print("snapshot \(name): no overlay window")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let geometry = overlay(window)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: folder.appendingPathComponent("\(name).png"))
        }
        print("snapshot \(name): \(geometry)")
    }

    private static func overlay(_ window: NSWindow) -> String {
        let controller = NotchOverlayController.shared
        return "window \(Int(window.frame.width))x\(Int(window.frame.height)) at \(Int(window.frame.minX)),\(Int(window.frame.minY)) visible=\(window.isVisible) level=\(window.level.rawValue); phase=\(controller.phase) style=\(controller.geometry.style) closed=\(Int(controller.geometry.closedSize.width))x\(Int(controller.geometry.closedSize.height))"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `open -a FaceKey`, or opening it from the Applications folder, while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `FaceKey --overlay-snapshot <folder>`: plays the notch animation once, saves pictures of it, and quits.
        // A development check that touches nothing else: no Touch ID prompt, no camera, no settings window.
        if let index = CommandLine.arguments.firstIndex(of: "--overlay-snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            OverlaySnapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }

        let environment = AppEnvironment.shared
        // Starts the lock/wake observation and the idle timer now rather than when a window first appears.
        _ = environment.coordinator
        environment.autoLocker.evaluate()

        let camera: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = "granted"
        case .notDetermined: camera = "not asked yet"
        case .denied: camera = "denied"
        case .restricted: camera = "restricted"
        @unknown default: camera = "unknown"
        }
        DebugLog.write("launch: camera \(camera); accessibility \(KeystrokeInjector.isAccessibilityTrusted() ? "granted" : "not granted"); password stored: \(SecureCredentialManager.hasStoredPassword()); face unlock on: \(AppSettings.shared.isFaceUnlockEnabled)")

        // Once something is stored, each launch asks for Touch ID so face unlock is armed again after a restart.
        if SecureCredentialManager.hasSessionEncryptedData {
            Task { await environment.credentials.unlockSession() }
        }

        // Start quietly in the menu bar only once face unlock is fully set up and switched on.
        if !(environment.isSetUp && environment.coordinator.isEnabled) {
            SettingsWindowController.shared.show()
        }
    }
}

@main
enum FaceKeyMain {
    static func main() {
        // `FaceKey --self-test` checks the parts that need no camera, no Touch ID and no lock screen, then exits.
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        FaceKeyApp.main()
    }
}

struct FaceKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @LocalState private var environment = AppEnvironment.shared

    var body: some Scene {
        MenuBarExtra("FaceKey", systemImage: menuBarSymbol) {
            MenuContent()
                .environment(environment)
        }
    }

    private var menuBarSymbol: String {
        if !environment.coordinator.isEnabled { return "faceid" }
        return environment.credentials.isSessionUnlocked ? "lock.open.fill" : "lock.fill"
    }
}

private struct MenuContent: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let credentials = environment.credentials
        let coordinator = environment.coordinator

        Text(statusLine)

        Divider()

        if credentials.isSessionUnlocked {
            Button("Lock Session") { credentials.lockSession() }
        } else {
            Button("Authenticate with Touch ID…") {
                Task { await credentials.unlockSession() }
            }
        }

        Toggle("Unlock with My Face", isOn: Binding(
            get: { coordinator.isEnabled },
            set: { coordinator.isEnabled = $0 }
        ))
        .disabled(!environment.isSetUp)

        Divider()

        Button("Settings…") { SettingsWindowController.shared.show() }
        Button("Quit FaceKey") { NSApp.terminate(nil) }
    }

    private var statusLine: String {
        let credentials = environment.credentials
        if !environment.isSetUp { return "Setup not finished" }
        if !environment.coordinator.isEnabled { return "Face unlock is off" }
        if !credentials.isSessionUnlocked { return "Needs Touch ID to arm" }
        if !credentials.accessibilityGranted { return "Needs Accessibility permission" }
        return "Face unlock is armed"
    }
}
