//
//  CredentialController.swift
//  FaceKey
//
//  Adapted from Glance's POCController (MIT, © 2026 Jonathan Zhou). Wires SecureCredentialManager to
//  KeystrokeInjector and exposes session and password status to the settings window.
//

import Foundation
import Observation

@Observable
@MainActor
final class CredentialController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String?

    /// Bound to the setup SecureField. Cleared as soon as a save starts.
    var passwordInput: String = ""

    var statusMessage: String = ""

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    func unlockSession() async {
        sessionError = nil
        do {
            try await SecureCredentialManager.unlockSession(reason: "arm face unlock and open its settings")
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Password

    /// Encrypts and stores `passwordInput`. Requires the session to be unlocked already.
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "Enter your Mac password first."
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "Password saved and encrypted."
            hasStoredPassword = true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func deletePassword() {
        SecureCredentialManager.deletePassword()
        hasStoredPassword = false
        statusMessage = "Stored password removed."
    }

    // MARK: - Typing

    /// Decrypts the stored password, types it followed by Return, and zeroes the plaintext. Refuses unless
    /// CoreGraphics confirms the screen is locked, so the password can never be typed into an ordinary window.
    /// Returns true if the keystrokes were sent.
    @discardableResult
    func typeStoredPasswordOnLockScreen() async -> Bool {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "Accessibility is not granted, so nothing can be typed."
            return false
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Session locked. Authenticate with Touch ID first."
            return false
        }
        guard LockMonitor.isScreenActuallyLocked() else {
            statusMessage = "Skipped typing: the screen is not locked."
            return false
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                // Checked again at the last moment, on the thread that types.
                guard LockMonitor.isScreenActuallyLocked() else { return }
                try KeystrokeInjector.typeAndReturn(bytes)
            }.value
            statusMessage = "Typed the stored password at \(Date().formatted(date: .omitted, time: .standard))."
            return true
        } catch {
            statusMessage = "Typing failed: \(error.localizedDescription)"
            return false
        }
    }
}
