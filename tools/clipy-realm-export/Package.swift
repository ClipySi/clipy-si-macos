// swift-tools-version:5.10
//
//  Package.swift — clipy-realm-export
//
//  A standalone, NON-shipped migration tool that reads the ORIGINAL Clipy's Realm history
//  (default.realm + the per-clip `.data` NSKeyedArchiver blobs) and emits the ClipySi History
//  Manager's JSON export format. This is the only place RealmSwift is used — the ClipySi
//  app itself never links Realm; the user runs this once, then imports the JSON via "History… →
//  Import…". Swift 5 language mode: RealmSwift isn't Swift-6-strict-concurrency-audited.
//

import PackageDescription

let package = Package(
    name: "clipy-realm-export",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to RealmSwift 10.7.2 / realm-core 10.5.5 — the EXACT version Clipy 1.2.2 ships — because
        // that is the realm-core that can still READ the original's on-disk Realm FILE FORMAT 9. Newer
        // realm-core (e.g. 20.1.4) rejects it with `UnsupportedFileFormatVersion` ("unsupported version
        // (9) and cannot be upgraded"). Despite the earlier assumption, realm-core 10.5.5 DOES build on
        // the macOS 26 SDK — the `std::is_pod` / `_LIBCPP_NO_SPECIALIZATIONS` hardening that blocks later
        // 10.x cores (realm-core ~14) does not affect 10.5.5. Verified end-to-end against a real v1.2.1
        // default.realm (30/30 text clips extracted). 10.7.2 predates `@Persisted`, so CPYClip uses the
        // legacy `@objc dynamic var` + `primaryKey()` syntax.
        .package(url: "https://github.com/realm/realm-swift.git", exact: "10.7.2")
    ],
    targets: [
        .target(
            name: "ClipyRealmExportKit",
            dependencies: [.product(name: "RealmSwift", package: "realm-swift")]
        ),
        .executableTarget(
            name: "clipy-realm-export",
            dependencies: ["ClipyRealmExportKit"]
        ),
        .testTarget(
            name: "ClipyRealmExportKitTests",
            dependencies: ["ClipyRealmExportKit"]
        )
    ]
)
