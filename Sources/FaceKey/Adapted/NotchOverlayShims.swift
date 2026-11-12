//
//  NotchOverlayShims.swift
//  FaceKey
//
//  Glance's notch overlay (Sources/FaceKey/Glance/NotchOverlay) also hosts Glance's onboarding flow and reads
//  Glance's settings and theme. FaceKey has its own settings window and no onboarding, so these stand-ins let the
//  overlay files compile almost unchanged while only the scan animation is ever shown.
//

import SwiftUI

/// The overlay reads its options through this name.
typealias GlanceSettings = AppSettings

enum GlanceTheme {
    static let textPrimary = Color.white
}

/// Never created in FaceKey; the overlay's onboarding mode is unused.
final class OnboardingController {
    let panelSize = NotchGeometry.notchOpenSize
    let panelBottomRadius = NotchGeometry.openBottomRadius
}

struct OnboardingNotchView: View {
    let controller: OnboardingController
    var body: some View { EmptyView() }
}

/// Zero, so the overlay window is sized for the scan animation alone.
enum OnboardingMetrics {
    static let maxPanelWidth: CGFloat = 0
    static func maxPanelHeight(for style: NotchPanelStyle) -> CGFloat { 0 }
}
