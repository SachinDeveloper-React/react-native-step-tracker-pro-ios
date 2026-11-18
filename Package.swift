// swift-tools-version:5.9
// The pure logic of the iOS module - metrics, minute bucketing, the fraud
// rules, source resolution, the motion gate, snapshot building, JSON - as a
// Swift package, so `swift test` runs it on macOS without a simulator. The
// same files compile into the CocoaPod; nothing here imports HealthKit,
// CoreMotion or UIKit.
import PackageDescription

let package = Package(
    name: "StepTrackerProCore",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "StepTrackerProCore", targets: ["StepTrackerProCore"]),
    ],
    targets: [
        .target(name: "StepTrackerProCore", path: "ios/Core"),
        .testTarget(
            name: "StepTrackerProCoreTests",
            dependencies: ["StepTrackerProCore"],
            path: "ios/Tests/StepTrackerProCoreTests"
        ),
    ]
)
