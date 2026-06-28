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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Paste2SSH",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Paste2SSH",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
