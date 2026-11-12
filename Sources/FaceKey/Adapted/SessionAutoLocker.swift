//
//  SessionAutoLocker.swift
//  FaceKey
//
//  Adapted from Glance (MIT, © 2026 Jonathan Zhou). Re-locks the session once it has gone unused past the chosen limit.
//

import Foundation
import AppKit

@MainActor
final class SessionAutoLocker {
    private let credentials: CredentialController
    private var timer: Timer?

    /// Coarse on purpose: the shortest limit is a full day, and the decision compares timestamps, not ticks.
    private let checkInterval: TimeInterval = 5 * 60

    init(credentials: CredentialController) {
        self.credentials = credentials
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // No timer fires during sleep, but the time asleep still counts as idle.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func evaluate() {
        guard SecureCredentialManager.isSessionUnlocked,
              let lastActivityAt = SecureCredentialManager.lastActivityAt
        else { return }

        let idleLimit = TimeInterval(AppSettings.shared.autoLockDays) * 24 * 60 * 60
        guard idleLimit > 0, Date().timeIntervalSince(lastActivityAt) >= idleLimit else { return }

        credentials.lockSession()
    }
}
