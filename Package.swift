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
    ],
    targets: [
        // User-facing strings live in each target's Resources/Localizable.xcstrings.
        .target(name: "AIDReportKit", resources: [.process("Resources")]),
    ]
)
