//
//  NotchPanelStyle.swift
//  glance
//
//  Which silhouette the overlay panel wears on a given screen — passed down
//  through the environment so onboarding's step views can adapt without a parameter.
//

import SwiftUI

enum NotchPanelStyle {
    /// Inverted top corners, flush with the screen's top edge.
    case notch
    /// Fully-rounded pill / floating rounded rectangle, detached from the edge.
    case pill
}

// Changed from Glance: written out by hand because the `@Entry` macro's compiler plugin ships only with Xcode.
private struct NotchPanelStyleKey: EnvironmentKey {
    static let defaultValue: NotchPanelStyle = .notch
}

extension EnvironmentValues {
    var notchPanelStyle: NotchPanelStyle {
        get { self[NotchPanelStyleKey.self] }
        set { self[NotchPanelStyleKey.self] = newValue }
    }
}
