// swift-tools-version: 6.2
import PackageDescription

// The build settings mirror the ones Glance's Xcode project uses (Swift 5 language mode, main-actor default
// isolation, approachable concurrency), so the engine files copied from Glance compile unchanged.
let package = Package(
    name: "FaceKey",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "FaceKey",
            path: "Sources/FaceKey",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        )
    ]
)
