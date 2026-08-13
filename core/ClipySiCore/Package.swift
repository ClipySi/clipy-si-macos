// swift-tools-version:5.9
import PackageDescription
import Foundation

// ClipySiCore — Swift bindings for the shared Rust core (`clipy-si-core`).
//
// The compiled core ships as a prebuilt `ClipySiCoreFFI.xcframework`. Released, CI, and public
// builds download it from this repository's GitHub Release asset (`binaryTarget(url:checksum:)`).
// `Sources/ClipySiCore/clipy_si_core_ffi.swift` is the committed, generated UniFFI glue that the
// app compiles against.
//
// Local core development: drop a locally built `ClipySiCoreFFI.xcframework` next to this
// `Package.swift` (it is git-ignored) and it is used directly — so you can build the app without a
// published release. See README.md for how the XCFramework is produced and released.

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localXCFramework = packageDir.appendingPathComponent("ClipySiCoreFFI.xcframework")

let coreBinary: Target = FileManager.default.fileExists(atPath: localXCFramework.path)
    ? .binaryTarget(name: "ClipySiCoreFFI", path: "ClipySiCoreFFI.xcframework")
    : .binaryTarget(
        name: "ClipySiCoreFFI",
        url: "https://github.com/ClipySi/clipy-si-macos/releases/download/core-v0.2.0/ClipySiCoreFFI.xcframework.zip",
        checksum: "c4e91866716a2641ea0fac0aec71ae07883b46b2c6a4de25bd4d64b80581d272"
    )

let package = Package(
    name: "ClipySiCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipySiCore", targets: ["ClipySiCore"]),
    ],
    targets: [
        coreBinary,
        .target(
            name: "ClipySiCore",
            dependencies: ["ClipySiCoreFFI"],
            path: "Sources/ClipySiCore"
        ),
    ]
)
