// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Solace",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Solace",
            path: "Sources/Solace",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
