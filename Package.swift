// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Talk360SDK",
    defaultLocalization: "en",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Talk360SDK", targets: ["Talk360SDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jitsi/webrtc.git", exact: "124.0.2"),
    ],
    targets: [
        .binaryTarget(
            name: "Shared",
            url: "https://github.com/Talk360/talk360-sdk-ios/releases/download/0.0.0/Shared.xcframework.zip",
            checksum: "0000000000000000000000000000000000000000000000000000000000000000"
        ),
        .target(
            name: "Talk360SDK",
            dependencies: [
                "Shared",
                .product(name: "WebRTC", package: "webrtc"),
            ],
            path: "Sources/Talk360SDK",
            resources: [.process("Resources")]
        ),
    ]
)
