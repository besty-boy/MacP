// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MacPCore",
            targets: ["MacPCore"]
        )
    ],
    targets: [
        .target(
            name: "MacPCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "MacPCoreTests",
            dependencies: ["MacPCore"]
        )
    ]
)
