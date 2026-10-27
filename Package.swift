// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BSBacktraceLogger",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "BSBacktraceLogger", targets: ["BSBacktraceLogger"]),
    ],
    targets: [
        .target(
            name: "BSBacktraceLogger",
            path: "Sources/BSBacktraceLogger",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "BacktraceDemo",
            dependencies: ["BSBacktraceLogger"],
            path: "Examples/BacktraceDemo"
        ),
        .testTarget(
            name: "BSBacktraceLoggerTests",
            dependencies: ["BSBacktraceLogger"],
            path: "Tests/BSBacktraceLoggerTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
