//
//  CameraDeviceCatalog.swift
//  FaceKey
//
//  Adapted from Glance (MIT, © 2026 Jonathan Zhou). Resolves the camera preference into the device to open.
//  Changed from Glance: one camera setting rather than separate ones for the built-in and external display.
//

import AVFoundation

struct CameraDevice: Identifiable, Hashable {
    let id: String // AVCaptureDevice.uniqueID
    let name: String
}

enum CameraDeviceCatalog {
    static func availableDevices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The chosen camera if it is connected, otherwise the built-in one.
    static func resolvedDevice() -> AVCaptureDevice? {
        if let preferredID = AppSettings.shared.cameraID, let device = AVCaptureDevice(uniqueID: preferredID) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
    }
}
