// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aural",
    platforms: [.macOS("15.4")],
    products: [.executable(name: "Aural", targets: ["Aural"])],
    targets: [
        .target(name: "AuralCore"),
        .executableTarget(name: "Aural", dependencies: ["AuralCore"], resources: [.process("Resources")]),
        .testTarget(name: "AuralCoreTests", dependencies: ["AuralCore"]),
        .testTarget(name: "AuralPanelTests", dependencies: ["Aural"])
    ],
    swiftLanguageModes: [.v5]
)
