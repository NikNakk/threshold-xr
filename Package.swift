// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ThresholdXR",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ThresholdCore", targets: ["ThresholdCore"]),
        .executable(name: "threshold-xr", targets: ["ThresholdXR"]),
    ],
    targets: [
        // Models and services shared by the desktop app and, later, Threshold
        // Home and any agent. No UI code and no link-time XR dependencies:
        // libmonado is loaded dynamically and only when it is safe to use.
        .target(
            name: "ThresholdCore",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "ThresholdXR",
            dependencies: ["ThresholdCore"]
        ),
        .testTarget(
            name: "ThresholdCoreTests",
            dependencies: ["ThresholdCore"]
        ),
    ]
)
