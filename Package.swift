// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Threshold Home builds against SwiftXR. During development it uses the local
// SwiftXR checkout (SWIFTXR_PATH, default ~/Code/SwiftXR beside this
// repository's usual parent), because it relies on SwiftXR changes developed
// alongside it; otherwise it uses SwiftXR's development branch on GitHub.
// Threshold XR itself does not depend on SwiftXR.
let localSwiftXR = Context.environment["SWIFTXR_PATH"]
    ?? URL(fileURLWithPath: Context.packageDirectory)
        .deletingLastPathComponent()
        .appendingPathComponent("Code/SwiftXR").path
let swiftXR: Package.Dependency = FileManager.default.fileExists(atPath: localSwiftXR + "/Package.swift")
    ? .package(path: localSwiftXR)
    : .package(url: "https://github.com/NikNakk/SwiftXR.git", branch: "swiftxr-video-player-poc")

// Threshold Home links the Khronos OpenXR loader installed in /usr/local/lib.
let openXRLoaderLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L/usr/local/lib",
        "-Xlinker", "-rpath",
        "-Xlinker", "/usr/local/lib",
    ], .when(platforms: [.macOS]))
]

let package = Package(
    name: "ThresholdXR",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ThresholdCore", targets: ["ThresholdCore"]),
        .executable(name: "threshold-xr", targets: ["ThresholdXR"]),
        // Threshold Home, still built and installed as SwiftXR Shell.
        .executable(name: "swiftxr-shell", targets: ["SwiftXRShell"]),
    ],
    dependencies: [
        swiftXR
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

        // MARK: Threshold Home (ThresholdHome/, imported from SwiftXR Shell)

        .target(
            name: "CVizBridge",
            path: "ThresholdHome/Sources/CVizBridge",
            linkerSettings: [.linkedFramework("IOSurface"), .linkedLibrary("bsm")]
        ),
        .executableTarget(
            name: "SwiftXRShell",
            dependencies: [
                "CVizBridge",
                "ThresholdCore",
                .product(name: "SwiftXR", package: "SwiftXR"),
            ],
            path: "ThresholdHome/Sources/SwiftXRShell",
            linkerSettings: openXRLoaderLinkerSettings + [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("GameController"),
                .linkedFramework("Network"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "SwiftXRShellTests",
            dependencies: ["SwiftXRShell", "ThresholdCore"],
            path: "ThresholdHome/Tests/SwiftXRShellTests",
            linkerSettings: openXRLoaderLinkerSettings
        ),
    ]
)
