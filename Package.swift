// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ResizeAPFS",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ResizeCore", targets: ["ResizeCore"]),
        .executable(name: "resize-mock", targets: ["ResizeMockServer"]),
        .executable(name: "resize-helper", targets: ["ResizeHelper"])
    ],
    targets: [
        .target(name: "ResizeCore"),
        .executableTarget(name: "ResizeMockServer", dependencies: ["ResizeCore"]),
        .target(name: "NativeSystem", publicHeadersPath: "include"),
        .target(name: "ResizeDevice", dependencies: ["ResizeCore", "NativeSystem"]),
        .executableTarget(name: "ResizeHelper", dependencies: ["ResizeCore", "ResizeDevice", "NativeSystem"]),
        .testTarget(name: "ResizeCoreTests", dependencies: ["ResizeCore", "ResizeDevice"])
    ]
)
