// swift-tools-version:5.9
// MGMKit -- pure-Swift core of the Morphing Groove Map: groove model, morph
// math, audio render, and an Accelerate (vDSP) onset detector. No UIKit, so it
// builds and unit-tests with the command-line toolchain (no Xcode needed) and
// links into the iPad app unchanged.
import PackageDescription

let package = Package(
    name: "MGMKit",
    platforms: [.macOS(.v12), .iOS(.v16)],
    products: [
        .library(name: "MGMKit", targets: ["MGMKit"]),
        .executable(name: "MGMValidate", targets: ["MGMValidate"]),
    ],
    targets: [
        .target(name: "MGMKit"),
        // Runs with the CLI toolchain (no Xcode/XCTest needed): `swift run MGMValidate`.
        .executableTarget(name: "MGMValidate", dependencies: ["MGMKit"]),
        // XCTest target -- used when opened in Xcode.
        .testTarget(name: "MGMKitTests", dependencies: ["MGMKit"]),
    ]
)
