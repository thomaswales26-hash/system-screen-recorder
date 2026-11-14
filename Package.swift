// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SystemScreenRecorder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "system-screen-recorder", targets: ["SystemScreenRecorder"])
    ],
    targets: [
        .executableTarget(name: "SystemScreenRecorder")
    ]
)
