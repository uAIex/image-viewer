// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OCRImageViewer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "OCRImageViewer"
        )
    ]
)
