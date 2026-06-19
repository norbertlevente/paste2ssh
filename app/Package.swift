// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Paste2SSH",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Paste2SSH", targets: ["Paste2SSH"])
    ],
    targets: [
        .executableTarget(
            name: "Paste2SSH",
            path: "Sources/Paste2SSH",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ]
)
