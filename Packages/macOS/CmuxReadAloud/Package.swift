// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxReadAloud",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxReadAloud", targets: ["CmuxReadAloud"])],
    targets: [
        .target(name: "CmuxReadAloud", resources: [.process("Resources")]),
        .testTarget(name: "CmuxReadAloudTests", dependencies: ["CmuxReadAloud"]),
    ],
    swiftLanguageModes: [.v6]
)
