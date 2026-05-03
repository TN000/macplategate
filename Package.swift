// swift-tools-version:5.10
import PackageDescription

// Pozn.: Testy v Tests/SPZAppTests/ vyžadují FULL Xcode (ne Command Line Tools).
// CLT nemá XCTest/Testing framework, takže `swift test` přes CLT selže.
// Pro spuštění testů: install Xcode, pak `xed .` → ⌘U.
let package = Package(
    name: "SPZApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SPZApp", targets: ["SPZApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 exact: "1.24.2"),
    ],
    targets: [
        .executableTarget(
            name: "SPZApp",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/SPZApp",
            resources: [
                // .process() compiles Localizable.xcstrings → per-locale .strings
                // and bundles ONNX config / privacy manifest verbatim.
                .process("Resources"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        .testTarget(
            name: "SPZAppTests",
            dependencies: ["SPZApp"],
            path: "Tests/SPZAppTests"
        ),
    ]
)
