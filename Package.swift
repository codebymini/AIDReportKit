// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIDReportKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .watchOS(.v8),
    ],
    products: [
        // Models, statistics, validation, report definitions/presets and text renderers.
        // No LoopKit, CoreData or UIKit dependencies.
        .library(name: "AIDReportKit", targets: ["AIDReportKit"]),
        // Nightscout entries/treatments/profile parsing and an HTTP data source.
        .library(name: "AIDReportNightscout", targets: ["AIDReportNightscout"]),
        // Apple Health (HealthKit) data source.
        .library(name: "AIDReportHealthKit", targets: ["AIDReportHealthKit"]),
        // Report builder sheet and multi-page A4 PDF export (SwiftUI + Charts, iOS 16 / macOS 13).
        .library(name: "AIDReportUI", targets: ["AIDReportUI"]),
        // Synthetic data, in-memory sources and adapter conformance checks for host test targets.
        .library(name: "AIDReportTesting", targets: ["AIDReportTesting"]),
    ],
    targets: [
        // User-facing strings live in each target's Resources/Localizable.xcstrings.
        .target(name: "AIDReportKit", resources: [.process("Resources")]),
        .target(name: "AIDReportNightscout", dependencies: ["AIDReportKit"], resources: [.process("Resources")]),
        .target(name: "AIDReportHealthKit", dependencies: ["AIDReportKit"]),
        .target(name: "AIDReportUI", dependencies: ["AIDReportKit"], resources: [.process("Resources")]),
        .target(name: "AIDReportTesting", dependencies: ["AIDReportKit"]),
        .testTarget(
            name: "AIDReportKitTests",
            dependencies: ["AIDReportKit", "AIDReportTesting"]
        ),
        .testTarget(
            name: "AIDReportNightscoutTests",
            dependencies: ["AIDReportNightscout", "AIDReportTesting"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AIDReportHealthKitTests",
            dependencies: ["AIDReportHealthKit"]
        ),
        .testTarget(
            name: "AIDReportUITests",
            dependencies: ["AIDReportUI", "AIDReportTesting"]
        ),
    ]
)
