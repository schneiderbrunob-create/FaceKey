//
//  SecureCredentialManager.swift
//  FaceKey
//
//  Adapted from Glance (MIT, © 2026 Jonathan Zhou). Two-tier storage: a 256-bit session key in the login keychain wraps
//  the Mac password and the enrolled faces with AES-GCM. The key is held in memory only while a session is unlocked.
//
//  Changed from Glance:
//  - Touch ID is asked for with LocalAuthentication before the key is read, rather than enforced by the keychain item
//    itself (see KeychainManager for why). This makes the gate the app's own: it stops someone at the keyboard, not
//    other software already running as this user, which the login keychain's per-app access prompt guards against instead.
//  - The encrypted password lives in a file next to the encrypted faces, not in the keychain, so nothing has to talk
//    to the keychain while the screen is locked, where a keychain dialog could not be answered.
//

import Foundation
import CryptoKit
import LocalAuthentication

enum SecureCredentialError: LocalizedError {
    case emptyPassword
    case sessionLocked
    case encryptionFailed
    case decryptionFailed
    case sessionKeyUnavailable
    case authenticationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Password cannot be empty."
        case .sessionLocked:
            return "The session is locked. Authenticate with Touch ID first."
        case .encryptionFailed:
            return "Encryption failed."
        case .decryptionFailed:
            return "Decryption failed. The stored data may be damaged or belong to an older key."
        case .sessionKeyUnavailable:
            return "The session key is missing, but encrypted data that only it could read still exists. Nothing was deleted. Use “Erase everything” to start fresh."
        case .authenticationFailed(let detail):
            return "Authentication did not succeed: \(detail)"
        }
    }
}

extension Notification.Name {
    /// Fires whenever the cached session key appears or disappears, so anything encrypted under it can reload.
    nonisolated static let secureCredentialSessionDidChange = Notification.Name("SecureCredentialManager.sessionDidChange")
}

enum SecureCredentialManager {
    nonisolated private static let sessionKeyAccount = "sessionKey"

    /// Shared with `SecureFaceStore`, which keeps its own file in the same folder.
    nonisolated static let storageDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("FaceKey", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }()

    nonisolated private static let passwordFileURL = storageDirectory.appendingPathComponent("password.enc")

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey?
    /// Last unlock or successful `readPassword`, which `SessionAutoLocker` compares against the idle limit.
    nonisolated(unsafe) private static var _lastActivityAt: Date?

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey != nil
    }

    nonisolated static var lastActivityAt: Date? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _lastActivityAt
    }

    nonisolated private static func cachedKey() -> SymmetricKey? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey
    }

    nonisolated private static func setCachedKey(_ key: SymmetricKey?) {
        sessionLock.lock()
        let changed = (key != nil) != (_cachedKey != nil)
        _cachedKey = key
        _lastActivityAt = key == nil ? nil : Date()
        sessionLock.unlock()
        // Posted after releasing the lock: observers call back into `isSessionUnlocked`.
        guard changed else { return }
        NotificationCenter.default.post(name: .secureCredentialSessionDidChange, object: nil)
    }

    nonisolated private static func recordActivity() {
        sessionLock.lock()
        if _cachedKey != nil { _lastActivityAt = Date() }
        sessionLock.unlock()
    }

    // MARK: - Session-key crypto (shared by the password here and the faces in SecureFaceStore)

    nonisolated static func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw SecureCredentialError.encryptionFailed }
            return combined
        } catch {
            throw SecureCredentialError.encryptionFailed
        }
    }

    nonisolated static func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureCredentialError.decryptionFailed
        }
    }

    // MARK: - Public API

    nonisolated static func hasStoredPassword() -> Bool {
        FileManager.default.fileExists(atPath: passwordFileURL.path)
    }

    /// True if anything on disk is encrypted under the session key, whether or not the key can be read right now.
    nonisolated static var hasSessionEncryptedData: Bool {
        hasStoredPassword() || SecureFaceStore.exists
    }

    /// Asks for Touch ID (or the login password where Touch ID is unavailable), then loads the session key into memory,
    /// creating it on first use. Must succeed before anything can be saved, read, or typed.
    nonisolated static func unlockSession(reason: String) async throws {
        if cachedKey() != nil { return }

        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw SecureCredentialError.authenticationFailed(error.localizedDescription)
        }

        // Off the main actor: the keychain can put up its own blocking dialog after a rebuild.
        let key = try await Task.detached(priority: .userInitiated) { () throws -> SymmetricKey in
            if KeychainManager.exists(account: sessionKeyAccount) {
                return SymmetricKey(data: try KeychainManager.read(account: sessionKeyAccount))
            }
            // Minting a new key would make existing encrypted data unreadable forever, so refuse instead.
            guard !hasSessionEncryptedData else {
                throw SecureCredentialError.sessionKeyUnavailable
            }
            let fresh = SymmetricKey(size: .bits256)
            try KeychainManager.save(account: sessionKeyAccount, data: fresh.withUnsafeBytes { Data($0) })
            // Read back rather than trusting the write.
            return SymmetricKey(data: try KeychainManager.read(account: sessionKeyAccount))
        }.value
        setCachedKey(key)
    }

    /// Drops the key from memory. The next save, read, or unlock needs Touch ID again.
    nonisolated static func lockSession() {
        setCachedKey(nil)
    }

    /// Encrypts and stores `passwordBytes`. Requires an unlocked session.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw SecureCredentialError.emptyPassword }
        let combined = try encrypt(passwordBytes)
        try combined.write(to: passwordFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFileURL.path)
    }

    /// Caller MUST zero the returned bytes with `.resetBytes(in:)` after use.
    nonisolated static func readPassword() throws -> Data {
        guard cachedKey() != nil else { throw SecureCredentialError.sessionLocked }
        let ciphertext = try Data(contentsOf: passwordFileURL)
        let plaintext = try decrypt(ciphertext)
        recordActivity()
        return plaintext
    }

    /// Removes only the stored password. The session key stays, since enrolled faces are encrypted under it too.
    nonisolated static func deletePassword() {
        try? FileManager.default.removeItem(at: passwordFileURL)
    }

    /// Removes the password, the enrolled faces, and the session key.
    nonisolated static func eraseEverything() throws {
        deletePassword()
        SecureFaceStore.deleteAll()
        try KeychainManager.delete(account: sessionKeyAccount)
        setCachedKey(nil)
    }
}
