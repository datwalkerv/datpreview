// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "datpreview",
    platforms: [.macOS("15.2")],
    products: [
        .executable(name: "datpreview", targets: ["datpreview"]),
        .executable(name: "refprobe", targets: ["RefProbe"]),
        .executable(name: "corecheck", targets: ["CoreCheck"]),
    ],
    targets: [
        .target(name: "PreviewCore"),
        .executableTarget(name: "RefProbe", dependencies: ["PreviewCore"]),
        .executableTarget(name: "datpreview", dependencies: ["PreviewCore"]),
        // Self-contained checks for PreviewCore (`swift run corecheck`). Not a test target because
        // the Command Line Tools' Swift Testing runtime silently discovers no tests from Swift 6.3.
        .executableTarget(name: "CoreCheck", dependencies: ["PreviewCore"]),
    ],
    swiftLanguageModes: [.v5]
)
